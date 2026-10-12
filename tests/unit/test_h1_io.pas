{ Tests for bearings.http1.io, design m3-transport.md 2.2.2-2.2.4 and 7.2.

  TTestIoRs: the tests of hyper v1.12.0 src/proto/h1/io.rs, adapted to the
  one write path of step T1 (small pieces copied into the cursor, large
  ones queued for writev).
  TTestIoExtra: pipeline_flush, poll_shutdown, partial writev inside
  prefix / data / suffix, WriteZero, qkFile entries over a socketpair, idle
  block release, read sizes from the read strategy, and the parts of
  Buffered that hyper does not test directly (parse errors and limits,
  read_mem, consume_leading_lines, into_inner, queue limits, trailers,
  owner release).
  Run: test_h1_io --all --format=plain }
program test_h1_io;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, BaseUnix, Sockets, fpcunit, testregistry, consoletestrunner,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.http.headers, bearings.http1.encode,
  bearings.http1.role, bearings.http.error, bearings.http1.io, bearings.test.mocktransport;

type
  TTestIoRs = class(TTestCase)
  published
    procedure Test_iobuf_write_empty_slice;
    procedure Parse_reads_until_blocked;
    procedure Read_strategy_adaptive_increments;
    procedure Read_strategy_adaptive_decrements;
    procedure Read_strategy_adaptive_stays_the_same;
    procedure Read_strategy_adaptive_max_fuzz;
    procedure Write_buf_requires_non_empty_bufs;
    procedure Write_buf_small_pieces_copied;
    procedure Cursor_drops_written_prefix_when_full;
    procedure Queued_entries_non_vectored_transport;
    procedure Test_write_buf_queue;
  end;

  TTestIoExtra = class(TTestCase)
  published
    procedure Init_defaults_and_max_buf_size;
    procedure Buffer_copies_small_and_queues_large;
    procedure Pipeline_flush_skips_flush_while_read_buffer_not_empty;
    procedure Poll_shutdown_never_shuts_down_with_bytes_buffered;
    procedure Poll_shutdown_skips_flush_under_pipeline_flush;
    procedure Partial_writev_inside_prefix_data_suffix;
    procedure Partial_write_copied_every_split;
    procedure Partial_write_non_vectored_queue;
    procedure Write_zero_cursor;
    procedure Write_zero_queue;
    procedure Write_error_and_pending;
    procedure File_entry_between_memory_entries;
    procedure File_entry_after_copied_body;
    procedure File_entry_partial_sendfile_and_eagain;
    procedure Idle_release_gives_blocks_back;
    procedure Reads_follow_the_read_strategy;
    procedure Read_uses_the_spare_room;
    procedure Partial_len_cleared_after_complete_parse;
    procedure Parse_error_after_split_removes_head;
    procedure Parse_error_before_split_keeps_bytes;
    procedure Parse_max_buf_size;
    procedure Parse_max_header_size;
    procedure Parse_eof_is_incomplete;
    procedure Parse_read_error_is_io;
    procedure Read_mem;
    procedure Consume_leading_lines;
    procedure Into_inner_returns_leftover;
    procedure Queue_limit_and_can_buffer;
    procedure Trailers_entry_queued_and_copied;
    procedure Owner_released_after_write;
    procedure Parse_max_header_size_boundary;
    procedure Cursor_flush_resets_cursor;
    procedure Pipeline_flush_writes_queued_file;
    procedure Pipeline_flush_writes_queued_large_body;
    procedure Entries_behind_a_queued_entry_are_queued;
    procedure Head_behind_16_queued_entries;
  end;

const
  CRLF = #13#10;

var
  ReleasedCount: Integer = 0;

procedure CountRelease(Ctx: Pointer; Data: PByte);
begin
  Inc(ReleasedCount);
end;

function CountingOwner: TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.Own := boCustom;
  Result.ReleaseProc := @CountRelease;
end;

{ A plain buffer of S's bytes (hyper's Cursor<Vec<u8>> in the io.rs tests):
  a close-delimited encoder writes the data as it is. S must outlive it. }
function MemBuf(const S: RawByteString; const Owner: TBodyData): TQueuedBuf; overload;
var
  E: TEncoder;
  Enc: TEncodedBuf;
begin
  E := TEncoder.CloseDelimited;
  E.Encode(PByte(Pointer(S)), Length(S), Enc);
  Result := QueuedEncoded(Enc, Owner);
end;

function MemBuf(const S: RawByteString): TQueuedBuf; overload;
begin
  Result := MemBuf(S, BodyStatic(Pointer(S), Length(S)));
end;

function ChunkBuf(const S: RawByteString; const Owner: TBodyData): TQueuedBuf;
var
  E: TEncoder;
  Enc: TEncodedBuf;
begin
  E := TEncoder.Chunked;
  E.Encode(PByte(Pointer(S)), Length(S), Enc);
  Result := QueuedEncoded(Enc, Owner);
end;

function ChunkEndBuf(const Owner: TBodyData): TQueuedBuf;
var
  E: TEncoder;
  Enc: TEncodedBuf;
  NotEof: QWord;
begin
  E := TEncoder.Chunked;
  E.Finish(Enc, NotEof);
  Result := QueuedEncoded(Enc, Owner);
end;

function ViewStr(const V: TBytesView): RawByteString;
begin
  SetString(Result, PAnsiChar(V.P), V.Len);
end;

function ReadBufStr(const Io: TH1Io): RawByteString;
begin
  SetString(Result, PAnsiChar(Io.ReadBuf.Ptr), Io.ReadBuf.Len);
end;

function CursorStr(const C: TCursor): RawByteString;
begin
  SetString(Result, PAnsiChar(C.Chunk), C.Remaining);
end;

procedure AppendStr(V: PByteVec; const S: RawByteString; Pool: PBlockPool);
begin
  V^.Append(PByte(Pointer(S)), Length(S), Pool);
end;

{ An entry pushed straight into the queue (TWriteBuf.Buffer would copy a
  small one into the cursor): tests of the writev path. }
procedure QueueDirect(var Io: TH1Io; const B: TQueuedBuf);
begin
  Io.WriteBuf.Queue.Push(B, Io.Pool);
end;

{ more than MAX_COPY_SIZE bytes: TWriteBuf.Buffer queues it }
function BigStr(C: AnsiChar): RawByteString;
begin
  Result := StringOfChar(C, MAX_COPY_SIZE + 1);
end;

{ ================= io.rs tests ================= }

