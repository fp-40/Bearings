{ bearings.rt.buf - memory blocks and byte buffers used by the connection code.

  A server that handles many connections reads and writes a lot of short
  byte sequences. Allocating and freeing a heap buffer for each of them is
  slow and fragments memory, so this unit keeps freed blocks in a pool and
  hands them out again.

  Main types:
  - TBlockPool: a pool of 64-byte aligned memory blocks in eight size
    classes (8 KiB to 1 MiB). Each event loop owns one pool.
  - TReadBuf: the read buffer of one connection. The bytes read from the
    socket go into it; the HTTP parser consumes them from the front.
  - TBytesView: a slice of a read buffer's block handed to other code (for
    example the parsed request head, or a chunk of the request body). The
    view "pins" the block: while a view exists the block is not moved, reused
    or freed, so the pointer in the view stays valid.
  - TByteVec: a growable byte vector over a pooled block (used, for example,
    for encoded response headers).
  - TBodyData: one piece of response body (memory or a file range) plus the
    information needed to release it after it was written.

  Threading: a TBlockPool, and every TReadBuf, TBytesView and TByteVec that
  uses it, belong to the loop thread that owns the pool. The pin counts are
  plain integers, not atomics, so views must be created and released on
  that thread. TBodyData values may be built on any thread; ReleaseBody runs
  on the loop thread after the bytes were written.

  The unit uses no managed types (strings, dynamic arrays, interfaces) in
  its routines, so the compiler generates no implicit exception frames for
  them; tools/check-hot-asm.sh checks this for TByteVec and TReadBuf. }
unit bearings.rt.buf;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  ctypes;

