{ Tests for bearings.rt.buf TReadBuf, TBytesView and TByteVec (docs/design.md
  sections 5.4 and 7).

  - Unit tests: pool-class growth, compaction of an unpinned block, pinned
    blocks (never moved, freed by their last view), idle release, Freeze,
    Done, TByteVec growth and release.
  - Random_ops_keep_bytes: random sequences of reserve / read / advance /
    split (views kept or released) / idle release against a model byte
    queue, with heap blocks, a pool that frees every block given back and a
    pool that keeps blocks. Checked after every step: the unread bytes and
    every live view equal the model, Len <= Cap, the block holds
    Offset + Cap bytes, a pinned block was never moved, and no block is
    left at the end.
  (Step T1 replaced the table test against bytes::BytesMut.)
  Run: test_rt_readbuf --all --format=plain }
program test_rt_readbuf;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bearings.rt.buf;

type
  TTestReadBuf = class(TTestCase)
  published
    procedure Zeroed_record_is_empty;
    procedure First_reserve_takes_a_pool_class;
    procedure Unpinned_block_is_compacted;
    procedure Full_block_grows_to_the_next_class;
    procedure Pinned_block_never_moves_and_is_freed_by_last_view;
    procedure Release_twice_is_noop;
    procedure Release_idle_gives_the_block_back;
    procedure Release_idle_refused_when_pinned_or_not_empty;
    procedure Freeze_detaches_block;
    procedure Done_with_pins_detaches_block;
    procedure SplitTo_without_block_is_empty;
    procedure ByteVec_growth;
    procedure ByteVec_release_idle;
    procedure Random_ops_keep_bytes;
  end;

{ outstanding blocks of a pool: taken and not given back }
function Outstanding(const Pool: TBlockPool): SizeInt;
var
  C: Integer;
begin
  Result := Pool.Allocated - Pool.Released;
  for C := 0 to POOL_CLASSES - 1 do
    Dec(Result, Pool.Counts[C]);
end;

procedure Fill(var B: TReadBuf; N: SizeInt; First: Byte);
var
  I: SizeInt;
begin
  for I := 0 to N - 1 do
    B.SpareData[I] := Byte(First + I);
  B.AdvanceMut(N);
end;

procedure TTestReadBuf.Zeroed_record_is_empty;
var
  B: TReadBuf;
begin
  B := Default(TReadBuf);
  AssertEquals(0, B.Len);
  AssertEquals(0, B.Cap);
  AssertEquals(0, B.Offset);
  B.Reserve(0, nil);
  AssertTrue('reserve(0) allocates nothing', B.Block = nil);
  B.Done;
end;

procedure TTestReadBuf.First_reserve_takes_a_pool_class;
var
  Pool: TBlockPool;
  B: TReadBuf;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  B := Default(TReadBuf);
  B.Reserve(100, @Pool);
  AssertEquals('capacity is the class', 8192, B.Cap);
  AssertEquals('one block', 1, Pool.Allocated);
  AssertTrue('spare data', B.SpareData = B.Block^.Data);
  B.Done;
  B.Reserve(8193, @Pool);
  AssertEquals('next class', 16384, B.Cap);
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Unpinned_block_is_compacted;
var
  Pool: TBlockPool;
  B: TReadBuf;
  Blk: PBufBlock;
  I: Integer;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  B := Default(TReadBuf);
  B.Reserve(8192, @Pool);
  Fill(B, 8192, 0);
  B.Advance(8000);
  AssertEquals(192, B.Len);
  AssertEquals(192, B.Cap);
  Blk := B.Block;
  B.Reserve(4096, @Pool);
  AssertTrue('same block', B.Block = Blk);
  AssertEquals('moved to the start', 0, B.Offset);
  AssertEquals(8192, B.Cap);
  for I := 0 to 191 do
    AssertEquals('bytes kept', Byte(8000 + I), B.Ptr[I]);
  AssertEquals(1, Pool.Allocated);
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Full_block_grows_to_the_next_class;
var
  Pool: TBlockPool;
  B: TReadBuf;
  I: Integer;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  B := Default(TReadBuf);
  B.Reserve(8192, @Pool);
  Fill(B, 8192, 3);
  B.Reserve(1, @Pool);
  AssertEquals(16384, B.Cap);
  AssertEquals(16384, B.Block^.Size);
  for I := 0 to 8191 do
    AssertEquals('bytes kept', Byte(3 + I), B.Ptr[I]);
  AssertEquals('old block back in the pool', 1, Pool.Counts[0]);
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Pinned_block_never_moves_and_is_freed_by_last_view;
var
  Pool: TBlockPool;
  B: TReadBuf;
  V1, V2: TBytesView;
  Old: PBufBlock;
  OldP: PByte;
  I: Integer;
