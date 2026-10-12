{ M3 step S1 tests for bearings.rt.sync and bearings.rt.loop (docs/design.md
  sections 2, 3 and 7.3):
  - TMpscStack: 8 producer threads x 10^7 pushes, one consumer; per-producer
    FIFO order, nothing lost, and "Push found the stack empty" exactly once
    per non-empty TakeAll batch;
  - TLoop.Post / Sleeping / eventfd race: 4 producers post 10^6 messages with
    random pauses to a loop that sleeps without timeout (a lost wakeup
    hangs a producer: detected by a deadline); a post to an awake loop does
    not write the eventfd;
  - F10 regression: a task closed during an event batch is not run for a
    later event of the same batch and is freed after the batch (after the
    run queue); a closed task still in the run queue is freed only after
    it left the queue;
  - exception resume: an exception in a task aborts that task (Abort, no
    more runs, freed) and the rest of the batch is dispatched without
    another epoll_wait; an exception in a message proc loses no message;
  - run-queue semantics: yield goes to the back, 61 polls per iteration,
    an event for a queued task only sets readiness bits;
  - timers in the loop, idle Blocks.Trim, per-loop date cache, ReadyFromEpoll,
    TBlockPool classes, connection ids.
  Run: test_rt_loop --all --format=plain }
program test_rt_loop;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, BaseUnix, Sockets, fpcunit, testregistry, consoletestrunner,
  ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.sync, bearings.rt.timer, bearings.rt.buf, bearings.rt.loop,
  bearings.http.date;

type
  TTestSync = class(TTestCase)
  published
    procedure Mpsc_8_producers_10e7_each;
    procedure Mpsc_takeall_returns_fifo;
    procedure Parker_unpark_before_and_after_park;
    procedure SpinLock_counts_under_contention;
  end;

  TTestLoop = class(TTestCase)
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ReadyFromEpoll_table;
    procedure BlockPool_classes_and_cap;
    procedure BlockPool_trim_frees_cold_blocks;
    procedure Conn_ids_per_loop;
    procedure Post_race_with_sleeping_loop;
    procedure Post_to_awake_loop_writes_no_eventfd;
    procedure F10_closed_task_skipped_and_freed_after_batch;
    procedure F10_closed_task_in_run_queue_freed_after_leaving_it;
    procedure Exception_aborts_task_and_resumes_batch;
    procedure Exception_in_message_loses_no_message;
    procedure Yield_goes_to_back_with_61_poll_budget;
    procedure Event_for_queued_task_only_sets_readiness;
    procedure Timer_fires_in_loop;
    procedure Idle_loop_trims_block_pool;
    procedure Date_cache_follows_wall_clock;
  end;

{ ---------------------------------------------------------------- MPSC ---- }

const
  MPSC_PRODUCERS = 8;
  MPSC_PER_PRODUCER = 10000000;
  MPSC_RING = 4096;

type
  PProdNode = ^TProdNode;
  TProdNode = record
    Node: TMpscNode;
    Producer: Integer;
    Seq: Integer;
    Free: LongInt;
    Pad: array[0..39] of Byte;
  end;

var
  MStack: TMpscStack;
  MNodes: array[0..MPSC_PRODUCERS - 1] of array of TProdNode;
  MPushEmpty: LongInt;
  MStart: LongInt;

function MpscProducer(Arg: Pointer): PtrInt;
var
  P, Seq, Spins: Integer;
  N: PProdNode;
begin
  P := PtrInt(Arg);
  while MStart = 0 do
    CpuRelax;
  for Seq := 1 to MPSC_PER_PRODUCER do
  begin
    N := @MNodes[P][Seq mod MPSC_RING];
    Spins := 0;
    while N^.Free = 0 do
    begin
      CpuRelax;
      Inc(Spins);
      if Spins > 1000 then
      begin
        ThreadSwitch;
        Spins := 0;
      end;
    end;
    N^.Free := 0;
    N^.Seq := Seq;
    if MStack.Push(@N^.Node) then
      InterlockedIncrement(MPushEmpty);
  end;
  Result := 0;
end;

procedure TTestSync.Mpsc_8_producers_10e7_each;
var
  Th: array[0..MPSC_PRODUCERS - 1] of TThreadID;
  Last: array[0..MPSC_PRODUCERS - 1] of Integer;
  I, J, Batches, Bad: Integer;
  Received: Int64;
  L, Nx: PMpscNode;
  N: PProdNode;
  T0: Int64;
