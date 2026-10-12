{ bearings.rt.sync - low-level thread synchronization: a lock-free message stack,
  futex-based wait/wake primitives, a spin lock and atomic helpers.

  The server runs one event loop thread per CPU plus a pool of worker
  threads. The loop threads must never block in a mutex, so the hand-offs
  between threads are built from these primitives:
  - TMpscStack: any thread pushes a message node, one owner thread takes
    them all at once. Used for the message inbox of each loop (bearings.rt.loop).
  - TParker: lets one thread sleep until another thread wakes it. Used by
    idle worker threads and by a worker waiting for request body data.
  - TEventCount: like TParker, but for any number of waiting threads.
  - TSpinLock: a short lock for data shared by a loop thread and a worker
    (an exchange that a worker handles, bearings.http.exchange).
  - AtomicLoad / AtomicStore / AtomicXchg / ...: named wrappers for atomic
    accesses (see "Race detection" below).

  A futex (futex(2), "fast userspace mutex") is a Linux system call that
  waits on, or wakes threads waiting on, a 32-bit word in memory.
  FUTEX_WAIT sleeps only if the word still holds an expected value, checked
  atomically by the kernel, so a wake that happens between the caller's
  check and the sleep is not lost. Both primitives below keep the common
  case in user space: they make the system call only when a thread is, or
  is about to be, asleep.

  Memory ordering: the code targets x86-64. There, the locked instructions
  behind InterlockedExchange / InterlockedCompareExchange / Interlocked-
  Increment are full barriers, and plain aligned loads and stores of a word
  are atomic; a store is not reordered with earlier stores, and a load is
  not reordered with earlier loads. The routines rely on this.

  TMpscStack (multi-producer, single-consumer): producers push with a
  compare-and-swap (CAS) on Head (a Treiber stack). Because there is only
  push and the single consumer takes the whole list with one exchange, the
  ABA problem of lock-free stacks (a node popped and pushed again between a
  reader's load and its CAS) cannot happen. TakeAll reverses the list to
  push (FIFO) order.

  TParker has three states: 0 empty, 1 notified, 2 a thread is parked.
  Unpark makes the futex wake call only when a thread is parked (state 2),
  so an Unpark of a running thread costs one atomic exchange. One waiter
  only: if two threads call Park on the same parker, one can miss its wake.

  TEventCount supports any number of waiters (for example several producers
  of one TChannelBody waiting for room). A waiter reads Key, checks its
  condition, and calls Wait(Key) if it must wait; Wait returns once Seq
  differs from Key, or spuriously, so callers loop. NotifyAll increments Seq
  and makes the futex wake call only when a thread is waiting. When the
  condition is protected by a lock, the waiter reads Key under the lock and
  the notifier changes the condition under the lock and calls NotifyAll
  after it; then every notification comes after the Key read it must wake,
  and no wake is lost.

  Race detection: the worker stress tests also run under valgrind's drd
  race detector. drd understands pthread mutexes and condition variables,
  but not futexes, spin locks or atomic instructions. Builds with -dWD_DRD
  therefore tell drd the happens-before edges of these primitives through
  valgrind client requests (drd.h ANNOTATE_HAPPENS_BEFORE / AFTER); other
  builds compile the annotations to nothing. drd also reports the accesses
  to the synchronization words themselves (it does not treat locked
  instructions or futex calls as synchronization), so in -dWD_DRD builds
  every access to such a word goes through a routine that is not inlined
  (the TSpinLock, TParker and TMpscStack methods, AtomicLoad / AtomicStore
  and the other wrappers, the RTL's Interlocked* functions) and
  tools/drd.supp suppresses reports whose top frame is one of them.
  AtomicLoad / AtomicStore mark the plain word-sized reads and writes of
  such words that race on purpose (for example a load whose value is
  checked again under a CAS or a lock). }
unit bearings.rt.sync;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  bearings.rt.sys;

type
  PMpscNode = ^TMpscNode;
  { Intrusive: the node is embedded in the message (the first field of
    TLoopMsg, bearings.rt.loop), so a push allocates nothing. }
  TMpscNode = record Next: PMpscNode; end;

  TMpscStack = record              { lock-free; producers CAS on Head }
    Head: PMpscNode;
    { Any thread. True if the stack was empty before the push. TLoop.Post
      wakes the loop only then: the push that made the stack non-empty
      already woke it, and its TakeAll will take the later nodes too. }
    function Push(N: PMpscNode): Boolean;
    { Owner thread only. Takes every pushed node, in push (FIFO) order; nil
      when empty. }
    function TakeAll: PMpscNode;
    { Owner thread; from another thread the result is only a hint. }
    function IsEmpty: Boolean; {$ifndef WD_DRD}inline;{$endif}
  end;

  TParker = record                 { one waiter; futex wait/wake on State }
    State: LongInt;                { 0 empty, 1 notified, 2 a thread is parked }
    { Sleeps until Unpark (or TimeoutMs elapsed; -1 = no timeout). Returns at
      once if an Unpark came first. Consumes the notification: State := 0. }
    procedure Park(TimeoutMs: Integer = -1);
    procedure Unpark;                          { any thread; State := 1, futex wake only if a thread is parked }
  end;

  TEventCount = record             { any number of waiters; futex wait/wake on Seq }
    Seq: LongInt;                  { incremented by every NotifyAll }
    Waiters: LongInt;              { threads inside Wait }
    function Key: LongInt; {$ifndef WD_DRD}inline;{$endif}   { read under the condition's lock, before Wait }
    procedure Wait(K: LongInt);    { until Seq <> K (or spuriously) }
    procedure NotifyAll;           { Seq += 1; futex_wake(all) only if a thread waits }
  end;

  { A lock that busy-waits instead of sleeping. Suited only to very short
    critical sections: bearings.http.exchange takes it when a worker thread and
    the loop thread both use one exchange. }
  TSpinLock = record
    State: LongInt;                { 0 free, 1 held }
    procedure Acquire; {$ifndef WD_DRD}inline;{$endif}   { atomic exchange; while held, spins with pause and calls sched_yield every 1000 spins }
    procedure Release; {$ifndef WD_DRD}inline;{$endif}
  end;

procedure CpuRelax; inline;        { x86 pause: tells the CPU this is a spin-wait loop }

{ A read / write of a synchronization word that races on purpose (x86: a
  plain aligned load / store, which is atomic). Not inlined in -dWD_DRD
  builds (see "Race detection" above). }
{$ifdef WD_DRD}
function AtomicLoad(var X: LongInt): LongInt;
procedure AtomicStore(var X: LongInt; V: LongInt);
function AtomicLoadThreadId(var X: TThreadID): TThreadID;
procedure AtomicStoreThreadId(var X: TThreadID; V: TThreadID);
function AtomicLoadPtr(var X: Pointer): Pointer;
procedure AtomicStorePtr(var X: Pointer; V: Pointer);
function AtomicXchg(var X: LongInt; V: LongInt): LongInt;
function AtomicInc(var X: LongInt): LongInt;
function AtomicDec(var X: LongInt): LongInt;
function AtomicInc64(var X: Int64): Int64;
{$else}
function AtomicLoad(var X: LongInt): LongInt; inline;
procedure AtomicStore(var X: LongInt; V: LongInt); inline;
{ For TLoop.ThreadId: written when a thread takes the loop thread's place
  (TLoop.Run, ProcessInbox, TServer's shutdown), read by any thread
  (TExchange.OnOwnLoop) }
function AtomicLoadThreadId(var X: TThreadID): TThreadID; inline;
procedure AtomicStoreThreadId(var X: TThreadID; V: TThreadID); inline;
{ For a pointer published by one thread and read by others
  (TExchange.FChannel, created by whichever thread begins the first stream) }
function AtomicLoadPtr(var X: Pointer): Pointer; inline;
procedure AtomicStorePtr(var X: Pointer; V: Pointer); inline;
{ InterlockedExchange / Increment / Decrement / Increment64, for the words
  that TLoop.Post (bearings.rt.loop) updates. FPC inlines the Interlocked* calls
  into the caller, so drd would attribute their accesses to TLoop.Post, and
  suppressing them would hide every report in Post. Through these routines
  (not inlined in -dWD_DRD builds) the accesses have their own frame, which
  tools/drd.supp suppresses. Release builds compile them to the same locked
  instructions. }
function AtomicXchg(var X: LongInt; V: LongInt): LongInt; inline;
function AtomicInc(var X: LongInt): LongInt; inline;
function AtomicDec(var X: LongInt): LongInt; inline;
function AtomicInc64(var X: Int64): Int64; inline;
{$endif}

{ drd.h ANNOTATE_HAPPENS_BEFORE / ANNOTATE_HAPPENS_AFTER on the address P
  (-dWD_DRD builds; empty otherwise). They tell drd that everything a thread
  did before HappensBefore(P) is visible to another thread after a later
  HappensAfter(P). }
{$ifdef WD_DRD}
procedure HappensBefore(P: Pointer);
procedure HappensAfter(P: Pointer);
{$else}
procedure HappensBefore(P: Pointer); inline;
procedure HappensAfter(P: Pointer); inline;
{$endif}

implementation

uses
  bearings.rt.clock;

{$asmmode att}

procedure CpuRelax;
begin
  asm
    pause
  end;
end;

function AtomicLoad(var X: LongInt): LongInt;
begin
  Result := X;
end;

procedure AtomicStore(var X: LongInt; V: LongInt);
begin
  X := V;
end;

function AtomicLoadThreadId(var X: TThreadID): TThreadID;
begin
  Result := X;
end;

procedure AtomicStoreThreadId(var X: TThreadID; V: TThreadID);
begin
  X := V;
end;

function AtomicLoadPtr(var X: Pointer): Pointer;
begin
  Result := X;
end;

procedure AtomicStorePtr(var X: Pointer; V: Pointer);
begin
  X := V;
end;

function AtomicXchg(var X: LongInt; V: LongInt): LongInt;
begin
  Result := InterlockedExchange(X, V);
end;

function AtomicInc(var X: LongInt): LongInt;
begin
  Result := InterLockedIncrement(X);
end;

function AtomicDec(var X: LongInt): LongInt;
begin
  Result := InterLockedDecrement(X);
end;

function AtomicInc64(var X: Int64): Int64;
begin
  Result := InterLockedIncrement64(X);
end;

{$ifdef WD_DRD}
const
  { valgrind.h VG_USERREQ_TOOL_BASE('H','G') + 256 + 33 / + 34 (drd.h) }
  VG_DRD_HAPPENS_BEFORE = $48470000 + 256 + 33;
  VG_DRD_HAPPENS_AFTER = $48470000 + 256 + 34;

{ valgrind.h VALGRIND_DO_CLIENT_REQUEST_EXPR for amd64: the special
  instruction preamble (rotations of %rdi by 3, 13, 61, 51 = 128 bits, so
  %rdi is unchanged) followed by xchgq %rbx,%rbx; %rax = the argument block,
  %rdx = the default result. valgrind recognizes the sequence and handles
  the request; on a real CPU it does nothing and returns Default. }
function VgClientRequest(Default: PtrUInt; Args: Pointer): PtrUInt; assembler; nostackframe;
asm
  movq %rsi, %rax
  movq %rdi, %rdx
  rolq $3, %rdi
  rolq $13, %rdi
  rolq $61, %rdi
  rolq $51, %rdi
  xchgq %rbx, %rbx
  movq %rdx, %rax
end;

procedure VgRequest1(Req: PtrUInt; A1: Pointer);
var
  Args: array[0..5] of PtrUInt;
begin
  Args[0] := Req;
  Args[1] := PtrUInt(A1);
  Args[2] := 0;
  Args[3] := 0;
  Args[4] := 0;
  Args[5] := 0;
  VgClientRequest(0, @Args[0]);
end;

procedure HappensBefore(P: Pointer);
begin
  VgRequest1(VG_DRD_HAPPENS_BEFORE, P);
end;

procedure HappensAfter(P: Pointer);
begin
  VgRequest1(VG_DRD_HAPPENS_AFTER, P);
end;
{$else}
procedure HappensBefore(P: Pointer);
begin
end;

procedure HappensAfter(P: Pointer);
begin
end;
{$endif}

function TMpscStack.Push(N: PMpscNode): Boolean;
var
  Old: PMpscNode;
begin
  repeat
    Old := Head;
    N^.Next := Old;
    { the node's link is written before the CAS publishes the node; the
      consumer reads it after TakeAll }
    HappensBefore(@Head);
  until InterlockedCompareExchange(Pointer(Head), Pointer(N), Pointer(Old)) = Pointer(Old);
  Result := Old = nil;
end;

function TMpscStack.TakeAll: PMpscNode;
var
  L, Next, Rev: PMpscNode;
begin
  if Head = nil then
    Exit(nil);
  L := PMpscNode(InterlockedExchange(Pointer(Head), nil));
  HappensAfter(@Head);
  { the stack is in LIFO order; reverse it to push order }
  Rev := nil;
  while L <> nil do
  begin
    Next := L^.Next;
    L^.Next := Rev;
    Rev := L;
    L := Next;
  end;
  Result := Rev;
end;

function TMpscStack.IsEmpty: Boolean;
begin
  Result := Head = nil;
end;

procedure TParker.Park(TimeoutMs: Integer);
var
  Ts: TClockSpec;
  Deadline, Left: Int64;
  R: SizeInt;
begin
  { fast path: a notification is there; consume it (1 -> 0) }
  if InterlockedCompareExchange(State, 0, 1) = 1 then
  begin
    HappensAfter(@State);
    Exit;
  end;
  { announce the wait (0 -> 2); this fails only when an Unpark came in
    between (State is 1): consume it and return }
  if InterlockedCompareExchange(State, 2, 0) <> 0 then
  begin
    InterlockedExchange(State, 0);
    HappensAfter(@State);
    Exit;
  end;
  if TimeoutMs >= 0 then
    Deadline := MonoNowNs + Int64(TimeoutMs) * 1000000
  else
    Deadline := 0;
  while True do
  begin
    if TimeoutMs >= 0 then
    begin
      Left := Deadline - MonoNowNs;
      if Left <= 0 then
        R := -ESysETIMEDOUT
      else
      begin
        Ts.Sec := Left div 1000000000;
        Ts.NSec := Left mod 1000000000;
        R := SysFutex(@State, FUTEX_WAIT_PRIVATE, 2, @Ts);
      end;
    end
    else
      R := SysFutex(@State, FUTEX_WAIT_PRIVATE, 2, nil);
    { R = 0: woken; -EAGAIN: State was no longer 2 when the kernel checked;
      -EINTR: interrupted by a signal. In every case check for a
      notification; without one, sleep again (a spurious wake) }
    if InterlockedCompareExchange(State, 0, 1) = 1 then
    begin
      HappensAfter(@State);
      Exit;
    end;
    if R = -ESysETIMEDOUT then
    begin
      { give up the wait (2 -> 0), unless an Unpark won the race (then 1 -> 0) }
      if InterlockedCompareExchange(State, 0, 2) <> 2 then
      begin
        InterlockedExchange(State, 0);
        HappensAfter(@State);
      end;
      Exit;
    end;
  end;
end;

{ The exchange returns the old state: only 2 means a thread is (or is about
  to be) inside FUTEX_WAIT on State. If it has not called futex yet, the
  kernel sees State = 1 <> 2 and the wait returns at once. }
procedure TParker.Unpark;
begin
  HappensBefore(@State);
  if InterlockedExchange(State, 1) = 2 then
    SysFutex(@State, FUTEX_WAKE_PRIVATE, 1, nil);
end;

function TEventCount.Key: LongInt;
begin
  Result := Seq;
end;

procedure TEventCount.Wait(K: LongInt);
begin
  { the Waiters increment (a full barrier) comes before the kernel's read of
    Seq. A NotifyAll that read Waiters = 0 therefore incremented Seq before
    that read, so the futex wait returns at once (EAGAIN) instead of
    sleeping without a waker }
  InterlockedIncrement(Waiters);
  if Seq = K then
    SysFutex(@Seq, FUTEX_WAIT_PRIVATE, K, nil);
  InterlockedDecrement(Waiters);
  HappensAfter(@Seq);
end;

procedure TEventCount.NotifyAll;
begin
  HappensBefore(@Seq);
  InterlockedIncrement(Seq);
  if Waiters > 0 then
    SysFutex(@Seq, FUTEX_WAKE_PRIVATE, High(LongInt), nil);
end;

{ Spins on a plain read until the lock looks free, then retries the
  exchange: spinning on the exchange itself would keep taking the cache
  line away from the holder. sched_yield lets the holder run if it was
  preempted on the same CPU. }
procedure TSpinLock.Acquire;
var
  Spins: Integer;
begin
  Spins := 0;
  while InterlockedExchange(State, 1) <> 0 do
  begin
    repeat
      Inc(Spins);
      if Spins >= 1000 then
      begin
        SysSchedYield;
        Spins := 0;
      end
      else
        CpuRelax;
    until State = 0;
  end;
  HappensAfter(@State);
end;

procedure TSpinLock.Release;
begin
  HappensBefore(@State);
  { the stores of the critical section become visible before the store
    that frees the lock (on x86 a plain store already has this order) }
  WriteBarrier;
  State := 0;
end;

end.
