# M3 design, candidate "faithful": a line-by-line port of hyper's HTTP/1 connection on a tokio-like Pascal runtime

> Written while this code was part of wd-40 (where "wd-40" in the text means the project of that time). The unit names were changed to `bearings.*` when the transport moved to this repository; commit hashes refer to the wd-40 history.

Status: design candidate, not implemented. Date: 2026-10-07.

Reference code (read for this design):

- hyper v1.12.0, rev `7f67699`: `src/proto/h1/{conn,dispatch,io,role,decode,encode,mod}.rs`,
  `src/server/conn/http1.rs`, `src/upgrade.rs`, `src/body/{incoming,chan}.rs`,
  `src/common/{time,date}.rs`, `src/error.rs`, `tests/h1_*.rs`.
- bytes 1.12.1 `src/bytes_mut.rs` (`reserve_inner`, lines 626-790), tokio 1.53.2 and mio 1.2.4
  (the versions in `conformance/Cargo.lock`).
- `conformance/SPEC.md`, `conformance/reference-server/src/main.rs`, `conformance/cases/h1/*.json`.
- `src/http1/*.pas` interfaces (parser, decode, encode, role, headers, uri, date, reason).
- `docs/research/hyper-features.md`, `docs/research/library-survey.md` (BUILD section).
- hyper's TechEmpower entry: `vendor/FrameworkBenchmarks/frameworks/Rust/hyper/src/main.rs`.

Short names used below: `conn.rs:NNN` = hyper `src/proto/h1/conn.rs` line NNN, and so on.

---

## 0. Summary, assumptions, open questions

### 0.1 What this candidate is

The HTTP/1 connection is a port of hyper's three layers, one Pascal unit per Rust file, with the same
names, the same fields and the same order of operations:

| hyper | Pascal | role |
|---|---|---|
| `io.rs` `Buffered`, `ReadStrategy`, `WriteBuf`, `Cursor` | `bearings.http1.io`: `TBuffered`, `TReadStrategy`, `TWriteBuf`, `TCursorVec` | socket buffers, adaptive read size, Flatten/Queue write strategies |
| `conn.rs` `Conn`, `State`, `Reading`, `Writing`, `KA` | `bearings.http1.conn`: `TConn`, `TConnState`, `TReading`, `TWriting`, `TKA` | per-message state machine, keep-alive, 100-continue, error responses |
| `dispatch.rs` `Dispatcher`, `Server` | `bearings.http1.dispatch`: `TDispatcher`, `TServerDispatch` | read/write/flush loop (16 iterations), service and body polling |
| `server/conn/http1.rs` `Builder`, `Connection`, `UpgradeableConnection`, `Parts` | `bearings.http1.server`: `TH1Builder`, `TH1Connection`, `TH1Parts` | configuration, plain / with_upgrades / without_shutdown |
| `body/chan.rs`, `body/incoming.rs` | `bearings.http.body`: `TBodyChan`, `TBodySender`, `TBodyReceiver`, `TIncoming` | request body channel with `want` |
| `upgrade.rs` | `bearings.http.upgrade`: `TOnUpgrade`, `TUpgraded` | upgrade hand-off with leftover bytes |
| `error.rs` | `bearings.http.error`: `THyperError` | error kinds and the predicates the SPEC outcome classes use |

Rust futures become **poll methods**: every `fn poll_x(&mut self, cx: &mut Context) -> Poll<...>` becomes
a Pascal method `function PollX(var Cx: TContext; ...): TPollResult` that returns `prPending` exactly where
hyper returns `Poll::Pending`, after registering a wake-up exactly where hyper's callee registers its waker.
There are no closures and no coroutines: the state that an `async fn` would keep across `.await` points is
kept in explicit fields, as hyper's own hand-written futures already do.

Under it is a small runtime that copies the behavior of tokio's **current-thread** scheduler, because
hyper's TechEmpower entry runs one current-thread runtime per core with `SO_REUSEPORT`, and the
reference server runs one current-thread runtime. The runtime has one `TEventLoop` per core:
edge-triggered epoll with tokio's readiness bookkeeping, a FIFO run queue with tokio's event interval, a
1 ms hierarchical timer wheel with tokio's rounding, an eventfd for cross-thread wake-ups, and a per-loop
date cache.

Application code runs either **on the loop** (a `THttpService` whose calls never block: the conformance
server, benchmark handlers, proxies) or **on a worker pool** (`TBlockingService`: synchronous
Proper-style controllers that may block on a database). Both kinds sit behind the same poll interface,
so the dispatcher does not know which one it is driving.

### 0.2 Assumptions (stated so they can be checked)

1. "Faithful" means: for every input byte sequence and timing, the bytes written, the moment the socket is
   shut down or closed, and the outcome class are the ones hyper 1.12.0 produces with the same builder
   options, up to scheduling jitter of the same order as tokio's. It does not mean the same number of
   `read(2)` calls (the SPEC removes `bytes_read` events in diff mode for that reason), but the design
   still copies tokio's readiness rules so the syscall pattern is close.
2. Only the server role is ported. hyper's client branches (`T::is_client()`, `require_empty_read`,
   `Client` dispatch, `h09_responses`, `on_informational`, `set_read_buf_exact_size`) are dropped.
   `T::should_read_first()` is the constant `True`, `T::should_error_on_parse_eof()` is `False`.
3. The perf comparison runs hyper's TechEmpower code with its hyper dependency moved from 1.6 to 1.12.0
   (its `Cargo.toml` says `version = "1.6.0"`; the target says hyper 1.12). Our benchmark server uses the
   same builder options as that entry: `pipeline_flush(true)` (hence the Flatten write strategy), no timer,
   `TCP_NODELAY` on, backlog 4096, `SO_REUSEPORT` + `SO_REUSEADDR`, one loop per CPU as counted by
   `num_cpus::get()` (affinity and cgroup quota).
4. "Known open issue: trailer encoding deviates from role.rs in 3 ways": I did not find the M2 list in the
   repository or the scratchpad. Section 5.2 lists the three deviations I found by comparing
   `encode.rs:167-222` and `role.rs:868-998` with `bearings.http1.encode.pas` / `bearings.http1.role.pas`. If the M2
   notes name different ones, section 5.2's method (fix at the unit, add a differential test) still applies.
5. FPC 3.2.2, `{$mode objfpc}{$H+}{$modeswitch advancedrecords}`, Linux x86_64 only, as in M2.

### 0.3 Open questions for the user

1. Perf acceptance beyond throughput: I propose p99 latency ≤ 1.25 × hyper's and peak RSS ≤ 1.25 × hyper's
   in each of the 4 wrk configurations. Accept, or give other numbers?
2. Is there a second machine for the load generator? If not, section 7.6 splits the 16 cores between server
   and wrk the same way for both servers. hyper and ours then run with 12 threads, not 16.
3. Production default for the header read timer. hyper has no timeouts unless a timer is set; the TFB entry
   sets none. I propose `THttpServer` defaults to `Timer = True` with hyper's 30 s `header_read_timeout`
   (it also bounds keep-alive idle time), and the benchmark config turns it off to match hyper's entry.
4. Should idle connections give their 8 KiB read and write blocks back to the loop's pool (section 4.6)?
   hyper keeps them. Returning them lowers RSS with many idle keep-alive clients and changes no wire bytes.
   I propose yes, on by default.

---

## 1. Threading and reactor

### 1.1 Shape

```
THttpServer
  └─ TRuntime ── N × TEventLoop (one OS thread each; loop 0 runs on the calling thread, as the TFB entry)
                   ├─ epoll fd (edge-triggered), eventfd, TTimerWheel, TDateCache, TBlockPool
                   ├─ TTcpListener (own SO_REUSEPORT socket) + TAcceptTask
                   ├─ run queue (FIFO) + deferred queue (yield_now) + task table (slot, generation)
                   └─ connection tasks: TH1ConnTask = one object holding TH1Connection by value
  └─ TWorkerPool (optional, M threads) for TBlockingService
```

Shared-nothing between loops: a connection lives and dies on the loop that accepted it. Nothing on the
hot path takes a lock or touches another core's cache lines. Cross-thread traffic exists only for the
worker pool (section 3.5) and for runtime-wide commands (shutdown).

### 1.2 Loops per core and CPU count

`GetCPUCount` returns 1 on Linux (library-survey §2), so the count comes from the kernel, the same way
Rust's `available_parallelism` and `num_cpus::get()` compute it:

```pascal
unit bearings.rt.sys;
{ sched_getaffinity(0, SizeOf(Mask), @Mask) via do_syscall(204); popcount of the mask. }
function AffinityCpuCount: Integer;
{ cgroup v2 /sys/fs/cgroup/cpu.max "quota period" (or v1 cpu.cfs_quota_us / cpu.cfs_period_us):
  Ceil(quota / period), or 0 when there is no quota ("max", -1, or no cgroup files). }
function CgroupCpuQuota: Integer;
{ Min(AffinityCpuCount, CgroupCpuQuota when > 0), at least 1. Falls back to parsing
  /sys/devices/system/cpu/online when the syscall fails. }
function DetectCpuCount: Integer;
function AffinityCpuList(out Cpus: array of Integer): Integer;   { ids for optional pinning }
```

`TRuntimeConfig.Loops = 0` means `DetectCpuCount`. Pinning (`sched_setaffinity`, syscall 203) is off by
default because hyper's TFB entry does not pin (library-survey §2 correction). `PinLoops = True` pins loop
*i* to the *i*-th CPU of the affinity list; it is offered for measurements, not used for the parity runs.

### 1.3 Accept: one SO_REUSEPORT listener per loop

Each loop creates its own listening socket with `SO_REUSEADDR`, `SO_REUSEPORT`, `TCP_NODELAY`,
non-blocking, backlog 4096 (exactly `create_socket` in the TFB `main.rs`). The kernel spreads incoming
connections over the listeners by 4-tuple hash.

Not chosen: one shared listener with `EPOLLEXCLUSIVE`. It is what some C servers use, but it is not what
hyper's entry does; using it would make the comparison measure two different accept strategies.
`SO_ATTACH_REUSEPORT_CBPF` (CPU-steered accept, used by libreactor) is a later option behind a flag, off for
parity runs.

`TAcceptTask` (one per loop) is a task like any other: on readiness it calls `accept4(fd, nil, nil,
SOCK_NONBLOCK or SOCK_CLOEXEC)` until `EAGAIN`, at most 128 accepts per poll (tokio's cooperative budget
is 128; after that tokio returns `Pending` and re-schedules). For each socket it builds a connection task
with `TH1Builder.ServeConnection` and calls `Loop.Spawn`. `EMFILE`/`ENFILE`: log once per second, keep
the listener registered, retry on the next readiness (tokio's accept returns the error, the TFB loop
propagates it with `?` and the runtime stops; we do not copy that, see deviation DV-15).

The conformance server uses one loop and a listener configured like `tokio::net::TcpListener::bind`
(mio 1.2.4 `TcpListener::bind`: `SO_REUSEADDR`, backlog 128 like Rust std, **no** `TCP_NODELAY`), because write coalescing on loopback
depends on Nagle and diff mode compares read boundaries.

### 1.4 Epoll mode and readiness: copy of mio/tokio

mio registers every socket once with `EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET`. tokio keeps readiness
bits per socket (`ScheduledIo`) and:

- `poll_read`: if the readable bit is clear, return `Pending` without a syscall (waker registered);
  otherwise `read(2)`. On `EAGAIN` clear the bit and return `Pending`. **On a short read
  (`0 < n < len`) also clear the bit** (tokio `PollEvented::poll_read`, Linux), so the next poll returns
  `Pending` without a syscall until epoll reports new data (tokio 1.53.2 `io/poll_evented.rs`:
  `if 0 < n && n < len { clear_readiness }`).
- `poll_write`: the same with the writable bit, including clearing it on a short write.
  `poll_write_vectored` clears the bit only on `EAGAIN`, not on a short write
  (tokio 1.53.2 `io/poll_evented.rs`: `poll_write` vs `poll_write_vectored` → `poll_write_io`).
  The port keeps that asymmetry.
- An epoll event sets bits and wakes the reader and/or writer waker.

The design copies this exactly:

```pascal
unit bearings.rt.net;

type
  TReadyBit = (rbReadable, rbWritable, rbReadClosed, rbWriteClosed, rbError);
  TReadiness = set of TReadyBit;

  PIoRegistration = ^TIoRegistration;
  TIoRegistration = record
    Fd: cint;
    Ready: TReadiness;
    ReadWaker, WriteWaker: TWaker;   { tokio: reader / writer waker slots }
  end;
  { epoll_event.data.ptr points at the TIoRegistration. }

  TIoPoll = (ioReady, ioPending, ioError);

  { hyper rt::Read + rt::Write. Virtual, see DV-2. }
  TIoStream = class
  public
    function PollRead(var Cx: TContext; Buf: PByte; Len: SizeInt;
      out N: SizeInt; out Errno: cint): TIoPoll; virtual; abstract;
    function PollWrite(var Cx: TContext; Buf: PByte; Len: SizeInt;
      out N: SizeInt; out Errno: cint): TIoPoll; virtual; abstract;
    function PollWriteVectored(var Cx: TContext; Iov: PIoSlice; Count: Integer;
      out N: SizeInt; out Errno: cint): TIoPoll; virtual;     { default: first non-empty slice only,
                                                                 as Rust's default poll_write_vectored }
    function IsWriteVectored: Boolean; virtual;                { default False }
    function PollFlush(var Cx: TContext; out Errno: cint): TIoPoll; virtual;  { TCP: ioReady }
    function PollShutdown(var Cx: TContext; out Errno: cint): TIoPoll; virtual; abstract; { SHUT_WR }
    { Extension (DV-14): sendfile. Default: not supported (False). }
    function CanSendFile: Boolean; virtual;
    function PollSendFile(var Cx: TContext; InFd: cint; var Offset: Int64; Count: SizeInt;
      out N: SizeInt; out Errno: cint): TIoPoll; virtual;
    procedure Close; virtual; abstract;                        { drop: close(2), no shutdown }
  end;

  TTcpStream = class(TIoStream)          { tokio TcpStream behind hyper-util TokioIo }
  public
    Reg: TIoRegistration;
    Loop: TEventLoop;
    function PollRead(...): TIoPoll; override;          { read(2); bookkeeping as above }
    function PollWriteVectored(...): TIoPoll; override; { writev(2), at most 64 iovecs (io.rs:288) }
    function IsWriteVectored: Boolean; override;        { True, as tokio's TcpStream }
    function PollShutdown(...): TIoPoll; override;      { shutdown(fd, SHUT_WR) }
    { Re-target wake-ups after an upgrade hand-off. }
    procedure SetOwner(const ReadW, WriteW: TWaker);
  end;
```

Level-triggered epoll was considered and rejected: it would return the same fd on every `epoll_wait` while
a connection waits for its service (data pending in the socket) and adds `epoll_ctl` calls to toggle
interest. Edge-triggered with readiness bits is what tokio does and needs one `epoll_ctl` per connection
lifetime.