procedure TTestIoRs.Test_iobuf_write_empty_slice;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  { io.rs:662-681 (#[ignore], body commented out). Stated intent: the
    buffered io does not trigger a write when there is nothing to flush. }
  M := TMockTransport.Create;
  try
    Io.Init(M, nil);
    AssertTrue('flush short-circuits', Io.PollFlush(E) = ipReady);
    AssertEquals('no write call', 0, M.WriteCalls);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoRs.Parse_reads_until_blocked;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
begin
  { io.rs:683-726, server form: split over multiple reads, missing the last
    line ending, then the io blocks (tokio_test's wait) }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF).Read('Host: x' + CRLF).ReadPending;
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue('parse is pending', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prPending);
    AssertEquals('read buf', 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF, ReadBufStr(Io));
    AssertEquals('three reads', 3, M.ReadCalls);
    AssertTrue('read blocked', Io.IsReadBlocked);
    M.AssertDone;
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoRs.Read_strategy_adaptive_increments;
var
  S: TReadStrategy;
  Mx: SizeUInt;
begin
  { io.rs:728-752 }
  S.InitDefault;
  AssertEquals(8192, Int64(S.Next));
  { Grows if record == next }
  S.Record_(8192);
  AssertEquals(16384, Int64(S.Next));
  S.Record_(16384);
  AssertEquals(32768, Int64(S.Next));
  { Enormous records still increment at same rate }
  S.Record_(High(SizeUInt));
  AssertEquals(65536, Int64(S.Next));
  Mx := S.Max;
  while S.Next < Mx do
    S.Record_(Mx);
  AssertEquals('never goes over max', Int64(Mx), Int64(S.Next));
  S.Record_(Mx + 1);
  AssertEquals('never goes over max', Int64(Mx), Int64(S.Next));
end;

procedure TTestIoRs.Read_strategy_adaptive_decrements;
var
  S: TReadStrategy;
begin
  { io.rs:754-783 }
  S.InitDefault;
  S.Record_(8192);
  AssertEquals(16384, Int64(S.Next));
  S.Record_(1);
  AssertEquals('first smaller record doesn''t decrement yet', 16384, Int64(S.Next));
  S.Record_(8192);
  AssertEquals('record was with range', 16384, Int64(S.Next));
  S.Record_(1);
  AssertEquals('in-range record should make this the ''first'' again', 16384, Int64(S.Next));
  S.Record_(1);
  AssertEquals('second smaller record decrements', 8192, Int64(S.Next));
  S.Record_(1);
  AssertEquals('first doesn''t decrement', 8192, Int64(S.Next));
  S.Record_(1);
  AssertEquals('doesn''t decrement under minimum', 8192, Int64(S.Next));
end;

procedure TTestIoRs.Read_strategy_adaptive_stays_the_same;
var
  S: TReadStrategy;
begin
  { io.rs:785-804 }
  S.InitDefault;
  S.Record_(8192);
  AssertEquals(16384, Int64(S.Next));
  S.Record_(8193);
  AssertEquals('first smaller record doesn''t decrement yet', 16384, Int64(S.Next));
  S.Record_(8193);
  AssertEquals('with current step does not decrement', 16384, Int64(S.Next));
end;

function IsPowerOfTwo(N: SizeUInt): Boolean;
begin
  Result := (N <> 0) and ((N and (N - 1)) = 0);
end;

procedure Fuzz(Mx: SizeUInt; T: TTestCase; var Checks: Integer);
var
  S: TReadStrategy;
  Next: SizeUInt;
begin
  S.InitWithMax(Mx);
  while S.Next < Mx do
    S.Record_(High(SizeUInt));
  Next := S.Next;
  while Next > 8192 do
  begin
    S.Record_(1);
    S.Record_(1);
    Next := S.Next;
    if not IsPowerOfTwo(Next) then
      T.Fail(Format('decrement should be powers of two: %u (max = %u)', [Next, Mx]));
    Inc(Checks);
  end;
end;

procedure TTestIoRs.Read_strategy_adaptive_max_fuzz;
var
  Mx, Half: SizeUInt;
  Checks, Maxes: Integer;
begin
  { io.rs:806-833 }
  Checks := 0;
  Maxes := 0;
  Mx := 8192;
  while Mx < High(SizeUInt) do
  begin
    Fuzz(Mx, Self, Checks);
    Inc(Maxes);
    { max = (max / 2).saturating_mul(3) }
    Half := Mx div 2;
    if Half > High(SizeUInt) div 3 then
      Mx := High(SizeUInt)
    else
      Mx := Half * 3;
  end;
  Fuzz(High(SizeUInt), Self, Checks);
  AssertEquals('maxes fuzzed below usize::MAX (as Rust: 8192, then (max / 2) * 3)', 88, Maxes);
  AssertTrue('decrements were checked', Checks > 1000);
end;

procedure TTestIoRs.Write_buf_requires_non_empty_bufs;
var
  M: TMockTransport;
  Io: TH1Io;
  Raised: Boolean;
  Q: TQueuedBuf;
begin
  { io.rs:835-843 (#[should_panic], debug_assertions): -Sa build,
    EAssertionFailed, from Buffer and from the queue's Push. }
  M := TMockTransport.Create;
  try
    Io.Init(M, nil);
    Q := QueuedEncoded(Default(TEncodedBuf), BodyEmpty);
    Raised := False;
    try
      Io.Buffer(Q);
    except
      on EAssertionFailed do
        Raised := True;
    end;
    AssertTrue('Buffer: empty buffer asserts', Raised);
    Raised := False;
    try
      QueueDirect(Io, Q);
    except
      on EAssertionFailed do
        Raised := True;
    end;
    AssertTrue('Push: empty buffer asserts', Raised);
    AssertEquals('nothing queued', 0, Io.WriteBuf.Queue.Count);
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoRs.Write_buf_small_pieces_copied;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  { io.rs:868-885 write_buf_flatten: small pieces go into the cursor, one write }
  M := TMockTransport.Create;
  try
    M.Vectored(True).Write('hello world, it''s hyper!');
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'hello ', nil);
    Io.Buffer(MemBuf('world, '));
    Io.Buffer(MemBuf('it''s '));
    Io.Buffer(MemBuf('hyper!'));
    AssertEquals('queue empty', 0, Io.WriteBuf.Queue.Count);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('one write', 1, M.WriteCalls);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoRs.Cursor_drops_written_prefix_when_full;
var
  Pool: TBlockPool;
  WB: TWriteBuf;
  Fill: RawByteString;
begin
  { io.rs:887-920 write_buf_flatten_partially_flushed: a partly written
    cursor keeps its prefix while the block has room, and drops it (moving
    the rest to the start) when the next piece does not fit }
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  WB.Init;
  WB.Buffer(MemBuf('hello '), @Pool);
  WB.Buffer(MemBuf('world, '), @Pool);
  AssertEquals('hello world, ', CursorStr(WB.Headers));
  { advance most of the way, but not all }
  WB.Advance(11);
  AssertEquals(', ', CursorStr(WB.Headers));
  AssertEquals('pos', 11, WB.Headers.Pos);
  { there's still room in the block, so just push on the end }
  WB.Buffer(MemBuf('it''s hyper!'), @Pool);
  AssertEquals(', it''s hyper!', CursorStr(WB.Headers));
  AssertEquals('pos', 11, WB.Headers.Pos);
  { fill the block to 100 bytes short of its end, then write 4000 more }
  Fill := StringOfChar('F', WB.Headers.Bytes.Cap - WB.Headers.Bytes.Len - 100);
  WB.Headers.Bytes.Append(PByte(Pointer(Fill)), Length(Fill), @Pool);
  WB.Advance(4000);
  AssertEquals('pos', 4011, WB.Headers.Pos);
  { 200 bytes do not fit at the end: the written prefix is dropped, no growth }
  WB.Buffer(MemBuf(StringOfChar('X', 200)), @Pool);
  AssertEquals('pos', 0, WB.Headers.Pos);
  AssertEquals('same block size', 8192, WB.Headers.Bytes.Cap);
  AssertEquals('bytes after the drop', Copy(', it''s hyper!' + Fill, 4001, MaxInt) +
    StringOfChar('X', 200), CursorStr(WB.Headers));
  BlockFree(WB.Headers.Bytes.Block);
  Pool.Done;
end;

procedure TTestIoRs.Queued_entries_non_vectored_transport;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  A, B, C: RawByteString;
begin
  { io.rs:922-949 write_buf_queue_disable_auto: queued entries over a
    transport without writev (the default WriteV writes the first slice) }
  A := BigStr('a');
  B := BigStr('b');
  C := BigStr('c');
  M := TMockTransport.Create;
  try
    M.Write('hello ').Write(A).Write(B).Write(C);
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'hello ', nil);
    Io.Buffer(MemBuf(A));
    Io.Buffer(MemBuf(B));
    Io.Buffer(MemBuf(C));
    AssertEquals('three queued', 3, Io.WriteBuf.Queue.Count);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('queue empty', 0, Io.WriteBuf.Queue.Count);
    AssertEquals('four writes', 4, M.WriteCalls);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoRs.Test_write_buf_queue;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  A, B, C: RawByteString;
begin
  { io.rs:845-866 (commented out: needs a writev-capable mock): the cursor
    and the queued entries in one writev }
  A := BigStr('a');
  B := BigStr('b');
  C := BigStr('c');
  M := TMockTransport.Create;
  try
    M.Vectored(True).Write('hello ' + A + B + C);
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'hello ', nil);
    Io.Buffer(MemBuf(A));
    Io.Buffer(MemBuf(B));
    Io.Buffer(MemBuf(C));
    AssertEquals('three queued', 3, Io.WriteBuf.Queue.Count);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('written', 'hello ' + A + B + C, M.Written);
    AssertEquals('one writev call', 1, Length(M.IovCounts));
    AssertEquals('of 4 slices', 4, M.IovCounts[0]);
    AssertEquals('queue empty', 0, Io.WriteBuf.Queue.Count);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

{ ================= extra tests ================= }

procedure TTestIoExtra.Init_defaults_and_max_buf_size;
var
  M: TMockTransport;
  Io: TH1Io;
begin
  M := TMockTransport.Create;
  try
    Io.Init(M, nil);
    AssertEquals('max buf size', DEFAULT_MAX_BUFFER_SIZE, Io.WriteBuf.MaxBufSize);
    AssertEquals('strategy max', DEFAULT_MAX_BUFFER_SIZE, Int64(Io.ReadBufStrategy.Max));
    AssertTrue('no memory before the first write', Io.WriteBuf.Headers.Bytes.Block = nil);
    AssertTrue('no memory before the first read', Io.ReadBuf.Block = nil);
    AssertEquals('partial_len None', -1, Io.PartialLen);
    Io.SetFlushPipeline(True);
    AssertTrue(Io.FlushPipeline);
    Io.SetMaxBufSize(MINIMUM_MAX_BUFFER_SIZE);
    AssertEquals(MINIMUM_MAX_BUFFER_SIZE, Int64(Io.ReadBufStrategy.Max));
    AssertEquals(MINIMUM_MAX_BUFFER_SIZE, Io.WriteBuf.MaxBufSize);
    try
      Io.SetMaxBufSize(MINIMUM_MAX_BUFFER_SIZE - 1);
      Fail('max_buf_size below the minimum must assert');
    except
      on EAssertionFailed do ;
    end;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Buffer_copies_small_and_queues_large;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  Big, Exact: RawByteString;
begin
  ReleasedCount := 0;
  Big := BigStr('L');
  Exact := StringOfChar('e', MAX_COPY_SIZE);
  M := TMockTransport.Create;
  try
    M.Vectored(True).Write('H' + Exact + 's' + Big + 't');
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'H', nil);
    Io.Buffer(MemBuf(Exact, CountingOwner));
    Io.Buffer(MemBuf('s', CountingOwner));
    AssertEquals('MAX_COPY_SIZE bytes and less: copied', 0, Io.WriteBuf.Queue.Count);
    AssertEquals('copied data released at once', 2, ReleasedCount);
    Io.Buffer(MemBuf(Big, CountingOwner));
    AssertEquals('more: queued', 1, Io.WriteBuf.Queue.Count);
    AssertEquals('queued data kept', 2, ReleasedCount);
    Io.Buffer(MemBuf('t', CountingOwner));
    AssertEquals('small behind a queued entry: queued', 2, Io.WriteBuf.Queue.Count);
    AssertEquals('cursor', 'H' + Exact + 's', CursorStr(Io.WriteBuf.Headers));
    AssertFalse('no head while entries are queued', Io.CanHeadersBuf);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('bytes in order', 'H' + Exact + 's' + Big + 't', M.Written);
    AssertEquals('all released', 4, ReleasedCount);
    AssertTrue(Io.CanHeadersBuf);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Pipeline_flush_skips_flush_while_read_buffer_not_empty;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  E: cint;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET /a HTTP/1.1' + CRLF + CRLF + 'GET /b HTTP/1.1' + CRLF + CRLF).Write('RESP1RESP2');
    Io.Init(M, nil);
    Io.SetFlushPipeline(True);
    Err := Default(THyperError);
    AssertTrue('first request', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    Head.Release;
    AppendStr(Io.HeadersBuf, 'RESP1', nil);
    AssertTrue('flush is Ready', Io.PollFlush(E) = ipReady);
    AssertEquals('io.rs:279: no write while the read buffer holds bytes', 0, M.WriteCalls);
    AssertTrue('still buffered', Io.HasBufferedWrite);
    AssertTrue('can_buffer is always true with pipeline_flush', Io.CanBuffer);
    AssertTrue('second request', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    Head.Release;
    AssertEquals('read buffer empty', 0, Io.ReadBufLen);
    AppendStr(Io.HeadersBuf, 'RESP2', nil);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('both responses in one write', 1, M.WriteCalls);
    AssertFalse(Io.HasBufferedWrite);
    M.AssertDone;
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Poll_shutdown_never_shuts_down_with_bytes_buffered;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  V: Boolean;
begin
  for V := False to True do
  begin
    M := TMockTransport.Create;
    try
      M.Vectored(V).WriteLimit(3).Write('abc').WritePending.Write('defgh').WriteError(ESysEPIPE);
      Io.Init(M, nil);
      AppendStr(Io.HeadersBuf, 'abc', nil);
      Io.Buffer(MemBuf('defgh'));
      AssertTrue('partial write, then pending', Io.PollShutdown(E) = ipPending);
      AssertEquals('no shutdown while pending', 0, M.ShutdownCalls);
      AssertEquals('5 bytes left', 5, Io.WriteBuf.Remaining);
      AssertTrue('rest written', Io.PollShutdown(E) = ipReady);
      AssertEquals('shutdown after the flush', 1, M.ShutdownCalls);
      AppendStr(Io.HeadersBuf, 'x', nil);
      AssertTrue('write error', Io.PollShutdown(E) = ipError);
      AssertEquals('errno', ESysEPIPE, E);
      AssertEquals('no shutdown after a write error', 1, M.ShutdownCalls);
      M.AssertDone;
      Io.Done;
    finally
      M.Free;
    end;
  end;
end;

procedure TTestIoExtra.Poll_shutdown_skips_flush_under_pipeline_flush;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  N: SizeInt;
begin
  { io.rs:337-340 + 279-280: with pipeline_flush and unread bytes the
    flush returns Ready without writing, so poll_shutdown shuts down with
    the response still buffered (a hyper quirk kept on purpose, R5) }
  M := TMockTransport.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF);
    Io.Init(M, nil);
    Io.SetFlushPipeline(True);
    AssertTrue(Io.PollReadFromIo(N, E) = ipReady);
    AppendStr(Io.HeadersBuf, 'RESPONSE', nil);
    AssertTrue('shutdown Ready', Io.PollShutdown(E) = ipReady);
    AssertEquals('shut down', 1, M.ShutdownCalls);
    AssertEquals('nothing written', 0, M.WriteCalls);
    AssertTrue('response still buffered', Io.HasBufferedWrite);
    Io.Done;
  finally
    M.Free;
  end;
end;

{ Cursor "HTTP/1.1 200 OK\r\n\r\n" (19), chunk "5\r\n" "hello" "\r\n" (10),
  end "0\r\n\r\n" (5): 34 bytes. For every split point the first write
  accepts N bytes, the next write is Pending, then everything else goes. }
{ Copied: the entries go through Buffer (small: copied into the cursor);
  otherwise they are pushed into the queue. }
procedure RunPartialSplits(T: TTestCase; Vectored, Copied: Boolean);
const
  HEADS = 'HTTP/1.1 200 OK' + #13#10#13#10;
  BODY = 'hello';
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  All: RawByteString;
  N: Integer;
begin
  All := HEADS + '5'#13#10'hello'#13#10'0'#13#10#13#10;
  T.AssertEquals(34, Length(All));
  for N := 1 to Length(All) - 1 do
  begin
    ReleasedCount := 0;
    M := TMockTransport.Create;
    try
      M.Vectored(Vectored).WriteLimit(N).Write(Copy(All, 1, N)).WritePending
        .Write(Copy(All, N + 1, MaxInt));
      Io.Init(M, nil);
      AppendStr(Io.HeadersBuf, HEADS, nil);
      if Copied then
      begin
        Io.Buffer(ChunkBuf(BODY, CountingOwner));
        Io.Buffer(ChunkEndBuf(CountingOwner));
      end
      else
      begin
        QueueDirect(Io, ChunkBuf(BODY, CountingOwner));
        QueueDirect(Io, ChunkEndBuf(CountingOwner));
      end;
      if Copied then
        T.AssertEquals('copied: released at once', 2, ReleasedCount)
      else
        T.AssertEquals('queued: not released yet', 0, ReleasedCount);
      if Vectored or Copied then
      begin
        { one write of N bytes, then Pending }
        T.AssertTrue(Format('split %d: pending', [N]), Io.PollFlush(E) = ipPending);
        T.AssertEquals(Format('split %d: remaining', [N]), Length(All) - N, Io.WriteBuf.Remaining);
        if not Copied then
        begin
          { io.rs:631: a write that ends exactly at (or past) the end of
            the head cursor clears it }
          if N >= 19 then
          begin
            T.AssertEquals(Format('split %d: cursor cleared', [N]), 0, Io.WriteBuf.Headers.Bytes.Len);
            T.AssertEquals(Format('split %d: cursor pos', [N]), 0, Io.WriteBuf.Headers.Pos);
          end
          else
            T.AssertEquals(Format('split %d: cursor pos', [N]), N, Io.WriteBuf.Headers.Pos);
          { the chunk entry ends at byte 29 }
          if N >= 29 then
            T.AssertEquals(Format('split %d: chunk released', [N]), 1, ReleasedCount)
          else
            T.AssertEquals(Format('split %d: chunk kept', [N]), 0, ReleasedCount);
        end;
      end
      else
      begin
        { non-vectored queue: one slice per write; the flush stops at the
          Pending write wherever that falls }
        while Io.PollFlush(E) = ipPending do ;
      end;
      T.AssertTrue(Format('split %d: flushed', [N]), Io.PollFlush(E) = ipReady);
      T.AssertEquals(Format('split %d: bytes', [N]), All, M.Written);
      T.AssertEquals(Format('split %d: all released', [N]), 2, ReleasedCount);
      T.AssertEquals(Format('split %d: queue empty', [N]), 0, Io.WriteBuf.Queue.Count);
      M.AssertDone;
      Io.Done;
    finally
      M.Free;
    end;
  end;
end;

procedure TTestIoExtra.Partial_writev_inside_prefix_data_suffix;
var
  M: TMockTransport;
  Io: TH1Io;
  Iov: array[0..MAX_WRITEV_BUFS - 1] of TIoSlice;
  E: cint;
begin
  RunPartialSplits(Self, True, False);
  { the slices after a split inside the prefix / data / suffix }
  M := TMockTransport.Create;
  try
    M.Vectored(True);
    Io.Init(M, nil);
    QueueDirect(Io, ChunkBuf('hello', BodyEmpty));
    AssertEquals('prefix, data, suffix', 3, Io.WriteBuf.ChunksVectored(@Iov[0], MAX_WRITEV_BUFS));
    Io.WriteBuf.Advance(1);   { inside "5\r\n" }
    AssertEquals(3, Io.WriteBuf.ChunksVectored(@Iov[0], MAX_WRITEV_BUFS));
    AssertEquals('rest of the prefix', 2, Iov[0].Len);
    Io.WriteBuf.Advance(4);   { inside "hello" }
    AssertEquals(2, Io.WriteBuf.ChunksVectored(@Iov[0], MAX_WRITEV_BUFS));
    AssertEquals('rest of the data', 3, Iov[0].Len);
    Io.WriteBuf.Advance(4);   { inside "\r\n" }
    AssertEquals(1, Io.WriteBuf.ChunksVectored(@Iov[0], MAX_WRITEV_BUFS));
    AssertEquals('rest of the suffix', 1, Iov[0].Len);
    AssertEquals(1, Io.WriteBuf.Remaining);
    AssertEquals('max slices respected', 0, Io.WriteBuf.ChunksVectored(@Iov[0], 0));
    Io.WriteBuf.Advance(1);
    AssertEquals('entry popped', 0, Io.WriteBuf.Queue.Count);
    AssertTrue(Io.PollFlush(E) = ipReady);
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Partial_write_copied_every_split;
begin
  RunPartialSplits(Self, False, True);
end;

procedure TTestIoExtra.Partial_write_non_vectored_queue;
begin
  RunPartialSplits(Self, False, False);
end;

procedure TTestIoExtra.Write_zero_cursor;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  M := TMockTransport.Create;
  try
    M.WriteLimit(0);
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'abc', nil);
    AssertTrue('error', Io.PollFlush(E) = ipError);
    AssertEquals('WriteZero', IO_ERRNO_WRITE_ZERO, E);
    AssertEquals('bytes kept', 3, Io.WriteBuf.Remaining);
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Write_zero_queue;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  M := TMockTransport.Create;
  try
    M.Vectored(True).WriteLimit(2).Write('ab').WriteLimit(0);
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'abc', nil);
    QueueDirect(Io, MemBuf('def'));
    AssertTrue('error', Io.PollFlush(E) = ipError);
    AssertEquals('WriteZero after progress', IO_ERRNO_WRITE_ZERO, E);
    AssertEquals('bytes kept', 4, Io.WriteBuf.Remaining);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Write_error_and_pending;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  M := TMockTransport.Create;
  try
    M.Vectored(True).WritePending.WriteError(ESysECONNRESET);
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'abc', nil);
    QueueDirect(Io, MemBuf('def'));
    AssertTrue('pending', Io.PollFlush(E) = ipPending);
    AssertTrue('error', Io.PollFlush(E) = ipError);
    AssertEquals('errno', ESysECONNRESET, E);
    AssertEquals('bytes kept', 6, Io.WriteBuf.Remaining);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

