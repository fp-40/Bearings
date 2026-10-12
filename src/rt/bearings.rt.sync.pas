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

  Memory ordering: the code was written for x86-64. There, the locked
  instructions behind InterlockedExchange / InterlockedCompareExchange /
  InterlockedIncrement are full barriers, and plain aligned loads and
  stores of a word are atomic; a store is not reordered with earlier stores,
  and a load is not reordered with earlier loads. The routines rely on
  this, and so does every other unit that shares a word between threads.
  Therefore every such access, in this unit and elsewhere, goes through the
  Atomic* wrappers below (never through Interlocked* directly), and the
  wrappers give the x86-64 guarantees on every architecture:
  - AtomicLoad*: an atomic load that is not reordered with later loads or
    stores (acquire); AtomicStore*: an atomic store that is not reordered
    with earlier loads or stores (release). On x86-64 a plain aligned load
    or store already is that. On ARM64 (aarch64) the load is followed by a
    load barrier (dmb ishld) and the store preceded by a full barrier (dmb
    ish).
  - AtomicXchg, AtomicCas, AtomicInc, AtomicDec, ... (read-modify-write):
    a full barrier on both sides. On x86-64 that is the locked instruction
    itself. On ARM64, FPC 3.2.2's Interlocked* routines are ldxr/stxr loops
    with no barrier at all (rtl/aarch64/aarch64.inc), not even acquire or
    release, so the wrappers put a full barrier (dmb ish) before and after.
  This is the conservative choice: it is correct by construction (each
  wrapper is at least as strong as the x86-64 instruction the code was
  reasoned about) and costs nothing on x86-64. A cheaper ARM64 mapping
  (acquire/release per site) needs the reasoning redone per site and a
  machine to test it on; docs/design.md section 11. The ARM64 build has
  not run on hardware yet (README.md, "ARM64").

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

procedure CpuRelax; inline;        { x86 pause / ARM64 yield: tells the CPU this is a spin-wait loop }

{ A read / write of a synchronization word that races on purpose (x86: a
  plain aligned load / store, which is atomic; ARM64: with the barrier that
  gives it the same ordering, see "Memory ordering" above). Not inlined in
  -dWD_DRD builds (see "Race detection" above). }
{$ifdef WD_DRD}
function AtomicLoad(var X: LongInt): LongInt;
procedure AtomicStore(var X: LongInt; V: LongInt);
function AtomicLoadThreadId(var X: TThreadID): TThreadID;
procedure AtomicStoreThreadId(var X: TThreadID; V: TThreadID);
function AtomicLoadPtr(var X: Pointer): Pointer;
procedure AtomicStorePtr(var X: Pointer; V: Pointer);
function AtomicXchg(var X: LongInt; V: LongInt): LongInt;
function AtomicXchgPtr(var X: Pointer; V: Pointer): Pointer;
function AtomicCas(var X: LongInt; NewValue, Comparand: LongInt): LongInt;
function AtomicCasPtr(var X: Pointer; NewValue, Comparand: Pointer): Pointer;
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
{ InterlockedExchange / CompareExchange / Increment / Decrement /
  Increment64 (the read-modify-write operations), for example for the words
  that TLoop.Post (bearings.rt.loop) updates. FPC inlines the Interlocked*
  calls into the caller, so drd would attribute their accesses to
  TLoop.Post, and suppressing them would hide every report in Post. Through
  these routines (not inlined in -dWD_DRD builds) the accesses have their
  own frame, which tools/drd.supp suppresses. Release builds on x86-64
  compile them to the same locked instructions. AtomicCas returns the value
  found: the exchange happened when it equals Comparand. }
function AtomicXchg(var X: LongInt; V: LongInt): LongInt; inline;
function AtomicXchgPtr(var X: Pointer; V: Pointer): Pointer; inline;
function AtomicCas(var X: LongInt; NewValue, Comparand: LongInt): LongInt; inline;
function AtomicCasPtr(var X: Pointer; NewValue, Comparand: Pointer): Pointer; inline;
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

{$if not defined(cpux86_64) and not defined(cpuaarch64)}
{$error bearings.rt.sync: no memory-ordering rules for this CPU (x86_64 and aarch64 only)}
{$endif}

{$ifdef cpux86_64}
{$asmmode att}
procedure CpuRelax;
begin
  asm
    pause
  end;
end;
{$endif}
{$ifdef cpuaarch64}
procedure CpuRelax;
begin
  asm
    yield
  end;
end;
{$endif}

{ The wrappers ("Memory ordering" in the unit header). x86-64: plain loads
  and stores, and the Interlocked* locked instructions, as they are. ARM64:
  the plain load is followed by a load barrier (ReadBarrier = dmb ishld:
  later loads and stores stay after it), the plain store is preceded by a
  full barrier (ReadWriteBarrier = dmb ish: earlier loads and stores stay
  before it), and each Interlocked* call (an ldxr/stxr loop without
  barriers in FPC 3.2.2) sits between two full barriers. }

{$ifdef cpuaarch64}
procedure Fence; inline;
begin
  ReadWriteBarrier;
end;
{$endif}

function AtomicLoad(var X: LongInt): LongInt;
begin
  Result := X;
  {$ifdef cpuaarch64}ReadBarrier;{$endif}
end;

procedure AtomicStore(var X: LongInt; V: LongInt);
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  X := V;
end;

function AtomicLoadThreadId(var X: TThreadID): TThreadID;
begin
  Result := X;
  {$ifdef cpuaarch64}ReadBarrier;{$endif}
end;

procedure AtomicStoreThreadId(var X: TThreadID; V: TThreadID);
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  X := V;
end;