begin
  Pool.Init(0);                        { every block given back is freed }
  B := Default(TReadBuf);
  B.Reserve(8192, @Pool);
  Fill(B, 300, 0);
  V1 := B.SplitTo(120);
  AssertEquals(1, V1.Block^.Pins);
  Old := B.Block;
  OldP := V1.P;
  B.Reserve(100, @Pool);               { room at the end: nothing moves }
  AssertTrue('same block', B.Block = Old);
  B.Reserve(8192, @Pool);              { pinned: a new block of the class >= len + additional }
  AssertEquals(16384, B.Cap);
  AssertTrue('new block', B.Block <> Old);
  AssertTrue('old block detached', Old^.Detached);
  AssertTrue('view not moved', V1.P = OldP);
  for I := 0 to 119 do
    AssertEquals('view bytes', I, V1.P[I]);
  for I := 0 to 179 do
    AssertEquals('buffer bytes', (I + 120) and $FF, B.Ptr[I]);
  AssertEquals('two blocks live', 2, Outstanding(Pool));
  V2 := B.SplitTo(10);
  V1.Release;
  AssertEquals('detached block freed by its last view', 1, Outstanding(Pool));
  V2.Release;
  AssertEquals('the buffer keeps its block', 1, Outstanding(Pool));
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Release_twice_is_noop;
var
  B: TReadBuf;
  V: TBytesView;
begin
  B := Default(TReadBuf);
  B.Reserve(16, nil);
  B.AdvanceMut(8);
  V := B.SplitTo(4);
  V.Release;
  AssertTrue(V.Block = nil);
  AssertEquals(0, V.Len);
  V.Release;
  AssertEquals(0, B.Block^.Pins);
  B.Done;
end;

procedure TTestReadBuf.Release_idle_gives_the_block_back;
var
  Pool: TBlockPool;
  B: TReadBuf;
  V: TBytesView;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  B := Default(TReadBuf);
  B.Reserve(8192, @Pool);
  B.AdvanceMut(100);
  V := B.SplitTo(100);
  V.Release;
  B.ReleaseIdle(@Pool);
  AssertTrue('block given back', B.Block = nil);
  AssertEquals('in the pool', 1, Pool.Counts[0]);
  AssertEquals(0, B.Len);
  AssertEquals(0, B.Cap);
  B.Reserve(10, @Pool);                { the pooled block is reused }
  AssertTrue(B.Block <> nil);
  AssertEquals(0, Pool.Counts[0]);
  AssertEquals(1, Pool.Allocated);
  AssertEquals(8192, B.Cap);
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Release_idle_refused_when_pinned_or_not_empty;
var
  Pool: TBlockPool;
  B: TReadBuf;
  V: TBytesView;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  B := Default(TReadBuf);
  B.Reserve(100, @Pool);
  B.AdvanceMut(100);
  V := B.SplitTo(100);
  B.ReleaseIdle(@Pool);
  AssertTrue('pinned: kept', B.Block <> nil);
  V.Release;
  B.Reserve(10, @Pool);
  B.AdvanceMut(5);
  B.ReleaseIdle(@Pool);
  AssertTrue('not empty: kept', B.Block <> nil);
  B.Done;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Freeze_detaches_block;
var
  Pool: TBlockPool;
  B: TReadBuf;
  V, E: TBytesView;