`SIGPIPE` is ignored process-wide at runtime start (`fpSignal(SIGPIPE, SIG_IGN)`), as the Rust standard
runtime does; writes to a reset socket then return `EPIPE`, which becomes an io error.

### 1.5 Tasks, context, wakers

```pascal
unit bearings.rt.task;

type
  TPoll = (plReady, plPending);
  { Poll<Result<(), E>>: the most common shape in conn.rs / dispatch.rs. }
  TPollResult = (prOk, prErr, prPending);

  TWakerKind = (wkNone, wkTask, wkThread);
  PThreadParker = ^TThreadParker;
  TThreadParker = record          { futex word: 0 = parked/empty, 1 = notified }
    State: LongInt;
    procedure Park;               { futex_wait while State = 0, then State := 0 }
    procedure Unpark;             { State := 1; futex_wake(1) }
  end;

  { std::task::Waker. Copyable, no reference counting. }
  TWaker = record
    Kind: TWakerKind;
    Loop: TEventLoop;             { wkTask }
    Slot, Gen: Cardinal;          { wkTask: task handle; stale handles are ignored }
    Parker: PThreadParker;        { wkThread }
    procedure Wake;               { any thread }
    function WillWake(const Other: TWaker): Boolean; inline;
  end;

  { std::task::Context }
  PContext = ^TContext;
  TContext = record
    Waker: TWaker;
    Loop: TEventLoop;             { nil when polled from a worker thread }
    procedure YieldNow;           { tokio task::yield_now: re-run after the next IO poll }
  end;

  TTask = class
  private
    FSlot, FGen: Cardinal;
    FNext: TTask;                 { intrusive run-queue link }
    FScheduled: LongInt;          { atomic 0/1; set by Wake, cleared before Poll }
  public
    Loop: TEventLoop;
    { Poll once. Return True when the task is finished; the loop then frees it. }
    function Poll(var Cx: TContext): Boolean; virtual; abstract;
    { Called instead of the destructor path when Poll raised (DV-10). }
    procedure Abort(E: Exception); virtual;
    function Waker: TWaker;
  end;
```

`TWaker.Wake` with `wkTask`: if the caller runs on `Loop`'s thread (compare `Loop.ThreadId` with
`GetCurrentThreadId`), push the task on the run queue if `FScheduled` was 0. Otherwise append
`(Slot, Gen)` to the loop's inbox (section 1.7). The loop checks `Gen` against its task table before
polling, so a wake for a finished task is dropped. No reference counts on tasks.

`Cx.YieldNow` is hyper's `task::yield_now(cx)` (dispatch.rs:222): the task is put on the **deferred**
queue, which the loop moves to the run queue only after its next epoll poll. That is what tokio does with
`wake_by_ref` during a poll (it defers the wake until after the driver is polled).

### 1.6 Timers and clock

hyper's timers go through `TokioTimer`, i.e. tokio's time driver: a hierarchical wheel with 1 ms
resolution, 6 levels of 64 slots, deadlines rounded **up** to the next millisecond. The port:

```pascal
unit bearings.rt.timer;

type
  TTimerState = (tsIdle, tsArmed, tsFired);
  PTimerEntry = ^TTimerEntry;
  TTimerEntry = record            { embedded in the object that owns the sleep (no allocation) }
    Prev, Next: PTimerEntry;
    DeadlineTick: Int64;          { ms since loop start, rounded up }
    Waker: TWaker;
    State: TTimerState;
    Level, Slot: Byte;
  end;

  TTimerWheel = record            { tokio runtime/time/wheel: 6 levels x 64 slots, 1 ms }
    procedure Init(StartNs: Int64);
    function DeadlineToTick(DeadlineNs: Int64): Int64;   { (Deadline - Start + 999_999) div 1_000_000 }
    { insert, or reset if armed (tokio Sleep::reset). Clears tsFired. }
    procedure Arm(E: PTimerEntry; DeadlineNs: Int64; const W: TWaker);
    procedure Cancel(E: PTimerEntry);
    { ms until the earliest deadline, -1 if none (tokio next_expiration via occupancy bitmaps). }
    function NextTimeoutMs(NowNs: Int64): Integer;
    { process ticks up to Now: State := tsFired, Waker.Wake, cascade higher levels. }
    procedure Advance(NowNs: Int64);
  end;

  { tokio::time::Sleep as a pollable: ready once the entry fired. }
  TSleep = record
    Entry: TTimerEntry;
    procedure Reset(var Cx: TContext; DeadlineNs: Int64);
    function Poll(var Cx: TContext): TPoll;    { re-registers Cx.Waker if still armed }
    procedure Cancel(var Cx: TContext);
  end;
```

A wheel, not a binary heap: `header_read_timeout` is re-armed on every request of every keep-alive
connection (conn.rs:223-245), and cancelled when the head arrives; the wheel does both in O(1) with no
allocation, and rounding the same way tokio does keeps "fires after N ms" equal to hyper's.

Clocks (library-survey §7: FPC's `clock_gettime` is a raw syscall at ~89 ns, libc's vDSO path ~11 ns):

```pascal
unit bearings.rt.clock;
function clock_gettime(clk: cint; tp: ptimespec): cint; cdecl; external 'c';
function MonoNowNs: Int64; inline;     { CLOCK_MONOTONIC via libc (vDSO) }
function RealNowUs: Int64; inline;     { CLOCK_REALTIME via libc (vDSO), for the Date header }
```

The loop reads `MonoNowNs` once per turn (after `epoll_wait`) for `Timers.Advance`. Arming a timer
reads the clock afresh (hyper uses `timer.now()` = `Instant::now()` at arming, conn.rs:224). One vDSO
call per request is 11 ns.

Date header: hyper calls `date::update()` at the start of every dispatcher poll (`T::update_date()`,
dispatch.rs:148), which compares `SystemTime::now()` with the next whole second. The port keeps that
call site: `TDispatcher.PollInner` calls `Loop.Date.Check(RealNowUs)` (`TDateCache` from
`bearings.http.date`, one per loop, not thread-local: threadvars cost 2.7 ns per access on x86_64-linux,
library-survey §2). `ServerEncode` gets `P.Date := Loop.Date.Buffer`.

### 1.7 Wake-ups across threads

```pascal
unit bearings.rt.loop;

type
  TLoopMsgKind = (lmWake, lmRun, lmGraceful, lmStop);
  TLoopMsg = record
    Kind: TLoopMsgKind;
    Slot, Gen: Cardinal;          { lmWake }
    Job: TObject;                 { lmRun: a TLoopJob to execute on the loop }
  end;

  TInbox = record                 { mutex + two arrays swapped by the loop each turn }
    Lock: TRTLCriticalSection;
    Items: array of TLoopMsg;
    Count: Integer;
    procedure Push(const M: TLoopMsg; out WasEmpty: Boolean);
    function Swap(var Spare: array of TLoopMsg): Integer;
  end;
```

A remote `Wake` pushes `lmWake` and, if the loop's `Sleeping` flag (atomic, set just before a blocking
`epoll_wait`) is 1 and the inbox was empty, writes 1 to the loop's eventfd. The loop clears `Sleeping`
after `epoll_wait` returns and drains the eventfd only when its fd was reported. Only the worker-pool
path produces remote wakes, at the rate of a few per request, so a mutex is enough; a lock-free MPSC
queue can replace it later without interface changes.

### 1.8 The loop turn (tokio current-thread `Core::run`)

```pascal
type
  TEventLoop = class
  public
    Id: Integer;
    ThreadId: TThreadID;
    EpFd, WakeFd: cint;
    Timers: TTimerWheel;
    Date: TDateCache;
    Blocks: TBlockPool;           { section 4 }
    NowNs: Int64;
    procedure Run;                { thread body }
    procedure Spawn(T: TTask);
    procedure Schedule(T: TTask); { same thread only }
    procedure Post(const M: TLoopMsg);   { any thread }
    function Register(var R: TIoRegistration): Boolean;    { EPOLL_CTL_ADD, ET, IN|OUT|RDHUP }
    procedure Deregister(var R: TIoRegistration);
    procedure GracefulShutdownAll;       { section 1.9 }
    property LiveConnections: Integer;
  end;

const
  EVENT_INTERVAL = 61;   { tokio current_thread: polls the driver every 61 task polls }
  MAX_EVENTS = 1024;
```

```
Run:
  loop
    n := 0
    while (RunQueue not empty) and (n < EVENT_INTERVAL):
      T := pop; T.FScheduled := 0
      Cx.Waker := T.Waker; Cx.Loop := Self
      try  done := T.Poll(Cx)  except on E do T.Abort(E); done := True  end
      if done: free slot (Gen += 1), free T
      inc(n)
    timeout := 0 if (RunQueue or Deferred not empty) else Timers.NextTimeoutMs(NowNs) (-1 = infinite)
    if timeout <> 0: Sleeping := 1; if Inbox not empty: timeout := 0
    k := epoll_wait(EpFd, Events, MAX_EVENTS, timeout); Sleeping := 0
    NowNs := MonoNowNs
    for each event: R := data.ptr; R.Ready += bits; wake R.ReadWaker / R.WriteWaker as tokio does
    Timers.Advance(NowNs)
    drain Inbox (wakes with generation check, lmRun jobs, lmGraceful, lmStop)
    move Deferred to RunQueue
```

### 1.9 Graceful shutdown

Per connection: `TH1Connection.GracefulShutdown` = hyper `Connection::graceful_shutdown` =
`Dispatcher::disable_keep_alive` (dispatch.rs:90-100), then wake the task so it is polled again (the
reference server re-polls after calling it; without the poll an idle connection would not notice).

Per server (hyper-util `GracefulShutdown`): `THttpServer.Shutdown(GraceMs)` (any thread, also wired to
SIGTERM/SIGINT through a `signalfd` registered on loop 0):

1. Post `lmGraceful` to every loop. Each loop deregisters and closes its listener, then calls
   `GracefulShutdown` on every live connection (each loop keeps an intrusive list of its connection tasks).
2. A loop exits when it has no live connections, or at the deadline, when it closes the remaining
   sockets (dropping their tasks, which cancels in-flight calls as in section 3.6).
3. `Shutdown` returns after all loop threads have exited and the worker pool has drained.

---

## 2. Connection state machine: port plan

The rule: each hyper function becomes one Pascal method with the same name in Pascal case, the same
statements in the same order, and a `{ conn.rs:NNN }` comment. A reviewer can read both side by side.
Every deviation is listed in Appendix A with its reason.

### 2.1 Shared result and error types

```pascal
unit bearings.http.error;      { port of src/error.rs, server-side kinds only }

type
  THyperErrorKind = (hekParse, hekUser, hekIncompleteMessage, hekUnexpectedMessage, hekCanceled,
    hekChannelClosed, hekIo, hekHeaderTimeout, hekBody, hekBodyWrite, hekShutdown, hekHttp2);
  THyperUserKind = (hukNone, hukBody, hukBodyWriteAborted, hukService, hukUnsupportedStatusCode,
    hukNoUpgrade, hukManualUpgrade, hukHeader, hukDispatchGone);
  TErrorCauseKind = (eckNone, eckErrno, eckDecode, eckMessage, eckObject);

  { Plain record (no managed fields): copying it never calls fpc_copy and routines with a
    THyperError local get no implicit exception frame. }
  THyperError = record
    Kind: THyperErrorKind;
    Parse: TH1ParseError;          { hekParse }
    User: THyperUserKind;          { hekUser }
    Cause: TErrorCauseKind;
    Errno: cint;                   { eckErrno: io::Error from the OS }
    Decode: TDecodeError;          { eckDecode: the body decoder's io::Error (kind + message) }
    Msg: PAnsiChar;                { eckMessage: static text, e.g. 'connection error' }
    Obj: TObject;                  { eckObject: owned cause (Exception from a service / body) }
    function IsParse: Boolean;
    function IsParseTooLarge: Boolean;      { TooLarge or UriTooLong }
    function IsParseVersionH2: Boolean;
    function IsUser: Boolean;
    function IsCanceled: Boolean;
    function IsClosed: Boolean;
    function IsIncompleteMessage: Boolean;
    function IsBodyWriteAborted: Boolean;
    function IsShutdown: Boolean;
    function IsTimeout: Boolean;            { HeaderTimeout or a TimedOut cause }
    function Description: string;          { hyper Display text; cold path }
    procedure Clear;                        { frees Obj }
  end;

function NewIncomplete: THyperError;
function NewTooLarge: THyperError;
function NewVersionH2: THyperError;
function NewIo(Errno: cint): THyperError;
function NewHeaderTimeout: THyperError;
function NewBody(const Cause: THyperError): THyperError;      { Error::new_body }
function NewBodyWrite(Errno: cint): THyperError;
function NewBodyWriteAborted(NotEofRemaining: QWord): THyperError;
function NewShutdown(Errno: cint): THyperError;
function NewUserService(const Cause: THyperError): THyperError;
function NewUserBody(const Cause: THyperError): THyperError;
function NewUserHeader: THyperError;
function NewUserUnsupportedStatusCode: THyperError;
function NewUserManualUpgrade: THyperError;
function NewParse(E: TH1ParseError): THyperError;
```

Ownership: a `THyperError` with `Obj <> nil` is moved, not copied. The connection calls `Clear` once
when it reports its result.

Rust shapes and their Pascal encodings:

| Rust | Pascal |
|---|---|
| `Poll<()>` | `TPoll` |
| `Poll<crate::Result<()>>` | `TPollResult` + `var Err: THyperError` |
| `Poll<Option<crate::Result<T>>>` | `TPollOpt = (poSome, poErr, poNone, poPending)` + `out` value + `var Err` |
| `ready!(x)` | `if R = prPending then Exit(prPending);` |
| `x?` | `if R = prErr then Exit(prErr);` (Err already filled) |
| `Option<T>` field | `T` + `HasX: Boolean`, or `nil` for object references, `-1` for sizes |
| enum with payload (`Reading::Body(Decoder)`) | kind field + payload field (`Reading: TReading; ReadDecoder: TDecoder`) |
| `Pin<Box<dyn Future>>` | object reference with a virtual `Poll` |

### 2.2 io.rs: `TBuffered`

