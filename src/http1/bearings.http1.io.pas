{ bearings.http1.io - the buffered reads and writes of one HTTP/1.1 connection.

  TH1Io sits between the connection's state machine (bearings.http1.conn) and the
  non-blocking socket (TTransport, bearings.rt.net). It owns:
  - the read buffer (TReadBuf, see bearings.rt.buf): bytes read from the socket
    wait there until the request head parser or the body decoder consumes
    them. A client may send several requests back to back without waiting
    for the responses (pipelining), so after one request the buffer can
    already hold the start of the next one;
  - the write buffer (TWriteBuf): response bytes waiting to be written.

  Reading. The parser needs the whole request head (request line and header
  fields, ending with an empty line, CRLF CRLF) in one contiguous buffer.
  Parse reads from the socket until the head is complete, until the
  buffer reaches the head size limit (max_header_size, which ends in a 431
  response) or until it reaches max_buf_size. Each read asks for
  TReadStrategy.Next bytes: the size starts at 8 KiB, doubles after a read
  that filled it, and halves after two reads in a row that used less than
  half of it, so a connection that sends large bodies reads in large pieces
  and an idle one keeps a small buffer. The buffer never holds more than
  max_buf_size bytes.

  Writing. A response is a head followed by body pieces. Small pieces
  (at most MAX_COPY_SIZE bytes) are copied into one contiguous buffer, the
  cursor; the response head is also encoded straight into it. Copying is
  cheaper than tracking many small separate buffers, and the whole batch
  goes out in one write(2). Large pieces and file ranges are not copied:
  they go into a queue of entries (TBufList), and the flush writes the
  cursor and the queued memory entries with one writev(2), and a file entry
  with sendfile(2). Once something is queued, every later piece is queued
  too, even a small one: the cursor is always written before the queue, so
  copying a later piece into the cursor would send it before the queued
  bytes. A response head that must be written while entries are queued
  (an automatic 400/414/431, or "100 Continue") is queued behind them for
  the same reason (BufferAfterQueue).

  Pipelined responses must be written in the order of the requests, since
  HTTP/1.1 has no other way to match a response to its request. The single
  cursor-then-queue order keeps them in order.

  Flush pipelining (FlushPipeline, the pipeline_flush option): while the
  read buffer still holds bytes of further requests, PollFlush does not
  write, so the responses to a batch of pipelined requests go out together
  in fewer system calls.

  Results: TIoPoll is ipReady, ipPending (the socket returned EAGAIN; the
  connection's task runs again on the next readiness event from the loop,
  see bearings.rt.loop) or ipError with the errno in Errno. A write that returns
  0 while bytes remain is reported as Errno = IO_ERRNO_WRITE_ZERO, since no
  OS errno exists for it.

  Ownership: Buffer takes ownership of its TQueuedBuf (the body data and the
  byte vector belong to the write buffer from then on). A copied entry
  releases its data right after the copy; a queued entry releases it in
  TBufList.Advance, once all its bytes were written.

  Memory: ReleaseIdle gives the read block, the cursor block and the queue
  array back to the loop's block pool when they hold nothing, so an idle
  keep-alive connection holds no buffers.

  Threading: a TH1Io belongs to the loop thread of its connection.

  No managed types: no routine of this unit gets an implicit exception
  frame (tools/check-hot-asm.sh checks TH1Io.*). }
unit bearings.http1.io;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  ctypes, bearings.rt.buf, bearings.rt.net, bearings.http.headers, bearings.http1.encode, bearings.http1.role, bearings.http.error;