begin
  MStack.Head := nil;
  MPushEmpty := 0;
  MStart := 0;
  for I := 0 to MPSC_PRODUCERS - 1 do
  begin
    SetLength(MNodes[I], MPSC_RING);
    for J := 0 to MPSC_RING - 1 do
    begin
      MNodes[I][J].Producer := I;
      MNodes[I][J].Free := 1;
    end;
    Last[I] := 0;
    Th[I] := BeginThread(@MpscProducer, Pointer(PtrInt(I)));
  end;
  T0 := MonoNowNs;
  InterlockedExchange(MStart, 1);
  Received := 0;
  Batches := 0;
  Bad := 0;
  while Received < Int64(MPSC_PRODUCERS) * MPSC_PER_PRODUCER do
  begin
    L := MStack.TakeAll;
    if L = nil then
    begin
      CpuRelax;
      Continue;
    end;
    Inc(Batches);
    while L <> nil do
    begin
      Nx := L^.Next;
      N := PProdNode(L);
      if N^.Seq <> Last[N^.Producer] + 1 then
        Inc(Bad);
      Last[N^.Producer] := N^.Seq;
      Inc(Received);
      ReadWriteBarrier;
      N^.Free := 1;
      L := Nx;
    end;
    if MonoNowNs - T0 > Int64(300) * 1000000000 then
      Fail('MPSC test did not finish in 300 s');
  end;
  for I := 0 to MPSC_PRODUCERS - 1 do
  begin
    WaitForThreadTerminate(Th[I], 0);
    CloseThread(Th[I]);
  end;
  AssertEquals('out-of-order or lost nodes', 0, Bad);
  AssertEquals('received', Int64(MPSC_PRODUCERS) * MPSC_PER_PRODUCER, Received);
  for I := 0 to MPSC_PRODUCERS - 1 do
    AssertEquals('last seq of producer ' + IntToStr(I), MPSC_PER_PRODUCER, Last[I]);
  AssertEquals('one "was empty" push per non-empty batch', Batches, MPushEmpty);
  AssertTrue('stack empty at the end', MStack.IsEmpty);
  WriteLn(StdErr, Format('  [mpsc] %d x %d pushes, %d batches, %.2f s',
    [MPSC_PRODUCERS, MPSC_PER_PRODUCER, Batches, (MonoNowNs - T0) / 1e9]));
  for I := 0 to MPSC_PRODUCERS - 1 do
    MNodes[I] := nil;
end;

procedure TTestSync.Mpsc_takeall_returns_fifo;
var
  S: TMpscStack;
  N: array[0..9] of TMpscNode;
  L: PMpscNode;
  I: Integer;
begin
  S.Head := nil;
  AssertTrue(S.TakeAll = nil);
  AssertTrue('first push finds it empty', S.Push(@N[0]));
  for I := 1 to 9 do
    AssertFalse('later pushes do not', S.Push(@N[I]));
  L := S.TakeAll;
  for I := 0 to 9 do
  begin
    AssertTrue('FIFO order', L = @N[I]);
    L := L^.Next;
  end;
  AssertTrue(L = nil);
  AssertTrue(S.IsEmpty);
  AssertTrue('empty again', S.Push(@N[3]));
end;

var
  ParkA: TParker;
  ParkFlag: LongInt;

function UnparkLater(Arg: Pointer): PtrInt;
begin
  Sleep(30);
  InterlockedExchange(ParkFlag, 1);
  ParkA.Unpark;
  Result := 0;
end;

procedure TTestSync.Parker_unpark_before_and_after_park;
var
  T0: Int64;
  Th: TThreadID;
begin
  ParkA.State := 0;
  ParkA.Unpark;
  T0 := MonoNowNs;
  ParkA.Park;                       { notification already there: returns at once }
  AssertTrue('no wait', MonoNowNs - T0 < 10000000);
  AssertEquals('consumed', 0, ParkA.State);
  T0 := MonoNowNs;
  ParkA.Park(50);                   { times out }
  AssertTrue('timeout >= 50 ms', MonoNowNs - T0 >= 49000000);
  ParkFlag := 0;
  Th := BeginThread(@UnparkLater, nil);
  ParkA.Park;
  AssertEquals('woken by Unpark', 1, ParkFlag);
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
end;

var
  SLock: TSpinLock;
  SCount: Int64;

function SpinWorker(Arg: Pointer): PtrInt;
var
  I: Integer;
begin
  for I := 1 to 200000 do
  begin
    SLock.Acquire;
    SCount := SCount + 1;
    SLock.Release;
  end;
  Result := 0;
end;

procedure TTestSync.SpinLock_counts_under_contention;
var
  Th: array[0..7] of TThreadID;
  I: Integer;
begin
  SLock.State := 0;
  SCount := 0;
  for I := 0 to 7 do
    Th[I] := BeginThread(@SpinWorker, nil);
  for I := 0 to 7 do
  begin
    WaitForThreadTerminate(Th[I], 0);
    CloseThread(Th[I]);
  end;
  AssertEquals(Int64(8 * 200000), SCount);
end;

{ ---------------------------------------------------------- loop tasks ---- }

var
  Log: TStringList;
  ErrLog: TStringList;

procedure SilentLoopError(Loop: TLoop; Task: TLoopTask; E: Exception);
begin
  ErrLog.Add(E.Message);
end;

type
  TProbeKind = (pkLog, pkCloseOthers, pkRaiseFirst, pkYield, pkCloseLast, pkStopAfter);

  TProbe = class(TIoTask)
  public
    Name: string;
    Kind: TProbeKind;
    Runs: Integer;
    Others: array of TLoopTask;
    ReadyAtRun: TReadySet;
    procedure Run; override;
    procedure Abort; override;
    destructor Destroy; override;
  end;