begin
  Pool.Init(0);
  B := Default(TReadBuf);
  B.Reserve(64, @Pool);
  B.SpareData[0] := 7;
  B.AdvanceMut(10);
  V := B.Freeze;
  AssertEquals(10, V.Len);
  AssertEquals(7, V.P[0]);
  AssertTrue('buffer empty again', (B.Block = nil) and (B.Cap = 0) and (B.Len = 0));
  AssertEquals(1, Outstanding(Pool));
  V.Release;
  AssertEquals('freed by the view', 0, Outstanding(Pool));
  B.Reserve(64, @Pool);
  E := B.Freeze;
  AssertTrue('empty rest: no block held', E.Block = nil);
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.Done_with_pins_detaches_block;
var
  Pool: TBlockPool;
  B: TReadBuf;
  V: TBytesView;
begin
  Pool.Init(0);
  B := Default(TReadBuf);
  B.Reserve(64, @Pool);
  B.AdvanceMut(10);
  V := B.SplitTo(4);
  B.Done;
  AssertEquals('kept for the view', 1, Outstanding(Pool));
  V.Release;
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

procedure TTestReadBuf.SplitTo_without_block_is_empty;
var
  B: TReadBuf;
  V: TBytesView;
begin
  B := Default(TReadBuf);
  V := B.SplitTo(0);
  AssertEquals(0, V.Len);
  AssertTrue(V.Block = nil);
  V.Release;
  AssertTrue(B.Block = nil);
end;

procedure TTestReadBuf.ByteVec_growth;
var
  Pool: TBlockPool;
  V, H: TByteVec;
  X: array[0..9999] of Byte;
  I: Integer;
begin
  for I := 0 to High(X) do
    X[I] := Byte(I * 7);
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  V := Default(TByteVec);
  V.Append(@X[0], 1, @Pool);
  AssertEquals('pool: the class', 8192, V.Cap);
  V.Append(@X[1], 9000, @Pool);
  AssertEquals('pool: Max(2 * cap, len + n) rounded to a class', 16384, V.Cap);
  for I := 0 to 9000 do
    AssertEquals('bytes', X[I], V.Data[I]);
  V.DrainFront(1000);
  AssertEquals(8001, V.Len);
  AssertEquals(X[1000], V.Data[0]);
  AssertEquals(X[9000], V.Data[8000]);
  V.Clear;
  V.ReleaseIdle(@Pool);
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
  H := Default(TByteVec);
  H.Reserve(10, nil);
  AssertEquals('heap: exact', 10, H.Cap);
  H.Append(@X[0], 21, nil);
  AssertEquals('heap: Max(2 * cap, len + n)', 21, H.Cap);
  H.Append(@X[21], 1, nil);
  AssertEquals('heap: doubling', 42, H.Cap);
  for I := 0 to 21 do
    AssertEquals(X[I], H.Data[I]);
  BlockFree(H.Block);
end;

procedure TTestReadBuf.ByteVec_release_idle;
var
  Pool: TBlockPool;
  V: TByteVec;
  X: Byte;
begin
  Pool.Init(POOL_DEFAULT_MAX_BYTES);
  V := Default(TByteVec);
  X := 42;
  V.Append(@X, 1, @Pool);
  V.ReleaseIdle(@Pool);
  AssertTrue('not empty: kept', V.Block <> nil);
  V.Clear;
  V.ReleaseIdle(@Pool);
  AssertTrue(V.Block = nil);
  AssertEquals(0, V.Cap);
  V.Append(@X, 1, @Pool);
  AssertEquals(1, Pool.Allocated);
  AssertEquals(42, V.Data[0]);
  V.Clear;
  V.ReleaseIdle(@Pool);
  AssertEquals(0, Outstanding(Pool));
  Pool.Done;
end;

{ ---- random operations against a model ---- }