{ ---- file entries over a socketpair (real TTcpTransport) ---- }

function MakeTempFile(const Content: RawByteString): cint;
var
  Name: string;
begin
  Name := GetTempFileName(GetTempDir(False), 'beio');
  Result := FpOpen(Name, O_RDWR or O_CREAT or O_TRUNC, &600);
  if Result < 0 then
    raise Exception.Create('temp file');
  FpUnlink(Name);
  if Length(Content) > 0 then
    if FpWrite(Result, Content[1], Length(Content)) <> Length(Content) then
      raise Exception.Create('temp file write');
end;

function PatternBytes(N: Integer; Seed: Integer): RawByteString;
var
  I: Integer;
begin
  SetLength(Result, N);
  for I := 1 to N do
    Result[I] := AnsiChar(Ord('a') + ((I * 7 + Seed) mod 26));
end;

function DrainSocket(Fd: cint): RawByteString;
var
  Buf: array[0..65535] of Byte;
  N: SizeInt;
  S: RawByteString;
begin
  Result := '';
  repeat
    N := SysRead(Fd, @Buf[0], SizeOf(Buf));
    if N > 0 then
    begin
      SetString(S, PAnsiChar(@Buf[0]), N);
      Result := Result + S;
    end;
  until N <= 0;
end;