var
  FirstRunDone: Boolean;
  StopAfterRuns: Integer;

procedure TProbe.Run;
var
  I: Integer;
begin
  Inc(Runs);
  ReadyAtRun := Src.Ready;
  Log.Add('run ' + Name + ' w' + IntToStr(Loop.Waits));
  case Kind of
    pkCloseOthers:
      if not FirstRunDone then
      begin
        FirstRunDone := True;
        for I := 0 to High(Others) do
          Others[I].Close;
      end;
    pkRaiseFirst:
      if not FirstRunDone then
      begin
        FirstRunDone := True;
        raise Exception.Create('boom ' + Name);
      end;
    pkYield:
      Wake;
    pkCloseLast:
      for I := 0 to High(Others) do
        Others[I].Close;
  end;
  if StopAfterRuns > 0 then
  begin
    Dec(StopAfterRuns);
    if StopAfterRuns = 0 then
      Loop.StopNow;
  end;
end;

procedure TProbe.Abort;
begin
  Log.Add('abort ' + Name);
end;

destructor TProbe.Destroy;
begin
  Log.Add('free ' + Name);
  inherited Destroy;
end;

{ A socket pair; the probe owns End0 (registered edge-triggered), the test
  writes to End1. }
function NewPairProbe(L: TLoop; const AName: string; AKind: TProbeKind; out Peer: cint): TProbe;
var
  Sv: array[0..1] of cint;
begin
  if fpsocketpair(AF_UNIX, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0, @Sv[0]) <> 0 then
    raise Exception.Create('socketpair failed');
  Result := TProbe.Create(L, Sv[0]);
  Result.Name := AName;
  Result.Kind := AKind;
  Peer := Sv[1];
  if not L.Register(@Result.Src, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET) then
    raise Exception.Create('register failed');
end;

function NewPlainProbe(L: TLoop; const AName: string; AKind: TProbeKind): TProbe;
begin
  Result := TProbe.Create(L, -1);
  Result.Name := AName;
  Result.Kind := AKind;
end;

procedure PokePeer(Fd: cint);
var
  B: Byte;