```pascal
unit bearings.http1.io;

const
  INIT_BUFFER_SIZE = 8192;                         { io.rs:15 }
  MINIMUM_MAX_BUFFER_SIZE = INIT_BUFFER_SIZE;      { io.rs:18 }
  DEFAULT_MAX_BUFFER_SIZE = 8192 + 4096 * 100;     { io.rs:23 }
  MAX_BUF_LIST_BUFFERS = 16;                       { io.rs:30 }
  MAX_WRITEV_BUFS = 64;                            { io.rs:288 }

type
  { io.rs:372-458 ReadStrategy::Adaptive (Exact is client-only). }
  TReadStrategy = record
    DecreaseNow: Boolean;
    Next: SizeUInt;
    Max: SizeUInt;
    class function WithMax(AMax: SizeUInt): TReadStrategy; static;
    class function Default: TReadStrategy; static;          { WithMax(DEFAULT_MAX_BUFFER_SIZE) }
    function NextSize: SizeUInt; inline;
    function MaxSize: SizeUInt; inline;
    procedure Record_(BytesRead: SizeUInt);                  { io.rs:408-440 }
  end;
function IncrPowerOfTwo(N: SizeUInt): SizeUInt; inline;     { saturating * 2 }
function PrevPowerOfTwo(N: SizeUInt): SizeUInt; inline;     { (High(SizeUInt) shr (lzcnt(N)+2)) + 1 }

type
  TWriteStrategy = (wsFlatten, wsQueue);

  { io.rs:460-523 Cursor<Vec<u8>>: the reusable head buffer. }
  TCursorVec = record
    Bytes: TBytes;                { capacity = Length(Bytes) }
    Len: SizeInt;                 { Vec::len }
    Pos: SizeInt;
    function Remaining: SizeInt; inline;
    function Chunk: PByte; inline;
    procedure Advance(N: SizeInt); inline;
    procedure MaybeUnshift(Additional: SizeInt);    { io.rs:477-490 }
    procedure Reset; inline;                         { pos = 0, len = 0 }
    procedure ExtendFromSlice(P: PByte; N: SizeInt); { Vec growth: Max(2*cap, len+N, 8) }
  end;

  { One element of BufList<EncodedBuf<B>> (common/buf.rs). }
  TQueuedKind = (qkEncoded, qkOwned, qkFile);
  TQueuedBuf = record
    Kind: TQueuedKind;
    Enc: TEncodedBuf;             { qkEncoded: chunk-size prefix + data + static suffix (M2 type) }
    Data: TBytesView;             { reference that keeps Enc's data alive; released when consumed }
    Owned: TBytes; OwnedPos: SizeInt;   { qkOwned: trailer section bytes }
    FileFd: cint; FileOff: Int64; FileLen: Int64;  { qkFile (DV-14) }
    function Remaining: SizeInt;
  end;

  TBufList = record               { VecDeque<B>: ring, grows when full }
    Items: array of TQueuedBuf;
    Head, Count: Integer;
    function BufsCnt: Integer; inline;
    function Remaining: SizeInt;
    function HasRemaining: Boolean; inline;
    procedure Push(var B: TQueuedBuf);
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
    procedure Advance(N: SizeInt); { releases fully consumed entries' TBytesView }
  end;

  { io.rs:525-646 WriteBuf<B>. }
  TWriteBuf = record
    Headers: TCursorVec;
    MaxBufSize: SizeInt;
    Queue: TBufList;
    Strategy: TWriteStrategy;
    procedure Init(AStrategy: TWriteStrategy);      { headers capacity INIT_BUFFER_SIZE }
    procedure Buffer(var B: TQueuedBuf);            { io.rs:549-584: Flatten copies, Queue pushes }
    function CanBuffer: Boolean;                    { io.rs:586-593 }
    function HeadersMut: PCursorVec;                { asserts not Queue.HasRemaining }
    function Remaining: SizeInt;
    function Chunk(out Len: SizeInt): PByte;
    procedure Advance(Cnt: SizeInt);                { io.rs:627-639 }
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
  end;

  { io.rs:32-40 Buffered<T, B>. }
  TBuffered = record
    FlushPipeline: Boolean;
    Io: TIoStream;
    PartialLen: SizeInt;          { Option<usize>: -1 = None }
    ReadBlocked: Boolean;
    ReadBuf: TReadBuf;            { BytesMut port, section 4.2 }
    ReadBufStrategy: TReadStrategy;
    WriteBuf: TWriteBuf;
    procedure Init(AIo: TIoStream; Pool: TBlockPool);    { strategy from Io.IsWriteVectored }
    procedure SetFlushPipeline(Enabled: Boolean);         { forces Flatten }
    procedure SetMaxBufSize(Max: SizeInt);                { raises if < MINIMUM_MAX_BUFFER_SIZE }
    procedure SetWriteStrategyFlatten;
    procedure SetWriteStrategyQueue;
    function ReadBufData: PByte; inline;
    function ReadBufLen: SizeInt; inline;
    function CanHeadersBuf: Boolean; inline;              { not Queue.HasRemaining }
    function HeadersBuf: PCursorVec; inline;
    procedure Buffer(var B: TQueuedBuf); inline;
    function HasBufferedWrite: Boolean; inline;
    function CanBuffer: Boolean; inline;                  { FlushPipeline or WriteBuf.CanBuffer }
    procedure ConsumeLeadingLines;                        { io.rs:161-172 }
    { io.rs:174-229 parse::<Server>. On prOk Head is the split-off head (a block reference). }
    function Parse(var Cx: TContext; const Ctx: TH1ParseContext; Headers: THttpHeaders;
      out Msg: TParsedRequestHead; out Head: TBytesView; var Err: THyperError): TPollResult;
    { io.rs:231-268 }
    function PollReadFromIo(var Cx: TContext; out N: SizeInt; out Errno: cint): TIoPoll;
    function IsReadBlocked: Boolean; inline;
    { io.rs:278-335 }
    function PollFlush(var Cx: TContext; out Errno: cint): TIoPoll;
    function PollFlushFlattened(var Cx: TContext; out Errno: cint): TIoPoll;
    function PollShutdown(var Cx: TContext; out Errno: cint): TIoPoll;   { flush, then Io.PollShutdown }
    { io.rs:361-369 MemRead::read_mem }
    function ReadMem(var Cx: TContext; Len: SizeInt; out Chunk: TBytesView; out Errno: cint): TIoPoll;
    procedure IntoInner(out AIo: TIoStream; out ReadBuf: TBytesView);  { io.rs:270 }
  end;
```

Details that the port keeps because they are visible on the wire or in limits:

- **Read size = spare capacity after reserve.** `PollReadFromIo` computes
  `next := Min(ReadBufStrategy.NextSize, ReadBufStrategy.MaxSize - ReadBuf.Len)`, calls
  `ReadBuf.Reserve(next)` only if spare capacity `< next`, then reads into **all** spare capacity
  (`chunk_mut()`), not just `next` bytes (io.rs:235-249). Because `TReadBuf.Reserve` reproduces
  `BytesMut::reserve` capacities (section 4.2), the 431 decisions (`curr_len >= max` after a read,
  io.rs:211-215) happen at the same byte counts: with `max_buf_size = 8192` the first reserve gives
  capacity 8192 exactly, so the buffer can never hold more than 8192 bytes, as in hyper.
- **`ReadStrategy.Record_`** is called with every successful read count, including 0 (io.rs:259).
- **Flush loop.** Queue: `writev` with up to 64 slices until `Remaining = 0`; `n = 0` with bytes left is
  `WriteZero` (error); Flatten: `write` of the head cursor. `PollFlush` returns `ioReady` without
  writing when `FlushPipeline and (ReadBuf.Len > 0)` (io.rs:279-280).
- **`PollShutdown`** flushes first (io.rs:337-340); the hyper regression test
  `h1_shutdown_while_buffered.rs` is ported (section 7.3).

### 2.3 conn.rs: `TConn`

```pascal
unit bearings.http1.conn;

type
  TReading = (rdInit, rdContinue, rdBody, rdKeepAlive, rdClosed);   { conn.rs:992-999 }
  TWriting = (wrInit, wrBody, wrKeepAlive, wrClosed);               { conn.rs:1001-1006 }
  TKA = (kaIdle, kaBusy, kaDisabled);                               { conn.rs:1051-1057, default Busy }
  TWant = (wUpgrade, wExpect);
  TWants = set of TWant;

  { conn.rs:940-990 State (server fields only). }
  TConnState = record
    AllowHalfClose: Boolean;
    CachedHeaders: THttpHeaders;          { reused request header list (DV-4) }
    HasError: Boolean;
    Error: THyperError;
    KeepAlive: TKA;
    Method: THttpMethod;                  { hmNone = None }
    ParseCtx: TH1ParseContext;            { parser config, h1_max_headers, h1_max_header_size }
    HeaderReadTimeoutNs: Int64;           { -1 = None }
    HeaderReadTimeoutSleep: TSleep;       { h1_header_read_timeout_fut; Entry.State tells Some/None }
    HasHeaderReadTimeoutFut: Boolean;
    HeaderReadTimeoutRunning: Boolean;
    DateHeader: Boolean;
    TimerSet: Boolean;                    { Time::Timer vs Time::Empty }
    TitleCaseHeaders: Boolean;
    NotifyRead: Boolean;
    Reading: TReading;
    ReadDecoder: TDecoder;                { payload of Continue / Body }
    Writing: TWriting;
    WriteEncoder: TEncoder;               { payload of Body }
    Upgrade: TOnUpgrade;                  { Option<upgrade::Pending>: the conn-side reference, nil = None }
    Version: THttpVersion;
    AllowTrailerFields: Boolean;
    procedure Close;                      { conn.rs:1062 }
    procedure CloseRead;
    procedure CloseWrite;
    function WantsKeepAlive: Boolean;
    procedure TryKeepAlive;               { conn.rs:1088-1108 }
    procedure DisableKeepAlive;
    procedure Busy;
    procedure Idle;                       { conn.rs:1121-1152 incl. notify_read when a timeout is set }
    function IsIdle: Boolean;
    function IsReadClosed: Boolean;
    function IsWriteClosed: Boolean;
    function PrepareUpgrade: TOnUpgrade;  { conn.rs:1170 }
  end;

  TConn = record
    Io: TBuffered;
    State: TConnState;
    procedure Init(AIo: TIoStream; Loop: TEventLoop);        { conn.rs:50-89 }
    { setters used by TH1Builder.ServeConnection (http1.rs:470-522) }
    procedure SetTimer(Enabled: Boolean);
    procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetWriteStrategyQueue;
    procedure SetWriteStrategyFlatten;
    procedure SetMaxBufSize(Max: SizeInt);
    procedure SetH1ParserConfig(const C: TParserConfig);
    procedure SetTitleCaseHeaders;
    procedure SetHttp1MaxHeaders(N: Integer);
    procedure SetHttp1MaxHeaderSize(N: SizeInt);
    procedure SetHttp1HeaderReadTimeout(Ns: Int64);
    procedure SetAllowHalfClose;
    procedure DisableDateHeader;

    procedure IntoInner(out AIo: TIoStream; out ReadBuf: TBytesView);
    function PendingUpgrade: TOnUpgrade;                       { take() }
    function IsReadClosed: Boolean;
    function IsWriteClosed: Boolean;
    function CanReadHead: Boolean;                             { conn.rs:177-187: Reading = Init }
    function CanReadBody: Boolean;
    function HasInitialReadWriteState: Boolean;                { conn.rs:197-201 }
    function HasH2Prefix: Boolean;                             { conn.rs:208-211 }

    { conn.rs:213-337 }
    function PollReadHead(var Cx: TContext; out Req: TParsedRequestHead; out Head: TBytesView;
      out Wants: TWants; var Err: THyperError): TPollOpt;
    function OnReadHeadError(var Cx: TContext; var Err: THyperError): TPollOpt;   { conn.rs:339-363 }
    { conn.rs:365-433. poSome: Data (TBytesView) or Trailers (owned list). }
    function PollReadBody(var Cx: TContext; out Frame: TInFrame; var Err: THyperError): TPollOpt;
    function WantsReadAgain: Boolean;                          { conn.rs:435-439 }
    function PollReadKeepAlive(var Cx: TContext; var Err: THyperError): TPollResult;  { conn.rs:441-451 }
    function IsMidMessage: Boolean;
    function MidMessageDetectEof(var Cx: TContext; var Err: THyperError): TPollResult; { conn.rs:493-510 }
    function ForceIoRead(var Cx: TContext; out N: SizeInt; out Errno: cint): TIoPoll; { conn.rs:512-522 }
    procedure MaybeNotify(var Cx: TContext);                   { conn.rs:524-568 }
    procedure TryKeepAlive(var Cx: TContext);                  { conn.rs:570-573 }

    function CanWriteHead: Boolean;                            { conn.rs:575-584 }
    function CanWriteBody: Boolean;
    function CanBufferBody: Boolean;
    function HasBufferedWrite: Boolean;
    procedure WriteHead(Resp: TOutgoingResponse; const Body: TBodyLength);   { conn.rs:600-611 }
    function EncodeHead(Resp: TOutgoingResponse; const Body: TBodyLength;
      out Enc: TEncoder): Boolean;                             { conn.rs:613-668 }
    procedure FixKeepAlive(Resp: TOutgoingResponse);           { conn.rs:671-698 }
    procedure EnforceVersion(Resp: TOutgoingResponse);         { conn.rs:702-731 }
    procedure WriteBody(var Chunk: TBytesView);                { conn.rs:733-756 }
    procedure WriteTrailers(Trailers: THttpHeaders);           { conn.rs:758-779 }
    procedure WriteBodyAndEnd(var Chunk: TBytesView);          { conn.rs:781-799 }
    function EndBody(var Err: THyperError): Boolean;           { conn.rs:801-829 }
    function OnParseError(var Err: THyperError): Boolean;      { conn.rs:836-853; True = Ok(()) }
    function PollFlush(var Cx: TContext; out Errno: cint): TIoPoll;          { + try_keep_alive }
    function PollShutdown(var Cx: TContext; out Errno: cint): TIoPoll;
    procedure PollDrainOrCloseRead(var Cx: TContext);          { conn.rs:874-892 }
    procedure CloseRead;
    procedure CloseWrite;
    procedure DisableKeepAlive;                                { conn.rs:902-911 }
    function TakeError(var Err: THyperError): Boolean;
    function OnUpgrade: TOnUpgrade;
  end;
```

How each listed behavior lands, with the hyper code it ports:

- **Header read timeout** (conn.rs:223-283). Before `Io.Parse`, if not running and a timeout is set:
  arm or reset `HeaderReadTimeoutSleep` to `MonoNowNs + timeout` with `Cx.Waker`. When `Parse`
  returns `prPending` and the timer is running: poll the sleep; if it fired, return
  `NewHeaderTimeout` (no response, outcome `timeout`). When a head is parsed: running := False, cancel.
  `State.Idle` sets `NotifyRead` when a timeout is configured (conn.rs:1146-1151), so the dispatcher
  loops once more and `PollReadHead` re-arms the timer right after a response: this is what makes the
  header timeout also the keep-alive idle timeout.