type
  PBlockPool = ^TBlockPool;
  PBufBlock = ^TBufBlock;

  TBufBlock = record
    Data: PByte;                 { 64-byte aligned (one cache line), Size bytes }
    Size: SizeInt;               { pool class, or the exact size of a heap block }
    Pins: Integer;               { number of live TBytesView values on this block; loop thread only }
    Detached: Boolean;           { no TReadBuf uses this block any more; the release of the last view frees it }
    Pool: PBlockPool;            { nil: a heap block (FreeMem on release) }
    NextFree: PBufBlock;         { link in the pool's free list }
  end;

  { A pool of free blocks. One per event loop; used by the loop thread only.

    Blocks come in eight size classes, 8 KiB to 1 MiB, each class twice the
    previous one. Each class has a LIFO free list: the most recently returned
    block is handed out first, because its memory is most likely still in
    the CPU cache. The total size of the blocks kept in the free lists is
    capped by MaxPooledBytes; a block given back when the cap would be
    exceeded is freed instead. A request above 1 MiB gets a heap block of
    the exact size, which Give frees. Blocks are not zero-filled.

    Trim returns unused memory to the heap. For each class it records the
    smallest length the free list had since the previous Trim (LowWater):
    that many blocks were not needed during the interval, so Trim frees that
    many from the tail of the list (the least recently returned ones) and
    keeps the rest. The loop calls Trim after 1 s without events
    (bearings.rt.loop). }
  TBlockPool = record
    FreeLists: array[0..7] of PBufBlock;   { 8, 16, 32, 64, 128, 256, 512 KiB, 1 MiB }
    PooledBytes: SizeInt;
    MaxPooledBytes: SizeInt;
    Counts: array[0..7] of SizeInt;        { blocks in each free list }
    LowWater: array[0..7] of SizeInt;      { minimum of Counts[i] since the previous Trim }
    Allocated: SizeInt;                    { blocks obtained from the heap (stats, tests) }
    Released: SizeInt;                     { blocks returned to the heap (stats, tests) }
    procedure Init(AMaxPooledBytes: SizeInt);
    function Take(MinSize: SizeInt): PBufBlock;     { smallest class >= MinSize; heap above 1 MiB }
    procedure Give(B: PBufBlock);                   { requires B^.Pins = 0 }
    procedure Trim;                                 { free the blocks not needed since the previous Trim }
    procedure Done;                                 { free every pooled block }
  end;

const
  POOL_MIN_CLASS = 8192;
  POOL_MAX_CLASS = 1024 * 1024;
  POOL_CLASSES = 8;
  POOL_DEFAULT_MAX_BYTES = 64 * 1024 * 1024;

{ Index of the smallest size class >= Size (0..7); -1 above POOL_MAX_CLASS. }
function PoolClassIndex(Size: SizeInt): Integer; inline;

type

  { A read-only slice of a block that keeps the block alive. While a view
    exists, its block has Pins > 0 and is neither moved nor reused, so P
    stays valid even after the TReadBuf moved on to another block. A view is
    a plain record: copying it does not add a pin, so exactly one copy must
    call Release. }
  TBytesView = record
    P: PByte;
    Len: SizeInt;
    Block: PBufBlock;            { nil: static or caller-owned memory }
    { Loop thread. Removes the pin; a Detached block whose last pin goes away
      is freed. Clears the view (P = nil, Len = 0, Block = nil), so a second
      Release on the same record does nothing. }
    procedure Release; inline;
  end;

  { The read buffer of one connection. The loop reads from the socket into
    the spare room after the unread bytes; the parser consumes bytes from
    the front (Advance) or takes them out as pinned views (SplitTo).

    Block = nil: the buffer holds no memory (never used yet, or given back
    while the connection was idle, so that thousands of idle keep-alive
    connections do not each hold a block). The unread bytes are
    [Ptr, Ptr + Len); Cap counts the bytes from Ptr to the end of the block,
    so the spare room is Cap - Len.

    Reserve(N) makes Cap - Len >= N: without a block it takes one of at
    least N bytes; on an unpinned block that is large enough it moves the
    unread bytes to the start of the block; otherwise it takes a block of
    the smallest pool class >= Len + N, copies the unread bytes and gives the
    old block back, or, while views still pin the old block, marks it
    Detached so that the release of its last view frees it.

    A block with pins is never moved or compacted, because views point into
    it. Pins are counted on the loop thread only. }
  TReadBuf = record
    Block: PBufBlock;
    Ptr: PByte;                  { start of the unread bytes }
    Len: SizeInt;                { unread bytes }
    Cap: SizeInt;                { bytes from Ptr to the end of the block }
    function Offset: SizeInt; inline;                    { Ptr - Block^.Data }
    function SpareCapacity: SizeInt; inline;             { Cap - Len }
    function SpareData: PByte; inline;                   { Ptr + Len; valid after Reserve }
    procedure Reserve(Additional: SizeInt; Pool: PBlockPool); inline;
    procedure ReserveSlow(Additional: SizeInt; Pool: PBlockPool);   { the non-inlined part of Reserve }
    procedure AdvanceMut(N: SizeInt); inline;            { after read(2): Len += N }
    procedure Advance(N: SizeInt); inline;               { drop N unread bytes }
    { Removes the first N unread bytes from the buffer and returns them as a
      view that pins the block. Without a block (then N must be 0) the
      result is an empty view without a block. }
    function SplitTo(N: SizeInt): TBytesView;
    { Hands all unread bytes over as one view and leaves the buffer empty,
      without a block. Used when the connection stops being HTTP (an upgrade)
      and the bytes already read belong to the new protocol. When nothing is
      unread the result is an empty view without a block, and the block is
      given back (or left Detached while other views pin it). }
    function Freeze: TBytesView;
    procedure ReleaseIdle(Pool: PBlockPool);             { gives the block back; does nothing unless Len = 0 and Pins = 0 }
    { Gives the block back (or leaves it Detached while views pin it); the
      record is empty again. }
    procedure Done;
  end;

  { A growable byte vector over a block from the pool (or from the heap when
    Pool = nil). When it grows it takes a block of at least
    Max(2 * Cap, Len + Additional) bytes, copies the bytes and frees the old
    block; Cap is then the new block's size. Block = nil: no memory, Cap = 0.
    A zeroed record (Default(TByteVec)) is an empty vector. Unlike TReadBuf
    there are no views into it, so the block may be replaced at any time. }
  PByteVec = ^TByteVec;
  TByteVec = record
    Data: PByte;
    Len: SizeInt;
    Cap: SizeInt;
    Block: PBufBlock;
    { After it, Cap - Len >= Additional and, when Additional > 0, Data
      points to a block with room for Cap bytes. }
    procedure Reserve(Additional: SizeInt; Pool: PBlockPool);
    procedure Append(P: PByte; N: SizeInt; Pool: PBlockPool);
    procedure DrainFront(N: SizeInt);                           { remove the first N bytes }
    procedure Clear; inline;                                    { Len := 0, keeps the block }
    procedure ReleaseIdle(Pool: PBlockPool);                    { Len = 0: block back, Cap := 0 }
  end;

  { One piece of response body, queued for writing to the socket. It uses
    no HTTP types, so the transport (bearings.http1.io) can queue it directly.

    Kind: bkMem is the memory [P, P + Len); bkFile is Len bytes of the open
    file Fd from Offset, sent with sendfile(2) (the kernel copies the file
    data to the socket without passing it through user memory).
    Own says how the memory is released once written:
      boStatic   - nothing to do (memory that outlives the write);
      boString   - Ctx holds one reference to a RawByteString; it is dropped;
      boHeap     - P was allocated with GetMem; FreeMem(P);
      boExchange - the request's exchange owns the memory; nothing to do here;
      boCustom   - ReleaseProc(Ctx, P) is called. }
  TBodyKind = (bkEmpty, bkMem, bkFile);
  TBodyOwnership = (boStatic, boString, boHeap, boExchange, boCustom);
  TBodyReleaseProc = procedure(Ctx: Pointer; Data: PByte);

  TBodyData = record                 { no managed fields }
    Kind: TBodyKind;
    P: PByte; Len: SizeInt;
    Own: TBodyOwnership;
    Ctx: Pointer;                    { boString: the RawByteString, with one reference held;
                                       boCustom: first argument of ReleaseProc }
    ReleaseProc: TBodyReleaseProc;
    Fd: cint; Offset: Int64; CloseFd: Boolean;      { bkFile; CloseFd: ReleaseBody closes Fd }
  end;

function BodyEmpty: TBodyData;                             { no bytes }
function BodyStatic(P: Pointer; Len: SizeInt): TBodyData;  { memory that outlives the server }
function BodyString(const S: RawByteString): TBodyData;   { keeps one reference to S until released }
function BodyHeap(P: Pointer; Len: SizeInt): TBodyData;   { takes ownership of P: FreeMem after the write }
function BodyFile(Fd: cint; Offset, Len: Int64; CloseAfter: Boolean): TBodyData;   { written with sendfile(2) }
procedure ReleaseBody(var B: TBodyData);                   { releases per Own (and closes the file if CloseFd); B becomes BodyEmpty }

{ Block storage of TByteVec and TReadBuf: from Pool when it is not nil
  (TBlockPool.Take), else a heap block of exactly MinSize bytes. }
function BlockAlloc(Pool: PBlockPool; MinSize: SizeInt): PBufBlock;
{ Gives B back to its pool, or frees a heap block. }
procedure BlockFree(B: PBufBlock);

implementation

uses
  bearings.rt.sys;

const
  BLOCK_ALIGN = 64;

{ ---- blocks ---- }

function PoolClassIndex(Size: SizeInt): Integer;
var
  C: SizeInt;
begin
  if Size > POOL_MAX_CLASS then
    Exit(-1);
  Result := 0;
  C := POOL_MIN_CLASS;
  while C < Size do
  begin
    C := C shl 1;
    Inc(Result);
  end;
end;

{ A block of Size data bytes in one heap allocation: the TBufBlock header
  first, then the data at the next 64-byte boundary. FreeMem on the block
  pointer frees both. }
function NewRawBlock(Size: SizeInt): PBufBlock; inline;
var
  Raw: PByte;
  Hdr: SizeInt;
begin
  Hdr := (SizeOf(TBufBlock) + BLOCK_ALIGN - 1) and not (BLOCK_ALIGN - 1);
  GetMem(Raw, Hdr + Size + BLOCK_ALIGN);
  Result := PBufBlock(Raw);
  Result^.Data := PByte((PtrUInt(Raw) + PtrUInt(Hdr) + BLOCK_ALIGN - 1) and not PtrUInt(BLOCK_ALIGN - 1));
  Result^.Size := Size;
  Result^.Pins := 0;
  Result^.Detached := False;
  Result^.Pool := nil;
  Result^.NextFree := nil;
end;

function BlockAlloc(Pool: PBlockPool; MinSize: SizeInt): PBufBlock;
begin
  if Pool <> nil then
    Exit(Pool^.Take(MinSize));
  Result := NewRawBlock(MinSize);
end;

procedure BlockFree(B: PBufBlock);
begin
  if B = nil then
    Exit;
  if B^.Pool <> nil then
    B^.Pool^.Give(B)
  else
    FreeMem(B);
end;

{ ---- TByteVec ---- }

procedure TByteVec.Reserve(Additional: SizeInt; Pool: PBlockPool);
var
  NewCap: SizeInt;
  B: PBufBlock;
begin
  if Cap - Len >= Additional then
    Exit;
  NewCap := 2 * Cap;
  if NewCap < Len + Additional then
    NewCap := Len + Additional;
  B := BlockAlloc(Pool, NewCap);
  if Len > 0 then
    Move(Data^, B^.Data^, Len);
  if Block <> nil then
    BlockFree(Block);
  Block := B;
  Data := B^.Data;
  Cap := B^.Size;
end;

procedure TByteVec.Append(P: PByte; N: SizeInt; Pool: PBlockPool);
begin
  if N <= 0 then
    Exit;
  Reserve(N, Pool);
  Move(P^, Data[Len], N);
  Inc(Len, N);
end;

procedure TByteVec.DrainFront(N: SizeInt);
begin
  Assert((N >= 0) and (N <= Len), 'TByteVec.DrainFront: range end out of bounds');
  if N <= 0 then
    Exit;
  if N < Len then
    Move(Data[N], Data[0], Len - N);
  Dec(Len, N);
end;

procedure TByteVec.Clear;
begin
  Len := 0;
end;

procedure TByteVec.ReleaseIdle(Pool: PBlockPool);
begin
  if (Len <> 0) or (Block = nil) then
    Exit;
  BlockFree(Block);
  Block := nil;
  Data := nil;
  Cap := 0;
end;

{ ---- TBlockPool ---- }

procedure TBlockPool.Init(AMaxPooledBytes: SizeInt);
begin
  FillChar(FreeLists, SizeOf(FreeLists), 0);
  FillChar(Counts, SizeOf(Counts), 0);
  FillChar(LowWater, SizeOf(LowWater), 0);
  PooledBytes := 0;
  MaxPooledBytes := AMaxPooledBytes;
  Allocated := 0;
  Released := 0;
end;

function TBlockPool.Take(MinSize: SizeInt): PBufBlock;
var
  C: Integer;
begin
  C := PoolClassIndex(MinSize);
  if C < 0 then
  begin
    Result := NewRawBlock(MinSize);         { above 1 MiB: exact size, not pooled; Give frees it }
    Result^.Pool := @Self;
    Inc(Allocated);
    Exit;
  end;
  Result := FreeLists[C];
  if Result <> nil then
  begin
    FreeLists[C] := Result^.NextFree;
    Dec(Counts[C]);
    if Counts[C] < LowWater[C] then
      LowWater[C] := Counts[C];
    Dec(PooledBytes, Result^.Size);
    Result^.NextFree := nil;
    Result^.Detached := False;
  end
  else
  begin
    Result := NewRawBlock(POOL_MIN_CLASS shl C);
    Result^.Pool := @Self;
    Inc(Allocated);
  end;
end;

procedure TBlockPool.Give(B: PBufBlock);
var
  C: Integer;
begin
  Assert(B^.Pins = 0, 'TBlockPool.Give: block still pinned');
  { debug builds fill freed blocks so that a use after release shows up }
  {$IFDEF WD_DEBUG}
  FillChar(B^.Data^, B^.Size, $DD);
  {$ENDIF}
  { a block that is not exactly a class size (an oversized one), or one
    that would exceed the cap, goes back to the heap }
  C := -1;
  if B^.Size <= POOL_MAX_CLASS then
    C := PoolClassIndex(B^.Size);
  if (C < 0) or ((POOL_MIN_CLASS shl C) <> B^.Size)
    or (PooledBytes + B^.Size > MaxPooledBytes) then
  begin
    FreeMem(B);
    Inc(Released);
    Exit;
  end;
  B^.NextFree := FreeLists[C];
  FreeLists[C] := B;
  Inc(Counts[C]);
  Inc(PooledBytes, B^.Size);
end;

procedure TBlockPool.Trim;
var
  C: Integer;
  Keep, I: SizeInt;
  P, Cut, Nx: PBufBlock;
begin
  for C := 0 to POOL_CLASSES - 1 do
  begin
    if LowWater[C] > 0 then
    begin
      { keep the head of the list (the recently used blocks): Counts - LowWater
        blocks; free the rest }
      Keep := Counts[C] - LowWater[C];
      if Keep = 0 then
      begin
        Cut := FreeLists[C];
        FreeLists[C] := nil;
      end
      else
      begin
        P := FreeLists[C];
        for I := 2 to Keep do
          P := P^.NextFree;
        Cut := P^.NextFree;
        P^.NextFree := nil;
      end;
      while Cut <> nil do
      begin
        Nx := Cut^.NextFree;
        Dec(PooledBytes, Cut^.Size);
        Dec(Counts[C]);
        FreeMem(Cut);
        Inc(Released);
        Cut := Nx;
      end;
    end;
    { start the next interval }
    LowWater[C] := Counts[C];
  end;
end;

procedure TBlockPool.Done;
var
  C: Integer;
  P, Nx: PBufBlock;
begin
  for C := 0 to POOL_CLASSES - 1 do
  begin
    P := FreeLists[C];
    while P <> nil do
    begin
      Nx := P^.NextFree;
      FreeMem(P);
      Inc(Released);
      P := Nx;
    end;
    FreeLists[C] := nil;
    Counts[C] := 0;
    LowWater[C] := 0;
  end;
  PooledBytes := 0;
end;

{ ---- TBytesView, TReadBuf ---- }

procedure TBytesView.Release;
var
  B: PBufBlock;
begin
  B := Block;
  if B <> nil then
  begin
    Assert(B^.Pins > 0, 'TBytesView.Release: block not pinned');
    Dec(B^.Pins);
    if (B^.Pins = 0) and B^.Detached then
      BlockFree(B);
    Block := nil;
  end;
  P := nil;
  Len := 0;
end;

function TReadBuf.Offset: SizeInt;
begin
  if Block = nil then
    Result := 0
  else
    Result := Ptr - Block^.Data;
end;

function TReadBuf.SpareCapacity: SizeInt;
begin
  Result := Cap - Len;
end;

function TReadBuf.SpareData: PByte;
begin
  Result := Ptr + Len;
end;

procedure TReadBuf.Reserve(Additional: SizeInt; Pool: PBlockPool);
begin
  if (Block <> nil) and (Cap - Len >= Additional) then
    Exit;
  ReserveSlow(Additional, Pool);
end;

procedure TReadBuf.ReserveSlow(Additional: SizeInt; Pool: PBlockPool);
var
  Need: SizeInt;
  B: PBufBlock;
begin
  Need := Len + Additional;
  if Block = nil then
  begin
    Assert(Len = 0, 'TReadBuf.Reserve: bytes without a block');
    if Additional <= 0 then
      Exit;
    B := BlockAlloc(Pool, Need);
    Block := B;
    Ptr := B^.Data;
    Cap := B^.Size;
    Exit;
  end;
  if Cap - Len >= Additional then
    Exit;
  if (Block^.Pins = 0) and (Block^.Size >= Need) then
  begin
    { compact: the unread bytes to the start of the block }
    if Len > 0 then
      Move(Ptr^, Block^.Data^, Len);
    Ptr := Block^.Data;
    Cap := Block^.Size;
    Exit;
  end;
  { a larger block (the smallest class >= Need); a pinned block stays alive
    until its last view is released }
  B := BlockAlloc(Pool, Need);
  if Len > 0 then
    Move(Ptr^, B^.Data^, Len);
  if Block^.Pins = 0 then
    BlockFree(Block)
  else
    Block^.Detached := True;
  Block := B;
  Ptr := B^.Data;
  Cap := B^.Size;
end;

procedure TReadBuf.AdvanceMut(N: SizeInt);
begin
  Assert((N >= 0) and (N <= Cap - Len), 'TReadBuf.AdvanceMut: past the capacity');
  Inc(Len, N);
end;

procedure TReadBuf.Advance(N: SizeInt);
begin
  Assert((N >= 0) and (N <= Len), 'TReadBuf.Advance: past the length');
  Inc(Ptr, N);
  Dec(Len, N);
  Dec(Cap, N);
end;

function TReadBuf.SplitTo(N: SizeInt): TBytesView;
begin
  Assert((N >= 0) and (N <= Len), 'TReadBuf.SplitTo: past the length');
  Result.P := Ptr;
  Result.Len := N;
  Result.Block := Block;
  if Block = nil then
    Exit;
  Inc(Block^.Pins);
  Inc(Ptr, N);
  Dec(Len, N);
  Dec(Cap, N);
end;

function TReadBuf.Freeze: TBytesView;
begin
  Result.P := nil;
  Result.Len := 0;
  Result.Block := nil;
  if Block <> nil then
  begin
    if Len > 0 then
    begin
      Result.P := Ptr;
      Result.Len := Len;
      Result.Block := Block;
      Inc(Block^.Pins);
      Block^.Detached := True;
    end
    else if Block^.Pins = 0 then
      BlockFree(Block)
    else
      Block^.Detached := True;
  end;
  Self := Default(TReadBuf);
end;

procedure TReadBuf.ReleaseIdle(Pool: PBlockPool);
begin
  if (Block = nil) or (Len <> 0) or (Block^.Pins <> 0) then
    Exit;
  BlockFree(Block);
  Self := Default(TReadBuf);
end;

procedure TReadBuf.Done;
begin
  if Block <> nil then
  begin
    if Block^.Pins = 0 then
      BlockFree(Block)
    else
      Block^.Detached := True;
  end;
  Self := Default(TReadBuf);
end;

{ ---- TBodyData. The write queue of bearings.http1.io calls ReleaseBody for each
  entry once it was written (or dropped). ---- }

const
  { BodyEmpty's value. Copying a typed constant compiles to a few moves;
    Default(TBodyData) would call FillChar, and BodyEmpty runs several times
    per request. }
  EMPTY_BODY: TBodyData = (Kind: bkEmpty; P: nil; Len: 0; Own: boStatic; Ctx: nil;
    ReleaseProc: nil; Fd: -1; Offset: 0; CloseFd: False);

function BodyEmpty: TBodyData;
begin
  Result := EMPTY_BODY;
end;

function BodyStatic(P: Pointer; Len: SizeInt): TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.P := P;
  Result.Len := Len;
end;

function BodyString(const S: RawByteString): TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.Own := boString;
  Result.P := Pointer(S);
  Result.Len := System.Length(S);
  { keep one reference in Ctx; assigning through a typecast adds the
    reference without a managed local variable }
  RawByteString(Result.Ctx) := S;
end;

function BodyHeap(P: Pointer; Len: SizeInt): TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.Own := boHeap;
  Result.P := P;
  Result.Len := Len;
end;

function BodyFile(Fd: cint; Offset, Len: Int64; CloseAfter: Boolean): TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkFile;
  Result.Fd := Fd;
  Result.Offset := Offset;
  Result.Len := Len;
  Result.CloseFd := CloseAfter;
end;

procedure ReleaseBody(var B: TBodyData);
begin
  case B.Own of
    boString:
      RawByteString(B.Ctx) := '';
    boHeap:
      if B.P <> nil then
        FreeMem(B.P);
    boCustom:
      if Assigned(B.ReleaseProc) then
        B.ReleaseProc(B.Ctx, B.P);
  else
    { boStatic: the caller's memory; boExchange: owned by the exchange }
  end;
  if (B.Kind = bkFile) and B.CloseFd and (B.Fd >= 0) then
    SysClose(B.Fd);
  B := BodyEmpty;
end;

end.
