# M3 design (candidate "api"): transport and service API, application-API first

> Written while this code was part of wd-40 (where "wd-40" in the text means the project of that time). The unit names were changed to `bearings.*` when the transport moved to this repository; commit hashes refer to the wd-40 history.

Status: candidate design for milestone M3. Angle: start from what the M5 Proper-like layer needs,
then shape the transport so that layer is natural to write in FPC 3.2.2 (no closures), while the
HTTP/1 engine stays a literal port of hyper 1.12.0 (rev 7f67699) and meets the performance target.

Inputs read for this design: hyper `src/proto/h1/{conn,dispatch,io}.rs`, `src/server/conn/http1.rs`,
`src/body/{chan,incoming}.rs`, `src/upgrade.rs` call sites; the interface sections of every unit in
`src/http1/`; `conformance/SPEC.md`, the 105 case files, `reference-server/src/main.rs`;
`docs/research/{hyper-features,hyper-test-catalog,library-survey}.md`; Proper's `api.md`, `app.md`
(Request Lifecycle, hooks, serving), `controllers.md`, `security.md` (body limits), `forms.md`/`storage.md`
(uploads); hyper's TechEmpower entry (`FrameworkBenchmarks/frameworks/Rust/hyper/src/main.rs`).

---

## 0. Summary