begin
  B := 1;
  fpWrite(Fd, @B, 1);      { EPIPE when the probe's end is already closed }
end;

var
  NoopMsg: TLoopMsg;

procedure NoopProc(Loop: TLoop; Arg: Pointer);
begin
end;

{ one iteration that does not block: a no-op message makes the timeout 0 }
procedure Tick(L: TLoop);
begin
  NoopMsg.Kind := lmCall;
  NoopMsg.Proc := @NoopProc;
  L.Post(@NoopMsg);
  L.RunIteration;
end;

{ drains the first events (EPOLLOUT of fresh sockets) with the probes in
  logging mode, so the next RunIteration sees only the events the test
  makes }
procedure SettleLoop(L: TLoop; const P: array of TProbe);
var
  I: Integer;
  K: array of TProbeKind;
begin
  SetLength(K, Length(P));
  for I := 0 to High(P) do
  begin
    K[I] := P[I].Kind;
    P[I].Kind := pkLog;
  end;
  Tick(L);
  for I := 0 to High(P) do
  begin
    P[I].Kind := K[I];
    P[I].Runs := 0;
  end;
  Log.Clear;
end;

procedure SafetyStopProc(T: PTimer);
begin
  TLoop(T^.Owner).StopNow;
end;

var
  SafetyTimer: TTimer;

{ a test that calls L.Run arms this so a regression fails instead of hanging }
procedure ArmSafetyStop(L: TLoop);
begin
  TimerInit(@SafetyTimer, @SafetyStopProc, L);
  L.Timers.Arm(@SafetyTimer, L.NowMs + 3000);
end;

procedure TTestLoop.SetUp;
begin
  Log.Clear;
  ErrLog.Clear;
  FirstRunDone := False;
  StopAfterRuns := 0;
  LoopErrorProc := @SilentLoopError;
end;

procedure TTestLoop.TearDown;
begin
  LoopErrorProc := nil;
end;

function LogIndex(const Prefix: string): Integer;
var
  I: Integer;
begin
  for I := 0 to Log.Count - 1 do
    if Copy(Log[I], 1, Length(Prefix)) = Prefix then
      Exit(I);
  Result := -1;
end;

function LogCount(const Prefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Log.Count - 1 do
    if Copy(Log[I], 1, Length(Prefix)) = Prefix then
      Inc(Result);
end;

{ ------------------------------------------------------------- tables ---- }

procedure TTestLoop.ReadyFromEpoll_table;
begin
  AssertTrue(ReadyFromEpoll(EPOLLIN) = [rdRead]);
  AssertTrue(ReadyFromEpoll(EPOLLOUT) = [rdWrite]);
  AssertTrue(ReadyFromEpoll(EPOLLIN or EPOLLOUT) = [rdRead, rdWrite]);
  AssertTrue('data + FIN', ReadyFromEpoll(EPOLLIN or EPOLLRDHUP) = [rdRead, rdReadClosed]);
  AssertTrue('RDHUP without IN is not read-closed', ReadyFromEpoll(EPOLLRDHUP) = []);
  AssertTrue(ReadyFromEpoll(EPOLLHUP) = [rdReadClosed, rdWriteClosed]);
  AssertTrue(ReadyFromEpoll(EPOLLIN or EPOLLOUT or EPOLLHUP or EPOLLERR or EPOLLRDHUP) =
    [rdRead, rdWrite, rdReadClosed, rdWriteClosed, rdError]);
  AssertTrue('OUT + ERR', ReadyFromEpoll(EPOLLOUT or EPOLLERR) = [rdWrite, rdWriteClosed, rdError]);
  AssertTrue('exactly ERR (mio is_write_closed)', ReadyFromEpoll(EPOLLERR) = [rdWriteClosed, rdError]);
  AssertTrue('IN + ERR', ReadyFromEpoll(EPOLLIN or EPOLLERR) = [rdRead, rdError]);
  AssertTrue('PRI is readable (mio)', ReadyFromEpoll(EPOLLPRI) = [rdRead]);
end;

procedure TTestLoop.BlockPool_classes_and_cap;
var
  P: TBlockPool;
  B, B2, Big: PBufBlock;
begin
  AssertEquals(0, PoolClassIndex(1));
  AssertEquals(0, PoolClassIndex(8192));
  AssertEquals(1, PoolClassIndex(8193));
  AssertEquals(7, PoolClassIndex(1024 * 1024));
  AssertEquals(-1, PoolClassIndex(1024 * 1024 + 1));
  P.Init(3 * 16384);
  B := P.Take(10000);
  AssertEquals('class size', 16384, B^.Size);
  AssertTrue('64-byte aligned', (PtrUInt(B^.Data) and 63) = 0);
  AssertTrue(B^.Pool = @P);
  FillChar(B^.Data^, B^.Size, 1);       { the whole class size is usable }
  P.Give(B);
  AssertEquals(16384, P.PooledBytes);
  B2 := P.Take(16000);
  AssertTrue('LIFO reuse', B2 = B);
  AssertEquals(0, P.PooledBytes);
  Big := P.Take(3 * 1024 * 1024);
  AssertEquals('heap block of the exact size', 3 * 1024 * 1024, Big^.Size);
  P.Give(Big);
  AssertEquals('large blocks are not pooled', 0, P.PooledBytes);
  P.Give(B2);
  P.Give(P.Take(16384 + 1));             { 32 KiB block: 16 + 32 = 48 KiB, at the cap }
  AssertEquals(16384 + 32768, P.PooledBytes);
  P.Give(P.Take(8192 * 3));              { 32 KiB: reuses the pooled one }
  B := P.Take(20000);                    { 32 KiB taken out ... }
  B2 := P.Take(20000);                   { ... and a new 32 KiB }
  P.Give(B);
  P.Give(B2);                            { above the cap: freed }
  AssertEquals(16384 + 32768, P.PooledBytes);
  AssertTrue('a block was released at the cap', P.Released >= 2);
  P.Done;
  AssertEquals(0, P.PooledBytes);
  AssertEquals('every block allocated was released', P.Allocated, P.Released);
end;

procedure TTestLoop.BlockPool_trim_frees_cold_blocks;
var
  P: TBlockPool;
  B: array[0..4] of PBufBlock;
  I: Integer;
begin
  P.Init(64 * 1024 * 1024);
  for I := 0 to 4 do
    B[I] := P.Take(8192);
  for I := 0 to 4 do
    P.Give(B[I]);
  P.Trim;                                { low-water was 0: nothing is cold yet }
  AssertEquals(5, P.Counts[0]);
  B[0] := P.Take(8192);
  B[1] := P.Take(8192);                  { low-water 3 }
  P.Give(B[1]);
  P.Give(B[0]);
  P.Trim;                                { 3 blocks unused in this interval: freed }
  AssertEquals(2, P.Counts[0]);
  AssertEquals(2 * 8192, P.PooledBytes);
  AssertTrue('the hot blocks are kept', (P.FreeLists[0] = B[0]) and (P.FreeLists[0]^.NextFree = B[1]));
  P.Trim;                                { idle interval: everything is cold }
  AssertEquals(0, P.Counts[0]);
  AssertEquals(0, P.PooledBytes);
  P.Done;
  AssertEquals(P.Allocated, P.Released);
end;

procedure TTestLoop.Conn_ids_per_loop;
var
  L: TLoop;
begin
  L := TLoop.Create(3);
  try
    AssertTrue(L.NextConnId = (QWord(3) shl 48 or 1));
    AssertTrue(L.NextConnId = (QWord(3) shl 48 or 2));
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------ cross-thread posts ---- }

const
  POST_PRODUCERS = 4;
  POST_PER_PRODUCER = 250000;
  POST_RING = 64;

type
  PPostMsg = ^TPostMsg;
  TPostMsg = record
    Msg: TLoopMsg;
    Producer: Integer;
    Seq: Integer;
    Done: LongInt;
  end;

var
  PostLoop: TLoop;
  PostMsgs: array[0..POST_PRODUCERS - 1, 0..POST_RING - 1] of TPostMsg;
  PostLast: array[0..POST_PRODUCERS - 1] of Integer;
  PostBad, PostReceived, PostLost: LongInt;
  PostGo: LongInt;

procedure PostProc(Loop: TLoop; Arg: Pointer);
var
  M: PPostMsg;
begin
  M := Arg;
  if M^.Seq <> PostLast[M^.Producer] + 1 then
    Inc(PostBad);
  PostLast[M^.Producer] := M^.Seq;
  Inc(PostReceived);
  ReadWriteBarrier;
  M^.Done := 1;
end;

procedure Pause(R: Integer);
var
  Ts: TTimeSpec;
  I: Integer;
begin
  case R mod 8 of
    0:
      begin
        Ts.tv_sec := 0;
        Ts.tv_nsec := 1000 + (R mod 97) * 1000;   { 1-97 us: the loop goes to sleep }
        fpNanoSleep(@Ts, nil);
      end;
    1: ThreadSwitch;
    2, 3:
      for I := 0 to R mod 3000 do
        CpuRelax;
  end;
end;

{$PUSH}{$Q-}{$R-}
function NextRand(var R: Cardinal): Cardinal; inline;
begin
  R := R * 1103515245 + 12345;
  Result := R;
end;
{$POP}

function PostProducer(Arg: Pointer): PtrInt;
var
  P, Seq: Integer;
  M: PPostMsg;
  Deadline: Int64;
  R: Cardinal;
begin
  P := PtrInt(Arg);
  R := 12345 + Cardinal(P) * 7919;
  while PostGo = 0 do
    CpuRelax;
  for Seq := 1 to POST_PER_PRODUCER do
  begin
    M := @PostMsgs[P, Seq mod POST_RING];
    if M^.Done = 0 then
    begin
      Deadline := MonoNowNs + Int64(10) * 1000000000;
      while M^.Done = 0 do
      begin
        ThreadSwitch;
        if MonoNowNs > Deadline then
        begin
          InterlockedIncrement(PostLost);     { a lost wakeup: the loop never ran it }
          Exit(1);
        end;
      end;
    end;
    M^.Done := 0;
    M^.Seq := Seq;
    PostLoop.Post(@M^.Msg);
    NextRand(R);
    if (R shr 16) mod 4 = 0 then
      Pause(Integer((R shr 8) mod 100000));
  end;
  Result := 0;
end;

procedure TTestLoop.Post_race_with_sleeping_loop;
var
  Th: array[0..POST_PRODUCERS - 1] of TThreadID;
  I, J: Integer;
  T0: Int64;
begin
  PostLoop := TLoop.Create(0);
  try
    for I := 0 to POST_PRODUCERS - 1 do
    begin
      PostLast[I] := 0;
      for J := 0 to POST_RING - 1 do
      begin
        PostMsgs[I, J].Msg.Kind := lmCall;
        PostMsgs[I, J].Msg.Proc := @PostProc;
        PostMsgs[I, J].Msg.Arg := @PostMsgs[I, J];
        PostMsgs[I, J].Producer := I;
        PostMsgs[I, J].Done := 1;
      end;
    end;
    PostBad := 0;
    PostReceived := 0;
    PostLost := 0;
    PostGo := 0;
    PostLoop.Start;
    for I := 0 to POST_PRODUCERS - 1 do
      Th[I] := BeginThread(@PostProducer, Pointer(PtrInt(I)));
    T0 := MonoNowNs;
    InterlockedExchange(PostGo, 1);
    for I := 0 to POST_PRODUCERS - 1 do
    begin
      WaitForThreadTerminate(Th[I], 0);
      CloseThread(Th[I]);
    end;
    { the last messages of each ring }
    while (PostReceived < POST_PRODUCERS * POST_PER_PRODUCER) and (PostLost = 0)
      and (MonoNowNs - T0 < Int64(60) * 1000000000) do
      Sleep(1);
    PostLoop.RequestStop;
    PostLoop.WaitFor;
    WriteLn(StdErr, Format('  [post] %d messages, %d epoll_waits, %d eventfd writes, %.2f s',
      [PostReceived, PostLoop.Waits, PostLoop.WakeWrites, (MonoNowNs - T0) / 1e9]));
    AssertEquals('lost wakeups (a producer waited 10 s)', 0, PostLost);
    AssertEquals('FIFO per producer', 0, PostBad);
    AssertEquals('every message ran', POST_PRODUCERS * POST_PER_PRODUCER, PostReceived);
    AssertTrue('the loop slept and was woken many times', PostLoop.WakeWrites > 1000);
    AssertTrue('fewer eventfd writes than posts', PostLoop.WakeWrites < POST_PRODUCERS * POST_PER_PRODUCER);
  finally
    PostLoop.Free;
    PostLoop := nil;
  end;
end;

var
  BusyRunning, BusyRelease: LongInt;
  BusyMsg: TLoopMsg;
  SmallMsgs: array[0..999] of TLoopMsg;
  SmallCount: LongInt;

procedure BusyProc(Loop: TLoop; Arg: Pointer);
begin
  InterlockedExchange(BusyRunning, 1);
  while BusyRelease = 0 do
    CpuRelax;
end;

procedure SmallProc(Loop: TLoop; Arg: Pointer);
begin
  InterlockedIncrement(SmallCount);
end;

procedure TTestLoop.Post_to_awake_loop_writes_no_eventfd;
var
  L: TLoop;
  I: Integer;
  W0: QWord;
  T0: Int64;
begin
  L := TLoop.Create(0);
  try
    BusyRunning := 0;
    BusyRelease := 0;
    SmallCount := 0;
    BusyMsg.Kind := lmCall;
    BusyMsg.Proc := @BusyProc;
    L.Start;
    Sleep(20);                              { the loop is asleep in epoll_wait }
    L.Post(@BusyMsg);
    while BusyRunning = 0 do
      ThreadSwitch;
    W0 := L.WakeWrites;
    AssertEquals('the first post woke the sleeping loop', 1, W0);
    for I := 0 to High(SmallMsgs) do
    begin
      SmallMsgs[I].Kind := lmCall;
      SmallMsgs[I].Proc := @SmallProc;
      L.Post(@SmallMsgs[I]);
    end;
    InterlockedExchange(BusyRelease, 1);
    T0 := MonoNowNs;
    while (SmallCount < Length(SmallMsgs)) and (MonoNowNs - T0 < Int64(5) * 1000000000) do
      ThreadSwitch;
    AssertEquals('all delivered', Length(SmallMsgs), SmallCount);
    AssertEquals('no eventfd write while the loop was awake', W0, L.WakeWrites);
    L.RequestStop;
    L.WaitFor;
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------------- F10 ---- }

