{ bearings.rt.workers - a pool of threads that run blocking code.

  The event loops must never block: one loop thread serves many connections,
  so a handler that waits for a database or a file would stall all of them.
  A request handler that may block is therefore "offloaded": the loop thread
  submits a work item to this pool, a worker thread runs it, and the result
  goes back to the loop. TExchange (bearings.http.exchange) is the work item for
  a request; it derives from TWorkItem and carries the queue link itself, so
  queueing it allocates nothing.

  Main types: TWorkItem (a unit of work with a virtual Execute), TWorkerPool
  (the threads and the FIFO queue) and TWorkerHooks (optional per-thread
  start and stop callbacks, e.g. to open one database connection per worker).

  How it works: Submit appends to a FIFO queue under a mutex
  (TRTLCriticalSection, a pthread mutex, which valgrind drd understands). A
  worker with nothing to do first spins briefly on the queue (see SpinNs),
  then parks on its own TParker, a futex-based wait (bearings.rt.sync). Submit
  wakes one parked worker only when no worker is spinning, so while the pool
  is busy queueing an item costs no system call. A worker keeps taking items
  until the queue is empty, then spins or parks again.

  Exceptions: an exception that escapes TWorkItem.Execute is caught on the
  worker, written to stderr, and the worker goes on with the next item.
  TExchange.Execute already catches handler exceptions and turns them into
  an error response, so this is only a safety net.

  Shutdown: once Shutdown starts, no new item is accepted (TrySubmit returns
  False, Submit raises EWorkerPoolStopped). The workers finish every item
  already queued, call TWorkerHooks.ThreadStopping and exit. Shutdown waits
  up to WaitMs (-1: no limit) and joins the threads if all of them exited;
  Alive tells how many are still running when it returned.

  Threading: Submit, TrySubmit, QueueLength, Saturated, Alive, Executed and
  SpinNs may be used from any thread. Shutdown and Destroy are called once,
  by the owner of the pool, and never from a worker (a worker would wait for
  itself). CurrentWorkerIndex reports on the calling thread. }
unit bearings.rt.workers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, bearings.rt.sync;