function AtomicLoadPtr(var X: Pointer): Pointer;
begin
  Result := X;
  {$ifdef cpuaarch64}ReadBarrier;{$endif}
end;

procedure AtomicStorePtr(var X: Pointer; V: Pointer);
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  X := V;
end;

function AtomicXchg(var X: LongInt; V: LongInt): LongInt;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterlockedExchange(X, V);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicXchgPtr(var X: Pointer; V: Pointer): Pointer;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterlockedExchange(X, V);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicCas(var X: LongInt; NewValue, Comparand: LongInt): LongInt;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterlockedCompareExchange(X, NewValue, Comparand);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicCasPtr(var X: Pointer; NewValue, Comparand: Pointer): Pointer;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterlockedCompareExchange(X, NewValue, Comparand);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicInc(var X: LongInt): LongInt;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterLockedIncrement(X);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicDec(var X: LongInt): LongInt;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterLockedDecrement(X);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

function AtomicInc64(var X: Int64): Int64;
begin
  {$ifdef cpuaarch64}Fence;{$endif}
  Result := InterLockedIncrement64(X);
  {$ifdef cpuaarch64}Fence;{$endif}
end;

{$ifdef WD_DRD}
const
  { valgrind.h VG_USERREQ_TOOL_BASE('H','G') + 256 + 33 / + 34 (drd.h) }
  VG_DRD_HAPPENS_BEFORE = $48470000 + 256 + 33;
  VG_DRD_HAPPENS_AFTER = $48470000 + 256 + 34;

{ valgrind.h VALGRIND_DO_CLIENT_REQUEST_EXPR: the special instruction
  preamble (rotations of a register by 3, 13, 61, 51 = 128 bits, so the
  register is unchanged) followed by a no-op the CPU executes as such.
  valgrind recognizes the sequence and handles the request; on a real CPU
  it does nothing and returns Default.
  amd64: %rdi rotated, then xchgq %rbx,%rbx; %rax = the argument block,
  %rdx = the default result.
  arm64: x12 rotated, then orr x10,x10,x10; x4 = the argument block, x3 =
  the default result and the result. }
{$ifdef cpux86_64}
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
{$endif}
{$ifdef cpuaarch64}
function VgClientRequest(Default: PtrUInt; Args: Pointer): PtrUInt; assembler; nostackframe;
asm
  mov x3, x0
  mov x4, x1
  ror x12, x12, #3
  ror x12, x12, #13
  ror x12, x12, #51
  ror x12, x12, #61
  orr x10, x10, x10
  mov x0, x3
end;
{$endif}

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
    Old := PMpscNode(AtomicLoadPtr(Pointer(Head)));
    N^.Next := Old;
    { the node's link is written before the CAS publishes the node; the
      consumer reads it after TakeAll }
    HappensBefore(@Head);
  until AtomicCasPtr(Pointer(Head), Pointer(N), Pointer(Old)) = Pointer(Old);
  Result := Old = nil;
end;

function TMpscStack.TakeAll: PMpscNode;
var
  L, Next, Rev: PMpscNode;
begin
  if AtomicLoadPtr(Pointer(Head)) = nil then
    Exit(nil);
  L := PMpscNode(AtomicXchgPtr(Pointer(Head), nil));
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
  Result := AtomicLoadPtr(Pointer(Head)) = nil;
end;

procedure TParker.Park(TimeoutMs: Integer);
var
  Ts: TClockSpec;
  Deadline, Left: Int64;
  R: SizeInt;
begin
  { fast path: a notification is there; consume it (1 -> 0) }
  if AtomicCas(State, 0, 1) = 1 then
  begin
    HappensAfter(@State);
    Exit;
  end;
  { announce the wait (0 -> 2); this fails only when an Unpark came in
    between (State is 1): consume it and return }
  if AtomicCas(State, 2, 0) <> 0 then
  begin
    AtomicXchg(State, 0);
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
    if AtomicCas(State, 0, 1) = 1 then
    begin
      HappensAfter(@State);
      Exit;
    end;
    if R = -ESysETIMEDOUT then
    begin
      { give up the wait (2 -> 0), unless an Unpark won the race (then 1 -> 0) }
      if AtomicCas(State, 0, 2) <> 2 then
      begin
        AtomicXchg(State, 0);
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
  if AtomicXchg(State, 1) = 2 then
    SysFutex(@State, FUTEX_WAKE_PRIVATE, 1, nil);
end;

function TEventCount.Key: LongInt;
begin
  Result := AtomicLoad(Seq);
end;

procedure TEventCount.Wait(K: LongInt);
begin
  { the Waiters increment (a full barrier) comes before the kernel's read of
    Seq. A NotifyAll that read Waiters = 0 therefore incremented Seq before
    that read, so the futex wait returns at once (EAGAIN) instead of
    sleeping without a waker }
  AtomicInc(Waiters);
  if AtomicLoad(Seq) = K then
    SysFutex(@Seq, FUTEX_WAIT_PRIVATE, K, nil);
  AtomicDec(Waiters);
  HappensAfter(@Seq);
end;

procedure TEventCount.NotifyAll;
begin
  HappensBefore(@Seq);
  AtomicInc(Seq);
  if AtomicLoad(Waiters) > 0 then
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
  while AtomicXchg(State, 1) <> 0 do
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
    until AtomicLoad(State) = 0;
  end;
  HappensAfter(@State);
end;

procedure TSpinLock.Release;
begin
  HappensBefore(@State);
  { the loads and stores of the critical section complete before the store
    that frees the lock: a release store (AtomicStore) }
  {$ifdef cpux86_64}
  WriteBarrier;                 { on x86 a plain store already has this order }
  State := 0;
  {$else}
  AtomicStore(State, 0);
  {$endif}
end;

end.