procedure TTestLoop.F10_closed_task_skipped_and_freed_after_batch;
var
  L: TLoop;
  P: array[0..2] of TProbe;
  Peer: array[0..2] of cint;
  D: TProbe;
  I, First, IdxD: Integer;
  W: QWord;
begin
  L := TLoop.Create(0);
  try
    for I := 0 to 2 do
      P[I] := NewPairProbe(L, 'p' + IntToStr(I), pkCloseOthers, Peer[I]);
    for I := 0 to 2 do
    begin
      SetLength(P[I].Others, 2);
      P[I].Others[0] := P[(I + 1) mod 3];
      P[I].Others[1] := P[(I + 2) mod 3];
    end;
    SettleLoop(L, P);                       { initial EPOLLOUT events }
    FirstRunDone := False;
    Log.Clear;
    D := NewPlainProbe(L, 'D', pkLog);
    D.Wake;                                 { in the run queue: runs at step 6 }
    for I := 0 to 2 do
      PokePeer(Peer[I]);
    W := L.Waits;
    L.RunIteration;
    AssertEquals('one epoll_wait', W + 1, L.Waits);
    { exactly one probe ran; the two it closed were skipped }
    First := -1;
    for I := 0 to Log.Count - 1 do
      if Copy(Log[I], 1, 5) = 'run p' then
      begin
        AssertEquals('only one probe runs: ' + Log.CommaText, -1, First);
        First := StrToInt(Log[I][6]);
      end;
    AssertTrue('a probe ran', First >= 0);
    IdxD := LogIndex('run D');
    AssertTrue('D ran', IdxD >= 0);
    AssertEquals('two frees', 2, LogCount('free p'));
    for I := 0 to Log.Count - 1 do
      if Copy(Log[I], 1, 6) = 'free p' then
        AssertTrue('freed after the batch and the run queue: ' + Log.CommaText, I > IdxD);
    AssertEquals('not freed: the survivor', 0, LogCount('free p' + IntToStr(First)));
    P[First].Close;
    D.Close;
    Tick(L);
    for I := 0 to 2 do
      fpClose(Peer[I]);
  finally
    L.Free;
  end;
