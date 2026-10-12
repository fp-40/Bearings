{ M3 step S7 tests: bearings.rt.workers and the worker parts of bearings.http.exchange
  (design m3-transport.md 1.7, 3.2.3, 3.3-3.6, 7.3 "Exchange" and
  "Channel", 9 S7).

  TTestPool: FIFO order, hooks, shutdown finishes the queue, an item that
  raises does not end its worker, the default thread count, QueueLength /
  Saturated, a Shutdown that times out.
  TTestParkRaces: TParker ping-pong between two threads (no lost wakeup),
  unparks before a park, unparks racing with a timed park.
  TTestOffload: the exchange driven the way the dispatcher drives it, on a
  real TLoop run by the test thread, with a real worker pool: an answer from
  a worker; cancel at every point (queued, running, parked in Read, parked
  in Write, both with the answer taken and not taken); a worker reading the
  body (100-continue want, Read / ReadChunk / ReadAll, the body error, the
  "connection error" of PollCatch that only a worker can observe); the
  ToRelease hand-back under a stress run (pins never above Held + Item +
  2 hand-backs + head, all back to 0); the stream writer (backpressure,
  frame boundaries, trailers, the end when the last producer released
  without Finish); handler exceptions; Share / Release balance under 16
  threads (the exchange reaches its pool exactly once); a wake queued when
  the last reference goes (the recycle waits for it, the owner is not
  woken).
  TTestWorkerServer: TServer with a worker pool over real sockets: offloaded
  GET, a 200 000-byte request body echoed, a chunked body with trailers, 16
  pipelined offloaded requests, a streamed response, a client that leaves
  while the handler sleeps (the handler sees the cancel), a handler that
  raises, and Stop with the pool shut down; a server destroyed while a
  worker still runs (every exchange recycled and freed).

  S7 fix (the S7 verifier's findings and surviving mutants, deviations
  S7-16..S7-21): a stale Release after the recycle leaves the next
  request's stream alone (ReleaseTestHook widens the window); the stream
  ends only with its last producer; a first frame above HighWater; two
  producers blocked in Write on one channel; a refused second Finish keeps
  the first one's trailers; a cancel keeps the chunk a worker holds pinned;
  Offload on a stopped pool; a head the worker released is unpinned when
  its wake arrives; ReadAll's limit on a chunked body; one WakeMsg while
  queued; the burst behind a spinning worker runs in parallel; the debug
  checks of 3.2.4 (loop-thread assertions, 0xDD head views, Wake on a
  recycled exchange). Off-loop actions of these tests run on the test
  pool's workers (RunOnPool), not on raw threads (drd, deviation S7-21).

  The worker stress tests run under valgrind --tool=drd in run_all.sh
  (built with -dWD_DRD; WD_ITER scales the loop counts down there).
  Run: test_workers --all --format=plain }
program test_workers;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  { -dWD_DRD (the drd runs): the C heap, which valgrind replaces with its
    own and drd tracks (a freed block starts a new access history). FPC's
    own heap hands blocks between threads through lock-free lists drd cannot
    see, so a block freed by one thread and reused by another gave false
    conflicts (S7 fix; deviation S1-9 asks the same for memcheck) }
  {$IFDEF WD_DRD}cmem,{$ENDIF}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix, ctypes,
  bearings.rt.sys, bearings.rt.sync, bearings.rt.clock, bearings.rt.cpu, bearings.rt.buf, bearings.rt.timer, bearings.rt.loop,
  bearings.rt.workers, bearings.http.headers, bearings.http1.parser, bearings.http1.role, bearings.http1.decode,
  bearings.http.error, bearings.http.exchange, bearings.server;

const
  CRLF = #13#10;

var
  { loop counts are multiplied by this (WD_ITER, percent; the drd run lowers it) }
  IterPct: Integer = 100;

function Iters(N: Integer): Integer;
begin
  Result := (N * IterPct) div 100;
  if Result < 1 then
    Result := 1;
end;

{ ============================ pool ============================ }

type
  TTestPool = class(TTestCase)
  published
    procedure Fifo_order_with_one_worker;
    procedure Hooks_and_shutdown_finish_the_queue;
    procedure Item_exception_does_not_end_the_worker;
    procedure Default_thread_count;
    procedure Queue_length_and_saturated;
    procedure Shutdown_wait_times_out;
    procedure Spin_then_park_loses_no_item;
    procedure Burst_behind_a_spinner_runs_in_parallel;
  end;

  TRecItem = class(TWorkItem)
  public
    Id: Integer;
    procedure Execute; override;
  end;

  TRaiseItem = class(TWorkItem)
  public
    procedure Execute; override;
  end;

  TGateItem = class(TWorkItem)
  public
    Gate: PRTLEvent;
    Started: LongInt;
    procedure Execute; override;
  end;

  { waits until Want items run at the same time (or 2 s) }
  TMeetItem = class(TWorkItem)
  public
    procedure Execute; override;
  end;

  TCountHooks = class(TWorkerHooks)
  public
    Started, Stopping: LongInt;
    Mask: LongInt;
    procedure ThreadStarted(Index: Integer); override;
    procedure ThreadStopping(Index: Integer); override;
  end;

var
  RecOrder: array of Integer;
  RecCount: LongInt;

procedure TRecItem.Execute;
var
  I: LongInt;
begin
  I := InterLockedIncrement(RecCount) - 1;
  if I <= High(RecOrder) then
    RecOrder[I] := Id;
end;

procedure TRaiseItem.Execute;
begin
  raise Exception.Create('test: item raises');
end;

procedure TGateItem.Execute;
begin
  InterLockedExchange(Started, 1);
  RTLEventWaitFor(Gate);
end;

var
  MeetRunning, MeetMet, MeetDone: LongInt;

procedure TMeetItem.Execute;
var
  T0: Int64;
begin
  InterLockedIncrement(MeetRunning);
  T0 := MonoNowNs;
  while (AtomicLoad(MeetRunning) < 4) and (MonoNowNs - T0 < 2000000000) do
    Sleep(1);
  if AtomicLoad(MeetRunning) >= 4 then
    InterLockedIncrement(MeetMet);
  HappensBefore(@MeetDone);
  InterLockedIncrement(MeetDone);
end;

procedure TCountHooks.ThreadStarted(Index: Integer);
var
  Old: LongInt;
begin
  InterLockedIncrement(Started);
  repeat
    Old := Mask;
  until InterlockedCompareExchange(Mask, Old or (1 shl Index), Old) = Old;
end;

procedure TCountHooks.ThreadStopping(Index: Integer);
begin
  InterLockedIncrement(Stopping);
end;

procedure TTestPool.Fifo_order_with_one_worker;
var
  P: TWorkerPool;
  Items: array of TRecItem;
  I, N: Integer;
begin
  N := Iters(500);
  SetLength(RecOrder, N);
  RecCount := 0;
  SetLength(Items, N);
  P := TWorkerPool.Create(1);
  try
    for I := 0 to N - 1 do
    begin
      Items[I] := TRecItem.Create;
      Items[I].Id := I;
      P.Submit(Items[I]);
    end;
    P.Shutdown(-1);
    AssertEquals('all executed', N, RecCount);
    AssertEquals('Executed', N, P.Executed);
    for I := 0 to N - 1 do
      AssertEquals('FIFO', I, RecOrder[I]);
  finally
    P.Free;
    for I := 0 to N - 1 do
      Items[I].Free;
  end;
end;

procedure TTestPool.Hooks_and_shutdown_finish_the_queue;
var
  P: TWorkerPool;
  H: TCountHooks;
  Items: array of TRecItem;
  I, N: Integer;
  Raised: Boolean;
begin
  N := Iters(2000);
  SetLength(RecOrder, N);
  RecCount := 0;
  SetLength(Items, N);
  H := TCountHooks.Create;
  P := TWorkerPool.Create(4, H);
  try
    AssertEquals('line 181', 4, P.ThreadCount);
    for I := 0 to N - 1 do
    begin
      Items[I] := TRecItem.Create;
      P.Submit(Items[I]);
    end;
    P.Shutdown(-1);
    AssertEquals('every queued item ran before the threads exited', N, RecCount);
    AssertEquals('ThreadStarted per thread', 4, H.Started);
    AssertEquals('one index each', 15, H.Mask);
    AssertEquals('ThreadStopping per thread', 4, H.Stopping);
    AssertEquals('no thread left', 0, P.Alive);
    Raised := False;
    try
      P.Submit(Items[0]);
    except
      on EWorkerPoolStopped do
        Raised := True;
    end;
    AssertTrue('Submit after Shutdown raises', Raised);
  finally
    P.Free;
    H.Free;
    for I := 0 to N - 1 do
      Items[I].Free;
  end;
end;

procedure TTestPool.Item_exception_does_not_end_the_worker;
var
  P: TWorkerPool;
  R: TRaiseItem;
  A, B: TRecItem;
begin
  SetLength(RecOrder, 2);
  RecCount := 0;
  R := TRaiseItem.Create;
  A := TRecItem.Create;
  B := TRecItem.Create;
  A.Id := 1;
  B.Id := 2;
  P := TWorkerPool.Create(1);
  try
    P.Submit(A);
    P.Submit(R);
    P.Submit(B);
    P.Shutdown(-1);
    AssertEquals('the items after the one that raised ran', 2, RecCount);
    AssertEquals('line 229', 1, RecOrder[0]);
    AssertEquals('line 230', 2, RecOrder[1]);
    AssertEquals('Executed counts the raising item', 3, P.Executed);
  finally
    P.Free;
    R.Free;
    A.Free;
    B.Free;
  end;
end;

procedure TTestPool.Default_thread_count;
var
  P: TWorkerPool;
  Want: Integer;
begin
  Want := DefaultLoopCount + 4;
  if Want > 32 then
    Want := 32;
  P := TWorkerPool.Create(0);
  try
    AssertEquals('Min(32, DefaultLoopCount + 4)', Want, P.ThreadCount);
  finally
    P.Free;
  end;
end;

procedure TTestPool.Queue_length_and_saturated;
var
  P: TWorkerPool;
  G: TGateItem;
  Items: array[0..2] of TRecItem;
  I: Integer;
begin
  SetLength(RecOrder, 3);
  RecCount := 0;
  G := TGateItem.Create;
  G.Gate := RTLEventCreate;
  for I := 0 to 2 do
    Items[I] := TRecItem.Create;
  P := TWorkerPool.Create(1, nil, 2);
  try
    P.Submit(G);
    while AtomicLoad(G.Started) = 0 do
      Sleep(1);
    AssertEquals('line 274', 0, P.QueueLength);
    AssertFalse('line 275', P.Saturated);
    P.Submit(Items[0]);
    AssertEquals('line 277', 1, P.QueueLength);
    AssertFalse('below the limit', P.Saturated);
    P.Submit(Items[1]);
    AssertEquals('line 280', 2, P.QueueLength);
    AssertTrue('at QueueLimit', P.Saturated);
    P.Submit(Items[2]);                    { Submit itself never refuses }
    AssertEquals('line 283', 3, P.QueueLength);
    RTLEventSetEvent(G.Gate);
    P.Shutdown(-1);
    AssertEquals('line 286', 0, P.QueueLength);
    AssertEquals('line 287', 3, RecCount);
  finally
    P.Free;
    RTLEventDestroy(G.Gate);
    G.Free;
    for I := 0 to 2 do
      Items[I].Free;
  end;
end;

procedure BusyWaitNs(Ns: Int64);
var
  T0: Int64;
begin
  T0 := MonoNowNs;
  while MonoNowNs - T0 < Ns do
    CpuRelax;
end;

procedure TTestPool.Spin_then_park_loses_no_item;
var
  P: TWorkerPool;
  Items: array of TRecItem;
  I, N, Round: Integer;
  T0: Int64;
begin
  { items arrive 0-60 us apart, around the 20 us spin: some reach a spinning
    worker (no wake), some a parked one (wake), some the moment the spinner
    gives up; every item must run without waiting for a later Submit (no
    Shutdown here: a lost wakeup leaves the last items queued) }
  for Round := 0 to 1 do
  begin
    N := Iters(3000);
    SetLength(RecOrder, N);
    RecCount := 0;
    SetLength(Items, N);
    P := TWorkerPool.Create(3);
    try
      if Round = 1 then
        P.SpinNs := 0;
      for I := 0 to N - 1 do
      begin
        Items[I] := TRecItem.Create;
        Items[I].Id := I;
        BusyWaitNs((I * 7919) mod 60000);
        P.Submit(Items[I]);
      end;
      T0 := MonoNowNs;
      while (AtomicLoad(RecCount) < N) and (MonoNowNs - T0 < 2000000000) do
        Sleep(1);
      AssertEquals('every item ran without a later Submit (spin ' + IntToStr(P.SpinNs) + ' ns)',
        N, AtomicLoad(RecCount));
      P.Shutdown(-1);
    finally
      P.Free;
      for I := 0 to N - 1 do
        Items[I].Free;
    end;
  end;
end;

procedure TTestPool.Burst_behind_a_spinner_runs_in_parallel;
var
  P: TWorkerPool;
  Items: array[0..3] of TMeetItem;
  I, R: Integer;
  T0: Int64;
begin
  { S7 verifier mutant v-pop-no-chain-wake: while one worker spins on the
    queue, Submit wakes nobody; when the spinner takes the first item of a
    burst, it must wake a parked worker for the rest (and each worker the
    next), or the burst runs on one worker. 4 workers, 4 items that each
    wait until all 4 run. Repeated: the burst must be queued before the
    spinner takes its first item for the rule to matter. }
  P := TWorkerPool.Create(4);
  try
    P.SpinNs := 1000000000;            { the spinner keeps spinning during the burst }
    for R := 1 to 5 do
    begin
      Sleep(50);                       { three workers parked, one spinning }
      InterLockedExchange(MeetRunning, 0);
      InterLockedExchange(MeetMet, 0);
      InterLockedExchange(MeetDone, 0);
      for I := 0 to 3 do
        Items[I] := TMeetItem.Create;
      for I := 0 to 3 do
        P.Submit(Items[I]);
      T0 := MonoNowNs;
      while (AtomicLoad(MeetDone) < 4) and (MonoNowNs - T0 < 10000000000) do
        Sleep(1);
      HappensAfter(@MeetDone);
      AssertEquals('round ' + IntToStr(R) + ': every item ran', 4, AtomicLoad(MeetDone));
      for I := 0 to 3 do
        Items[I].Free;
      AssertEquals('round ' + IntToStr(R) + ': the 4 items ran at the same time', 4,
        AtomicLoad(MeetMet));
    end;
  finally
    P.SpinNs := 0;
    P.Shutdown(5000);
    P.Free;
  end;
end;

procedure TTestPool.Shutdown_wait_times_out;
var
  P: TWorkerPool;
  G: TGateItem;
  T0: Int64;
begin
  G := TGateItem.Create;
  G.Gate := RTLEventCreate;
  P := TWorkerPool.Create(2);
  try
    P.Submit(G);
    while AtomicLoad(G.Started) = 0 do
      Sleep(1);
    T0 := MonoNowNs;
    P.Shutdown(50);
    AssertTrue('waited about 50 ms', MonoNowNs - T0 >= 45000000);
    AssertEquals('the busy worker is still running', 1, P.Alive);
    RTLEventSetEvent(G.Gate);
    P.Shutdown(-1);
    AssertEquals('line 316', 0, P.Alive);
  finally
    P.Free;
    RTLEventDestroy(G.Gate);
    G.Free;
  end;
end;

{ ============================ parker races ============================ }

type
  TTestParkRaces = class(TTestCase)
  published
    procedure Ping_pong_has_no_lost_wakeup;
    procedure Unpark_at_park_entry;
    procedure Unparks_before_park_wake_once;
    procedure Unpark_races_with_timed_park;
  end;

var
  PA, PB: TParker;
  PongTimeouts: LongInt;
  PongRounds: Integer;

function PongThread(Arg: Pointer): PtrInt;
var
  I: Integer;
  T0: Int64;
begin
  for I := 1 to PongRounds do
  begin
    T0 := MonoNowNs;
    PB.Park(2000);
    if MonoNowNs - T0 >= 1900000000 then
      InterLockedIncrement(PongTimeouts);
    PA.Unpark;
  end;
  Result := 0;
end;

procedure TTestParkRaces.Ping_pong_has_no_lost_wakeup;
var
  Th: TThreadID;
  I: Integer;
  T0: Int64;
begin
  PA.State := 0;
  PB.State := 0;
  PongTimeouts := 0;
  PongRounds := Iters(50000);
  Th := BeginThread(@PongThread, nil);
  for I := 1 to PongRounds do
  begin
    PB.Unpark;
    T0 := MonoNowNs;
    PA.Park(2000);
    if MonoNowNs - T0 >= 1900000000 then
      InterLockedIncrement(PongTimeouts);
  end;
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  AssertEquals('no park waited for its timeout (a lost wakeup)', 0, PongTimeouts);
  AssertEquals('A consumed', 0, PA.State);
  AssertEquals('B consumed', 0, PB.State);
end;

var
  EntryRound, EntryLost, EntryDummy: LongInt;
  EntryRounds: Integer;
  { diagnostics of the first long park: when the round began, when the
    other thread started and returned from its Unpark, when Park returned }
  EntryBase: Int64;                  { set before the thread starts }
  EntryUnparkStart, EntryUnparkDone: LongInt;   { us after EntryBase }
  EntryInfo: string;

function EntryUs: LongInt;
begin
  Result := LongInt((MonoNowNs - EntryBase) div 1000);
end;

function EntryParker(Arg: Pointer): PtrInt;
var
  I, J: Integer;
  T0: Int64;
  S0, U0, U1: LongInt;
begin
  for I := 1 to EntryRounds do
  begin
    T0 := MonoNowNs;
    InterLockedExchange(EntryRound, I);
    { a delay of 0..511 loads (a few ns per step) before Park: the other
      thread's Unpark, made as soon as it sees the round, lands at a
      different point of Park's entry in each round }
    for J := 1 to I mod 512 do
      if AtomicLoad(EntryDummy) = -1 then
        Break;
    PB.Park(1000);
    if MonoNowNs - T0 >= 900000000 then
    begin
      if EntryInfo = '' then
      begin
        S0 := LongInt((T0 - EntryBase) div 1000);
        U0 := AtomicLoad(EntryUnparkStart) - S0;
        U1 := AtomicLoad(EntryUnparkDone) - S0;
        EntryInfo := Format('(round %d: Park returned %d ms after the round began; the other thread''s ' +
          'last Unpark started at %d ms and returned at %d ms of the round, negative: before it)',
          [I, (EntryUs - S0) div 1000, U0 div 1000, U1 div 1000]);
      end;
      if InterLockedIncrement(EntryLost) >= 2 then
        Break;
    end;
    PA.Unpark;
  end;
  InterLockedExchange(EntryRound, -1);
  PA.Unpark;
  Result := 0;
end;

procedure TTestParkRaces.Unpark_at_park_entry;
var
  Th: TThreadID;
  I: Integer;
begin
  { the Unpark lands while the other thread is entering Park: the parker
    announces the round, waits 0..511 loads and parks; the unparker unparks
    as soon as it sees the round, so some rounds hit the instructions
    between Park's first CAS and its announce CAS (mutant
    park-loses-notification: an Unpark there is overwritten and the park
    sleeps until its timeout). A lost wakeup costs 1 s; the parker stops
    after 2 }
  PA.State := 0;
  PB.State := 0;
  EntryLost := 0;
  EntryRound := 0;
  EntryBase := MonoNowNs;
  EntryUnparkStart := -1000000000;
  EntryUnparkDone := -1000000000;
  EntryInfo := '';
  EntryRounds := Iters(200000);
  Th := BeginThread(@EntryParker, nil);
  for I := 1 to EntryRounds do
  begin
    while (AtomicLoad(EntryRound) <> I) and (AtomicLoad(EntryRound) >= 0) do
      CpuRelax;
    if AtomicLoad(EntryRound) < 0 then
      Break;
    AtomicStore(EntryUnparkStart, EntryUs);
    PB.Unpark;
    AtomicStore(EntryUnparkDone, EntryUs);
    PA.Park(5000);
  end;
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  AssertEquals('no park waited for its timeout (a lost wakeup) ' + EntryInfo, 0, AtomicLoad(EntryLost));
end;

procedure TTestParkRaces.Unparks_before_park_wake_once;
var
  T0: Int64;
begin
  PA.State := 0;
  PA.Unpark;
  PA.Unpark;
  PA.Unpark;
  T0 := MonoNowNs;
  PA.Park(1000);
  AssertTrue('returns at once', MonoNowNs - T0 < 100000000);
  T0 := MonoNowNs;
  PA.Park(30);
  AssertTrue('one notification only: the second park times out', MonoNowNs - T0 >= 29000000);
  AssertEquals('line 395', 0, PA.State);
end;

var
  RaceStop: LongInt;
  RaceUnparks: LongInt;

function RaceUnparker(Arg: Pointer): PtrInt;
begin
  while RaceStop = 0 do
  begin
    PA.Unpark;
    InterLockedIncrement(RaceUnparks);
    if (RaceUnparks and 7) = 0 then
      Sleep(0);
  end;
  Result := 0;
end;

procedure TTestParkRaces.Unpark_races_with_timed_park;
var
  Th: TThreadID;
  I, Woken: Integer;
  T0: Int64;