- **Expect: 100-continue** (conn.rs:309-325, 411-422). A head with `expect_continue`, a non-zero
  body and version > 1.0 sets `Reading := rdContinue` and adds `wExpect`. The dispatcher creates the
  body channel with `want = False` (`TBodyChan.Create(Wanter = True)`, chan.rs:11-19). The dispatcher's
  `body.poll_ready` stays pending until the receiver polls for the first time (the service "polls the
  body"); then `PollReadBody` sees `rdContinue`, appends `HTTP/1.1 100 Continue\r\n\r\n` to the head
  buffer if `Writing = wrInit`, switches to `rdBody` and recurses once. The bytes go out in the same
  dispatcher iteration's flush. If the service drops the body unread, `PollDrainOrCloseRead` switches
  `rdContinue` to `rdBody` without the 100 and makes one read attempt (conn.rs:875-881).
- **half_close** (conn.rs:493-510): while a request is in progress and nothing is buffered, the dispatcher
  keeps a read pending (`MidMessageDetectEof`). EOF → `CloseRead`, `NewIncomplete` → the connection ends,
  dropping the in-flight call (section 3.6). With `AllowHalfClose` the read is not attempted.
- **Keep-alive** state machine, `TryKeepAlive`, `Idle`, `Busy`, `DisableKeepAlive`: line-for-line.
- **Pipelining.** The next head is parsed only when `CanReadHead` (Reading = Init), which `Idle` sets
  after both sides reached KeepAlive. `MaybeNotify` (conn.rs:524-568) sets `NotifyRead` when the read side
  is Init and the reader is not blocked; with bytes already buffered it does not read and only notifies.
- **Error → response** (conn.rs:339-363, 836-853, role.rs:493-511): `OnReadHeadError` closes the read
  side, consumes leading CR/LF, and when the buffer is not empty or the error is a parse error calls
  `OnParseError`: with `Writing = wrInit` and an h2 preface in the buffer → `NewVersionH2` (nothing
  written); else `ServerErrorStatus(E)` > 0 → write that head with no body (`connection: close`
  appears because keep-alive is disabled), store the error, return `poPending` (hyper's "XXX: wat?"
  `Poll::Pending`); the dispatcher flushes and ends with the stored error (outcome `parse` or
  `parse_too_large`). Otherwise the error is returned (outcome `incomplete`, `io`, ...).
- **1xx from the service**: `ServerEncode` returns `serUnsupportedStatusCode` with a 500 head already
  in the buffer; `EncodeHead` stores `NewUserUnsupportedStatusCode`, sets `wrClosed` and keeps the bytes
  (hyper writes them). `serUserHeader` (bad CL/TE combination from the service): nothing written,
  error stored, `wrClosed`.
- **HTTP/2 preface**: `HasH2Prefix` (conn.rs:208-211) on a parse error, as above. Section 2.7 covers
  serving it.

### 2.4 dispatch.rs: `TDispatcher`

```pascal
unit bearings.http1.dispatch;

type
  TDispatched = (dpShutdown, dpUpgrade);

  { dispatch.rs:46-52 Server<S, B> + impl Dispatch (597-670) }
  TServerDispatch = record
    Service: THttpService;
    InFlight: TServiceCall;             { nil = None }
    Req: TIncomingRequest;              { per-connection reusable request object }
    Resp: TOutgoingResponse;            { per-connection reusable response object }
    function PollMsg(var Cx: TContext; var Err: THyperError): TPollOpt;    { Some = Resp filled }
    function RecvMsg(var Head: TParsedRequestHead; const HeadBytes: TBytesView; Body: TIncoming;
      Upgrade: TOnUpgrade; var Err: THyperError): Boolean;               { calls Service.Call }
    function PollReady: Boolean; inline;      { InFlight = nil }
    function ShouldPoll: Boolean; inline;     { InFlight <> nil }
  end;

  { dispatch.rs:22-28 }
  TDispatcher = record
    Conn: TConn;
    Dispatch: TServerDispatch;
    BodyTx: TBodySender;                { SenderDropGuard: Finalize sends NewIncomplete }
    BodyRx: TOutgoingBody;              { Pin<Box<Option<Bs>>>: nil = None }
    IsClosing: Boolean;
    procedure DisableKeepAlive;                                           { 90-100 }
    procedure IntoInner(out AIo: TIoStream; out ReadBuf: TBytesView);
    function PollWithoutShutdown(var Cx: TContext; var Err: THyperError): TPollResult;    { 112-121 }
    function PollCatch(var Cx: TContext; ShouldShutdown: Boolean; out D: TDispatched;
      var Err: THyperError): TPollResult;                                 { 123-141 }
    function PollInner(var Cx: TContext; ShouldShutdown: Boolean; out D: TDispatched;
      var Err: THyperError): TPollResult;                                 { 143-164 }
    function PollLoop(var Cx: TContext; var Err: THyperError): TPollResult;     { 166-223 }
    function PollRead(var Cx: TContext; var Err: THyperError): TPollResult;     { 225-296 }
    function PollReadHead(var Cx: TContext; var Err: THyperError): TPollResult; { 298-348 }
    function PollWrite(var Cx: TContext; var Err: THyperError): TPollResult;    { 350-437 }
    function PollFlush(var Cx: TContext; var Err: THyperError): TPollResult;    { 439-444 }
    procedure Close;                                                      { 446-450 }
    function CanWriteAgain: Boolean;                                      { 454-456 }
    function IsDone: Boolean;                                             { 458-473 }
    procedure Drop;     { Drop for Dispatcher: cancels InFlight, releases BodyRx, BodyTx guard }
  end;
```

The two loops, as Pascal (they show the port style; the rest of the unit follows the same pattern):

```pascal
function TDispatcher.PollLoop(var Cx: TContext; var Err: THyperError): TPollResult;
var
  I: Integer;
  R: TPollResult;
  WriteReady, FlushReady, WantsWriteAgain, WantsReadAgain: Boolean;
begin
  for I := 1 to 16 do                                   { dispatch.rs:172 }
  begin
    if PollRead(Cx, Err) = prErr then Exit(prErr);      { let _ = self.poll_read(cx)?; }
    R := PollWrite(Cx, Err);
    if R = prErr then Exit(prErr);
    WriteReady := R = prOk;
    R := PollFlush(Cx, Err);
    if R = prErr then Exit(prErr);
    FlushReady := R = prOk;
    WantsWriteAgain := CanWriteAgain and (WriteReady or FlushReady);
    WantsReadAgain := Conn.WantsReadAgain;
    if not (WantsWriteAgain or WantsReadAgain) then Exit(prOk);
    if (not WantsReadAgain) and WantsWriteAgain then    { dispatch.rs:201-218 }
    begin
      R := PollWrite(Cx, Err);
      if R = prErr then Exit(prErr);
      if R = prPending then
      begin
        if Conn.HasBufferedWrite then
          if PollFlush(Cx, Err) = prErr then Exit(prErr);
        Exit(prOk);
      end;
    end;
  end;
  Cx.YieldNow;                                          { task::yield_now(cx) }
  Result := prPending;
end;

function TDispatcher.PollWrite(var Cx: TContext; var Err: THyperError): TPollResult;
var
  F: TOutFrame;
  N: QWord;
  BL: TBodyLength;
begin
  while True do
  begin
    if IsClosing then Exit(prOk)
    else if (BodyRx = nil) and Conn.CanWriteHead and Dispatch.ShouldPoll then
    begin
      case Dispatch.PollMsg(Cx, Err) of
        poPending: Exit(prPending);
        poErr: begin Err := NewUserService(Err); Exit(prErr); end;
        poNone: begin Close; Exit(prOk); end;
      end;
      if Dispatch.Resp.Body.IsEndStream then
      begin
        Dispatch.Resp.ReleaseBody;
        BL.Kind := blkNone;                              { body_type = None }
      end
      else
      begin
        if Dispatch.Resp.Body.SizeHint(N) then begin BL.Kind := blkKnown; BL.Len := N; end
        else BL.Kind := blkUnknown;
        BodyRx := Dispatch.Resp.TakeBody;
      end;
      Conn.WriteHead(Dispatch.Resp, BL);
    end
    else if not Conn.CanBufferBody then
    begin
      Result := PollFlush(Cx, Err);
      if Result <> prOk then Exit;
    end
    else if BodyRx <> nil then
    begin
      if not Conn.CanWriteBody then begin ClearBodyRx; Continue; end;
      case BodyRx.PollFrame(Cx, F, Err) of
        fpPending: Exit(prPending);
        fpError: begin ClearBodyRx; Err := NewUserBody(Err); Exit(prErr); end;
        fpData:
          if BodyRx.IsEndStream then
          begin
            if F.Data.Len = 0 then
            begin
              F.Data.Release;
              ClearBodyRx;
              if not Conn.EndBody(Err) then Exit(prErr);
            end
            else
            begin
              Conn.WriteBodyAndEnd(F.Data);
              ClearBodyRx;
            end;
          end
          else if F.Data.Len = 0 then
            F.Data.Release                                { "discarding empty chunk" }
          else
            Conn.WriteBody(F.Data);
        fpTrailers: begin ClearBodyRx; Conn.WriteTrailers(F.Trailers); end;
        fpEnd: begin ClearBodyRx; if not Conn.EndBody(Err) then Exit(prErr); end;
      end;
    end
    else if Conn.CanWriteBody then
    begin
      if not Conn.EndBody(Err) then Exit(prErr);
    end
    else
      Exit(prPending);
  end;
end;
```

`PollRead` (dispatch.rs:225-296) follows the same pattern: `CanReadHead` → `PollReadHead`; else if
`BodyTx` is set and `CanReadBody`: `BodyTx.PollReady` (receiver gone → `PollDrainOrCloseRead`), then
`Conn.PollReadBody` and `TrySendData` / `TrySendTrailers` / `SendError(NewBody(...))`; else
`Conn.PollReadKeepAlive`.

`PollCatch` (dispatch.rs:123-141): on error, send `NewBody('connection error')` to a live body
receiver, then `Dispatch.RecvMsg(Err)` which, for the server, returns the error itself
(dispatch.rs:633 `let (msg, body) = msg?;`), so the connection result is that error.

### 2.5 server/conn/http1.rs: builder and connection modes

```pascal
unit bearings.http1.server;

type
  TDurKind = (dkDefault, dkConfigured);           { common/time.rs Dur }
  TH1ConnMode = (cmPlain, cmWithUpgrades, cmWithoutShutdown);
  TTriState = (tsAuto, tsTrue, tsFalse);

  { http1.rs Builder, defaults of Builder::new() }
  TH1Builder = record
    ParserConfig: TParserConfig;
    Timer: Boolean;                    { Time::Timer (the loop's wheel) vs Time::Empty }
    HalfClose: Boolean;                { false }
    KeepAlive: Boolean;                { true }
    TitleCaseHeaders: Boolean;
    PreserveHeaderCase: Boolean;       { accepted; THttpHeaders always keeps request case }
    MaxHeaders: Integer;               { -1 = None (100) }
    MaxHeaderSize: SizeInt;            { -1 = None }
    HeaderReadTimeoutKind: TDurKind;   { Default(Some(30 s)) }
    HeaderReadTimeoutMs: Int64;        { -1 = None }
    Writev: TTriState;
    MaxBufSize: SizeInt;               { -1 = None }
    PipelineFlush: Boolean;
    DateHeader: Boolean;               { true }
    class function New: TH1Builder; static;
    { Time::check (common/time.rs:72-89): Default + no timer -> disabled; Configured + no timer ->
      raises EH1Config (hyper panics). }
    function CheckHeaderReadTimeout(out Ns: Int64): Boolean;
    function ServeConnection(Io: TIoStream; Service: THttpService; Loop: TEventLoop;
      Mode: TH1ConnMode): TH1Connection;                      { http1.rs:470-522 }
  end;

  { http1.rs Parts }
  TH1Parts = record
    Io: TIoStream;
    ReadBuf: TBytesView;
    Service: THttpService;
  end;

  { Connection + UpgradeableConnection + without_shutdown, one class, chosen by Mode. }
  TH1Connection = class
  public
    Dispatcher: TDispatcher;           { by value: one allocation per connection }
    Mode: TH1ConnMode;
    Upgraded: Boolean;                 { UpgradeableConnection.inner = None }
    { Connection::graceful_shutdown / UpgradeableConnection::graceful_shutdown (no-op once upgraded) }
    procedure GracefulShutdown;
    { cmPlain: Connection::poll (Upgrade -> pending.manual(), Ok).
      cmWithUpgrades: UpgradeableConnection::poll (Upgrade -> into_inner, fulfill(Upgraded), Ok).
      cmWithoutShutdown: poll_without_shutdown. }
    function Poll(var Cx: TContext; var Err: THyperError): TPollResult;
    function IntoParts(out Parts: TH1Parts): Boolean;   { only after cmWithoutShutdown Ok }
    destructor Destroy; override;      { drop: Dispatcher.Drop, then Io.Close }
  end;

  { tokio::spawn(serve_conn(...)): the task that owns one connection. }
  TConnDoneEvent = procedure(Task: TH1ConnTask; Ok: Boolean; var Err: THyperError) of object;
  TH1ConnTask = class(TTask)
  public
    Conn: TH1Connection;
    OnDone: TConnDoneEvent;            { called after the connection was dropped }
    function Poll(var Cx: TContext): Boolean; override;
  end;
```

The order at the end of a connection matches the reference server: `Poll` returns Ready → drop the
`TH1Connection` (in-flight call cancelled, body dropped, socket closed unless parts were taken) →
`OnDone`. That is why `handler_dropped` precedes `conn_close` in the conformance events.

### 2.6 Upgrades and CONNECT with leftover bytes

```pascal
unit bearings.http.upgrade;

type
  TUpgraded = record                  { upgrade.rs Upgraded = Rewind<io> }
    Io: TIoStream;                    { ownership moves to the receiver }
    ReadBuf: TBytesView;              { bytes read past the head; consume these first }
  end;

  TUpgradeState = (usPending, usFulfilled, usManual, usCanceled);

  { One object shared by the connection (hyper upgrade::Pending) and the request (OnUpgrade):
    atomic refcount 2. }
  TOnUpgrade = class
  public
    function Poll(var Cx: TContext; out U: TUpgraded; var Err: THyperError): TPollResult;
    procedure Fulfill(const U: TUpgraded);     { Pending::fulfill }
    procedure Manual;                          { Pending::manual: Err = NewUserManualUpgrade }
    procedure Release;                         { drop of either side; conn side unfulfilled -> canceled }
  end;

function TakeUpgrade(Req: TIncomingRequest): TOnUpgrade;   { hyper::upgrade::on(&mut req); nil -> NoUpgrade }
```

Flow (dispatch.rs:322-330, 152-160; http1.rs:562-592): a request with an `Upgrade` header (HTTP/1.1) or
method CONNECT gets `wUpgrade`; `PollReadHead` calls `Conn.OnUpgrade`, which stores the conn side in
`State.Upgrade` and puts the request side in `Req.Upgrade`. When the response is 101 (or 2xx to CONNECT)
`ServerEncode` marks the encoder `is_last` (role.rs:404-410) and forces a zero-length body, so the write
side goes to `wrClosed`; `TryKeepAlive` sees `(rdKeepAlive, wrClosed)` and closes the read side;
`IsDone` becomes true and `PollInner` takes `State.Upgrade` and returns `dpUpgrade` without shutting
down the socket. Then:

- `cmWithUpgrades`: `Dispatcher.IntoInner(Io, ReadBuf)` (`ReadBuf` = the unparsed bytes, e.g.
  `eagerly optimistic`), `Pending.Fulfill`, connection result Ok. The `TTcpStream` is re-targeted to
  the waiting task with `SetOwner`; its epoll registration is kept.
- `cmPlain`: `Pending.Manual`, result Ok, socket dropped (closed without shutdown).
- `cmWithoutShutdown`: result Ok; the caller calls `IntoParts`.

If the service returns a non-upgrade response, `State.Upgrade` keeps the pending side exactly as hyper
does: the next upgrade request replaces it (the earlier request side then resolves to canceled, "upgrade
expected but not completed"), and if the connection finishes while it is still set, `PollInner`
returns `dpUpgrade` (dispatch.rs:152-155). The port keeps this behavior rather than "fixing" it.

### 2.7 HTTP/2: where it plugs in later

- The task layer is protocol-neutral: `TConnTask` subclasses own one protocol connection.
  `TH2ConnTask` (later, over libnghttp2's sans-IO session) owns a `TBuffered`-like read/write pair and
  spawns one `TH2StreamTask` per request stream on the same loop (hyper spawns `H2Stream` per stream on
  its executor, proto/h2/server.rs:263-317; `Loop.Spawn` is our executor).
- The service interface (section 3) has no HTTP/1 types: `TIncomingRequest`, `TOutgoingResponse`,
  `TIncoming`, `TOutgoingBody`, `TServiceCall` serve both. `TIncoming` gets an `ikH2` kind whose
  `PollFrame` releases flow-control credit as the service consumes data (incoming.rs:180-230).
- Detection (hyper-util `auto::Builder`): `TAutoConnTask` reads up to 24 bytes into a `TBuffered` read
  buffer; preface → h2 session gets those bytes through `nghttp2_session_mem_recv2`; otherwise a
  `TH1Connection` is built **around the same `TBuffered`** (no `Rewind` wrapper needed because we own the
  buffer). TLS ALPN (later) chooses directly.
- Without auto detection (the conformance `http1_only` case), an HTTP/1 connection that receives the
  preface ends with `parse_version_h2` and writes nothing, as hyper does.

---

## 3. Service API (no closures)

### 3.1 Objects the application sees

```pascal
unit bearings.http.service;

type
  { http::Request<Incoming>. One object per connection, reused for each request. }
  TIncomingRequest = class
  public
    HeadBytes: TBytesView;          { the request head, a reference into the read buffer block }
    Method: THttpMethod;
    MethodSlice: TSlice;            { offsets relative to HeadBytes.P }
    Target: TSlice;
    Uri: TUriParts;
    Version: THttpVersion;
    Headers: THttpHeaders;          { external entries, ExternalBase = HeadBytes.P }
    Body: TIncoming;
    Upgrade: TOnUpgrade;            { hyper's OnUpgrade extension; take with TakeUpgrade }
    RemoteAddr, LocalAddr: TSockAddrStorage;
    function MethodStr: RawByteString;   { allocates; convenience }
    function Path(out P: PByte; out Len: SizeInt): Boolean;
    { Copies head bytes and headers into memory owned by this object, releasing the block
      reference. Needed only to keep the request beyond its exchange (section 4.4). }
    procedure Detach;
    procedure Release;              { drop(req): Body.Release, HeadBytes.Release }
  end;

  TBodyLength = record Kind: TBodyLengthKind; Len: QWord; end;   { role's Option<BodyLength> }

  { http::Response<B>. One object per connection, reused. }
  TOutgoingResponse = class
  public
    Head: TResponseHead;            { Status, Version, Reason, Headers (checked list, reused) }
    Body: TOutgoingBody;            { never nil: Reset installs the shared static TEmptyBody (http_body_util::Empty) }
    procedure Reset;                { 200, HTTP/1.1, no headers, no body }
    procedure SetStatus(S: Word);
    procedure SetVersion(V: THttpVersion);
    procedure SetReason(P: PByte; Len: SizeInt);              { validated (TReasonPhrase.TryFrom) }
    procedure SetHeader(const Name, Value: RawByteString);   { HeaderMap::insert, validated }
    procedure AddHeader(const Name, Value: RawByteString);   { HeaderMap::append, validated }
    function TrySetHeader(Name: PByte; NL: SizeInt; Value: PByte; VL: SizeInt): Boolean;
    procedure SetBodyStatic(P: PByte; Len: SizeInt);        { static memory: no reference counting }
    procedure SetBodyString(const S: RawByteString);        { keeps one string reference }
    procedure SetBodyView(const V: TBytesView);
    procedure SetBodyFile(Fd: cint; Offset, Len: Int64; CloseFd: Boolean);   { sendfile, DV-14 }
    procedure SetBody(B: TOutgoingBody);                    { any body, e.g. a stream }
    function TakeBody: TOutgoingBody;
    procedure ReleaseBody;
  end;
```

### 3.2 Bodies

```pascal
type
  TFramePoll = (fpData, fpTrailers, fpEnd, fpError, fpPending);

  TOutFrame = record
    Data: TBytesView;               { fpData; may be empty (dispatcher discards it) }
    Trailers: THttpHeaders;         { fpTrailers; ownership passes to the dispatcher }
    IsFile: Boolean;                { file segment (DV-14): Fd/Offset/Len }
    Fd: cint; Offset, Len: Int64;
  end;

  { http_body::Body for the response side }
  TOutgoingBody = class
  public
    function PollFrame(var Cx: TContext; out F: TOutFrame; var Err: THyperError): TFramePoll;
      virtual; abstract;
    function IsEndStream: Boolean; virtual;                 { default False }
    function SizeHint(out Exact: QWord): Boolean; virtual;  { default False (unknown) }
    procedure Release; virtual;                             { drop }
  end;

  TFullBody = class(TOutgoingBody)       { http_body_util::Full: IsEndStream = (Len = 0), exact hint }
  TEmptyBody = class(TOutgoingBody)      { IsEndStream True, exact 0 }
  TFileBody = class(TOutgoingBody)       { exact hint = file length; one file frame }
  TChannelBody = class(TOutgoingBody)    { fed from any thread, section 3.5 }

  { body/incoming.rs Incoming (request side) }
  TIncomingKind = (ikEmpty, ikChan);
  TIncoming = class
  public
    Kind: TIncomingKind;
    ContentLength: QWord;           { DecodedLength; sub_if per data chunk }
    Rx: TBodyReceiver;
    function PollFrame(var Cx: TContext; out Data: TBytesView; out Trailers: THttpHeaders;
      var Err: THyperError): TFramePoll;
    function IsEndStream: Boolean;
    function SizeHint(out Exact: QWord): Boolean;
    procedure Release;              { drop: receiver_open := False, wakes the sender }
  end;

  { body/chan.rs, ported with the same State fields and the same wake rules. }
  TBodyChan = class
  public
    Lock: TRTLCriticalSection;
    Item: TBytesView; HasItem: Boolean;
    ItemErr: THyperError; HasItemErr: Boolean;
    PendingError: THyperError; HasPendingError: Boolean;
    Trailers: THttpHeaders;
    SenderOpen, ReceiverOpen, Want: Boolean;
    SenderWaker, ReceiverWaker: TWaker;      { AtomicWaker: registered under Lock }
    RefCount: LongInt;                       { sender + receiver }
    constructor Create(Wanter: Boolean);     { Want := not Wanter }
  end;
  TBodySender = record    { chan.rs Sender: PollReady, TrySendData, TrySendTrailers, SendError, Drop }
  TBodyReceiver = record  { chan.rs Receiver: PollNext, TakeTrailers, Drop }
```

The mutex mirrors hyper's `Mutex<State>`; uncontended it costs ~20 ns per operation and only requests
with a body use the channel (a GET creates `ikEmpty`, as `IncomingBody::empty()`).

### 3.3 The service and its call (the future)

```pascal
type
  TCallPoll = (cpReady, cpError, cpPending);

  { S::Future. One object per request, usually pooled by the service. }
  TServiceCall = class
  public
    { cpReady: Resp is complete. cpError: Err holds the service error (hyper S::Error). }
    function Poll(var Cx: TContext; Resp: TOutgoingResponse; var Err: THyperError): TCallPoll;
      virtual; abstract;
    { drop before completion = cancellation. Must not touch the connection. }
    procedure Cancel; virtual;
    procedure Release; virtual;     { after cpReady / cpError / Cancel }
  end;

  { HttpService: Call is hyper's service.call(req) (runs in recv_msg, dispatch.rs:645);
    the returned call is polled from poll_write (dispatch.rs:600-632). }
  THttpService = class
  public
    function Call(Req: TIncomingRequest; Resp: TOutgoingResponse): TServiceCall; virtual; abstract;
  end;

  { One service instance per loop (hyper clones the service per connection). }
  TServiceFactory = function(Loop: TEventLoop): THttpService of object;
```

An inline service whose answer is known at once returns a pooled "ready" call whose first `Poll`
returns `cpReady` (hyper's `async {}` block also completes on its first poll). The call object of a
pipelined plaintext request is taken from and returned to a per-loop free list: no heap allocation per
request.

### 3.4 Producing responses

| need | how |
|---|---|
| known-length body | `Resp.SetBodyStatic` / `SetBodyString` / `SetBodyView` → `TFullBody`, `SizeHint` exact → `content-length` |
| empty | keep the default `TEmptyBody` → `IsEndStream` → `content-length: 0` (except HEAD/204/304) |
| streamed body, chunks over time, same loop | a `TOutgoingBody` subclass whose `PollFrame` returns `fpPending` and later `Cx.Waker.Wake`s (e.g. after a `TSleep`) |
| streamed body from another thread | `TChannelBody` (section 3.5) |
| trailers | `PollFrame` returns `fpTrailers` after the data; hyper's rules decide what is written (section 5.2) |
| sendfile | `Resp.SetBodyFile(fd, off, len)` → `TFileBody` (DV-14) |
| upgrade | `U := TakeUpgrade(Req)` in `Call`, respond 101; spawn a task that polls `U` (or pass a `TUpgradeHandler` object to `TUpgradeTask`) |

### 3.5 Where application code runs

**On the loop (inline).** `THttpService` subclasses that never block. Used by: the conformance server,
benchmark endpoints, proxies and anything written in poll style. This is hyper's model and the fast
path.

**On a worker pool (blocking).** Synchronous Proper-style controller code that may block on a database:

```pascal
unit bearings.http.blocking;

type
  TJob = class
    Next: TJob;
    procedure Execute; virtual; abstract;
  end;

  TWorkerPool = class
  public
    constructor Create(Threads: Integer; QueueLimit: Integer = 0);   { 0 = unbounded }
    procedure Submit(Job: TJob);          { any thread; mutex + condition variable queue }
    procedure Shutdown;                   { finish queued jobs, join }
    property Threads: Integer;
  end;

  { Worker-side views. }
  TBodyReader = class
  public
    { Blocks the worker until data, end or error. The first call is the first body poll:
      it sets want and the loop sends 100 Continue if the client asked for it. }
    function Read(Dst: PByte; Max: SizeInt): SizeInt;     { 0 = end of body }
    function ReadAll(MaxBytes: SizeInt): RawByteString;   { raises EHttpBodyTooLarge }
    function Trailers: THttpHeaders;                      { after Read returned 0 }
  end;

  TResponseWriter = class
  public
    { Sends the head now: completes the service call with a TChannelBody. }
    procedure Start;
    procedure Write(P: PByte; Len: SizeInt); overload;    { copies into a pooled block }
    procedure Write(const S: RawByteString); overload;    { keeps a string reference, no copy }
    procedure Finish(Trailers: THttpHeaders = nil);
    procedure Abort;                                      { body error: connection aborted }
    function Cancelled: Boolean;
  end;

  TBlockingRequest = class          { worker view of TIncomingRequest }
    Req: TIncomingRequest;
    Body: TBodyReader;
    function Cancelled: Boolean;
  end;
  TBlockingResponse = class         { worker view of TOutgoingResponse }
    Resp: TOutgoingResponse;
    function Stream: TResponseWriter;
  end;

  TBlockingHandler = class
  public
    procedure Handle(Req: TBlockingRequest; Resp: TBlockingResponse); virtual; abstract;
  end;

  TBlockingService = class(THttpService)
  public
    constructor Create(Pool: TWorkerPool; Handler: TBlockingHandler);
    function Call(Req: TIncomingRequest; Resp: TOutgoingResponse): TServiceCall; override;
  end;

  TBlockingCallState = (bcQueued, bcRunning, bcStreaming, bcDone, bcFailed, bcCancelled);
  TBlockingCall = class(TServiceCall)
  public
    State: LongInt;                 { TBlockingCallState, changed with InterlockedCompareExchange }
    Waker: TWaker;                  { the connection task }
    Parker: TThreadParker;          { the worker, for body reads / backpressure }
    RefCount: LongInt;              { loop side + worker side }
    function Poll(var Cx: TContext; Resp: TOutgoingResponse; var Err: THyperError): TCallPoll; override;
    procedure Cancel; override;
  end;
```

Sequence for one blocking request:

1. Loop: `TBlockingService.Call` takes a `TBlockingCall` from a pool, takes one reference on the read
   buffer block that holds the head (section 4.4), and `Submit`s it. `Poll` returns `cpPending` and
   stores `Cx.Waker` (under the call's lock).
2. Worker: runs `Handler.Handle`. Body reads go through `TIncoming.PollFrame` with a `TContext` whose
   waker is the worker's `TThreadParker`; `fpPending` → `Parker.Park`. The receiver's first poll sets
   `want` and wakes the connection task (eventfd if the loop sleeps): the loop then reads the body and,
   for `Expect: 100-continue`, writes the 100 first. This is the same "send 100 when the service first
   polls the body" rule, now crossing a thread.
3. Worker returns: the call stores the response (status, headers, a `TFullBody` holding the string
   reference) and sets `bcDone`, then `Waker.Wake`. Streaming instead: `Resp.Stream.Start` sets
   `bcStreaming` with a `TChannelBody` as the body and wakes the loop; the head goes out at once; each
   `Write` appends to the channel; the worker parks when the channel holds more than its high-water mark
   (default 64 KiB) and is unparked when the loop has taken data (response backpressure).
4. Loop: `PollMsg` → `Poll` sees `bcDone`/`bcStreaming` → `cpReady`. From here the dispatcher does what
   it does for any service.

The connection state never crosses threads: the worker touches only the call object, the body channel
and the response object, each with its own lock or a happens-before edge (the state CAS). One request
costs two cross-thread wakes (submit, completion) plus one per body chunk that has to wait.

### 3.6 Backpressure and cancellation

- **Request body**: single-slot channel with `want` (chan.rs): the dispatcher decodes the next chunk
  only after the receiver took the previous one. A worker that does not read the body stops the socket
  reads after one chunk; TCP flow control does the rest.
- **Response body**: the dispatcher polls the body only while `CanBufferBody` (write buffer below
  `max_buf_size`, queue below 16 buffers, dispatch.rs:384-386). `TChannelBody` adds the worker-side
  high-water mark.
- **Client disconnect**: with `half_close = false` the dispatcher keeps a read pending while the service
  runs (`MidMessageDetectEof`). EOF ends the connection with `incomplete`; dropping the dispatcher calls
  `InFlight.Cancel`:
  - inline call: frees its state, cancels its timers (the conformance call emits `handler_dropped` here);
  - blocking call: CAS to `bcCancelled`; if still queued the worker skips it; if running, the worker sees
    `Cancelled` at its next `Read` / `Write` (they raise `EHttpCancelled`) or when it returns, and its
    result is discarded. A running database query is not interrupted. Ownership of the request and
    response objects (and the block reference) moves to the call, which frees them when the worker is
    done (section 4.4). A Proper controller can test `Req.Cancelled` between steps.

### 3.7 How M5's Proper-like Request/Response sit on it

```
TProperApp = class(THttpService)                      (M5)
  Call(Req, Resp):
    route := Router.Match(Req.Method, path)            loop thread, no allocation for static routes
    if route.Inline then run the action now            hot endpoints written for the loop
    else BlockingService.Call(Req, Resp)               default for controllers

worker thread (TProperJob.Execute):
  current := TProperContext (threadvar, set once per request)
  Request := TProperRequest.Create(BlockingReq)        lazy: path, query (MultiDict), cookies,
                                                       headers view, form (reads the body only
                                                       when accessed: 100-continue stays lazy)
  Response := TProperResponse.Create(BlockingResp)     status, headers (checked), body string,
                                                       send_file -> SetBodyFile, cookies, cache helpers
  pipeline: head_to_get, method_override, match, redirect, copy_session,
            dispatch (before callbacks, action, after callbacks), update_session_cookie
  DB connection per worker thread (Proper: "each thread opens its own database connection")
  on return: Response -> TOutgoingResponse (one string reference moves, no copy)
```

`MAX_THREADS` maps to `TWorkerPool.Threads`; requests beyond that wait in the pool queue, as they wait
for a Granian thread today. Exceptions in controller code are handled by M5's error handling (500
page); an exception that escapes to the call becomes a service error (hyper: no response, connection
closed, outcome `user`).

---

## 4. Memory

### 4.1 Blocks and views (the `Bytes` port)

```pascal
unit bearings.rt.buf;

type
  TBufBlockKind = (bbkPooled, bbkHeap, bbkString, bbkStatic);
  PBufBlock = ^TBufBlock;
  TBufBlock = record                 { bytes::Shared }
    RefCount: LongInt;               { atomic; bbkStatic ignores it }
    Kind: TBufBlockKind;
    Cap: SizeInt;
    OriginalCapacityRepr: Byte;      { bytes original_capacity_repr }
    Pool: TBlockPool;                { bbkPooled }
    Str: Pointer;                    { bbkString: one RawByteString reference }
    Data: PByte;                     { pooled/heap: right after this header }
  end;

  { bytes::Bytes: a slice plus the block that keeps it alive. }
  TBytesView = record
    P: PByte;
    Len: SizeInt;
    Block: PBufBlock;                { nil = static or borrowed memory }
    procedure Release; inline;       { RefCount -1, free at 0 }
    function Clone: TBytesView; inline;
    procedure Advance(N: SizeInt); inline;
  end;

  TBlockPool = class                 { one per loop; size classes 8 KiB .. 1 MiB, power of two }
    function Alloc(Cap: SizeInt): PBufBlock;     { exact capacity requested (see 4.2) }
    procedure Free(B: PBufBlock);                { back to its class list; list length capped }
  end;
```

Blocks larger than the biggest class come from the heap (`bbkHeap`). Freeing is allowed from any thread:
a block freed on a worker goes into the pool's lock-protected return list, drained by the loop.

### 4.2 Read buffer: `TReadBuf` = `BytesMut`

```pascal
type
  TReadBuf = record                  { bytes 1.12.1 BytesMut, the paths hyper uses }
    Block: PBufBlock;
    Off: SizeInt;                    { start of unconsumed data inside Block }
    Len: SizeInt;
    Cap: SizeInt;                    { capacity from Off }
    Shared: Boolean;                 { KIND_ARC after a split; KIND_VEC otherwise }
    function Data: PByte; inline;
    function SpareCapacity: SizeInt; inline;
    procedure Reserve(Additional: SizeInt);   { bytes_mut.rs:626-790 }
    procedure AdvanceMut(N: SizeInt); inline; { after read(2) }
    procedure Advance(N: SizeInt); inline;    { Buf::advance }
    function SplitTo(N: SizeInt): TBytesView; { split_to(n).freeze(): +1 ref, Shared := True }
    function Freeze: TBytesView;              { into_inner for upgrades }
  end;
```

`Reserve` is a port of `reserve_inner`, so the capacities (and therefore the read sizes and the 431
points) are hyper's:

- VEC (never split): if `Cap - Len + Off >= Additional` and `Off >= Len`, move the data to the start of
  the block; else grow like `Vec::reserve`: new capacity `Max(2 * (Cap + Off), Off + Len + Additional)`.
- ARC and unique (`RefCount = 1`): reuse in place if the block has room after `Off`; move to the front if
  the block is big enough and `Off >= Len`; else grow to `Max(2 * BlockCap, Len + Additional + Off)`.
- ARC and not unique (an earlier `SplitTo` view is still alive: a request head or a body chunk in use):
  allocate a new block of `Max(Len + Additional, original_capacity)`, copy the unconsumed bytes, drop
  this buffer's reference to the old block (the views keep it alive). `Shared := False`.

The initial state is hyper's `BytesMut::with_capacity(0)`: no block until the first read, so a
connection that never sends anything costs no buffer.

### 4.3 Write buffer

- Flatten: `TCursorVec.Bytes` (a `TBytes` field of the connection object), initial capacity 8192, grows
  like a `Vec`. `ServerEncode` appends the head directly to it (existing M2 API), body chunks are copied
  after it.
- Queue: head in the cursor, body chunks as `TQueuedBuf` entries holding a `TBytesView` reference (the
  chunk stays valid until written, then the reference is released). `TEncodedBuf` already carries the
  chunk-size prefix inline (M2), so a chunked frame is 3 iovecs and no copy.

### 4.4 Zero-copy slices and their lifetimes

| slice | points into | valid until | mechanism |
|---|---|---|---|
| request method, target, header names/values | read buffer block | `TIncomingRequest.Release` (end of the exchange) or `Detach` | `HeadBytes` holds one block reference; `Headers.ExternalBase = HeadBytes.P` |
| request body chunk (`TIncoming.PollFrame` data) | read buffer block | the consumer's `Release` of that view | the view holds one block reference |
| response body chunk handed to the dispatcher | the body's memory | written to the socket (Queue) or copied (Flatten) | `TBytesView` reference or static memory |
| `TUpgraded.ReadBuf` | read buffer block | its receiver releases it | `Freeze` |

A block reference is an atomic increment on a cache line owned by the loop's core (uncontended, a few
ns). hyper pays the same: `split_to().freeze()` bumps an `Arc` for every head and every body chunk.
When a reference is alive, `Reserve` never moves or frees the block (the not-unique path allocates a new
one), so slices cannot dangle. Debug builds poison freed blocks (0xDD) and check `RefCount > 0` on every
`Clone`/`Release`.

Cancellation of a running blocking call: the call already holds a reference for the head (taken at
submit), and the request and response objects are handed to the call before the connection frees its
own state. Nothing the worker can still touch is freed by the loop.

### 4.5 No refcount traffic or exception frames on the hot path

- `THyperError`, `TBytesView`, `TReadBuf`, `TReadStrategy`, `TConnState` (after M3.0) contain no managed
  fields. Assigning them never calls `fpc_copy`; routines with such locals get no implicit `try/finally`.
- **M3.0 change**: `TEncoder.FTrailerFields: array of RawByteString` and `TDecoder.FTrailerBuf: TBytes`
  make those records managed: every `State.WriteEncoder := Enc` would run RTTI copy code. Both move to a
  per-connection unmanaged scratch (`TTrailerScratch`: name slices in an arena, a byte buffer), referenced
  by pointer. The 506 M2 tests stay the regression check.
- `TResponseHead` contains `TReasonPhrase` (a `RawByteString`): the head lives in the per-connection
  `TOutgoingResponse` and is passed by reference, never assigned.
- Static response bytes (`SetBodyStatic`, `bbkStatic`) skip reference counting completely.
- No threadvars on the hot path: the loop is reached through `Cx.Loop` (date cache, pools, timers).
- Per-request objects (`TIncomingRequest`, `TOutgoingResponse`, the two `THttpHeaders`) are per
  connection and reused; call objects come from per-loop free lists.

### 4.6 Per-connection RSS

| item | size | when |
|---|---|---|
| `TH1ConnTask` + `TH1Connection` (dispatcher, conn, buffered, state by value) | ~1 KiB | always |
| request + response objects, two `THttpHeaders` (16 entries, 1 KiB arena each) | ~3.5 KiB | after the first request |
| read block | 8 KiB (+ header) | from the first read; grows like hyper |
| write head buffer | 8 KiB | hyper allocates it at creation; we allocate at the first response |
| epoll registration | in the stream object | always |

Active connection ≈ 21 KiB, close to hyper (8 KiB `BytesMut` + 8 KiB `Vec` + task and `HeaderMap`).
With `ReleaseIdleBuffers` (open question 4): when the connection is idle (Reading and Writing Init), the
read buffer is empty and nothing is queued, both 8 KiB blocks go back to the loop pool; the read buffer
remembers its capacity so the next `Reserve` asks the pool for the same capacity and the read sizes stay
hyper's. Idle keep-alive connection ≈ 5 KiB.

---

## 5. Header value validation and the trailer deviations

### 5.1 Validation boundary

In hyper, an invalid header cannot exist: `HeaderName::from_bytes` and `HeaderValue::from_bytes`
(bytes ≥ 0x20 except 0x7F, plus HTAB) reject it when the application builds it, and `HeaderMap` only
holds those types. The encoder then copies bytes without checking.

The port puts the check at the same place, the mutators an application uses:

```pascal
{ bearings.http.headers (M3.0 change) }
type
  EInvalidHeader = class(Exception);
  THttpHeaders = class
  public
    { Checked: name must pass IsValidHeaderName, value IsValidHeaderValue; else EInvalidHeader. }
    function Add(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
    procedure Insert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
    procedure SetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt);
    { Same checks, no exception. }
    function TryAdd(...): Boolean;
    function TryInsert(...): Boolean;
    function TrySetValue(...): Boolean;
    { Unchecked, for bytes already validated by the parser / decoder or produced by the library
      itself (AddExternal from ServerParse, ParseTrailers, AddChunked, SetContentLengthIfMissing). }
    function AddTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
    function AddExternal(NameOfs, NameLen, ValueOfs, ValueLen: SizeInt): SizeInt;   { unchanged }
  end;
```

- All `RawByteString` overloads and `TOutgoingResponse.SetHeader/AddHeader` go through the checked path.
  Cost: one byte-class scan per added header, the same work `HeaderValue::from_bytes` does.
- `bearings.http1.decode` (trailer parse) switches its `Dest.Add` to `AddTrusted`; the parser already applied
  httparse's stricter rules.
- `ServerEncode` and `EncodeTrailers` get a debug-build assertion that every name and value they write
  passes the checks, so a missed path shows up in tests.
- The conformance server validates reply headers and trailers at config load with `TryInsert` and exits
  with status 2 on failure, as the reference server does with `HeaderValue::from_bytes`.

### 5.2 Trailer encoding fixes

Deviations found between `encode.rs:167-222` + `role.rs:868-998` and the M2 Pascal code (see assumption 4):

| # | hyper | M2 Pascal | wire effect | fix |
|---|---|---|---|---|
| T1 | `encode_trailers` iterates the trailers `HeaderMap` and appends allowed fields to a new `HeaderMap`; `write_headers` iterates that map: fields come out **grouped by name in order of first appearance** | `EncodeTrailers` writes allowed fields in list order | `a: 1, b: 2, a: 3` is written `a, a, b` by hyper, `a, b, a` by M2 | write grouped: for each name at its first appearance, write all its allowed values (same algorithm `ServerEncode` uses for response headers) |
| T2 | names and values are valid by construction (5.1) | any bytes in the list are written, so CR/LF in a trailer value injects lines into the trailer section | header injection | section 5.1 boundary + debug assertion in `EncodeTrailers` |
| T3 | conn.rs:758-779: a server writes trailers only when the request had `TE: trailers` (`allow_trailer_fields`); when `encode_trailers` returns `None` the writing state stays `Body`, and the dispatcher's next turn calls `end_body`, which writes `0\r\n\r\n` | `EncodeTrailers` returns a fresh `TBytes` and leaves the "nothing written, then end the body" step to its caller; there is no caller yet | without the conn port, trailers would be written for any request, or the chunked body would not be terminated | `TConn.WriteTrailers` ports conn.rs:758-779 exactly (check `AllowTrailerFields`, keep `wrBody` when nothing was encoded); `EncodeTrailers` appends into the write buffer instead of allocating (`procedure EncodeTrailers(T: THttpHeaders; TitleCase: Boolean; var Dst: TCursorVec): Boolean`), and Queue mode pushes a `qkOwned` entry |

Verification: extend `tests/unit/test_codec_diff_rs` with a trailer generator (random names incl.
repeated non-adjacent ones, declared/undeclared, forbidden names, title case) that runs hyper's
`Encoder::encode_trailers` and the Pascal `EncodeTrailers` on the same input and compares bytes; plus the
four `http1_trailer_*` wire cases.

---

## 6. The Pascal conformance server (SPEC.md)

Location: `conformance/pascal-server/` (`wd40_conformance.lpr` + units `cs.spec`, `cs.json`,
`cs.events`, `cs.service`, `cs.body`, `cs.upgrade`, `cs.control`). Binary:
`conformance/target/pascal/wd40-conformance`. It runs **one** `TEventLoop` on the main thread, like the
reference server's current-thread runtime, so event order and timing follow the same model.

### 6.1 Process protocol (SPEC §3)

| SPEC item | implementation |
|---|---|
| `--config <path>`, `--config-json` | `cs.spec` reads the file, parses with fcl-json (`fpjson`); unknown fields, wrong types, values hyper rejects (`max_buf_size < 8192`, `header_read_timeout_ms` number with `timer` false, invalid header name/value, invalid reason bytes, status outside 100..999) → message on stderr, exit 2, no `LISTENING` |
| byte strings | JSON string → code points ≤ U+00FF → bytes; parts arrays (`repeat`, `hex`) as SPEC §2 |
| bind and `LISTENING <port>` | `TTcpListener` on 127.0.0.1:0 with mio's options (§1.3: `SO_REUSEADDR`, backlog 128, no `TCP_NODELAY`); `getsockname`; one `fpWrite` of the line |
| connection numbering | global counter incremented in the accept task, in accept order |
| stdout events | `cs.events.Emit(...)`: builds one line in a buffer and writes it with a single `write(1, ...)`; bytes ≥ 0x80 and control bytes as `\u00XX` |
| stdin commands | fd 0 set non-blocking and registered in the loop's epoll; `TControlTask` splits lines. `graceful_shutdown`: `GracefulShutdown` on every live connection, then the ack; `signal <name>`: set the latch, wake waiters, ack; `exit`: `fpExit(0)`; other: `control_error`; EOF on stdin: exit 0 |
| ordering guarantee of §3.4 / §7 (`bytes_read` then `graceful_shutdown`) | the read, the `bytes_read` event and the buffering happen inside one poll of the connection task; control lines are processed by another task on the same loop, never in the middle of a connection poll |

### 6.2 `config` fields (SPEC §4)

| field | mapping |
|---|---|
| `keep_alive` | `TH1Builder.KeepAlive` → `Conn.DisableKeepAlive` at construction (http1.rs:481) |
| `half_close` | `HalfClose` → `SetAllowHalfClose` |
| `title_case_headers` | `TitleCaseHeaders` → `ServerEncode` params and `EncodeTrailers(TitleCase)` |
| `preserve_header_case` | `PreserveHeaderCase`: accepted; no wire effect (THttpHeaders always keeps request case; no response case map is produced) |
| `max_headers` | `SetHttp1MaxHeaders` → `TH1ParseContext.MaxHeaders` and the trailer count limit of `InitDecoderFor` |
| `max_header_size` | `SetHttp1MaxHeaderSize` → parse check in `TBuffered.Parse` and trailer byte limit |
| `max_buf_size` | `SetMaxBufSize` → `TReadStrategy.WithMax` and `WriteBuf.MaxBufSize` |
| `timer` | `TH1Builder.Timer` (Time::Timer vs Empty) |
| `header_read_timeout_ms` | absent → `dkDefault` 30 s (active only with timer); number → `dkConfigured`; `null` → configured None |
| `writev` | `Writev` tri-state → `SetWriteStrategyQueue/Flatten` |
| `pipeline_flush` | `PipelineFlush` → `SetFlushPipeline` (forces Flatten) |
| `auto_date_header` | `DateHeader` → `DisableDateHeader` |
| `ignore_invalid_headers` | `ParserConfig.IgnoreInvalidHeadersInRequests` |
| `allow_multiple_spaces_in_request_line_delimiters` | `ParserConfig.AllowMultipleSpacesInRequestLineDelimiters` |
| `conn_mode` | `TH1ConnMode` of `ServeConnection` |
| `graceful_shutdown_on_accept` | `Conn.GracefulShutdown` right after `ServeConnection`, before the first poll |
| `bytes_read_events` | the socket is wrapped in `TCountingStream = class(TIoStream)` (the reference's `CountIo`): counts bytes, emits `bytes_read` after each read that returned data, delegates everything else, including `IsWriteVectored` |

### 6.3 Handlers (SPEC §5.1) and the call sequence (§5.5)

All handlers are one `TConformanceService = class(THttpService)` whose `Call` emits `request` (method
token, target as received, version, headers lowercased and grouped by first appearance of each name, as
`HeaderMap` iterates; the CL/TE removal order of `bearings.http1.role` already mimics `HeaderMap::remove`),
assigns `req`, and returns a `TConformanceCall`. `handler_dropped` is emitted by `Cancel` when the call
has not completed (the reference's `DropGuard`); `handler_done` is emitted by `Poll` right before it
returns `cpReady` (result `response`, `status`) or `cpError` (result `error`, `message`).

| handler | `TConformanceCall.Poll` |
|---|---|
| `hello_world` | first poll: `Resp.SetBodyStatic('hello')` (exact hint 5), `cpReady`; never touches the body |
| `unreachable` | first poll: error `request shouldn't be received`, `cpError` |
| `test_service` | state machine below |

`test_service` state machine, field `Step: (stStart, stReadBody, stDelay, stRespond)`:

1. `Call`: emit `request`; take the next reply from the process-wide queue (default `{}` when empty).
   If `upgrade.on_upgrade` is true: `U := TakeUpgrade(Req)` now (step 3 of §5.5).
2. `stReadBody` when `read_body` is true: loop `Req.Body.PollFrame`: `fpData` → append to a buffer,
   release the view; `fpTrailers` → keep the list; `fpPending` → return `cpPending` (the body channel
   woke us); `fpEnd` → emit `request_body` (with `trailers` if any); `fpError` → emit
   `request_body_error` with `kind` from the decode error's io kind (`unexpected_eof`, `invalid_data`,
   `invalid_input`; `io` for errno; `other` for "connection error") and `message` =
   `DecodeErrorMessage`, then `cpError` with `req body error`.
3. Release the request (`Req.Release`: unread body dropped → drain-or-close in the dispatcher).
4. `stDelay`: if `delay_ms > 0`, arm a `TSleep` once, return `cpPending` until it fired.
5. `error` set → `cpError` with that message.
6. `upgrade`: with `on_upgrade`: spawn `TUpgradeTask(U, spec)` (it polls `U`); without: store the spec
   on the connection record for the `without_shutdown` hand-off.
7. Build the response: status; reason (`TReasonPhrase`); version (`HTTP/1.0` → hv10, `HTTP/2.0` → hv2,
   written as HTTP/1.1; `HTTP/0.9` / `HTTP/3.0` → hv09 / hv3, for which `ServerEncode` raises, the task
   aborts like a panicked tokio task: no `conn_close` event, socket closed, as the reference server);
   headers with insert semantics (`SetHeader`); body (6.4). `cpReady`.

### 6.4 Bodies (SPEC §5.4)

| spec | Pascal |
|---|---|
| absent | default `TEmptyBody`, exact 0, `IsEndStream` |
| `{"known": b}` | `TFullBody` over an owned copy; `IsEndStream = (Len = 0)`; exact hint `Len` |
| `{"stream": [...], "trailers": [...]}` | `TScriptBody = class(TOutgoingBody)`, port of the reference `ScriptBody`: items queue; an item with `delay_ms > 0` that has not slept arms a `TSleep` and returns `fpPending`; `data` → `fpData` (one frame per item and per repetition of `times`); `error` → `fpError` with the message (the dispatcher turns it into a user body error, the chunked body stays unterminated); end → `fpTrailers` once if trailers were given, then `fpEnd`. `SizeHint` unknown, `IsEndStream` False |

### 6.5 Connection modes, graceful shutdown, upgrades (SPEC §6)

| item | implementation |
|---|---|
| `plain` | `cmPlain`; on dpUpgrade → `Manual` (upgrade task emits `upgrade_error` "upgrade handled manually") |
| `with_upgrades` | `cmWithUpgrades`; `Fulfill(TUpgraded(Io, ReadBuf))`; the connection result Ok; `conn_close` is emitted by `OnDone` in the same loop turn, before the upgrade task runs, so it precedes `upgraded` |
| `without_shutdown` | `cmWithoutShutdown`; on Ok: `IntoParts`, emit `conn_close`, then if a spec was stored run the upgrade actions on `Parts.Io` with `Parts.ReadBuf`; on error: drop and emit `conn_close` |
| graceful shutdown | `TH1Connection.GracefulShutdown` (Dispatcher.DisableKeepAlive: closes at once when idle or untouched, else `connection: close` on the current response); ignored after an upgrade |
| upgrade task | `TUpgradeTask = class(TTask)`: emit `upgraded` with `read_buf`; wait for the latch (`TSignalLatch` with a waiter list of wakers); write `write` on the raw stream (non-blocking, EPOLLOUT); if `read_to_eof`: read until EOF (first the `ReadBuf` bytes are not re-read: they were already reported), emit `upgrade_read` (`end` `eof` or `error` + message); close. Errors emit `upgrade_error`. Its reads are not counted in `bytes_read` (it uses the inner `TTcpStream`, not the counting wrapper) |

### 6.6 Events (SPEC §7)

| event | emitted by |
|---|---|
| `conn_open` | accept task, before the first poll |
| `request`, `handler_done`, `handler_dropped` | `TConformanceService` / `TConformanceCall` (6.3) |
| `request_body`, `request_body_error` | `test_service` step 2 |
| `conn_close` | `TH1ConnTask.OnDone`: outcome from `THyperError` predicates in SPEC §7.2 order (`IsTimeout`, `IsParseTooLarge`, `IsParseVersionH2`, `IsParse`, `IsIncompleteMessage`, `IsUser`, `IsCanceled`, `IsClosed`, `IsBodyWriteAborted`, `IsShutdown`, errno cause → `io`, else `other`); `detail` = `Description` chain |
| `bytes_read` | `TCountingStream` |
| `upgraded`, `upgrade_read`, `upgrade_error` | `TUpgradeTask` |
| `control_ack`, `control_error` | `TControlTask` |

### 6.7 Running it

```sh
cd /home/jps/Code/wd-40/conformance
target/release/runner run --server target/pascal/wd40-conformance cases/h1
target/release/runner diff --a target/release/reference-server --b target/pascal/wd40-conformance cases/h1
```

A second mode, `wd40-conformance --executor worker`, runs `test_service` through `TBlockingService`
(body reads with `TBodyReader`, delays with `Sleep` on the worker, responses via `TBlockingResponse`;
streamed bodies through `TResponseWriter`). It must give the same results in run and diff mode. This
checks that the worker path keeps hyper's behavior (100-continue only on first body read, cancellation
on client EOF, `handler_dropped` before `conn_close`).

---

## 7. Test plan

### 7.1 Test doubles

`tests/support/bearings.test.mockio.pas`: port of `tokio_test::io::Builder` as a `TIoStream`:

```pascal
type
  TMockIo = class(TIoStream)
  public
    function Read(const Data: RawByteString): TMockIo;    { next read returns these bytes }
    function Write(const Data: RawByteString): TMockIo;   { next write must match these bytes }
    function Wait(Ms: Integer): TMockIo;                  { reads/writes pend for this long }
    function ReadError(Errno: cint): TMockIo;
    function WriteError(Errno: cint): TMockIo;
    function Vectored(Enabled: Boolean): TMockIo;         { IsWriteVectored; default False, as the mock }
    function Build: TMockIo;
    function BuildWithHandle(out H: TMockHandle): TMockIo;  { handle.read() after construction }
    procedure AssertDone;                                  { all scripted actions consumed }
  end;
```

Its `PollWriteVectored` writes only the first non-empty slice when not vectored (Rust's default), which
is what `write_buf_queue_disable_auto` relies on. A `TTestLoop` drives polls deterministically with a
fake clock (`Advance(Ms)`), so timer tests do not sleep.

### 7.2 Port of hyper `io.rs` unit tests (`tests/unit/test_h1_io.pas`)

| hyper test (io.rs) | Pascal test | note |
|---|---|---|
| `iobuf_write_empty_slice` (#[ignore]) | `Test_iobuf_write_empty_slice` | upstream body is commented out; ported as its stated intent: `PollFlush` with nothing buffered makes no write call (mock with no writes) |
| `parse_reads_until_blocked` | `Test_parse_reads_until_blocked` | uses server bytes `GET / HTTP/1.1\r\n` + `Host: x\r\n` + wait (the client role is not ported); asserts `Parse` pending and the read buffer holds both pieces |
| `read_strategy_adaptive_increments` | same name | `usize::MAX` → `High(SizeUInt)` |
| `read_strategy_adaptive_decrements` | same name | |
| `read_strategy_adaptive_stays_the_same` | same name | |
| `read_strategy_adaptive_max_fuzz` | same name | loop `max := (max div 2) * 3` with saturation, up to `High(SizeUInt)` |
| `write_buf_requires_non_empty_bufs` (#[should_panic]) | same name | compiled with `-Sa`; expects `EAssertionFailed` |
| `write_buf_flatten` | same name | one write `hello world, it's hyper!` |
| `write_buf_flatten_partially_flushed` | same name | checks `Pos` and capacity = `INIT_BUFFER_SIZE` and the no-copy rule when over capacity |
| `write_buf_queue_disable_auto` | same name | 4 separate writes with a non-vectored mock |
| (commented-out) `write_buf_queue` | `Test_write_buf_queue` | vectored mock: one writev, queue empty after flush |

Extra tests for code hyper gets from `bytes`: `TReadBuf.Reserve` against a table of capacities produced by
running `BytesMut` itself (a small Rust generator in `tests/unit/test_bytesmut_rs`, same pattern as the
existing diff tools).

### 7.3 conn.rs / dispatch.rs / regression tests (`test_h1_conn.pas`, `test_h1_dispatch.pas`)

conn.rs server tests ported: `conn_reads_request_head`, `conn_reads_partial_request_head`,
`conn_accepts_eof_when_idle`, `conn_rejects_eof_during_partial_head`, `server_accepts_eof_while_busy`,
`conn_reads_body_and_reports_end`, `closed_conn_cannot_read_or_write`, and every other server-side test in
that module (e.g. `conn_writes_chunked_body`). Client-only tests (`client_request_connection_close_disables_keep_alive`,
`client_rejects_eof_while_busy`, `conn_reads_empty_response_before_eof`) are not ported (no client role).

dispatch.rs: its three tests are client-side. `body_empty_chunks_ignored` is ported in server form
(response body yields an empty data frame; assert nothing is written for it and no assertion fires).

hyper integration regression tests, ported as dispatcher tests with `TMockIo` and scripted bodies:
`h1_flush_before_yield.rs` (body: data, pending, end within one loop iteration; the terminating chunk must
be flushed before the poll returns), `h1_shutdown_while_buffered.rs` (shutdown never while bytes are
buffered), `unbuffered_stream.rs` and `ready_on_poll_stream.rs` (server fixture tests). `h1_ready_in_flight.rs`
is client-only.

Own tests for the parts hyper does not have: body channel (port of the `body/incoming.rs` and `chan.rs`
tests: `channel_abort`, `channel_abort_when_buffer_is_full`, `size_hint`, want transitions), timer wheel
(insert/cancel/reset/cascade, rounding equal to tokio's on a table of deadlines), readiness clearing,
`TBlockingCall` state transitions under a stress test (16 threads, random cancel points, run under
valgrind `drd`), block reference counting with poisoning.

### 7.4 Wire cases

- **Assertion mode**: `runner run --server target/pascal/wd40-conformance cases/h1` must print
  `SUMMARY passed=104 failed=0 pending=1 total=105`, 5 runs in a row, and the same with
  `--executor worker`.
- **Diff mode**: `runner diff --a reference-server --b wd40-conformance cases/h1` must give
  `same=104 different=0 pending=1 invalid=0`, 5 runs in a row, also while a CPU stress load runs on all
  cores (finds timing-sensitive differences in `read_once` boundaries).
- Dumb-server control as in MANIFEST.md, to confirm the cases still detect a broken server.

### 7.5 Fuzz and soak

- **Differential stream fuzzer** (Rust, `conformance/fuzz-diff/`, test tooling only): generates request
  streams from a grammar and by mutating the case corpus and httparse's corpus (methods, targets, header
  lines, CL/TE combinations, chunk framing, trailers, pipelined sequences, h2 preface), splits each into
  random write pieces with random 0-5 ms gaps and random half-closes, sends it to the reference server and
  to ours with the same server spec, and compares the full response bytes (date-normalized), the close
  kind (FIN / RST / open) and the event lists (normalized like diff mode). Deterministic seeds; nightly
  100k streams.
- **In-process fuzz**: `TConn` + `TMockIo` with random read splits on random inputs; invariants: no
  exception other than the documented ones, block reference counts return to zero, heaptrc reports no
  leaks.
- **Soak**: 24 h of wrk (keep-alive and pipelined) plus a Rust "chaos client" (partial heads, slow
  bodies, mid-response RST, idle sockets) against the benchmark server with both inline and worker
  endpoints. Pass: RSS stops growing after warm-up, open fd count returns to baseline, no crash, no
  error counter growth beyond the chaos client's own induced errors.
- Debug builds for all tests: `-Ci -Cr -Co -Ct -Sa -gh -gl`; the conformance suite also runs once under
  valgrind memcheck.

### 7.6 Performance measurement

Servers:
- hyper: `vendor/FrameworkBenchmarks/frameworks/Rust/hyper`, dependency set to hyper 1.12.0
  (`cargo update -p hyper --precise 1.12.0`), `--release`, run with `--runtime current-thread --threads N`.
- ours: `tools/bench-server` with `/plaintext` returning the same header set and byte length
  (`server: wd-40` has the same length as `server: hyper`), same builder options (pipeline_flush,
  no timer, NODELAY, backlog 4096, SO_REUSEPORT, N loops), inline service.
- Check before measuring: one request to each, raw bytes compared after date normalization.

Load (wrk from `vendor/wrk`, TFB's `pipeline.lua`):

```sh
wrk -t$T -c256  -d30s --latency http://127.0.0.1:8080/plaintext
wrk -t$T -c1024 -d30s --latency http://127.0.0.1:8080/plaintext
wrk -t$T -c256  -d30s --latency -s pipeline.lua http://127.0.0.1:8080/plaintext -- 16
wrk -t$T -c1024 -d30s --latency -s pipeline.lua http://127.0.0.1:8080/plaintext -- 16
```

Method: CPU governor `performance`, same kernel and sysctls (`somaxconn`, `ulimit -n 65536`) for both;
with one machine, server on CPUs 0-11 (N = 12), wrk on 12-15 (`taskset`, T = 4), identical for both
servers; 10 s warm-up discarded; 5 runs per configuration, alternating servers; report the median.
Record requests/s, p50 and p99 (wrk `--latency`), CPU% (pidstat), RSS sampled every second from
`/proc/<pid>/status` (max VmRSS and VmHWM), syscalls per request (`perf stat -e 'syscalls:sys_enter_*'`
over 10 s). Also wrk2 at fixed rates of 50 % and 80 % of hyper's measured maximum for p99 without
coordinated omission. Profile both with `perf record -g` when a target is missed.

Targets: ≥ 80 % of hyper's requests/s in each of the 4 configurations (given); p99 and RSS per open
question 1.

Expected syscall pattern (both servers): non-pipelined, one `read` + one `write` per request plus amortized
`epoll_wait`; pipelined 16, one `read` for the batch and one `write` for 16 flattened responses
(pipeline_flush). The short-read readiness rule (§1.4) avoids an `EAGAIN` read after each batch.

---

## 8. Layout, milestones, risks

### 8.1 Files under `/home/jps/Code/wd-40/src/`

```
src/rt/
  bearings.rt.sys.pas        syscall numbers and wrappers (epoll_create1/ctl/pwait, accept4, eventfd2, writev,
                       sendfile, shutdown, sched_get/setaffinity, futex, signalfd), constants, CPU count
  bearings.rt.clock.pas      libc clock_gettime (vDSO)
  bearings.rt.task.pas       TPoll, TPollResult, TWaker, TContext, TTask, TThreadParker
  bearings.rt.timer.pas      TTimerWheel, TTimerEntry, TSleep
  bearings.rt.buf.pas        TBufBlock, TBytesView, TBlockPool, TReadBuf
  bearings.rt.loop.pas       TEventLoop, TInbox, run loop
  bearings.rt.net.pas        TIoRegistration, TIoStream, TTcpStream, TTcpListener, TAcceptTask
  bearings.rt.runtime.pas    TRuntime (loops, threads, pinning, shutdown fan-out, signals)
src/http/
  bearings.http.error.pas    THyperError
  bearings.http.body.pas     TOutgoingBody (+ Empty, Full, File, Channel), TIncoming, TBodyChan/Sender/Receiver
  bearings.http.service.pas  TIncomingRequest, TOutgoingResponse, THttpService, TServiceCall
  bearings.http.upgrade.pas  TOnUpgrade, TUpgraded, TakeUpgrade, TUpgradeTask
  bearings.http.blocking.pas TWorkerPool, TJob, TBlockingService, TBlockingCall, TBodyReader, TResponseWriter
src/http1/             (existing M2 units stay here unchanged except the M3.0 changes)
  bearings.http1.io.pas      TBuffered, TReadStrategy, TWriteBuf, TCursorVec, TBufList
  bearings.http1.conn.pas    TConn, TConnState
  bearings.http1.dispatch.pas TDispatcher, TServerDispatch
  bearings.http1.server.pas  TH1Builder, TH1Connection, TH1Parts, TH1ConnTask
src/server/
  bearings.server.pas        THttpServer (runtime + listeners + builder + service factory)
tests/unit/            test_h1_io, test_h1_conn, test_h1_dispatch, test_rt_timer, test_rt_buf,
                       test_rt_loop, test_body_chan, test_blocking, test_bytesmut_rs/ (Rust generator)
tests/support/         bearings.test.mockio.pas, bearings.test.loop.pas
conformance/pascal-server/   (section 6)
tools/bench-server/    benchmark server
```

Moving the existing `bearings.http.*` units from `src/http1/` to `src/http/` is optional and not part of M3.

### 8.2 Implementation order (each step has a check that can be run)

| step | content | verified by |
|---|---|---|
| M3.0 | unmanaged `TEncoder`/`TDecoder` (trailer scratch), header validation boundary (5.1), trailer fixes T1-T3 at unit level, `bearings.http.error` | 506 M2 tests + diff tests pass; new trailer diff generator vs hyper; tests that invalid names/values raise |
| M3.1 | `bearings.rt.*`: syscalls, clock, timer wheel, tasks, loop, TCP stream/listener, CPU count | unit tests (timer table vs tokio rounding; CPU count = `nproc`; readiness rules with a socketpair); an echo server passes a 1 GB transfer with random splits |
| M3.2 | `bearings.rt.buf` + `bearings.http1.io` | the 11 io tests (7.2); `TReadBuf` capacity table vs `BytesMut` |
| M3.3 | `bearings.http.body` (chan) + `bearings.http1.conn` | conn.rs server tests; chan tests |
| M3.4 | `bearings.http1.dispatch`, `bearings.http1.server`, `bearings.http.service`, `bearings.http.upgrade` | dispatcher tests + ported regression tests (7.3) |
| M3.5 | conformance server | 104/105 run mode ×5; diff mode same=104 ×5 incl. under CPU stress |
| M3.6 | multi-loop runtime, `THttpServer`, bench server, hyper baseline build | the perf method of 7.6; targets met in all 4 configurations |
| M3.7 | worker pool, `TBlockingService`, `TChannelBody`, `TFileBody` (sendfile) | blocking tests; conformance `--executor worker` 104/105 and diff same=104; soak 24 h; fuzz-diff nightly clean |

M3.5 is the first point where hyper parity on the wire is measured end to end; M3.6 the first perf
number. If the perf gap is large at M3.6, profiling happens before M3.7 starts.

### 8.3 Risks and mitigations

| risk | effect | mitigation |
|---|---|---|
| A port mistake in the order of poll operations (e.g. flush vs read) | wrong wire behavior in rare interleavings | method-by-method port with line references; dispatcher tests from hyper's regression files; diff mode; fuzz-diff with random splits and gaps |
| Scheduling differences from tokio change `read_once` boundaries | diff-mode failures that are not protocol bugs | copy tokio's readiness clearing, event interval, yield deferral and timer rounding; cases already mark batching-dependent reads `diff_capture: false`; run diff under load to find the remaining ones early |
| Use-after-free of zero-copy slices | memory corruption | block references for every slice handed out (4.4), poisoning and refcount checks in debug builds, heaptrc, valgrind |
| Races in the worker path | rare corruption or hangs | connection state never crosses threads; only call/channel objects are shared, each with one lock or CAS; stress tests under valgrind drd; `--executor worker` conformance run |
| FPC codegen slower than rustc for parse/encode | throughput below 80 % | hot paths without managed types or exception frames (4.5); SIMD scanners in inline asm (parser unit contract already prepared); compare instructions per request with perf; syscalls dominate per-request cost, so the parse/encode share is bounded |
| `SO_REUSEPORT` hashing imbalance at 256 connections over many loops | lower throughput, higher p99 | same strategy as hyper, so the comparison is fair; CBPF steering is a later option |
| Load generator on the same machine | noisy, biased numbers | identical pinning for both servers, alternating runs, medians of 5; a second machine if available |
| tokio's per-task cooperative budget is not ported | a very busy connection could delay others more than in tokio | hyper's own 16-iteration limit plus yield bounds work per poll; accept loop limited to 128 per poll; measure p99 under mixed load |
| Exceptions escaping application code on the loop | loop thread dies | each task poll runs in `try/except`; the task is aborted and its socket closed (DV-10) |
| Memory growth from pools | RSS above hyper's | capped pool lists; idle buffer release; RSS sampled in every perf run and in the soak |

---

## Appendix A. Deviations from hyper's structure, with reasons

| id | hyper | this design | reason |
|---|---|---|---|
| DV-1 | `async`/`Future`, `Context`, `Waker` | poll methods with explicit state fields; `TContext`, `TWaker` (task handle or thread parker) | FPC 3.2.2 has no closures, no async; hyper's protocol code is already hand-written poll code, so the shape carries over |
| DV-2 | generic `I`, `B`, `T`, monomorphized | `TIoStream` and `TOutgoingBody` are classes with virtual methods; the server role is hard-wired | FPC generics with these constraints are clumsy; a virtual call costs ~2 ns per syscall-sized operation (< 1 % of a `read(2)`); client role is out of scope |
| DV-3 | `bytes::Bytes` / `BytesMut` | `TBufBlock` + `TBytesView` + `TReadBuf` (port of `reserve_inner`) | same ownership semantics and capacities without a Rust runtime |
| DV-4 | `HeaderMap`, `cached_headers` holds the drained response map | `THttpHeaders` (M2: list in wire order with external slices); one reused list for requests, one for responses | M2 decision; wire output already matches `HeaderMap` order (role port) |
| DV-5 | `BufList<EncodedBuf<B>>` | `TBufList` of `TQueuedBuf` with an owning `TBytesView` | Pascal needs explicit ownership of queued chunks |
| DV-6 | buffers kept for the connection's life | optional return of idle 8 KiB blocks to a per-loop pool, capacity remembered | RSS; no wire effect |
| DV-7 | tokio scheduler, mio, tokio timer | `TEventLoop` copying the current-thread scheduler rules, mio's epoll flags and readiness bits, tokio's wheel and rounding; coop budget not ported (accept capped at 128) | tokio is not available; copying its rules keeps timing and syscall behavior close |
| DV-8 | `body::chan` with `AtomicWaker` | same states with a mutex and `TWaker` that can be a thread parker | lets a blocking worker be the receiver |
| DV-9 | none (users call `spawn_blocking`) | `TBlockingService` + `TWorkerPool` | synchronous Proper controllers; behind the same poll interface |
| DV-10 | a panic aborts the tokio task | an exception in a task poll aborts the task: drop, close, no completion callback | same observable result (the conformance server relies on it for invalid response versions) |
| DV-11 | header validity by type construction | checks in `THttpHeaders` mutators, unchecked `AddTrusted` / `AddExternal` for library paths | Pascal has no newtype-checked byte types without allocation |
| DV-12 | `Upgraded` = `Rewind<Box<dyn Io>>` | `TUpgraded` = stream + `ReadBuf` view; the receiver consumes `ReadBuf` first | no trait objects needed; same data |
| DV-13 | thread-local date cache checked per dispatcher poll | per-loop `TDateCache` checked per dispatcher poll | threadvars are slow on x86_64-linux FPC |
| DV-14 | no file bodies | `TFileBody` + `qkFile` + `sendfile(2)`; with Flatten the head is written first with `MSG_MORE` | Proper's `send_file`; the bytes on the wire equal a `Full` body with the file content |
| DV-15 | the TFB accept loop ends the runtime on an accept error | log and retry on `EMFILE`/`ENFILE` | a production server must survive fd exhaustion; not part of hyper itself |

## Appendix B. hyper → Pascal map (quick reference)

| hyper | Pascal |
|---|---|
| `Buffered::parse` | `TBuffered.Parse` |
| `Buffered::poll_read_from_io` | `TBuffered.PollReadFromIo` |
| `Buffered::poll_flush` / `poll_flush_flattened` | `TBuffered.PollFlush` / `PollFlushFlattened` |
| `ReadStrategy::record` | `TReadStrategy.Record_` |
| `WriteBuf::buffer` / `can_buffer` | `TWriteBuf.Buffer` / `CanBuffer` |
| `Conn::poll_read_head` | `TConn.PollReadHead` |
| `Conn::poll_read_body` | `TConn.PollReadBody` |
| `Conn::poll_read_keep_alive` / `mid_message_detect_eof` | `TConn.PollReadKeepAlive` / `MidMessageDetectEof` |
| `Conn::maybe_notify` / `wants_read_again` | `TConn.MaybeNotify` / `WantsReadAgain` |
| `Conn::write_head` / `encode_head` / `enforce_version` / `fix_keep_alive` | same names |
| `Conn::write_body` / `write_body_and_end` / `write_trailers` / `end_body` | same names |
| `Conn::on_parse_error` / `poll_drain_or_close_read` / `disable_keep_alive` | same names |
| `State::try_keep_alive` / `idle` / `busy` / `close*` | `TConnState` methods |
| `Dispatcher::poll_catch` / `poll_inner` / `poll_loop` / `poll_read` / `poll_write` / `poll_flush` | `TDispatcher` methods |
| `Server::poll_msg` / `recv_msg` / `poll_ready` / `should_poll` | `TServerDispatch` methods |
| `Builder::serve_connection` | `TH1Builder.ServeConnection` |
| `Connection::graceful_shutdown` / `into_parts` / `without_shutdown` / `with_upgrades` | `TH1Connection.GracefulShutdown` / `IntoParts` / `cmWithoutShutdown` / `cmWithUpgrades` |
| `upgrade::on` / `Pending::fulfill` / `Pending::manual` | `TakeUpgrade` / `TOnUpgrade.Fulfill` / `Manual` |
| `Sender::poll_ready` / `try_send_data` / `send_error` | `TBodySender.PollReady` / `TrySendData` / `SendError` |
| `Receiver::poll_next` / `take_trailers` | `TBodyReceiver.PollNext` / `TakeTrailers` |
| `Time::check` | `TH1Builder.CheckHeaderReadTimeout` |
| `date::update` / `date::extend` | `TDateCache.Check` / `ServerEncode(P.Date)` |