| decision | choice |
|---|---|
| loops | one epoll loop thread per CPU in the process affinity mask (`sched_getaffinity`, popcount), optional pinning |
| accept | `SO_REUSEPORT`, one listener per loop (hyper TFB layout). Option: one shared listener registered `EPOLLEXCLUSIVE` in every loop |
| epoll | edge-triggered for connections (`EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET`, registered once, never modified); level-triggered for listeners and the wake eventfd |
| wakeups | per-loop intrusive MPSC inbox + `eventfd`, written only when the loop is (or may be) asleep |
| timers | per-loop hierarchical timer wheel, 1 ms tick, intrusive nodes, lazy deadline extension (header-read/keep-alive reset is one store) |
| clock | `clock_gettime` from libc (vDSO, 11 ns) once per loop iteration; `CLOCK_MONOTONIC` for timers, `CLOCK_REALTIME` for the Date cache |
| HTTP/1 engine | literal port of `Conn` + `State` (`bearings.http1.conn`), `Dispatcher` + server `Dispatch` (`bearings.http1.dispatch`), `Buffered` + `ReadStrategy` + `WriteBuf` (`bearings.http1.io`), using the M2 units unchanged except for the fixes in section 5 |
| service API | one protocol-neutral object per request, `TExchange`. The service's `Dispatch(X)` runs on the loop thread; it either answers inline or calls `X.Offload(Handler)` to run `Handler.Execute(X)` on a worker thread. No closures: callbacks are virtual methods of handler/listener classes |
| blocking code | Proper-style synchronous controllers (DB calls) run on a worker pool (default `min(32, cpus+4)`, Proper's `MAX_THREADS` rule). Blocking body reads and stream writes park the worker on a futex; the loop never blocks |
| request body | hyper's single-slot channel (`body/chan.rs`): `want` starts false only for `Expect: 100-continue`; the first body read sets it, which is when `100 Continue` is buffered |
| response body | `TBody` abstract class = `http_body::Body` (`PollFrame`, `IsEndStream`, `SizeHint`). Built-ins: empty, static/copied/referenced bytes, file (sendfile), thread-safe stream ring, custom loop-side sources |
| memory | per-loop pools of buffer blocks in power-of-two size classes; request head and lent body slices are zero-copy slices into a pinned read block; pins are counted on the loop thread only (no atomics) |
| strings | no managed types (AnsiString, dynamic arrays, interfaces) in locals or parameters of hot routines; `PByte`+length slices everywhere in the transport; M5 objects may use AnsiString |
| header validation | `THttpHeaders` mutators validate names (token) and values (HTAB / 0x20..0x7E / 0x80..0xFF) like `http::HeaderName/HeaderValue`; `*Unchecked` variants for already-validated bytes; debug assertion in the encoders |
| HTTP/2 room | `TExchange` and `TBody` do not know the protocol. A connection holds a `TProtoDriver` (`TH1Dispatcher` now, `TH2Session` over libnghttp2 later); `cpAuto` sniffs the 24-byte preface like hyper-util |
| conformance server | `conformance/pascal-server/wdconf.pas`: one loop, test_service as an inline state machine (delays are loop timers, so cancel/drop ordering matches hyper's future drop); `--exec worker` variant runs it on the worker pool |

### Assumptions (stated explicitly; correct me where wrong)

1. Linux x86_64 only, kernel >= 5.10 (the box runs 7.0). No portability layer.
2. One process. Several processes on the same port (Proper's `PROCESSES`) work unchanged through `SO_REUSEPORT`.
3. The perf comparison uses hyper's TFB configuration including `pipeline_flush(true)` and no timer (that is what `main.rs` does). Our benchmark server uses the same options; production defaults stay hyper's defaults.
4. M5 controllers run on workers by default. Inline (loop-thread) handlers are for code that never blocks: benchmarks, health checks, static files already open, WebSocket frame handling.
5. WebSockets: Proper serves them from a separate cable process (proper-wse). This design supports in-process WebSockets through the upgrade API; whether M5 uses it is an M5 decision.
6. "p99 latency and RSS" have no numeric target in the brief. I propose: p99 <= 1.25 x hyper's p99 in the non-pipelined runs, and RSS at 1024 connections <= hyper's. These are proposals to confirm.

### Open questions

1. The brief says the M2 trailer encoder "deviates from role.rs in 3 ways". I did not find that list written down anywhere in the repo or scratchpad. Section 5.2 lists the deviations I found by reading `bearings.http1.encode.pas`/`bearings.http1.role.pas` against `encode.rs`/`role.rs`/`conn.rs`; please reconcile with the list M2 produced.
2. Should the transport enforce a default request-body limit? hyper has none (the service must). Proper enforces `MAX_CONTENT_LENGTH` (8 MB, 413). This design leaves it to M5 and gives the transport only the mechanism (`ContentLength` before reading, byte counting while reading).
3. Is a 30 s header-read timeout acceptable as the production default? hyper applies it only when a timer is configured; we always have a timer.

---

## 1. Threading and reactor

### 1.1 Threads

```
main thread ─ parses config, binds, starts loops and workers, then waits in sigwait()
              (SIGINT/SIGTERM blocked in every thread before any thread is created)
loop[0..N-1] ─ one per CPU of the affinity mask; owns: epoll fd, listener (REUSEPORT),
               eventfd, MPSC inbox, timer wheel, block pools, exchange pool, date cache,
               every connection it accepted (a connection never migrates)
worker[0..W-1] ─ run TWorkerHandler.Execute (blocking application code); W = 0 disables
```

`N` comes from `sched_getaffinity(0)` (syscall 204), not from `GetCPUCount` (a stub returning 1 in
FPC 3.2.2). It is then capped by the cgroup v2 quota if one is set (`/sys/fs/cgroup/cpu.max`,
`ceil(quota/period)`), because a container limited to 4 CPUs on a 16-CPU host must not start 16 loops.

```pascal
unit wd.sys.cpu;
function AffinityCpus(var Cpus: array of LongInt): LongInt; { CPU ids in the mask; returns count }
function AffinityCpuCount: LongInt;                         { popcount of sched_getaffinity(0) }
function CgroupCpuLimit: LongInt;                           { ceil(quota/period) or 0 = unlimited }
function DefaultLoopCount: LongInt;                         { max(1, min(affinity, cgroup limit)) }
function PinCurrentThread(Cpu: LongInt): Boolean;           { sched_setaffinity(0, {Cpu}) }
```

Pinning is optional (`TServerOptions.PinLoops`, default False). hyper's TFB entry does not pin; the
perf comparison runs both servers unpinned, and once more both pinned.

### 1.2 Accept

- Default `amReusePort`: each loop creates its own socket with `SO_REUSEADDR`, `SO_REUSEPORT`,
  `TCP_NODELAY` (inherited by accepted sockets on Linux, same as hyper TFB's listener), backlog 4096,
  binds the same address, listens, and registers it level-triggered `EPOLLIN`. The kernel hashes
  the 4-tuple to one listener. Port 0: the first loop binds port 0, reads the port with
  `getsockname`, the others bind that port.
- Option `amSharedExclusive`: one listener, added to every loop's epoll with `EPOLLIN|EPOLLEXCLUSIVE`
  (one loop woken per connection). Better balance when loops are unevenly loaded; one more cache
  line shared between loops.
- Accept in a batch of at most 64 `accept4(SOCK_NONBLOCK|SOCK_CLOEXEC)` calls per wakeup, then return
  to other events (fairness).
- Each accepted socket gets a connection id from a global `InterlockedIncrement64` counter (SPEC 3.2
  numbers connections in accept order; with one loop the order is exact).

### 1.3 epoll mode

Connections are registered once at accept with `EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET` and the
`TPollable` pointer in `data`. There is never an `epoll_ctl(MOD)` per request: backpressure is
expressed by not calling `read`/`write`, not by changing interest.

Readiness is tracked in two flags in the socket object:

- `ReadReady` set by an event carrying `EPOLLIN|EPOLLRDHUP|EPOLLHUP|EPOLLERR`; cleared when `read`
  returns `EAGAIN`, or returns fewer bytes than requested (see risk R3 for why this is safe on Linux
  TCP and how it is tested).
- `WriteReady` set by `EPOLLOUT|EPOLLHUP|EPOLLERR`; cleared on `EAGAIN` or a short write.

`TTcpIo.Read` returns `-EAGAIN` without a syscall when `ReadReady` is false. In the hyper port,
`-EAGAIN` is `Poll::Pending` and the epoll event is the waker. This gives hyper's "read until
blocked" behaviour (io.rs `parse_reads_until_blocked`) with no wasted syscalls.

### 1.4 Wakeups between threads

```pascal
unit wd.sys.sync;
type
  TLoopWork = class                    { anything a non-loop thread hands to a loop }
  private
    FNextWork: TLoopWork;              { intrusive MPSC link }
    FQueued: LongInt;                  { 1 while in an inbox: repeated posts coalesce }
  public
    procedure RunOnLoop; virtual; abstract;   { loop thread }
  end;

  TMpscQueue = record                  { Vyukov intrusive MPSC, stub node, no allocation }
    procedure Init;
    procedure Push(W: TLoopWork);      { any thread; InterlockedExchange on the tail }
    function Pop: TLoopWork;           { loop thread only; nil when empty }
  end;

  TParker = record                     { one waiter, futex-based (syscall 202) }
    State: LongInt;
    procedure Park(TimeoutMs: LongInt = -1);
    procedure Unpark;
  end;

function AtomicOr(var Target: LongWord; Bits: LongWord): LongWord;   { CAS loop; returns old }
```

Post protocol (no syscall while the loop is awake):

```
producer:  if InterlockedExchange(W.FQueued, 1) = 0 then Inbox.Push(W);
           if InterlockedExchange(Loop.FSleeping, 0) = 1 then write(eventfd, 1)
loop:      FSleeping := 1 (InterlockedExchange); if Inbox not empty or deferred work
           then FSleeping := 0, timeout 0; epoll_wait(...); FSleeping := 0
           on eventfd readable: read it (counter reset)
           RunOnLoop: FQueued := 0 BEFORE reading the work's state, so a post that races
           with the run queues it again
```

### 1.5 Loop iteration

```pascal
unit bearings.rt.loop;
type
  TPollable = class
  protected
    FFd: cint;
    FLoop: TLoop;
  public
    procedure HandleEvents(Events: LongWord); virtual; abstract;   { loop thread }
  end;

  TDeferred = class                     { "yield": run after the current batch }
  private
    FNextDeferred: TDeferred;
    FDeferred: Boolean;
  public
    procedure RunDeferred; virtual; abstract;
  end;

  TLoop = class
  public
    constructor Create(AIndex: LongInt; const Opts: TServerOptions; AServer: TObject);
    procedure Run;                                   { thread body }
    procedure Post(W: TLoopWork);                    { any thread }
    procedure Defer(D: TDeferred);                   { loop thread; idempotent }
    procedure Register(P: TPollable; Events: LongWord);
    procedure Unregister(P: TPollable);
    function InLoopThread: Boolean; inline;
    property Index: LongInt read FIndex;
    property NowMs: Int64 read FNowMs;               { sampled once per iteration }
    property Timers: TTimerWheel read FTimers;
    property Date: PByte read GetDateBytes;          { 29 bytes, this loop's TDateCache }
    property Blocks: TBlockPool read FBlocks;
    property Exchanges: TExchangePool read FExchanges;
  end;
```

One iteration:

1. `FNowMs := MonoMs`; `FDate.Check(RealUs)` only when `FNowMs` passed the cached next-second mark
   (one compare per iteration; hyper checks once per dispatcher poll, `dispatch.rs` `update_date`).
2. Drain the inbox (`RunOnLoop` for each). Commands such as graceful shutdown are applied here,
   before any socket is read in this iteration (SPEC 3.4/7 ordering).
3. Run deferred items (connections that used their 16-iteration budget, `dispatch.rs` `poll_loop`).
4. `Timers.Advance(FNowMs)`.
5. `epoll_wait(maxevents = 256, timeout)`, timeout = 0 if inbox or deferred list is non-empty, else
   `min(Timers.NextDue - Now, 1000)`, else -1 when no timers.
6. Dispatch each event to `TPollable.HandleEvents`.

### 1.6 Timers

```pascal
unit bearings.rt.timer;
type
  TTimerTarget = class
  public
    procedure TimerFired(Tag: PtrInt); virtual; abstract;   { loop thread }
  end;

  PTimerNode = ^TTimerNode;
  TTimerNode = record                 { embedded in its owner; no allocation }
    Deadline: Int64;                  { ms the owner wants }
    Due: Int64;                       { ms of the slot it is filed in; 0 = not armed }
    Next, Prev: PTimerNode;
    Target: TTimerTarget;
    Tag: PtrInt;
  end;

  TTimerWheel = class                 { 6 levels x 64 slots, 1 ms resolution (tokio layout) }
  public
    constructor Create(NowMs: Int64);
    procedure Arm(N: PTimerNode; DeadlineMs: Int64);
    { Lazy reset: if N is armed and DeadlineMs >= N^.Due, only stores Deadline.
      On expiry, a node whose Deadline > Due is refiled instead of fired. }
    procedure Extend(N: PTimerNode; DeadlineMs: Int64); inline;
    procedure Cancel(N: PTimerNode);
    procedure Advance(NowMs: Int64);  { fires every node with Deadline <= NowMs }
    function NextDue: Int64;          { High(Int64) when empty }
  end;
```

Uses:

| timer | owner | semantics |
|---|---|---|
| header read timeout | `TH1Conn` | armed when `poll_read_head` starts waiting (`conn.rs` 223-243); fires `Drive`; `PollReadHead` checks `Now >= deadline` after a `Pending` parse (conn.rs 270-283). Doubles as keep-alive idle timeout exactly as in hyper |
| application delays | `TExchange` (`X.SetTimer`) | inline handlers; conformance `delay_ms` and stream item delays |
| graceful shutdown deadline | `TLoop` | force-close remaining connections |
| stall detector (debug builds) | `TH1Conn` | reports a connection that is not idle and got no wake for 60 s (catches lost-wakeup bugs, risk R2) |

Lazy extension matters for keep-alive with a header timeout: re-arming per request would be a
list unlink + relink; `Extend` is one store. hyper's TFB entry runs without a timer; our benchmark
server does the same, but the production default (30 s) costs only the store.

### 1.7 Clock

```pascal
unit wd.sys.clock;
function clock_gettime(Clk: LongInt; Tp: Pointer): LongInt; cdecl; external 'c';
function MonoMs: Int64; inline;    { CLOCK_MONOTONIC }
function MonoNs: Int64; inline;
function RealUs: Int64; inline;    { CLOCK_REALTIME, for the Date header }
```

FPC's own `clock_gettime` and `GetTickCount64` are real syscalls (89.5 ns measured); libc's goes
through the vDSO (11 ns). The loop reads the clock once per iteration; nothing on the request path
reads it.

### 1.8 Graceful shutdown

Per connection (hyper `Connection::graceful_shutdown` -> `Dispatcher::disable_keep_alive`):
`TH1Dispatcher.GracefulShutdown` = `Conn.DisableKeepAlive` (idle -> close now, else disable) and
`Close` if write is closed or `HasInitialReadWriteState`. No effect after an upgrade hand-off.

Server:

```pascal
unit bearings.rt.server;
type
  TServer = class
  public
    constructor Create(const Opts: TServerOptions; AService: THttpService);
    procedure Start;                            { bind, start loops and workers; returns }
    procedure Wait;                             { until every loop has exited }
    { Stop accepting; graceful shutdown on every connection; after GraceMs force-close;
      then stop workers (in-flight handlers finish; their responses are dropped if the
      connection is gone). Any thread. }
    procedure Shutdown(GraceMs: Int64);
    { Graceful shutdown of the connections open now; listeners keep accepting. Done
      is posted to the caller's TLoopWork after every loop applied it (SPEC 3.4 ack). }
    procedure GracefulShutdownOpenConnections(Done: TShutdownAck);
    function Port: Word;
  end;
```

`Shutdown` closes listeners first. With `SO_REUSEPORT`, closing one listener resets the connections
still in its accept queue, so each loop first drains its queue (`accept4` until `EAGAIN`) and only
then closes the listener; connections accepted in that drain are served with keep-alive disabled.
SIGTERM/SIGINT are taken with `sigwait` on the main thread, which calls `Shutdown`.

---

## 2. Connection state machine: port plan

### 2.1 Layering

```
TTcpConn (TPollable)     socket fd, ET flags, conn id, peer address, owning loop
  └─ Io: TConnIo          TTcpIo (plain socket) | TTlsIo (later) | TMockIo (tests)
  └─ Proto: TProtoDriver  TH1Dispatcher | TH2Session (later) | TProtoSniffer (cpAuto)
TH1Dispatcher            dispatch.rs Dispatcher<Server, ..>  + server Dispatch impl
  └─ Conn: TH1Conn         conn.rs Conn + State
       └─ Io: TH1Io          io.rs Buffered (read buffer, ReadStrategy, WriteBuf)
```

```pascal
unit bearings.rt.net;
type
  TConnIo = class                    { hyper rt::Read + rt::Write for one connection }
  public
    { > 0 bytes; 0 EOF; < 0 = -errno, -EAGAIN = would block (Poll::Pending) }
    function Read(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    function WriteV(Iov: PIoSlice; Count: LongInt): SizeInt; virtual; abstract;
    { -ENOSYS when unsupported (TLS): the caller falls back to pread + Write }
    function SendFile(InFd: cint; var Offset: Int64; Len: SizeInt): SizeInt; virtual;
    function IsWriteVectored: Boolean; virtual;      { TTcpIo True, TTlsIo False }
    function ShutdownWrite: SizeInt; virtual; abstract;
    procedure Close; virtual; abstract;
  end;

  TProtoDriver = class
  public
    procedure Drive; virtual; abstract;              { run the protocol until Pending }
    procedure GracefulShutdown; virtual; abstract;
    procedure Abort; virtual; abstract;              { loop shutdown deadline }
  end;
```

`TIoSlice` is the M2 type in `bearings.http1.encode` (same layout as `struct iovec`).

### 2.2 hyper function -> Pascal method

All names below are methods of the Pascal classes; every one is a line-by-line port unless the
note says otherwise. `Poll<T>` becomes `TPoll = (pReady, pPending, pErr)` with the error stored in
`FError: TH1Error` (no exceptions on the hot path); `ready!(x)?` becomes
`R := X; if R <> pReady then Exit(R)`.

**bearings.http1.io (io.rs, 654 lines)**

| hyper | Pascal | note |
|---|---|---|
| `ReadStrategy::{with_max,next,max,record}`, `incr/prev_power_of_two` | `TReadStrategy` record: `InitWithMax`, `NextSize`, `MaxSize`, `Record` | exact port; io.rs tests 3-6 |
| `Buffered::new` | `TH1Io.Create(Io: TConnIo; Loop: TLoop)` | Queue if `Io.IsWriteVectored` else Flatten |
| `set_flush_pipeline`, `set_max_buf_size`, `set_write_strategy_*` | same names | `max < 8192` raises `EArgumentException` (hyper asserts) |
| `read_buf`, `consume_leading_lines` | `ReadBufPtr/ReadBufLen`, `ConsumeLeadingLines` | |
| `parse` | `ParseHead(const Ctx: TH1ParseContext; Headers: THttpHeaders; out Msg: TParsedRequestHead): TPoll` | calls M2 `ServerParseHeaders` with `PrevLen = FPartialLen` (is_complete_fast); then the `max_header_size` and `max` checks, then `PollReadFromIo`; 0 bytes -> incomplete |
| `poll_read_from_io` | `PollReadFromIo(out N: SizeInt): TPoll` | `next = min(strategy.next, max - len)`, reserve, one `Io.Read`, `Record(n)`, then `Observer.BytesRead` (SPEC `bytes_read`), `read_blocked` on `-EAGAIN` |
| `MemRead::read_mem` | `ReadMem(Len: SizeInt; out P: PByte; out N: SizeInt): TPoll` | used by the decoder glue (2.4) |
| `poll_flush`, `poll_flush_flattened` | `PollFlush`, `PollFlushFlattened` | pipeline_flush skip, 64 iovecs, `WriteZero` error |
| `poll_shutdown` | `PollShutdown` | flush then `ShutdownWrite` |
| `into_inner` | `TakeParts(out Fd: cint; out Leftover: TBufSlice)` | upgrade / without_shutdown hand-off |
| `WriteBuf::{buffer,can_buffer,headers_mut,remaining,advance,chunks_vectored}` | `TWriteBuf` same names | Queue holds up to 16 `TQueuedBuf`; Flatten copies via `TEncodedBuf.AppendTo` |
| `Cursor::{maybe_unshift,reset}` | `TByteCursor.MaybeUnshift/Reset` | io.rs test `write_buf_flatten_partially_flushed` checks pos/capacity |

**bearings.http1.conn (conn.rs, 1183 lines)**

| hyper | Pascal |
|---|---|
| `Reading {Init, Continue(D), Body(D), KeepAlive, Closed}` | `TReading = (rdInit, rdContinue, rdBody, rdKeepAlive, rdClosed)` + `FDecoder: TDecoder` (M2) |
| `Writing {Init, Body(E), KeepAlive, Closed}` | `TWriting = (wrInit, wrBody, wrKeepAlive, wrClosed)` + `FEncoder: TEncoder` (M2) |
| `KA {Idle, Busy, Disabled}` | `TKeepAlive = (kaIdle, kaBusy, kaDisabled)` |
| `State` fields | `TH1ConnState` record (allow_half_close, keep_alive, method, notify_read, reading, writing, upgrade pending flag, version, allow_trailer_fields, header timeout node + running flag, date_header, title_case_headers, parser ctx) |
| `can_read_head`, `can_read_body`, `has_initial_read_write_state`, `should_error_on_eof`, `has_h2_prefix` | same names |
| `poll_read_head` | `PollReadHead(out Msg: TParsedRequestHead; out Wants: TWants): TPoll` (header-timeout arm/check, `busy`, `keep_alive &= msg.keep_alive`, Continue vs Body decoder via M2 `InitDecoderFor`, `allow_trailer_fields := TeIsTrailers`) |
| `on_read_head_error` | `OnReadHeadError` |
| `poll_read_body` | `PollReadBody(out F: TInFrame): TPoll` (Continue -> buffer `HTTP/1.1 100 Continue\r\n\r\n` if `wrInit`) |
| `wants_read_again`, `poll_read_keep_alive`, `is_mid_message`, `mid_message_detect_eof`, `force_io_read`, `maybe_notify`, `try_keep_alive` | same names (`require_empty_read` is client-only, not ported) |
| `can_write_head`, `can_write_body`, `can_buffer_body`, `has_buffered_write` | same names |
| `write_head`, `encode_head`, `fix_keep_alive`, `enforce_version` | same names; `encode_head` calls M2 `ServerEncode` with `P.Date := Loop.Date` (no threadvar) |
| `write_body`, `write_trailers`, `write_body_and_end`, `end_body` | same names; `WriteTrailers` is the fixed version (5.2) |
| `on_parse_error` | `OnParseError` (h2 preface -> `VersionH2`; `ServerErrorStatus` -> automatic 400/414/431 head) |
| `poll_flush`, `poll_shutdown`, `poll_drain_or_close_read` | same names |
| `close_read`, `close_write`, `disable_keep_alive`, `take_error`, `on_upgrade`, `pending_upgrade` | same names |
| `State::{close, close_read, close_write, wants_keep_alive, try_keep_alive, busy, idle, is_idle, ...}` | methods of `TH1ConnState` |

**bearings.http1.dispatch (dispatch.rs, 770 lines; server parts)**

| hyper | Pascal |
|---|---|
| `Dispatcher { conn, dispatch, body_tx, body_rx, is_closing }` | `TH1Dispatcher = class(TProtoDriver)`: `FConn`, `FInFlight: TExchange` (server Dispatch's `in_flight`), `FBodyTx: TBodySender` (the loop end of the single-slot channel, 3.5), `FBodyRx: TBody`, `FIsClosing` |
| `poll_catch`, `poll_inner`, `poll_loop` | `Drive` (entry point), `PollInner`, `PollLoop` |
| `poll_read`, `poll_read_head`, `poll_write`, `poll_flush`, `close`, `can_write_again`, `is_done` | same names |
| `disable_keep_alive` | `GracefulShutdown` |
| `poll_without_shutdown`, `into_inner` | `TH1Options.ConnMode = cmWithoutShutdown` + `FinishWithParts` |
| `Server::poll_msg` | `PollMsg`: `pReady` when `FInFlight` has a response (signal `sigResponse`) |
| `Server::recv_msg` | `RecvMsg`: fill the exchange head, call `Service.Dispatch(X)` |
| `Server::poll_ready`, `should_poll` | `FInFlight = nil`, `FInFlight <> nil` |
| `SenderDropGuard` | in `Finish`: if `FBodyTx` is open, error it with `incomplete` |
| `OptGuard` | not needed: `clear_body` becomes an explicit `ClearBodyRx` call |
| `task::yield_now` after 16 iterations | `Loop.Defer(Self)` (`RunDeferred` calls `Drive`) |

Style of the port (excerpt):

```pascal
function TH1Dispatcher.PollLoop: TPoll;
var
  I: LongInt;
  R: TPoll;
  WriteReady, FlushReady, WantsWriteAgain, WantsReadAgain: Boolean;
begin
  for I := 1 to 16 do
  begin
    if PollRead = pErr then Exit(pErr);
    R := PollWrite;  if R = pErr then Exit(pErr);  WriteReady := R = pReady;
    R := PollFlush;  if R = pErr then Exit(pErr);  FlushReady := R = pReady;
    WantsWriteAgain := CanWriteAgain and (WriteReady or FlushReady);
    WantsReadAgain := FConn.WantsReadAgain;
    if not (WantsWriteAgain or WantsReadAgain) then Exit(pReady);
    if (not WantsReadAgain) and WantsWriteAgain then
    begin
      R := PollWrite;
      if R = pErr then Exit(pErr);
      if R = pPending then
      begin
        if FConn.HasBufferedWrite and (PollFlush = pErr) then Exit(pErr);
        Exit(pReady);
      end;
    end;
  end;
  FConn.Loop.Defer(Self);      { tokio yield_now: run again after this batch }
  Result := pPending;
end;
```

### 2.3 Wake sources (the replacement for wakers)

A `pPending` result is correct only if something will call `Drive` again. The sources:

| pending on | wake source |
|---|---|
| socket read/write `-EAGAIN` | epoll edge event on the socket |
| `FInFlight` has no response yet | `X` signals `sigResponse` (inline: direct; other thread: inbox post) |
| request body slot full / `want` false | `X` signals `sigBodyWant` when the app takes the slot or first reads |
| response body `PollFrame` pending | the body signals `sigStreamData` (stream ring) or its own timer (custom bodies) |
| header read timeout | timer wheel node |
| budget of 16 used | `Loop.Defer` |

Debug builds assert, when `Drive` returns `pPending`, that at least one of these is armed
(socket flags cleared by `EAGAIN`, an outstanding exchange, or an armed timer). The stall detector
(1.6) covers what the assertion cannot see.

### 2.4 Read buffer

`TReadBuf` mirrors `BytesMut`: data is `[Pos, Len)` of a pooled block `TBufBlock` (4.1).

- Start with no block (hyper starts with capacity 0). The first read takes a block of the size class
  `>= Strategy.NextSize` (8 KiB).
- `Reserve(Next)`: if `Cap - Len >= Next`, nothing. Else, if the block has no pins and
  `(Len - Pos) + Next <= Cap`, move the unread bytes to the front. Else take a block of the size class
  `>= (Len - Pos) + Next` and copy the unread bytes; the old block is released (or stays alive
  while pinned). Same visible behaviour as `BytesMut::reserve`.
- Reads are capped at `MaxBufSize - (Len - Pos)` exactly as io.rs 231-239; the 431 checks happen in
  `ParseHead` before reading (io.rs 204-215).
- When the buffer is empty and the connection is idle or waiting on the application, the block goes
  back to the loop pool (RSS, section 4).
- A complete head is parsed in place: M2 `ServerParse` adds external header entries relative to the
  block data; `TUriParts` offsets are relative to the same base. hyper's `split_to(head_len)` becomes
  `Pos += HeadLen` plus a pin on the block for the exchange's lifetime.

Decoder glue (hyper `Decoder::decode(cx, &mut io)` over `MemRead`): the M2 `TDecoder` works on a
buffer with an `AtEof` flag. `TH1Conn.DecodeFrame`:

```
loop
  if buffer empty: PollReadFromIo -> Pending/Err returns; 0 bytes -> AtEof := True
  St := FDecoder.Decode(BufPtr, BufLen, AtEof, FTrailers, R)
  Pos += R.Consumed (data slice = BufPtr + R.DataOfs, R.DataLen, pinned when handed out)
  dsNeedMore and not AtEof -> continue (next iteration reads)
  else return the frame / end / error
```

### 2.5 Write buffer and strategies

- Head buffer: `TByteCursor` over a pooled block (hyper's `Vec` with capacity 8192 per connection;
  ours is taken on first use and returned when fully flushed and the connection waits).
- `wsQueue` (default for plain TCP, as hyper with tokio's `is_write_vectored() = true`): body frames
  are queued without copy as `TQueuedBuf = record Enc: TEncodedBuf; Body: TBody; Tag: PtrInt;
  FileFd: cint; FileOfs, FileLen: Int64 end`, at most 16 (`MAX_BUF_LIST_BUFFERS`). Flush builds up to
  64 iovecs (`TEncodedBuf.FillIoVec` gives 0..3 each), one `writev`, then `Advance` and
  `Body.ReleaseFrame(Tag)` for every fully written entry. The queue array is taken from the loop
  pool on first use.
- `wsFlatten` (forced by `pipeline_flush`, and the default for TLS): `TEncodedBuf.AppendTo` copies
  into the head cursor; `MaybeUnshift` keeps the buffer from growing (io.rs semantics).
- File frames (`sendfile`) are never flattened. They are queued in both strategies; when a file
  frame reaches the front, the bytes before it are written first, then `Io.SendFile` runs until the
  frame is done or `EAGAIN`. Chunked framing around a file frame stays in memory (prefix/suffix of
  its `TEncodedBuf`).
- `can_buffer`: Flatten `remaining < max_buf_size`; Queue additionally `< 16` bufs (io.rs 529-536).

`pipeline_flush`: `PollFlush` returns `pReady` without writing while the read buffer has unparsed
bytes (io.rs 279-280), so pipelined responses leave in one write (`pipeline_enabled` case).

### 2.6 Behaviours that need care

| behaviour | where in hyper | port |
|---|---|---|
| keep-alive | `State::try_keep_alive`, `idle` | literal; `idle` resets `rdInit/wrInit`, sets `notify_read` when a header timeout is configured |
| half_close | `mid_message_detect_eof` | with `HalfClose` false and nothing buffered, a busy connection does one read when `ReadReady`; 0 bytes -> `incomplete`, the in-flight exchange is canceled |
| unread request body | `poll_drain_or_close_read` | one decode attempt from what is buffered/readable; not at end -> `close_read` |
| Expect: 100-continue | `poll_read_body` `Continue` arm | buffered only when the app first polls the body (3.5) and `wrInit` |
| upgrade / CONNECT | `prepare_upgrade`, `pending_upgrade`, `is_done` | `RecvMsg` marks the exchange `WantsUpgrade` and sets `FConn.UpgradePending` (hyper: `state.upgrade = Some`). At `is_done`, if pending: no shutdown, hand the socket plus `[Pos, Len)` of the read buffer (`read_buf`) to the registered `TUpgradeHandler` (with_upgrades) or to `Observer.ConnParts` (without_shutdown); in plain mode the handler gets `UpgradeFailed('manual upgrade')`. Leftover bytes move with the block; no copy |
| error -> response | `on_parse_error`, `Server::on_error` | M2 `ServerErrorStatus`: 400 / 414 / 431 written with `connection: close`, `content-length: 0`; anything else: no bytes |
| h2 preface | `has_h2_prefix` in `on_parse_error` | `cpHttp1Only`: outcome `parse_version_h2`, nothing written. `cpAuto`: `TProtoSniffer` reads up to 24 bytes before creating the h1 dispatcher, hands the bytes to the chosen driver (hyper-util `auto`) |
| service error / body error | `poll_catch`, `new_user_service`, `new_user_body` | `X.Fail` / body `pfError`: connection ends with `user`, no response (or unterminated chunked body) |
| 1xx final status | `Server::encode` | M2 already writes the 500 head and returns `serUnsupportedStatusCode` |
| response version HTTP/0.9 or 3.0 | role.rs panics | `ServerEncode` raises; the dispatcher catches it in `EncodeHead`'s cold path and ends the connection with `user` |
| flush before yield, shutdown while buffered | tests `h1_flush_before_yield.rs`, `h1_shutdown_while_buffered.rs` | follow from the literal port; reproduced with `TMockIo` (7.2) |

### 2.7 Error type and outcomes

```pascal
unit bearings.http.outcome;
type
  TH1ErrorKind = (h1eNone, h1eParse, h1eIncomplete, h1eHeaderTimeout, h1eUser, h1eCanceled,
    h1eClosed, h1eBody, h1eBodyWrite, h1eBodyWriteAborted, h1eShutdown, h1eIo,
    h1eUnexpectedMessage);
  TH1UserKind = (ukNone, ukService, ukBody, ukUnsupportedStatusCode, ukHeader, ukManualUpgrade,
    ukUnsupportedVersion);
  TH1Error = record                   { no managed fields }
    Kind: TH1ErrorKind;
    Parse: TH1ParseError;             { M2 bearings.http1.role }
    User: TH1UserKind;
    Errno: cint;
  end;

  TConnOutcome = (coOk, coTimeout, coParseTooLarge, coParseVersionH2, coParse, coIncomplete,
    coUser, coCanceled, coClosed, coBodyWriteAborted, coShutdown, coIo, coOther);

function OutcomeOf(const E: TH1Error): TConnOutcome;   { SPEC 7.2 order of predicates }

type
  TConnObserver = class               { nil by default: zero cost }
  public
    procedure ConnOpened(ConnId: QWord); virtual;
    procedure BytesRead(ConnId: QWord; Total: QWord); virtual;
    procedure ConnClosed(ConnId: QWord; Outcome: TConnOutcome; const Detail: string); virtual;
    { cmWithoutShutdown: the HTTP layer finished; U owns the socket and read_buf }
    procedure ConnParts(ConnId: QWord; U: TUpgraded); virtual;
  end;
```

Teardown order in `TH1Dispatcher.Finish` (fixes the SPEC event ordering): cancel the in-flight
exchange (its listener's `Canceled` runs now, so `handler_dropped` precedes `conn_close`), error
the body sender, flush + `shutdown(SHUT_WR)` + `close` (or keep the socket for an upgrade / parts),
`Observer.ConnClosed`, then deliver `TUpgraded` to the upgrade handler or `ConnParts`
(SPEC 6.1: `conn_close` before any upgrade action).

### 2.8 Options

```pascal
unit bearings.http1.options;
type
  TWriteStrategyOpt = (wsAuto, wsQueue, wsFlatten);
  TH1ConnMode = (cmPlain, cmWithUpgrades, cmWithoutShutdown);
  TH1Options = record                 { hyper http1::Builder }
    KeepAlive: Boolean;               { true }
    HalfClose: Boolean;               { false }
    TitleCaseHeaders: Boolean;        { false }
    PreserveHeaderCase: Boolean;      { false; no effect on server responses (see bearings.http1.role header) }
    MaxHeaders: LongInt;              { -1 = None (100 stack slots) }
    MaxHeaderSize: SizeInt;           { -1 = None }
    MaxBufSize: SizeInt;              { 8192 + 4096*100; >= 8192 }
    HeaderReadTimeoutMs: Int64;       { -1 = none; hyper: 30000 only with a timer }
    WriteStrategy: TWriteStrategyOpt; { wsAuto }
    PipelineFlush: Boolean;           { false }
    AutoDateHeader: Boolean;          { true }
    ParserConfig: TParserConfig;      { M2: ignore_invalid_headers, multiple spaces }
    ConnMode: TH1ConnMode;            { cmWithUpgrades for production }
  end;

function DefaultH1Options: TH1Options;
function ValidateH1Options(const O: TH1Options; out Msg: string): Boolean;
```

---

## 3. Service API

### 3.1 What M5 needs (derived from Proper's docs)

| Proper behaviour | requirement on the transport |
|---|---|
| controllers, models, forms are synchronous code; DB calls block (Granian runs WSGI on its own threads; `MAX_THREADS` = requests at once) | run handlers on worker threads; a blocked handler must not stall any loop |
| pipeline: head_to_get, method_override, match, redirect, copy_session, dispatch (before / action / after), update_session_cookie; `around_request`, `on_error`, `on_teardown` | the whole pipeline runs in one call on one thread with the request head and a response under construction |
| `request.form` incl. multipart uploads, `MAX_CONTENT_LENGTH` 413 "before parsing", `MAX_FORM_PART_SIZE` | blocking, bounded body reads; `ContentLength` known before reading; zero-copy chunks for spooling files |
| `request.headers/cookies/query/remote_ip/host/port/...` | read-only head with zero-copy accessors and the peer address |
| `response.status/headers/body/cookies`, `redirect_to`, `fresh_when` | a response head + a known-length body handed over at the end |
| `send_file` (plus X-Sendfile) | a file body that uses `sendfile` |
| exceptions -> `router.error(...)` handlers, 404/500 pages | the transport only sees a response; M5 catches exceptions |
| client disconnects while a controller waits on the DB | the request is marked canceled; blocked body reads/writes return at once; the response is dropped |
| streaming (CSV export, SSE), WebSockets (channels) | streamed bodies with backpressure, from the handler thread or another thread; upgrade hand-off |
| benchmark endpoints, health checks | answer on the loop thread with no thread hop |

### 3.2 Execution model

```
loop thread                                    worker thread
───────────                                    ─────────────
TH1Dispatcher.RecvMsg
  X := exchange (head slices, body sender)
  Service.Dispatch(X) ──► inline: X.SendStatic(...)        (done before Dispatch returns)
                      └─► X.Offload(Runner) ─ queue ──────► Runner.Execute(X)
                                                              ... DB, X.Read (parks), ...
  PollMsg sees sigResponse ◄─ inbox post ◄────────────────── X.SendString(Body)
  write head + body, flush                                   returns; X.Release
```

- `THttpService.Dispatch` always runs on the loop thread, right after the head is parsed (hyper's
  `service.call`). It must not block. A router matches the route here (pure CPU) and chooses inline
  or offload per route.
- Inline handlers answer from `Dispatch` or later from loop callbacks (`TExchangeListener`).
- `X.Offload(H)` queues `X` to the worker pool. The response is "pending" (hyper: the service
  future is not ready) until the worker hands a response over.
- HTTP/1 processes one request at a time per connection (hyper `poll_ready` returns Pending while
  `in_flight`), so a worker-bound connection costs one queue entry, not more.

Why not everything on workers: a thread hop per request costs two cross-core cache transfers and
often an `eventfd` write plus a futex wake. For pipelined plaintext at hyper's rate that alone
exceeds the 20 % budget. Why not everything on loops: Proper code blocks. Why not stackful
coroutines (run blocking code on the loop and switch on block): FPC 3.2.2 has no support,
exception frames across hand-written context switches are unverified, and DB client libraries block
in C anyway. The hybrid is the simplest model that meets both requirements.

### 3.3 Types

```pascal
unit bearings.http.exchange;
{$mode objfpc}{$H+}
interface
uses wd.sys.sync, bearings.rt.timer, bearings.http.headers, bearings.http.uri, bearings.http1.role, bearings.http.body;

type
  TExchange = class;

  { The application: one instance per server. }
  THttpService = class
  public
    { Loop thread, request head parsed. Must not block. Must eventually lead to exactly
      one terminal call on X (Send*, BeginStream..Finish/Abort, Fail), here, from a
      listener callback, from Offload'ed code, or from another thread holding a ref. }
    procedure Dispatch(X: TExchange); virtual; abstract;
  end;

  { Blocking application code; a shared, stateless instance is typical. }
  TWorkerHandler = class
  public
    procedure Execute(X: TExchange); virtual; abstract;   { worker thread }
  end;

  { Callbacks for code that runs on the loop thread. All are called on X's loop. }
  TExchangeListener = class
  public
    procedure BodyReady(X: TExchange); virtual;            { TryRead can make progress }
    procedure Writable(X: TExchange); virtual;             { TryWrite has room again }
    procedure TimerFired(X: TExchange; Tag: PtrInt); virtual;
    { The HTTP layer abandoned the request before a response was handed over
      (hyper drops the service future). Not called after Send*/BeginStream. }
    procedure Canceled(X: TExchange); virtual;
    procedure Finished(X: TExchange); virtual;             { X is about to be recycled }
  end;

  TBodyReadStatus = (brData, brPending, brTrailers, brEnd, brError, brCanceled);
  TWriteResult = (wrOk, wrWouldBlock, wrCanceled);

  TBodyErrorKind = (bekNone, bekUnexpectedEof, bekInvalidData, bekInvalidInput, bekIo,
    bekConnection, bekOther);                              { SPEC 7.1 kinds }

  EClientGone = class(Exception);                          { blocking calls after cancel }
  EBodyError = class(Exception)
  public
    Kind: TBodyErrorKind;
  end;

  TExchange = class(TLoopWork)
  private
    { fields omitted in this sketch: FStatus, FRespVersion, FUser, FUserTag, FSignals,
      FOwner, FRefCount, FShared, head slices, body slot, timer node, ... }
  public
    { ---- request head: immutable, any thread, valid until X is recycled ---- }
    function Method: THttpMethod;
    procedure MethodBytes(out P: PByte; out Len: SizeInt);
    procedure Target(out P: PByte; out Len: SizeInt);       { request-target as received }
    procedure Path(out P: PByte; out Len: SizeInt);         { http Uri::path() }
    function Query(out P: PByte; out Len: SizeInt): Boolean;
    function Uri: TUriParts;                                { offsets relative to HeadBase }
    function HeadBase: PByte;
    function Version: THttpVersion;
    function Headers: THttpHeaders;                         { read-only by contract }
    function Header(const Name: RawByteString; out P: PByte; out Len: SizeInt): Boolean;
    function ContentLength: Int64;                          { 0 no body; -1 chunked }
    function ExpectsContinue: Boolean;
    function WantsUpgrade: Boolean;
    function PeerAddress: PSockAddr;
    function ConnId: QWord;
    function RequestNo: LongWord;                           { 1, 2, ... per connection }
    function IsSecure: Boolean;

    { ---- request body ---- }
    { Never blocks; any thread. The first call sets "want" (sends 100 Continue when
      the client asked and nothing was written). P/Len valid until the next body call
      on X or X's terminal call. brPending: an inline caller gets BodyReady later. }
    function TryRead(out P: PByte; out Len: SizeInt): TBodyReadStatus;
    { Worker threads only (asserts not on a loop). Park until data/end/error.
      Return 0 at end. Raise EBodyError / EClientGone. }
    function Read(Buf: PByte; Max: SizeInt): SizeInt;
    function ReadChunk(out P: PByte; out Len: SizeInt): Boolean;      { zero-copy }
    function ReadAll(var Dst: TBytes; Limit: SizeInt): SizeInt;       { EBodyTooLarge over Limit }
    { Drop the body without reading (hyper: drop Incoming). No 100 Continue. }
    procedure DiscardBody;
    function RequestTrailers: THttpHeaders;                 { after brTrailers/end }
    function BodyErrorKind: TBodyErrorKind;
    function BodyErrorMessage: string;

    { ---- response head (set before the terminal call) ---- }
    property Status: Word read FStatus write FStatus;       { 200 }
    property ResponseVersion: THttpVersion read FRespVersion write FRespVersion;
    procedure SetReason(P: PByte; Len: SizeInt);            { validated; EInvalidReason }
    function ResponseHeaders: THttpHeaders;                 { validating mutators (5.1) }

    { ---- terminal calls: exactly one per exchange, any thread ---- }
    procedure SendEmpty;                                    { http_body_util::Empty }
    procedure SendStatic(P: PByte; Len: SizeInt);           { no copy; memory outlives the server }
    procedure SendCopy(P: PByte; Len: SizeInt);             { copied into X's body buffer }
    procedure SendString(const S: RawByteString);           { keeps one reference, no copy }
    procedure SendFile(Fd: cint; Offset, Len: Int64; CloseWhenDone: Boolean);
    procedure SendBody(B: TBody);                           { custom loop-side source }
    procedure Fail(const Msg: string);                      { hyper: service returns Err }

    { ---- streamed response: unknown length (chunked on 1.1, close-delimited on 1.0) ---- }
    procedure BeginStream(HighWater: SizeInt = 65536);      { hands the head over now }
    function Write(P: PByte; Len: SizeInt): TWriteResult;   { non-loop threads: parks for room }
    function TryWrite(P: PByte; Len: SizeInt): TWriteResult;{ any thread, never blocks }
    function WriteString(const S: RawByteString): TWriteResult;      { zero-copy frame }
    procedure Finish(Trailers: THttpHeaders = nil);         { copied; sent if allowed (5.2) }
    procedure Abort(const Msg: string);                     { hyper: body yields Err }

    { ---- upgrade (hyper::upgrade::on) ---- }
    procedure OnUpgrade(H: TUpgradeHandler);                { before the terminal call }

    { ---- execution and lifetime ---- }
    procedure Offload(H: TWorkerHandler);                   { loop thread, from Dispatch }
    procedure Listen(L: TExchangeListener);                 { loop-thread callbacks }
    procedure SetTimer(DelayMs: Int64; Tag: PtrInt);        { loop thread; one timer per X }
    procedure CancelTimer;
    function IsCanceled: Boolean;                           { any thread }
    procedure AddRef;                                       { keep X alive past the handler }
    procedure Release;                                      { any thread }
    property User: TObject read FUser write FUser;          { per-request application state }
    property UserTag: PtrInt read FUserTag write FUserTag;
  end;
```

Notes:

- One terminal call. A second terminal call raises `EExchangeState` (programming error). A worker
  `Execute` that returns without one gets `Fail('handler returned no response')`.
- "Canceled" is a state, not an exception: after cancellation every terminal call is a no-op,
  `Write`/`TryWrite` return `wrCanceled`, blocking reads raise `EClientGone`.
- `IsCanceled` is a plain load of a flag written by the loop (x86 TSO; the flag is set with an
  interlocked op).

### 3.4 Exchange lifetime and cross-thread protocol

- Owned by the connection's loop. HTTP/1: each `TH1Dispatcher` keeps one exchange and reuses it
  for the next request when its reference count is back to 1 (no pool traffic per request).
  Otherwise (a worker or stream producer still holds it) the dispatcher drops its reference and
  takes a fresh one from the loop's `TExchangePool`.
- `RefCount` is a plain integer while the exchange is "not shared" (inline-only use) and an
  interlocked integer once `Offload` or `AddRef` from another thread happened (`FShared` flag). The
  final `Release` on a non-loop thread posts the exchange to its loop (as a `TLoopWork`) to be
  recycled; exchanges and their blocks are always freed on the loop that allocated them (FPC's
  per-thread heap: no cross-thread frees on the hot path).
- Signals from the application to the loop are bits in `FSignals` (`AtomicOr`), then one
  `Loop.Post(X)` (coalesced by `FQueued`). `RunOnLoop` takes all bits with `InterlockedExchange`
  and calls the owner (`TStreamOwner`, implemented by `TH1Dispatcher`, later `TH2Session`):

```pascal
const
  sigResponse    = 1 shl 0;   { a terminal call happened: head (+ body) ready }
  sigBodyWant    = 1 shl 1;   { app polled the body / took the slot }
  sigBodyDrop    = 1 shl 2;   { app discarded the body (receiver closed) }
  sigStreamData  = 1 shl 3;   { frames or Finish/Abort in the stream ring }
  sigHandlerDone = 1 shl 4;   { Execute returned }
  sigReleased    = 1 shl 5;   { last off-loop ref dropped }

type
  TStreamOwner = class
  public
    procedure ExchangeSignaled(X: TExchange; Bits: LongWord); virtual; abstract;  { loop }
    procedure ExchangeDetached(X: TExchange); virtual; abstract;                   { loop }
  end;
```

- When the loop thread itself makes the call (inline handler), the bits are set and, if the
  dispatcher is inside `Drive`, the current `PollLoop` iteration sees them; otherwise the
  dispatcher is deferred (`Loop.Defer`). There is no recursion into `Drive` from application code.
- On cancellation the dispatcher calls `X.Cancel` (sets the flag, unparks a parked worker, calls
  `Listener.Canceled` if no response was handed over), sets `X.FOwner := nil` and drops its
  reference. Later signals from a worker find `FOwner = nil` and only do lifetime work. The worker
  never touches the connection; the socket may already be closed and reused.

### 3.5 Request body: the single-slot channel

Port of `body/chan.rs`, split into the loop side (`TBodySender`, used by `TH1Dispatcher.PollRead`
exactly where hyper uses `body_tx`) and the application side (methods on `TExchange`):

| field | meaning |
|---|---|
| `Want` | initial value `not ExpectContinue` (chan.rs: `want: !wanter`). Set True by every application poll |
| `Slot` | one frame: data slice (pinned block), trailers, or error |
| `ReceiverOpen` | False after `DiscardBody`, after `Execute` returns, or after an inline handler's terminal call when it never read (hyper drops `Incoming` with the request) |
| `SenderOpen` | False after end of body or connection error |

Loop side, as in `dispatch.rs` 228-296: `PollReady` (Ready if `Want` and slot empty; Err if
receiver closed -> `PollDrainOrCloseRead`), then `FConn.PollReadBody`, then `TrySendData` /
`TrySendTrailers` / `SendError`. With `Want` initially true, the loop prefetches one chunk before the
application asks (same as hyper). For `Expect: 100-continue`, nothing is read until the first
`TryRead`/`Read`/`ReadChunk`/`ReadAll`, which sets `Want`; the dispatcher then calls
`PollReadBody`, which buffers `HTTP/1.1 100 Continue\r\n\r\n` (`expect_continue_waits_for_body_poll`).

Worker `Read` without busy waiting:

```
G := X.FBodyGen;                 { generation counter, bumped by the loop on every slot change }
case TryRead(P, L) of
  brData: copy, return
  brPending: Parker.ParkOn(@X.FBodyGen, G)   { futex wait on the counter value }
  ...
```

The loop bumps `FBodyGen` and does `futex_wake` after filling the slot, ending the body, or
canceling.

Backpressure into the socket: while the slot is full, `PollRead` returns Pending before reading
the socket, so a slow consumer stops reads and TCP flow control pushes back on the client.

### 3.6 Response bodies

```pascal
unit bearings.http.body;
type
  TFrameKind = (fkData, fkTrailers, fkFile);
  TFrame = record
    Kind: TFrameKind;
    Data: PByte; Len: SizeInt;              { fkData; valid until ReleaseFrame(Tag) }
    Trailers: THttpHeaders;                 { fkTrailers; owned by the body }
    FileFd: cint; FileOfs, FileLen: Int64;  { fkFile }
    Tag: PtrInt;                            { passed back to ReleaseFrame }
  end;
  TPollFrame = (pfFrame, pfPending, pfEnd, pfError);

  TBody = class                              { http_body::Body; called on the loop only }
  public
    { pfPending only if a wake is arranged (signal the exchange or a timer). }
    function PollFrame(var F: TFrame): TPollFrame; virtual; abstract;
    function IsEndStream: Boolean; virtual;                  { default False }
    function SizeHint(out Exact: QWord): Boolean; virtual;   { True: exact length }
    procedure ReleaseFrame(Tag: PtrInt); virtual;            { bytes left the write buffer }
    function ErrorMessage: string; virtual;
    procedure Dispose; virtual;                              { back to a pool or Free }
  end;

  TEmptyBody   { IsEndStream True: no CL/TE logic beyond hyper's "None" }
  TBytesBody   { static / copied / RawByteString; SizeHint exact; IsEndStream after the frame }
  TFileBody    { one fkFile frame; SizeHint exact }
  TStreamBody  { ring fed by TExchange.Write/TryWrite/WriteString/Finish/Abort }
```

The dispatcher uses them exactly as hyper uses `Body` (dispatch.rs 349-437): `IsEndStream` at
head time chooses "no body", `SizeHint` chooses `Known(n)` vs `Unknown`, a data frame followed by
`IsEndStream` goes through `write_body_and_end` (last chunk and terminator in one buffer), empty data
frames are skipped (`body_empty_chunks_ignored`).

`TStreamBody` is a single-producer ring of `[len][bytes]` records sized `HighWater` (default 64 KiB)
taken from a global, mutex-protected ring pool (streams are not the hot path; the ring is allocated
by whatever thread calls `BeginStream`, and returned to the pool, never freed cross-thread). Frame
boundaries are kept: each `Write` is one frame and one chunk on the wire (SPEC 5.4 requires this).
A frame larger than the ring gets its own buffer (no splitting). `WriteString` stores a
RawByteString reference instead of copying. Several producer threads must serialize themselves.

Backpressure out: the dispatcher polls the body only while `CanBufferBody` (write buffer below
`max_buf_size`, Queue below 16 bufs: hyper's rule). In Queue mode ring slices are released only
after `writev`, so ring space tracks bytes actually written to the socket. A producer blocked in
`Write` parks until the ring is below half `HighWater` or the exchange is canceled; `TryWrite`
returns `wrWouldBlock` and the inline listener gets `Writable` later.

### 3.7 Upgrades

```pascal
type
  TUpgraded = class(TPollable)
  public
    procedure Leftover(out P: PByte; out Len: SizeInt);    { hyper read_buf }
    procedure ConsumeLeftover(N: SizeInt);
    { Stay on the loop: callbacks on the loop thread }
    procedure Attach(L: TRawListener);
    function TryRead(Buf: PByte; Max: SizeInt): SizeInt;   { > 0, 0 EOF, -EAGAIN, -errno }
    function TryWrite(Buf: PByte; Len: SizeInt): SizeInt;
    { Leave the loop: removes the fd from epoll, makes it blocking, returns it.
      Leftover stays readable. Caller owns the fd. }
    function Detach: cint;
    procedure Close;
    property Loop: TLoop read FLoop;
  end;

  TRawListener = class
  public
    procedure Readable(U: TUpgraded); virtual;
    procedure Writable(U: TUpgraded); virtual;
  end;

  TUpgradeHandler = class
  public
    procedure Upgraded(U: TUpgraded); virtual; abstract;   { loop thread }
    procedure UpgradeFailed(const Msg: string); virtual;   { plain mode: 'manual upgrade' }
  end;
```

`X.OnUpgrade(H)` corresponds to `hyper::upgrade::on(&mut req)`. hyper decides at `is_done` (the
HTTP layer finished; a 101 or CONNECT-2xx response sets `is_last`); the port keeps that rule,
including the hyper behaviour that a pending upgrade from a request whose response was not 101 is
still handed over when the connection ends (`upgrades_ignored`: nobody registered, so the socket is
closed).

### 3.8 HTTP/2 fit (not built in M3)

| nghttp2 callback | exchange operation |
|---|---|
| `on_begin_headers` | take `X` from the loop pool, `FOwner := Session` |
| `on_header` | `X.Headers.AddUnchecked` (nghttp2 validated) into the exchange arena (h2 has no read buffer to point into) |
| `on_frame_recv` (HEADERS, END_HEADERS) | `Service.Dispatch(X)` |
| `on_data_chunk_recv` | copy into the exchange's body ring; `nghttp2_session_consume` when the app takes it (flow control = backpressure, as hyper's `release_capacity` on poll) |
| data provider `read_callback` | `X`'s `TBody.PollFrame`; `NGHTTP2_ERR_DEFERRED` on pending, `nghttp2_session_resume_data` on `sigStreamData` |
| trailers | `nghttp2_submit_trailer` from the `fkTrailers` frame |
| `on_stream_close` with error | `X.Cancel` (hyper: RST cancels the handler) |

The application code in section 3.10 runs unchanged on HTTP/2.

### 3.9 M5 on top of the exchange

M5 objects (`TRequest`, `TResponse`, controllers) live on the worker thread for the duration of
`Execute`, use AnsiString freely, and hold the exchange.

| Proper (api.md) | M5 implementation over `TExchange` |
|---|---|
| `request.method`, `request_method`, `path`, `query_string`, `http_version`, `headers` | lazy AnsiStrings built once from `X.MethodBytes`, `X.Path`, `X.Query`, `X.Version`; `headers` a MultiDict view over `X.Headers` |
| `host`, `port`, `protocol`, `remote_ip`, `is_secure` | `Host` header / `X.Uri` authority, `X.PeerAddress`, `X.IsSecure`, forwarded headers |
| `content_length`, `content_type` | `X.ContentLength`, header |
| `form` (urlencoded, multipart, files) | `TFormParser` reads with `X.ReadChunk`; checks `X.ContentLength > MAX_CONTENT_LENGTH` before reading (413), counts bytes for chunked bodies; multipart parts over a threshold spool to a temp file (`TMultipartPart.Stream`) |
| `cookies`, `get_signed_cookie`, `session` | parse `Cookie`; HMAC-SHA256 via OpenSSL libcrypto (already a runtime dependency) |
| `response.status`, `headers`, `body`, `set_cookie`, `redirect_to`, cache helpers | M5 objects; `CommitTo(X)` copies status + headers (validated) + `Set-Cookie` lines, then `X.SendString(Body)` (no copy) |
| `send_file(path, ...)` | `CommitTo` opens the file (`O_RDONLY|O_CLOEXEC`), `fstat`, sets content-type/disposition, `X.SendFile(Fd, 0, Size, True)`; with `x_sendfile_header` only the header is sent |
| HEAD -> GET, body dropped | nothing to do: the encoder sends `content-length` and no body for HEAD (hyper) |
| `current` | a threadvar set by the worker for the duration of `Execute` (2.7 ns per access; acceptable at this layer) |
| `on_error`, `on_teardown`, `around_request` | run inside `Execute`'s try/except/finally |
| per-thread DB connections | `TWorkerHooks.ThreadStarted/ThreadStopping` virtuals on the pool |

Callback registration without closures: published methods resolved by name once, at class
registration (`MethodAddress`), into `TMethod` code pointers; no per-request string lookups.

```pascal
type
  TControllerRunner = class(TWorkerHandler)       { one per route, shared }
  private
    FRoute: TRoute;
    FApp: TWebApp;
  public
    procedure Execute(X: TExchange); override;
  end;

procedure TControllerRunner.Execute(X: TExchange);
var
  Req: TRequest;
  Res: TResponse;
begin
  Req := TRequest.Create(FApp, X, FRoute);
  Res := TResponse.Create(FApp, X);
  try
    try
      FApp.RunPipeline(Req, Res);             { around_request -> head_to_get ... update_session_cookie }
      Res.CommitTo(X);
    except
      on EClientGone do X.Fail('client gone');  { nothing can be sent }
      on E: Exception do
      begin
        FApp.HandleError(E, Req, Res);        { router.error(...) controller, on_error hooks }
        Res.CommitTo(X);                      { the error page }
      end;
    end;
  finally
    FApp.RunTeardown(Req, Res);
    Res.Free;
    Req.Free;
  end;
end;

type
  TRouter = class(THttpService)
  public
    procedure Dispatch(X: TExchange); override;
  end;

procedure TRouter.Dispatch(X: TExchange);
var
  R: TRoute;
begin
  R := Match(X);                              { loop thread: CPU only }
  if R = nil then R := FNotFoundRoute;
  if R.Inline then
    R.InlineHandler.Handle(X)                 { static assets, health, benchmarks }
  else
    X.Offload(R.Runner);
end;
```

### 3.10 Code sketches

**(a) Controller action** (worker thread; blocks on the DB):

```pascal
type
  TCardController = class(TAppController)
  private
    FCard: TCard;
    FForm: TCardForm;
  public
    class procedure Callbacks(C: TCallbackSpec); override;
  published
    procedure Index;
    procedure Show;
    procedure Update;
    procedure Delete_;                        { 'delete' action; trailing _ avoids Pascal clashes }
    procedure SetCard;
    procedure SetForm;
  end;

class procedure TCardController.Callbacks(C: TCallbackSpec);
begin
  inherited Callbacks(C);                     { parent callbacks run first (MRO order) }
  C.Before('SetCard', [], ['Index', 'New', 'Create_']);
  C.Before('SetForm', [], ['Index', 'Show', 'Delete_']);
  C.Before('ValidateForm', ['Create_', 'Update'], []);   { from the FormValidation concern }
end;

procedure TCardController.SetCard;
begin
  FCard := TCard.Find(StrToInt64Def(Params['card_id'], 0));   { SQL round trip: worker parks in libpq }
  if (FCard = nil) and (Request.MatchedAction <> 'delete') then
    raise ENotFound.Create('Card not found');  { -> router.error(ENotFound) controller }
end;

procedure TCardController.SetForm;
begin
  FForm := TCardForm.Create(Params, FCard);    { Params reads Request.Form: body read here }
end;

procedure TCardController.Update;
var
  Card: TCard;
begin
  Card := TCard(FForm.Save);
  Response.RedirectTo('Card.show', Card, 'Card was updated');   { sets body -> after callbacks run }
end;
```

**(b) Streamed responses.** From the handler thread (CSV export; client disconnect stops the query):

```pascal
procedure TReportController.Export;
var
  W: TResponseStream;
  Q: TQuery;
  Line: RawByteString;
begin
  Response.ContentType := 'text/csv';
  W := Response.Stream;                       { commits status + headers: X.BeginStream }
  Q := DB.Query('select id, title, created_at from cards order by id');
  try
    while Q.Next do
    begin
      Line := Q.CsvLine;
      if W.Write(Line) = wrCanceled then Exit;   { parks while 64 KiB are unsent }
    end;
    W.Finish;                                 { "0\r\n\r\n" }
  finally
    Q.Free;
  end;
end;
```

From another thread (server-sent events fed by a broadcaster; the handler returns at once):

```pascal
type
  TSseService = class(THttpService)
  public
    procedure Dispatch(X: TExchange); override;
  end;

  TTicker = class(TThread)                    { owns the subscriber list }
  protected
    procedure Execute; override;
  end;

procedure TSseService.Dispatch(X: TExchange);
begin
  X.ResponseHeaders.Add('content-type', 'text/event-stream');
  X.ResponseHeaders.Add('cache-control', 'no-store');
  X.BeginStream(16 * 1024);
  X.AddRef;                                   { the ticker thread keeps X alive }
  Ticker.Subscribe(X);                        { mutex-protected list }
end;

procedure TTicker.Execute;
var
  I: LongInt;
  Msg: RawByteString;
begin
  while not Terminated do
  begin
    Sleep(1000);
    Msg := 'data: ' + FormatDateTime('hh:nn:ss', Now) + #10#10;
    Lock;
    try
      for I := FSubs.Count - 1 downto 0 do
        if TExchange(FSubs[I]).TryWrite(PByte(Pointer(Msg)), Length(Msg)) = wrCanceled then
        begin
          TExchange(FSubs[I]).Release;        { client gone }
          FSubs.Delete(I);
        end;                                  { wrWouldBlock: slow client, skip this tick }
    finally
      Unlock;
    end;
  end;
end;
```

**(c) Upload.** Through M5 forms (multipart, spooled parts):

```pascal
procedure TProfileController.Update;
var
  Part: TMultipartPart;
  Att: TAttachment;
begin
  Part := Request.Form.FilePart('avatar');    { form parsed on first access; 413 / part limits raise }
  if Part <> nil then
  begin
    Att := TAttachment.CreateFrom(Part.Stream, Part.FileName, Part.ContentType);
    Att.Save;                                 { storage service + INSERT }
    CurrentUser.AvatarId := Att.Id;
    CurrentUser.Save;
  end;
  Response.RedirectTo('Profile.show', nil, 'Profile updated');
end;
```

Raw streaming upload at the transport level (PUT to disk; `100 Continue` is sent by the first
`ReadChunk` if the client asked):

```pascal
type
  TPutFile = class(TWorkerHandler)
  public
    procedure Execute(X: TExchange); override;
  end;

procedure TPutFile.Execute(X: TExchange);
var
  P: PByte;
  Len, Total: SizeInt;
  F: THandle;
begin
  if X.ContentLength > MaxUpload then
  begin
    X.Status := 413;
    X.DiscardBody;                            { no 100 Continue; hyper drains or closes }
    X.SendEmpty;
    Exit;
  end;
  F := FileCreate(TargetPath(X));
  Total := 0;
  try
    while X.ReadChunk(P, Len) do              { zero-copy slice of the read buffer }
    begin
      Inc(Total, Len);
      if Total > MaxUpload then raise EBodyTooLarge.Create('upload too large');
      if FileWrite(F, P^, Len) <> Len then raise EInOutError.Create('disk write failed');
    end;
  finally
    FileClose(F);
  end;
  X.Status := 201;
  X.SendEmpty;
end;
```

**(d) Upgrade handler** (WebSocket echo on the loop thread; the handshake runs in a controller):

```pascal
procedure TSocketController.Connect;           { worker; validates the handshake }
begin
  if not IsWebSocketHandshake(Request) then raise EBadRequest.Create('not a websocket handshake');
  Response.Status := 101;
  Response.Headers['upgrade'] := 'websocket';
  Response.Headers['connection'] := 'upgrade';
  Response.Headers['sec-websocket-accept'] := WebSocketAccept(Request.Headers['sec-websocket-key']);
  Request.OnUpgrade(TEchoSocketFactory.Instance);   { X.OnUpgrade }
end;

type
  TEchoSocketFactory = class(TUpgradeHandler)
  public
    class var Instance: TEchoSocketFactory;
    procedure Upgraded(U: TUpgraded); override;
  end;

  TEchoSocket = class(TRawListener)          { one per connection: holds parser state }
  private
    FU: TUpgraded;
    FParser: TWsFrameParser;
    FOut: TWsWriteQueue;
  public
    procedure Readable(U: TUpgraded); override;
    procedure Writable(U: TUpgraded); override;
  end;

procedure TEchoSocketFactory.Upgraded(U: TUpgraded);
var
  S: TEchoSocket;
  P: PByte;
  L: SizeInt;
begin
  S := TEchoSocket.Create;
  S.FU := U;
  U.Leftover(P, L);                           { bytes the client sent after the handshake }
  S.FParser.Feed(P, L);
  U.ConsumeLeftover(L);
  U.Attach(S);                                { Readable/Writable on this loop from now on }
  S.Readable(U);
end;

procedure TEchoSocket.Readable(U: TUpgraded);
var
  Buf: array[0..16383] of Byte;
  N: SizeInt;
begin
  repeat
    N := U.TryRead(@Buf[0], SizeOf(Buf));
    if N > 0 then FParser.Feed(@Buf[0], N);
  until N <= 0;
  while FParser.NextMessage do
    FOut.Push(FParser.Opcode, FParser.Payload, FParser.PayloadLen);
  Writable(U);
  if N = 0 then begin U.Close; Free; end;     { EOF }
end;

procedure TEchoSocket.Writable(U: TUpgraded);
begin
  FOut.FlushTo(U);                            { TryWrite until empty or -EAGAIN }
end;
```

**(e) Inline benchmark endpoint** (no thread hop, no allocation, no refcount):

```pascal
const
  HELLO: array[0..12] of AnsiChar = 'Hello, world!';
  HN_CT: array[0..11] of AnsiChar = 'content-type';
  HV_TEXT: array[0..9] of AnsiChar = 'text/plain';
  HN_SRV: array[0..5] of AnsiChar = 'server';
  HV_SRV: array[0..4] of AnsiChar = 'wd-40';

procedure TPlaintext.Dispatch(X: TExchange);
begin
  X.ResponseHeaders.AddUnchecked(@HN_SRV, 6, @HV_SRV, 5);     { constants: validated by a unit test }
  X.ResponseHeaders.AddUnchecked(@HN_CT, 12, @HV_TEXT, 10);
  X.SendStatic(@HELLO, 13);
end;
```

---

## 4. Memory

### 4.1 Blocks and pools

```pascal
unit bearings.rt.buf;
type
  PBufBlock = ^TBufBlock;
  TBufBlock = record
    Data: PByte;          { 64-byte aligned }
    Cap: SizeInt;         { size class: 8 KiB, 16 KiB, ... 512 KiB; larger: exact, unpooled }
    Pins: LongInt;        { loop thread only }
    Owner: Pointer;       { the TBlockPool }
    NextFree: PBufBlock;
  end;

  TBlockPool = class      { one per loop; LIFO per size class (hot in cache) }
  public
    function Take(MinCap: SizeInt): PBufBlock;
    procedure Give(B: PBufBlock);           { if Pins = 0 }
    procedure Pin(B: PBufBlock); inline;
    procedure Unpin(B: PBufBlock); inline;  { gives back at 0 when detached from its buffer }
    procedure Trim(KeepBytes: SizeInt);     { called on idle loops: free cold blocks }
  end;
```

- All `Pin/Unpin` happen on the loop thread: a worker "releases" a slice by signalling the
  exchange; the loop unpins. No atomics on block refcounts.
- Large blocks (above 512 KiB; `max_buf_size` defaults to 417792) are allocated exactly and freed
  when released.

### 4.2 Zero-copy slices and their lifetimes

| slice | points into | valid until | who keeps it alive |
|---|---|---|---|
| request method, target, URI parts, header names/values | read block (head region) | the exchange is recycled | exchange pins the block at `RecvMsg`, unpins at recycle |
| request body chunk (`TryRead`/`ReadChunk`) | read block (body region) | next body call on X or X's terminal call | slot entry pins; released when the app takes the next or ends |
| request trailers | decoder-owned trailer buffer (M2 `TDecoder`) copied into the exchange's trailer list | exchange recycled | exchange |
| response headers | `ResponseHeaders` arena (exchange-owned, reused) | encode time | exchange |
| `SendStatic` data | caller's static memory | forever | caller |
| `SendString` / `WriteString` | RawByteString heap block | frame released after write | one reference held by the exchange/frame |
| `SendCopy`, `Write` data | exchange body buffer / stream ring | frame released after write | exchange / ring |
| upgrade leftover | read block | `ConsumeLeftover` / `Close` | `TUpgraded` pins |

Rule enforced by the read buffer: a pinned block is never compacted or reused; when the buffer
needs room it moves to a new block (copying only the unread tail, which is never lent out).

### 4.3 No refcount traffic on the hot path

- Transport routines take `PByte` + length; no `string`/`RawByteString`/dynamic-array parameters
  by value and no managed locals in `Drive`, `PollLoop`, `PollRead*`, `PollWrite`, `PollFlush`,
  `ParseHead`, `EncodeHead`, decoder/encoder calls. FPC inserts an implicit try/finally frame
  (a setjmp on Linux) in routines with managed locals; M2 already follows this rule for the parser
  and encoder.
- Check: the build of the hot units with `-al` and a script that fails if any listed routine's
  assembly contains `FPC_PUSHEXCEPTADDR` (run in the unit-test target).
- No threadvars on the hot path (2.74 ns each on x86_64-linux): the date pointer, pools and
  options come from the loop object.
- `THttpHeaders` objects are created once per exchange and `Clear`ed per request (M2 design:
  steady state with no allocation).
- `IsMultiThread` makes every AnsiString refcount operation `lock`-prefixed; the transport never
  touches AnsiStrings per request except `SendString`/`WriteString` (one increment, one decrement).

### 4.4 Per-connection memory budget

| item | bytes | when |
|---|---|---|
| `TTcpConn` + `TTcpIo` (fd, flags, ids, peer address) | ~120 | always |
| `TH1Dispatcher` + `TH1Conn` state (decoder, encoder, timer node, read/write buffer descriptors) | ~600 | always |
| `TExchange` incl. two `THttpHeaders` (16 entries each, response arena 1 KiB) | ~2700 | while a request is in progress; returned to the loop pool when the connection goes idle |
| read block | 8 KiB+ | only while unparsed/unconsumed bytes exist or a slice is pinned |
| head buffer block, Queue array | 8 KiB, ~1.6 KiB | only while bytes are unflushed |

Idle keep-alive connection: ~0.7 KiB. Busy connection between syscalls: ~3.4 KiB plus blocks that
are shared through the loop pool. hyper per connection, for comparison (not measured yet): a tokio
task with the connection future, an 8 KiB write `Vec` allocated at creation and the `BytesMut` read
buffer. The RSS comparison in 7.5 measures both.

---

## 5. Header value validation and trailer fixes

### 5.1 Validation boundary (fix for CR/LF/NUL)

hyper cannot put CR, LF or NUL on the wire because `http::HeaderValue::from_bytes` rejects bytes
below 0x20 except HTAB, and 0x7F; `HeaderName` accepts only tokens. `THttpHeaders` accepts anything.
The boundary moves into `THttpHeaders` itself, because every path that adds response headers or
trailers goes through its mutators:

```pascal
type
  THeaderFieldError = (hfeNone, hfeName, hfeValue);
  EInvalidHeader = class(Exception)
  public
    Field: THeaderFieldError;
  end;

  THttpHeaders = class
  public
    { Validating (http::HeaderName::from_bytes + HeaderValue::from_bytes rules,
      i.e. IsValidHeaderName / IsValidHeaderValue from M2). Raise EInvalidHeader. }
    function Add(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt; overload;
    function Add(const Name, Value: RawByteString): SizeInt; overload;
    function Append(const Name, Value: RawByteString): SizeInt;
    procedure Insert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure Insert(const Name, Value: RawByteString); overload;
    procedure SetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure SetValue(I: SizeInt; const Value: RawByteString); overload;
    { Same without raising. }
    function TryAdd(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderFieldError;
    function TryInsert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderFieldError;
    { No validation: for bytes that are valid by construction (parser output, nghttp2,
      copies from another validated list, constants covered by a unit test). }
    function AddUnchecked(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
    procedure InsertUnchecked(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
    function AddExternal(NameOfs, NameLen, ValueOfs, ValueLen: SizeInt): SizeInt;   { unchanged }
    ...
  end;
```

- The cost is one scan of the value per `Add` (the same work `HeaderValue::from_bytes` does);
  the scanner is a candidate for the SSE4.2 work already planned for the parser.
- Internal M2 callers: `AddChunked` and `SetContentLengthIfMissing` add constant/derived valid
  bytes (switch to `AddUnchecked`); the trailer decoder's `ParseTrailers` adds httparse-validated
  fields (switch to `AddUnchecked`). Any M2 unit test that inserts invalid bytes on purpose moves
  to `AddUnchecked` and gets a twin test asserting the validating method raises.
- Reason phrase: `TReasonPhrase.TryFrom` already validates (M2).
- Defence in depth: with `-Sa` (assertions, used by the test builds), `EncodeHead` and the trailer
  encoder assert `IsValidHeaderName`/`IsValidHeaderValue` for every field they write.

### 5.2 Trailer encoding deviations and fixes

Found by reading `TEncoder.EncodeTrailers` / `MakeEncoder` against `encode.rs` `encode_trailers`,
`role.rs` 868-998 and `conn.rs` `write_trailers`/`end_body`. (The brief mentions three; see open
question 1.)

| # | hyper | M2 today | wire effect | fix |
|---|---|---|---|---|
| T1 | `allowed_trailers` is a `HeaderMap`; `write_headers` emits values grouped by name in order of first appearance | `EncodeTrailers` writes the list in list order | `a: 1`, `b: 2`, `a: 3` (append semantics) is written `a,b,a` instead of `a,a,b` | walk the list grouped by name (same `Done`-flag walk `EncodeHead` uses for `HeaderMap::drain` order) |
| T2 | trailer values are `HeaderValue`s: no CR/LF/NUL possible | raw bytes copied | header injection through trailers | 5.1 boundary + assertion in the encoder |
| T3 | `write_trailers` (conn.rs 756-779): nothing unless the request had `TE: trailers` (`allow_trailer_fields`); when `encode_trailers` returns `None` the state stays `Body`, and the body end then goes through `end_body` (`0\r\n\r\n`, or `NotEof` for a short `Length` body); after trailers, `Closed` if `is_last` or close-delimited, else `KeepAlive` | `EncodeTrailers` has no conn context (there is no conn yet) | `http1_trailer_fields_not_allowed` and the keep-alive cases depend on it | `TH1Conn.WriteTrailers` ported literally; unit tests per branch (7.2) |
| T4 (not wire) | encodes into the shared write buffer | returns a new `TBytes` per call (`out Dst: TBytes`) | allocation per trailer section | change the signature to `procedure EncodeTrailers(Trailers: THttpHeaders; TitleCase: Boolean; var Dst: TBytes; var DstLen: SizeInt; out Written: Boolean)`, like `ServerEncode` |

The `role_diff` differential test inserts unique trailer names with valid values, which is why T1
and T2 are not caught there; the fix adds those inputs to the generator (duplicate names, appended
non-adjacent).

---

## 6. The Pascal conformance server

Location: `conformance/pascal-server/` (test tooling, next to `reference-server/`):
`wdconf.pas` (program), `wdconf.spec.pas` (JSON spec parsing with fcl-json, validation, exit 2 on
errors), `wdconf.events.pas` (JSON line emitter, latin-1 byte strings, one `write` per line under a
mutex), `wdconf.handlers.pas` (service, per-request script, script body, upgrade task),
`wdconf.control.pas` (stdin thread).

Defaults: one loop (`--loops 1`, so accept order = connection numbering), inline execution.
Variants used by the test plan: `--exec worker` (test_service runs as a `TWorkerHandler` with real
`Sleep`), `--loops 4`.

### 6.1 Process protocol (SPEC 3)

| SPEC | implementation |
|---|---|
| `--config <path>` | read file, parse, validate; on error print to stderr, exit 2 before `LISTENING` |
| bind `127.0.0.1:0`, `LISTENING <port>` | `TServer.Start` then print + flush |
| connections numbered 1, 2, ... | `TConnObserver.ConnOpened(ConnId)` |
| stdout events, atomic lines | emitter: build the line in a local buffer, `fpWrite` once under a mutex |
| `graceful_shutdown` | control thread posts a `TLoopWork` to every loop; each applies `TH1Dispatcher.GracefulShutdown` to its connections; the last loop emits `control_ack` (after every connection was notified) |
| `signal <name>` | posted to loop 0: set the latch, release waiting upgrade tasks, then emit the ack |
| `exit` / stdin EOF | `fpExit(0)` (no thread joins) |
| other lines | `control_error` |

### 6.2 `config` (SPEC 4), field by field

| field | maps to |
|---|---|
| `keep_alive` | `TH1Options.KeepAlive` (false -> `DisableKeepAlive` at connection start, as `serve_connection` does) |
| `half_close` | `HalfClose` |
| `title_case_headers` | `TitleCaseHeaders` |
| `preserve_header_case` | `PreserveHeaderCase` (accepted; no wire effect, SPEC allows this) |
| `max_headers` | `MaxHeaders` |
| `max_header_size` | `MaxHeaderSize` |
| `max_buf_size` | `MaxBufSize`; `< 8192` -> config error |
| `timer` | spec-level flag only: our loop always has a timer |
| `header_read_timeout_ms` | absent: `30000` if `timer` else `-1`; `null`: `-1`; number with `timer` false: config error |
| `writev` | `WriteStrategy` (`true` -> `wsQueue`, `false` -> `wsFlatten`, absent -> `wsAuto`) |
| `pipeline_flush` | `PipelineFlush` |
| `auto_date_header` | `AutoDateHeader` |
| `ignore_invalid_headers` | `ParserConfig.IgnoreInvalidHeadersInRequests` |
| `allow_multiple_spaces_in_request_line_delimiters` | `ParserConfig.AllowMultipleSpacesInRequestLineDelimiters` |
| `conn_mode` | `ConnMode` (`plain`, `with_upgrades`, `without_shutdown`) |
| `graceful_shutdown_on_accept` | `GracefulShutdown` called in `ConnOpened` before the first `Drive` |
| `bytes_read_events` | the observer's `BytesRead` emits the event (called by `TH1Io.PollReadFromIo` after the bytes are in the buffer, before parsing) |

### 6.3 Handlers (SPEC 5.1) and the test_service sequence (SPEC 5.5)

`TConfService.Dispatch(X)` emits `request` (method, target, version, headers lowercased and grouped
by first appearance, computed from `X.Headers` which keeps wire order), assigns `req`, then:

| handler | implementation |
|---|---|
| `hello_world` | `X.SendStatic('hello', 5)`; emit `handler_done` (response, 200). Never reads; the body receiver closes when `Dispatch` returns (hyper drops the request in `call`) |
| `unreachable` | `X.Fail('request shouldn''t be received')`; emit `handler_done` (error) |
| `test_service` | a pooled `TScriptRequest` (a `TExchangeListener` holding per-request state) runs the steps below |

`TScriptRequest`, step by step (SPEC 5.5):

1. `request` already emitted.
2. Take the next reply from the shared queue (a mutex-protected list; one queue per process).
3. `upgrade.on_upgrade` true: `X.OnUpgrade(TUpgradeTask.Create(Spec))` now.
4. `read_body` true: `X.Listen(Self)`, then `TryRead` in a loop, appending data to a local `TBytes`;
   `brPending` waits for `BodyReady`; `brTrailers` copies `X.RequestTrailers`; `brEnd` emits
   `request_body` (with `trailers` if the request had any); `brError` emits `request_body_error`
   (`kind`, `message` from `X.BodyErrorKind/Message`, M2 `DecodeErrorKind/Message` give hyper's text)
   and `X.Fail('req body error')`.
5. `X.DiscardBody` (release the request).
6. `delay_ms > 0`: `X.SetTimer(delay_ms, 0)`; continue in `TimerFired`.
7. `error`: `X.Fail(error)`, emit `handler_done` (error).
8. `upgrade` with `on_upgrade` false: store the spec in a per-connection slot read by `ConnParts`.
9. Respond: `X.Status`, `X.SetReason`, `X.ResponseVersion` (`HTTP/1.0` -> `hv10`, `HTTP/1.1` -> `hv11`,
   `HTTP/2.0` -> `hv2`, `HTTP/0.9`/`HTTP/3.0` -> `hv09`/`hv3`: role raises like hyper panics; the
   cases do not use them), headers with `X.ResponseHeaders.Insert` (insert semantics, order kept),
   body per 6.4; emit `handler_done` (response, status).

`Canceled(X)` (the dispatcher canceled before step 9 or 7): cancel the timer, emit
`handler_dropped`. Because the dispatcher calls it during teardown, it precedes `conn_close`.
In `--exec worker` mode the same steps run in `Execute` with blocking `ReadChunk` and `Sleep`; the
loop emits `handler_dropped` when it cancels (that is the moment the HTTP layer abandons the
handler), and the worker's later terminal call is a no-op.

### 6.4 Bodies (SPEC 5.4)

| spec | implementation |
|---|---|
| absent | `X.SendEmpty` (`Empty`: `IsEndStream` True) |
| `{"known": b}` | `X.SendStatic(reply bytes)` (reply objects live for the process); empty -> `SendEmpty` |
| `{"stream": [...], "trailers": [...]}` | `X.SendBody(TScriptBody)`: a loop-side `TBody` with `SizeHint` = unknown and `IsEndStream` always False (like `StreamBody`), so the end goes through `end_body` exactly as in hyper |
| item `data`, `delay_ms`, `times` | `PollFrame`: if the item has a delay and its timer has not fired, arm `X.SetTimer(delay, ItemIndex)`, return `pfPending`; `TimerFired` signals `sigStreamData`; then return the frame (each repetition separately) |
| item `error` | after the delay, `pfError` with the message (hyper: body error -> connection aborted, chunked left open) |
| `trailers` | after the last item, one `fkTrailers` frame built with `Insert`; then `pfEnd`. Whether they reach the wire is `TH1Conn.WriteTrailers`' decision (5.2 T3) |

### 6.5 Connection modes, upgrades (SPEC 6)

| SPEC | implementation |
|---|---|
| `plain` | `cmPlain`; a registered `OnUpgrade` handler gets `UpgradeFailed('manual upgrade')` -> `upgrade_error` |
| `with_upgrades` | `cmWithUpgrades`; at `is_done` with a pending upgrade the dispatcher emits `conn_close` (`ok`), then calls `TUpgradeTask.Upgraded(U)` |
| `without_shutdown` | `cmWithoutShutdown`; when the HTTP layer finishes without error the socket is not shut down; `conn_close` then `ConnParts(U)`; if the connection slot holds an `on_upgrade: false` spec, run the task on `U`, else `U.Close`. On error: close and `conn_close` only (reference server does the same) |
| upgrade task | `TUpgradeTask` (a `TRawListener`): emit `upgraded` (`read_buf` = `U.Leftover`), wait for the latch (`await_signal`), `TryWrite` the bytes (wait `Writable` on short writes), read to EOF with `Readable` callbacks, emit `upgrade_read` (`eof` or `error` + message), close. Reads here do not emit `bytes_read` (the observer is not involved) |
| graceful shutdown semantics (6.2) | `TH1Dispatcher.GracefulShutdown` (1.8); no effect after a hand-off because the dispatcher no longer exists |

### 6.6 Events (SPEC 7)

| event | emitted by |
|---|---|
| `conn_open` | `ConnOpened` (before the first read) |
| `request` | `TConfService.Dispatch` |
| `request_body`, `request_body_error` | `TScriptRequest` |
| `handler_done` | at the terminal call (`Send*`/`SendBody` -> response; `Fail` -> error) |
| `handler_dropped` | `TExchangeListener.Canceled` |
| `conn_close` | `ConnClosed` with `OutcomeOf(FError)` and `detail` = error text |
| `bytes_read` | `BytesRead` |
| `upgraded`, `upgrade_read`, `upgrade_error` | `TUpgradeTask` |
| `control_ack`, `control_error` | control handling (6.1) |

---

## 7. Test plan

### 7.1 Port of hyper io.rs unit tests (the 9 compiled, live tests)

`tests/unit/test_h1_io.pas`, with `TMockIo` (scripted reads: bytes / `-EAGAIN` / EOF; recorded
writes; a switch for `IsWriteVectored`; a per-call write limit).

| hyper test | Pascal test |
|---|---|
| `parse_reads_until_blocked` (client head in hyper) | server variant: reads `GET / HTTP/1.1\r\n`, `Host: x\r\n`, then `-EAGAIN`; `ParseHead` returns `pPending` and the buffer holds both reads |
| `read_strategy_adaptive_increments` | `TReadStrategy`: 8192 -> 16384 -> 32768 -> 65536 (`Record(High(SizeInt))` doubles once), then to max, `Record(max+1)` stays |
| `read_strategy_adaptive_decrements` | the 7-step sequence from the catalog |
| `read_strategy_adaptive_stays_the_same` | 8192, 8193, 8193 -> 16384 |
| `read_strategy_adaptive_max_fuzz` | max from 8192, x1.5 saturating, to `High(SizeInt)`; power-of-two invariant |
| `write_buf_requires_non_empty_bufs` | `Buffer` of an empty frame raises `EAssertionFailed` (`-Sa` build) |
| `write_buf_flatten` | head `hello ` + 3 frames, 0 queued, one write `hello world, it's hyper!` |
| `write_buf_flatten_partially_flushed` | cursor `Pos`/capacity checks and the `MaybeUnshift` compaction |
| `write_buf_queue_disable_auto` | Queue with a non-vectored IO writes `hello `, `world, `, `it's `, `hyper!` in order |

Plus the ignored/disabled ideas: an empty flush makes no write call (`iobuf_write_empty_slice`);
one `writev` for head + 3 queued frames (`write_buf_queue`).

### 7.2 Conn and dispatcher unit tests

`tests/unit/test_h1_conn.pas`, `test_h1_dispatch.pas`, over `TMockIo`, a fake clock and a scripted
inline service:

- hyper conn.rs server tests: `conn_reads_request_head`, `conn_reads_partial_request_head`,
  `conn_accepts_eof_when_idle`, `conn_rejects_eof_during_partial_head`,
  `server_accepts_eof_while_busy`, `conn_reads_body_and_reports_end`,
  `closed_conn_cannot_read_or_write`, `conn_writes_chunked_body`.
- `body_empty_chunks_ignored` (server form: an empty data frame produces no chunk).
- `h1_flush_before_yield`: body yields data, then `pfPending` with no wake, then end; the
  terminator must be flushed.
- `h1_shutdown_while_buffered`: IO accepts 212992 bytes then blocks; `ShutdownWrite` must not be
  called while bytes are buffered.
- state table: every `(TReading, TWriting, TKeepAlive)` reachable combination x event
  (head, body chunk, body end, response head, body frame, flush, EOF, graceful shutdown, timer),
  compared with a reference table derived from conn.rs (written once by hand, reviewed against the
  Rust code).
- Expect/continue: no 100 if the handler responds without reading; 100 exactly once on first read;
  none for HTTP/1.0 or empty bodies.
- trailers: each branch of `WriteTrailers` (5.2 T3) and T1 ordering.
- pipelining: 16 requests in one read produce one write with `PipelineFlush`, budget yields
  after 16 iterations.
- cancellation: EOF while a worker handler is parked in `Read`/`Write` wakes it with
  `EClientGone`/`wrCanceled`; the exchange is recycled only after `Release`.
- exchange/channel: TryRead/want/slot semantics against chan.rs cases (`error_queued_behind_accepted_data`,
  `trailers_follow_data_close`).

Reactor tests (`test_loop.pas`, `test_timer.pas`, `test_mpsc.pas`): timer wheel against a brute-force
sorted list with random arm/extend/cancel/advance; MPSC with 8 producers x 10^7 pushes; wake latency;
an ET test where FIN arrives in the same window as data (risk R3).

### 7.3 The 105 wire cases

From `conformance/`:

```sh
cargo build --release
fpc ... -o../build/conformance/wdconf pascal-server/wdconf.pas
# assertion mode, each variant
target/release/runner run --server '../build/conformance/wdconf' cases/h1
target/release/runner run --server '../build/conformance/wdconf --exec worker' cases/h1
target/release/runner run --server '../build/conformance/wdconf --loops 4' cases/h1
# diff mode against hyper
target/release/runner diff --a target/release/reference-server --b '../build/conformance/wdconf' cases/h1
```

Gate: `SUMMARY passed=104 failed=0 pending=1` in 3 consecutive runs per variant, and
`same=104 different=0` in diff mode for the default variant. The worker variant must pass
assertion mode; diff differences there are reviewed one by one (expected: none on the wire;
events may differ only in documented timing).

### 7.4 Fuzz and soak

- Connection-level differential fuzzer (Rust, test tooling): `conformance/fuzz-h1/` generates
  random server specs (from the SPEC option space) and random client byte streams (valid requests,
  M2 corpora mutations, pipelining, random split points and pauses, half-close, abrupt close), writes
  them as case files and runs the runner's diff mode against both servers. Runs nightly; every
  difference is minimized into a new case.
- Coverage-guided: AFL++ in QEMU mode on a harness that feeds stdin bytes with random split points
  into `TH1Dispatcher` over `TMockIo` and an inline service; checks invariants (no exception
  escapes, the output parses as HTTP/1 responses, state machine assertions with `-Sa`).
- Memory: the conformance suite and the unit tests under valgrind memcheck and with FPC `-gh`
  (heaptrc) for leaks; helgrind/drd on the worker-variant stress test.
- Soak (24 h): wrk at 50 % of max rate + a chaos client (random disconnects mid-head/mid-body,
  slowloris, half-close, pipelining bursts, oversize heads, upgrades) against a server with inline
  and worker routes. Sampled every 10 s: VmRSS, open fds, live connections, pool sizes, worker
  queue. Pass: RSS and fds flat after warm-up, zero stall-detector reports, zero crashes.

### 7.5 Performance measurement

- hyper: TFB `frameworks/Rust/hyper` with `hyper` pinned to 1.12.0 rev 7f67699 (Cargo `[patch]`),
  `--runtime current-thread --threads N`, `pipeline_flush(true)`, no timer. Release build,
  `lto = true`, `codegen-units = 1` as in its Cargo.toml.
- wd-40: `bench/wdbench.pas`, `N` loops, `PipelineFlush` true, no header timeout, the inline
  plaintext service of 3.10(e). The responses are byte-identical except the server name, which has
  the same length: hyper's TFB `SERVER_HEADER` is `hyper` (5 bytes), ours is `wd-40` (5 bytes). Header
  order is the same (`server`, `content-type`, `content-length`, `date`).
- One box, 16 CPUs: server on CPUs 0-7 (`taskset`, N = 8), wrk on CPUs 8-15 (`-t8`). Check that wrk
  stays below 90 % CPU; if not, the run is invalid (client-bound) and is repeated with fewer server
  CPUs. A second matrix with all 16 CPUs shared is reported for information.
- Matrix: {256, 1024} connections x {no pipelining, pipelining depth 16 (TFB `pipeline.lua`)}.
  10 s warm-up, 5 runs x 30 s, report the median requests/s and the ratio to hyper; p50/p99 from
  `wrk --latency` (non-pipelined runs); peak and steady VmRSS/VmHWM from `/proc/<pid>/status`.
- Gate (M3.7): ratio >= 0.80 in all four cells; p99 and RSS targets as confirmed (assumption 6).
- Profiling: `perf record -g` on both servers in the pipelined 256 cell; compare cycles per request
  in parse, encode, syscalls.

---

## 8. Layout, milestones, risks

### 8.1 Files under `src/`

```
src/
  sys/
    wd.sys.linux.pas      raw syscall stubs returning -errno (inline asm `syscall`; avoids FPC's
                          seterrno threadvar), constants (EPOLL*, SOCK_*, SO_REUSEPORT, ...),
                          epoll, accept4, eventfd2, futex, sendfile, writev, shutdown,
                          sched_get/setaffinity
    wd.sys.clock.pas      libc clock_gettime (vDSO)
    wd.sys.cpu.pas        affinity count, cgroup limit, pinning
    wd.sys.sync.pas       TLoopWork, TMpscQueue, TParker, AtomicOr
  rt/
    bearings.rt.timer.pas       TTimerWheel, TTimerNode, TTimerTarget
    bearings.rt.buf.pas         TBufBlock, TBlockPool, TByteCursor
    bearings.rt.loop.pas        TLoop, TPollable, TDeferred
    bearings.rt.net.pas         TListener, TTcpConn, TConnIo, TTcpIo, TUpgraded, TRawListener
    bearings.rt.workers.pas     TWorkerPool, TWorkerHooks
    bearings.rt.server.pas      TServer, TServerOptions
  http/
    bearings.http.outcome.pas   TH1Error, TConnOutcome, TConnObserver
    bearings.http.body.pas      TFrame, TBody, TEmptyBody, TBytesBody, TFileBody, TStreamBody
    bearings.http.exchange.pas  TExchange, THttpService, TWorkerHandler, TExchangeListener,
                          TUpgradeHandler, TStreamOwner, TExchangePool
  http1/                  (M2 units stay here unchanged in name and place)
    bearings.http1.options.pas  TH1Options
    bearings.http1.io.pas       TReadStrategy, TReadBuf, TWriteBuf, TH1Io        (io.rs)
    bearings.http1.conn.pas     TH1ConnState, TH1Conn                           (conn.rs)
    bearings.http1.dispatch.pas TH1Dispatcher, TBodySender                      (dispatch.rs, chan.rs)
  http2/  (M4)            bearings.http2.nghttp2.pas (binding), bearings.http2.session.pas (TH2Session)
  tls/    (later)         wd.tls.openssl.pas (TTlsIo, ALPN)
  web/    (M5)            wd.web.request, wd.web.response, wd.web.controller, wd.web.router,
                          wd.web.form, wd.web.multipart, wd.web.session, wd.web.app
tests/unit/               test_h1_io, test_h1_conn, test_h1_dispatch, test_exchange,
                          test_loop, test_timer, test_mpsc, test_buf, test_headers_validate
conformance/pascal-server/ wdconf*.pas
conformance/fuzz-h1/      Rust differential fuzzer
bench/                    wdbench.pas, wrk scripts, hyper TFB patch, run-matrix.sh
```

`THttpVersion`/`THttpMethod` currently live in `bearings.http1.role`; they move to a protocol-neutral
`bearings.http.types` (role re-exports them) when HTTP/2 starts. Not needed for M3.

### 8.2 Implementation order

Each step ends with a check that can be run.

| step | content | verified by |
|---|---|---|
| M3.1 | `wd.sys.*`, `bearings.rt.timer`, `bearings.rt.buf`, `bearings.rt.loop`, `bearings.rt.net` (listener, `TTcpIo`), `bearings.rt.server` without HTTP | unit tests (timer vs brute force, MPSC stress, pools); an echo server with 1000 connections and random sizes under valgrind; probes for every syscall stub |
| M3.2 | `bearings.http1.io` | the 9 io.rs tests + 2 extra (7.1) |
| M3.3 | header validation (5.1), trailer fixes (5.2), `bearings.http.body`, `bearings.http.exchange` (inline only), `bearings.http1.conn`, `bearings.http1.dispatch` | 7.2 tests; M2's 506 tests still pass; role_diff with the new trailer inputs; **early perf check**: inline plaintext, 1 loop vs hyper 1 thread, pipelined and not; gate >= 0.60 (structural problems show here, before the remaining work) |
| M3.4 | conformance server, inline mode | 7.3 gate (104 pass, diff same=104) |
| M3.5 | worker pool, blocking body/stream API, cross-thread streams, cancellation | `--exec worker` passes 104; cancellation stress under helgrind; unit tests for park/unpark races |
| M3.6 | upgrades (attach and detach), sendfile, server graceful shutdown, multi-loop, `cpAuto` sniffing stub | `--loops 4` passes 104; sendfile tests (known length, chunked around a file frame, partial sendfile); shutdown test with in-flight requests |
| M3.7 | performance work and soak | 7.5 matrix gate; 7.4 soak and fuzz clean |

### 8.3 Risks

| # | risk | mitigation |
|---|---|---|
| R1 | use-after-free or races on `TExchange` across loop and worker | one owner thread per object; signals only through `FSignals` + inbox; the worker never touches the connection; refcount with `FShared`; helgrind/drd stress; debug builds poison recycled exchanges |
| R2 | lost wakeups (a `Pending` with nothing armed) hang a connection | invariant assertion at `Drive` exit (2.3), stall detector, soak test |
| R3 | edge-triggered readiness: clearing `ReadReady` on a short read could miss an EOF | Linux re-reports the socket when a FIN arrives after `epoll_wait` returned it (the wakeup callback re-queues it); a dedicated test sends data+FIN in one segment and in two; the short-read optimization is a compile-time switch, off if the test ever fails |
| R4 | FPC code generation reaches less than 80 % of hyper | early perf gate at M3.3; no managed locals in hot routines (asm check); SSE4.2/AVX2 scanners for parser and header validation; Flatten fast path for small responses; `perf` comparison per stage |
| R5 | blocking work accidentally on a loop (inline handler, cold `sendfile` from disk) | inline is opt-in per route; debug watchdog logs inline callbacks longer than 10 ms; `SendFile` from M5 issues `posix_fadvise(WILLNEED)` on the worker; large cold files can be streamed by the worker instead |
| R6 | worker pool saturation (slow DB) piles up requests | HTTP/1 serial processing bounds the queue by connections; `TWorkerPool.Pending` lets the router answer 503 inline above a limit; per-route inline/worker choice |
| R7 | `SO_REUSEPORT` imbalance or reset of queued connections on shutdown | `amSharedExclusive` option; drain-accept before closing listeners |
| R8 | exceptions crossing the boundary (application code raising into the loop) | `Dispatch` and listener calls are wrapped in a cold try/except in the dispatcher that turns an exception into `Fail` and logs it; worker `Execute` likewise |
| R9 | cross-thread frees in FPC's per-thread heap | pools return objects to their home loop; stream rings come from a global pool, not freed cross-thread |
| R10 | the conformance worker variant's event timing differs from hyper | inline mode is the oracle-equivalent variant; worker mode is checked in assertion mode and its diff reviewed |
| R11 | HTTP/2 needs changes to the exchange | section 3.8 mapping done now; `TStreamOwner` abstraction; the h2 body path copies (nghttp2 buffers are transient), so no read-block pinning assumption leaks into the API |