end;

procedure TTestLoop.F10_closed_task_in_run_queue_freed_after_leaving_it;
var
  L: TLoop;
  T: array[0..69] of TProbe;
  I: Integer;
begin
  L := TLoop.Create(0);
  try
    for I := 0 to 69 do
    begin
      T[I] := NewPlainProbe(L, 't' + IntToStr(I), pkLog);
      T[I].Wake;
    end;
    T[0].Kind := pkCloseLast;
    SetLength(T[0].Others, 1);
    T[0].Others[0] := T[69];                { beyond the 61-poll budget }
    L.RunIteration;
    AssertEquals('61 polls in the first iteration', 61, LogCount('run '));
    AssertEquals('t69 still queued: not freed yet', 0, LogCount('free t69'));
    AssertTrue(T[69].Closed and T[69].Queued);
    L.RunIteration;
    AssertEquals('t69 never ran', 0, LogCount('run t69'));
    AssertEquals('t69 freed once it left the queue', 1, LogCount('free t69'));
    AssertEquals('t61..t68 ran in the second iteration', 69, LogCount('run '));
    for I := 0 to 68 do
      T[I].Close;
    Tick(L);
    AssertEquals(70, LogCount('free '));
  finally
    L.Free;
  end;
end;

{ ---------------------------------------------------------- exceptions ---- }