type
  TWorkItem = class                  { the queue link lives in the item: queueing allocates nothing }
  public
    FNextWork: TWorkItem;            { next item in the pool's queue; owned by the pool while queued }
    procedure Execute; virtual; abstract;
  end;

  TWorkerHooks = class
  public
    procedure ThreadStarted(Index: Integer); virtual;      { on the new worker, before its first item; e.g. open a DB connection }
    procedure ThreadStopping(Index: Integer); virtual;   { on the worker, after its last item }
  end;

  TWorkerPool = class;

  { One per worker thread. The pool keeps them in an array that never moves
    while threads run: WorkerMain gets a pointer to its slot. }
  PWorkerSlot = ^TWorkerSlot;
  TWorkerSlot = record
    Pool: TWorkerPool;
    Index: Integer;
    Thread: TThreadID;
    Parker: TParker;                 { the worker parks here when the queue is empty }
    Joined: Boolean;                 { thread already joined and its handle closed }
  end;

  TWorkerPool = class
  private
    FThreads: Integer;
    FHooks: TWorkerHooks;
    FQueueLimit: Integer;
    FLock: TRTLCriticalSection;
    FHead, FTail: TWorkItem;         { FIFO of queued items, linked through FNextWork; under FLock }
    FCount: LongInt;                 { queued items; written under FLock, read without it }
    FSlots: array of TWorkerSlot;
    FIdle: array of PWorkerSlot;     { stack of parked workers (FIdleCount used); under FLock }
    FIdleCount: Integer;
    FStopping: Boolean;              { Shutdown started: no new items, workers exit when the queue is empty }
    FShutDone: Boolean;
    FAlive: LongInt;                 { worker threads not yet exited }
    FAllExited: PRTLEvent;           { set by the last worker to exit }
    FExecuted: Int64;
    FSpinners: LongInt;              { workers spinning on the queue (0 or 1); under FLock }
    FSpinNs: Int64;
    function PopLocked(out Wake: PWorkerSlot): TWorkItem;
    function TakeOrPark(Slot: PWorkerSlot): TWorkItem;
    function GetAlive: LongInt;
    procedure SetSpinNs(V: Int64);
  public
    { Threads <= 0 picks Min(32, DefaultLoopCount + 4), DefaultLoopCount being
      the number of CPUs the process may use. QueueLimit 0 means no limit
      (Saturated is then always False). The threads start at once. }
    constructor Create(Threads: Integer; Hooks: TWorkerHooks = nil; QueueLimit: Integer = 0);
    { Runs Shutdown(-1) if it did not run. If some thread is still running
      (an earlier Shutdown timed out), the object is not freed, because those
      threads still use the slots. }
    destructor Destroy; override;
    procedure Submit(Item: TWorkItem);    { queue Item; raises EWorkerPoolStopped after Shutdown started }
    { like Submit, but returns False instead of raising when the pool is shut down }
    function TrySubmit(Item: TWorkItem): Boolean;
    function QueueLength: Integer;        { queued items not yet taken; read without the lock, so only a hint }
    { QueueLimit > 0 and QueueLength >= QueueLimit. Lets a caller answer
      503 Service Unavailable at once instead of queueing a request that
      would wait too long. }
    function Saturated: Boolean;
    procedure Shutdown(WaitMs: Integer);  { refuse new items, run the queued ones, join the threads }
    property ThreadCount: Integer read FThreads;
    { Nanoseconds an idle worker watches the queue before it parks (0: park at
      once). At most one worker spins at a time. Spinning costs CPU but saves
      the futex wake and the thread switch when items arrive in a steady
      stream. Default DEFAULT_SPIN_NS; may be set from any thread. }
    property SpinNs: Int64 read FSpinNs write SetSpinNs;
    property QueueLimit: Integer read FQueueLimit;
    { worker threads still running (0 after a complete Shutdown) }
    property Alive: LongInt read GetAlive;
    { items executed so far (atomic counter; statistics and tests) }
    property Executed: Int64 read FExecuted;
  end;

  EWorkerPoolStopped = class(Exception);

const
  DEFAULT_SPIN_NS = 20000;           { 20 microseconds }

{ The index (0 .. ThreadCount-1) of the calling worker thread, or -1 when
  the calling thread is not a pool worker. }
function CurrentWorkerIndex: Integer;

implementation

uses
  bearings.rt.cpu, bearings.rt.clock;

threadvar
  TvWorkerIndex: Integer;
  TvIsWorker: Boolean;

function CurrentWorkerIndex: Integer;
begin
  if TvIsWorker then
    Result := TvWorkerIndex
  else
    Result := -1;
end;

{ TWorkerHooks }

procedure TWorkerHooks.ThreadStarted(Index: Integer);
begin
end;

procedure TWorkerHooks.ThreadStopping(Index: Integer);
begin
end;

{ TWorkerPool }

procedure ReportError(Slot: PWorkerSlot; const Where: string; E: Exception);
begin
  WriteLn(StdErr, 'bearings.rt.workers: worker ', Slot^.Index, ': ', Where, ': ', E.ClassName, ': ',
    E.Message);
end;

{ One try/except per item, so an exception from one item does not end the
  worker. }
procedure ExecuteItem(Slot: PWorkerSlot; Item: TWorkItem);
begin
  try
    Item.Execute;
  except
    on E: Exception do
      ReportError(Slot, 'item raised', E);
  end;
end;

{ Thread function of a worker. Arg is its slot. Runs items until
  TakeOrPark returns nil (Shutdown started and the queue is empty). }
function WorkerMain(Arg: Pointer): PtrInt;
var
  Slot: PWorkerSlot;
  Pool: TWorkerPool;
  Item: TWorkItem;
begin
  Slot := PWorkerSlot(Arg);
  Pool := Slot^.Pool;
  TvIsWorker := True;
  TvWorkerIndex := Slot^.Index;
  if Pool.FHooks <> nil then
    try
      Pool.FHooks.ThreadStarted(Slot^.Index);
    except
      on E: Exception do
        ReportError(Slot, 'ThreadStarted raised', E);
    end;
  while True do
  begin
    Item := Pool.TakeOrPark(Slot);
    if Item = nil then
      Break;
    ExecuteItem(Slot, Item);
    InterLockedIncrement64(Pool.FExecuted);
  end;
  if Pool.FHooks <> nil then
    try
      Pool.FHooks.ThreadStopping(Slot^.Index);
    except
      on E: Exception do
        ReportError(Slot, 'ThreadStopping raised', E);
    end;
  { FPC threads detach themselves when they end (cthreads CEndThread), so
    for valgrind drd WaitForThreadTerminate does not order a worker's last
    memory accesses before Shutdown's return. HappensBefore on FAlive, paired
    with HappensAfter in Shutdown, declares that order (only in -dWD_DRD
    builds; a no-op otherwise). }
  HappensBefore(@Pool.FAlive);
  if InterLockedDecrement(Pool.FAlive) = 0 then
    RTLEventSetEvent(Pool.FAllExited);
  Result := 0;
end;

constructor TWorkerPool.Create(Threads: Integer; Hooks: TWorkerHooks; QueueLimit: Integer);
var
  I: Integer;
begin
  inherited Create;
  if Threads <= 0 then
  begin
    Threads := DefaultLoopCount + 4;
    if Threads > 32 then
      Threads := 32;
  end;
  FThreads := Threads;
  FHooks := Hooks;
  FQueueLimit := QueueLimit;
  FSpinNs := DEFAULT_SPIN_NS;
  InitCriticalSection(FLock);
  FAllExited := RTLEventCreate;
  SetLength(FSlots, Threads);
  SetLength(FIdle, Threads);
  FIdleCount := 0;
  FAlive := Threads;
  for I := 0 to Threads - 1 do
  begin
    FSlots[I].Pool := Self;
    FSlots[I].Index := I;
    FSlots[I].Parker.State := 0;
    FSlots[I].Joined := False;
  end;
  for I := 0 to Threads - 1 do
    FSlots[I].Thread := BeginThread(@WorkerMain, @FSlots[I]);
end;

destructor TWorkerPool.Destroy;
begin
  if not FShutDone then
    Shutdown(-1);
  if AtomicLoad(FAlive) = 0 then
  begin
    RTLEventDestroy(FAllExited);
    DoneCriticalSection(FLock);
    inherited Destroy;
  end;
  { else: threads still run and use the slots; the pool is leaked on purpose }
end;

function TWorkerPool.PopLocked(out Wake: PWorkerSlot): TWorkItem;
begin
  { Called under FLock. Removes the head item (nil if the queue is empty).
    If items remain and no worker is spinning, it also pops one parked worker
    into Wake; the caller unparks it after leaving the lock. This matters
    after a spin: Submit wakes nobody while a worker spins, so items queued
    during the spin would otherwise wait for this worker alone. }
  Wake := nil;
  Result := FHead;
  if Result = nil then
    Exit;
  FHead := Result.FNextWork;
  if FHead = nil then
    FTail := nil;
  Result.FNextWork := nil;
  AtomicStore(FCount, FCount - 1);
  if (FHead <> nil) and (FSpinners = 0) and (FIdleCount > 0) then
  begin
    Dec(FIdleCount);
    Wake := FIdle[FIdleCount];
  end;
end;

{ Returns the next item for the worker in Slot, waiting for one if needed:
  take an item if one is queued; else spin for SpinNs if no other worker is
  spinning; else push the slot on the idle stack and park until someone
  pops it and unparks it. Returns nil when Shutdown started and the queue is
  empty. }
function TWorkerPool.TakeOrPark(Slot: PWorkerSlot): TWorkItem;
var
  W: PWorkerSlot;
  T0, Spin: Int64;
  I: Integer;
  Spun: Boolean;
begin
  Spun := False;
  while True do
  begin
    EnterCriticalSection(FLock);
    Result := PopLocked(W);
    if Result <> nil then
    begin
      LeaveCriticalSection(FLock);
      if W <> nil then
        W^.Parker.Unpark;
      Exit;
    end;
    if FStopping then
    begin
      LeaveCriticalSection(FLock);
      Exit(nil);
    end;
    if (not Spun) and (FSpinNs > 0) and (FSpinners = 0) then
    begin
      { Spin, then park: one worker at a time watches FCount for SpinNs
        without the lock. While it spins Submit wakes nobody, so a steady
        stream of short items costs no futex call. CpuRelax (the x86 PAUSE
        instruction) lowers the cost of the busy loop; the clock is read
        once per 64 checks. Spun stops the same worker from spinning twice
        in a row without having parked. }
      FSpinners := 1;
      Spin := FSpinNs;
      LeaveCriticalSection(FLock);
      Spun := True;
      T0 := MonoNowNs;
      repeat
        I := 0;
        while (I < 64) and (AtomicLoad(FCount) = 0) do
        begin
          CpuRelax;
          Inc(I);
        end;
      until (AtomicLoad(FCount) > 0) or (MonoNowNs - T0 >= Spin);
      EnterCriticalSection(FLock);
      FSpinners := 0;
      Result := PopLocked(W);
      if Result <> nil then
      begin
        LeaveCriticalSection(FLock);
        if W <> nil then
          W^.Parker.Unpark;
        Exit;
      end;
      if FStopping then
      begin
        LeaveCriticalSection(FLock);
        Exit(nil);
      end;
    end;
    FIdle[FIdleCount] := Slot;
    Inc(FIdleCount);
    LeaveCriticalSection(FLock);
    { Park returns after Submit, a worker taking an item (PopLocked), or
      Shutdown popped this slot off the idle stack and unparked it. The
      parker remembers an Unpark that comes before Park, so no wakeup is
      lost between LeaveCriticalSection and Park. }
    Slot^.Parker.Park;
    Spun := False;
  end;
end;

procedure TWorkerPool.Submit(Item: TWorkItem);
begin
  if not TrySubmit(Item) then
    raise EWorkerPoolStopped.Create('TWorkerPool.Submit: the pool is shut down');
end;

function TWorkerPool.TrySubmit(Item: TWorkItem): Boolean;
var
  W: PWorkerSlot;
begin
  Item.FNextWork := nil;
  W := nil;
  EnterCriticalSection(FLock);
  if FStopping then
  begin
    LeaveCriticalSection(FLock);
    Exit(False);
  end;
  if FTail <> nil then
    FTail.FNextWork := Item
  else
    FHead := Item;
  FTail := Item;
  AtomicStore(FCount, FCount + 1);     { read without the lock by a spinner, QueueLength and Saturated }
  { a spinning worker will take it; otherwise wake one parked worker }
  if (FSpinners = 0) and (FIdleCount > 0) then
  begin
    Dec(FIdleCount);
    W := FIdle[FIdleCount];
  end;
  LeaveCriticalSection(FLock);
  if W <> nil then
    W^.Parker.Unpark;
  Result := True;
end;

procedure TWorkerPool.SetSpinNs(V: Int64);
begin
  EnterCriticalSection(FLock);
  FSpinNs := V;
  LeaveCriticalSection(FLock);
end;

function TWorkerPool.GetAlive: LongInt;
begin
  Result := AtomicLoad(FAlive);
end;

function TWorkerPool.QueueLength: Integer;
begin
  Result := AtomicLoad(FCount);         { a hint: read without the lock }
end;

function TWorkerPool.Saturated: Boolean;
begin
  Result := (FQueueLimit > 0) and (AtomicLoad(FCount) >= FQueueLimit);
end;

procedure TWorkerPool.Shutdown(WaitMs: Integer);
var
  I, N: Integer;
  Wake: array of PWorkerSlot;
begin
  EnterCriticalSection(FLock);
  FStopping := True;
  N := FIdleCount;
  SetLength(Wake, N);
  for I := 0 to N - 1 do
    Wake[I] := FIdle[I];
  FIdleCount := 0;
  LeaveCriticalSection(FLock);
  for I := 0 to N - 1 do
    Wake[I]^.Parker.Unpark;
  { the workers run the remaining items and exit; the last one sets FAllExited }
  if AtomicLoad(FAlive) > 0 then
  begin
    if WaitMs < 0 then
      RTLEventWaitFor(FAllExited)
    else
      RTLEventWaitFor(FAllExited, WaitMs);
  end;
  if AtomicLoad(FAlive) = 0 then
    HappensAfter(@FAlive);
  if AtomicLoad(FAlive) = 0 then
    for I := 0 to High(FSlots) do
      { join only when every worker exited: a thread still running keeps its handle }
      if not FSlots[I].Joined then
      begin
        WaitForThreadTerminate(FSlots[I].Thread, 0);
        CloseThread(FSlots[I].Thread);
        FSlots[I].Joined := True;
      end;
  FShutDone := True;
end;

end.