function FdIsOpen(Fd: cint): Boolean;
begin
  Result := FpFcntl(Fd, F_GETFD) >= 0;
end;

procedure MakePair(out Sv: array of cint);
var
  P: array[0..1] of cint;
begin
  if fpsocketpair(AF_UNIX, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0, @P[0]) <> 0 then
    raise Exception.Create('socketpair failed');
  Sv[0] := P[0];
  Sv[1] := P[1];
end;

procedure TTestIoExtra.File_entry_between_memory_entries;
var
  Sv: array[0..1] of cint;
  Src: TIoSource;
  T: TTcpTransport;
  Io: TH1Io;
  Fd: cint;
  Content, A, B, Got: RawByteString;
  E: cint;
  Pool: TBlockPool;
begin
  Content := PatternBytes(20000, 3);
  A := StringOfChar('A', 100);
  B := StringOfChar('B', 50);
  MakePair(Sv);
  Fd := MakeTempFile(Content);
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  Src := Default(TIoSource);
  Src.Fd := Sv[0];
  Src.Ready := [rdRead, rdWrite];
  T := NewTcpTransport(@Src);
  try
    Io.Init(T, @Pool);
    AppendStr(Io.HeadersBuf, 'HEAD' + CRLF, @Pool);
    Io.Buffer(MemBuf(A));
    Io.Buffer(QueuedFile(Fd, 10, 5000, BodyFile(Fd, 10, 5000, True)));
    Io.Buffer(MemBuf(B));
    AssertEquals('remaining counts the file', 6 + 100 + 5000 + 50, Io.WriteBuf.Remaining);
    AssertFalse('no head while entries are queued', Io.CanHeadersBuf);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    Got := DrainSocket(Sv[1]);
    AssertEquals('bytes in order', 'HEAD' + CRLF + A + Copy(Content, 11, 5000) + B, Got);
    AssertEquals('queue empty', 0, Io.WriteBuf.Queue.Count);
    AssertFalse('the file was closed after its last byte', FdIsOpen(Fd));
    Io.ReleaseIdle;
    AssertTrue('queue array back', Io.WriteBuf.Queue.Items = nil);
    Io.Done;
  finally
    T.Free;
    SysClose(Sv[0]);
    SysClose(Sv[1]);
    Pool.Done;
  end;