procedure TTestLoop.Exception_aborts_task_and_resumes_batch;
var
  L: TLoop;
  P: array[0..2] of TProbe;
  Peer: array[0..2] of cint;
  I, Raised: Integer;
  W: QWord;
  Ws: TStringList;
begin
  L := TLoop.Create(0);
  Ws := TStringList.Create;
  try
    for I := 0 to 2 do
      P[I] := NewPairProbe(L, 'p' + IntToStr(I), pkRaiseFirst, Peer[I]);
    SettleLoop(L, P);
    FirstRunDone := False;
    Log.Clear;
    for I := 0 to 2 do
      PokePeer(Peer[I]);
    W := L.Waits;
    StopAfterRuns := 2;                     { the two probes that do not raise }
    ArmSafetyStop(L);
    L.Run;                                  { returns after StopNow }
    L.Timers.Remove(@SafetyTimer);
    AssertEquals('the batch was resumed without another epoll_wait: ' + Log.CommaText,
      W + 1, L.Waits);
    AssertEquals('one exception logged', 1, ErrLog.Count);
    AssertEquals('one task aborted', 1, L.Aborts);
    AssertEquals(1, LogCount('abort '));
    AssertEquals('three runs (one raised)', 3, LogCount('run '));
    for I := 0 to Log.Count - 1 do
      if Copy(Log[I], 1, 4) = 'run ' then
        Ws.Add(Copy(Log[I], Pos(' w', Log[I]) + 2, 20));
    for I := 1 to Ws.Count - 1 do
      AssertEquals('same epoll_wait batch', Ws[0], Ws[I]);
    Raised := -1;
    for I := 0 to 2 do
      if LogIndex('abort p' + IntToStr(I)) >= 0 then
        Raised := I;
    AssertTrue(Raised >= 0);
    AssertEquals('the aborted task was freed', 1, LogCount('free p' + IntToStr(Raised)));
    { the aborted task gets no more runs, the others keep working }
    Log.Clear;
    for I := 0 to 2 do
      PokePeer(Peer[I]);
    L.RunIteration;
    AssertEquals('only the two live probes run', 2, LogCount('run '));
    AssertEquals(0, LogCount('run p' + IntToStr(Raised)));
    for I := 0 to 2 do
      if I <> Raised then
        P[I].Close;
    Tick(L);
    for I := 0 to 2 do
      fpClose(Peer[I]);
  finally
    Ws.Free;
    L.Free;
  end;
end;

var
  ExMsgs: array[0..2] of TLoopMsg;

procedure ExMsgProc(Loop: TLoop; Arg: Pointer);
begin
  Log.Add('msg ' + IntToStr(PtrInt(Arg)));
  if PtrInt(Arg) = 1 then
    raise Exception.Create('message boom');
  if PtrInt(Arg) = 2 then
    Loop.StopNow;
end;

procedure TTestLoop.Exception_in_message_loses_no_message;
var
  L: TLoop;
  I: Integer;
begin
  L := TLoop.Create(0);
  try
    for I := 0 to 2 do
    begin
      ExMsgs[I].Kind := lmCall;
      ExMsgs[I].Proc := @ExMsgProc;
      ExMsgs[I].Arg := Pointer(PtrInt(I));
      L.Post(@ExMsgs[I]);
    end;
    ArmSafetyStop(L);
    L.Run;
    L.Timers.Remove(@SafetyTimer);
    AssertEquals(3, Log.Count);
    AssertEquals('msg 0', Log[0]);
    AssertEquals('msg 1', Log[1]);
    AssertEquals('msg 2', Log[2]);
    AssertEquals(1, ErrLog.Count);
    AssertEquals('no task to abort', 0, L.Aborts);
  finally
    L.Free;
  end;
end;

{ -------------------------------------------------------- run queue ---- }

procedure TTestLoop.Yield_goes_to_back_with_61_poll_budget;
var
  L: TLoop;
  A, B: TProbe;
  I: Integer;
begin
  L := TLoop.Create(0);
  try
    A := NewPlainProbe(L, 'A', pkYield);
    B := NewPlainProbe(L, 'B', pkYield);
    A.Wake;
    B.Wake;
    A.Wake;                                 { already queued: no effect }
    L.RunIteration;
    AssertEquals('61 polls per iteration', 61, Log.Count);
    for I := 0 to Log.Count - 1 do
      if I mod 2 = 0 then
        AssertEquals('alternating (yield to the back)', 'run A', Copy(Log[I], 1, 5))
      else
        AssertEquals('alternating (yield to the back)', 'run B', Copy(Log[I], 1, 5));
    AssertEquals(31, A.Runs);
    AssertEquals(30, B.Runs);
    AssertTrue('both still queued', A.Queued and B.Queued);
    Log.Clear;
    L.RunIteration;
    AssertEquals('B first now', 'run B', Copy(Log[0], 1, 5));
    A.Kind := pkLog;
    B.Kind := pkLog;
    L.RunIteration;
    A.Close;
    B.Close;
    Tick(L);
  finally
    L.Free;
  end;