type
  TModelView = record
    V: TBytesView;
    First: Cardinal;           { model position of V.P[0] }
    BlockData: PByte;          { the block's data pointer when split: it must not move }
  end;

procedure TTestReadBuf.Random_ops_keep_bytes;
const
  STEPS = 1000;
  SEEDS = 20;
var
  Mode, Seed, Step, I, K: Integer;
  Pool: TBlockPool;
  PP: PBlockPool;
  B: TReadBuf;
  Views: array of TModelView;
  Head, Tail: Cardinal;        { model: unread bytes are positions [Head, Tail); byte = pos and $FF }
  N: SizeInt;
  Op: Integer;

  procedure CheckState(const What: string);
  var
    J: Integer;
    X: SizeInt;
  begin
    AssertEquals(What + ': len', SizeInt(Tail - Head), B.Len);
    AssertTrue(What + ': len <= cap', B.Len <= B.Cap);
    if B.Block <> nil then
      AssertTrue(What + ': cap inside the block', B.Offset + B.Cap <= B.Block^.Size)
    else
      AssertEquals(What + ': no block, no bytes', 0, B.Len);
    for X := 0 to B.Len - 1 do
      if B.Ptr[X] <> Byte(Head + Cardinal(X)) then
        Fail(Format('%s: unread byte %d', [What, X]));
    for J := 0 to High(Views) do
    begin
      AssertTrue(What + ': view block not moved', Views[J].V.Block^.Data = Views[J].BlockData);
      for X := 0 to Views[J].V.Len - 1 do
        if Views[J].V.P[X] <> Byte(Views[J].First + Cardinal(X)) then
          Fail(Format('%s: view %d byte %d', [What, J, X]));
    end;
  end;

begin
  for Mode := 0 to 2 do
    for Seed := 1 to SEEDS do
    begin
      RandSeed := Seed * 7919 + Mode;
      case Mode of
        0: PP := nil;
        1: begin Pool.Init(0); PP := @Pool; end;
      else
        begin Pool.Init(POOL_DEFAULT_MAX_BYTES); PP := @Pool; end;
      end;
      B := Default(TReadBuf);
      Views := nil;
      Head := 0;
      Tail := 0;
      for Step := 1 to STEPS do
      begin
        Op := Random(100);
        if Op < 30 then
        begin
          { a read: reserve like PollReadFromIo, then fill part of the spare room }
          N := 1 + Random(3) * 4096 + Random(5000);
          B.Reserve(N, PP);
          AssertTrue('reserve gives the room', B.SpareCapacity >= N);
          K := 1 + Random(B.SpareCapacity);
          for I := 0 to K - 1 do
            B.SpareData[I] := Byte(Tail + Cardinal(I));
          B.AdvanceMut(K);
          Inc(Tail, K);
        end
        else if Op < 50 then
        begin
          if B.Len > 0 then
          begin
            K := Random(B.Len + 1);
            B.Advance(K);
            Inc(Head, K);
          end;
        end
        else if Op < 70 then
        begin
          { split: a head or a body chunk view, kept for a while }
          if (B.Len > 0) and (Length(Views) < 8) then
          begin
            K := 1 + Random(B.Len);
            SetLength(Views, Length(Views) + 1);
            Views[High(Views)].V := B.SplitTo(K);
            Views[High(Views)].First := Head;
            Views[High(Views)].BlockData := B.Block^.Data;
            Inc(Head, K);
          end;
        end
        else if Op < 90 then
        begin
          if Length(Views) > 0 then
          begin
            I := Random(Length(Views));
            Views[I].V.Release;
            Views[I] := Views[High(Views)];
            SetLength(Views, Length(Views) - 1);
          end;
        end
        else
          B.ReleaseIdle(PP);
        CheckState(Format('mode %d seed %d step %d op %d', [Mode, Seed, Step, Op]));
      end;
      for I := 0 to High(Views) do
        Views[I].V.Release;
      Views := nil;
      B.Done;
      if PP <> nil then
      begin
        AssertEquals(Format('mode %d seed %d: blocks left', [Mode, Seed]), 0, Outstanding(Pool));
        Pool.Done;
      end;
    end;
end;

var
  App: TTestRunner;
begin
  RegisterTest(TTestReadBuf);
  App := TTestRunner.Create(nil);
  App.Initialize;
  App.Title := 'test_rt_readbuf';
  App.Run;
  App.Free;
end.