end;

procedure TTestIoExtra.File_entry_after_copied_body;
var
  Sv: array[0..1] of cint;
  Src: TIoSource;
  T: TTcpTransport;
  Io: TH1Io;
  Fd: cint;
  Content, Got: RawByteString;
  E: cint;
begin
  Content := PatternBytes(3000, 5);
  MakePair(Sv);
  Fd := MakeTempFile(Content);
  Src := Default(TIoSource);
  Src.Fd := Sv[0];
  Src.Ready := [rdRead, rdWrite];
  T := NewTcpTransport(@Src);
  try
    Io.Init(T, nil);
    Io.SetFlushPipeline(True);
    AppendStr(Io.HeadersBuf, 'HTTP/1.1 200 OK' + CRLF + CRLF, nil);
    Io.Buffer(MemBuf('pre'));
    Io.Buffer(QueuedFile(Fd, 0, 3000, BodyFile(Fd, 0, 3000, False)));
    AssertEquals('only the file is queued', 1, Io.WriteBuf.Queue.Count);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    Got := DrainSocket(Sv[1]);
    AssertEquals('bytes', 'HTTP/1.1 200 OK' + CRLF + CRLF + 'pre' + Content, Got);
    AssertTrue('CloseAfter False keeps the file open', FdIsOpen(Fd));
    Io.Done;
  finally
    FpClose(Fd);
    T.Free;
    SysClose(Sv[0]);
    SysClose(Sv[1]);
  end;
end;

procedure TTestIoExtra.File_entry_partial_sendfile_and_eagain;
var
  Sv: array[0..1] of cint;
  Src: TIoSource;
  T: TTcpTransport;
  Io: TH1Io;
  Fd: cint;
  Content, Got, Tail: RawByteString;
  E: cint;
  R: TIoPoll;
  Pendings, Bufsz: Integer;
begin
  Content := PatternBytes(1 shl 20, 11);
  Tail := 'TAIL';
  MakePair(Sv);
  Bufsz := 4096;
  fpsetsockopt(Sv[0], SOL_SOCKET, SO_SNDBUF, @Bufsz, SizeOf(Bufsz));
  Fd := MakeTempFile(Content);
  Src := Default(TIoSource);
  Src.Fd := Sv[0];
  Src.Ready := [rdRead, rdWrite];
  T := NewTcpTransport(@Src);
  try
    Io.Init(T, nil);
    AppendStr(Io.HeadersBuf, 'H' + CRLF, nil);
    Io.Buffer(QueuedFile(Fd, 0, Length(Content), BodyFile(Fd, 0, Length(Content), True)));
    Io.Buffer(MemBuf(Tail));
    Got := '';
    Pendings := 0;
    repeat
      R := Io.PollFlush(E);
      AssertTrue('no error', R <> ipError);
      if R = ipPending then
      begin
        Inc(Pendings);
        AssertFalse('EAGAIN cleared rdWrite', rdWrite in Src.Ready);
        Got := Got + DrainSocket(Sv[1]);
        Src.Ready := Src.Ready + [rdWrite];   { the next EPOLLOUT edge }
      end;
    until R = ipReady;
    Got := Got + DrainSocket(Sv[1]);
    AssertTrue('sendfile hit EAGAIN at least once', Pendings > 0);
    AssertEquals('length', 3 + Length(Content) + 4, Length(Got));
    AssertTrue('bytes', Got = 'H' + CRLF + Content + Tail);
    AssertFalse('file closed', FdIsOpen(Fd));
    Io.Done;
  finally
    T.Free;
    SysClose(Sv[0]);
    SysClose(Sv[1]);
  end;
end;

{ ---- read sizes ---- }

{ A request head and a body read with read_mem, views released at once.
  With Release the idle blocks go back to the pool whenever the read
  buffer is empty. Returns the body; Releases counts the releases. }
function RunReads(Release: Boolean; Pool: PBlockPool; out Releases: Integer;
  out Expected: RawByteString): RawByteString;
const
  HEADS = 'POST / HTTP/1.1' + #13#10 + 'Content-Length: 300000' + #13#10#13#10;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  View, Head: TBytesView;
  Err: THyperError;
  E: cint;
  I: Integer;
  Sizes: array[0..8] of Integer = (100, 20000, 8192, 50000, 5, 16384, 70000, 1, 135318);
  Part: RawByteString;
begin
  Releases := 0;
  Expected := '';
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read(HEADS);
    for I := 0 to High(Sizes) do
    begin
      Part := PatternBytes(Sizes[I], I);
      M.Read(Part);
      Expected := Expected + Part;
    end;
    Io.Init(M, Pool);
    Err := Default(THyperError);
    if Io.Parse(DefaultParseContext, H, Msg, Head, Err) <> prOk then
      raise Exception.Create('parse');
    Head.Release;
    Result := '';
    while Length(Result) < Length(Expected) do
    begin
      if Release and (Io.ReadBuf.Len = 0) then
      begin
        Io.ReleaseIdle;
        if Io.ReadBuf.Block = nil then
          Inc(Releases);
      end;
      if Io.ReadMem(1 shl 30, View, E) <> ipReady then
        raise Exception.Create('read_mem');
      Result := Result + ViewStr(View);
      View.Release;
    end;
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Idle_release_gives_blocks_back;
var
  A, B, Want: RawByteString;
  Ra, Rb: Integer;
  Pool: TBlockPool;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  try
    A := RunReads(False, @Pool, Ra, Want);
    AssertTrue('body without releases', A = Want);
    B := RunReads(True, @Pool, Rb, Want);
    AssertTrue('body with releases', B = Want);
    AssertTrue('blocks were released while idle', Rb >= 5);
    AssertEquals('no block outstanding', Pool.Allocated - Pool.Released,
      Pool.Counts[0] + Pool.Counts[1] + Pool.Counts[2] + Pool.Counts[3] + Pool.Counts[4] +
      Pool.Counts[5] + Pool.Counts[6] + Pool.Counts[7]);
  finally
    Pool.Done;
  end;
end;

procedure TTestIoExtra.Reads_follow_the_read_strategy;
var
  M: TMockTransport;
  Io: TH1Io;
  View: TBytesView;
  E: cint;
  I: Integer;
begin
  { the adaptive strategy (io.rs:408-440) doubles next after a full read;
    the buffer takes a block of the class >= next }
  M := TMockTransport.Create;
  try
    M.Read(PatternBytes(200000, 1));
    Io.Init(M, nil);
    for I := 1 to 3 do
    begin
      AssertTrue(Io.ReadMem(1 shl 30, View, E) = ipReady);
      View.Release;
    end;
    AssertEquals(3, Length(M.ReadLens));
    AssertEquals('first read: 8192', 8192, M.ReadLens[0]);
    AssertEquals('second read', 16384, M.ReadLens[1]);
    AssertEquals('third read', 32768, M.ReadLens[2]);
    AssertEquals('block', 32768, Io.ReadBuf.Block^.Size);
    AssertEquals('strategy next', 65536, Int64(Io.ReadBufStrategy.Next));
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Read_uses_the_spare_room;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Part: RawByteString;
  Pool: TBlockPool;
begin
  { a partial head of 8000 bytes: next stays 8192; spare 192 < 8192, so the
    buffer moves to a 16 KiB block and the next read gets all 8384 bytes of
    spare room. Then 16384 bytes held: next 16384, a 32 KiB block (read
    16384); then 28000 held: a 64 KiB block, read 37536. }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    Part := 'GET / HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 8000 - 19);
    M.Read(Part).ReadPending.Read(StringOfChar('b', 20000)).ReadPending;
    Pool.Init(POOL_DEFAULT_MAX_BYTES);
    Io.Init(M, @Pool);
    Err := Default(THyperError);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prPending);
    AssertEquals(8192, M.ReadLens[0]);
    AssertEquals('strategy unchanged', 8192, Int64(Io.ReadBufStrategy.Next));
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prPending);
    AssertEquals('the pending read had all the spare room', 16384 - 8000, M.ReadLens[1]);
    AssertEquals('second read: all the spare room', 16384 - 8000, M.ReadLens[2]);
    AssertEquals('third read', 16384, M.ReadLens[3]);
    AssertEquals('fourth read', 65536 - 28000, M.ReadLens[4]);
    AssertEquals('capacity', 65536, Io.ReadBuf.Cap);
    Io.Done;
    Pool.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Partial_len_cleared_after_complete_parse;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Req1, Req2: RawByteString;