end;

procedure TTestLoop.Event_for_queued_task_only_sets_readiness;
var
  L: TLoop;
  P: TProbe;
  Peer: cint;
begin
  L := TLoop.Create(0);
  try
    P := NewPairProbe(L, 'q', pkLog, Peer);
    SettleLoop(L, [P]);
    P.Src.Ready := [];
    Log.Clear;
    P.Runs := 0;
    P.Wake;
    PokePeer(Peer);
    L.RunIteration;
    AssertEquals('one run, from the run queue', 1, P.Runs);
    AssertTrue('the event set rdRead before that run', rdRead in P.ReadyAtRun);
    P.Close;
    Tick(L);
    fpClose(Peer);
  finally
    L.Free;
  end;
end;

{ -------------------------------------------------------------- timers ---- }

var
  TimerFiredNs: Int64;

procedure StopTimerProc(T: PTimer);
begin
  TimerFiredNs := MonoNowNs;
  TLoop(T^.Owner).StopNow;
end;

procedure TTestLoop.Timer_fires_in_loop;
var
  L: TLoop;
  T: TTimer;
  T0: Int64;
begin
  L := TLoop.Create(0);
  try
    TimerInit(@T, @StopTimerProc, L);
    T0 := MonoNowNs;
    L.Timers.Arm(@T, DeadlineToTick(T0 + 30 * 1000000));
    L.Run;
    AssertTrue('fired', T.Fired);
    AssertTrue(Format('not early (%d us)', [(TimerFiredNs - T0) div 1000]), TimerFiredNs - T0 >= 29000000);
    AssertTrue(Format('not late (%d us)', [(TimerFiredNs - T0) div 1000]), TimerFiredNs - T0 < 60000000);
  finally
    L.Free;
  end;
end;

procedure TTestLoop.Idle_loop_trims_block_pool;
var
  L: TLoop;
  B: array[0..3] of PBufBlock;
  I: Integer;
  T0: Int64;
begin
  L := TLoop.Create(0);
  try
    for I := 0 to 3 do
      B[I] := L.Blocks.Take(8192);
    for I := 0 to 3 do
      L.Blocks.Give(B[I]);
    AssertEquals(4 * 8192, L.Blocks.PooledBytes);
    L.Start;
    T0 := MonoNowNs;
    while (L.Blocks.PooledBytes > 0) and (MonoNowNs - T0 < Int64(5) * 1000000000) do
      Sleep(50);
    L.RequestStop;
    L.WaitFor;
    AssertEquals('idle loop returned its pooled blocks', 0, L.Blocks.PooledBytes);
    AssertTrue(Format('after about 2 s of idle (%d ms)', [(MonoNowNs - T0) div 1000000]),
      MonoNowNs - T0 >= Int64(1900) * 1000000);
    AssertTrue('trimmed at least twice', L.Trims >= 2);
  finally
    L.Free;
  end;
end;

var
  DateTicks: Integer;

procedure DateTickProc(T: PTimer);
var
  L: TLoop;
begin
  L := TLoop(T^.Owner);
  Inc(DateTicks);
  if DateTicks >= 25 then
    L.StopNow
  else
    L.Timers.Arm(T, L.NowMs + 97);
end;

procedure TTestLoop.Date_cache_follows_wall_clock;
var
  L: TLoop;
  T: TTimer;
  Fresh: TDateCache;
  Mism, Checks: Integer;
  A, B: RawByteString;
  Us: Int64;
begin
  L := TLoop.Create(0);
  try
    TimerInit(@T, @DateTickProc, L);
    DateTicks := 0;
    Mism := 0;
    Checks := 0;
    L.Timers.Arm(@T, L.NowMs + 97);
    while not L.Stopped do
    begin
      L.RunIteration;
      A := LoopDateCache(L)^.AsString;
      Us := RealNowUs;
      Fresh.Update(Us);
      B := Fresh.AsString;
      Inc(Checks);
      if A <> B then
      begin
        { only possible when a second boundary fell between the loop's
          clock sample and this check }
        Fresh.Update(Us - 5000);
        if Fresh.AsString <> A then
          Inc(Mism);
      end;
    end;
    AssertTrue('ran across a second boundary', DateTicks >= 25);
    AssertEquals(Format('stale dates in %d checks', [Checks]), 0, Mism);
  finally
    L.Free;
  end;
end;

begin
  Log := TStringList.Create;
  ErrLog := TStringList.Create;
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));   { as the server does (1.4) }
  RegisterTest(TTestSync);
  RegisterTest(TTestLoop);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  Log.Free;
  ErrLog.Free;
end.