begin
  { timed parks (0-1 ms) while another thread unparks continuously: the
    state is never stuck at 2 (parked) after Park returned }
  PA.State := 0;
  RaceStop := 0;
  RaceUnparks := 0;
  Woken := 0;
  Th := BeginThread(@RaceUnparker, nil);
  for I := 1 to Iters(20000) do
  begin
    T0 := MonoNowNs;
    PA.Park(I mod 2);
    if MonoNowNs - T0 < 500000 then
      Inc(Woken);
    AssertTrue('state after Park is 0 or 1', AtomicLoad(PA.State) <= 1);
  end;
  InterLockedExchange(RaceStop, 1);
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  PA.State := 0;
  PA.Unpark;
  T0 := MonoNowNs;
  PA.Park(1000);
  AssertTrue('a later notification still wakes at once', MonoNowNs - T0 < 100000000);
  AssertTrue('most parks were woken by the unparker', Woken > 0);
end;

{ ============================ offload (exchange + loop + pool) ============================ }

type
  TOwnerTask = class(TLoopTask)
  public
    Runs: Integer;
    procedure Run; override;
    procedure Abort; override;
  end;

  THandlerMode = (hmRespond, hmWaitThenRespond, hmReadBody, hmReadAll, hmRead, hmStream,
    hmStreamNoFinish, hmRaise, hmRaiseAfterStream, hmNoAnswer, hmCopy,
    hmStreamWaitNoFinish, hmReadHold, hmReleaseWait,
    hmFail, hmRespondWaitRead, hmStreamOneThenWait,
    { S7 fix round 4 (decisions 15 and 16, the third S7 verifier's findings) }
    hmRespondThenRead, hmStreamEcho, hmRespondNoRead, hmRespondCounted, hmStreamCounted,
    hmBeginStreamOnly, hmHeadThenWait,
    { S7 fix round 5 (the fourth S7 verifiers' findings) }
    hmHeadAfterGate, hmReadPath,
    { S7 fix round 6 (the fifth S7 verifiers' findings) }
    hmGateRespondCounted,
    { S7 fix round 7 (the sixth S7 verifiers' findings) }
    hmWriteNoBegin);

  { records what happened on the worker; the test thread asserts }
  TRecHandler = class(TBlockingHandler)
  public
    Mode: THandlerMode;
    Gate: PRTLEvent;                 { hmWaitThenRespond: waits for it }
    Started, Finished: LongInt;
    CanceledAtStart, CanceledAtEnd: Boolean;
    RespondResult, FailResult: Boolean;
    TryReadAtStart: TBodyReadStatus;
    Body: RawByteString;
    Got: TStringList;                { hmReadBody: chunks }
    ErrClass: string;
    ErrKind: TBodyErrorKind;
    WriteResults: array of TWriteResult;
    StreamFrames, FrameLen: Integer;
    HighWater: SizeInt;
    WritingAt: LongInt;              { index of the Write in progress }
    FinishResult: Boolean;
    Ready: LongInt;                  { hmStreamWaitNoFinish / hmReadHold / hmReleaseWait: at the gate }
    HeldCopy: RawByteString;         { hmReadHold: the chunk as it was read }
    Intact: Boolean;                 { hmReadHold: the held chunk's bytes after the gate }
    TryReadLate: TBodyReadStatus;    { hmRespondWaitRead: TryRead after the gate }
    Gate2: PRTLEvent;                { hmStreamOneThenWait: the second gate }
    LateHeadRaised: Boolean;         { hmHeadThenWait: a head write after the answer asserted }
    constructor Create(AMode: THandlerMode);
    destructor Destroy; override;
    procedure Run(Ex: TExchange); override;
  end;

  TCond = function: Boolean of object;

  TWCase = class(TTestCase)
  protected
    FLoop: TLoop;
    FPool: TExchangePool;
    FWork: TWorkerPool;
    FTask: TOwnerTask;
    FBuf: TReadBuf;
    FTick: TTimer;
    FEx: TExchange;
    FH: TRecHandler;
    FCall: TOffloadCall;
    FFree0: Integer;
    FBlocks: array of PBufBlock;
    procedure SetUp; override;
    procedure TearDown; override;
    procedure Drive;
    function Until_(C: TCond; Ms: Integer): Boolean;
    function NewEx(const Req: RawByteString): TExchange;
    function View(const S: RawByteString): TBytesView;
    function PinsLive: Integer;
    procedure StartOffload(AMode: THandlerMode);
    procedure FinishExchange;        { CompleteCall (if answered) + ReleaseTransport, then recycled }
    { conditions }
    function CondAnswered: Boolean;
    function CondStarted: Boolean;
    function CondFinished: Boolean;
    function CondRecycled: Boolean;
    function CondWoken: Boolean;
    function CondParkedInRead: Boolean;
    function CondWritingSecond: Boolean;
    function CondReady: Boolean;
    function CondNoPins: Boolean;
    function CondHookIn: Boolean;
    function CondHookOut: Boolean;
    function CondRef2: Boolean;
    function CondChanReady: Boolean;
    function CondReady2: Boolean;
    function CondRef1: Boolean;
    function CondAbaIn: Boolean;
  end;

  TTestOffload = class(TWCase)
  published
    procedure Answer_from_worker;
    procedure Cancel_while_queued;
    procedure Cancel_while_running;
    procedure Cancel_while_parked_in_read;
    procedure Cancel_while_parked_in_write_taken;
    procedure Cancel_while_parked_in_write_not_taken;
    procedure Worker_reads_body_with_continue;
    procedure Worker_read_and_read_all;
    procedure Body_error_raises_body_error;
    procedure Connection_error_reaches_worker;
    procedure To_release_hand_back_stress;
    procedure Stream_backpressure_frames_and_trailers;
    procedure Stream_ends_when_last_producer_releases;
    procedure Handler_exception_and_no_answer_fail;
    procedure Exception_after_stream_aborts_body;
    procedure Body_copy_on_worker_uses_heap;
    procedure Share_release_balance_16_threads;
    procedure Wake_queued_at_last_release_delays_recycle;
    procedure Blocking_read_on_loop_thread_raises;
    { S7 fix tests (the S7 verifier's findings and surviving mutants) }
    procedure Release_after_recycle_leaves_the_new_stream;
    procedure Stream_two_producers_one_releases;
    procedure Stream_first_frame_above_high_water;
    procedure Stream_two_blocked_producers;
    procedure Second_finish_leaves_the_trailers;
    procedure Cancel_keeps_the_chunk_a_worker_holds;
    procedure Offload_on_a_stopped_pool;
    procedure Released_head_unpinned_on_wake;
    procedure Read_all_limit_without_content_length;
    procedure Wake_posts_one_message_while_queued;
    procedure Debug_checks_and_poison;
    { second S7 fix (S7-23, S7-24: the second S7 verifier's findings and surviving mutants) }
    procedure Cancel_before_the_read_takes_the_lock;
    procedure Concurrent_terminal_calls_leave_the_winner;
    procedure Complete_keeps_body_and_transport_release_detaches;
    procedure Cancel_releases_the_untaken_item;
    procedure Stream_frame_wakes_the_waiting_consumer;
    { S7 fix round 4: decision 15 (the request lives until the handler releases it), the third
      S7 verifier's findings (V3_*: a worker parked in a body read after its answer), its
      surviving mutants B, C, D (take-back branches, BeginStream's claim), decisions 16, 17 }
    procedure V3_complete_while_parked_in_read;
    procedure V3_stream_then_read_parked;
    procedure Cancel_after_answer_while_parked_in_read;
    procedure Connection_gone_after_answer_while_parked;
    procedure Last_release_drops_the_request;
    procedure Respond_take_back_releases_the_body;
    procedure Stream_take_back_calls_done;
    procedure Begin_stream_claims_before_the_channel;
    procedure Head_built_by_one_thread;
    procedure Terminal_call_by_another_thread_than_the_head;
    procedure Debug_loop_only_and_wake_generation;
    { S7 fix round 5: the fourth S7 verifiers' findings (race, contract, gate lenses) }
    procedure Head_write_after_cancel_is_legal;
    procedure Second_holder_release_request_unparks_the_reader;
    procedure Cancel_lost_with_complete_body_keeps_the_chunk;
    procedure Stale_cancel_does_not_end_the_next_request;
    procedure Share_during_the_call_keeps_the_request;
    procedure Share_after_the_last_holder_raises;
    procedure Release_leaving_another_holder_keeps_the_request;
    { S7 fix round 6: the fifth S7 verifiers' findings (race, contract lenses) }
    procedure Empty_write_after_the_stream_ended;
    procedure Reset_and_abort_race_keeps_the_message_counts;
    procedure Claim_refused_by_the_head_check_lets_the_job_answer;
    procedure Job_error_path_exception_releases_the_reference;
    procedure Read_after_the_request_was_dropped_is_not_the_end;
    procedure Read_after_the_end_and_release_is_the_end;
    { S7 fix round 7: the sixth S7 verifiers' findings (race, contract lenses) }
    procedure Last_producer_is_decided_at_the_holder_decrement;
    procedure Call_in_flight_keeps_the_stream_for_its_next_producer;
    procedure Inline_stream_without_finish_ends_at_completion;
    procedure Second_offload_raises;
    procedure Post_counts_the_poster_before_the_push;
  end;

procedure TOwnerTask.Run;
begin
  Inc(Runs);
end;

procedure TOwnerTask.Abort;
begin
end;

constructor TRecHandler.Create(AMode: THandlerMode);
begin
  inherited Create;
  Mode := AMode;
  Got := TStringList.Create;
  StreamFrames := 10;
  FrameLen := 32;
  HighWater := 64;
  WritingAt := -1;
end;

destructor TRecHandler.Destroy;
begin
  Got.Free;
  inherited Destroy;
end;

function FrameText(I, Len: Integer): RawByteString;
begin
  Result := Format('frame %.4d ', [I]);
  while Length(Result) < Len do
    Result := Result + AnsiChar(Ord('a') + (I mod 26));
  SetLength(Result, Len);
end;

{ a body and a source that count their release (the take-back branches of
  the shared terminal calls, S7-23; the third S7 verifier's mutants B, C) }
var
  CountedReleases, CountedDones: LongInt;
  CountedByte: Byte = 7;

procedure CountedRelease(Ctx: Pointer; Data: PByte);
begin
  InterLockedIncrement(CountedReleases);
end;

function CountedBody: TBodyData;
begin
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.P := @CountedByte;
  Result.Len := 1;
  Result.Own := boCustom;
  Result.ReleaseProc := @CountedRelease;
end;

type
  TCountedSource = class(TBodySource)
  public
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

function TCountedSource.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
begin
  Data := BodyEmpty;
  Trailers := nil;
  Result := fpEnd;
end;

procedure TCountedSource.Done(Ex: TExchange);
begin
  InterLockedIncrement(CountedDones);
end;

var
  CountedSource: TCountedSource;

procedure TRecHandler.Run(Ex: TExchange);
var
  C: TByteSlice;
  S: RawByteString;
  Buf: array[0..6] of Byte;
  N: SizeInt;
  Dst: TBytes;
  I: Integer;
  W: TWriteResult;
  Tr: THttpHeaders;
  B: TBodyData;
begin
  InterLockedExchange(Started, 1);
  try
  try
    CanceledAtStart := Ex.IsCanceled;
    case Mode of
      hmRespond:
        begin
          TryReadAtStart := Ex.TryRead(C);
          Ex.Status := 201;
          Ex.ResponseHeaders.Add('x-worker', 'yes');
          RespondResult := Ex.Respond(BodyString('from worker'));
          { after the answer: refused, and the response slot is left alone }
          FailResult := Ex.Fail('after the answer');
        end;
      hmWaitThenRespond:
        begin
          RTLEventWaitFor(Gate);
          CanceledAtEnd := Ex.IsCanceled;
          RespondResult := Ex.Respond(BodyString('late'));
          FailResult := Ex.Fail('late');
          TryReadAtStart := Ex.TryRead(C);
        end;
      hmReadBody:
        begin
          try
            while Ex.ReadChunk(C) do
            begin
              SetString(S, PAnsiChar(C.P), C.Len);
              Got.Add(S);
              Body := Body + S;
            end;
            RespondResult := Ex.Respond(BodyString(Body));
          except
            on E: Exception do
            begin
              ErrClass := E.ClassName;
              CanceledAtEnd := Ex.IsCanceled;
              if E is EBodyError then
                ErrKind := EBodyError(E).Kind;
            end;
          end;
        end;
      hmRead:
        begin
          repeat
            N := Ex.Read(@Buf[0], SizeOf(Buf));
            if N > 0 then
            begin
              SetString(S, PAnsiChar(@Buf[0]), N);
              Got.Add(S);
              Body := Body + S;
            end;
          until N = 0;
          RespondResult := Ex.Respond(BodyEmpty);
        end;
      hmReadAll:
        begin
          Dst := nil;
          try
            N := Ex.ReadAll(Dst, 10);
            SetString(Body, PAnsiChar(@Dst[0]), N);
          except
            on E: Exception do
              ErrClass := E.ClassName;
          end;
          RespondResult := Ex.Respond(BodyEmpty);
        end;
      hmStream, hmStreamNoFinish, hmRaiseAfterStream:
        begin
          Ex.ResponseHeaders.Add('content-type', 'text/plain');
          RespondResult := Ex.BeginStream(HighWater);
          SetLength(WriteResults, StreamFrames);
          for I := 0 to StreamFrames - 1 do
          begin
            InterLockedExchange(WritingAt, I);
            S := FrameText(I, FrameLen);
            if I mod 2 = 0 then
              W := Ex.Write(PByte(Pointer(S)), Length(S))
            else
              W := Ex.WriteString(S);
            WriteResults[I] := W;
            if W <> wrOk then
              Break;
          end;
          if Mode = hmRaiseAfterStream then
            raise Exception.Create('after stream');
          if Mode = hmStream then
          begin
            Tr := THttpHeaders.Create;
            try
              Tr.Add('x-t', '1');
              FinishResult := Ex.Finish(Tr);
            finally
              Tr.Free;
            end;
          end;
        end;
      hmRaise:
        raise EConvertError.Create('boom');
      hmNoAnswer:
        ;
      hmStreamWaitNoFinish:
        begin
          RespondResult := Ex.BeginStream(HighWater);
          SetLength(WriteResults, StreamFrames);
          for I := 0 to StreamFrames - 1 do
            WriteResults[I] := Ex.WriteString(FrameText(I, FrameLen));
          InterLockedExchange(Ready, 1);
          RTLEventWaitFor(Gate);
        end;
      hmReadHold:
        begin
          if Ex.ReadChunk(C) then
          begin
            SetString(HeldCopy, PAnsiChar(C.P), C.Len);
            InterLockedExchange(Ready, 1);
            RTLEventWaitFor(Gate);
            { the view is still the worker's: its bytes did not change }
            Intact := (C.Len = Length(HeldCopy)) and (CompareByte(C.P^, HeldCopy[1], C.Len) = 0);
            Ex.ReadChunk(C);                 { the cancel: EClientGone }
          end;
        end;
      hmReleaseWait:
        begin
          Ex.ReleaseRequest;
          InterLockedExchange(Ready, 1);
          RTLEventWaitFor(Gate);
          RespondResult := Ex.Respond(BodyEmpty);
        end;
      hmFail:
        FailResult := Ex.Fail('from worker');
      hmRespondWaitRead:
        begin
          { answers without reading the body, waits, then reads and drops
            the request (its ReleaseRequest wakes the loop) }
          RespondResult := Ex.Respond(BodyEmpty);
          InterLockedExchange(Ready, 1);
          RTLEventWaitFor(Gate);
          TryReadLate := Ex.TryRead(C);
          Ex.ReleaseRequest;
        end;
      hmStreamOneThenWait:
        begin
          RespondResult := Ex.BeginStream(HighWater);
          SetLength(WriteResults, 1);
          InterLockedExchange(Ready, 1);
          RTLEventWaitFor(Gate);
          WriteResults[0] := Ex.WriteString(FrameText(0, FrameLen));
          InterLockedExchange(Ready, 2);
          RTLEventWaitFor(Gate2);
          FinishResult := Ex.Finish(nil);
        end;
      hmRespondThenRead, hmStreamEcho:
        begin
          { answers first, then reads the body (decision 15); the echo
            writes each chunk to its stream as it reads it }
          if Mode = hmRespondThenRead then
            RespondResult := Ex.Respond(BodyEmpty)
          else
            RespondResult := Ex.BeginStream(HighWater);
          InterLockedExchange(Ready, 1);
          try
            while Ex.ReadChunk(C) do
            begin
              SetString(S, PAnsiChar(C.P), C.Len);
              Got.Add(S);
              if Mode = hmStreamEcho then
                Ex.WriteString(S);
            end;
            TryReadLate := brEnd;
            if Mode = hmStreamEcho then
              FinishResult := Ex.Finish(nil);
          except
            on E: Exception do
            begin
              ErrClass := E.ClassName;
              if Mode = hmStreamEcho then
                Ex.AbortStream('read failed');
            end;
          end;
        end;
      hmRespondNoRead:
        { answers and returns: no read, no ReleaseRequest }
        RespondResult := Ex.Respond(BodyEmpty);
      hmRespondCounted:
        RespondResult := Ex.Respond(CountedBody);
      hmStreamCounted:
        RespondResult := Ex.RespondStream(CountedSource);
      hmBeginStreamOnly:
        begin
          RespondResult := Ex.BeginStream(HighWater);
          SetLength(WriteResults, 1);
          WriteResults[0] := Ex.WriteString('from the worker''s stream');
          FinishResult := Ex.Finish(nil);
        end;
      hmHeadThenWait:
        begin
          { decision 16: this thread builds the head and answers }
          Ex.Status := 202;
          Ex.ResponseHeaders.Add('x-built-by', 'worker');
          InterLockedExchange(Ready, 1);
          RTLEventWaitFor(Gate);
          RespondResult := Ex.Respond(BodyEmpty);
          try
            Ex.Status := 500;
          except
            on E: EAssertionFailed do
              LateHeadRaised := True;
          end;
        end;
      hmHeadAfterGate:
        begin
          { decision 16: this thread builds the head and makes the terminal
            call; the loop's cancel may come at any time before it }
          RTLEventWaitFor(Gate);
          try
            Ex.Status := 503;
          except
            on E: EAssertionFailed do
              LateHeadRaised := True;
          end;
          RespondResult := Ex.Respond(BodyEmpty);
        end;
      hmGateRespondCounted:
        begin
          { the loop writes the head meanwhile (a program error that the
            decision-16 check reports at this Respond) }
          RTLEventWaitFor(Gate);
          RespondResult := Ex.Respond(CountedBody);
        end;
      hmWriteNoBegin:
        begin
          { another producer of a stream the call began: frames, no Finish }
          SetLength(WriteResults, StreamFrames);
          for I := 0 to StreamFrames - 1 do
            WriteResults[I] := Ex.WriteString(FrameText(I, FrameLen));
        end;
      hmReadPath:
        begin
          C := Ex.Path;
          SetString(Body, PAnsiChar(C.P), C.Len);
          RespondResult := Ex.Respond(BodyEmpty);
        end;
      hmCopy:
        begin
          S := 'copied on a worker';
          B := BodyCopy(Ex, PByte(Pointer(S)), Length(S));
          RespondResult := Ex.Respond(B);
        end;
    end;
  except
    on E: EClientGone do
    begin
      ErrClass := E.ClassName;
      CanceledAtEnd := Ex.IsCanceled;
      RespondResult := Ex.Respond(BodyEmpty);
    end;
  end;
  finally
    HappensBefore(@Finished);
    InterLockedExchange(Finished, 1);
  end;
end;

procedure TickProc(T: PTimer);
begin
end;

procedure TWCase.SetUp;
begin
  { WD_TRACE=1: the test's name on stderr, so drd's reports can be matched
    to the test that was running }
  if GetEnvironmentVariable('WD_TRACE') <> '' then
  begin
    WriteLn(StdErr, '### test ', TestName);
    Flush(StdErr);
  end;
  FLoop := TLoop.Create(0);
  FPool := TExchangePool.Create;
  FLoop.Exchanges := FPool;
  FWork := TWorkerPool.Create(2);
  FTask := TOwnerTask.Create;
  FTask.Loop := FLoop;
  FBuf := Default(TReadBuf);
  TimerInit(@FTick, @TickProc, nil);
  FEx := nil;
  FH := nil;
  FCall := nil;
  FBlocks := nil;
end;

procedure FreeFuncItems; forward;

procedure TWCase.TearDown;
begin
  FWork.Shutdown(5000);
  { S7 fix round 7: a test's Release hook goes once the pool's threads were
    joined }
  if Assigned(ReleaseBeforeDecrementHook) then
    ReleaseBeforeDecrementHook := nil;
  FreeFuncItems;
  FLoop.ProcessInbox;
  FWork.Free;
  FLoop.Timers.Remove(@FTick);
  FCall.Free;
  FH.Free;
  FPool.Free;
  FBuf.Done;
  FLoop.Free;
  FTask.Free;
end;

procedure TWCase.Drive;
begin
  { one loop iteration; the tick timer bounds epoll_wait to 2 ms }
  FLoop.Timers.Arm(@FTick, FLoop.NowMs + 2);
  FLoop.RunIteration;
end;

function TWCase.Until_(C: TCond; Ms: Integer): Boolean;
var
  Deadline: Int64;
begin
  Deadline := MonoNowNs + Int64(Ms) * 1000000;
  while not C() do
  begin
    if MonoNowNs > Deadline then
      Exit(False);
    Drive;
  end;
  Result := True;
end;

function TWCase.View(const S: RawByteString): TBytesView;
var
  I: Integer;
  Known: Boolean;
begin
  FBuf.Reserve(Length(S), @FLoop.Blocks);
  Move(S[1], FBuf.SpareData^, Length(S));
  FBuf.AdvanceMut(Length(S));
  Result := FBuf.SplitTo(Length(S));
  Known := False;
  for I := 0 to High(FBlocks) do
    if FBlocks[I] = Result.Block then
      Known := True;
  if not Known then
  begin
    SetLength(FBlocks, Length(FBlocks) + 1);
    FBlocks[High(FBlocks)] := Result.Block;
  end;
end;

function TWCase.PinsLive: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FBlocks) do
    Inc(Result, FBlocks[I]^.Pins);
end;

function TWCase.NewEx(const Req: RawByteString): TExchange;
var
  Msg: TParsedRequestHead;
  V: TBytesView;
begin
  Result := FPool.Take(FLoop);
  FBuf.Reserve(Length(Req), @FLoop.Blocks);
  Move(Req[1], FBuf.SpareData^, Length(Req));
  FBuf.AdvanceMut(Length(Req));
  AssertTrue('parse', ServerParse(FBuf.Ptr, FBuf.Len, DefaultParseContext, Result.Head.Headers, Msg)
    = spsComplete);
  V := FBuf.SplitTo(Msg.HeadLen);
  SetLength(FBlocks, Length(FBlocks) + 1);
  FBlocks[High(FBlocks)] := V.Block;
  Result.BeginRequest(FTask);
  Result.FillHead(Msg, V, 1);
  if Msg.Decode <> DECODED_LENGTH_ZERO then
    Result.Chan.Open(Msg.ExpectContinue);
  FFree0 := FPool.FreeCount;
end;

procedure TWCase.StartOffload(AMode: THandlerMode);
begin
  if FH = nil then
    FH := TRecHandler.Create(AMode);
  FCall := TOffloadCall.Create;
  FCall.Pool := FWork;
  FCall.Handler := FH;
  AssertTrue('first poll: Pending', FCall.Poll(FEx) = cpPending);
  AssertTrue('offloaded', FEx.Offloaded);
  AssertTrue('shared', FEx.Shared);
end;

procedure TWCase.FinishExchange;
begin
  if FEx.Answered and (FEx.Resp.Source = nil) then
    ReleaseBody(FEx.Resp.Body);
  FEx.ReleaseTransport;
  AssertTrue('recycled into the loop pool', Until_(@CondRecycled, 5000));
  { exactly once: nothing else arrives }
  Drive;
  Drive;
  AssertEquals('given to the pool once', FFree0 + 1, FPool.FreeCount);
  AssertEquals('every pin back', 0, PinsLive);
  FEx := nil;
end;

function TWCase.CondAnswered: Boolean;
begin
  Result := FEx.Answered;
end;

function TWCase.CondStarted: Boolean;
begin
  Result := AtomicLoad(FH.Started) <> 0;
end;

function TWCase.CondFinished: Boolean;
begin
  { the handler's fields are read after this returned True }
  Result := AtomicLoad(FH.Finished) <> 0;
  if Result then
    HappensAfter(@FH.Finished);
end;

function TWCase.CondRecycled: Boolean;
begin
  Result := FPool.FreeCount > FFree0;
end;

function TWCase.CondWoken: Boolean;
begin
  Result := FTask.Runs > 0;
end;

function TWCase.CondParkedInRead: Boolean;
begin
  Result := AtomicLoad(FEx.Chan.Parker.State) = 2;
end;

function TWCase.CondWritingSecond: Boolean;
begin
  Result := AtomicLoad(FH.WritingAt) >= 1;
end;

function TWCase.CondReady: Boolean;
begin
  Result := AtomicLoad(FH.Ready) <> 0;
end;

function TWCase.CondNoPins: Boolean;
begin
  Result := PinsLive = 0;
end;

procedure TTestOffload.Answer_from_worker;
var
  S: RawByteString;
  R: LongInt;
begin
  FEx := NewEx('GET /a HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmRespond);
  { the worker may already have run the handler and released its reference
    (it releases after Run returned, so Finished is set by then; seen under
    drd with other processes on the CPUs) }
  R := FEx.RefCount;
  AssertTrue('transport + worker (got ' + IntToStr(R) + ')',
    (R = 2) or ((R = 1) and CondFinished));
  AssertTrue('the worker answers and the connection is woken through the inbox',
    Until_(@CondWoken, 5000));
  AssertTrue('line 875', Until_(@CondAnswered, 5000));
  AssertTrue('later poll: ready', FCall.Poll(FEx) = cpReady);
  AssertTrue('handler finished', Until_(@CondFinished, 5000));
  AssertTrue('line 877', FH.RespondResult);
  AssertFalse('a Fail after the answer is refused', FH.FailResult);
  AssertFalse('line 878', FH.CanceledAtStart);
  AssertTrue('no body: end', FH.TryReadAtStart = brEnd);
  FEx.CompleteCall;
  AssertEquals('line 881', 201, FEx.Status);
  AssertEquals('x-worker', FEx.ResponseHeaders.Name(0));
  SetString(S, PAnsiChar(FEx.Resp.Body.P), FEx.Resp.Body.Len);
  AssertEquals('from worker', S);
  AssertFalse('the refused Fail left the slot alone', FEx.Resp.Failed);
  AssertEquals('', FEx.Resp.FailText);
  AssertTrue('line 885', Until_(@CondFinished, 5000));
  FinishExchange;
end;

procedure TTestOffload.Cancel_while_queued;
var
  One: TWorkerPool;
  G: TGateItem;
begin
  { the only worker is busy: the exchange stays queued while the connection
    abandons the call }
  G := TGateItem.Create;
  G.Gate := RTLEventCreate;
  One := TWorkerPool.Create(1);
  try
    One.Submit(G);
    while AtomicLoad(G.Started) = 0 do
      Sleep(1);
    FEx := NewEx('GET /q HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    FH := TRecHandler.Create(hmRespond);
    FCall := TOffloadCall.Create;
    FCall.Pool := One;
    FCall.Handler := FH;
    AssertTrue('line 908', FCall.Poll(FEx) = cpPending);
    AssertEquals('queued', 1, One.QueueLength);
    FEx.Cancel;
    AssertTrue('line 911', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    AssertEquals('the worker still holds it', FFree0, FPool.FreeCount);
    RTLEventSetEvent(G.Gate);
    AssertTrue('line 916', Until_(@CondFinished, 5000));
    AssertTrue('the handler sees the cancel', FH.CanceledAtStart);
    AssertFalse('its answer is refused', FH.RespondResult);
    AssertTrue('the body reports the cancel', FH.TryReadAtStart = brCanceled);
    AssertTrue('line 920', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('recycled once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('line 923', 0, PinsLive);
    AssertEquals('the owner was never woken after the cancel', 0, FTask.Runs);
    FEx := nil;
  finally
    One.Shutdown(5000);
    FLoop.ProcessInbox;
    One.Free;
    RTLEventDestroy(G.Gate);
    G.Free;
  end;
end;

procedure TTestOffload.Cancel_while_running;
begin
  FH := TRecHandler.Create(hmWaitThenRespond);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /r HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmWaitThenRespond);
    AssertTrue('line 942', Until_(@CondStarted, 5000));
    FEx.Cancel;
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    RTLEventSetEvent(FH.Gate);
    AssertTrue('line 947', Until_(@CondFinished, 5000));
    AssertFalse('line 948', FH.CanceledAtStart);
    AssertTrue('line 949', FH.CanceledAtEnd);
    AssertFalse('Respond refused', FH.RespondResult);
    AssertFalse('Fail refused', FH.FailResult);
    AssertTrue('line 952', FH.TryReadAtStart = brCanceled);
    AssertTrue('line 953', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('line 955', FFree0 + 1, FPool.FreeCount);
    AssertEquals('line 956', 0, PinsLive);
    AssertEquals('no wake reaches the abandoned owner', 0, FTask.Runs);
    FEx := nil;
  finally
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Cancel_while_parked_in_read;
var
  Closed: Boolean;
begin
  FEx := NewEx('POST /p HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  StartOffload(hmReadBody);
  { one chunk arrives, then nothing: the worker parks in ReadChunk }
  AssertTrue('line 971', FEx.Chan.PollReady(Closed));
  AssertFalse('line 972', Closed);
  AssertTrue('line 973', FEx.Chan.TrySendData(View('hello')));
  AssertTrue('parked in ReadChunk', Until_(@CondParkedInRead, 5000));
  FEx.Cancel;
  FCall.Drop(FEx, False);
  FEx.Chan.SendError(NewIncomplete);          { DropAll: the body sender goes }
  FEx.Chan.CloseSender;
  FEx.ReleaseTransport;
  AssertTrue('line 982', Until_(@CondFinished, 5000));
  AssertEquals('the parked read raised', 'EClientGone', FH.ErrClass);
  AssertEquals('the chunk arrived', 1, FH.Got.Count);
  AssertEquals('hello', FH.Got[0]);
  AssertTrue('line 984', FH.CanceledAtEnd);
  AssertTrue('line 985', Until_(@CondRecycled, 5000));
  Drive;
  AssertEquals('line 987', FFree0 + 1, FPool.FreeCount);
  AssertEquals('the chunk the worker held is unpinned at the recycle', 0, PinsLive);
  FEx := nil;
end;

procedure TTestOffload.Cancel_while_parked_in_write_taken;
var
  Src: TBodySource;
begin
  FH := TRecHandler.Create(hmStreamNoFinish);
  FH.HighWater := 32;
  FH.FrameLen := 32;
  FH.StreamFrames := 5;
  FEx := NewEx('GET /w HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmStreamNoFinish);
  AssertTrue('line 1002', Until_(@CondAnswered, 5000));
  AssertTrue('line 1003', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  { the dispatcher takes the body (TakeResponseBody) and does not poll it }
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  AssertTrue('the second write is in progress', Until_(@CondWritingSecond, 5000));
  Sleep(30);
  AssertEquals('the first frame queued, the second parked', 0, FH.Finished);
  { the connection ends: ClearBodyRx drops the source }
  Src.Done(FEx);
  AssertTrue('line 1014', Until_(@CondFinished, 5000));
  AssertTrue('first frame', FH.WriteResults[0] = wrOk);
  AssertTrue('the parked write is canceled', FH.WriteResults[1] = wrCanceled);
  FEx.ReleaseTransport;
  AssertTrue('line 1018', Until_(@CondRecycled, 5000));
  Drive;
  AssertEquals('line 1020', FFree0 + 1, FPool.FreeCount);
  FEx := nil;
end;

procedure TTestOffload.Cancel_while_parked_in_write_not_taken;
begin
  { the worker answered (BeginStream) but the connection ended before the
    dispatcher took the answer: the cancel loses, the transport's release
    drops the untaken stream }
  FH := TRecHandler.Create(hmStreamNoFinish);
  FH.HighWater := 32;
  FH.FrameLen := 32;
  FH.StreamFrames := 5;
  FEx := NewEx('GET /w HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmStreamNoFinish);
  AssertTrue('line 1035', Until_(@CondWritingSecond, 5000));
  Sleep(30);
  FEx.Cancel;
  AssertFalse('the answer won', FEx.IsCanceled);
  FCall.Drop(FEx, False);
  FEx.ReleaseTransport;
  AssertTrue('line 1041', Until_(@CondFinished, 5000));
  AssertTrue('line 1042', FH.WriteResults[0] = wrOk);
  AssertTrue('the parked write is canceled', FH.WriteResults[1] = wrCanceled);
  AssertTrue('line 1044', Until_(@CondRecycled, 5000));
  Drive;
  AssertEquals('line 1046', FFree0 + 1, FPool.FreeCount);
  FEx := nil;
end;

procedure TTestOffload.Worker_reads_body_with_continue;
var
  Closed: Boolean;
  I, J: Integer;
const
  Parts: array[0..2] of RawByteString = ('abc', 'defg', 'hij');
begin
  FEx := NewEx('POST /c HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Expect: 100-continue' + CRLF
    + 'Content-Length: 10' + CRLF + CRLF);
  { want starts False (Expect): the sender waits for the handler's first read }
  AssertFalse('no 100 before the handler reads', FEx.Chan.PollReady(Closed));
  StartOffload(hmReadBody);
  AssertTrue('the first read wakes the sender through the inbox', Until_(@CondWoken, 5000));
  for I := 0 to 2 do
  begin
    { a wake may come before the take that makes the channel ready (wakes
      can be spurious: the handler's first read wakes the sender too); the
      sender polls again after each wake, and a missing wake fails here }
    J := 0;
    while True do
    begin
      FTask.Runs := 0;
      if FEx.Chan.PollReady(Closed) then
        Break;
      AssertTrue('the take wakes the sender', Until_(@CondWoken, 5000));
      Inc(J);
      AssertTrue('ready after at most 3 wakes', J <= 3);
    end;
    AssertFalse('line 1069', Closed);
    AssertTrue('line 1070', FEx.Chan.TrySendData(View(Parts[I])));
  end;
  FEx.Chan.CloseSender;
  AssertTrue('line 1073', Until_(@CondAnswered, 5000));
  AssertTrue('line 1074', FCall.Poll(FEx) = cpReady);
  FEx.CompleteCall;
  AssertTrue('handler finished', Until_(@CondFinished, 5000));
  AssertEquals('abcdefghij', FH.Body);
  AssertEquals('line 1077', 3, FH.Got.Count);
  AssertEquals('', FH.ErrClass);
  AssertTrue('line 1079', Until_(@CondFinished, 5000));
  FinishExchange;
end;

procedure TTestOffload.Worker_read_and_read_all;
var
  Closed: Boolean;
begin
  { Read with a 7-byte buffer over chunks of 12 and 9 bytes: a chunk is
    copied out in pieces (the rest of a chunk comes from where the last Read
    stopped), and a Read never spans two chunks }
  FEx := NewEx('POST /r HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 21' + CRLF + CRLF);
  StartOffload(hmRead);
  AssertTrue('line 1090', FEx.Chan.PollReady(Closed));
  AssertTrue('line 1091', FEx.Chan.TrySendData(View('hello brave ')));
  FTask.Runs := 0;
  Until_(@CondWoken, 2000);
  AssertTrue('line 1094', FEx.Chan.PollReady(Closed));
  AssertTrue('line 1095', FEx.Chan.TrySendData(View('new world')));
  FEx.Chan.CloseSender;
  AssertTrue('line 1097', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertTrue('handler finished', Until_(@CondFinished, 5000));
  AssertEquals('hello brave new world', FH.Body);
  AssertEquals('Read pieces', 'hello b|rave |new wor|ld', StringReplace(Trim(FH.Got.Text),
    LineEnding, '|', [rfReplaceAll]));
  AssertTrue('line 1100', Until_(@CondFinished, 5000));
  FinishExchange;
  { ReadAll over the limit: EBodyTooLarge before reading (Content-Length) }
  FreeAndNil(FCall);
  FreeAndNil(FH);
  FEx := NewEx('POST /r HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 11' + CRLF + CRLF);
  StartOffload(hmReadAll);
  AssertTrue('line 1107', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertTrue('handler finished', Until_(@CondFinished, 5000));
  AssertEquals('EBodyTooLarge', FH.ErrClass);
  AssertTrue('line 1110', Until_(@CondFinished, 5000));
  FEx.Chan.CloseSender;
  FinishExchange;
end;

procedure TTestOffload.Body_error_raises_body_error;
var
  Closed: Boolean;
begin
  FEx := NewEx('POST /e HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Transfer-Encoding: chunked'
    + CRLF + CRLF);
  StartOffload(hmReadBody);
  AssertTrue('line 1122', FEx.Chan.PollReady(Closed));
  FEx.Chan.SendError(NewBodyDecode(deInvalidSize));
  FEx.Chan.CloseSender;
  AssertTrue('line 1125', Until_(@CondFinished, 5000));
  AssertEquals('EBodyError', FH.ErrClass);
  AssertTrue('SPEC 7.1 kind', FH.ErrKind = bekInvalidInput);
  AssertTrue('the job fails a handler that gave no answer', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertTrue('line 1130', FEx.Resp.Failed);
  AssertEquals('handler returned no response', FEx.Resp.FailText);
  FinishExchange;
end;

procedure TTestOffload.Connection_error_reaches_worker;
var
  Closed: Boolean;
begin
  { PollCatch: a connection error while the body is read reaches the
    receiver as "connection error" (an equivalent mutant for the inline
    service, design 7.3 conn-diff README; observable with a worker) }
  FEx := NewEx('POST /e HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  StartOffload(hmReadBody);
  AssertTrue('line 1144', FEx.Chan.PollReady(Closed));
  AssertTrue('line 1145', Until_(@CondParkedInRead, 5000));
  FEx.Chan.SendError(NewBodyStatic('connection error'));
  FEx.Chan.CloseSender;
  AssertTrue('line 1148', Until_(@CondFinished, 5000));
  AssertEquals('EBodyError', FH.ErrClass);
  AssertTrue('kind other', FH.ErrKind = bekOther);
  AssertTrue('line 1151', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  FinishExchange;
end;

procedure TTestOffload.To_release_hand_back_stress;
var
  Closed: Boolean;
  I, N, MaxPins, P: Integer;
  S, All: RawByteString;
  Deadline: Int64;
begin
  { many chunks, the worker reading as fast as it can, the loop filling the
    slot whenever PollReady allows: the views the worker drops come back
    through ToRelease / ToRelease2; never more than head + Item + Held + 2
    pinned, and all of them back at the end }
  N := Iters(3000);
  All := '';
  for I := 0 to N - 1 do
    All := All + FrameText(I, 3 + I mod 13);
  FEx := NewEx('POST /s HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: '
    + IntToStr(Length(All)) + CRLF + CRLF);
  StartOffload(hmReadBody);
  MaxPins := 0;
  I := 0;
  Deadline := MonoNowNs + 60000000000;
  while I < N do
  begin
    AssertTrue('progress', MonoNowNs < Deadline);
    if FEx.Chan.PollReady(Closed) then
    begin
      AssertFalse('line 1182', Closed);
      S := FrameText(I, 3 + I mod 13);
      AssertTrue('line 1184', FEx.Chan.TrySendData(View(S)));
      Inc(I);
      P := PinsLive;
      if P > MaxPins then
        MaxPins := P;
    end
    else
      Drive;
  end;
  FEx.Chan.CloseSender;
  AssertTrue('line 1194', Until_(@CondAnswered, 60000));
  FEx.CompleteCall;
  AssertTrue('handler finished', Until_(@CondFinished, 60000));
  AssertEquals('every byte, in order', All, FH.Body);
  AssertEquals('line 1197', N, FH.Got.Count);
  AssertTrue('pins bounded (head + item + held + 2 hand-backs): ' + IntToStr(MaxPins),
    MaxPins <= 5);
  AssertTrue('line 1200', Until_(@CondFinished, 5000));
  FinishExchange;
end;

procedure TTestOffload.Stream_backpressure_frames_and_trailers;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  Frames: Integer;
  S: RawByteString;
  Deadline: Int64;
  SawTrailers, Pending: Boolean;
begin
  FH := TRecHandler.Create(hmStream);
  FH.StreamFrames := Iters(400);
  FH.FrameLen := 32;
  FH.HighWater := 64;
  FEx := NewEx('GET /s HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmStream);
  AssertTrue('line 1221', Until_(@CondAnswered, 5000));
  AssertTrue('line 1222', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  AssertTrue('BeginStream answers with the channel', Src is TChannelBody);
  Frames := 0;
  SawTrailers := False;
  Pending := False;
  Deadline := MonoNowNs + 60000000000;
  while True do
  begin
    AssertTrue('progress', MonoNowNs < Deadline);
    AssertTrue('never more than HighWater queued', TChannelBody(Src).Queued <= 64);
    F := Src.PollFrame(FEx, D, Tr);
    case F of
      fpData:
        begin
          SetString(S, PAnsiChar(D.P), D.Len);
          AssertEquals('one Write = one frame, in order', FrameText(Frames, 32), S);
          ReleaseBody(D);
          Inc(Frames);
        end;
      fpTrailers:
        begin
          AssertEquals('x-t', Tr.Name(0));
          AssertEquals('1', Tr.Value(0));
          SawTrailers := True;
        end;
      fpEnd:
        Break;
      fpPending:
        begin
          Pending := True;
          FTask.Runs := 0;
          AssertTrue('the next frame wakes the dispatcher', Until_(@CondWoken, 5000));
        end;
    else
      Fail('unexpected frame');
    end;
  end;
  AssertEquals('line 1263', FH.StreamFrames, Frames);
  AssertTrue('line 1264', SawTrailers);
  AssertTrue('handler finished', Until_(@CondFinished, 5000));
  AssertTrue('Finish accepted', FH.FinishResult);
  AssertTrue('the consumer waited at least once', Pending or (Frames > 0));
  Src.Done(FEx);
  AssertTrue('line 1268', Until_(@CondFinished, 5000));
  FinishExchange;
end;

procedure TTestOffload.Stream_ends_when_last_producer_releases;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  Frames: Integer;
begin
  FH := TRecHandler.Create(hmStreamNoFinish);
  FH.StreamFrames := 3;
  FH.HighWater := 1024;
  FEx := NewEx('GET /n HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmStreamNoFinish);
  AssertTrue('line 1285', Until_(@CondFinished, 5000));
  AssertTrue('line 1286', Until_(@CondAnswered, 5000));
  { the worker's Release brought the count to 1 (the transport); the call's
    completion, the last producer since the S7 fix round 7 (S7-43), ends
    the stream }
  Drive;
  AssertEquals('line 1289', 1, FEx.RefCount);
  FEx.CompleteCall;
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  Frames := 0;
  repeat
    F := Src.PollFrame(FEx, D, Tr);
    if F = fpData then
    begin
      ReleaseBody(D);
      Inc(Frames);
    end;
  until F <> fpData;
  AssertEquals('line 1302', 3, Frames);
  AssertTrue('a stream without Finish ends when its last producer is gone', F = fpEnd);
  Src.Done(FEx);
  FinishExchange;
end;

procedure TTestOffload.Handler_exception_and_no_answer_fail;
begin
  FEx := NewEx('GET /x HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmRaise);
  AssertTrue('line 1312', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertTrue('line 1314', FEx.Resp.Failed);
  AssertEquals('handler raised EConvertError: boom', FEx.Resp.FailText);
  FinishExchange;
  FreeAndNil(FCall);
  FreeAndNil(FH);
  FEx := NewEx('GET /y HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmNoAnswer);
  AssertTrue('line 1321', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertTrue('line 1323', FEx.Resp.Failed);
  AssertEquals('handler returned no response', FEx.Resp.FailText);
  FinishExchange;
end;

procedure TTestOffload.Exception_after_stream_aborts_body;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  Frames: Integer;
begin
  FH := TRecHandler.Create(hmRaiseAfterStream);
  FH.StreamFrames := 2;
  FH.HighWater := 1024;
  FEx := NewEx('GET /z HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmRaiseAfterStream);
  AssertTrue('line 1341', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  AssertFalse('the answer was the stream', FEx.Resp.Failed);
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  Frames := 0;
  repeat
    F := Src.PollFrame(FEx, D, Tr);
    if F = fpData then
    begin
      ReleaseBody(D);
      Inc(Frames);
    end
    else if F = fpPending then
      Until_(@CondFinished, 5000);
  until (F <> fpData) and (F <> fpPending);
  AssertEquals('the frames before the exception', 2, Frames);
  AssertTrue('then the body error', F = fpError);
  AssertEquals('handler raised Exception: after stream', FEx.Resp.BodyErrorText);
  Src.Done(FEx);
  AssertTrue('line 1361', Until_(@CondFinished, 5000));
  FinishExchange;
end;

procedure TTestOffload.Body_copy_on_worker_uses_heap;
var
  B: TBodyData;
  S: RawByteString;
begin
  FEx := NewEx('GET /c HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmCopy);
  AssertTrue('line 1372', Until_(@CondAnswered, 5000));
  FEx.CompleteCall;
  B := FEx.Resp.Body;
  SetString(S, PAnsiChar(B.P), B.Len);
  AssertEquals('copied on a worker', S);
  AssertTrue('a heap block, not one of the loop''s pool', PBufBlock(B.Ctx)^.Pool = nil);
  FinishExchange;
end;

var
  ShareEx: TExchange;
  ShareWakes: Integer;

function ShareThread(Arg: Pointer): PtrInt;
var
  I: Integer;
begin
  for I := 1 to ShareWakes do
    ShareEx.Wake;
  ShareEx.Release;
  Result := 0;
end;

procedure TTestOffload.Share_release_balance_16_threads;
var
  It, I: Integer;
  Th: array[0..15] of TThreadID;
begin
  ShareWakes := Iters(200);
  for It := 1 to Iters(40) do
  begin
    FEx := NewEx('GET /b HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    FTask.Runs := 0;
    for I := 0 to 15 do
      FEx.Share;
    AssertEquals('line 1407', 17, FEx.RefCount);
    ShareEx := FEx;
    for I := 0 to 15 do
      Th[I] := BeginThread(@ShareThread, nil);
    if It mod 2 = 0 then
    begin
      Drive;
      FEx.ReleaseTransport;                 { early: the last Release is a worker's }
    end;
    for I := 0 to 15 do
    begin
      while WaitForThreadTerminate(Th[I], 1) <> 0 do
        Drive;
      CloseThread(Th[I]);
    end;
    if It mod 2 = 1 then
      FEx.ReleaseTransport;                 { late: the last release is the loop's }
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    Drive;
    AssertEquals('exactly once in iteration ' + IntToStr(It), FFree0 + 1, FPool.FreeCount);
    AssertEquals('line 1428', 0, PinsLive);
    FEx := nil;
  end;
end;

function WakeAndRelease(Arg: Pointer): PtrInt;
begin
  ShareEx.Wake;
  ShareEx.Release;
  Result := 0;
end;

procedure TTestOffload.Wake_queued_at_last_release_delays_recycle;
var
  Th: TThreadID;
begin
  { 3.2.3 rule 3: another thread posts a wake and releases; the loop drops
    the last reference while the WakeMsg is still queued: the recycle waits
    for the message, and the message wakes nobody }
  FEx := NewEx('GET /w HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;
  ShareEx := FEx;
  Th := BeginThread(@WakeAndRelease, nil);
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  AssertEquals('line 1453', 1, FEx.RefCount);
  FEx.ReleaseTransport;
  AssertEquals('not recycled while the wake is queued', FFree0, FPool.FreeCount);
  AssertTrue('line 1456', Until_(@CondRecycled, 5000));
  Drive;
  AssertEquals('line 1458', FFree0 + 1, FPool.FreeCount);
  AssertEquals('the owner is not woken', 0, FTask.Runs);
  FEx := nil;
end;

procedure TTestOffload.Blocking_read_on_loop_thread_raises;
var
  C: TByteSlice;
  Raised: Boolean;
begin
  FEx := NewEx('POST /l HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 3' + CRLF + CRLF);
  Raised := False;
  try
    FEx.ReadChunk(C);
  except
    on E: Exception do
      Raised := Pos('loop thread', E.Message) > 0;
  end;
  AssertTrue('a blocking read on the loop thread raises instead of waiting for itself', Raised);
  FEx.Chan.CloseSender;
  FEx.CompleteCall;
  FinishExchange;
end;

{ ---- S7 fix tests: the S7 verifier's findings and its surviving mutants ---- }

type
  { runs F(Arg) on a worker of the test's pool (a pool thread: its heap and
    exit are ordered for drd, unlike a raw BeginThread thread that allocates) }
  TFuncItem = class(TWorkItem)
  public
    F: TThreadFunc;
    Arg: Pointer;
    Done: LongInt;
    procedure Execute; override;
  end;

procedure TFuncItem.Execute;
begin
  F(Arg);
  HappensBefore(@Done);
  InterLockedExchange(Done, 1);
end;

var
  FuncItems: array of TFuncItem;     { freed by TWCase.TearDown }

function RunOnPool(Pool: TWorkerPool; F: TThreadFunc; Arg: Pointer): TFuncItem;
begin
  Result := TFuncItem.Create;
  Result.F := F;
  Result.Arg := Arg;
  SetLength(FuncItems, Length(FuncItems) + 1);
  FuncItems[High(FuncItems)] := Result;
  Pool.Submit(Result);
end;

procedure FreeFuncItems;
var
  I: Integer;
begin
  for I := 0 to High(FuncItems) do
    FuncItems[I].Free;
  FuncItems := nil;
end;

{ waits for the item (10 s); False on the timeout. The item is freed by
  TWCase.TearDown after the pool shut down (its worker writes Done after
  the last happens-before edge it can give drd, so an earlier free would be
  reported) }
function JoinItem(It: TFuncItem): Boolean;
var
  T0: Int64;
begin
  T0 := MonoNowNs;
  while (AtomicLoad(It.Done) = 0) and (MonoNowNs - T0 < 10000000000) do
    Sleep(1);
  Result := AtomicLoad(It.Done) <> 0;
  if Result then
    HappensAfter(@It.Done);
end;

var
  HookArmed, HookIn: LongInt;

procedure SleepyReleaseHook(Ex: TExchange; NewCount: LongInt);
begin
  { only the worker's release that leaves the transport's reference }
  if (NewCount = 1) and (CurrentWorkerIndex >= 0)
    and (InterlockedCompareExchange(HookArmed, 0, 1) = 1) then
  begin
    InterLockedExchange(HookIn, 1);
    Sleep(300);
    HappensBefore(@HookIn);
    InterLockedExchange(HookIn, 2);
  end;
end;

function TWCase.CondHookIn: Boolean;
begin
  Result := AtomicLoad(HookIn) = 1;
end;

function TWCase.CondHookOut: Boolean;
begin
  Result := AtomicLoad(HookIn) = 2;
  if Result then
    HappensAfter(@HookIn);
end;

function TWCase.CondRef2: Boolean;
begin
  Result := FEx.RefCount = 2;
end;

function TWCase.CondRef1: Boolean;
begin
  Result := FEx.RefCount = 1;
end;

function TWCase.CondChanReady: Boolean;
var
  Closed: Boolean;
begin
  Result := FEx.Chan.PollReady(Closed);
end;

{ every frame until the stream is not ready (fpPending) or ended; returns the data frames }
function DrainFrames(Ex: TExchange; Src: TBodySource; out Last: TFramePoll; Tr: PPointer): Integer;
var
  D: TBodyData;
  T: THttpHeaders;
begin
  Result := 0;
  repeat
    Last := Src.PollFrame(Ex, D, T);
    if Last = fpData then
    begin
      ReleaseBody(D);
      Inc(Result);
    end
    else if (Last = fpTrailers) and (Tr <> nil) then
      Tr^ := T;
  until (Last <> fpData) and (Last <> fpTrailers);
end;

procedure TTestOffload.Release_after_recycle_leaves_the_new_stream;
var
  Src: TBodySource;
  F: TFramePoll;
  Old, H: TExchange;
  W: TWriteResult;
begin
  { S7 verifier finding (major): the worker's Release ended the stream
    (AutoFinish) after its decrement had given up its reference. The hook
    holds the worker right after the decrement (2 -> 1) for 300 ms; in that
    window the loop ends the stream, releases the transport (1 -> 0: the
    exchange is recycled) and a new request on the same object begins a
    stream. After the stale Release returned, the new stream is still open.
    S7 fix round 7 (S7-43): the new request also shares its exchange with a
    second producer, which releases after the stale Release returned: the
    holder count the stale Release would decrement after its reference went
    (mutant autofinish-after-decrement) is the new request's, and the call
    in flight keeps the stream open }
  FH := TRecHandler.Create(hmStream);
  FH.StreamFrames := 1;
  FH.HighWater := 1024;
  HookIn := 0;
  HookArmed := 1;
  ReleaseTestHook := @SleepyReleaseHook;
  try
    FEx := NewEx('GET /a HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmStream);
    AssertTrue('the worker''s Release is in the window after its decrement',
      Until_(@CondHookIn, 5000));
    AssertTrue('answered', Until_(@CondAnswered, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    AssertEquals('one frame', 1, DrainFrames(FEx, Src, F, nil));
    AssertTrue('ended by Finish', F = fpEnd);
    Src.Done(FEx);
    AssertEquals('the worker''s reference is gone', 1, FEx.RefCount);
    FEx.ReleaseTransport;
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Old := FEx;
    FEx := NewEx('GET /b HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    AssertTrue('the pool gave back the same object', Pointer(FEx) = Pointer(Old));
    AssertTrue('a stream of the new request', FEx.BeginStream(1024));
    H := FEx.Share;
    AssertTrue('the stale Release returns', Until_(@CondHookOut, 5000));
    Sleep(50);
    H.Release;
    W := FEx.WriteString('second request frame');
    AssertTrue('the new request''s stream is still open (got ' + IntToStr(Ord(W)) + ')', W = wrOk);
    AssertTrue('Finish', FEx.Finish(nil));
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    AssertEquals('the new request''s frame', 1, DrainFrames(FEx, Src, F, nil));
    AssertTrue('then its end', F = fpEnd);
    Src.Done(FEx);
    FinishExchange;
  finally
    ReleaseTestHook := nil;
  end;
end;

procedure TTestOffload.Stream_two_producers_one_releases;
var
  Src: TBodySource;
  F: TFramePoll;
begin
  { deviation S7-5's rule applies to the LAST producer only: the worker
    returns without Finish while a second producer (this thread, after
    Share) still holds the exchange; the stream stays open until that one
    releases too (mutant v-autofinish-at-any-count) }
  FH := TRecHandler.Create(hmStreamWaitNoFinish);
  FH.StreamFrames := 2;
  FH.HighWater := 1024;
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /two HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmStreamWaitNoFinish);
    AssertTrue('the worker wrote its frames', Until_(@CondReady, 5000));
    AssertTrue('answered', Until_(@CondAnswered, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    FEx.Share;
    AssertEquals('transport + worker + second producer', 3, FEx.RefCount);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('the worker returned', Until_(@CondFinished, 5000));
    AssertTrue('the worker released', Until_(@CondRef2, 5000));
    AssertTrue('the second producer still writes', FEx.WriteString('third frame') = wrOk);
    AssertEquals('the three frames', 3, DrainFrames(FEx, Src, F, nil));
    AssertTrue('open while a producer is left', F = fpPending);
    FEx.Release;
    AssertEquals('the transport only', 1, FEx.RefCount);
    AssertEquals('no more frames', 0, DrainFrames(FEx, Src, F, nil));
    AssertTrue('the last producer''s release ended the stream', F = fpEnd);
    Src.Done(FEx);
    FinishExchange;
  finally
    { a failed assertion leaves the worker at the gate: let it go first }
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Stream_first_frame_above_high_water;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  Big, One: RawByteString;
begin
  { deviation S7-5: a frame is accepted while the queue is empty, even one
    larger than HighWater (else Write would park forever on it; mutant
    v-push-no-first-frame-rule) }
  FEx := NewEx('GET /big HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  AssertTrue('BeginStream', FEx.BeginStream(16));
  Big := StringOfChar('x', 40);
  One := 'y';
  AssertTrue('a 40-byte frame on an empty 16-byte channel', FEx.TryWrite(PByte(Pointer(Big)), 40) = wrOk);
  AssertTrue('the next frame waits for room', FEx.TryWrite(PByte(Pointer(One)), 1) = wrWouldBlock);
  { the call is still in flight while it writes: an unshared call's
    completion ends its stream (S7 fix round 7, S7-44) }
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  F := Src.PollFrame(FEx, D, Tr);
  AssertTrue('data', F = fpData);
  AssertEquals('the whole frame', 40, D.Len);
  ReleaseBody(D);
  AssertTrue('room again', FEx.TryWrite(PByte(Pointer(One)), 1) = wrOk);
  AssertTrue('Finish', FEx.Finish(nil));
  FEx.CompleteCall;
  AssertEquals('one more frame', 1, DrainFrames(FEx, Src, F, nil));
  AssertTrue('end', F = fpEnd);
  Src.Done(FEx);
  FinishExchange;
end;

var
  BlockEx: TExchange;
  BlockDone: LongInt;
  BlockFrames: array[1..2, 0..2] of RawByteString;   { made by the test thread }

function BlockedWriter(Arg: Pointer): PtrInt;
var
  I: Integer;
begin
  { WriteString: no allocation on this thread (the frames are the test
    thread's strings) }
  for I := 0 to 2 do
    if BlockEx.WriteString(BlockFrames[PtrInt(Arg), I]) <> wrOk then
      Break;
  InterLockedIncrement(BlockDone);
  BlockEx.Release;
  Result := 0;
end;

procedure TTestOffload.Stream_two_blocked_producers;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  W1, W2: TFuncItem;
  It, Frames, I, J: Integer;
  Deadline: Int64;
begin
  { design 3.5: after Share any thread may write the stream. Two threads
    blocked in Write on the same full channel (HighWater = one frame) are
    both woken as the consumer frees room (the S7 verifier's TParker
    finding: one waiter only, the second could make the first miss its
    wake) }
  for I := 1 to 2 do
    for J := 0 to 2 do
      BlockFrames[I, J] := FrameText(I * 10 + J, 8);
  for It := 1 to Iters(50) do
  begin
    FEx := NewEx('GET /blk HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    AssertTrue('BeginStream', FEx.BeginStream(8));
    { a first frame from this thread: the ring grows here, not on a writer }
    AssertTrue('first frame', FEx.WriteString(FrameText(0, 8)) = wrOk);
    FEx.Share;
    FEx.Share;
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    BlockEx := FEx;
    InterLockedExchange(BlockDone, 0);
    W1 := RunOnPool(FWork, @BlockedWriter, Pointer(1));
    W2 := RunOnPool(FWork, @BlockedWriter, Pointer(2));
    if It mod 2 = 0 then
      Sleep(2);                        { both producers parked before the first take }
    Frames := 0;
    Deadline := MonoNowNs + 10000000000;
    while True do
    begin
      if MonoNowNs > Deadline then
        Fail('iteration ' + IntToStr(It) + ': a blocked producer was not woken (' + IntToStr(Frames)
          + ' frames)');
      F := Src.PollFrame(FEx, D, Tr);
      if F = fpData then
      begin
        ReleaseBody(D);
        Inc(Frames);
      end
      else if F = fpPending then
        Drive
      else
        Break;
    end;
    AssertTrue('the end', F = fpEnd);
    AssertEquals('every frame of both producers', 7, Frames);
    AssertTrue('writer 1 returned', JoinItem(W1));
    AssertTrue('writer 2 returned', JoinItem(W2));
    AssertEquals('both producers finished', 2, AtomicLoad(BlockDone));
    Src.Done(FEx);
    FinishExchange;
  end;
end;

procedure TTestOffload.Second_finish_leaves_the_trailers;
var
  Src: TBodySource;
  F: TFramePoll;
  T1, T2, Got: THttpHeaders;
begin
  { the S7 verifier's FinishStream finding: a refused Finish (the stream
    already finished) must not rewrite the trailers the consumer reads }
  T1 := THttpHeaders.Create;
  T2 := THttpHeaders.Create;
  try
    T1.Add('x-t', '1');
    T2.Add('x-t', '2');
    FEx := NewEx('GET /tr HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    AssertTrue('BeginStream', FEx.BeginStream(1024));
    AssertTrue('the first Finish', FEx.Finish(T1));
    AssertFalse('a second Finish is refused', FEx.Finish(T2));
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    Got := nil;
    AssertEquals('no data', 0, DrainFrames(FEx, Src, F, @Got));
    AssertTrue('end', F = fpEnd);
    AssertTrue('trailers', Got <> nil);
    AssertEquals('the first Finish''s trailers', '1', Got.Value(0));
    Src.Done(FEx);
    FinishExchange;
  finally
    T1.Free;
    T2.Free;
  end;
end;

procedure TTestOffload.Cancel_keeps_the_chunk_a_worker_holds;
var
  Closed: Boolean;
  P0: Integer;
begin
  { deviation S7-2: a cancel closes the receiver for the worker but leaves
    the chunk it holds (and the head) pinned until the worker's next body
    call or the recycle (mutant v-close-from-loop-unpins-held) }
  FH := TRecHandler.Create(hmReadHold);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('POST /h HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmReadHold);
    AssertTrue('ready', FEx.Chan.PollReady(Closed));
    AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
    AssertTrue('the worker holds the chunk', Until_(@CondReady, 5000));
    Drive;
    P0 := PinsLive;
    AssertEquals('the head and the chunk', 2, P0);
    FEx.Cancel;
    FCall.Drop(FEx, False);
    FEx.Chan.SendError(NewIncomplete);
    FEx.Chan.CloseSender;
    FEx.ReleaseTransport;
    Drive;
    Drive;
    AssertEquals('the worker''s chunk and the head stay pinned', P0, PinsLive);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertEquals('hello', FH.HeldCopy);
    AssertTrue('the bytes did not change under the worker', FH.Intact);
    AssertEquals('then the cancel', 'EClientGone', FH.ErrClass);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    { a failed assertion leaves the worker at the gate: let it go first }
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Offload_on_a_stopped_pool;
var
  One: TWorkerPool;
  Raised: Boolean;
begin
  { deviation S7-11: Offload on a shut-down pool raises EWorkerPoolStopped
    and gives back the reference Share took (mutant
    v-offload-pool-stopped-keeps-ref) }
  One := TWorkerPool.Create(1);
  try
    One.Shutdown(5000);
    FEx := NewEx('GET /s HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    FH := TRecHandler.Create(hmRespond);
    Raised := False;
    try
      FEx.Offload(One, FH);
    except
      on E: EWorkerPoolStopped do
        Raised := True;
    end;
    AssertTrue('EWorkerPoolStopped', Raised);
    AssertEquals('the reference Share took went back', 1, FEx.RefCount);
    AssertFalse('not offloaded', FEx.Offloaded);
    { the exception aborts the connection task (1.10) }
    FEx.Cancel;
    FEx.ReleaseTransport;
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    One.Free;
  end;
end;

procedure TTestOffload.Released_head_unpinned_on_wake;
begin
  { 3.2.4 Head.Released: the head a worker released is unpinned on the loop
    when the worker's wake reaches it (SyncShared from the WakeMsg), before
    the call completes (mutants v-sync-shared-keeps-head,
    v-wakemsg-no-sync) }
  FH := TRecHandler.Create(hmReleaseWait);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /rel HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    AssertEquals('the head', 1, PinsLive);
    StartOffload(hmReleaseWait);
    AssertTrue('released', Until_(@CondReady, 5000));
    AssertTrue('the head is unpinned before the answer', Until_(@CondNoPins, 5000));
    AssertFalse('not answered yet', FEx.Answered);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('answered', Until_(@CondAnswered, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FEx.CompleteCall;
    AssertTrue('finished', Until_(@CondFinished, 5000));
    FinishExchange;
  finally
    { a failed assertion leaves the worker at the gate: let it go first }
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Read_all_limit_without_content_length;
begin
  { ReadAll's limit also holds for a body without Content-Length (chunked):
    EBodyTooLarge once more than Limit bytes arrived (mutant
    v-readall-no-limit) }
  FEx := NewEx('POST /c HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Transfer-Encoding: chunked'
    + CRLF + CRLF);
  StartOffload(hmReadAll);
  AssertTrue('ready', Until_(@CondChanReady, 5000));
  AssertTrue('send 6', FEx.Chan.TrySendData(View('abcdef')));
  AssertTrue('ready again', Until_(@CondChanReady, 5000));
  AssertTrue('send 6 more', FEx.Chan.TrySendData(View('ghijkl')));
  if not Until_(@CondFinished, 5000) then
  begin
    { the handler waits for more body: end it, so the worker returns }
    FEx.Chan.CloseSender;
    Until_(@CondFinished, 5000);
    Fail('ReadAll went past its limit of 10 bytes and waited for more');
  end;
  AssertEquals('over the limit of 10', 'EBodyTooLarge', FH.ErrClass);
  AssertTrue('answered', Until_(@CondAnswered, 5000));
  FEx.Chan.CloseSender;
  FEx.CompleteCall;
  FinishExchange;
end;

var
  DupEx1, DupEx2: TExchange;

function DoubleWake(Arg: Pointer): PtrInt;
begin
  DupEx1.Wake;
  DupEx2.Wake;
  DupEx1.Wake;
  DupEx2.Wake;
  Result := 0;
end;

procedure TTestOffload.Wake_posts_one_message_while_queued;
var
  Task2: TOwnerTask;
  Ex2: TExchange;
begin
  { 1.7 / 3.2.2 FWakeQueued: while an exchange's WakeMsg is queued, a
    second Wake posts nothing (the node is intrusive: pushing it twice
    links it into the inbox twice, with another exchange's message between
    them; mutant v-wake-always-post: the batch then holds a node twice,
    and its second dispatch fails ExchangeWakeMsg's assertion) }
  Task2 := TOwnerTask.Create;
  Task2.Loop := FLoop;
  Ex2 := FPool.Take(FLoop);
  try
    Ex2.BeginRequest(Task2);
    FEx := NewEx('GET /dup HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    FEx.Share;
    Ex2.Share;
    DupEx1 := FEx;
    DupEx2 := Ex2;
    AssertTrue('the wakes were posted', JoinItem(RunOnPool(FWork, @DoubleWake, nil)));
    FTask.Runs := 0;
    Task2.Runs := 0;
    Drive;
    Drive;
    AssertEquals('the first owner woken once', 1, FTask.Runs);
    AssertEquals('the second owner woken once', 1, Task2.Runs);
    FEx.Release;
    Ex2.Release;
    FinishExchange;
    Ex2.Cancel;
    Ex2.ReleaseTransport;
    Drive;
  finally
    Task2.Free;
  end;
end;

var
  OffLoopEx: TExchange;
  OffLoopAsserted: LongInt;

function OffLoopTryRead(Arg: Pointer): PtrInt;
var
  C: TByteSlice;
begin
  try
    OffLoopEx.TryRead(C);
  except
    on E: EAssertionFailed do
      InterLockedExchange(OffLoopAsserted, 1);
  end;
  Result := 0;
end;

procedure TTestOffload.Debug_checks_and_poison;
var
  P: PByte;
  L, I: SizeInt;
  Poisoned, Raised: Boolean;
  Ex: TExchange;
begin
  { 3.2.4 last paragraph, in builds with assertions: a loop-only method of
    an unshared exchange called off its loop thread fails an assertion; the
    bytes of a released head view are 0xDD; Wake on a recycled exchange
    fails an assertion }
  FEx := NewEx('GET /poison HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  OffLoopEx := FEx;
  OffLoopAsserted := 0;
  AssertTrue('ran', JoinItem(RunOnPool(FWork, @OffLoopTryRead, nil)));
  AssertEquals('TryRead off the loop thread on an unshared exchange', 1, AtomicLoad(OffLoopAsserted));
  P := FEx.Head.View.P;
  L := FEx.Head.View.Len;
  AssertTrue('a head view', (P <> nil) and (L > 0));
  AssertTrue('answer', FEx.Respond(BodyEmpty));
  FEx.CompleteCall;
  Poisoned := True;
  for I := 0 to L - 1 do
    if P[I] <> $DD then
      Poisoned := False;
  AssertTrue('the released head view is 0xDD', Poisoned);
  FinishExchange;
  Ex := FPool.Take(FLoop);
  Raised := False;
  try
    Ex.Wake;
  except
    on E: EAssertionFailed do
      Raised := True;
  end;
  FPool.Give(Ex);
  AssertTrue('Wake on a recycled exchange', Raised);
end;

{ ============================ TServer with a worker pool ============================ }

type
  TTestWorkerServer = class(TTestCase)
  published
    procedure Server_offloaded_requests;
    procedure Server_destroy_recycles_what_workers_release;
    procedure Server_worker_reads_after_its_answer;
    { S7 fix round 5 }
    procedure Server_abort_after_answer_gives_body_error;
    procedure Server_destroy_waits_for_an_outside_holder;
    { S7 fix round 6 }
    procedure Server_destroy_waits_for_a_poster_to_leave_post;
    procedure Server_inline_echo_needs_share;
  end;

  TSrvHandler = class(TBlockingHandler)
  public
    procedure Run(Ex: TExchange); override;
  end;

  TSrvService = class(THttpService)
  public
    Call_: TOffloadCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TSrvApp = class
  public
    Srv: TServer;
    H: TSrvHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

var
  SleepCanceled, SleepDone, Sleep2Started: LongInt;
  SleepWrite: TWriteResult;
  AnswerReadDone: LongInt;
  AnswerReadBody, AnswerReadErr: RawByteString;

{ ---- second S7 fix (S7-23, S7-24) ---- }

procedure SleepyExHook(Ex: TExchange);
begin
  { a worker's call only, once per arming: 300 ms in the window }
  if (CurrentWorkerIndex >= 0) and (InterlockedCompareExchange(HookArmed, 0, 1) = 1) then
  begin
    InterLockedExchange(HookIn, 1);
    Sleep(300);
    HappensBefore(@HookIn);
    InterLockedExchange(HookIn, 2);
  end;
end;

function TWCase.CondReady2: Boolean;
begin
  Result := AtomicLoad(FH.Ready) = 2;
end;

procedure TTestOffload.Cancel_before_the_read_takes_the_lock;
begin
  { S7-23 (second S7 verifier, major): a blocking read whose state check
    came before the loop's cancel, and whose lock came after the cancel
    closed the receiver, returned the end of the body: the handler took a
    truncated body for a complete one. The hook holds the worker's read
    right before Chan.Lock for 300 ms; in that window the loop cancels
    (CAS, then the receiver closes under the lock) and the connection's
    sender goes. The read must raise EClientGone (3.2.3 rule 6), not end
    (mutant v2-try-read-state-before-lock) }
  FH := TRecHandler.Create(hmReadBody);
  HookIn := 0;
  HookArmed := 1;
  TryReadTestHook := @SleepyExHook;
  try
    FEx := NewEx('POST /c HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmReadBody);
    AssertTrue('the worker''s read is before the lock', Until_(@CondHookIn, 5000));
    FEx.Cancel;
    FCall.Drop(FEx, False);
    FEx.Chan.SendError(NewIncomplete);          { DropAll: the body sender goes }
    FEx.Chan.CloseSender;
    FEx.ReleaseTransport;
    AssertTrue('the read went on', Until_(@CondHookOut, 5000));
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertEquals('the read raised EClientGone, the body did not end', 'EClientGone', FH.ErrClass);
    AssertEquals('no chunk', 0, FH.Got.Count);
    AssertFalse('the answer is refused', FH.RespondResult);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    TryReadTestHook := nil;
  end;
end;

procedure TTestOffload.Concurrent_terminal_calls_leave_the_winner;
var
  R: Boolean;
  S: RawByteString;
begin
  { S7-23 (second S7 verifier, minor): two threads answer at once. The
    worker's Fail claims the response slot, then the hook holds it 300 ms
    before it writes the slot; meanwhile the loop thread's Respond (the
    shared path) must return False and leave the slot alone; the Fail wins
    and its slot is the response. Before the claim, the Respond won the CAS
    and the late Fail then wrote Failed / FailText over the answered slot
    (mutant v2-no-answer-claim) }
  FH := TRecHandler.Create(hmFail);
  HookIn := 0;
  HookArmed := 1;
  AnswerTestHook := @SleepyExHook;
  try
    FEx := NewEx('GET /t HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmFail);
    AssertTrue('the worker''s Fail is in the window', Until_(@CondHookIn, 5000));
    R := FEx.Respond(BodyString('from the loop'));
    AssertFalse('the second terminal call returns False', R);
    AssertTrue('the Fail went on', Until_(@CondHookOut, 5000));
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the first call won', FH.FailResult);
    AssertTrue('answered', FEx.Answered);
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FEx.CompleteCall;
    AssertTrue('the slot is the Fail''s', FEx.Resp.Failed);
    AssertEquals('from worker', FEx.Resp.FailText);
    SetString(S, PAnsiChar(FEx.Resp.Body.P), FEx.Resp.Body.Len);
    AssertEquals('the losing Respond wrote no body', '', S);
    FinishExchange;
  finally
    AnswerTestHook := nil;
  end;
end;

procedure TTestOffload.Complete_keeps_body_and_transport_release_detaches;
var
  Closed: Boolean;
begin
  { the handler answered without reading the body and still runs.
    (1) Decision 15 (S7 fix round 4; this test asserted the opposite since
    the second S7 fix): CompleteCall leaves the receiver open while the
    handler holds the request; the dispatcher keeps feeding it, and the
    handler's later read gets the chunk (mutant d15-complete-shared-closes).
    (2) After the transport's release no wake reaches the owner, though the
    worker's ReleaseRequest still wakes the loop (the dispatcher may be
    freed by then; mutant v2-release-transport-keeps-owner) }
  FH := TRecHandler.Create(hmRespondWaitRead);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('POST /k HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmRespondWaitRead);
    AssertTrue('answered', Until_(@CondReady, 5000));
    AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
    Drive;
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    AssertTrue('poll_ready', FEx.Chan.PollReady(Closed));
    AssertFalse('the receiver stays open after the completion', Closed);
    AssertTrue('the dispatcher feeds it', FEx.Chan.TrySendData(View('hello')));
    FEx.Chan.CloseSender;                       { the body ended }
    FEx.ReleaseTransport;
    Drive;
    FTask.Runs := 0;
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the handler''s late read gets the chunk (got ' + IntToStr(Ord(FH.TryReadLate)) + ')',
      FH.TryReadLate = brData);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('no wake reached the owner after the transport''s release', 0, FTask.Runs);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Cancel_releases_the_untaken_item;
var
  Closed: Boolean;
begin
  { a cancel closes the receiver for the handler, so the chunk the
    connection sent and nobody took is unpinned when the sender goes
    (chan.rs: the item is dropped with the last of Sender and Receiver);
    the head stays pinned for the handler (S7-2). Mutant
    v2-cancel-shared-no-close: the item stays pinned until the recycle }
  FH := TRecHandler.Create(hmWaitThenRespond);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('POST /u HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmWaitThenRespond);
    AssertTrue('started', Until_(@CondStarted, 5000));
    AssertTrue('ready', FEx.Chan.PollReady(Closed));
    AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
    AssertEquals('the head and the item', 2, PinsLive);
    FEx.Cancel;
    FCall.Drop(FEx, False);
    FEx.Chan.SendError(NewIncomplete);
    FEx.Chan.CloseSender;
    FEx.ReleaseTransport;
    Drive;
    AssertEquals('the untaken item is unpinned, the head stays', 1, PinsLive);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the read after the cancel', FH.TryReadAtStart = brCanceled);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Stream_frame_wakes_the_waiting_consumer;
var
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  S: RawByteString;
begin
  { a frame written while the dispatcher waits on an empty stream wakes it
    (TChannelBody.Push: FConsumerWaiting). Deterministic: the consumer
    waits before the producer writes, and nothing else wakes it until the
    producer's second gate (mutant stream-no-consumer-wake survived
    Stream_backpressure_frames_and_trailers in 1 of 4 runs under load: the
    consumer did not always wait there) }
  FH := TRecHandler.Create(hmStreamOneThenWait);
  FH.HighWater := 1024;
  FH.FrameLen := 32;
  FH.Gate := RTLEventCreate;
  FH.Gate2 := RTLEventCreate;
  try
    FEx := NewEx('GET /sw HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmStreamOneThenWait);
    AssertTrue('the stream began', Until_(@CondReady, 5000));
    AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
    Drive;
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    AssertTrue('the channel', Src is TChannelBody);
    F := Src.PollFrame(FEx, D, Tr);
    AssertTrue('nothing written yet: pending', F = fpPending);
    Drive;
    FTask.Runs := 0;
    RTLEventSetEvent(FH.Gate);
    AssertTrue('written', Until_(@CondReady2, 5000));
    AssertTrue('the frame woke the waiting dispatcher', Until_(@CondWoken, 2000));
    F := Src.PollFrame(FEx, D, Tr);
    AssertTrue('the frame', F = fpData);
    SetString(S, PAnsiChar(D.P), D.Len);
    ReleaseBody(D);
    AssertEquals(FrameText(0, 32), S);
    RTLEventSetEvent(FH.Gate2);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the write', FH.WriteResults[0] = wrOk);
    AssertTrue('Finish', FH.FinishResult);
    AssertEquals('then the end', 0, DrainFrames(FEx, Src, F, nil));
    AssertTrue('end', F = fpEnd);
    Src.Done(FEx);
    FinishExchange;
  finally
    RTLEventSetEvent(FH.Gate);
    RTLEventSetEvent(FH.Gate2);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
    RTLEventDestroy(FH.Gate2);
  end;
end;

{ ---- S7 fix round 4 (decisions 15-17; the third S7 verifier's findings) ---- }

procedure TTestOffload.V3_complete_while_parked_in_read;
var
  Closed: Boolean;
begin
  { the third S7 verifier (major): the handler answers, then reads the body
    and parks (no chunk yet); the loop completes the call. Before, the
    completion closed the receiver without unparking: the worker stayed
    parked for ever. Decision 15: the completion leaves the receiver open,
    the dispatcher keeps feeding it, and the read returns the chunks and
    then the end the body really has (mutants d15-complete-shared-closes,
    d15-complete-shared-closes-no-unpark) }
  FH := TRecHandler.Create(hmRespondThenRead);
  try
    FEx := NewEx('POST /p HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmRespondThenRead);
    AssertTrue('answered', Until_(@CondReady, 5000));
    AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
    AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Drive;
    AssertFalse('the read did not end at the completion', CondFinished);
    AssertTrue('the receiver is open: poll_ready', FEx.Chan.PollReady(Closed));
    AssertFalse('the receiver is open', Closed);
    AssertTrue('send hello', FEx.Chan.TrySendData(View('hello')));
    AssertTrue('taken', Until_(@CondChanReady, 5000));
    AssertTrue('send world', FEx.Chan.TrySendData(View('world')));
    FEx.Chan.CloseSender;                       { the body ended }
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertEquals('no exception', '', FH.ErrClass);
    AssertEquals('both chunks', 2, FH.Got.Count);
    AssertEquals('hello', FH.Got[0]);
    AssertEquals('world', FH.Got[1]);
    AssertTrue('then the end', FH.TryReadLate = brEnd);
    AssertTrue('the answer', FH.RespondResult);
    FinishExchange;
  finally
    if (FEx <> nil) and not CondFinished then
    begin
      { a failed run: unstick the worker so the test can tear down }
      FEx.Chan.Parker.Unpark;
      Until_(@CondFinished, 3000);
    end;
  end;
end;

procedure TTestOffload.V3_stream_then_read_parked;
var
  Closed: Boolean;
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  S, All: RawByteString;
  Deadline: Int64;
begin
  { the echo of decision 15: BeginStream, then ReadChunk and Write per
    chunk. The completion (the stream is the answer) leaves the receiver
    open; every chunk comes back as a frame of the response, then the end
    (mutants d15-complete-shared-closes, d15-complete-shared-closes-no-unpark) }
  FH := TRecHandler.Create(hmStreamEcho);
  FH.HighWater := 1024;
  Src := nil;
  try
    FEx := NewEx('POST /e HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmStreamEcho);
    AssertTrue('the stream began', Until_(@CondReady, 5000));
    AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
    AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    AssertTrue('the channel', Src is TChannelBody);
    AssertTrue('the receiver is open: poll_ready', FEx.Chan.PollReady(Closed));
    AssertFalse('the receiver is open', Closed);
    AssertTrue('send hello', FEx.Chan.TrySendData(View('hello')));
    { the worker reads the chunk and writes it back while the request body
      is still open }
    All := '';
    Deadline := MonoNowNs + 5000000000;
    repeat
      Drive;
      F := Src.PollFrame(FEx, D, Tr);
      if F = fpData then
      begin
        SetString(S, PAnsiChar(D.P), D.Len);
        ReleaseBody(D);
        All := All + S;
      end;
    until (All <> '') or (MonoNowNs > Deadline);
    AssertEquals('the first chunk came back before the body ended', 'hello', All);
    AssertTrue('taken', Until_(@CondChanReady, 5000));
    AssertTrue('send world', FEx.Chan.TrySendData(View('world')));
    FEx.Chan.CloseSender;
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertEquals('no exception', '', FH.ErrClass);
    repeat
      F := Src.PollFrame(FEx, D, Tr);
      if F = fpData then
      begin
        SetString(S, PAnsiChar(D.P), D.Len);
        ReleaseBody(D);
        All := All + S;
      end;
    until F <> fpData;
    AssertEquals('the echo', 'helloworld', All);
    AssertTrue('then the end', F = fpEnd);
    AssertTrue('Finish', FH.FinishResult);
    Src.Done(FEx);
    Src := nil;
    FinishExchange;
  finally
    if (FEx <> nil) and not CondFinished then
    begin
      FEx.Chan.Parker.Unpark;
      Until_(@CondFinished, 3000);
    end;
    if (Src <> nil) and (FEx <> nil) then
      Src.Done(FEx);
  end;
end;

procedure TTestOffload.Cancel_after_answer_while_parked_in_read;
begin
  { the connection ends after the worker's answer and before the dispatcher
    took it (the cancel loses the CAS) while the worker is parked in a body
    read. S7 fix round 5 (deviation S7-31; the fourth S7 verifiers: the same
    event gave EClientGone here and EBodyError after the completion): the
    cancel that lost leaves the request with its holders, as hyper's
    spawned task keeps its Incoming; the dispatcher's SenderDropGuard
    (DropAll, done by hand here) ends the body with the incomplete-message
    error, which unparks the worker, and its read raises EBodyError, as
    after the completion. It never reports the end of a body that did not
    end (mutant d15-loop-closed-reads-end) }
  FH := TRecHandler.Create(hmRespondThenRead);
  try
    FEx := NewEx('POST /p HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmRespondThenRead);
    AssertTrue('answered', Until_(@CondReady, 5000));
    AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
    FEx.Cancel;
    AssertFalse('the answer won', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.Chan.SendError(NewIncomplete);          { DropAll: the body sender goes }
    FEx.Chan.CloseSender;
    FEx.ReleaseTransport;
    AssertTrue('the parked read returned', Until_(@CondFinished, 5000));
    AssertEquals('the read raised the incomplete-message error', 'EBodyError', FH.ErrClass);
    AssertEquals('no chunk', 0, FH.Got.Count);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    if (FEx <> nil) and not CondFinished then
    begin
      FEx.Chan.Parker.Unpark;
      Until_(@CondFinished, 3000);
    end;
  end;
end;

procedure TTestOffload.Connection_gone_after_answer_while_parked;
begin
  { the call completed (the worker answered) and the worker reads the body;
    then the connection ends (DropAll after the completion: no cancel, the
    sender goes with hyper's incomplete error). The parked read wakes and
    raises a body error: not the end of the body (decision 15) }
  FH := TRecHandler.Create(hmRespondThenRead);
  try
    FEx := NewEx('POST /p HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
    StartOffload(hmRespondThenRead);
    AssertTrue('answered', Until_(@CondReady, 5000));
    AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
    AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    FEx.Chan.SendError(NewIncomplete);
    FEx.Chan.CloseSender;
    FEx.ReleaseTransport;
    AssertTrue('the parked read returned', Until_(@CondFinished, 5000));
    AssertEquals('a body error, not the end', 'EBodyError', FH.ErrClass);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
  finally
    if (FEx <> nil) and not CondFinished then
    begin
      FEx.Chan.Parker.Unpark;
      Until_(@CondFinished, 3000);
    end;
  end;
end;

procedure TTestOffload.Last_release_drops_the_request;
var
  Closed: Boolean;
begin
  { decision 15: a handler that answers and returns without reading the
    body or releasing the request: the request goes with its last holder.
    S7 fix round 5 (deviation S7-32): the call in flight is a holder too
    (hyper: the service future owns req until it completes), so the
    worker's Release leaves the request to the call, and the completion,
    the last holder now, drops it: the dispatcher's next poll_ready sees the
    receiver closed (drain or close), and the head and the untaken chunk
    are unpinned (mutants d15-release-keeps-request,
    r5-complete-keeps-call-holder) }
  FH := TRecHandler.Create(hmRespondNoRead);
  FEx := NewEx('POST /n HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  AssertTrue('prefetch: poll_ready', FEx.Chan.PollReady(Closed));
  AssertTrue('prefetch', FEx.Chan.TrySendData(View('hello')));
  StartOffload(hmRespondNoRead);
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertTrue('the worker''s reference went', Until_(@CondRef1, 5000));
  Drive;
  FEx.Chan.PollReady(Closed);
  AssertFalse('the call in flight still holds the request', Closed);
  AssertFalse('the head is not released', FEx.Head.Released);
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  AssertTrue('poll_ready', FEx.Chan.PollReady(Closed));
  AssertTrue('the request was dropped with its last holder, the call', Closed);
  FEx.Chan.CloseSender;
  AssertEquals('the head and the untaken chunk are unpinned', 0, PinsLive);
  FinishExchange;
end;

procedure TTestOffload.Respond_take_back_releases_the_body;
begin
  { S7-23's take-back in RespondShared (the third S7 verifier's mutant B):
    the worker's Respond claimed the slot, the hook holds it 300 ms, the
    loop's cancel wins the CAS; the Respond returns False and releases its
    body once }
  FH := TRecHandler.Create(hmRespondCounted);
  CountedReleases := 0;
  HookIn := 0;
  HookArmed := 1;
  AnswerTestHook := @SleepyExHook;
  try
    FEx := NewEx('GET /tb HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmRespondCounted);
    AssertTrue('the Respond is in the window', Until_(@CondHookIn, 5000));
    FEx.Cancel;
    AssertTrue('the cancel won', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    AssertTrue('the Respond went on', Until_(@CondHookOut, 5000));
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertFalse('the Respond lost', FH.RespondResult);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('the body was released once', 1, AtomicLoad(CountedReleases));
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    FEx := nil;
  finally
    AnswerTestHook := nil;
  end;
end;

procedure TTestOffload.Stream_take_back_calls_done;
begin
  { the same take-back in PublishStream (mutant C): a RespondStream that
    lost to the cancel gives its source back once (Done) }
  FH := TRecHandler.Create(hmStreamCounted);
  CountedDones := 0;
  CountedSource := TCountedSource.Create;
  HookIn := 0;
  HookArmed := 1;
  AnswerTestHook := @SleepyExHook;
  try
    FEx := NewEx('GET /td HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmStreamCounted);
    AssertTrue('the RespondStream is in the window', Until_(@CondHookIn, 5000));
    FEx.Cancel;
    AssertTrue('the cancel won', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    AssertTrue('the RespondStream went on', Until_(@CondHookOut, 5000));
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertFalse('the RespondStream lost', FH.RespondResult);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('the source was given back once', 1, AtomicLoad(CountedDones));
    FEx := nil;
  finally
    AnswerTestHook := nil;
    FreeAndNil(CountedSource);
  end;
end;

procedure TTestOffload.Begin_stream_claims_before_the_channel;
var
  R: Boolean;
  Src: TBodySource;
  F: TFramePoll;
  D: TBodyData;
  Tr: THttpHeaders;
  S: RawByteString;
begin
  { S7-23: BeginStream on a shared exchange claims the response before it
    touches the channel (the third S7 verifier's mutant D). The worker's
    BeginStream claimed and is held 300 ms before its CAS; a second
    BeginStream (the loop thread) must return False and leave the worker's
    channel alone; the worker's stream is the answer }
  FH := TRecHandler.Create(hmBeginStreamOnly);
  FH.HighWater := 1024;
  HookIn := 0;
  HookArmed := 1;
  AnswerTestHook := @SleepyExHook;
  try
    FEx := NewEx('GET /bs HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmBeginStreamOnly);
    AssertTrue('the worker''s BeginStream is in the window', Until_(@CondHookIn, 5000));
    R := FEx.BeginStream(16);
    AssertFalse('the second BeginStream returns False', R);
    AssertTrue('the BeginStream went on', Until_(@CondHookOut, 5000));
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the worker''s BeginStream won', FH.RespondResult);
    AssertTrue('its write', FH.WriteResults[0] = wrOk);
    AssertTrue('its Finish', FH.FinishResult);
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    F := Src.PollFrame(FEx, D, Tr);
    AssertTrue('the worker''s frame', F = fpData);
    SetString(S, PAnsiChar(D.P), D.Len);
    ReleaseBody(D);
    AssertEquals('from the worker''s stream', S);
    AssertTrue('then the end', Src.PollFrame(FEx, D, Tr) = fpEnd);
    Src.Done(FEx);
    FinishExchange;
  finally
    AnswerTestHook := nil;
  end;
end;

procedure TTestOffload.Head_built_by_one_thread;
var
  Raised: Boolean;
begin
  { decision 16 (builds with assertions): the response head of a shared
    exchange is built by the thread that makes the terminal call, before
    that call. The worker set the status and a header; a head write from
    the loop thread meanwhile fails an assertion (mutant
    d16-head-two-threads), and so does the worker's own head write after its
    answer (mutant d16-head-after-answer). After the answer the loop reads
    the head }
  FH := TRecHandler.Create(hmHeadThenWait);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /h HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmHeadThenWait);
    AssertTrue('the worker built the head', Until_(@CondReady, 5000));
    Raised := False;
    try
      FEx.Status := 500;
    except
      on E: EAssertionFailed do
        Raised := Pos('two threads', E.Message) > 0;
    end;
    AssertTrue('a head write from a second thread fails', Raised);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('answered', FH.RespondResult);
    AssertTrue('a head write after the answer fails', FH.LateHeadRaised);
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    AssertEquals('the worker''s status', 202, FEx.Status);
    AssertEquals('the worker''s header', 'x-built-by', FEx.ResponseHeaders.Name(0));
    FinishExchange;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Terminal_call_by_another_thread_than_the_head;
var
  Raised, R: Boolean;
begin
  { decision 16: the terminal call that claims the response is made by the
    thread that built the head (mutant d16-claim-no-check). The worker built
    the head; the loop thread's Respond fails the assertion. S7 fix round 6:
    the refused claim is given back (round 5 kept it taken), so the
    worker's own Respond answers afterwards }
  FH := TRecHandler.Create(hmHeadThenWait);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /hc HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmHeadThenWait);
    AssertTrue('the worker built the head', Until_(@CondReady, 5000));
    Raised := False;
    try
      R := FEx.Respond(BodyEmpty);
    except
      on E: EAssertionFailed do
        Raised := Pos('another thread than the one that built', E.Message) > 0;
    end;
    AssertTrue('the claim by another thread fails', Raised);
    AssertFalse('the refused claim answered nothing', FEx.Answered);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    { S7 fix round 6: the refused claim was given back (round 5 kept it, so
      this Respond lost and the request stayed unanswered), so the head's
      builder answers }
    AssertTrue('the worker''s Respond (the head''s builder) wins', FH.RespondResult);
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    AssertEquals('the worker''s status', 202, FEx.Status);
    FinishExchange;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

var
  LoopOnlyAsserts: LongInt;

function OffLoopCalls(Arg: Pointer): PtrInt;
var
  Q: TByteSlice;
begin
  { decision 17: loop-only methods of an unshared exchange, called off its
    loop thread }
  try OffLoopEx.Path; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.Query(Q); except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.ContentLength; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.Status := 204; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.ResponseHeaders; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.IsCanceled; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  try OffLoopEx.WriteString('x'); except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  { S7 fix round 5: a request without a body too (DiscardBody returned before its check) }
  try OffLoopEx.DiscardBody; except on E: EAssertionFailed do InterLockedIncrement(LoopOnlyAsserts); end;
  Result := 0;
end;

function WakeFromWorker(Arg: Pointer): PtrInt;
begin
  OffLoopEx.Wake;
  Result := 0;
end;

procedure TTestOffload.Debug_loop_only_and_wake_generation;
var
  Msg: string;
begin
  { decision 17 (builds with assertions; release builds have none of it,
    tools/check-hot-asm.sh --s7): (1) every loop-only method of an unshared
    exchange asserts the loop thread (mutant d17-loop-only-no-assert);
    (2) a WakeMsg carries the generation it was posted for and its dispatch
    checks it: an exchange recycled while its message is queued fails that
    check (mutant d17-wake-msg-no-gen-check; the dispatch's other check,
    FWakeQueued, gives another message) }
  FEx := NewEx('GET /dbg HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  OffLoopEx := FEx;
  LoopOnlyAsserts := 0;
  AssertTrue('ran', JoinItem(RunOnPool(FWork, @OffLoopCalls, nil)));
  AssertEquals('each off-loop call asserted', 8, AtomicLoad(LoopOnlyAsserts));
  AssertTrue('answer', FEx.Respond(BodyEmpty));
  FEx.CompleteCall;
  FinishExchange;
  { (2) a queued wake, then a recycle that ignores it (what a broken
    FinalRelease would do) }
  FEx := NewEx('GET /gen HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;
  OffLoopEx := FEx;
  AssertTrue('the wake was posted', JoinItem(RunOnPool(FWork, @WakeFromWorker, nil)));
  FEx.Recycle;
  Msg := '';
  try
    Drive;
    Drive;
  except
    on E: EAssertionFailed do
      Msg := E.Message;
  end;
  AssertTrue('the dispatch saw the other generation (got: ' + Msg + ')',
    Pos('recycled while its WakeMsg was queued', Msg) > 0);
  FPool.Give(FEx);
  FEx := nil;
end;

{ ---- S7 fix round 5: the fourth S7 verifiers' findings ---- }

function ReleaseFn(Arg: Pointer): PtrInt;
begin
  TExchange(Arg).Release;
  Result := 0;
end;

function ReleaseRequestFn(Arg: Pointer): PtrInt;
begin
  TExchange(Arg).ReleaseRequest;
  Result := 0;
end;

procedure TTestOffload.Head_write_after_cancel_is_legal;
begin
  { decision 16 (the fourth S7 verifiers, X_head_write_after_cancel_is_legal):
    the worker builds the head before its own terminal call; the loop's
    cancel comes first. The head write is legal (the claim is not taken);
    the Respond returns False. The check asserted the state, which the
    cancel changes, so it raised here }
  FH := TRecHandler.Create(hmHeadAfterGate);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('GET /h HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmHeadAfterGate);
    AssertTrue('started', Until_(@CondStarted, 5000));
    FEx.Cancel;
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertFalse('the Respond after the cancel is refused', FH.RespondResult);
    AssertFalse('the head write before the (losing) terminal call raised no assertion', FH.LateHeadRaised);
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    FEx := nil;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Second_holder_release_request_unparks_the_reader;
var
  Stuck: Boolean;
begin
  { the fourth S7 verifiers (X_second_holder_release_request_while_parked):
    a second holder calls ReleaseRequest (request-wide, 3.2.3 rule 7: only
    the request's reader should; a misuse) while the worker that reads the
    body is parked in ReadChunk on a Content-Length: 10 body of which
    nothing arrived. The handler-side close unparks the reader, and its
    read raises EClientGone: not the end of a body that did not end, and
    no worker stays parked (mutants r5-close-receiver-no-unpark,
    r5-closed-receiver-reads-end) }
  FH := TRecHandler.Create(hmRespondThenRead);
  Stuck := False;
  FEx := NewEx('POST /p HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  StartOffload(hmRespondThenRead);
  AssertTrue('answered', Until_(@CondReady, 5000));
  AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
  AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  FEx.Share;                                    { the second holder }
  AssertTrue('joined', JoinItem(RunOnPool(FWork, @ReleaseRequestFn, FEx)));
  Stuck := not Until_(@CondFinished, 2000);
  if Stuck then
  begin
    FEx.Chan.Parker.Unpark;
    Until_(@CondFinished, 3000);
  end;
  FEx.Release;
  FEx.Chan.CloseSender;
  FinishExchange;
  AssertFalse('the reader stayed parked after another holder released the request', Stuck);
  AssertEquals('the read raised EClientGone, not the end', 'EClientGone', FH.ErrClass);
  AssertEquals('no chunk', 0, FH.Got.Count);
end;

procedure TTestOffload.Cancel_lost_with_complete_body_keeps_the_chunk;
begin
  { the fourth S7 verifiers (X_cancel_lost_with_complete_body): the whole
    body arrived (the sender closed after the last chunk) and the worker
    answered without reading it; the connection then ends before the
    dispatcher polled the answer (the cancel loses the CAS). hyper's
    Incoming still yields the chunk; S7 fix round 5 (S7-31): so does this
    read (the cancel that lost does not close the receiver), and the end
    the body really had follows }
  FH := TRecHandler.Create(hmRespondWaitRead);
  FH.Gate := RTLEventCreate;
  try
    FEx := NewEx('POST /k HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF);
    StartOffload(hmRespondWaitRead);
    AssertTrue('answered', Until_(@CondReady, 5000));
    AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
    FEx.Chan.CloseSender;                       { the body ended }
    FEx.Cancel;
    AssertFalse('the answer won', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    AssertEquals('every pin back', 0, PinsLive);
    FEx := nil;
    AssertTrue('the late read gets the chunk of the complete body (got ' + IntToStr(Ord(FH.TryReadLate)) + ')',
      FH.TryReadLate = brData);
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure TTestOffload.Stale_cancel_does_not_end_the_next_request;
var
  First: TExchange;
begin
  { the fourth S7 verifiers (major; build/S7-verify4-race/evidence/
    repro_loopclosed.pas): a cancel closed the receiver of a request whose
    worker was reading its body, which set Chan.LoopClosed; the flag
    survived the recycle, and the next request on the same exchange
    without a body (no Chan.Open) read brCanceled: EClientGone on a live
    connection. S7 fix round 5: the flag is gone; a closed receiver reads
    as canceled only within its own request (mutant r5-stale-close-flag) }
  FH := TRecHandler.Create(hmReadBody);
  FEx := NewEx('POST /one HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  StartOffload(hmReadBody);
  AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
  FEx.Cancel;
  AssertTrue('the cancel won', FEx.IsCanceled);
  FCall.Drop(FEx, False);
  FEx.Chan.SendError(NewIncomplete);
  FEx.Chan.CloseSender;
  FEx.ReleaseTransport;
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertEquals('the canceled read', 'EClientGone', FH.ErrClass);
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  Drive;
  First := FEx;
  FEx := nil;
  FreeAndNil(FCall);
  FreeAndNil(FH);
  { the next request, without a body, on the same exchange (the pool is LIFO) }
  FEx := NewEx('GET /two HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  AssertTrue('the same exchange object', FEx = First);
  FH := TRecHandler.Create(hmReadBody);
  StartOffload(hmReadBody);
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertEquals('the empty body ends without an error', '', FH.ErrClass);
  AssertEquals('no body', '', FH.Body);
  AssertTrue('answered', FH.RespondResult);
  AssertTrue('the answer''s wake', Until_(@CondAnswered, 5000));
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  FinishExchange;
end;

procedure TTestOffload.Share_during_the_call_keeps_the_request;
begin
  { the fourth S7 verifiers (major; repro_share_after_drop.pas): the call
    shares the exchange to a helper that releases at once, then offloads.
    The holder count went 1 -> 0 at the helper's release, which dropped the
    request (head unpinned and poisoned) while the call was still in
    flight; the worker then read a released head. S7 fix round 5 (S7-32):
    the call in flight is a holder (hyper: the future owns req until it
    completes), so the request lives until the completion (mutant
    r5-share-no-call-holder) }
  FH := TRecHandler.Create(hmReadPath);
  FEx := NewEx('GET /keep/path HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;                                    { the helper's reference }
  AssertTrue('the helper released', JoinItem(RunOnPool(FWork, @ReleaseFn, FEx)));
  Drive;
  Drive;
  AssertFalse('the call in flight still holds the request', FEx.Head.Released);
  StartOffload(hmReadPath);
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertEquals('the worker read the head', '/keep/path', FH.Body);
  AssertTrue('answered', FH.RespondResult);
  AssertTrue('the answer''s wake', Until_(@CondAnswered, 5000));
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  AssertTrue('the request goes with its last holder', FEx.Head.Released);
  FinishExchange;
end;

procedure TTestOffload.Share_after_the_last_holder_raises;
var
  Msg: string;
begin
  { S7 fix round 5 (S7-32): a Share when no holder is left (the request was
    dropped) or with no call in flight raises instead of handing out a
    reference to a released request (S7-27 (6) accepted that edge) }
  FH := TRecHandler.Create(hmRespond);
  FEx := NewEx('GET /a HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  StartOffload(hmRespond);
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertTrue('the worker''s reference went', Until_(@CondRef1, 5000));
  AssertTrue('the answer''s wake', Until_(@CondAnswered, 5000));
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;                             { the last holder: the request goes }
  Msg := '';
  try
    FEx.Share;
  except
    on E: Exception do
      Msg := E.Message;
  end;
  AssertTrue('Share after the last holder raised (got: ' + Msg + ')',
    Pos('released by its last holder', Msg) > 0);
  AssertEquals('no reference was added', 1, FEx.RefCount);
  FinishExchange;
  { an unshared exchange after its completion: no call in flight }
  FEx := NewEx('GET /b HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  AssertTrue('answer', FEx.Respond(BodyEmpty));
  FEx.CompleteCall;
  Msg := '';
  try
    FEx.Share;
  except
    on E: Exception do
      Msg := E.Message;
  end;
  AssertTrue('Share with no call in flight raised (got: ' + Msg + ')', Pos('no call in flight', Msg) > 0);
  AssertFalse('still unshared', FEx.Shared);
  FinishExchange;
end;

procedure TTestOffload.Release_leaving_another_holder_keeps_the_request;
var
  Closed: Boolean;
begin
  { the fourth S7 verifiers (mutant my4: the request dropped at a Release
    that leaves another holder): after the completion the worker reads the
    body; a second holder (Share) releases; the request stays with the
    worker, which gets the chunk the loop sends and then the end }
  FH := TRecHandler.Create(hmRespondThenRead);
  FEx := NewEx('POST /r HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF);
  StartOffload(hmRespondThenRead);
  AssertTrue('answered', Until_(@CondReady, 5000));
  AssertTrue('parked in read', Until_(@CondParkedInRead, 5000));
  AssertTrue('the answer''s wake', Until_(@CondWoken, 5000));
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  FEx.Share;                                    { the second holder }
  AssertTrue('the second holder released', JoinItem(RunOnPool(FWork, @ReleaseFn, FEx)));
  Drive;
  AssertTrue('poll_ready', FEx.Chan.PollReady(Closed));
  AssertFalse('the reader still holds the request', Closed);
  AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
  FEx.Chan.CloseSender;                         { the body ended }
  AssertTrue('finished', Until_(@CondFinished, 5000));
  AssertEquals('no exception', '', FH.ErrClass);
  AssertEquals('the chunk', 1, FH.Got.Count);
  AssertEquals('hello', FH.Got[0]);
  AssertTrue('then the end', FH.TryReadLate = brEnd);
  FinishExchange;
end;


{ ---- S7 fix round 6 (the fifth S7 verifiers' findings) ---- }

procedure TTestOffload.Empty_write_after_the_stream_ended;
var
  W: TWriteResult;
  Prev: TExchange;
begin
  { 3.2.3 rule 6, 3.6: once the stream is gone a producer gets wrCanceled,
    for an empty write too (heartbeats). The contract verifier's
    C_empty_write_after_transport_dropped_stream and C_empty_write_after_finish,
    and its mutant my5 (mutant r6-empty-write-active) }
  { an open stream: wrOk }
  FEx := NewEx('GET /s1 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;
  AssertTrue('begin stream', FEx.BeginStream(64));
  W := FEx.WriteString('');
  AssertTrue('an empty write to an open stream: wrOk', W = wrOk);
  W := FEx.Write(nil, 0);
  AssertTrue('Write of 0 bytes to an open stream: wrOk', W = wrOk);
  { after Finish }
  AssertTrue('finish', FEx.Finish(nil));
  AssertTrue('a frame after Finish: wrCanceled', FEx.WriteString('x') = wrCanceled);
  AssertTrue('an empty write after Finish: wrCanceled', FEx.WriteString('') = wrCanceled);
  AssertTrue('TryWrite of 0 bytes after Finish: wrCanceled', FEx.TryWrite(nil, 0) = wrCanceled);
  FEx.Cancel;
  FEx.ReleaseTransport;
  FEx.Release;
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  FEx := nil;
  { the transport dropped the stream (a lost cancel, then ReleaseTransport: Source.Done) }
  FEx := NewEx('GET /s2 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;
  AssertTrue('begin stream', FEx.BeginStream(64));
  FEx.Cancel;
  AssertFalse('the answer won', FEx.IsCanceled);
  FEx.ReleaseTransport;
  AssertTrue('a frame after Done: wrCanceled', FEx.WriteString('x') = wrCanceled);
  AssertTrue('an empty write after Done: wrCanceled', FEx.WriteString('') = wrCanceled);
  FEx.Release;
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  FEx := nil;
  { after AbortStream }
  FEx := NewEx('GET /s3 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.Share;
  AssertTrue('begin stream', FEx.BeginStream(64));
  FEx.AbortStream('gone');
  AssertTrue('an empty write after AbortStream: wrCanceled', FEx.WriteString('') = wrCanceled);
  FEx.Cancel;
  FEx.ReleaseTransport;
  FEx.Release;
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  Prev := FEx;
  FEx := nil;
  { a recycled exchange whose channel an earlier request used, and this
    request never began a stream }
  FEx := NewEx('GET /s4 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  AssertTrue('the pool gave the same exchange (and its channel) back', FEx = Prev);
  FEx.Share;
  AssertTrue('an empty write without a stream: wrCanceled', FEx.WriteString('') = wrCanceled);
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FEx.Release;
  FEx.ReleaseTransport;
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  FEx := nil;
end;

var
  AbortRaceN: Integer;
  AbortRaceChan: TChannelBody;

function ResetLoop(Arg: Pointer): PtrInt;
var
  I: Integer;
begin
  { a bounded count, not "until told to stop": under drd a thread in an
    unbounded loop of annotated lock calls starved the other one }
  for I := 1 to AbortRaceN do
    AbortRaceChan.Reset(nil, 64);
  Result := 0;
end;

procedure TTestOffload.Reset_and_abort_race_keeps_the_message_counts;
var
  Strs: array of RawByteString;
  T: TThreadID;
  I, N, Bad, Aborted: Integer;
begin
  { the race verifier's r2_channel: TChannelBody.Reset cleared FAbortMsg
    after it released the lock, while AbortWith (any holder's thread)
    assigns it under the lock; the two string assignments lost or
    double-released references (mutant r6-reset-abort-msg-unlocked; the drd
    run reports it as a conflict on FAbortMsg). Every message string is
    held once by Strs; after the race and a last Reset each must have a
    reference count of exactly 1 }
  N := Iters(200000);
  SetLength(Strs, N);
  for I := 0 to N - 1 do
    Strs[I] := 'abort ' + IntToStr(I);
  AbortRaceChan := TChannelBody.Create(64);
  AbortRaceN := N;
  Aborted := 0;
  T := BeginThread(@ResetLoop, nil);
  try
    for I := 0 to N - 1 do
      if AbortRaceChan.AbortWith(Strs[I]) then
        Inc(Aborted);
  finally
    WaitForThreadTerminate(T, 0);
    CloseThread(T);
  end;
  AbortRaceChan.Reset(nil, 64);
  Bad := 0;
  for I := 0 to High(Strs) do
    if StringRefCount(Strs[I]) <> 1 then
      Inc(Bad);
  AbortRaceChan.Free;
  WriteLn(StdErr, 'Reset_and_abort_race: ', N, ' AbortWith calls (', Aborted, ' took), ', N,
    ' Resets, ', Bad, ' message(s) with a wrong reference count');
  AssertTrue('the race ran (an AbortWith took the message)', Aborted > 0);
  AssertEquals('every message string has one reference left (the test''s)', 0, Bad);
  Strs := nil;
end;

procedure TTestOffload.Claim_refused_by_the_head_check_lets_the_job_answer;
var
  Raised: Boolean;
begin
  { the race verifier's r3_claim_assert (builds with assertions): the loop
    writes the head after the offload, the worker's Respond then fails the
    decision-16 check. Round 5 raised with the claim taken: the job's
    Fail("handler raised ...") could not claim, the request was never
    answered and the Respond body never released. Now the claim is given
    back, the body released, the assertion raised, and the job's error
    answer goes out (mutants r6-claim-not-undone, r6-job-fail-checks-head) }
  FH := TRecHandler.Create(hmGateRespondCounted);
  FH.Gate := RTLEventCreate;
  CountedReleases := 0;
  try
    FEx := NewEx('GET /cr HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmGateRespondCounted);
    Raised := False;
    try
      FEx.Status := 500;                 { the loop thread names itself the head's builder }
    except
      on E: EAssertionFailed do
        Raised := True;
    end;
    AssertFalse('the first head write is legal', Raised);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertFalse('the worker''s Respond was refused', FH.RespondResult);
    AssertTrue('the job answered with its error', Until_(@CondAnswered, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    AssertTrue('a failure', FEx.Resp.Failed);
    AssertTrue('the error names the check: ' + FEx.Resp.FailText,
      (Pos('handler raised EAssertionFailed', FEx.Resp.FailText) = 1)
      and (Pos('another thread than the one that built', FEx.Resp.FailText) > 0));
    AssertEquals('the Respond body was released once', 1, AtomicLoad(CountedReleases));
    FinishExchange;
  finally
    RTLEventSetEvent(FH.Gate);
    Until_(@CondFinished, 5000);
    RTLEventDestroy(FH.Gate);
  end;
end;

procedure RaisingExHook(Ex: TExchange);
begin
  { the job's own error answer raises (once): an exception that escapes RunHandler }
  if (CurrentWorkerIndex >= 0) and (InterlockedCompareExchange(HookArmed, 0, 1) = 1) then
    raise Exception.Create('raised in the job''s error path (test hook)');
end;

procedure TTestOffload.Job_error_path_exception_releases_the_reference;
begin
  { the race verifier: TExchange.Execute was "RunHandler; Release" without
    try/finally, so an exception escaping the job's error path skipped the
    worker's Release (a leaked reference: TServer.Destroy then waits
    WorkerWaitMs and leaks the loops). The hook raises in the job's
    Fail("handler returned no response"), after its claim (mutant
    r6-execute-no-finally) }
  FH := TRecHandler.Create(hmNoAnswer);
  HookArmed := 1;
  AnswerTestHook := @RaisingExHook;
  try
    FEx := NewEx('GET /je HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmNoAnswer);
    AssertTrue('finished', Until_(@CondFinished, 5000));
    AssertTrue('the worker''s reference went back', Until_(@CondRef1, 5000));
    AssertEquals('the hook raised', 0, AtomicLoad(HookArmed));
    { the job's answer never published; the call is cancelled to end it }
    FEx.Cancel;
    AssertTrue('the cancel won', FEx.IsCanceled);
    FCall.Drop(FEx, False);
    FEx.ReleaseTransport;
    AssertTrue('recycled', Until_(@CondRecycled, 5000));
    Drive;
    AssertEquals('once', FFree0 + 1, FPool.FreeCount);
    FEx := nil;
  finally
    AnswerTestHook := nil;
  end;
end;

procedure TTestOffload.Read_after_the_request_was_dropped_is_not_the_end;
var
  C: TByteSlice;
  R: TBodyReadStatus;
begin
  { decision 15's rule "a read never returns a clean end of body unless the
    body really ended", on an unshared exchange too (S7 fix round 6,
    deviation S7-38; the contract verifier's
    C_read_after_discard_unshared_vs_shared: unshared gave brEnd; mutant
    r6-unshared-closed-reads-end) }
  FEx := NewEx('POST /d1 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  FEx.DiscardBody;
  R := FEx.TryRead(C);
  AssertTrue('unshared, after DiscardBody of a body that did not end: brCanceled', R = brCanceled);
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FEx.Chan.CloseSender;
  FinishExchange;
  { ReleaseRequest before the end }
  FEx := NewEx('POST /d2 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF);
  AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
  AssertTrue('a chunk', FEx.TryRead(C) = brData);
  FEx.ReleaseRequest;
  AssertTrue('unshared, after ReleaseRequest before the end: brCanceled', FEx.TryRead(C) = brCanceled);
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FEx.Chan.CloseSender;
  FinishExchange;
  { the end the body really had stays the end after the request was dropped }
  FEx := NewEx('POST /d3 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF);
  AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
  FEx.Chan.CloseSender;
  AssertTrue('a chunk', FEx.TryRead(C) = brData);
  AssertTrue('the end', FEx.TryRead(C) = brEnd);
  FEx.ReleaseRequest;
  AssertTrue('unshared, the end, then ReleaseRequest: still the end', FEx.TryRead(C) = brEnd);
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FinishExchange;
  { a request without a body: the end }
  FEx := NewEx('GET /d4 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  FEx.ReleaseRequest;
  AssertTrue('no body: the end', FEx.TryRead(C) = brEnd);
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FinishExchange;
end;

procedure TTestOffload.Read_after_the_end_and_release_is_the_end;
var
  C: TByteSlice;
begin
  { the contract verifier's test gap (mutant my9): on a shared exchange a
    reader that saw the end the body really had, and whose request was then
    released, reads the end again (False from ReadChunk), not brCanceled
    (EClientGone) (mutant r6-shared-closed-after-end-canceled) }
  FEx := NewEx('POST /e HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF);
  FEx.Share;
  AssertTrue('send', FEx.Chan.TrySendData(View('hello')));
  FEx.Chan.CloseSender;
  AssertTrue('a chunk', FEx.TryRead(C) = brData);
  AssertTrue('the end', FEx.TryRead(C) = brEnd);
  FEx.ReleaseRequest;
  AssertTrue('shared, the end, then ReleaseRequest: still the end', FEx.TryRead(C) = brEnd);
  AssertFalse('ReadChunk: the end, no EClientGone', FEx.ReadChunk(C));
  FEx.Respond(BodyEmpty);
  FEx.CompleteCall;
  FEx.Release;
  FEx.ReleaseTransport;
  AssertTrue('recycled', Until_(@CondRecycled, 5000));
  FEx := nil;
end;


{ ---- S7 fix round 7: the sixth S7 verifiers' findings ---- }

var
  AbaArmed, AbaIn, AbaGo: LongInt;
  AbaThread: TThreadID;

procedure AbaReleaseHook(Ex: TExchange);
var
  T0: Int64;
begin
  { the helper's Release only, once: it stops right before its reference
    count decrement (a preemption there) until the test lets it go }
  if GetCurrentThreadId <> AtomicLoadThreadId(AbaThread) then
    Exit;
  if InterlockedCompareExchange(AbaArmed, 0, 1) <> 1 then
    Exit;
  InterLockedExchange(AbaIn, 1);
  T0 := MonoNowNs;
  while (AtomicLoad(AbaGo) = 0) and (MonoNowNs - T0 < 10000000000) do
    Sleep(1);
  HappensAfter(@AbaGo);
  InterLockedExchange(AbaIn, 2);
end;

function AbaHelper(Arg: Pointer): PtrInt;
begin
  AtomicStoreThreadId(AbaThread, GetCurrentThreadId);
  TExchange(Arg).Release;
  Result := 0;
end;

function TWCase.CondAbaIn: Boolean;
begin
  Result := AtomicLoad(AbaIn) = 1;
end;

procedure TTestOffload.Last_producer_is_decided_at_the_holder_decrement;
var
  H: TExchange;
  It: TFuncItem;
  Src: TBodySource;
  F: TFramePoll;
begin
  { the sixth S7 verifiers (race lens, major; repro r2_autofinish_aba): the
    round-6 Release decided the stream's end on the reference count it
    loaded (2 = itself and the transport) and decremented later with a CAS
    that compares values only. A helper that released before the stream
    existed (its AutoFinish a no-op) and was preempted before its CAS let
    the count go 2 -> 3 -> 2 meanwhile (the loop offloaded a worker, which
    began the stream, wrote and released); the helper's CAS then succeeded
    and nobody ended the stream. S7 fix round 7 (deviation S7-43): the end
    is decided by the holder decrement that reaches 0 (the call in flight
    counts), which no later Share can undo. The hook holds the helper right
    before its reference count decrement }
  FH := TRecHandler.Create(hmStreamNoFinish);
  FH.StreamFrames := 2;
  FH.HighWater := 1024;
  AbaArmed := 1;
  AbaIn := 0;
  AbaGo := 0;
  AtomicStoreThreadId(AbaThread, TThreadID(0));
  ReleaseBeforeDecrementHook := @AbaReleaseHook;
  try
    FEx := NewEx('GET /aba HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    { the call's first Poll: a helper reference, released at once by its thread }
    H := FEx.Share;
    It := RunOnPool(FWork, @AbaHelper, H);
    AssertTrue('the helper stopped before its decrement', Until_(@CondAbaIn, 5000));
    AssertEquals('transport + helper (not yet decremented)', 2, FEx.RefCount);
    { then the call offloads a worker that begins the stream, writes and
      returns without Finish }
    StartOffload(hmStreamNoFinish);
    AssertTrue('the worker returned', Until_(@CondFinished, 5000));
    AssertTrue('the worker released (2 -> 3 -> 2)', Until_(@CondRef2, 5000));
    AssertTrue('the worker''s frames', (FH.WriteResults[0] = wrOk) and (FH.WriteResults[1] = wrOk));
    InterLockedExchange(AbaGo, 1);
    AssertTrue('the helper returned', JoinItem(It));
    AssertEquals('the transport only', 1, FEx.RefCount);
    AssertTrue('answered', Until_(@CondAnswered, 5000));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    Src := FEx.Resp.Source;
    FEx.Resp.Source := nil;
    AssertEquals('the two frames', 2, DrainFrames(FEx, Src, F, nil));
    AssertTrue('the stream ended with its last producer (got ' + IntToStr(Ord(F)) + ')', F = fpEnd);
    Src.Done(FEx);
    FinishExchange;
  finally
    { disarmed here; the hook variable is cleared by TearDown after the pool
      threads, which read it in every Release, were joined (a store here
      raced with those reads under drd) }
    InterLockedExchange(AbaArmed, 0);
    InterLockedExchange(AbaGo, 1);
  end;
end;

procedure TTestOffload.Call_in_flight_keeps_the_stream_for_its_next_producer;
var
  H: TExchange;
  Src: TBodySource;
  F: TFramePoll;
  W: TWriteResult;
begin
  { the sixth S7 verifiers (race lens, major; repro r1_autofinish): the call
    begins a stream, shares it with a helper and then offloads a worker in
    the same Poll. When the helper released first, round 6's rule saw only
    the transport's reference left and ended the stream: the client got a
    complete chunked body without the worker's frames, whose writes got
    wrCanceled. S7 fix round 7 (deviation S7-43): the call in flight is a
    producer of the stream as it is a holder of the request (hyper: the
    future drops its sender when it completes) }
  FH := TRecHandler.Create(hmWriteNoBegin);
  FH.StreamFrames := 2;
  FH.FrameLen := 16;
  FEx := NewEx('GET /r1 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  { the call's Poll, on the loop: BeginStream, a helper, then the worker }
  AssertTrue('BeginStream', FEx.BeginStream(1024));
  H := FEx.Share;
  AssertTrue('the helper writes', H.WriteString('h1;') = wrOk);
  H.Release;
  W := FEx.WriteString('c1;');
  AssertTrue('the call still writes after the helper released (got ' + IntToStr(Ord(W)) + ')', W = wrOk);
  StartOffload(hmWriteNoBegin);
  AssertTrue('the worker returned', Until_(@CondFinished, 5000));
  AssertTrue('the worker released', Until_(@CondRef1, 5000));
  AssertTrue('the worker''s first frame was taken', FH.WriteResults[0] = wrOk);
  AssertTrue('the worker''s second frame was taken', FH.WriteResults[1] = wrOk);
  Src := FEx.Resp.Source;
  AssertEquals('h1, c1 and the worker''s two frames', 4, DrainFrames(FEx, Src, F, nil));
  AssertTrue('open while the call is in flight', F = fpPending);
  AssertTrue('ready', FCall.Poll(FEx) = cpReady);
  FCall.Drop(FEx, True);
  FEx.CompleteCall;
  FEx.Resp.Source := nil;
  AssertEquals('no more frames', 0, DrainFrames(FEx, Src, F, nil));
  AssertTrue('the completion of the call, the last producer, ended the stream', F = fpEnd);
  Src.Done(FEx);
  FinishExchange;
end;

procedure TTestOffload.Inline_stream_without_finish_ends_at_completion;
var
  Src: TBodySource;
  F: TFramePoll;
begin
  { the sixth S7 verifiers (contract lens, minor; K_inline_stream_without_finish):
    an unshared call that began a stream, wrote and completed without Finish
    left the response open forever (nobody may write to an unshared exchange
    after its completion, 3.2.3 rule 2). S7 fix round 7 (deviation S7-44):
    the completion ends it, as hyper drops the future's sender and as the
    last producer of a shared exchange does }
  FEx := NewEx('GET /inline HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  AssertTrue('BeginStream', FEx.BeginStream(1024));
  AssertTrue('a frame', FEx.WriteString('hello') = wrOk);
  FEx.CompleteCall;
  Src := FEx.Resp.Source;
  FEx.Resp.Source := nil;
  AssertEquals('the frame', 1, DrainFrames(FEx, Src, F, nil));
  AssertTrue('the completion ended the stream (got ' + IntToStr(Ord(F)) + ')', F = fpEnd);
  Src.Done(FEx);
  FinishExchange;
end;

procedure TTestOffload.Second_offload_raises;
var
  H2: TRecHandler;
  Raised: Boolean;
begin
  { the sixth S7 verifiers (race lens, minor; K_offload_twice): nothing
    refused a second Offload of one request: it overwrote the handler, added
    a reference and submitted the exchange (an intrusive work item) again,
    which links it to itself while the first submission is queued. S7 fix
    round 7 (deviation S7-45): it raises, and nothing changes }
  FH := TRecHandler.Create(hmWaitThenRespond);
  FH.Gate := RTLEventCreate;
  H2 := TRecHandler.Create(hmNoAnswer);
  try
    FEx := NewEx('GET /twice HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    StartOffload(hmWaitThenRespond);
    Raised := False;
    try
      FEx.Offload(FWork, H2);
    except
      on E: Exception do
        Raised := True;
    end;
    AssertTrue('a second Offload of the request raises', Raised);
    AssertEquals('no second reference', 2, FEx.RefCount);
    RTLEventSetEvent(FH.Gate);
    AssertTrue('the first job ran', Until_(@CondFinished, 5000));
    AssertTrue('its handler answered', FH.RespondResult);
    AssertEquals('the second handler never ran', 0, AtomicLoad(H2.Started));
    AssertTrue('ready', FCall.Poll(FEx) = cpReady);
    FCall.Drop(FEx, True);
    FEx.CompleteCall;
    FinishExchange;
  finally
    RTLEventSetEvent(FH.Gate);
    FWork.Shutdown(5000);
    RTLEventDestroy(FH.Gate);
    H2.Free;
  end;
end;

var
  PostSeenCount: LongInt;
  PostHookRuns: LongInt;
  NoopPosted: TLoopMsg;

procedure CountAtPushHook(Loop: TLoop);
begin
  InterLockedIncrement(PostHookRuns);
  InterLockedExchange(PostSeenCount, Loop.PostsInProgress);
end;

procedure NoopMsgProc(Loop: TLoop; Arg: Pointer);
begin
end;

function PostFromThread(Arg: Pointer): PtrInt;
begin
  TLoop(Arg).Post(@NoopPosted);
  Result := 0;
end;

procedure TTestOffload.Post_counts_the_poster_before_the_push;
var
  It: TFuncItem;
begin
  { the sixth S7 verifiers (race lens, minor: a test gap): the mutant that
    moves AtomicInc(Posting) after Inbox.Push survived, since the test's
    hook ran after both. The message can be handled, and the loop freed by
    TServer.Destroy, as soon as it is pushed, so the count must cover the
    push (deviation S7-37). The hook runs right before the push }
  PostSeenCount := -1;
  PostHookRuns := 0;
  NoopPosted := Default(TLoopMsg);
  NoopPosted.Kind := lmCall;
  NoopPosted.Proc := @NoopMsgProc;
  PostBeforePushHook := @CountAtPushHook;
  try
    It := RunOnPool(FWork, @PostFromThread, FLoop);
    AssertTrue('posted', JoinItem(It));
  finally
    PostBeforePushHook := nil;
  end;
  AssertEquals('the hook ran once', 1, AtomicLoad(PostHookRuns));
  AssertEquals('Posting counts the call before its push', 1, AtomicLoad(PostSeenCount));
  FLoop.ProcessInbox;
  AssertEquals('none in Post afterwards', 0, FLoop.PostsInProgress);
end;

procedure TSrvHandler.Run(Ex: TExchange);
var
  Dst: TBytes;
  N: SizeInt;
  S: RawByteString;
  I: Integer;
  Tr: THttpHeaders;
  C: TByteSlice;
begin
  if PathIs(Ex, '/hello') then
  begin
    Ex.ReleaseRequest;
    Ex.Respond(BodyString('hello'));
  end
  else if PathIs(Ex, '/echo') then
  begin
    Dst := nil;
    N := Ex.ReadAll(Dst, 0);
    SetString(S, PAnsiChar(@Dst[0]), N);
    if Ex.RequestTrailers.Count > 0 then
      Ex.ResponseHeaders.Add('x-trailer', Ex.RequestTrailers.Value(0));
    Ex.ReleaseRequest;
    Ex.Respond(BodyString(S));
  end
  else if PathIs(Ex, '/stream') then
  begin
    Ex.ReleaseRequest;
    Ex.BeginStream(256);
    for I := 1 to 100 do
      if Ex.WriteString(Format('line %d' + #10, [I])) <> wrOk then
        Exit;
    Tr := THttpHeaders.Create;
    try
      Ex.Finish(Tr);
    finally
      Tr.Free;
    end;
  end
  else if PathIs(Ex, '/sleep') then
  begin
    Ex.ReleaseRequest;
    Sleep(300);
    if Ex.IsCanceled then
      InterLockedExchange(SleepCanceled, 1);
    Ex.BeginStream;
    SleepWrite := Ex.WriteString('late');
    HappensBefore(@SleepDone);
    InterLockedExchange(SleepDone, 1);
  end
  else if PathIs(Ex, '/sleep2') then
  begin
    { still running when the server is destroyed: its Release is the last
      one, posted to a loop whose thread has exited }
    Ex.ReleaseRequest;
    InterLockedExchange(Sleep2Started, 1);
    Sleep(300);
    Ex.Respond(BodyEmpty);
  end
  else if PathIs(Ex, '/stream-echo') then
  begin
    { decision 15: the response streams while the request body is read }
    Ex.BeginStream(256);
    while Ex.ReadChunk(C) do
    begin
      SetString(S, PAnsiChar(C.P), C.Len);
      if Ex.WriteString(S) <> wrOk then
        Exit;
    end;
    Ex.Finish(nil);
  end
  else if PathIs(Ex, '/answer-then-read') then
  begin
    { decision 15: the answer goes out first; the body is read after it,
      and its end is seen while the connection stays open (deviation S7-27) }
    Ex.Respond(BodyString('ok'));
    try
      Dst := nil;
      N := Ex.ReadAll(Dst, 0);
      SetString(AnswerReadBody, PAnsiChar(@Dst[0]), N);
    except
      on E: Exception do
        AnswerReadErr := E.ClassName;
    end;
    HappensBefore(@AnswerReadDone);
    InterLockedExchange(AnswerReadDone, 1);
  end
  else if PathIs(Ex, '/fail') then
    raise Exception.Create('handler fails')
  else
  begin
    Ex.Status := 404;
    Ex.Respond(BodyEmpty);
  end;
end;

destructor TSrvService.Destroy;
begin
  Call_.Free;
  inherited Destroy;
end;

function TSrvService.Call(Ex: TExchange): TServiceCall;
begin
  Result := Call_;
end;

function TSrvApp.NewService(Loop: TLoop): THttpService;
var
  S: TSrvService;
begin
  S := TSrvService.Create;
  S.Call_ := TOffloadCall.Create;
  S.Call_.Pool := Srv.Workers;
  S.Call_.Handler := H;
  Result := S;
end;

function Connect(Port: Word): cint;
var
  A: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Result, @A, SizeOf(A)) <> 0 then
    raise Exception.Create('connect failed');
end;

procedure SendAll(Fd: cint; const S: RawByteString);
var
  Off, R: SizeInt;
begin
  Off := 0;
  while Off < Length(S) do
  begin
    R := fpSend(Fd, PAnsiChar(S) + Off, Length(S) - Off, 0);
    if R <= 0 then
      raise Exception.Create('send failed');
    Inc(Off, R);
  end;
end;

function CountOf(const Sub, S: RawByteString): Integer;
var
  P: SizeInt;
begin
  Result := 0;
  P := Pos(Sub, S);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(Sub, S, P + Length(Sub));
  end;
end;

{ reads until Marker was seen N times (N < 0: until EOF), or 10 s }
function RecvUntil(Fd: cint; const Marker: RawByteString; N: Integer; out Eof: Boolean): RawByteString;
var
  Buf: array[0..65535] of AnsiChar;
  R: ssize_t;
  TV: TTimeVal;
  S: RawByteString;
begin
  Result := '';
  Eof := False;
  TV.tv_sec := 10;
  TV.tv_usec := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  while (N < 0) or (CountOf(Marker, Result) < N) do
  begin
    R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
    if R <= 0 then
    begin
      Eof := R = 0;
      Exit;
    end;
    SetString(S, PAnsiChar(@Buf[0]), R);
    Result := Result + S;
  end;
end;

{ reads until at least Len bytes arrived (or EOF / 10 s) }
function RecvLen(Fd: cint; Len: Integer): RawByteString;
var
  Buf: array[0..65535] of AnsiChar;
  R: ssize_t;
  TV: TTimeVal;
  S: RawByteString;
begin
  Result := '';
  TV.tv_sec := 10;
  TV.tv_usec := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  while Length(Result) < Len do
  begin
    R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
    if R <= 0 then
      Exit;
    SetString(S, PAnsiChar(@Buf[0]), R);
    Result := Result + S;
  end;
end;

procedure TTestWorkerServer.Server_offloaded_requests;
var
  App: TSrvApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got, Big, Reqs: RawByteString;
  Eof: Boolean;
  I: Integer;
  T0: Int64;
begin
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 2;
  Cfg.Workers := 4;
  Cfg.H1.AutoDateHeader := False;
  App := TSrvApp.Create;
  App.H := TSrvHandler.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv := Srv;
  SleepCanceled := 0;
  SleepDone := 0;
  try
    Srv.Start;
    AssertTrue('the pool exists', Srv.Workers <> nil);
    AssertEquals('line 1690', 4, Srv.Workers.ThreadCount);
    Fd := Connect(Srv.Port);
    try
      { 1. an offloaded GET }
      SendAll(Fd, 'GET /hello HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, 'hello', 1, Eof);
      AssertEquals('HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF + 'hello', Got);
      { 2. a 200 000-byte body read on the worker and echoed }
      SetLength(Big, 200000);
      for I := 1 to Length(Big) do
        Big[I] := AnsiChar(Ord('a') + I mod 26);
      SendAll(Fd, 'POST /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 200000'
        + CRLF + CRLF + Big);
      Got := RecvLen(Fd, Length('HTTP/1.1 200 OK' + CRLF + 'content-length: 200000' + CRLF + CRLF)
        + 200000);
      AssertEquals('HTTP/1.1 200 OK' + CRLF + 'content-length: 200000' + CRLF + CRLF + Big, Got);
      { 3. a chunked body with a trailer }
      SendAll(Fd, 'POST /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Transfer-Encoding: chunked'
        + CRLF + CRLF + '3' + CRLF + 'abc' + CRLF + '2' + CRLF + 'de' + CRLF + '0' + CRLF
        + 'X-Sum: 5' + CRLF + CRLF);
      Got := RecvUntil(Fd, 'abcde', 1, Eof);
      AssertEquals('HTTP/1.1 200 OK' + CRLF + 'x-trailer: 5' + CRLF + 'content-length: 5' + CRLF
        + CRLF + 'abcde', Got);
      { 4. 16 pipelined offloaded requests, answered in order }
      Reqs := '';
      for I := 1 to 16 do
        Reqs := Reqs + 'GET /hello HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF;
      SendAll(Fd, Reqs);
      Got := RecvUntil(Fd, 'hello', 16, Eof);
      AssertEquals(16, CountOf('HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF
        + 'hello', Got));
      { 5. a streamed response from the worker (chunked, one chunk per write) }
      SendAll(Fd, 'GET /stream HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, '0' + CRLF + CRLF, 1, Eof);
      AssertTrue('chunked', Pos('transfer-encoding: chunked', Got) > 0);
      AssertEquals('100 chunks', 100, CountOf('line ', Got));
      AssertTrue('the last line', Pos('9' + CRLF + 'line 100' + #10 + CRLF + '0' + CRLF + CRLF, Got) > 0);
      { 6. a handler that raises: no response, the connection is closed }
      SendAll(Fd, 'GET /fail HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, '', -1, Eof);
      AssertTrue('closed', Eof);
      AssertEquals('nothing written', '', Got);
    finally
      fpClose(Fd);
    end;
    { 7. the client leaves while the handler sleeps: the handler sees the cancel }
    Fd := Connect(Srv.Port);
    SendAll(Fd, 'GET /sleep HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    Sleep(50);
    fpClose(Fd);
    T0 := MonoNowNs;
    while (AtomicLoad(SleepDone) = 0) and (MonoNowNs - T0 < 5000000000) do
      Sleep(5);
    HappensAfter(@SleepDone);
    AssertEquals('the handler finished', 1, SleepDone);
    AssertEquals('it saw the cancel', 1, SleepCanceled);
    AssertTrue('its stream was refused', SleepWrite = wrCanceled);
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    App.H.Free;
    App.Free;
  end;
end;

procedure TTestWorkerServer.Server_destroy_recycles_what_workers_release;
var
  App: TSrvApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Live0: LongInt;
  T0: Int64;
begin
  { deviation S7-10: TServer.Destroy shuts the pool down after the loop
    threads exited, then processes every loop's inbox, so the exchange whose
    last reference a worker gave up (FreeMsg posted to a loop without a
    thread) is recycled into its loop's pool and freed with it (mutant
    v-server-no-process-inbox: the exchange is never freed) }
  Live0 := AtomicLoad(ExchangesLive);
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 1;
  Cfg.Workers := 2;
  Cfg.H1.AutoDateHeader := False;
  App := TSrvApp.Create;
  App.H := TSrvHandler.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv := Srv;
  Sleep2Started := 0;
  Fd := -1;
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    SendAll(Fd, 'GET /sleep2 HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    T0 := MonoNowNs;
    while (AtomicLoad(Sleep2Started) = 0) and (MonoNowNs - T0 < 5000000000) do
      Sleep(1);
    AssertEquals('the handler runs', 1, AtomicLoad(Sleep2Started));
  finally
    Srv.Free;                         { Stop(0), Wait, abort, pool shutdown, inboxes }
    if Fd >= 0 then
      fpClose(Fd);
    App.H.Free;
    App.Free;
  end;
  AssertEquals('every exchange was recycled and freed', Live0, AtomicLoad(ExchangesLive));
end;

procedure TTestWorkerServer.Server_worker_reads_after_its_answer;
var
  App: TSrvApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  T0: Int64;
begin
  { decision 15 end to end, through the dispatcher: (1) an echo that streams
    each chunk of the request body back as it reads it: the client gets the
    first chunk back before it sends the second; (2) a handler that answers
    first and reads the body afterwards: the client has the whole response
    before it sends the body; the worker reads it and sees its end while the
    connection stays open (deviation S7-27: the ended body's sender is
    dropped at the next head read; mutant d15-dispatcher-keeps-ended-sender:
    the worker waits for ever), and the connection serves the next request }
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 1;
  Cfg.Workers := 2;
  Cfg.WorkerWaitMs := 2000;
  Cfg.H1.AutoDateHeader := False;
  App := TSrvApp.Create;
  App.H := TSrvHandler.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv := Srv;
  AnswerReadDone := 0;
  AnswerReadBody := '';
  AnswerReadErr := '';
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      { 1. the echo }
      SendAll(Fd, 'POST /stream-echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10'
        + CRLF + CRLF + 'hello');
      Got := RecvUntil(Fd, 'hello' + CRLF, 1, Eof);
      AssertTrue('the first chunk came back before the body ended (got ' + Got + ')',
        Pos('5' + CRLF + 'hello' + CRLF, Got) > 0);
      AssertTrue('chunked', Pos('transfer-encoding: chunked', Got) > 0);
      SendAll(Fd, 'world');
      Got := RecvUntil(Fd, '0' + CRLF + CRLF, 1, Eof);
      AssertEquals('the second chunk, then the end', '5' + CRLF + 'world' + CRLF + '0' + CRLF + CRLF, Got);
      { 2. the answer, then the body }
      SendAll(Fd, 'POST /answer-then-read HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10'
        + CRLF + CRLF);
      Got := RecvUntil(Fd, 'ok', 1, Eof);
      AssertEquals('the answer before the body', 'HTTP/1.1 200 OK' + CRLF + 'content-length: 2' + CRLF
        + CRLF + 'ok', Got);
      SendAll(Fd, '0123456789');
      T0 := MonoNowNs;
      while (AtomicLoad(AnswerReadDone) = 0) and (MonoNowNs - T0 < 5000000000) do
        Sleep(2);
      AssertEquals('the worker saw the end of the body', 1, AtomicLoad(AnswerReadDone));
      HappensAfter(@AnswerReadDone);
      AssertEquals('no error', '', AnswerReadErr);
      AssertEquals('the whole body', '0123456789', AnswerReadBody);
      { the connection goes on }
      SendAll(Fd, 'GET /hello HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, 'hello', 1, Eof);
      AssertEquals('HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF + 'hello', Got);
    finally
      fpClose(Fd);
    end;
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    App.H.Free;
    App.Free;
  end;
end;

procedure TTestWorkerServer.Server_abort_after_answer_gives_body_error;
var
  App: TSrvApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  T0: Int64;
begin
  { the fourth S7 verifiers (mutant my6: the dispatcher's SenderDropGuard
    without its SendError): the worker answered (the call completed) and
    reads the body, 3 of 10 bytes arrived; the server is destroyed, which
    aborts the connection (DropAll). The body sender goes with hyper's
    incomplete-message error, so the read raises EBodyError and does not
    report the end (decision 15) }
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 1;
  Cfg.Workers := 2;
  Cfg.WorkerWaitMs := 5000;
  Cfg.H1.AutoDateHeader := False;
  App := TSrvApp.Create;
  App.H := TSrvHandler.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv := Srv;
  AnswerReadDone := 0;
  AnswerReadBody := '';
  AnswerReadErr := '';
  Fd := -1;
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    SendAll(Fd, 'POST /answer-then-read HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10'
      + CRLF + CRLF + '012');
    Got := RecvUntil(Fd, 'ok', 1, Eof);
    AssertEquals('the answer', 'HTTP/1.1 200 OK' + CRLF + 'content-length: 2' + CRLF + CRLF + 'ok', Got);
    Sleep(50);                       { the worker reads the 3 bytes and waits for more }
  finally
    Srv.Free;                        { Stop(0): the connection is aborted (DropAll) }
    if Fd >= 0 then
      fpClose(Fd);
    App.H.Free;
    App.Free;
  end;
  T0 := MonoNowNs;
  while (AtomicLoad(AnswerReadDone) = 0) and (MonoNowNs - T0 < 2000000000) do
    Sleep(2);
  AssertEquals('the read returned', 1, AtomicLoad(AnswerReadDone));
  HappensAfter(@AnswerReadDone);
  AssertEquals('a body error, not the end of the body', 'EBodyError', AnswerReadErr);
end;

type
  { S7 fix round 5: a call that answers on the loop and gives a reference to
    another thread (an SSE-style producer), which releases it later }
  THolderItem = class(TWorkItem)
  public
    Ex: TExchange;
    procedure Execute; override;
  end;

  THolderCall = class(TServiceCall)
  public
    Pool: TWorkerPool;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  THolderService = class(THttpService)
  public
    C: THolderCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  THolderApp = class
  public
    Pool: TWorkerPool;
    function NewService(Loop: TLoop): THttpService;
  end;

var
  HolderStarted, HolderReleased: LongInt;
  { S7 fix round 6: the holder's thread, the hook's sleep, and what the hook saw }
  HolderThread: TThreadID;
  HolderHookSleepMs: Integer;
  HolderPosted, ServerFreed, FreedSeenInPost: LongInt;

procedure HolderPostHook(Loop: TLoop);
begin
  { TLoop.Post on the holder's thread, right after the push: the message can
    be handled from here on, while Post still uses the loop (S7 fix round 6,
    the fifth S7 verifiers' repro r1_destroy_post) }
  if GetCurrentThreadId <> AtomicLoadThreadId(HolderThread) then
    Exit;
  InterLockedExchange(HolderPosted, 1);
  if HolderHookSleepMs > 0 then
    Sleep(HolderHookSleepMs);
  if AtomicLoad(ServerFreed) <> 0 then
    InterLockedExchange(FreedSeenInPost, 1);
end;

procedure THolderItem.Execute;
begin
  AtomicStoreThreadId(HolderThread, GetCurrentThreadId);
  InterLockedExchange(HolderStarted, 1);
  Sleep(300);
  Ex.Release;
  HappensBefore(@HolderReleased);
  InterLockedExchange(HolderReleased, 1);
  Free;
end;

function THolderCall.Poll(Ex: TExchange): TCallPoll;
var
  It: THolderItem;
begin
  It := THolderItem.Create;
  It.Ex := Ex.Share;
  Pool.Submit(It);
  Ex.Respond(BodyString('held'));
  Result := cpReady;
end;

destructor THolderService.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

function THolderService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

function THolderApp.NewService(Loop: TLoop): THttpService;
var
  S: THolderService;
begin
  S := THolderService.Create;
  S.C := THolderCall.Create;
  S.C.Pool := Pool;
  Result := S;
end;

procedure RunHolderServer(T: TTestCase; HookSleepMs: Integer);
var
  App: THolderApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  Live0: LongInt;
begin
  { a call that answers on the loop and gives a reference to a thread of
    another pool (an SSE-style producer, design 3.5), which releases it
    300 ms later, after TServer.Free began. The hook runs in that release's
    TLoop.Post right after the push, on the holder's thread only, and
    sleeps HookSleepMs there }
  Live0 := AtomicLoad(ExchangesLive);
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 1;
  Cfg.Workers := 1;
  Cfg.WorkerWaitMs := 5000;
  Cfg.H1.AutoDateHeader := False;
  App := THolderApp.Create;
  App.Pool := TWorkerPool.Create(1);
  HolderStarted := 0;
  HolderReleased := 0;
  HolderPosted := 0;
  ServerFreed := 0;
  FreedSeenInPost := 0;
  HolderThread := TThreadID(0);
  HolderHookSleepMs := HookSleepMs;
  PostAfterPushHook := @HolderPostHook;
  Srv := TServer.Create(Cfg, @App.NewService);
  Fd := -1;
  try
    try
      Srv.Start;
      Fd := Connect(Srv.Port);
      SendAll(Fd, 'GET /held HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
      Got := RecvUntil(Fd, 'held', 1, Eof);
      T.AssertEquals('the answer', 'HTTP/1.1 200 OK' + CRLF + 'content-length: 4' + CRLF + CRLF + 'held', Got);
    finally
      Srv.Free;
      InterLockedExchange(ServerFreed, 1);
      if Fd >= 0 then
        fpClose(Fd);
      App.Pool.Shutdown(5000);
      App.Pool.Free;
      App.Free;
    end;
  finally
    PostAfterPushHook := nil;
  end;
  HappensAfter(@HolderReleased);
  T.AssertEquals('the holder released', 1, AtomicLoad(HolderReleased));
  { what Destroy guarantees: the holder's release reached TLoop.Post and
    left it before TServer.Free returned (the flag the holder sets after its
    Release returned is not ordered with Free: round 5 asserted it) }
  T.AssertEquals('the holder''s release posted before TServer.Free returned', 1, AtomicLoad(HolderPosted));
  T.AssertEquals('TServer.Free returned only after the holder left TLoop.Post', 0, AtomicLoad(FreedSeenInPost));
  T.AssertEquals('every exchange was recycled and freed', Live0, AtomicLoad(ExchangesLive));
end;

procedure TTestWorkerServer.Server_destroy_waits_for_an_outside_holder;
begin
  { the fourth S7 verifiers (repro_destroy_with_holder: a use after free):
    a reference Share gave to another thread than the server's pool is
    released 300 ms after TServer.Free began. S7 fix round 5 (deviation
    S7-10): Destroy processes the loops' inboxes until every exchange is
    back in its pool, so the release reaches a live loop and the exchange
    is recycled and freed with it (mutant r5-destroy-no-holder-wait) }
  RunHolderServer(Self, 0);
end;

procedure TTestWorkerServer.Server_destroy_waits_for_a_poster_to_leave_post;
begin
  { the fifth S7 verifiers (r1_destroy_post: memcheck "Invalid read of size
    4 at TLoop.Post ... inside a block of size 15,936 free'd"): the holder's
    FreeMsg was handled and the exchange was back in its pool while the
    holder was still inside TLoop.Post; Destroy freed the loop under it.
    S7 fix round 6 (deviation S7-37): Destroy also waits until no thread is
    inside Post (TLoop.Posting). The hook keeps the holder 300 ms in Post
    after its push (mutant r6-destroy-no-post-wait) }
  RunHolderServer(Self, 300);
end;


type
  { S7 fix round 6: hyper's examples/echo.rs (Response::new(req.into_body()))
    on the loop thread: the response source reads the request body after the
    call completed (the contract verifier's C_inline_echo_*) }
  TEchoReadSource = class(TBodySource)
  public
    Ref: TExchange;                 { set when the call shared the exchange }
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

  TEchoReadCall = class(TServiceCall)
  public
    UseShare: Boolean;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TEchoReadService = class(THttpService)
  public
    C: TEchoReadCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TEchoReadApp = class
  public
    UseShare: Boolean;
    function NewService(Loop: TLoop): THttpService;
  end;

function TEchoReadSource.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
var
  C: TByteSlice;
begin
  Data := BodyEmpty;
  Trailers := nil;
  while True do
    case Ex.TryRead(C) of
      brData:
        begin
          Data := BodyCopy(Ex, C.P, C.Len);
          Exit(fpData);
        end;
      brTrailers:
        ;
      brPending:
        Exit(fpPending);
      brEnd:
        Exit(fpEnd);
    else
      begin
        Ex.SetBodyErrorText('request body read failed');
        Exit(fpError);
      end;
    end;
end;

procedure TEchoReadSource.Done(Ex: TExchange);
begin
  if Ref <> nil then
  begin
    Ref := nil;
    Ex.Release;
  end;
  Free;
end;

function TEchoReadCall.Poll(Ex: TExchange): TCallPoll;
var
  S: TEchoReadSource;
begin
  S := TEchoReadSource.Create;
  if UseShare then
    S.Ref := Ex.Share;                 { the source holds the request (3.4) }
  Ex.RespondStream(S);
  Result := cpReady;
end;

destructor TEchoReadService.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

function TEchoReadService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

function TEchoReadApp.NewService(Loop: TLoop): THttpService;
var
  S: TEchoReadService;
begin
  S := TEchoReadService.Create;
  S.C := TEchoReadCall.Create;
  S.C.UseShare := UseShare;
  Result := S;
end;

function EchoReadRun(UseShare: Boolean; out Eof: Boolean): RawByteString;
var
  App: TEchoReadApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
begin
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := 1;
  Cfg.Workers := 1;
  Cfg.WorkerWaitMs := 2000;
  Cfg.H1.AutoDateHeader := False;
  App := TEchoReadApp.Create;
  App.UseShare := UseShare;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, 'POST /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10'
        + CRLF + CRLF + 'hello');
      Sleep(100);
      SendAll(Fd, 'world');
      Result := RecvUntil(Fd, '0' + CRLF + CRLF, 1, Eof);
    finally
      fpClose(Fd);
    end;
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    App.Free;
  end;
end;

procedure TTestWorkerServer.Server_inline_echo_needs_share;
var
  Got: RawByteString;
  Eof: Boolean;
begin
  { the contract verifier's C_inline_echo_unshared: an unshared exchange
    drops its request at the call's completion, and the source's read then
    returned brEnd: "transfer-encoding: chunked ... 0 CRLF CRLF", a clean end
    with 0 of 10 bytes. S7 fix round 6 (deviation S7-38): the read reports
    brCanceled, the body fails and the connection closes without the
    terminating chunk (mutant r6-unshared-closed-reads-end). A source that
    holds the request with Share in the call's Poll echoes the body }
  Got := EchoReadRun(False, Eof);
  { the source's first poll fails, so the connection ends with an error
    before the buffered head is flushed (0 bytes here); what matters is that
    no complete response arrives }
  AssertEquals('unshared: no terminating chunk (the body failed): ' + Got, 0,
    Pos(CRLF + '0' + CRLF + CRLF, Got));
  AssertTrue('unshared: the connection closed', Eof);
  Got := EchoReadRun(True, Eof);
  AssertTrue('shared: the whole body echoed: ' + Got,
    Pos('5' + CRLF + 'hello' + CRLF + '5' + CRLF + 'world' + CRLF + '0' + CRLF + CRLF, Got) > 0);
end;

begin
  IterPct := StrToIntDef(GetEnvironmentVariable('WD_ITER'), 100);
  RegisterTest(TTestPool);
  RegisterTest(TTestParkRaces);
  RegisterTest(TTestOffload);
  RegisterTest(TTestWorkerServer);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.