begin
  { io.rs:201: partial_len = None after a parsed message. A stale
    partial_len would make is_complete_fast start past the end of a short
    pipelined request and wait for bytes that never come. }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    Req1 := 'GET /first HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 100) + CRLF + CRLF;
    Req2 := 'GET / HTTP/1.1' + CRLF + CRLF;
    M.Read(Copy(Req1, 1, 110)).ReadPending.Read(Copy(Req1, 111, MaxInt) + Req2).ReadPending;
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prPending);
    AssertEquals('partial_len', 110, Io.PartialLen);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    AssertEquals('partial_len None', -1, Io.PartialLen);
    Head.Release;
    AssertTrue('second request from the buffer', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    AssertEquals('target', '/', Copy(ViewStr(Head), Msg.Target.Off + 1, Msg.Target.Len));
    Head.Release;
    AssertEquals('no extra read', 3, M.ReadCalls);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

{ ---- parse ---- }

procedure TTestIoExtra.Parse_error_after_split_removes_head;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Req: RawByteString;
  I: Integer;
const
  CASES: array[0..3] of RawByteString = (
    'GET / HTTP/1.1' + #13#10 + 'Content-Length: abc' + #13#10#13#10 + 'XYZ',
    'GET / HTTP/1.1' + #13#10 + 'Transfer-Encoding: gzip' + #13#10#13#10 + 'XYZ',
    'GET / HTTP/1.0' + #13#10 + 'Transfer-Encoding: chunked' + #13#10#13#10 + 'XYZ',
    'GET http://a:b:c/ HTTP/1.1' + #13#10#13#10 + 'XYZ');
  ERRS: array[0..3] of TH1ParseError = (h1peHeaderContentLengthInvalid,
    h1peHeaderTransferEncodingInvalid, h1peHeaderTransferEncodingUnexpected, h1peUri);
begin
  for I := 0 to High(CASES) do
  begin
    M := TMockTransport.Create;
    H := THttpHeaders.Create;
    try
      Req := CASES[I];
      M.Read(Req);
      Io.Init(M, nil);
      Err := Default(THyperError);
      AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
      AssertTrue('kind parse', Err.Kind = hekParse);
      AssertTrue(Format('case %d: parse error', [I]), Err.Parse = ERRS[I]);
      AssertEquals(Format('case %d: role.rs:225 split the head off', [I]), 'XYZ', ReadBufStr(Io));
      AssertTrue('no view handed out', Head.Block = nil);
      AssertEquals('head view released', 0, Io.ReadBuf.Block^.Pins);
      Io.Done;
    finally
      H.Free;
      M.Free;
    end;
  end;
end;

procedure TTestIoExtra.Parse_error_before_split_keeps_bytes;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Ctx: TH1ParseContext;
  Req: RawByteString;
begin
  { errors raised before role.rs:225: method/version tokens, too many
    headers, max_header_size on a complete head, URI too long }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    Req := 'GET / HTTP/1.1' + CRLF + 'Host: example' + CRLF + CRLF;
    M.Read(Req);
    Io.Init(M, nil);
    Ctx := DefaultParseContext;
    Ctx.MaxHeaderSize := 20;
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(Ctx, H, Msg, Head, Err) = prErr);
    AssertTrue('too large', (Err.Kind = hekParse) and (Err.Parse = h1peTooLarge));
    AssertEquals('bytes kept', Req, ReadBufStr(Io));
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    Req := 'G@T / HTTP/1.1' + CRLF + CRLF;
    M.Read(Req);
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
    AssertTrue('method', (Err.Kind = hekParse) and (Err.Parse = h1peMethod));
    AssertEquals('bytes kept', Req, ReadBufStr(Io));
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Parse_max_buf_size;
var
  M: TMockTransport;
  Total, I: SizeInt;
  Pool: TBlockPool;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 10000));
    Io.Init(M, nil);
    Io.SetMaxBufSize(8192);
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
    AssertTrue('too large', (Err.Kind = hekParse) and (Err.Parse = h1peTooLarge));
    AssertEquals('one read of exactly 8192', 1, Length(M.ReadLens));
    AssertEquals(8192, M.ReadLens[0]);
    AssertEquals('buffer full', 8192, Io.ReadBufLen);
    AssertEquals('rest left in the socket', 1, M.Remaining);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
  { just below the limit: another read happens }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 8000)).ReadPending;
    Io.Init(M, nil);
    Io.SetMaxBufSize(8192);
    AssertTrue('pending', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prPending);
    AssertEquals('partial_len', 16 + 3 + 8000, Io.PartialLen);
    AssertEquals('second read limited by max - len', 2, Length(M.ReadLens));
    AssertEquals(8192 - (16 + 3 + 8000), M.ReadLens[1]);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
  { pooled, max not a block size: the 16 KiB block has more spare room than
    max - len, the read is still clamped, so a head that does not fit is
    always 431 (DV-15) }
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 20000));
    Pool.Init(POOL_DEFAULT_MAX_BYTES);
    Io.Init(M, @Pool);
    Io.SetMaxBufSize(10000);
    AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
    AssertTrue('too large', (Err.Kind = hekParse) and (Err.Parse = h1peTooLarge));
    AssertEquals('buffer stops at max', 10000, Io.ReadBufLen);
    Total := 0;
    for I := 0 to High(M.ReadLens) do
      Inc(Total, M.ReadLens[I]);
    AssertEquals('reads ask for no more than max in total', 10000, Total);
    Io.Done;
    Pool.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Parse_max_header_size;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Ctx: TH1ParseContext;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF + 'X: ' + StringOfChar('a', 200));
    Io.Init(M, nil);
    Ctx := DefaultParseContext;
    Ctx.MaxHeaderSize := 100;
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(Ctx, H, Msg, Head, Err) = prErr);
    AssertTrue('too large', (Err.Kind = hekParse) and (Err.Parse = h1peTooLarge));
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Parse_eof_is_incomplete;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF);
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
    AssertTrue('incomplete', Err.Kind = hekIncompleteMessage);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Parse_read_error_is_io;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.ReadError(ESysECONNRESET);
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue('error', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prErr);
    AssertTrue('io', (Err.Kind = hekIo) and (Err.Cause = ecErrno));
    AssertEquals('errno', ESysECONNRESET, Err.Errno);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Read_mem;
var
  M: TMockTransport;
  Io: TH1Io;
  V: TBytesView;
  E: cint;
  N: SizeInt;