const
  INIT_BUFFER_SIZE = 8192;                         { first read size; also the minimum read size }
  MINIMUM_MAX_BUFFER_SIZE = INIT_BUFFER_SIZE;      { smallest allowed max_buf_size }
  DEFAULT_MAX_BUFFER_SIZE = 8192 + 4096 * 100;     { default max_buf_size (417 792 bytes) }
  MAX_BUF_LIST_BUFFERS = 16;                       { CanBuffer's bound on queued entries }
  { The queue ring: the 16 entries CanBuffer lets callers queue plus the
    heads BufferAfterQueue puts behind them. A power of two, so the ring
    index is a mask; Push raises EH1Panic when it is full. }
  QUEUE_SLOTS = 32;
  { TWriteBuf.Buffer copies an entry of at most this many bytes into the
    cursor (when nothing is queued); larger entries are queued for writev. }
  MAX_COPY_SIZE = 4096;
  MAX_WRITEV_BUFS = 64;                            { iovec entries per writev(2) call }

  { A write returned 0 while bytes were left: not an OS errno, so a
    negative marker in the Errno of ipError. }
  IO_ERRNO_WRITE_ZERO = -1;

  { Linux sendfile(2) moves at most 0x7ffff000 bytes per call. }
  SENDFILE_MAX_CHUNK = $7ffff000;

type
  { The adaptive read size. Next is the number of bytes the next read asks
    for, between INIT_BUFFER_SIZE and Max (max_buf_size). Record_ grows Next
    at once after a read that filled it and shrinks it only after two
    consecutive reads that would have fit in half of it (DecreaseNow marks
    the first one), so one short read does not shrink the buffer. Unsigned
    fields. }
  TReadStrategy = record
    DecreaseNow: Boolean;
    Next: SizeUInt;
    Max: SizeUInt;
    procedure InitWithMax(AMax: SizeUInt);
    procedure InitDefault;                          { InitWithMax(DEFAULT_MAX_BUFFER_SIZE) }
    procedure Record_(BytesRead: SizeUInt);         { the trailing '_': 'record' is a keyword }
  end;

  { The write cursor: a byte vector and the position of the first byte not
    yet written. Bytes[0..Pos-1] were written; Bytes[Pos..Len-1] wait. }
  TCursor = record
    Bytes: TByteVec;                 { memory from the pool at the first append }
    Pos: SizeInt;
    function Remaining: SizeInt; inline;
    function Chunk: PByte; inline;
    procedure Advance(N: SizeInt); inline;
    { drops the written prefix when the block has no room for Additional more bytes }
    procedure MaybeUnshift(Additional: SizeInt);
    procedure Reset; inline;                       { Pos := 0 and the vector emptied }
  end;
  PCursor = ^TCursor;

  { What a queue entry holds:
    qkEncoded   a body piece framed by the encoder (TEncodedBuf: an optional
                chunk-size line, the data, an optional suffix such as the
                CRLF after a chunk);
    qkTrailers  an encoded trailer section ("0" CRLF, trailer fields, CRLF)
                in Trailers;
    qkFile      a range of a file, sent with sendfile(2);
    qkBytes     owned bytes sent as one slice (a head written while entries
                are queued: TH1Io.BufferAfterQueue). }
  TQueuedKind = (qkEncoded, qkTrailers, qkFile, qkBytes);
  PQueuedBuf = ^TQueuedBuf;
  { One write buffer entry. }
  TQueuedBuf = record
    Kind: TQueuedKind;
    Enc: TEncodedBuf;                { qkEncoded: chunk-size prefix inline + data pointer + static suffix }
    Owner: TBodyData;                { releases the data after it was written; no managed fields }
    Trailers: TByteVec;              { qkTrailers: "0\r\n" + fields + "\r\n";
                                       qkBytes: the bytes }
    TrailersPos: SizeInt;            { qkTrailers, qkBytes: bytes of Trailers already written }
    FileFd: cint; FileOff, FileLen: Int64;      { qkFile: FileLen = bytes still to send }
    function Remaining: SizeInt;
    procedure Advance(N: SizeInt);
    { Fills Dst with at most Max iovec entries for the bytes not yet
      written (empty segments are skipped). qkFile: none. }
    function FillIoVec(Dst: PIoSlice; Max: Integer): Integer;
    { Releases Owner and the block of Trailers. }
    procedure Release;
  end;
  PQueuedArray = ^TQueuedArray;
  TQueuedArray = array[0..QUEUE_SLOTS - 1] of TQueuedBuf;

  { The queue of write entries: a ring of at most QUEUE_SLOTS entries, in
    the order they are written. }
  TBufList = record
    Items: PQueuedArray;             { pooled; nil until first use and after ReleaseIdle }
    ItemsBlock: PBufBlock;           { the pool block that holds Items }
    Head, Count: Integer;
    Files: Integer;                  { qkFile entries in the ring }
    function Remaining: SizeInt;
    { Every entry has bytes left (Push asserts it, Advance removes written
      entries), so the list has bytes left exactly when Count > 0. }
    function HasRemaining: Boolean; inline;
    function Front: PQueuedBuf; inline;
    { raises EH1Panic when the ring is full (QUEUE_SLOTS entries) }
    procedure Push(const B: TQueuedBuf; Pool: PBlockPool);
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;   { stops before a qkFile }
    procedure Advance(N: SizeInt);   { releases fully written entries (Owner, Trailers) }
    procedure ReleaseIdle;           { Count = 0: the array goes back to the pool }
    procedure Done;                  { releases every entry and the array }
  end;

  { The write buffer: the cursor (written first) and then the queue. }
  TWriteBuf = record
    Headers: TCursor;                { the cursor: encoded heads and copied small pieces }
    MaxBufSize: SizeInt;             { max_buf_size; DEFAULT_MAX_BUFFER_SIZE }
    Queue: TBufList;
    procedure Init;
    { Copies B into the cursor (and releases its data at once) when nothing is
      queued, B is not a file and B.Remaining <= MAX_COPY_SIZE; queues B
      otherwise. Asserts B.Remaining > 0 (-Sa). }
    procedure Buffer(const B: TQueuedBuf; Pool: PBlockPool);
    { Room for more body: Remaining < MaxBufSize and Queue.Count < 16. The
      connection stops taking body pieces from the handler while it is
      False, which bounds the memory one response can hold. }
    function CanBuffer: Boolean;
    function HeadersMut: PCursor;    { the cursor; asserts that nothing is queued }
    function Remaining: SizeInt;
    { Marks Cnt bytes as written: first the cursor's, then the queue's. }
    procedure Advance(Cnt: SizeInt);
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
  end;

  TIoPoll = (ipReady, ipPending, ipError);

  { The buffered transport of one connection (see the unit header). }
  TH1Io = record
    FlushPipeline: Boolean;          { the pipeline_flush option }
    Io: TTransport;
    { Length of the read buffer when the last parse attempt found the head
      incomplete, or -1. The next attempt looks for the end of the head
      only in the new bytes (and the 3 before them, since CRLF CRLF may
      straddle two reads) and skips the full parse when it is not there. }
    PartialLen: SizeInt;
    ReadBlocked: Boolean;            { the last read returned EAGAIN }
    { Transport results that were Pending (EAGAIN), for the dispatcher's
      debug check that a task returning Pending will be woken: a Pending
      read or write means the next readiness event wakes it. }
    PendingReads, PendingWrites: QWord;
    ReadBuf: TReadBuf;
    ReadBufStrategy: TReadStrategy;
    WriteBuf: TWriteBuf;
    Pool: PBlockPool;                { the loop's block pool }
    procedure Init(AIo: TTransport; APool: PBlockPool);
    { asserts that nothing is buffered for writing }
    procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetMaxBufSize(Max: SizeInt);                    { asserts Max >= MINIMUM_MAX_BUFFER_SIZE }
    function ReadBufPtr: PByte; inline;
    function ReadBufLen: SizeInt; inline;
    { True when a head can be encoded into the cursor: nothing is queued. }
    function CanHeadersBuf: Boolean; inline;
    { The cursor's byte vector (ServerEncode appends the response head to
      it). Only while CanHeadersBuf. }
    function HeadersBuf: PByteVec; inline;
    { Adds B to the write buffer; takes ownership of B. }
    procedure Buffer(const B: TQueuedBuf); inline;
    { A head written while entries are queued (the automatic 400/414/431 or
      100 Continue): queued after them as one qkBytes entry, so it never
      lands inside an earlier response. Takes V's block (V is left empty). }
    procedure BufferAfterQueue(var V: TByteVec);
    function HasBufferedWrite: Boolean; inline;
    { FlushPipeline (while the queue has room) or WriteBuf.CanBuffer }
    function CanBuffer: Boolean; inline;
    { Drops CR and LF bytes at the front of the read buffer. RFC 9112 2.2
      lets a server ignore empty lines before a request line; this is used
      to tell a connection closed between requests from one closed in the
      middle of a head. }
    procedure ConsumeLeadingLines;
    { Reads and parses one request head. On prOk: Msg filled, Headers filled
      with entries that point into the head bytes, and Head = the head
      split off the front of the read buffer (a pinned view, so the header
      entries stay valid while Head is alive). prPending: the head is not
      complete and the socket has no more bytes now. prErr: Err is a parse
      error, a size limit (TooLarge), an I/O error, or Incomplete (the peer
      closed the connection before the head was complete). }
    function Parse(const Ctx: TH1ParseContext; Headers: THttpHeaders; out Msg: TParsedRequestHead;
      out Head: TBytesView; var Err: THyperError): TPollResult;
    { One read(2) from the socket into the read buffer: asks for
      Min(ReadBufStrategy.Next, max_buf_size - Len) bytes, so the buffer
      never holds more than max_buf_size; updates the strategy; sets
      ReadBlocked on EAGAIN. N = 0 means the peer closed its side (EOF). }
    function PollReadFromIo(out N: SizeInt; out Errno: cint): TIoPoll;
    function IsReadBlocked: Boolean; inline;
    { A pinned view of up to Len bytes from the front of the read buffer.
      Reads from the socket only when the buffer is empty; View.Len = 0
      after a ready read means EOF. }
    function ReadMem(Len: SizeInt; out View: TBytesView; out Errno: cint): TIoPoll;
    { Writes the write buffer until it is empty (ipReady), the socket is full
      (ipPending) or an error. With FlushPipeline, bytes in the read buffer
      and nothing queued, it writes nothing and returns ipReady (the
      responses to the following requests will join the batch). Not when
      something is queued: while an entry is queued no later head can be
      buffered (CanHeadersBuf is False), so holding the bytes would stall
      the connection. }
    function PollFlush(out Errno: cint): TIoPoll;
    { True exactly when PollFlush would skip under FlushPipeline while the
      write buffer holds bytes. }
    function HoldsPipelinedWrite: Boolean; inline;
    { PollFlush without the FlushPipeline skip. The dispatcher calls it
      once the connection is done (before an upgrade hand-off, handing the
      transport on as parts, or shutdown), where no later response can join
      the batch, so the held bytes must be written now or they would be
      lost. }
    function PollFlushHeld(out Errno: cint): TIoPoll;
    { write(2) of the cursor until it is empty (queue empty) }
    function PollFlushCursor(out Errno: cint): TIoPoll;
    { the writev loop over the cursor and the queue, sendfile(2) for a file entry at the front }
    function PollFlushQueue(out Errno: cint): TIoPoll;
    { Flushes, then shuts down the write side of the socket (shutdown(2)
      SHUT_WR): the peer reads EOF after the last response byte. }
    function PollShutdown(out Errno: cint): TIoPoll;
    { Hands the connection over (upgrade): returns the transport and the
      bytes still in the read buffer (they belong to the new protocol), and
      drops the write buffer. Io := nil. }
    procedure IntoInner(out AIo: TTransport; out Rest: TBytesView);
    { Gives back the blocks that hold nothing (read buffer empty and
      unpinned, cursor empty, queue empty). }
    procedure ReleaseIdle;
    { Frees every block and releases queued data. The transport is not
      closed. }
    procedure Done;
  end;

function IncrPowerOfTwo(N: SizeUInt): SizeUInt; inline;   { N * 2, saturating at High(SizeUInt) }
{ The largest power of two <= N div 2 (N >= 4). }
function PrevPowerOfTwo(N: SizeUInt): SizeUInt; inline;

{ Entries for TWriteBuf.Buffer / TH1Io.Buffer. }
{ An encoded body chunk (TEncoder.Encode / EncodeAndEnd / Finish); Owner
  is released once its bytes were written or copied. }
function QueuedEncoded(const Enc: TEncodedBuf; const Owner: TBodyData): TQueuedBuf;
{ An encoded trailer section (TEncoder.EncodeTrailers into V). Takes V's
  block: V is left empty (capacity 0, no block). }
function QueuedTrailers(var V: TByteVec): TQueuedBuf;
{ Len bytes of Fd from Off, sent with sendfile(2); Owner (normally the
  BodyFile data) is released when the last byte was sent. }
function QueuedFile(Fd: cint; Off, Len: Int64; const Owner: TBodyData): TQueuedBuf;
{ V's bytes as one slice (qkBytes). Takes V's block: V is left empty. }
function QueuedBytes(var V: TByteVec): TQueuedBuf;

implementation

uses
  bearings.rt.sys;

const
  QUEUE_MASK = QUEUE_SLOTS - 1;
  {$IF (QUEUE_SLOTS and QUEUE_MASK) <> 0}{$ERROR QUEUE_SLOTS must be a power of two}{$ENDIF}
  {$IF QUEUE_SLOTS <= MAX_BUF_LIST_BUFFERS}{$ERROR QUEUE_SLOTS must exceed MAX_BUF_LIST_BUFFERS}{$ENDIF}

{ Frees V's block (pool or heap) and empties V. }
procedure ByteVecFree(var V: TByteVec); inline;
begin
  if V.Block <> nil then
    BlockFree(V.Block);
  V := Default(TByteVec);
end;

{ ---- TReadStrategy ---- }

function IncrPowerOfTwo(N: SizeUInt): SizeUInt;
begin
  if N > High(SizeUInt) shr 1 then
    Result := High(SizeUInt)
  else
    Result := N shl 1;
end;

function PrevPowerOfTwo(N: SizeUInt): SizeUInt;
begin
  { (High(SizeUInt) shr (leading zero bits of N + 2)) + 1; for N < 4 the
    shift count would reach 64 }
  Assert(N >= 4, 'PrevPowerOfTwo: n < 4');
  Result := (High(SizeUInt) shr ((63 - BsrQWord(QWord(N))) + 2)) + 1;
end;

procedure TReadStrategy.InitWithMax(AMax: SizeUInt);
begin
  DecreaseNow := False;
  Next := INIT_BUFFER_SIZE;
  Max := AMax;
end;

procedure TReadStrategy.InitDefault;
begin
  InitWithMax(DEFAULT_MAX_BUFFER_SIZE);
end;

procedure TReadStrategy.Record_(BytesRead: SizeUInt);
var
  DecrTo, Incr: SizeUInt;
begin
  if BytesRead >= Next then
  begin
    { the read filled the requested size: double it, up to Max }
    Incr := IncrPowerOfTwo(Next);
    if Incr < Max then
      Next := Incr
    else
      Next := Max;
    DecreaseNow := False;
  end
  else
  begin
    DecrTo := PrevPowerOfTwo(Next);
    if BytesRead < DecrTo then
    begin
      if DecreaseNow then
      begin
        if DecrTo > INIT_BUFFER_SIZE then
          Next := DecrTo
        else
          Next := INIT_BUFFER_SIZE;
        DecreaseNow := False;
      end
      else
        { the first short read only marks it; the second one shrinks }
        DecreaseNow := True;
    end
    else
      { a read between half and the full size shows that the current size
        is still needed: cancel a pending decrease }
      DecreaseNow := False;
  end;
end;

{ ---- TCursor ---- }

function TCursor.Remaining: SizeInt;
begin
  Result := Bytes.Len - Pos;
end;

function TCursor.Chunk: PByte;
begin
  Result := Bytes.Data + Pos;
end;

procedure TCursor.Advance(N: SizeInt);
begin
  Assert(Pos + N <= Bytes.Len, 'TCursor.Advance: past the end');
  Inc(Pos, N);
end;

procedure TCursor.MaybeUnshift(Additional: SizeInt);
begin
  if Pos = 0 then
    { nothing written yet: nothing to drop }
    Exit;
  if Bytes.Cap - Bytes.Len >= Additional then
    { the new bytes fit after the existing ones }
    Exit;
  Bytes.DrainFront(Pos);
  Pos := 0;
end;

procedure TCursor.Reset;
begin
  Pos := 0;
  Bytes.Clear;
end;

{ ---- Queue entries ---- }

function QueuedEncoded(const Enc: TEncodedBuf; const Owner: TBodyData): TQueuedBuf;
begin
  { every field is stored one by one instead of Default(): the FillChar of
    Default was measurable per request }
  Result.Kind := qkEncoded;
  Result.Enc := Enc;
  Result.Owner := Owner;
  Result.Trailers.Data := nil;
  Result.Trailers.Len := 0;
  Result.Trailers.Cap := 0;
  Result.Trailers.Block := nil;
  Result.TrailersPos := 0;
  Result.FileFd := -1;
  Result.FileOff := 0;
  Result.FileLen := 0;
end;

function QueuedTrailers(var V: TByteVec): TQueuedBuf;
begin
  Result := Default(TQueuedBuf);
  Result.Kind := qkTrailers;
  Result.Trailers := V;
  Result.TrailersPos := 0;
  Result.Owner := BodyEmpty;
  Result.FileFd := -1;
  V := Default(TByteVec);
end;

function QueuedFile(Fd: cint; Off, Len: Int64; const Owner: TBodyData): TQueuedBuf;
begin
  Result := Default(TQueuedBuf);
  Result.Kind := qkFile;
  Result.Owner := Owner;
  Result.FileFd := Fd;
  Result.FileOff := Off;
  Result.FileLen := Len;
end;

function QueuedBytes(var V: TByteVec): TQueuedBuf;
begin
  Result := Default(TQueuedBuf);
  Result.Kind := qkBytes;
  Result.Trailers := V;
  Result.TrailersPos := 0;
  Result.Owner := BodyEmpty;
  Result.FileFd := -1;
  V := Default(TByteVec);
end;

function TQueuedBuf.Remaining: SizeInt;
begin
  case Kind of
    qkEncoded: Result := Enc.Remaining;
    qkTrailers, qkBytes: Result := Trailers.Len - TrailersPos;
  else
    Result := FileLen;
  end;
end;

procedure TQueuedBuf.Advance(N: SizeInt);
begin
  case Kind of
    qkEncoded:
      Enc.Advance(N);
    qkTrailers, qkBytes:
      begin
        Assert(TrailersPos + N <= Trailers.Len, 'TQueuedBuf.Advance: past the trailers');
        Inc(TrailersPos, N);
      end;
  else
    begin
      Assert(N <= FileLen, 'TQueuedBuf.Advance: past the file range');
      Inc(FileOff, N);
      Dec(FileLen, N);
    end;
  end;
end;

function TQueuedBuf.FillIoVec(Dst: PIoSlice; Max: Integer): Integer;
var
  S, E, A, B: SizeInt;
  Seg: Integer;
begin
  case Kind of
    qkEncoded:
      Result := Enc.FillIoVec(Dst, Max);
    qkTrailers:
      begin
        { three segments of the one vector: "0\r\n", the fields, the final
          "\r\n" }
        Result := 0;
        for Seg := 0 to 2 do
        begin
          if Result >= Max then
            Break;
          case Seg of
            0: begin S := 0; E := 3; end;
            1: begin S := 3; E := Trailers.Len - 2; end;
          else
            begin S := Trailers.Len - 2; E := Trailers.Len; end;
          end;
          A := S;
          if A < TrailersPos then
            A := TrailersPos;
          B := E;
          if B > A then
          begin
            Dst[Result].Base := Trailers.Data + A;
            Dst[Result].Len := SizeUInt(B - A);
            Inc(Result);
          end;
        end;
      end;
    qkBytes:
      begin
        Result := 0;
        if (Max > 0) and (Trailers.Len > TrailersPos) then
        begin
          Dst[0].Base := Trailers.Data + TrailersPos;
          Dst[0].Len := SizeUInt(Trailers.Len - TrailersPos);
          Result := 1;
        end;
      end;
  else
    Result := 0;
  end;
end;

procedure TQueuedBuf.Release;
begin
  ReleaseBody(Owner);
  if Trailers.Block <> nil then
    ByteVecFree(Trailers);
end;

{ ---- TBufList ---- }

procedure QueueOverflow;
begin
  { CanBuffer keeps callers at MAX_BUF_LIST_BUFFERS entries and at most a
    few heads go behind them, so a full ring is a bug in the caller }
  raise EH1Panic.Create('TBufList.Push: the queue ring is full');
end;

function TBufList.Remaining: SizeInt;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    Inc(Result, Items^[(Head + I) and QUEUE_MASK].Remaining);
end;

function TBufList.HasRemaining: Boolean;
begin
  Result := Count > 0;
end;

function TBufList.Front: PQueuedBuf;
begin
  Result := @Items^[Head];
end;

procedure TBufList.Push(const B: TQueuedBuf; Pool: PBlockPool);
begin
  Assert(B.Remaining > 0, 'TBufList.Push: empty buffer');
  if Count >= QUEUE_SLOTS then
    QueueOverflow;
  if Items = nil then
  begin
    ItemsBlock := BlockAlloc(Pool, SizeOf(TQueuedArray));
    Items := PQueuedArray(ItemsBlock^.Data);
    Head := 0;
  end;
  Items^[(Head + Count) and QUEUE_MASK] := B;
  Inc(Count);
  if B.Kind = qkFile then
    Inc(Files);
end;

function TBufList.ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
var
  I: Integer;
  E: PQueuedBuf;
begin
  { a qkFile entry ends the list: it is sent with sendfile(2) once it
    reaches the front }
  Result := 0;
  if Max <= 0 then
    Exit;
  for I := 0 to Count - 1 do
  begin
    E := @Items^[(Head + I) and QUEUE_MASK];
    if E^.Kind = qkFile then
      Break;
    Inc(Result, E^.FillIoVec(Dst + Result, Max - Result));
    if Result = Max then
      Break;
  end;
end;

procedure TBufList.Advance(N: SizeInt);
var
  E: PQueuedBuf;
  Rem: SizeInt;
begin
  while N > 0 do
  begin
    Assert(Count > 0, 'TBufList.Advance: past the end');
    E := @Items^[Head];
    Rem := E^.Remaining;
    if Rem > N then
    begin
      E^.Advance(N);
      Exit;
    end;
    Dec(N, Rem);
    { the entry was fully written: release it and remove it from the ring }
    if E^.Kind = qkFile then
      Dec(Files);
    E^.Release;
    Head := (Head + 1) and QUEUE_MASK;
    Dec(Count);
  end;
end;

procedure TBufList.ReleaseIdle;
begin
  if (Count <> 0) or (ItemsBlock = nil) then
    Exit;
  BlockFree(ItemsBlock);
  ItemsBlock := nil;
  Items := nil;
  Head := 0;
end;

procedure TBufList.Done;
begin
  while Count > 0 do
  begin
    Items^[Head].Release;
    Head := (Head + 1) and QUEUE_MASK;
    Dec(Count);
  end;
  Files := 0;
  ReleaseIdle;
end;

{ ---- TWriteBuf ---- }

procedure TWriteBuf.Init;
begin
  Headers.Bytes := Default(TByteVec);
  Headers.Pos := 0;
  MaxBufSize := DEFAULT_MAX_BUFFER_SIZE;
  Queue := Default(TBufList);
end;

procedure TWriteBuf.Buffer(const B: TQueuedBuf; Pool: PBlockPool);
var
  Head: PCursor;
  Iov: array[0..2] of TIoSlice;
  N, I: Integer;
  Rem: SizeInt;
  Own: TBodyData;
  Tr: TByteVec;
begin
  Rem := B.Remaining;
  Assert(Rem > 0, 'TWriteBuf.Buffer: empty buffer');
  if (B.Kind = qkFile) or (Queue.Count > 0) or (Rem > MAX_COPY_SIZE) then
  begin
    { large, a file, or behind a queued entry (the cursor is written before
      the queue, so copying would move these bytes ahead of it) }
    Queue.Push(B, Pool);
    Exit;
  end;
  Head := HeadersMut;
  Head^.MaybeUnshift(Rem);
  N := B.FillIoVec(@Iov[0], 3);
  for I := 0 to N - 1 do
    Head^.Bytes.Append(Iov[I].Base, SizeInt(Iov[I].Len), Pool);
  { the bytes were copied: release the entry's data now }
  Own := B.Owner;
  ReleaseBody(Own);
  if B.Kind in [qkTrailers, qkBytes] then
  begin
    Tr := B.Trailers;
    ByteVecFree(Tr);
  end;
end;

function TWriteBuf.CanBuffer: Boolean;
begin
  Result := (Queue.Count < MAX_BUF_LIST_BUFFERS) and (Remaining < MaxBufSize);
end;

function TWriteBuf.HeadersMut: PCursor;
begin
  Assert(not Queue.HasRemaining, 'TWriteBuf.HeadersMut: queued buffers remain');
  Result := @Headers;
end;

function TWriteBuf.Remaining: SizeInt;
begin
  Result := Headers.Remaining + Queue.Remaining;
end;

procedure TWriteBuf.Advance(Cnt: SizeInt);
var
  HRem: SizeInt;
begin
  HRem := Headers.Remaining;
  if HRem = Cnt then
    Headers.Reset
  else if HRem > Cnt then
    Headers.Advance(Cnt)
  else
  begin
    Headers.Reset;
    Queue.Advance(Cnt - HRem);
  end;
end;

function TWriteBuf.ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
begin
  { the cursor first (one slice when it has bytes), then the queue }
  Result := 0;
  if (Max > 0) and (Headers.Remaining > 0) then
  begin
    Dst[0].Base := Headers.Chunk;
    Dst[0].Len := SizeUInt(Headers.Remaining);
    Result := 1;
  end;
  Inc(Result, Queue.ChunksVectored(Dst + Result, Max - Result));
end;

{ ---- TH1Io ---- }

procedure TH1Io.Init(AIo: TTransport; APool: PBlockPool);
begin
  FlushPipeline := False;
  Io := AIo;
  PartialLen := -1;
  ReadBlocked := False;
  PendingReads := 0;
  PendingWrites := 0;
  ReadBuf := Default(TReadBuf);                    { no block until the first read }
  ReadBufStrategy.InitDefault;
  WriteBuf.Init;
  Pool := APool;
end;

procedure TH1Io.SetFlushPipeline(Enabled: Boolean);
begin
  Assert(WriteBuf.Remaining = 0, 'SetFlushPipeline: bytes are buffered');
  FlushPipeline := Enabled;
end;

procedure TH1Io.SetMaxBufSize(Max: SizeInt);
begin
  Assert(Max >= MINIMUM_MAX_BUFFER_SIZE, 'The max_buf_size cannot be smaller than 8192.');
  ReadBufStrategy.InitWithMax(SizeUInt(Max));
  WriteBuf.MaxBufSize := Max;
end;

function TH1Io.ReadBufPtr: PByte;
begin
  Result := ReadBuf.Ptr;
end;

function TH1Io.ReadBufLen: SizeInt;
begin
  Result := ReadBuf.Len;
end;

function TH1Io.CanHeadersBuf: Boolean;
begin
  Result := not WriteBuf.Queue.HasRemaining;
end;

function TH1Io.HeadersBuf: PByteVec;
begin
  Result := @WriteBuf.HeadersMut^.Bytes;
end;

procedure TH1Io.Buffer(const B: TQueuedBuf);
begin
  WriteBuf.Buffer(B, Pool);
end;

procedure TH1Io.BufferAfterQueue(var V: TByteVec);
begin
  { the cursor is written before the queue: a head appended to it now would
    land between a queued response's head and its body }
  Assert(WriteBuf.Queue.HasRemaining, 'BufferAfterQueue: nothing queued');
  if V.Len = 0 then
  begin
    ByteVecFree(V);
    Exit;
  end;
  WriteBuf.Queue.Push(QueuedBytes(V), Pool);
end;

function TH1Io.HasBufferedWrite: Boolean;
begin
  Result := WriteBuf.Remaining > 0;
end;

function TH1Io.CanBuffer: Boolean;
begin
  { with FlushPipeline the cursor is not bounded (the responses of a
    pipelined batch accumulate there); the queue still is }
  Result := (FlushPipeline and (WriteBuf.Queue.Count < MAX_BUF_LIST_BUFFERS)) or WriteBuf.CanBuffer;
end;

procedure TH1Io.ConsumeLeadingLines;
var
  I: SizeInt;
  P: PByte;
begin
  if ReadBuf.Len <> 0 then
  begin
    I := 0;
    P := ReadBuf.Ptr;
    while I < ReadBuf.Len do
    begin
      case P[I] of
        13, 10: Inc(I);
      else
        Break;
      end;
    end;
    ReadBuf.Advance(I);
  end;
end;

function TH1Io.Parse(const Ctx: TH1ParseContext; Headers: THttpHeaders; out Msg: TParsedRequestHead;
  out Head: TBytesView; var Err: THyperError): TPollResult;
var
  St: TServerParseStatus;
  CurLen, N: SizeInt;
  Errno: cint;
  R: TIoPoll;
begin
  Head.P := nil;
  Head.Len := 0;
  Head.Block := nil;
  while True do
  begin
    St := ServerParseHeaders(ReadBuf.Ptr, ReadBuf.Len, PartialLen, Ctx, Headers, Msg);
    if St = spsComplete then
    begin
      PartialLen := -1;
      { the head leaves the read buffer; the body and any pipelined
        requests stay }
      Head := ReadBuf.SplitTo(Msg.HeadLen);
      Exit(prOk);
    end;
    if St = spsError then
    begin
      if Msg.HeadSplit then
      begin
        { the error was found after the head was complete (URI or framing
          headers): the head bytes are removed from the buffer and dropped }
        Head := ReadBuf.SplitTo(Msg.HeadLen);
        Head.Release;
      end;
      Err := NewParse(Msg.Error);
      Exit(prErr);
    end;
    { the head is incomplete: check the limits before reading more }
    CurLen := ReadBuf.Len;
    if Ctx.MaxHeaderSize >= 0 then
      if CurLen >= Ctx.MaxHeaderSize then
      begin
        { max_header_size reached: the connection answers 431 and closes }
        Err := NewTooLarge;
        Exit(prErr);
      end;
    if SizeUInt(CurLen) >= ReadBufStrategy.Max then
    begin
      { max_buf_size reached without a complete head }
      Err := NewTooLarge;
      Exit(prErr);
    end;
    if CurLen > 0 then
      { remember how far the end-of-head scan got }
      PartialLen := CurLen
    else
      { empty buffer: the next attempt scans from the start }
      PartialLen := -1;
    R := PollReadFromIo(N, Errno);
    if R = ipPending then
      Exit(prPending);
    if R = ipError then
    begin
      Err := NewIo(Errno);
      Exit(prErr);
    end;
    if N = 0 then
    begin
      { EOF before the head was complete }
      Err := NewIncomplete;
      Exit(prErr);
    end;
  end;
end;

function TH1Io.PollReadFromIo(out N: SizeInt; out Errno: cint): TIoPoll;
var
  Next, Room: SizeUInt;
  Want, R: SizeInt;
begin
  ReadBlocked := False;
  if ReadBufStrategy.Max > SizeUInt(ReadBuf.Len) then
    Room := ReadBufStrategy.Max - SizeUInt(ReadBuf.Len)
  else
    Room := 0;
  Next := ReadBufStrategy.Next;
  if Room < Next then
    Next := Room;
  ReadBuf.Reserve(SizeInt(Next), Pool);
  { the block may have more spare room than requested; never read past
    max_buf_size }
  Want := ReadBuf.SpareCapacity;
  if SizeUInt(Want) > Room then
    Want := SizeInt(Room);
  Assert(Want > 0, 'PollReadFromIo: no room to read into');
  R := Io.Read(ReadBuf.SpareData, Want);
  if R >= 0 then
  begin
    ReadBuf.AdvanceMut(R);
    ReadBufStrategy.Record_(SizeUInt(R));
    N := R;
    Errno := 0;
    Exit(ipReady);
  end;
  N := 0;
  if R = -ESysEAGAIN then
  begin
    ReadBlocked := True;
    Inc(PendingReads);
    Errno := 0;
    Exit(ipPending);
  end;
  Errno := cint(-R);
  Result := ipError;
end;

function TH1Io.IsReadBlocked: Boolean;
begin
  Result := ReadBlocked;
end;

function TH1Io.ReadMem(Len: SizeInt; out View: TBytesView; out Errno: cint): TIoPoll;
var
  N: SizeInt;
begin
  if ReadBuf.Len <> 0 then
  begin
    N := ReadBuf.Len;
    if Len < N then
      N := Len;
    View := ReadBuf.SplitTo(N);
    Errno := 0;
    Exit(ipReady);
  end;
  View.P := nil;
  View.Len := 0;
  View.Block := nil;
  Result := PollReadFromIo(N, Errno);
  if Result <> ipReady then
    Exit;
  if Len < N then
    N := Len;
  View := ReadBuf.SplitTo(N);
end;

function TH1Io.HoldsPipelinedWrite: Boolean;
begin
  Result := FlushPipeline and (ReadBuf.Len <> 0) and (WriteBuf.Queue.Count = 0)
    and (WriteBuf.Remaining > 0);
end;

function TH1Io.PollFlushHeld(out Errno: cint): TIoPoll;
begin
  FlushPipeline := False;
  Result := PollFlush(Errno);
  FlushPipeline := True;
end;

function TH1Io.PollFlush(out Errno: cint): TIoPoll;
begin
  Errno := 0;
  { pipeline_flush: hold the bytes while more requests are buffered, unless
    something is queued: a queued entry keeps CanHeadersBuf false, so the
    next response could not be buffered and nothing would wake the task }
  if FlushPipeline and (ReadBuf.Len <> 0) and (WriteBuf.Queue.Count = 0) then
    Exit(ipReady);
  if WriteBuf.Remaining = 0 then
    { nothing to write (a TCP socket has no flush of its own) }
    Exit(ipReady);
  if WriteBuf.Queue.Count = 0 then
    Exit(PollFlushCursor(Errno));
  Result := PollFlushQueue(Errno);
end;

function TH1Io.PollFlushQueue(out Errno: cint): TIoPoll;
var
  Iovs: array[0..MAX_WRITEV_BUFS - 1] of TIoSlice;
  Cnt: Integer;
  N: SizeInt;
  E: PQueuedBuf;
  Off: Int64;
  Want: SizeInt;
begin
  Errno := 0;
  while True do
  begin
    E := nil;
    if (WriteBuf.Headers.Remaining = 0) and WriteBuf.Queue.HasRemaining then
    begin
      E := WriteBuf.Queue.Front;
      if E^.Kind <> qkFile then
        E := nil;
    end;
    if E <> nil then
    begin
      { the cursor is empty and a file entry is at the front: sendfile(2)
        copies from the file to the socket inside the kernel }
      Off := E^.FileOff;
      if E^.FileLen > SENDFILE_MAX_CHUNK then
        Want := SENDFILE_MAX_CHUNK
      else
        Want := SizeInt(E^.FileLen);
      N := Io.SendFile(E^.FileFd, Off, Want);
    end
    else
    begin
      { the cursor and the memory entries up to the next file entry }
      Cnt := WriteBuf.ChunksVectored(@Iovs[0], MAX_WRITEV_BUFS);
      N := Io.WriteV(@Iovs[0], Cnt);
    end;
    if N < 0 then
    begin
      if N = -ESysEAGAIN then
      begin
        Inc(PendingWrites);
        Exit(ipPending);
      end;
      Errno := cint(-N);
      Exit(ipError);
    end;
    WriteBuf.Advance(N);
    if WriteBuf.Remaining = 0 then
      Break
    else if N = 0 then
    begin
      { the write returned 0 with bytes left: it would never progress }
      Errno := IO_ERRNO_WRITE_ZERO;
      Exit(ipError);
    end;
  end;
  Result := ipReady;
end;

function TH1Io.PollFlushCursor(out Errno: cint): TIoPoll;
var
  N: SizeInt;
begin
  { nothing queued: plain write(2) calls of the cursor }
  Errno := 0;
  while True do
  begin
    N := Io.Write(WriteBuf.Headers.Chunk, WriteBuf.Headers.Remaining);
    if N < 0 then
    begin
      if N = -ESysEAGAIN then
      begin
        Inc(PendingWrites);
        Exit(ipPending);
      end;
      Errno := cint(-N);
      Exit(ipError);
    end;
    WriteBuf.Headers.Advance(N);
    if WriteBuf.Headers.Remaining = 0 then
    begin
      WriteBuf.Headers.Reset;
      Break;
    end
    else if N = 0 then
    begin
      { the write returned 0 with bytes left: it would never progress }
      Errno := IO_ERRNO_WRITE_ZERO;
      Exit(ipError);
    end;
  end;
  Result := ipReady;
end;

function TH1Io.PollShutdown(out Errno: cint): TIoPoll;
var
  R: SizeInt;
begin
  Result := PollFlush(Errno);
  if Result <> ipReady then
    Exit;
  R := Io.ShutdownWrite;
  if R < 0 then
  begin
    if R = -ESysEAGAIN then
    begin
      Inc(PendingWrites);
      Exit(ipPending);
    end;
    Errno := cint(-R);
    Exit(ipError);
  end;
  Result := ipReady;
end;

procedure TH1Io.IntoInner(out AIo: TTransport; out Rest: TBytesView);
begin
  AIo := Io;
  Rest := ReadBuf.Freeze;
  { the write buffer is freed with its queued data }
  WriteBuf.Queue.Done;
  ByteVecFree(WriteBuf.Headers.Bytes);
  WriteBuf.Headers.Pos := 0;
  Io := nil;
end;

procedure TH1Io.ReleaseIdle;
begin
  ReadBuf.ReleaseIdle(Pool);
  if (WriteBuf.Headers.Bytes.Len = 0) and (WriteBuf.Headers.Pos = 0) then
    WriteBuf.Headers.Bytes.ReleaseIdle(Pool);
  WriteBuf.Queue.ReleaseIdle;
end;

procedure TH1Io.Done;
begin
  ReadBuf.Done;
  WriteBuf.Queue.Done;
  ByteVecFree(WriteBuf.Headers.Bytes);
  WriteBuf.Headers.Pos := 0;
end;

end.