begin
  M := TMockTransport.Create;
  try
    M.Read('abcdef').ReadPending.Read('gh');
    Io.Init(M, nil);
    AssertTrue(Io.ReadMem(4, V, E) = ipReady);
    AssertEquals('first part', 'abcd', ViewStr(V));
    AssertEquals('pinned', 1, V.Block^.Pins);
    V.Release;
    AssertTrue(Io.ReadMem(10, V, E) = ipReady);
    AssertEquals('rest of the buffer, no read', 'ef', ViewStr(V));
    AssertEquals('one read so far', 1, M.ReadCalls);
    V.Release;
    AssertTrue('pending', Io.ReadMem(10, V, E) = ipPending);
    AssertTrue('read blocked', Io.IsReadBlocked);
    AssertTrue(Io.ReadMem(10, V, E) = ipReady);
    AssertFalse('poll_read_from_io clears read_blocked', Io.IsReadBlocked);
    AssertEquals('gh', ViewStr(V));
    V.Release;
    AssertTrue('eof', Io.ReadMem(10, V, E) = ipReady);
    AssertEquals('eof: empty view', 0, V.Len);
    V.Release;
    AssertTrue('eof again via poll_read_from_io', Io.PollReadFromIo(N, E) = ipReady);
    AssertEquals(0, N);
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Consume_leading_lines;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  N: SizeInt;
begin
  M := TMockTransport.Create;
  try
    M.Read(#13#10#10#13'GET');
    Io.Init(M, nil);
    Io.ConsumeLeadingLines;
    AssertEquals('empty buffer: nothing', 0, Io.ReadBufLen);
    AssertTrue(Io.PollReadFromIo(N, E) = ipReady);
    Io.ConsumeLeadingLines;
    AssertEquals('GET', ReadBufStr(Io));
    Io.ConsumeLeadingLines;
    AssertEquals('GET', ReadBufStr(Io));
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Into_inner_returns_leftover;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head, Rest: TBytesView;
  Err: THyperError;
  AIo: TTransport;
begin
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read('GET / HTTP/1.1' + CRLF + 'Upgrade: foo' + CRLF + CRLF + 'LEFTOVER');
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    AssertTrue('wants upgrade', Msg.WantsUpgrade);
    AppendStr(Io.HeadersBuf, 'unflushed', nil);
    Io.IntoInner(AIo, Rest);
    AssertTrue('transport', AIo = M);
    AssertEquals('leftover', 'LEFTOVER', ViewStr(Rest));
    AssertTrue('io taken', Io.Io = nil);
    AssertEquals('head and rest pin the block', 2, Rest.Block^.Pins);
    Head.Release;
    Rest.Release;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Queue_limit_and_can_buffer;
var
  M: TMockTransport;
  Io: TH1Io;
  I: Integer;
  Raised: Boolean;
  Big: RawByteString;
begin
  Big := BigStr('x');
  M := TMockTransport.Create;
  try
    M.Vectored(True);
    Io.Init(M, nil);
    for I := 1 to MAX_BUF_LIST_BUFFERS do
    begin
      AssertTrue('can buffer', Io.CanBuffer);
      Io.Buffer(MemBuf(Big));
    end;
    AssertFalse('16 queued: can_buffer false', Io.CanBuffer);
    AssertFalse('no head buffer', Io.CanHeadersBuf);
    { the ring holds QUEUE_SLOTS entries; one more is a caller bug }
    for I := MAX_BUF_LIST_BUFFERS + 1 to QUEUE_SLOTS do
      Io.Buffer(MemBuf('x'));
    Raised := False;
    try
      Io.Buffer(MemBuf('x'));
    except
      on EH1Panic do
        Raised := True;
    end;
    AssertTrue('full ring refused', Raised);
    AssertEquals(QUEUE_SLOTS, Io.WriteBuf.Queue.Count);
    Io.Done;
    { remaining against max_buf_size }
    M.Vectored(False);
    Io.Init(M, nil);
    Io.SetMaxBufSize(8192);
    AppendStr(Io.HeadersBuf, StringOfChar('a', 8191), nil);
    AssertTrue('8191 < 8192', Io.CanBuffer);
    Io.Buffer(MemBuf('b'));
    AssertFalse('8192 bytes: can_buffer false', Io.CanBuffer);
    Io.FlushPipeline := True;   { set_flush_pipeline asserts an empty write buffer }
    AssertTrue('pipeline_flush: the cursor is not bounded', Io.CanBuffer);
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Trailers_entry_queued_and_copied;
var
  M: TMockTransport;
  Io: TH1Io;
  V: TByteVec;
  Iov: array[0..MAX_WRITEV_BUFS - 1] of TIoSlice;
  E: cint;
  Pool: TBlockPool;
  S: RawByteString;
  Blk: PBufBlock;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  M := TMockTransport.Create;
  try
    { Queue: three slices, as hyper's chain; partial write inside the fields }
    M.Vectored(True).WriteLimit(5).Write('0'#13#10'fo').Write('o: bar'#13#10#13#10);
    Io.Init(M, @Pool);
    V := Default(TByteVec);
    AppendStr(@V, '0'#13#10'foo: bar'#13#10#13#10, @Pool);
    QueueDirect(Io, QueuedTrailers(V));
    AssertTrue('ownership taken', V.Block = nil);
    AssertEquals('3 slices', 3, Io.WriteBuf.ChunksVectored(@Iov[0], MAX_WRITEV_BUFS));
    SetString(S, PAnsiChar(Iov[1].Base), Iov[1].Len);
    AssertEquals('fields slice', 'foo: bar'#13#10, S);
    Blk := Io.WriteBuf.Queue.Front^.Trailers.Block;
    AssertTrue(Io.PollFlush(E) = ipReady);
    AssertTrue('trailer block back in the pool after the write', Pool.FreeLists[0] = Blk);
    AssertEquals(2, M.WriteCalls);
    M.AssertDone;
    Io.Done;
    { through Buffer: copied into the cursor, block back at once }
    M.Vectored(False).Write('0'#13#10'foo: bar'#13#10#13#10);
    Io.Init(M, @Pool);
    V := Default(TByteVec);
    AppendStr(@V, '0'#13#10'foo: bar'#13#10#13#10, @Pool);
    Blk := V.Block;
    Io.Buffer(QueuedTrailers(V));
    AssertTrue('trailer block back at once (head of the free list)', Pool.FreeLists[0] = Blk);
    AssertEquals('in the cursor', '0'#13#10'foo: bar'#13#10#13#10, CursorStr(Io.WriteBuf.Headers));
    AssertTrue(Io.PollFlush(E) = ipReady);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
    Pool.Done;
  end;
end;

procedure TTestIoExtra.Owner_released_after_write;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
  S: RawByteString;
  B: TBodyData;
  Refs: SizeInt;
begin
  M := TMockTransport.Create;
  try
    ReleasedCount := 0;
    M.Vectored(True).WriteLimit(3).Write('abc').WritePending.Write('defghi');
    Io.Init(M, nil);
    QueueDirect(Io, MemBuf('abcd', CountingOwner));
    QueueDirect(Io, MemBuf('efghi', CountingOwner));
    AssertTrue(Io.PollFlush(E) = ipPending);
    AssertEquals('partially written: not released', 0, ReleasedCount);
    AssertTrue(Io.PollFlush(E) = ipReady);
    AssertEquals('both released', 2, ReleasedCount);
    M.AssertDone;
    Io.Done;
    { Done releases queued data that was never written }
    ReleasedCount := 0;
    Io.Init(M, nil);
    QueueDirect(Io, MemBuf('zz', CountingOwner));
    Io.Done;
    AssertEquals('released by Done', 1, ReleasedCount);
    { BodyString: the reference is dropped after the copy }
    S := 'string body ' + IntToStr(Random(1000));
    M.Vectored(False).Write(S);          { the mock keeps its own reference }
    Refs := StringRefCount(S);
    B := BodyString(S);
    AssertEquals('one reference held', Refs + 1, StringRefCount(S));
    Io.Init(M, nil);
    Io.Buffer(MemBuf(S, B));
    AssertEquals('reference dropped after the copy', Refs, StringRefCount(S));
    AssertTrue(Io.PollFlush(E) = ipReady);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;


procedure TTestIoExtra.Parse_max_header_size_boundary;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  Ctx: TH1ParseContext;
  Part: RawByteString;
begin
  { io.rs:204 "if curr_len >= max": a partial head of exactly
    max_header_size bytes is TooLarge; one byte less reads on }
  Part := 'GET / HTTP/1.1' + CRLF + 'X: ';
  Part := Part + StringOfChar('a', 100 - Length(Part));
  AssertEquals(100, Length(Part));
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Read(Part).ReadPending;
    Io.Init(M, nil);
    Ctx := DefaultParseContext;
    Ctx.MaxHeaderSize := 100;
    Err := Default(THyperError);
    AssertTrue('len = max: error', Io.Parse(Ctx, H, Msg, Head, Err) = prErr);
    AssertTrue('too large', (Err.Kind = hekParse) and (Err.Parse = h1peTooLarge));
    Io.Done;
    M.Free;
    M := TMockTransport.Create;
    M.Read(Copy(Part, 1, 99)).ReadPending;
    Io.Init(M, nil);
    Err := Default(THyperError);
    AssertTrue('len = max - 1: reads on (Pending)', Io.Parse(Ctx, H, Msg, Head, Err) = prPending);
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Cursor_flush_resets_cursor;
var
  M: TMockTransport;
  Io: TH1Io;
  E: cint;
begin
  { io.rs:325 headers.reset() after a complete write of the cursor: position
    and length back to 0, so later heads reuse the block from its start }
  M := TMockTransport.Create;
  try
    M.Write('hello world').Write('again');
    Io.Init(M, nil);
    AppendStr(Io.HeadersBuf, 'hello ', nil);
    Io.Buffer(MemBuf('world'));
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('pos reset', 0, Io.WriteBuf.Headers.Pos);
    AssertEquals('len reset', 0, Io.WriteBuf.Headers.Bytes.Len);
    AppendStr(Io.HeadersBuf, 'again', nil);
    AssertEquals('the next head starts at 0', 5, Io.WriteBuf.Headers.Bytes.Len);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    M.AssertDone;
    Io.Done;
  finally
    M.Free;
  end;
end;

procedure TTestIoExtra.Pipeline_flush_writes_queued_file;
var
  Sv: array[0..1] of cint;
  Src: TIoSource;
  T: TTcpTransport;
  Io: TH1Io;
  Fd: cint;
  Content, Got: RawByteString;
  E: cint;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
begin
  { io.rs:279 returns Ready without writing while pipeline_flush is on and
    the read buffer holds bytes. With an entry queued (here a file),
    CanHeadersBuf stays False until it is written, so the next response
    could never be buffered and nothing would wake the task: a queued entry
    is written even then }
  Content := PatternBytes(3000, 9);
  MakePair(Sv);
  Fd := MakeTempFile(Content);
  H := THttpHeaders.Create;
  Src := Default(TIoSource);
  Src.Fd := Sv[0];
  Src.Ready := [rdRead, rdWrite];
  T := NewTcpTransport(@Src);
  try
    Io.Init(T, nil);
    Io.SetFlushPipeline(True);
    Got := 'GET /1 HTTP/1.1' + CRLF + CRLF + 'GET /2 HTTP/1.1' + CRLF + CRLF + 'GET /3 HTTP/1.1' + CRLF + CRLF;
    AssertEquals(Length(Got), fpSend(Sv[1], PAnsiChar(Got), Length(Got), 0));
    Err := Default(THyperError);
    AssertTrue('request 1', Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    Head.Release;
    AssertTrue('requests 2 and 3 still buffered', Io.ReadBufLen > 0);
    AppendStr(Io.HeadersBuf, 'HEAD1' + CRLF, nil);
    Io.Buffer(QueuedFile(Fd, 0, 3000, BodyFile(Fd, 0, 3000, False)));
    AssertFalse('no head can be buffered behind the file', Io.CanHeadersBuf);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertTrue('the file was written', Io.WriteBuf.Remaining = 0);
    AssertTrue('the next head can be buffered', Io.CanHeadersBuf);
    Got := DrainSocket(Sv[1]);
    AssertEquals('bytes', 'HEAD1' + CRLF + Content, Got);
    { memory only: the io.rs:279 skip still applies }
    AppendStr(Io.HeadersBuf, 'HEAD2' + CRLF, nil);
    AssertTrue('flush skipped', Io.PollFlush(E) = ipReady);
    AssertTrue('still buffered', Io.HasBufferedWrite);
    Io.Done;
  finally
    FpClose(Fd);
    H.Free;
    T.Free;
    SysClose(Sv[0]);
    SysClose(Sv[1]);
  end;
end;

procedure TTestIoExtra.Pipeline_flush_writes_queued_large_body;
var
  M: TMockTransport;
  Io: TH1Io;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Err: THyperError;
  E: cint;
  Big: RawByteString;
begin
  Big := BigStr('z');
  M := TMockTransport.Create;
  H := THttpHeaders.Create;
  try
    M.Vectored(True).Read('GET /a HTTP/1.1' + CRLF + CRLF + 'GET /b HTTP/1.1' + CRLF + CRLF)
      .Write('HEAD1' + Big).Write('HEAD2small');
    Io.Init(M, nil);
    Io.SetFlushPipeline(True);
    Err := Default(THyperError);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    Head.Release;
    AppendStr(Io.HeadersBuf, 'HEAD1', nil);
    Io.Buffer(MemBuf(Big));
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('written although the read buffer holds bytes', 1, M.WriteCalls);
    AssertTrue(Io.CanHeadersBuf);
    AssertTrue(Io.Parse(DefaultParseContext, H, Msg, Head, Err) = prOk);
    Head.Release;
    AppendStr(Io.HeadersBuf, 'HEAD2', nil);
    Io.Buffer(MemBuf('small'));
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    M.AssertDone;
    Io.Done;
  finally
    H.Free;
    M.Free;
  end;
end;

procedure TTestIoExtra.Entries_behind_a_queued_entry_are_queued;
var
  Sv: array[0..1] of cint;
  Src: TIoSource;
  T: TTcpTransport;
  Io: TH1Io;
  Fd: cint;
  Content, Got, Tail: RawByteString;
  E: cint;
  I: Integer;
begin
  { an entry buffered while the queue is non-empty is queued too (not
    copied into the cursor, which is written first), so the bytes keep their
    order; the queue's room bounds CanBuffer }
  Content := PatternBytes(2000, 4);
  Tail := 'tail-bytes';
  MakePair(Sv);
  Fd := MakeTempFile(Content);
  Src := Default(TIoSource);
  Src.Fd := Sv[0];
  Src.Ready := [rdRead, rdWrite];
  T := NewTcpTransport(@Src);
  try
    Io.Init(T, nil);
    Io.SetFlushPipeline(True);
    AppendStr(Io.HeadersBuf, 'HEAD' + CRLF, nil);
    Io.Buffer(QueuedFile(Fd, 0, 2000, BodyFile(Fd, 0, 2000, False)));
    Io.Buffer(MemBuf(Tail));
    AssertEquals('queued behind the file', 2, Io.WriteBuf.Queue.Count);
    AssertEquals('the cursor holds only the head', 'HEAD' + CRLF, CursorStr(Io.WriteBuf.Headers));
    for I := 3 to MAX_BUF_LIST_BUFFERS do
      Io.Buffer(MemBuf('x'));
    AssertFalse('16 entries: CanBuffer is False', Io.CanBuffer);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    Got := DrainSocket(Sv[1]);
    AssertEquals('order: head, file, tail', 'HEAD' + CRLF + Content + Tail +
      StringOfChar('x', MAX_BUF_LIST_BUFFERS - 2), Got);
    AssertTrue('CanBuffer again', Io.CanBuffer);
    Io.Done;
  finally
    FpClose(Fd);
    T.Free;
    SysClose(Sv[0]);
    SysClose(Sv[1]);
  end;
end;

procedure TTestIoExtra.Head_behind_16_queued_entries;
var
  M: TMockTransport;
  Io: TH1Io;
  V: TByteVec;
  E: cint;
  I: Integer;
begin
  { a head written while entries are queued (the automatic 400/414/431 or
    100 Continue) goes behind them, also when CanBuffer already stopped the
    callers at 16 entries }
  M := TMockTransport.Create;
  try
    M.Vectored(True).Write(StringOfChar('x', MAX_BUF_LIST_BUFFERS) + 'HEAD');
    Io.Init(M, nil);
    for I := 1 to MAX_BUF_LIST_BUFFERS do
      QueueDirect(Io, MemBuf('x'));
    AssertFalse('16 queued: can_buffer false', Io.CanBuffer);
    V := Default(TByteVec);
    AppendStr(@V, 'HEAD', nil);
    Io.BufferAfterQueue(V);
    AssertTrue('ownership taken', V.Block = nil);
    AssertEquals('ring entries', MAX_BUF_LIST_BUFFERS + 1, Io.WriteBuf.Queue.Count);
    AssertEquals('the cursor stays empty', 0, Io.WriteBuf.Headers.Remaining);
    AssertTrue('flush', Io.PollFlush(E) = ipReady);
    AssertEquals('one writev, the head last', 1, M.WriteCalls);
    M.AssertDone;
    AssertEquals('ring empty', 0, Io.WriteBuf.Queue.Count);
    Io.Done;
  finally
    M.Free;
  end;
end;

begin
  RegisterTest(TTestIoRs);
  RegisterTest(TTestIoExtra);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
