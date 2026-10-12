# M3 design candidate: performance first

> Written while this code was part of wd-40 (where "wd-40" in the text means the project of that time). The unit names were changed to `bearings.*` when the transport moved to this repository; commit hashes refer to the wd-40 history.

Status: candidate design for milestone M3 (event loop, HTTP/1 connection engine, service API,
Pascal conformance server). The angle is throughput, latency and memory, with conformance to
hyper 1.12 kept as a hard requirement.

Every performance claim in this document is either measured on this machine (section 1, raw
numbers in the tables) or marked as an estimate. The prototypes and scripts are in
`scratchpad/m3-perf-proto/` (paths in Appendix A).

Contents

0. Summary, assumptions, open questions
1. Measurements and the decisions they support
2. Threading and reactor
3. Connection state machine (port of conn.rs, dispatch.rs, io.rs)
4. Service API (no closures) and how M5 sits on it
5. Memory
6. Header value validation boundary and trailer fixes
7. The Pascal conformance server, SPEC item by SPEC item
8. Test plan
9. Unit layout, implementation order, risks

Appendix A: prototype files and how to reproduce the numbers

---

## 0. Summary, assumptions, open questions

### 0.1 Summary

- One event loop thread per usable CPU. Each loop owns an epoll instance, an eventfd for
  cross-thread wakeups, a hierarchical timer wheel, a buffer pool and all its connections.
  Nothing on the request path is shared between loops.
- Accept: one `SO_REUSEPORT` listener per loop (default, like hyper's TFB entry). A shared
  listener with `EPOLLEXCLUSIVE` is a config option. Measured: no throughput difference.
- Connections: edge-triggered `EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET`, registered once, never
  modified. Readiness is cached per connection (like mio/tokio) so the engine never makes a
  syscall that is known to return `EAGAIN`.
- HTTP/1: `Buffered`, `Conn` and `Dispatcher` are ported function by function from hyper
  (`io.rs`, `conn.rs`, `dispatch.rs`), as poll-style routines that return `Ready`/`Pending`. The
  16-iteration poll budget, `pipeline_flush`, the write strategies, the adaptive read size and
  the lazy `100 Continue` are kept exactly.
- Service API: a request is a `TExchange` object. The handler is called on the loop thread. It
  can answer at once (fast path, no allocation, no atomics), answer later from a loop timer or
  callback, or call `Ex.Offload` to continue on a blocking worker pool. Proper-style
  synchronous controllers (database calls) run on the worker pool. Bodies are pull sources
  (`TBodySource.PollFrame`, the shape of hyper's `Body::poll_frame` and of nghttp2's data
  provider) or push sinks; both have backpressure.
- Memory: request heads are parsed in place (slices into the read buffer, as now). Read and
  write buffers come from a per-loop pool and go back to it when a connection is idle. Hot
  routines have no managed locals (an implicit exception frame costs 19.5 ns per call, measured).

Headline measurements (section 1): a prototype of this loop design that uses the real M2 parser
and encoder serves TFB plaintext at **105-110 % of hyper 1.12** when the server is the
bottleneck, and at 97-112 % in the 8-CPU configuration the brief asked for. Idle connections
cost **1.7 KB** each with buffer pooling, against 10.7 KB for hyper. Handing every request to a
blocking worker pool halves non-pipelined throughput and cuts pipelined throughput to 18-38 %
(depending on pool size), so the plaintext benchmark path must run on the loop thread.

### 0.2 Assumptions (stated, not verified with the user)

1. "16-core Linux box" is this machine: Intel Core i5-14400, 6 P-cores (CPUs 0-11 with SMT) plus
   4 E-cores (CPUs 12-15, max 3.5 GHz), 16 logical CPUs, 62 GiB, kernel 7.0.0. The brief's split
   "server on 0-7, wrk on 8-15" gives the server 4 P-cores with SMT and gives wrk 2 P-cores plus
   all 4 E-cores. In that split the non-pipelined runs are limited by the client and the kernel,
   not by the server (both servers score the same, section 1.3). I therefore also report a
   server-bound split (server on 0-3, wrk on 4-15) and a CPU-normalized metric (requests per
   server CPU-second). The performance gate (section 8.6) uses all three.
2. "≥ 80 % of hyper" is checked per cell (256/1024 connections × depth 1/16), not as an
   average.
3. "p99 latency" is compared at depth 1. wrk prints `99% 0.00us` for several pipelined runs
   (a known wrk histogram problem when one write carries 16 requests), so pipelined p99 is not
   reliable with wrk. Section 8.6 adds wrk2 at fixed rates for latency.
4. "RSS" means resident set size of the server process, measured mid-run under load and with
   10 000 idle keep-alive connections.
5. hyper's defaults are the conformance contract. wd-40's own production defaults may differ
   where the difference is not visible in bytes on the wire (example: `pipeline_flush` on by
   default, section 3.7). Every such difference is listed in section 3.10.

### 0.3 Open questions for the user

1. Production default for `pipeline_flush`: hyper's default is `false`; measured cost of `false`
   with depth-16 pipelining is 4× lower throughput (section 1.3, table T4). This design proposes
   `true` as wd-40's default and `false` only when the conformance server asks for hyper's
   default. Is a default that differs from hyper acceptable?
2. Where Proper controllers run by default (section 4.8): this design proposes "worker pool by
   default, `inline` opt-in per route". The alternative (inline by default) is faster but one
   blocking call in a controller stalls every connection of that loop.
3. The brief says the M2 trailer encoder "deviates from role.rs in 3 ways". I did not find that
   list in the repository. Section 6.2 lists the deviations I found by reading the code; please
   check them against the M2 list.

---

## 1. Measurements and the decisions they support

### 1.1 Setup

| item | value |
|---|---|
| CPU | i5-14400, 6P+4E, 16 logical CPUs, governor `powersave` (intel_pstate) |
| kernel | Linux 7.0.0-38-generic |
| load generator | wrk `a211dd5`, built in `scratchpad/vendor/wrk` |
| wrk script | TFB `pipeline.lua` (depth argument), TFB headers: `Host: tfb-server`, the TFB `Accept` line, `Connection: keep-alive` |
| runs | 2 s warm-up, then 10 s per cell, `--latency` |
| hyper baseline | `scratchpad/m3-perf-proto/hyper-tfb`: TFB `frameworks/Rust/hyper/src/main.rs` with the DB routes removed; hyper pinned to rev `7f67699` (1.12.0, same as the conformance oracle), tokio 1.53.2, hyper-util 0.1.21; one current-thread runtime per thread, `SO_REUSEPORT`, `TCP_NODELAY`, backlog 4096, `pipeline_flush(true)`, LTO, codegen-units 1. Response bytes are identical to the prototype's (checked with `cmp`, date normalized) |
| prototype | `scratchpad/m3-perf-proto/loop/wdproto.pas`, FPC 3.2.2 `-O3`, uses the M2 units unchanged: `ServerParse` (with `THttpHeaders` external slices), `ServerEncode`, `TEncoder.Encode` |
| metrics | Requests/sec; wrk p50/p99; server CPU seconds from `/proc/<pid>/stat` (utime+stime); RSS from `ps` in the middle of the run |

The prototype implements the loop design of section 2 for the plaintext path only: per-loop
epoll, edge-triggered sockets registered once, read until short read, parse and answer every
buffered request, then one write (hyper's `pipeline_flush(true)` behaviour). It has no request
bodies, no keep-alive state machine, no timers and no service layer. Its numbers are an upper
bound for the transport cost, not a promise for M3. Section 1.4 turns them into a per-request
budget.

### 1.2 Results

**T1. Configuration A (the brief's split): server on CPUs 0-7 (8 threads), wrk on 8-15 (8 threads)**

| server | c | depth | req/s | p50 | p99 | server CPU-s / 10 s | req per CPU-s | RSS KB |
|---|---|---|---|---|---|---|---|---|
| hyper | 256 | 1 | 1 198 324 | 105 us | 255 us | 71.6 | 168 778 | 7 288 |
| hyper | 256 | 16 | 6 300 583 | 383 us | (wrk 0.00) | 80.8 | 787 572 | 8 292 |
| hyper | 1024 | 1 | 1 130 511 | 410 us | 1.11 ms | 70.0 | 163 842 | 16 224 |
| hyper | 1024 | 16 | 5 769 340 | 1.55 ms | 3.14 ms | 80.1 | 721 167 | 21 592 |
| wdproto | 256 | 1 | 1 179 032 | 103 us | 263 us | 67.4 | 175 974 | 8 380 |
| wdproto | 256 | 16 | 6 687 141 | 348 us | (wrk 0.00) | 80.7 | 835 892 | 10 232 |
| wdproto | 1024 | 1 | 1 094 973 | 414 us | 1.13 ms | 64.4 | 171 089 | 20 160 |
| wdproto | 1024 | 16 | 6 275 380 | 1.66 ms | (wrk 0.00) | 80.0 | 784 422 | 22 252 |
| wdproto POOL=1 | 256 | 1 | 1 189 190 | 103 us | 256 us | 68.1 | 174 880 | 5 572 |
| wdproto POOL=1 | 256 | 16 | 6 796 241 | 401 us | (wrk 0.00) | 80.8 | 849 530 | 5 596 |
| wdproto POOL=1 | 1024 | 1 | 1 143 633 | 403 us | 1.06 ms | 66.0 | 175 943 | 6 580 |
| wdproto POOL=1 | 1024 | 16 | 6 454 070 | 1.38 ms | 2.78 ms | 80.0 | 806 758 | 4 832 |

A first hyper run gave 1 192 546 / 6 197 672 / 1 127 358 / 5 780 011 req/s (same order as the
table). Ratio wdproto / hyper in configuration A: 0.98 / 1.06 / 0.97 / 1.09 (plain prototype),
0.99 / 1.08 / 1.01 / 1.12 (with buffer pooling). In the depth-1 cells both servers use only 6.4-7.2
of their 8 CPUs, so the client side (wrk on 2 P-cores + 4 E-cores, plus the loopback TCP stack)
sets the limit. Configuration A cannot rank the servers at depth 1.

**T2. Configuration B (server-bound): server on CPUs 0-3 (4 threads), wrk on 4-15 (12 threads)**

| server | c=256 d=1 | c=256 d=16 | c=1024 d=1 | c=1024 d=16 |
|---|---|---|---|---|
| hyper (run 1) | 678 986 (p99 421 us) | 3 127 171 | 629 074 (p99 1.77 ms) | 2 950 866 (p99 5.86 ms) |
| hyper (run 2) | 679 772 (p99 431 us) | 3 091 180 | 628 941 (p99 1.77 ms) | 2 858 551 (p99 6.21 ms) |
| wdproto | 715 101 (p99 385 us) | 3 339 184 | 678 873 (p99 1.56 ms) | 3 179 399 |
| wdproto POOL=1 | 715 873 (p99 376 us) | 3 380 719 | 680 014 (p99 1.70 ms) | 3 126 942 (p99 6.05 ms) |
| wdproto LISTEN=exclusive | 716 150 | 3 342 416 | 677 171 | 3 197 665 |
| wdproto PIN=1 | 719 019 | 3 355 018 | 673 270 | 3 198 347 |
| wdproto READSZ=4096 | 715 704 | 3 351 865 | 672 804 | 3 173 792 |

All server rows used 40.0-40.4 CPU-seconds per 10 s run (4 CPUs saturated). Ratio wdproto /
hyper (mean of the two hyper runs): **1.05 / 1.07 / 1.08 / 1.10**. Requests per server
CPU-second: hyper 169 746 / 781 792 / 157 268 / 737 716; wdproto 178 775 / 834 796 / 174 070 /
794 849.

**T3. Offload to a blocking worker pool (`wdpool.pas`, configuration B)**

Each request is parsed on the loop, handed to a worker (mutex FIFO + POSIX semaphore), the worker
builds the response header list, and posts the completion back through a lock-free MPSC stack +
eventfd (one eventfd write per batch). One request in flight per connection, as in hyper.

| mode | c=256 d=1 | c=256 d=16 | c=1024 d=1 | c=1024 d=16 |
|---|---|---|---|---|
| inline (handler on the loop) | 714 356 | 3 380 969 | 673 194 | 3 221 124 |
| pool, 8 workers | 363 245 | 728 981 | 354 734 | 721 480 |
| pool, 4 workers | 370 173 | 1 270 401 | 359 104 | 949 252 |
| pool, 32 workers | 363 070 | 610 436 | 353 656 | 602 615 |

The offload costs about 5.4 us of CPU per request at depth 1 (5.6 → 11.0 us per request) and
about 4.3 us at depth 16. For a handler that waits 100 us or more on a database this does not
matter; for plaintext it halves throughput or worse.

**T4. Flush after every response (hyper's default `pipeline_flush(false)`), depth 16, configuration B**

| server | c=256 | c=1024 |
|---|---|---|
| hyper, `pipeline_flush(false)` | 766 117 | 743 749 |
| wdproto, one write per response | 821 449 | 808 082 |
| (for comparison) hyper, `pipeline_flush(true)` | 3 127 171 | 2 950 866 |

**T5. Idle connections: 10 000 keep-alive connections, one request each, then idle (4 loops)**

| server | RSS before | RSS after | per connection |
|---|---|---|---|
| hyper | 3 156 KB | 107 636 KB | 10 698 B |
| wdproto (buffers held per connection) | 2 040 KB | 140 336 KB | 14 161 B |
| wdproto POOL=1 (buffers returned to the loop pool when idle) | 2 252 KB | 19 240 KB | 1 739 B |

The plain prototype is worse than hyper because `SetLength(WBuf, 8192)` zero-fills (touches) two
pages per connection. With pooling, an idle connection holds no buffer at all.

**T6. Micro-benchmarks (single thread pinned to one P-core, `IsMultiThread = True`)**

| operation | ns |
|---|---|
| `ServerParse`, TFB-like request (M2 `bench_role`) | 152 per request |
| `ServerEncode`, 2 user headers + content-length + date | 121 per response |
| request view through slices: path + one header lookup | 9-10 per request |
| Proper-like request object, eager: method, path, query and 6 headers as AnsiStrings | 357-361 per request |
| same, lazy: only path and `Host` become strings | 52-53 per request |
| response object, 5 AnsiString fields assigned from constants (refcount only) | 24-26 |
| one dynamic string concatenation | 48-50 |
| object Create+Free with managed fields | 47-49 |
| routine with a managed local (implicit exception frame, setjmp-based on x86_64-linux 3.2.2) | 19.54 per call |
| same routine without managed locals | 0.66 per call |

### 1.3 Findings and the decisions they drive

| # | finding | decision |
|---|---|---|
| F1 | The loop design with the M2 codec beats hyper by 5-10 % when server-bound (T2). | Keep the codec; the parser does not need SIMD to reach the target (it stays an option). |
| F2 | `SO_REUSEPORT` per loop vs shared listener + `EPOLLEXCLUSIVE`: within 1 % (T2). | Default `SO_REUSEPORT` (hyper TFB does the same); `EPOLLEXCLUSIVE` as an option (2.2). |
| F3 | Pinning loops to CPUs: within 1 % (T2). | No pinning by default (hyper TFB does not pin); `PinLoops` option. |
| F4 | Read size 4 KiB vs 8 KiB: within 1 % for small requests. | Keep hyper's 8 KiB initial size and its adaptive strategy (needed for conformance anyway). |
| F5 | Offloading every request to a worker pool costs ~5 us CPU per request (T3). | Handlers start on the loop thread; blocking work is opt-in per request (`Ex.Offload`). |
| F6 | One write per response instead of per batch: 4× lower pipelined throughput (T4). | Production default `PipelineFlush = True`; hyper's default only in conformance mode. |
| F7 | Pooling buffers of idle connections: idle RSS 14.2 → 1.7 KB per connection with no throughput loss (T1, T2, T5). | Per-loop buffer pool; buffers are returned when a connection is idle (5.2). |
| F8 | Eager AnsiString request object = 360 ns, about 30 % of hyper's per-request CPU at depth 16 (T6). | The transport never creates strings; M5's `TRequest` materializes fields lazily (4.8). |
| F9 | An implicit exception frame costs ~19 ns per call (T6). | No managed locals, parameters or temporaries in hot routines; remove managed fields from `TEncoder` and `TResponseHead` (6.3). |
| F10 | `wdpool` crashed under pipelined load: a completion freed a connection whose event was still in the same `epoll_wait` batch (use-after-free). Fixed by deferring frees to the end of the batch. | Connection records are freed only after the current event batch (2.7). This bug class is a test target (8.5). |

### 1.4 Per-request CPU budget for the real implementation

Depth 16, server-bound: hyper uses 1 / 760 000 ≈ 1.32 us of CPU per request (mean of T2's
pipelined rows, 781 792 and 737 716 requests per CPU-second); the prototype 1 / 815 000 ≈ 1.23 us.
80 % of hyper's throughput is 1.65 us per request. So the full engine (state machine, exchange
object, routing, keep-alive bookkeeping) may add at most **about 420 ns per request** over the
prototype to stay at 80 %, and **about 90 ns** to stay at 100 %. At depth 1 the kernel dominates (hyper 6.1 us, prototype 5.7 us per request) and the
headroom is about 1.9 us. These budgets are why sections 2-5 avoid atomics, allocation, string
creation and implicit exception frames on the inline path, and why the perf gate (8.6) runs after
every milestone.

---

## 2. Threading and reactor

### 2.1 Loops per core and CPU count

- Number of loops = number of CPUs the process may use, from `sched_getaffinity(0)` (syscall
  204), reduced by a cgroup-v2 quota if `/sys/fs/cgroup/cpu.max` sets one
  (`ceil(quota / period)`), overridden by `TServerConfig.Loops` if > 0. `GetCPUCount` is not used
  (it returns 1 on FPC 3.2.2 Linux).
- One OS thread per loop, created with `BeginThread`; the main thread only supervises (signals,
  control, shutdown). This matches hyper's TFB entry (one current-thread runtime per CPU).
- Pinning: off by default (F3). With `PinLoops = True`, loop *i* is pinned with
  `sched_setaffinity` to the *i*-th allowed CPU. On hybrid CPUs (this box) the kernel balances
  better unpinned; the option exists for dedicated servers.

```pascal
unit bearings.rt.cpu;
type
  TCpuList = array of Integer;
function UsableCpus: TCpuList;          { sched_getaffinity(0), ascending CPU ids }
function CgroupCpuLimit: Integer;       { 0 = no quota; else ceil(quota/period) }
function DefaultLoopCount: Integer;     { min(Length(UsableCpus), CgroupCpuLimit if > 0), at least 1 }
function PinCurrentThread(Cpu: Integer): Boolean;   { sched_setaffinity(0, ...) }
```

### 2.2 Accepting connections

Default: every loop creates its own listening socket with `SO_REUSEADDR`, `SO_REUSEPORT`,
`TCP_NODELAY`, `SOCK_NONBLOCK|SOCK_CLOEXEC`, backlog from config (default 4096, like hyper's
TFB), and registers it level-triggered (`EPOLLIN`). On readiness the loop calls
`accept4(..., SOCK_NONBLOCK|SOCK_CLOEXEC)` up to 64 times or until `EAGAIN`, so one burst cannot
starve the connections already open.

Option `AcceptMode = amSharedExclusive`: one listening socket, registered in every loop with
`EPOLLIN|EPOLLEXCLUSIVE`. The kernel wakes one waiting loop per connection; a loop that is busy is
not waiting and is not chosen. Measured throughput equal to `SO_REUSEPORT` (T2). Use it when
loops may be stalled (blocking code by mistake on a loop) or when connection counts are low and
uneven; `SO_REUSEPORT` hashes connections to loops regardless of load.

`TCP_NODELAY` is inherited by accepted sockets on Linux; M3.1 has a test that reads it back with
`getsockopt` on an accepted socket and, if the test fails on some kernel, the loop sets it per
connection (one syscall per connection).

```pascal
unit bearings.rt.listener;
type
  TAcceptMode = (amReusePort, amSharedExclusive);
  TListenSpec = record
    Host: RawByteString;     { '0.0.0.0', '127.0.0.1', '::' }
    Port: Word;              { 0 = kernel-assigned (conformance) }
    Backlog: Integer;        { default 4096 }
    Mode: TAcceptMode;
  end;
function OpenListener(const Spec: TListenSpec; ReusePort: Boolean; out Fd: cint;
  out BoundPort: Word): Boolean;
```

### 2.3 epoll mode

- Connections: `EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET`, added once with `EPOLL_CTL_ADD`, never
  modified, removed implicitly by `close`. This is what tokio does: it registers sockets for
  readable and writable interest (`tokio/src/io/poll_evented.rs`), and mio's epoll selector
  turns that into `EPOLLET | EPOLLIN | EPOLLRDHUP | EPOLLOUT` (`mio/src/sys/unix/selector/epoll.rs`).
  Level-triggered with `EPOLLOUT` toggling would cost an `epoll_ctl` per write that blocks and
  an event per writable socket per iteration.
- Readiness cache per connection (`TIoSource.Ready`, bits `rdRead`, `rdWrite`, `rdHup`): an
  event sets bits; a read or write that returns `EAGAIN` clears the bit; **a read that returns
  fewer bytes than requested clears `rdRead`** (tokio does the same, `tokio/src/io/poll_evented.rs`
  "reading a partially full buffer is sufficient to show that the socket buffer has been
  drained"). The engine checks the bit before a syscall; a cleared bit means "Pending" without a
  syscall. This keeps per-request syscalls at one `read` and one `write` (or `writev`), plus a
  share of `epoll_wait`.
- Listener and eventfd: level-triggered.

### 2.4 Wakeups and cross-thread messages

Each loop has one `eventfd(0, EFD_NONBLOCK|EFD_CLOEXEC)` registered for `EPOLLIN`, and an
intrusive lock-free MPSC stack of messages. A producer pushes with a CAS loop and writes the
eventfd **only if the stack was empty before its push** (one wakeup per batch; prototype
`wdpool.pas` does exactly this). The loop takes the whole stack with one atomic exchange,
reverses it to FIFO order, and processes it.

```pascal
unit bearings.rt.mpsc;
type
  PLoopMsg = ^TLoopMsg;
  TLoopMsgKind = (lmWakeExchange, lmCall, lmGraceful, lmStop);
  TLoopMsgProc = procedure(Loop: TObject; Msg: PLoopMsg);
  TLoopMsg = record
    Next: PLoopMsg;
    Kind: TLoopMsgKind;
    Proc: TLoopMsgProc;      { lmCall: run on the loop thread }
    Arg: Pointer;            { exchange, server, countdown, ... }
  end;
  TMpscStack = record
    Head: PLoopMsg;
    { any thread; returns True if the stack was empty (caller must signal) }
    function Push(M: PLoopMsg): Boolean;
    { owner thread; whole batch in FIFO order, or nil }
    function TakeAll: PLoopMsg;
  end;
```

Messages are embedded in the objects that send them (each `TExchange` has its own
`WakeMsg: TLoopMsg` and an atomic `WakeQueued` flag), so posting allocates nothing and a burst of
wakes for one exchange collapses into one message.

### 2.5 Timers

A per-loop hierarchical timing wheel with 1 ms resolution, 6 levels of 64 slots (the layout of
tokio's timer, covering about 2.2 years), intrusive doubly linked entries, O(1) arm and cancel.
Expired entries are fired in deadline order inside the loop iteration. The `epoll_wait` timeout
is the time to the next deadline, rounded up to the next millisecond (0 if the run queue is not
empty, -1 if there is no timer).

Users of timers in M3: the header read timeout (one entry per connection, armed when the
connection starts waiting for a head and cancelled when the head is parsed, exactly where hyper
arms and drops `h1_header_read_timeout_fut`); handler sleeps on the loop (conformance
`delay_ms`, stream item delays); graceful shutdown deadline; later HTTP/2 keep-alive pings.
Arming and cancelling per request is two list operations, a few nanoseconds; no "lazy deadline"
trick is needed.

```pascal
unit bearings.rt.timer;
type
  PTimer = ^TTimer;
  TTimerProc = procedure(T: PTimer);   { plain procedure; the owner is T^.Owner }
  TTimer = record
    Prev, Next: PTimer;
    DeadlineMs: Int64;                 { loop clock, ms }
    Level, Slot: SmallInt;             { -1 = not armed }
    Proc: TTimerProc;
    Owner: Pointer;
    Tag: PtrInt;
  end;
  TTimerWheel = record
    procedure Init(NowMs: Int64);
    procedure Arm(T: PTimer; DeadlineMs: Int64);    { re-arms if already armed }
    procedure Cancel(T: PTimer);                    { no-op if not armed }
    function Armed(T: PTimer): Boolean; inline;
    function NextDeadlineMs: Int64;                 { High(Int64) if none }
    function Advance(NowMs: Int64): Integer;        { fires expired timers; returns count }
  end;
```

### 2.6 Clock

- Loop clock: `CLOCK_MONOTONIC` read once per loop iteration, right after `epoll_wait` returns,
  through libc's `clock_gettime` (vDSO, 11 ns measured in the M2 survey; FPC's own
  `clock_gettime` and `GetTickCount64` are real syscalls, 89 ns). Everything in that iteration
  uses the cached value (`TLoop.NowMs`, `TLoop.NowNs`), like tokio's cached time.
- Date header: `TDateCache.Check` (M2 `bearings.http.date`) with `CLOCK_REALTIME` from the same vDSO
  call path, once per loop iteration. The pointer `TDateCache.Buffer` goes into
  `TServerEncodeParams.Date`, so the encoder never touches the `DateBuffer` threadvar
  (2.7 ns per access).

```pascal
unit bearings.rt.clock;
function MonoNowNs: Int64;   { libc clock_gettime(CLOCK_MONOTONIC), vDSO }
function RealNowUs: Int64;   { libc clock_gettime(CLOCK_REALTIME), vDSO }
```

### 2.7 The loop

```pascal
unit bearings.rt.loop;
type
  TIoKind = (ikListener, ikWake, ikConn);
  TReadyBit = (rdRead, rdWrite, rdHup, rdErr);
  TReadySet = set of TReadyBit;

  { First field of every object registered in epoll; epoll data.ptr points here. }
  PIoSource = ^TIoSource;
  TIoSource = record
    Kind: TIoKind;
    Fd: cint;
    Ready: TReadySet;
    Driver: TObject;            { TConnDriver for ikConn }
  end;

  TLoop = class;

  { One per connection: HTTP/1 now, HTTP/2 (nghttp2) and upgraded streams later. }
  TConnDriver = class
  public
    Loop: TLoop;
    Src: TIoSource;
    Closed: Boolean;            { set by Close; record freed after the batch }
    InRunQueue: Boolean;
    RunNext: TConnDriver;
    FreeNext: TConnDriver;
    procedure OnIo; virtual; abstract;          { Src.Ready changed }
    procedure OnRun; virtual; abstract;         { run queue: wake or yield }
    procedure GracefulShutdown; virtual; abstract;
    procedure Abort; virtual; abstract;         { close now, no response }
    procedure Close;                            { close fd, mark, defer free }
  end;

  TLoop = class
  public
    Index: Integer;
    Ep, WakeFd: cint;
    NowMs, NowNs: Int64;
    Date: TDateCache;
    Timers: TTimerWheel;
    Remote: TMpscStack;
    Bufs: TBufPool;             { section 5.2 }
    ConnCount: Integer;
    procedure Run;              { thread body }
    procedure Post(M: PLoopMsg);             { any thread }
    procedure Schedule(D: TConnDriver);      { loop thread: add to run queue }
    function Register(Src: PIoSource; Events: Cardinal): Boolean;
    procedure DeferFree(D: TConnDriver);
  end;
```

One iteration of `TLoop.Run`:

1. `n := epoll_wait(Ep, Events, 1024, Timeout)`.
2. Read the clock once (2.6); `Date.Check`.
3. For each event: listener → accept batch; wake fd → read the eventfd, drain `Remote`, apply
   each message (wakes put the connection in the run queue); connection → if `Closed`, skip;
   else OR the event bits into `Src.Ready` and call `Driver.OnIo` directly (no queueing on the
   hot path).
4. `Timers.Advance(NowMs)`.
5. Run queue: run the drivers that were queued **before** this step started (drivers queued
   while it runs wait for the next iteration, so a driver that keeps yielding cannot starve the
   others).
6. Free every driver closed during this iteration (finding F10: a driver can be closed while a
   later event of the same batch, or a queued wake, still points to it).

Graceful shutdown of the whole server (`TServer.Stop`) is in 3.9.

---

## 3. Connection state machine

### 3.1 Port plan

Three units, one per hyper file, keeping hyper's function names (Pascal style) and order so a
reviewer can read them side by side. The poll model is kept: a routine returns `psReady` or
`psPending`; errors are returned as `psError` with the error stored in the connection (hyper's
`Poll<Result<..>>` collapsed into one enum). No exceptions on the request path.

| hyper | Pascal | notes |
|---|---|---|
| `io.rs` `Buffered`, `ReadStrategy`, `WriteBuf`, `Cursor`, `WriteStrategy`, `MemRead::read_mem` | `bearings.http1.io`: `TH1Io`, `TReadStrategy`, `TH1WriteBuf` | read buffer from the loop pool; writes through `TTransport` |
| `conn.rs` `Conn`, `State`, `Reading`, `Writing`, `KA` | `bearings.http1.conn`: `TH1Conn` (advanced record, embedded in the dispatcher) | every method ported, client-only paths dropped |
| `dispatch.rs` `Dispatcher`, `Server` dispatch, `OptGuard`, `SenderDropGuard` | `bearings.http1.dispatch`: `TH1Dispatcher = class(TConnDriver)` | the service future is the `TExchange` |
| `server/conn/http1.rs` `Builder`, `Connection`, `UpgradeableConnection`, `Parts` | `bearings.http1.dispatch` (`TH1Config`, finish modes) and `bearings.server` | |
| `body/chan.rs`, `body/incoming.rs` (h1 part) | `bearings.http.exchange` (`TRequestBodyState`) | single-slot channel with `want` |
| `upgrade.rs` `Pending`, `OnUpgrade`, `Upgraded` | `bearings.http.exchange` (`TUpgradeHandler`), `bearings.rt.stream` (`TUpgradedStream`) | |

### 3.2 Configuration (hyper `http1::Builder`)

```pascal
unit bearings.http1.dispatch;
type
  TWriteStrategyOpt = (wsoAuto, wsoQueue, wsoFlatten);   { writev: None / Some(true) / Some(false) }
  TH1FinishMode = (fmPlain, fmWithUpgrades, fmWithoutShutdown);

  TH1Config = record
    KeepAlive: Boolean;              { default True }
    HalfClose: Boolean;              { default False }
    TitleCaseHeaders: Boolean;       { default False }
    PreserveHeaderCase: Boolean;     { default False (names are always kept as received; 6.4) }
    MaxHeaders: Integer;             { -1 = None (100) }
    MaxHeaderSize: SizeInt;          { -1 = None }
    MaxBufSize: SizeInt;             { -1 = None (8192 + 4096*100); >= 8192 else config error }
    HasTimer: Boolean;               { hyper .timer(..); wd-40 production: True }
    HeaderReadTimeoutMs: Integer;    { -2 = default (30000 if HasTimer), -1 = None }
    Writev: TWriteStrategyOpt;       { default wsoAuto }
    PipelineFlush: Boolean;          { hyper default False; wd-40 production default True (F6) }
    AutoDateHeader: Boolean;         { default True }
    Parser: TParserConfig;           { ignore_invalid_headers, allow_multiple_spaces... }
    FinishMode: TH1FinishMode;       { default fmPlain }
  end;

function HyperDefaultH1Config: TH1Config;      { exactly http1::Builder::new() }
function WdProductionH1Config: TH1Config;      { HasTimer, PipelineFlush, fmWithUpgrades }
function ValidateH1Config(const C: TH1Config; out Msg: string): Boolean;  { hyper's panics -> False }
```

### 3.3 Read side (`TH1Io`, port of `Buffered` read half)

```pascal
unit bearings.http1.io;
const
  INIT_BUFFER_SIZE = 8192;
  MINIMUM_MAX_BUFFER_SIZE = INIT_BUFFER_SIZE;
  DEFAULT_MAX_BUFFER_SIZE = 8192 + 4096 * 100;
  MAX_BUF_LIST_BUFFERS = 16;
  MAX_WRITEV_BUFS = 64;

type
  TReadStrategy = record               { io.rs ReadStrategy::Adaptive }
    DecreaseNow: Boolean;
    Next: SizeInt;
    Max: SizeInt;
    procedure InitWithMax(AMax: SizeInt);
    procedure Record_(BytesRead: SizeInt);    { 'record' is reserved }
  end;
  function IncrPowerOfTwo(N: SizeInt): SizeInt;
  function PrevPowerOfTwo(N: SizeInt): SizeInt;

type
  TIoStatus = (iosOk, iosWouldBlock, iosEof, iosError);

  { Plain TCP now; TLS (OpenSSL) later. Virtual calls cost ~2 ns, two per request. }
  TTransport = class
    LastErrno: cint;
    function Read(Buf: PByte; Cap: SizeInt; out N: SizeInt): TIoStatus; virtual; abstract;
    function Write(Buf: PByte; Len: SizeInt; out N: SizeInt): TIoStatus; virtual; abstract;
    function WriteV(Iov: PIoSlice; Count: Integer; out N: SizeInt): TIoStatus; virtual; abstract;
    function SendFile(InFd: cint; var Offset: Int64; Len: SizeInt; out N: SizeInt): TIoStatus; virtual;
    function IsWriteVectored: Boolean; virtual;          { TCP: True (tokio TcpStream too) }
    function ShutdownWrite: TIoStatus; virtual; abstract;
  end;

  TReadBuf = record
    Mem: PByte;            { from TLoop.Bufs, nil when idle and empty }
    Cap: SizeInt;
    Start, Stop: SizeInt;  { unparsed bytes are Mem[Start..Stop) }
    PinStart: SizeInt;     { -1, or start of a region that must not move (3.8) }
    Retired: PByte;        { old block kept alive while pinned bytes live in it }
    RetiredCap: SizeInt;
  end;

  TH1Io = record
    Transport: TTransport;
    Src: PIoSource;        { readiness cache (2.3) }
    Loop: TObject;
    FlushPipeline: Boolean;
    PartialLen: SizeInt;   { -1 = None }
    ReadBlocked: Boolean;
    R: TReadBuf;
    Strategy: TReadStrategy;
    W: TH1WriteBuf;
    BytesReadTotal: Int64;
    Observer: TObject;     { TConnObserver or nil (conformance bytes_read events) }

    function ReadBufLen: SizeInt; inline;
    function ReadBufPtr: PByte; inline;
    procedure Consume(N: SizeInt); inline;                   { buf.advance(n) }
    procedure ConsumeLeadingLines;
    { Buffered::parse::<Server>: psReady with Msg filled, psPending, psError (Err set) }
    function Parse(const Ctx: TH1ParseContext; Headers: THttpHeaders;
      out Msg: TParsedRequestHead; out Err: TH1Error): TPollStatus;
    { poll_read_from_io: N = 0 means EOF }
    function PollReadFromIo(out N: SizeInt; out Err: TH1Error): TPollStatus;
    { MemRead::read_mem: up to Len bytes, a slice of the read buffer }
    function ReadMem(Len: SizeInt; out P: PByte; out N: SizeInt; out Err: TH1Error): TPollStatus;
    function IsReadBlocked: Boolean; inline;
    procedure SetMaxBufSize(Max: SizeInt);
    procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetWriteStrategy(S: TWriteStrategy);
    { into_inner: hands the unread bytes over (upgrade / without_shutdown) }
    procedure TakeReadBuf(out Mem: PByte; out Start, Stop, Cap: SizeInt);
    procedure ReleaseIdleBuffers;                           { 5.2 }
  end;
```

Exact behaviours kept from `io.rs`:

- Read size per `read()` = `min(Strategy.Next, Strategy.Max - buffered)`; capacity is ensured
  first (pool block of 8 KiB, grown by reallocation, or by moving into a larger pooled block when
  not pinned).
- `Parse`: calls `ServerParseHeaders(Buf, Len, PartialLen, ...)` (M2, which runs
  `IsCompleteFast` first); on Partial checks `max_header_size` then `max_buf_size` with `>=`, sets
  `PartialLen`, reads again; EOF → `IncompleteMessage`.
- `Strategy.Record_` after each read, so the 4 `ReadStrategy` tests port literally.
- `bytes_read` observer call: after the bytes are in the buffer, before parsing (SPEC section 7).

`PartialLen` handling is unchanged from hyper; the prototype parsed whole heads only, so the
incremental path is new code to benchmark (slowloris case in 8.5).

### 3.4 Write side (`TH1WriteBuf`, port of `WriteBuf`)

```pascal
type
  TWriteStrategy = (wsFlatten, wsQueue);

  { One queued body buffer (EncodedBuf<B>): chunk-size prefix, data, static suffix. }
  TQueuedBuf = record
    Enc: TEncodedBuf;            { M2: prefix stored inline, data pointer, suffix }
    Owner: TBodyData;            { release information for the data (4.4) }
    FileFd: cint;                { >= 0: data is a file range for sendfile }
    FileOffset: Int64;
  end;

  TH1WriteBuf = record
    Head: PByte;                 { Cursor<Vec<u8>>: pooled block, nil when idle }
    HeadCap, HeadPos, HeadLen: SizeInt;
    Queue: array[0..MAX_BUF_LIST_BUFFERS - 1] of TQueuedBuf;   { BufList }
    QFirst, QCount: Integer;
    MaxBufSize: SizeInt;
    Strategy: TWriteStrategy;
    function Remaining: SizeInt;
    function CanBuffer: Boolean;           { Flatten: Remaining < Max; Queue: also QCount < 16 }
    function CanHeadersBuf: Boolean;       { not queue.has_remaining() }
    { headers_buf(): the encoder appends here (ServerEncode writes into this block) }
    procedure EnsureHead(Extra: SizeInt);
    procedure MaybeUnshift(Additional: SizeInt);
    procedure Buffer(const B: TEncodedBuf; const Owner: TBodyData);  { flatten copies, queue links }
    function FillIoVec(Dst: PIoSlice; Max: Integer): Integer;
    procedure Advance(N: SizeInt);         { releases fully written queued buffers }
  end;
```

- Strategy selection is hyper's: `Writev = wsoAuto` → `wsQueue` when
  `Transport.IsWriteVectored` (true for TCP); `PipelineFlush` forces `wsFlatten`.
- `Flush` (port of `poll_flush`): if `FlushPipeline` and the read buffer is not empty → Ready
  without writing; if nothing buffered → Ready; Flatten → `write()` loop on the head block;
  Queue → `writev()` with up to 64 iovecs. A file entry splits the vector: write the iovecs
  before it, then `sendfile` until done or `EAGAIN`, then continue. A write returning 0 → error
  `WriteZero`, as in hyper. `EAGAIN` → clear `rdWrite`, Pending (the edge-triggered `EPOLLOUT`
  will come).
- Small-chunk coalescing (wd-40 addition, invisible on the wire): in Queue mode a body buffer
  of at most 512 bytes is copied into the head block when it fits, instead of taking a queue
  slot. Same bytes, same or fewer syscalls.
- Not-yet-written queued data stays owned by its `TBodyData` until `Advance` passes it; then it
  is released (static: nothing; string: refcount drop; heap: `FreeMem`; file: `close` if asked).

`write_head` writes directly into `Head` (M2's `ServerEncode` takes `var Dst: TBytes`; M3.0
changes it to take a `PByte`/capacity pair from `TH1WriteBuf.EnsureHead`, computing the upper
bound first as it does now).

### 3.5 `TH1Conn` (port of `conn.rs`)

```pascal
unit bearings.http1.conn;
type
  TH1Reading = (rdgInit, rdgContinue, rdgBody, rdgKeepAlive, rdgClosed);
  TH1Writing = (wrgInit, wrgBody, wrgKeepAlive, wrgClosed);
  TH1KA = (kaIdle, kaBusy, kaDisabled);
  TH1Want = (wantExpect, wantUpgrade);
  TH1Wants = set of TH1Want;
  TPollStatus = (psReady, psPending, psError);

  { hyper error::Kind + the parts the conformance outcome needs (SPEC 7.2) }
  TH1ErrorKind = (ekNone, ekParse, ekUser, ekIo, ekIncompleteMessage, ekHeaderTimeout,
    ekBodyWrite, ekBodyWriteAborted, ekShutdown, ekCanceled, ekClosed, ekBody);
  TH1UserKind = (ukNone, ukService, ukBody, ukUnsupportedStatusCode, ukHeader,
    ukManualUpgrade, ukAbortedByCallback);
  TH1Error = record
    Kind: TH1ErrorKind;
    Parse: TH1ParseError;        { ekParse; h1peVersionH2 for the h2 preface }
    User: TH1UserKind;
    Errno: cint;                 { ekIo, ekBodyWrite, ekShutdown }
    Detail: PAnsiChar;           { static text; dynamic text lives in the exchange }
  end;

  TH1Conn = record
    Io: TH1Io;
    Reading: TH1Reading;
    Decoder: TDecoder;           { valid in rdgContinue / rdgBody }
    Writing: TH1Writing;
    Encoder: TEncoder;           { valid in wrgBody }
    KeepAlive: TH1KA;
    AllowHalfClose: Boolean;
    NotifyRead: Boolean;
    AllowTrailerFields: Boolean;
    TitleCaseHeaders: Boolean;
    DateHeader: Boolean;
    Method: THttpMethod;         { state.method }
    Version: THttpVersion;       { state.version, starts hv11 }
    Error: TH1Error;             { state.error }
    UpgradePending: Boolean;     { state.upgrade.is_some() }
    HeaderTimeoutMs: Integer;    { -1 = none }
    HeaderTimer: TTimer;
    HeaderTimerRunning: Boolean;
    HeaderTimedOut: Boolean;     { set by the timer proc, consumed by PollReadHead }
    ParseCtx: TH1ParseContext;
    ReqHeaders: THttpHeaders;    { cached_headers: reused for every request }

    procedure Init(const Cfg: TH1Config; Transport: TTransport; Src: PIoSource; Loop: TObject);
    function CanReadHead: Boolean;
    function CanReadBody: Boolean;
    function HasInitialReadWriteState: Boolean;
    function PollReadHead(out Msg: TParsedRequestHead; out Wants: TH1Wants): TPollStatus;
      { psReady + Msg; psReady with Msg.HeadLen = 0 means Ready(None) (clean EOF) }
    function PollReadBody(out Frame: TReqBodyFrame): TPollStatus;
    function WantsReadAgain: Boolean;
    function PollReadKeepAlive: TPollStatus;
    function CanWriteHead: Boolean;
    function CanWriteBody: Boolean;
    function CanBufferBody: Boolean;
    function HasBufferedWrite: Boolean;
    procedure WriteHead(const Head: TResponseHead; Body: TBodyLengthKind; BodyLen: QWord);
    procedure WriteBody(const Chunk: TBodyData);
    procedure WriteBodyAndEnd(const Chunk: TBodyData);
    procedure WriteTrailers(Trailers: THttpHeaders);
    function EndBody: Boolean;                     { False: Error = BodyWriteAborted }
    function PollFlush: TPollStatus;
    function PollShutdown: TPollStatus;
    procedure PollDrainOrCloseRead;
    procedure CloseRead;
    procedure CloseWrite;
    procedure DisableKeepAlive;                    { graceful: close if idle }
    function TakeError(out E: TH1Error): Boolean;
    procedure OnUpgrade;                           { prepare_upgrade }
    { private, same names as conn.rs }
    function ShouldErrorOnEof: Boolean;
    function HasH2Prefix: Boolean;
    function OnReadHeadError(const E: TH1Error): TPollStatus;
    function OnParseError(const E: TH1Error): Boolean;   { True = 4xx head written }
    function MidMessageDetectEof: TPollStatus;
    function ForceIoRead(out N: SizeInt): TPollStatus;
    procedure MaybeNotify;
    procedure TryKeepAlive;
    procedure EnforceVersion(var Head: TResponseHead);
    procedure FixKeepAlive(var Head: TResponseHead);
    { State:: }
    procedure StClose; procedure StCloseRead; procedure StCloseWrite;
    function StWantsKeepAlive: Boolean;
    procedure StTryKeepAlive; procedure StBusy; procedure StIdle;
    function StIsIdle: Boolean;
  end;
```

Behaviours that matter for both conformance and speed, with their hyper source:

- **Header read timeout**: `PollReadHead` arms `HeaderTimer` if not running
  (`conn.rs poll_read_head`), cancels it when a head is parsed, and on Pending checks
  `HeaderTimedOut` → `ekHeaderTimeout`. `StIdle` sets `NotifyRead` when a timeout is configured,
  so the next poll re-arms it (header_read_timeout_as_idle_timeout).
- **Error to response** (`on_read_head_error`, `on_parse_error`): close read, consume leading
  CR/LF, if mid-parse or the error must be reported: if `Writing = wrgInit` and the buffer starts
  with the 24-byte h2 preface → `ekParse/h1peVersionH2`, nothing written; else
  `ServerErrorStatus` (M2) gives 400/414/431 → `WriteHead` of an HTTP/1.1 head with no headers
  (keep-alive is already disabled, so `EnforceVersion` adds `connection: close`; the encoder adds
  `content-length: 0` and `date`), error kept for `TakeError`. Otherwise (EOF while idle) close
  write, Ready(None).
- **100 Continue**: `PollReadBody` in `rdgContinue` appends `HTTP/1.1 100 Continue\r\n\r\n` to
  the head block if `Writing = wrgInit`, switches to `rdgBody`, and recurses once. It is only
  reached when the consumer wants body data (3.6), which is what makes it lazy.
  `PollDrainOrCloseRead` switches to `rdgBody` without the 100 (drop-without-reading path).
- **half_close**: `MidMessageDetectEof` returns Pending if `AllowHalfClose` or the read buffer
  is not empty; otherwise `ForceIoRead` (only a syscall if `rdRead` is set) and EOF →
  `IncompleteMessage`.
- **MaybeNotify** (hyper's trick to avoid a lost wakeup after the response): when reading is
  `Init` and writing is not `Body`, and the read is not blocked: if the read buffer is empty, try
  one read (no syscall if `rdRead` is clear), then set `NotifyRead`.
- **Upgrades**: `OnUpgrade` sets `UpgradePending` for every request head that wants an upgrade
  (`dispatch.rs poll_read_head` calls `conn.on_upgrade()` whenever `Wants::UPGRADE`, independent
  of what the service does). The flag stays set until the dispatcher finishes, even if the
  response was not 101 (hyper keeps `state.upgrade` until `pending_upgrade()` is taken in
  `poll_inner`). This quirk is ported as is and flagged in risk R5.

### 3.6 `TH1Dispatcher` (port of `dispatch.rs`)

```pascal
type
  TDispatched = (dsShutdown, dsUpgrade);

  TH1Dispatcher = class(TConnDriver)
  public
    Conn: TH1Conn;
    Cfg: TH1Config;
    Service: THttpService;           { 4.2 }
    InFlight: TExchange;             { Server.in_flight; nil when none }
    BodyTx: TExchange;               { the exchange whose request body we still feed; nil = none }
    BodyRx: TExchange;               { the exchange whose response body we are writing }
    IsClosing: Boolean;
    Observer: TConnObserver;         { nil in production }
    ConnId: Int64;

    procedure OnIo; override;        { = poll; loop calls it on socket events }
    procedure OnRun; override;       { wake / yield }
    procedure GracefulShutdown; override;   { Dispatcher::disable_keep_alive }
    procedure Abort; override;

    { ports }
    function PollCatch(ShouldShutdown: Boolean): TPollStatus;
    function PollInner(ShouldShutdown: Boolean; out D: TDispatched): TPollStatus;
    function PollLoop: TPollStatus;  { 16-iteration budget; Pending or Yield }
    function PollRead: TPollStatus;
    function PollReadHead: TPollStatus;
    function PollWrite: TPollStatus;
    function PollFlush: TPollStatus;
    procedure Close_;                { is_closing := true; close read+write }
    function CanWriteAgain: Boolean;
    function IsDone: Boolean;
    procedure Finish(const D: TDispatched; const E: TH1Error);   { 3.9 }
  end;
```

Mapping of hyper's async pieces onto the loop:

| hyper | here |
|---|---|
| `Dispatcher` future polled by the runtime | `OnIo` (socket event), `OnRun` (wake or yield) call `PollCatch(ShouldShutdown)` |
| `task::yield_now` after 16 iterations | `Loop.Schedule(Self)`; runs again in step 5 of the next loop iteration |
| `dispatch.recv_msg(Ok((head, body)))` → `service.call(req)` | `InFlight := NewExchange(...)`; `Service.Call(InFlight)` runs **now**, on the loop thread (4.2) |
| `poll_msg` (polls the service future) | `InFlight.State`: responded → take head + body; pending → Pending (the exchange's wake will call `OnRun`) |
| `body_tx.poll_ready` (receiver wants) | `BodyTx.ReqBody.Want` (4.5) |
| `body.try_send_data(chunk)` | deliver to the sink (inline) or copy into the exchange slot (blocking) (4.5) |
| `body_rx.poll_frame` | `TBodySource.PollFrame` or the one-shot `TBodyData` (4.4) |
| dropping the service future | `InFlight.Cancel` → `OnCancel` callback, `handler_dropped` event, worker sees `Cancelled` |
| `SenderDropGuard` (incomplete error to the body receiver) | `Finish` sends `ekIncompleteMessage` to a live request-body consumer |

The `PollLoop` port keeps the hyper fix covered by `tests/h1_flush_before_yield.rs`: when
the loop continues only because of `wants_write_again` and the second `PollWrite` is Pending, it
flushes buffered bytes before returning.

**Inline fast path.** A handler that answers inside `Call` (plaintext, JSON, static) costs:
parse, create/reuse exchange (no allocation: one exchange object per connection is reused while
nobody holds a reference to it), call, encode head + body into the head block, and, after the
last buffered request, one write. No atomics (the exchange reference count is only touched when
the handler defers, 4.3), no heap allocation, no string.

### 3.7 Keep-alive, pipelining and flushing

- Keep-alive and pipelining are hyper's: one request in flight; the next head is parsed only after
  the response is written to the buffer and both sides reached `KeepAlive` → `Idle` → `Init`.
- `PipelineFlush = True` (wd-40 production default): no write while the read buffer still holds
  bytes; responses to a pipelined batch leave in one `write`. With hyper's default (`False`) every
  response is flushed in its own poll iteration. Measured cost of the hyper default at depth 16:
  4× lower throughput for both hyper and the prototype (T4).
- Write buffer limits: Flatten `Remaining < MaxBufSize`; Queue also `QCount < 16`. With
  `PipelineFlush`, `can_buffer` is always true (hyper `Buffered::can_buffer`), so the write
  buffer is bounded only by what the bounded read buffer can request.

### 3.8 Upgrades, CONNECT and the read buffer hand-off

When `IsDone` and `UpgradePending`:

- `fmWithUpgrades`: the dispatcher takes the error first (`take_error`), then hands over: the fd,
  its epoll registration and the unread bytes (`TakeReadBuf`, no copy: the pooled block's
  ownership moves) become a `TUpgradedStream` on the same loop, and the exchange's
  `TUpgradeHandler.OnUpgraded(Stream, ReadBuf, Len)` runs on the loop thread. If no handler was
  registered, the stream is closed (hyper: `pending.fulfill` into a dropped receiver drops the
  IO).
- `fmPlain`: the handler, if any, gets `OnUpgradeFailed('upgrade expected but low level API in
  use')` (hyper `Pending::manual`). As in `poll_inner`, a pending upgrade skips `poll_shutdown`:
  the socket is closed without `shutdown(SHUT_WR)`.
- `fmWithoutShutdown`: no `shutdown()`; the finish callback (`TConnObserver.OnFinished`) gets
  `TConnParts = (Fd, ReadBuf, Len)` and owns them; a registered handler gets the manual-upgrade
  error.

```pascal
unit bearings.rt.stream;
type
  TStreamHandler = class
    procedure OnReadable(S: TObject); virtual;
    procedure OnWritable(S: TObject); virtual;
    procedure OnClosed(S: TObject); virtual;
  end;
  TUpgradedStream = class(TConnDriver)
    function Read(Buf: PByte; Cap: SizeInt; out N: SizeInt): TIoStatus;   { returns leftover bytes first }
    function Write(Buf: PByte; Len: SizeInt; out N: SizeInt): TIoStatus;
    procedure SetHandler(H: TStreamHandler);
    function Detach(out Fd: cint; out Pending: RawByteString): Boolean;   { leave the loop: blocking use on a thread }
  end;
  TConnParts = record
    Fd: cint;
    ReadBuf: PByte; ReadLen: SizeInt;   { caller frees with TLoop.Bufs / FreeMem as documented }
  end;
```

HTTP/2 preface: hyper (core) detects it only when parsing fails (`has_h2_prefix`) and returns
`VersionH2` without writing; that is what the conformance cases need and what `TH1Conn` does.
For production "auto" serving (later, with libnghttp2), the accept path looks at the first bytes
already in the pooled read buffer before choosing a driver: `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`
prefix → `TH2Driver`, mismatch or EOF → `TH1Dispatcher` (hyper-util `auto::Builder` semantics).
Because the same buffer is handed to whichever driver is chosen, no "Rewind" copy is needed.

### 3.9 Finishing, graceful shutdown and outcomes

`Finish(D, E)`:

1. If a request-body consumer is still attached: deliver `ekBody` "connection error"
   (`poll_catch`), and if the dispatcher is being dropped with no error, the incomplete-message
   error (`SenderDropGuard`).
2. If the exchange in flight has not finished: `Cancel` (handler_dropped).
3. Outcome: `ok` for `dsShutdown`/`dsUpgrade` without error, else from `E` in SPEC 7.2's order.
4. Normal end: flush, `shutdown(SHUT_WR)` (hyper `poll_shutdown`) unless `fmWithoutShutdown` or
   upgrade, then `close`. Error end: `close` without shutdown (hyper drops the IO).
5. `Observer.OnConnClose(ConnId, Outcome, E)` (conformance: `conn_close`, emitted before any
   upgrade action runs).

Graceful shutdown of one connection = `Dispatcher::disable_keep_alive`: `Conn.DisableKeepAlive`
(close if idle), then `Close_` if write-closed or `HasInitialReadWriteState`. Server-wide:

```pascal
unit bearings.server;
type
  TServer = class
    procedure Start;
    { SPEC graceful_shutdown: every open connection, all loops; returns after all loops applied it }
    procedure GracefulShutdownConnections;
    { stop accepting, graceful on all connections, force-close after GraceMs, join loops }
    procedure Stop(GraceMs: Integer);
  end;
```

`GracefulShutdownConnections` posts one `lmGraceful` message per loop with a shared countdown
(`InterlockedDecrement` + `RTLEvent`) and waits; each loop calls `GracefulShutdown` on every live
driver before acknowledging. A `bytes_read` event is emitted after its bytes are in the buffer,
so a later `graceful_shutdown` always finds them (SPEC section 7).

`Stop`: each loop first accepts whatever is queued on its `SO_REUSEPORT` listener, then closes it
(closing a reuse-port listener resets connections still in its queue; draining first narrows the
window, risk R7), then applies graceful shutdown, then exits when its connection count is 0 or
the grace deadline fires (remaining connections aborted).

### 3.10 Differences from hyper (all invisible in bytes on the wire)

| # | difference | why | where it could be seen |
|---|---|---|---|
| D1 | `PipelineFlush` default `True` in production | F6 | TCP segmentation of pipelined responses (diff mode `read_once` steps with `diff_capture: false` only) |
| D2 | small body chunks copied into the head block in Queue mode | fewer iovecs | nowhere (same bytes, same or fewer syscalls) |
| D3 | read buffer returned to the pool when idle | F7 | nowhere |
| D4 | the handler starts running inside `recv_msg` (hyper: on the first `poll_msg`, same loop iteration) | no future to poll | event order within one iteration only; `request` is emitted at call time in both |
| D5 | request header names keep their received case | M2 design | only through the API (`preserve_header_case` has no wire effect in the SPEC handlers) |

---

## 4. Service API

### 4.1 Requirements recap

No closures, no async. A handler must be able to: read the request head without copying; read
the body (or not, which must not trigger `100 Continue`); answer with a known-length body, a
stream (possibly produced on another thread, possibly with delays), trailers, a file (sendfile);
take over the connection (upgrade/CONNECT); notice cancellation. It must be possible to run
blocking code (database) without stalling the loop. The same API must work for HTTP/2 streams
later.

### 4.2 Shape

```pascal
unit bearings.http.service;
type
  THttpService = class
    { Called on the loop thread when a request head has been parsed. Must not block.
      It may answer now (Ex.Respond*), arrange to answer later (loop timer, body sink,
      Ex.Defer for another thread) or call Ex.Offload to continue on the worker pool.
      Returning without answering = Pending (hyper's future not ready). }
    procedure Call(Ex: TExchange); virtual; abstract;
  end;

  { Code that may block (database, files, sleeps). Runs on a worker thread. }
  TBlockingHandler = class
    procedure Run(Ex: TExchange); virtual; abstract;
  end;
```

A handler class is the "closure": its fields hold the state. Per-request state objects come from
a per-loop free list (`TObjectPool`) so the steady state allocates nothing.

### 4.3 `TExchange`

```pascal
unit bearings.http.exchange;
type
  TByteSlice = record P: PByte; Len: SizeInt; end;

  TExchangeState = (xsCalled, xsResponded, xsFailed, xsCancelled, xsFinished);

  TResponseSpec = record          { what the handler gives; no managed fields }
    Status: Word;                 { 100..999 }
    Version: THttpVersion;        { hv11 default; hv10 / hv2 / hv09 / hv3 passed through (SPEC 5.3) }
    Reason: TByteSlice;           { Len = 0: canonical phrase; build it with TryReason }
    Headers: THttpHeaders;        { nil = none; owned by the exchange (Ex.ResponseHeaders) }
  end;

  TExchangeEvent = procedure(Ex: TExchange) of object;

  TExchange = class
  public
    { --- request head: valid from Call until the handler answers or is cancelled --- }
    function Method: THttpMethod; inline;
    function MethodBytes: TByteSlice;
    function Target: TByteSlice;                       { as received }
    function Path: TByteSlice;                         { http Uri::path() rules (M2 TUriParts) }
    function Query(out Q: TByteSlice): Boolean;
    function Version: THttpVersion; inline;
    function RequestHeaders: THttpHeaders; inline;     { external slices into the read buffer }
    function Header(const Name: RawByteString; out V: TByteSlice): Boolean;
    function Conn: PConnInfo;                          { peer/local address, conn id, loop index }
    function OnLoopThread: Boolean; inline;

    { --- request body --- }
    function HasBody: Boolean;                         { decoded length <> 0 }
    function BodyLengthHint(out Len: QWord): Boolean;  { False = chunked/unknown }
    procedure ReadBody(Sink: TBodySink);               { loop thread, push with backpressure (4.5) }
    procedure ResumeBody;                              { sink returned False earlier }
    function ReadBodyBlocking(Buf: PByte; Cap: SizeInt; out N: SizeInt): TBodyReadStatus;  { worker }
    function ReadTrailersBlocking: THttpHeaders;       { after brEnd; nil if none }
    procedure DropBody;                                { hyper: drop(req.body) -> drain or close }

    { --- response: exactly one of Respond* / Fail per exchange --- }
    function ResponseHeaders: THttpHeaders;            { empty list owned by the exchange, reused }
    function Respond(const R: TResponseSpec; const Body: TBodyData): Boolean;   { known length or empty }
    function RespondStream(const R: TResponseSpec; Source: TBodySource): Boolean;  { unknown length }
    function Fail(const Msg: RawByteString): Boolean;  { hyper service Err: no response, conn ends (user) }
    { False from all three: already answered, or cancelled (client gone) }

    { --- upgrades (hyper upgrade::on) --- }
    function WantsUpgrade: Boolean;                    { Upgrade header (HTTP/1.1) or CONNECT }
    procedure OnUpgrade(H: TUpgradeHandler);           { must be called before answering }

    { --- threads and lifetime --- }
    procedure Offload(H: TBlockingHandler);            { continue on the worker pool }
    function Defer: TExchange;                         { +1 reference (atomic); for use after Call returns }
    procedure Release;                                 { -1; last one returns it to its loop }
    procedure Wake;                                    { any thread: re-poll this exchange's connection }
    function Cancelled: Boolean; inline;
    property OnCancel: TExchangeEvent read FOnCancel write FOnCancel;   { loop thread }
    property State: TExchangeState read FState;
    property Tag: Pointer read FTag write FTag;        { handler use }
    { private fields (FOnCancel, FState, FTag, request-body slot, refcount, loop, ...) elided }
  end;

{ validates with FindInvalidReasonByte (HTAB, SP, VCHAR, obs-text); R points at P }
function TryReason(P: PByte; Len: SizeInt; out R: TByteSlice): Boolean;
```

Lifetime rules (these replace Rust's ownership):

1. During `Call`, on the loop thread, the handler may use the exchange freely. If it answers
   before returning, nothing else is needed (fast path, no atomic operation).
2. To keep the exchange after `Call` returns (timer, other thread, stream source), the handler
   calls `Defer` once and `Release` when done. The transport holds its own reference until the
   response is written or the connection ends. `Offload` does `Defer` for the worker.
3. The request head view (method, target, headers) is valid until the handler answers or the
   exchange is cancelled. A handler that answers with a stream and keeps producing must copy what
   it still needs first. Debug builds check this with a generation counter.
4. Answer methods may be called from any thread. Off the loop they store the answer in the
   exchange and `Wake` the loop (the dispatcher's `poll_msg` picks it up).
5. When the connection ends with the exchange unanswered, the loop sets `xsCancelled`, calls
   `OnCancel` (loop thread) and emits `handler_dropped`; later answers return False. Memory stays
   valid until the last `Release`; a release on a worker thread posts the free to the owning loop.

### 4.4 Response bodies

```pascal
unit bearings.http.body;
type
  TBodyKind = (bkEmpty, bkMem, bkFile);
  TBodyOwnership = (boStatic, boCopyNow, boFreeMem, boString, boCustom);
  TBodyReleaseProc = procedure(Ctx: Pointer; Data: PByte);

  TBodyData = record              { no managed fields }
    Kind: TBodyKind;
    Data: PByte; Len: SizeInt;
    Own: TBodyOwnership;
    Ctx: Pointer;                 { boString: the string's payload pointer (refcount held); boCustom: arg }
    ReleaseProc: TBodyReleaseProc;
    Fd: cint; Offset: Int64; CloseFd: Boolean;     { bkFile }
  end;
  function BodyEmpty: TBodyData;
  function BodyStatic(P: Pointer; Len: SizeInt): TBodyData;     { constants, immortal buffers }
  function BodyCopy(P: Pointer; Len: SizeInt): TBodyData;       { copied into the head block now }
  function BodyString(const S: RawByteString): TBodyData;       { +1 refcount, -1 after the write }
  function BodyHeap(P: Pointer; Len: SizeInt): TBodyData;       { FreeMem after the write }
  function BodyFile(Fd: cint; Offset, Len: Int64; CloseAfter: Boolean): TBodyData;  { sendfile }
  procedure ReleaseBody(var B: TBodyData);

type
  TFrameKind = (fkData, fkTrailers);
  TFramePoll = (fpReady, fpPending, fpEnd, fpError);
  TBodyFrame = record
    Kind: TFrameKind;
    Data: TBodyData;
    Trailers: THttpHeaders;       { fkTrailers; owned by the source until the next poll }
  end;

  { hyper http_body::Body. Polled on the loop thread only. }
  TBodySource = class
    function SizeHint(out Exact: QWord): Boolean; virtual;   { default False (unknown) }
    function IsEndStream: Boolean; virtual;                  { default False }
    { fpPending: the source must call Ex.Wake when it has more }
    function PollFrame(Ex: TExchange; out F: TBodyFrame; out ErrMsg: RawByteString): TFramePoll;
      virtual; abstract;
    procedure Done(Ex: TExchange); virtual;                  { transport finished with it (end, error or drop) }
  end;

  { Producer on any thread, consumer = transport. Bounded: Capacity chunks. }
  TChannelBody = class(TBodySource)
    constructor Create(Capacity: Integer);
    function Send(const D: TBodyData): TSendStatus;          { worker: blocks while full; ssClosed if client gone }
    function TrySend(const D: TBodyData): TSendStatus;       { never blocks: ssFull -> wait for OnWritable }
    procedure Finish(Trailers: THttpHeaders);                { nil = no trailers }
    procedure Abort(const Msg: RawByteString);
    property OnWritable: TExchangeEvent read FOnWritable write FOnWritable;  { loop-thread producers }
  end;
```

How the dispatcher uses them (port of `poll_write`):

- `Respond(R, Body)`: `bkEmpty` or `Len = 0` → hyper's `is_end_stream()` → no body (`None`);
  otherwise `BodyLength::Known(Len)`. Head and body are encoded together (`write_body_and_end`),
  so a small response is one contiguous block and leaves in one write. `bkFile` → known length,
  queued as a sendfile entry.
- `RespondStream(R, Src)`: `Src.IsEndStream` / `Src.SizeHint` pick `None` / `Known` / `Unknown`
  exactly as `dispatch.rs` does; then `PollFrame` is called only while `CanBufferBody` (hyper's
  backpressure). A data frame followed by `IsEndStream` becomes `write_body_and_end`; empty data
  frames are skipped; trailers go to `Conn.WriteTrailers` (which checks `AllowTrailerFields`);
  `fpError` → `ekUser/ukBody`, connection closes, chunked body left unterminated (hyper).
- Backpressure to producers: `TChannelBody.Send` blocks a worker while the channel is full; the
  dispatcher drains the channel only while the write buffer has room; when the socket is slow,
  the write buffer fills, the channel fills, and the worker waits. Loop-thread producers use
  `TrySend` and `OnWritable`.

### 4.5 Request bodies

The exchange holds hyper's single-slot channel state:

```pascal
type
  TReqBodyFrameKind = (rbData, rbTrailers, rbEnd, rbError);
  TReqBodyFrame = record
    Kind: TReqBodyFrameKind;
    Data: PByte; Len: SizeInt;        { slice of the read buffer (loop) }
    Trailers: THttpHeaders;           { decoder-owned copy }
    Error: TDecodeError; IoKind: TIoErrorKind; Errno: cint;
  end;

  TBodySink = class                   { loop-thread consumer }
    function OnData(Ex: TExchange; P: PByte; Len: SizeInt): Boolean; virtual; abstract;  { False = pause }
    procedure OnTrailers(Ex: TExchange; T: THttpHeaders); virtual;
    procedure OnEnd(Ex: TExchange); virtual; abstract;
    procedure OnError(Ex: TExchange; const F: TReqBodyFrame); virtual; abstract;
  end;

  TBodyReadStatus = (brData, brEnd, brError, brCancelled);
```

- `want` starts False when the request had `Expect: 100-continue` (channel "wanter"), True
  otherwise (`chan.rs`). `ReadBody` / `ResumeBody` / `ReadBodyBlocking` set it; `OnData`
  returning False clears it. The dispatcher's `PollRead` only calls `Conn.PollReadBody` while
  `want` is set, so the first `ReadBody*` call is the "first poll" that sends `100 Continue`.
- Inline sink: the slice is valid only during `OnData` (zero copy).
- Worker (`ReadBodyBlocking`): the loop copies the chunk into a per-exchange buffer (up to
  `Cap` of the caller; the rest stays in the read buffer) and signals the worker's event. The
  copy costs far less than the thread hand-off (T3) and avoids pinning read buffers across
  threads.
- `DropBody`, or answering without reading: hyper's `poll_drain_or_close_read` (one read attempt;
  if the body is not complete, close the read side and disable keep-alive).
- Errors: the decoder's `TDecodeError` with `DecodeErrorKind` / `DecodeErrorMessage` (M2), socket
  errors as `ekIo` with errno.

### 4.6 Where code runs, and blocking code

| work | thread | how |
|---|---|---|
| parsing, routing, static files, plaintext/JSON, redirects | loop | inside `Call` |
| waiting on timers or other loop events | loop | `Defer`, loop timer (`TLoop.Timers`), answer from the timer proc |
| code that blocks (DB, file reads, external HTTP with a blocking client, `Sleep`) | worker | `Ex.Offload(H)`; `H.Run` calls `ReadBodyBlocking`, `Respond`, `TChannelBody.Send` |
| producing a stream from another thread | any | `RespondStream(R, TChannelBody)` then `Send` |

```pascal
unit bearings.rt.workers;
type
  TWorkerPool = class
    constructor Create(Threads: Integer; Name: RawByteString);
    procedure Submit(Ex: TExchange; H: TBlockingHandler);     { loop thread; FIFO }
    procedure Shutdown(WaitMs: Integer);
    function QueueLength: Integer;
  end;
```

Implementation: mutex-protected FIFO of exchanges (the link field is inside the exchange; no
allocation) and a counting semaphore (futex) to park idle workers, as in `wdpool.pas`. Each
worker has an `RTLEvent` used by `ReadBodyBlocking` and `TChannelBody.Send` to wait. Results go
back through the owning loop's MPSC stack + eventfd (2.4). Pool size is a config value; for
Proper it equals `MAX_THREADS` (one database connection per worker, as with Granian threads).

Possible later optimizations of the hand-off, to be measured, not assumed: spin briefly before
parking (both directions); keep a worker affinity per loop; batch several completions per wake
(already done by the "write eventfd only if the stack was empty" rule).

### 4.7 Cancellation and backpressure summary

| direction | mechanism |
|---|---|
| client → handler (request body) | single slot + `want`; read buffer bounded by `MaxBufSize`; TCP window closes when the handler is slow |
| handler → client (response body) | `PollFrame` only while `CanBufferBody`; `TChannelBody` bounded; `Send` blocks or `TrySend` + `OnWritable` |
| handler work → pool | at most one request in flight per HTTP/1 connection, so pool queue length ≤ open connections; HTTP/2 later: `max_concurrent_streams` |
| client gone | `half_close = False`: EOF while busy → `IncompleteMessage` → exchange cancelled; `OnCancel` (loop), `Cancelled` (workers), answers return False |

### 4.8 M5 (Proper-like `Request` / `Response`) on top

Proper (app.md, "Request Lifecycle") runs synchronous controller code on server threads
(Granian), `MAX_THREADS` per process, one DB connection per thread. Mapping:

| Proper | wd-40 M5 on this API |
|---|---|
| pipeline steps 1-4 (head_to_get, method_override, match, redirect) | on the loop, inside `Call`, on slices; no strings |
| static assets | loop, `BodyFile` (sendfile) |
| controller dispatch (steps 5-7, DB open/close around it) | `Ex.Offload(ControllerJob)`; the job object comes from a pool; `current` = threadvar on the worker (2.7 ns) |
| `request.method/path/headers/query/cookies/...` | `TRequest` wraps the exchange; each property materializes its string on first access and caches it (T6: 53 ns for path + one header vs 360 ns eager) |
| `request.form` | `ReadBodyBlocking` to a limit, then parse |
| `response.body` (str/bytes) | `Respond(Spec, BodyString(Body))`: no copy, refcount released after the write |
| `response.headers`, cookies, cache helpers | `Ex.ResponseHeaders` with validating setters (6.1) |
| `response.send_file` | `BodyFile` |
| errors in controllers | M5 turns them into 500 responses; `Ex.Fail` is reserved for transport-level failure |
| routes that never block (health, JSON from memory, benchmarks) | route flag `inline`: the controller runs inside `Call` on the loop |

Default proposed (open question 2): controller actions run on the worker pool; `inline` is
opt-in per route. With that default a TFB-style Proper app declares its plaintext/JSON routes
`inline` and gets loop-thread performance.

### 4.9 Room for HTTP/2 (libnghttp2, later)

The loop, `TConnDriver`, `TExchange`, `TBodySource` and `TBodySink` are protocol-free:

- `TH2Driver = class(TConnDriver)` owns an `nghttp2_session` (sans-IO): reads go to
  `nghttp2_session_mem_recv2`, writes come from `nghttp2_session_mem_send2` into the same
  `TH1WriteBuf`-style buffer.
- One `TExchange` per stream, from the loop's exchange pool; `Service.Call` is the same.
- Response bodies: nghttp2's data provider read callback calls `TBodySource.PollFrame`;
  `fpPending` → `NGHTTP2_ERR_DEFERRED`; `Ex.Wake` → `nghttp2_session_resume_data`. Trailers →
  `nghttp2_submit_trailer`.
- Request bodies: `on_data_chunk_recv` copies into the exchange slot (nghttp2's buffers are
  transient); `nghttp2_session_consume` is called when the consumer takes the data, so flow
  control is the backpressure (hyper releases capacity on poll, `incoming.rs`).
- Cancellation: `RST_STREAM` from the peer → `Ex.Cancel` for that stream only.

---

## 5. Memory

### 5.1 Ownership

| object | owner | lifetime |
|---|---|---|
| `TH1Dispatcher` (+ embedded `TH1Conn`, `TH1Io`) | loop | accept → close; freed after the event batch (F10) |
| read buffer block | connection while it holds unread bytes or a pinned head; loop pool otherwise | 5.2 |
| write head block | connection while bytes are buffered; loop pool otherwise | 5.2 |
| queued body data | `TBodyData` until written | released in `TH1WriteBuf.Advance` |
| request `THttpHeaders` (`cached_headers`) | connection | reused for every request (external entries) |
| `TExchange` (+ its response `THttpHeaders`) | loop pool; references: transport + `Defer` | last `Release` returns it to its loop |
| request trailers | decoder buffer → `THttpHeaders` owned by the exchange | until the exchange is released |
| `TUpgradedStream` | loop | until closed |

### 5.2 Buffer pool and per-connection RSS

Per-loop `TBufPool` with size classes 8, 16, 32, 64 KiB (larger: direct `GetMem`/`FreeMem`).
Blocks are taken when a connection has something to read or write and returned when it is idle:
read buffer empty and not pinned, write buffer empty, no exchange in flight. Measured with the
prototype: idle 10k connections 1 739 B each instead of 14 161 B (hyper: 10 698 B), and lower
RSS under load (4.8 MB vs 22.3 MB at c=1024 depth 16, because only connections being processed in
the current batch hold buffers), with no throughput change (T1, T2, T5).

```pascal
unit bearings.rt.bufpool;
type
  TBufPool = record
    procedure Init(MaxPooledBytes: SizeInt);            { cap: excess blocks go back to the heap }
    function Get(MinSize: SizeInt; out Cap: SizeInt): PByte;   { no zero-fill }
    procedure Put(P: PByte; Cap: SizeInt);
    procedure Trim;                                      { called on idle loop iterations }
  end;
```

Blocks never cross threads (worker copies use exchange-owned buffers), so the FPC heap's
cross-thread free path is not on the hot path.

Targets for M3 (checked in 8.6): idle connection ≤ 2 KB; active connection with small requests
≤ hyper's per-connection RSS at c=1024 (21.6 MB total measured for hyper).

### 5.3 Zero-copy slices and their lifetimes

- Request head: `ServerParse` (M2) fills `ReqHeaders` with external entries relative to the head
  start, and `TParsedRequestHead` with offsets. The head bytes are **pinned** from parse until
  the handler answers (rule 3 in 4.3). While pinned, the read buffer is never compacted and never
  reallocated in place: if it must grow (pipelined bytes, half-close EOF detection), the unread
  tail moves to a new block and the old block is kept in `Retired` until unpinned (what
  `BytesMut` does implicitly when a frozen head `Bytes` still references the allocation).
- Body slices for inline sinks: valid only during `OnData`.
- Hyper's `split_to().freeze()` refcounting is replaced by these two rules; no reference counts
  on buffers.

### 5.4 No AnsiString and no implicit frames on the hot path

- The transport never creates strings; names/values/paths are `PByte`+length (`TByteSlice`).
- Records used on the hot path have no managed fields; routines on the hot path have no managed
  locals, parameters or temporaries (each such routine pays ~19 ns for the implicit exception
  frame, T6). M3.0 removes the two managed fields M2 has on this path:
  - `TEncoder.FTrailerFields: array of RawByteString` → trailer names as `(Ofs, Len)` slices into
    the response header list that declared them (alive until the response is written), stored in
    a fixed array of 16 slices with a heap overflow array for more.
  - `TResponseHead.Reason: TReasonPhrase` (RawByteString) → `TByteSlice`, validated by the API
    (`TryReason`, `FindInvalidReasonByte`).
- Strings are allowed in cold paths: config, conformance server, error messages (`Fail` keeps
  its message in the exchange).
- The conformance server and M5 are free to use strings; M5 uses lazy materialization (4.8).

---

## 6. Header value validation and trailer fixes

### 6.1 Validation boundary (fix for CR/LF/NUL)

hyper cannot put CR, LF or NUL into a response header because `http::HeaderValue::from_bytes`
rejects bytes < 0x20 except HTAB, and 0x7F; `HeaderName::from_bytes` only accepts tokens. M2's
`THttpHeaders.Add/Insert/Append/SetValue` copy anything, so a handler can inject header lines.

Boundary: **where bytes enter an outgoing header list**. Parsed request headers do not need it
(httparse's tables already reject these bytes; they enter through `AddExternal`).

```pascal
{ bearings.http.headers additions }
type
  EInvalidHeader = class(Exception);
  THeaderCheck = (hcOk, hcBadName, hcBadValue);

  THttpHeaders = class
    { validating (public API, M5 setters): name = IsValidHeaderName, value = IsValidHeaderValue }
    function TryAdd(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TryInsert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TrySetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    procedure Add(const Name, Value: RawByteString);      { now validates; raises EInvalidHeader }
    procedure Insert(const Name, Value: RawByteString);   { same }
    { trusted: constants and internal callers; debug builds still assert }
    function AddTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
    procedure InsertTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
  end;
```

- `IsValidHeaderValue` (exists in M2) = http's `HeaderValue::from_bytes` (HTAB, ≥ 0x20, not
  0x7F; obs-text allowed). `IsValidHeaderName` (exists) = tchar, 1..65535 bytes.
- Cost: one table lookup per byte, about 20 ns for a typical 3-header response; constants use
  `AddTrusted`. Debug builds also assert in `ServerEncode` that every byte it copies is valid
  (defense in depth without release-build cost).
- Same rule for trailers (they are `THttpHeaders` too), for the reason phrase
  (`TResponseSpec.Reason` built with `TryReason`, which uses `FindInvalidReasonByte`) and for
  M5 cookie/redirect helpers (they build values from user data).
- Conformance: the SPEC's reply headers are byte strings from JSON; the conformance server uses
  `TryInsert` and rejects an invalid spec with exit status 2 (hyper's tests could not construct
  such a header either).

### 6.2 Trailer encoding: deviations found and their fixes

Compared `TEncoder.EncodeTrailers` / `IntoChunkedWithTrailerHeader` (M2) with `encode.rs
encode_trailers`, `role.rs` (`header::TRAILER` arm, `into_chunked_with_trailing_fields`) and
`conn.rs write_trailers`:

| # | hyper | M2 | wire effect | fix |
|---|---|---|---|---|
| T1 | iterates the trailer `HeaderMap` and re-collects into a `HeaderMap`; output groups all values of a name together, in order of first appearance | iterates `THttpHeaders` in insertion order | different line order when a trailer name repeats non-adjacently (only via `Append`) | emit grouped: for each first occurrence of a name, write all its values (same as `ServerEncode` already does for headers) |
| T2 | trailer values are `HeaderValue`s: no CR/LF/NUL | copies raw bytes | header injection through trailers | 6.1 boundary + debug assertion in the encoder |
| T3 | trailer names are `HeaderName`s (tokens) | writes stored name bytes (lowercased) unchecked | a name containing `:` or CR/LF would be written | 6.1 boundary (`TryAdd` rejects); encoder skips non-token names in release builds (hyper could never see one) |
| T4 (perf) | builds into a reused `Vec` | `SetLength(Dst, ...)` per call → heap allocation, zero-fill | none | encode into `TH1WriteBuf` head block directly |
| T5 (perf) | `allowed_trailer_fields: Vec<HeaderName>` | `array of RawByteString` inside `TEncoder` (managed record, see 5.4) | none | slices into the response header list |

T1-T3 are the wire/robustness deviations I could find; I could not find M2's own list (open
question 3). Tests (8.2): the M2 differential harness for the encoder gets trailer cases with
repeated names and invalid bytes, compared against hyper's `encode_trailers` through the existing
Rust side (`tests/unit/test_codec_diff_rs`).

### 6.3 Other M2 changes needed by M3 (M3.0)

- `ServerEncode` writes into a `PByte` + capacity (the pooled head block) instead of
  `var TBytes`.
- `TEncoder` and `TResponseHead` without managed fields (5.4).
- `TEncodedBuf` already has the right shape for `writev` (prefix stored inline); `TQueuedBuf`
  embeds it, so the record must not move while queued (it lives in the fixed queue array).

---

## 7. The Pascal conformance server

Location: `conformance/pascal-server/` (test tooling, not shipped). It is a thin wrapper:
everything on the wire comes from `bearings.http1.*`.

Command line: `wdconf [--handler-mode inline|blocking] [--loops N] --config <path>`. The runner
appends `--config`; the extra flags let the same 105 cases run against both execution paths.
Default: `--loops 1` (connections are numbered in accept order; with one loop accept order is the
kernel's queue order, the same as hyper's single accept loop), `--handler-mode inline`.

### 7.1 Process protocol (SPEC 3)

| SPEC item | implementation |
|---|---|
| `--config <path>`, invalid spec → stderr + exit 2, no `LISTENING` | `fpjson` parse; unknown field / wrong type / hyper-panic values (`max_buf_size < 8192`, `header_read_timeout_ms` number with `timer` false) → `ValidateH1Config` false → exit 2 |
| bind 127.0.0.1:0, `LISTENING <port>` | `OpenListener` with port 0 and `ReusePort = False`, `getsockname`; line written and flushed before loops start accepting |
| connections numbered 1, 2, ... in accept order | global `InterlockedIncrement` in the accept path (`TConnObserver.OnAccept`) |
| stdout: one JSON object per line, atomic | `TEventWriter`: builds the line (cold path, strings allowed), then one mutex-protected `fpWrite` loop on fd 1 |
| stdin control | a dedicated thread reads lines (blocking) |
| `graceful_shutdown` | `TServer.GracefulShutdownConnections` (waits until every loop applied it), then `control_ack` |
| `signal <name>` | latch registry (mutex + per-name `RTLEvent`, never reset), then `control_ack` |
| `exit`, EOF on stdin | `fpExit(0)` immediately |
| other line | `control_error` |

### 7.2 `config` fields (SPEC 4)

| field | mapping |
|---|---|
| `keep_alive` | `TH1Config.KeepAlive` (false → `Conn.DisableKeepAlive` at construction, as `serve_connection`) |
| `half_close` | `HalfClose` → `Conn.AllowHalfClose` |
| `title_case_headers` | `TitleCaseHeaders` |
| `preserve_header_case` | accepted; `PreserveHeaderCase` (names are always kept as received; the SPEC handlers do not echo case, so no wire effect, as with hyper's private case map) |
| `max_headers` | `MaxHeaders` → `ParseCtx.MaxHeaders` and the decoder's trailer count limit |
| `max_header_size` | `MaxHeaderSize` → parse context, `TH1Io.Parse` partial check, decoder trailer byte limit |
| `max_buf_size` | `MaxBufSize` → `TReadStrategy.Max` and `TH1WriteBuf.MaxBufSize` |
| `timer` | `HasTimer` |
| `header_read_timeout_ms` | `HeaderReadTimeoutMs` (absent = default 30000 only if `timer`; `null` = -1) |
| `writev` | `Writev` (`wsoQueue` / `wsoFlatten`) |
| `pipeline_flush` | `PipelineFlush` (forces Flatten) |
| `auto_date_header` | `AutoDateHeader` |
| `ignore_invalid_headers` | `Parser.IgnoreInvalidHeadersInRequests` |
| `allow_multiple_spaces_in_request_line_delimiters` | `Parser.AllowMultipleSpacesInRequestLineDelimiters` |
| `conn_mode` | `FinishMode`: `plain` → `fmPlain`, `with_upgrades` → `fmWithUpgrades`, `without_shutdown` → `fmWithoutShutdown` |
| `graceful_shutdown_on_accept` | the accept hook calls `Dispatcher.GracefulShutdown` before the first poll (→ `HasInitialReadWriteState` → close, outcome ok, nothing written) |
| `bytes_read_events` | `TConnObserver.OnBytesRead(Conn, Total)` from `TH1Io.PollReadFromIo` after the bytes are buffered, before parsing; `Total` = `TH1Io.BytesReadTotal`; not called for EOF/errors/EAGAIN or after hand-off |

### 7.3 Handlers (SPEC 5.1)

| handler | implementation |
|---|---|
| `test_service` | `TTestService.Call`: emits `request`, takes the next reply from the global queue (mutex), then runs the 5.5 sequence (7.4) as a per-request state object; in `--handler-mode blocking` the same sequence runs in `TBlockingHandler.Run` with blocking calls |
| `hello_world` | `Respond(200, BodyStatic('hello'))` inside `Call`; never touches the body (so `DropBody` semantics apply: drain or close, no 100) |
| `unreachable` | `Fail('request shouldn''t be received')` inside `Call` → no response, outcome `user` |

Events for every call: `request` in `Call` (method token, target as received, version,
headers lowercased and grouped by first appearance: built from `RequestHeaders` on the cold path),
then exactly one of `handler_done` (emitted inside `Respond*`/`Fail` when called by the handler)
or `handler_dropped` (emitted by the transport in `Cancel`, before `conn_close`).

### 7.4 `test_service` sequence (SPEC 5.5), inline mode

State object `TTestJob` (pooled) with fields: reply, collected body (`RawByteString`, cold path),
trailers, timer, stream source.

1. `request` event; `req` number = per-connection counter in the connection's observer data.
2. Take reply (queue empty → `{}`).
3. `upgrade.on_upgrade` true → `Ex.OnUpgrade(TConfUpgradeHandler)` now.
4. `read_body` true → `Ex.ReadBody(Job)` (sink): `OnData` appends; `OnTrailers` keeps them;
   `OnEnd` emits `request_body` (+ `trailers` if any) and continues at 5; `OnError` emits
   `request_body_error` with `kind` (`unexpected_eof` / `invalid_data` / `invalid_input` from
   `DecodeErrorKind`; `io` for socket errors; `other`) and `message` (`DecodeErrorMessage`), then
   `Fail('req body error')`.
   `read_body` false → `Ex.DropBody` (no 100 Continue ever).
5. Release the request view (nothing to do; the job stops using slices).
6. `delay_ms` > 0 → `Ex.Defer`, arm a loop timer; the timer proc continues at 7. If the
   connection ends first, `OnCancel` cancels the timer and releases (`handler_dropped` is emitted
   by the transport).
7. `error` → `Fail(error)`.
8. `upgrade` with `on_upgrade` false → remember the spec on the connection's observer data for
   the `without_shutdown` hand-off.
9. Build the response: `ResponseHeaders.TryInsert` for each `[name, value]` (insert semantics),
   `Status`, `Reason` (`TryReason`; invalid → config error at load time), `Version`
   (`HTTP/1.0` → `hv10`, `HTTP/2.0` → `hv2`, `HTTP/0.9` → `hv09`, `HTTP/3.0` → `hv3`), body:
   - absent → `Respond(R, BodyEmpty)`;
   - `{"known": b}` → `Respond(R, BodyString(b))` (empty `b` = absent, as `Full` with no data is
     end-of-stream);
   - `{"stream": [...], "trailers": [...]}` → `RespondStream(R, TScriptedBody)`.

`TScriptedBody = class(TBodySource)`: no size hint, `IsEndStream` false until the item list and
trailers are consumed. `PollFrame`: next item; `delay_ms` > 0 and not yet waited → arm a loop
timer, return `fpPending` (the timer proc calls `Ex.Wake`); `data` → `fpReady` with
`BodyString` (one frame per repetition of `times`); `error` → `fpError` with the message;
after the last item: `trailers` present → `fkTrailers` frame built with insert semantics, then
`fpEnd`. Items without delay are ready on the first poll (SPEC 5.4).

Blocking mode: same sequence with `ReadBodyBlocking` / `ReadTrailersBlocking`, `Sleep(delay_ms)`
on the worker (cancellation is observed when it wakes: answers return False), and
`RespondStream(R, TChannelBody)` where the worker `Send`s each item after its `Sleep`.

1xx final status (`status` 100..199 except 101): passed through; M2's `ServerEncode` writes the
500 head and returns `serUnsupportedStatusCode` → `ekUser/ukUnsupportedStatusCode` → outcome
`user`, as hyper.

### 7.5 Upgrades (SPEC 6.1, 6.3)

- `TConfUpgradeHandler.OnUpgraded(Stream, ReadBuf, Len)`: emit `upgraded` with `read_buf`, then
  `Stream.Detach` (fd leaves the loop, set blocking) and start a thread that: waits for the latch
  (`await_signal`), writes `write`, reads to EOF (`read_to_eof`) and emits `upgrade_read` (`eof`
  or `error` + message), closes. Errors → `upgrade_error`. Bytes read here are not counted in
  `bytes_read`.
- `OnUpgradeFailed(Msg)` → `upgrade_error` with hyper's message.
- `without_shutdown`: `TConnObserver.OnFinished(Parts)`: if a non-registering upgrade spec was
  remembered (step 8), run the same thread on `Parts.Fd` with `Parts.ReadBuf` as `read_buf`;
  otherwise close the fd. `conn_close` is emitted before (3.9 step 5).

### 7.6 Graceful shutdown (SPEC 6.2)

`graceful_shutdown` → `GracefulShutdownConnections`: per connection `Dispatcher.GracefulShutdown`
(3.9). Connections accepted later are not affected; the listener keeps accepting. After an
upgrade hand-off the connection is no longer a `TH1Dispatcher`, so it is not affected (hyper:
no-op after upgrade).

### 7.7 Outcomes (SPEC 7.2)

`conn_close.outcome` from `TH1Error`: `ok` (no error), then in order `timeout`
(`ekHeaderTimeout`), `parse_too_large` (`ekParse` with `h1peTooLarge` or `h1peUriTooLong`),
`parse_version_h2` (`h1peVersionH2`), `parse` (other parse errors), `incomplete`
(`ekIncompleteMessage`), `user` (`ekUser`, any sub-kind), `canceled`, `closed`,
`body_write_aborted`, `shutdown`, `io`, `other`. `detail` = textual description (ignored in diff
mode).

---

## 8. Test plan

### 8.1 Port of hyper `io.rs` unit tests (M3.2, `tests/unit/test_h1_io.pas`)

`io.rs` has 10 test functions (9 active, 1 `#[ignore]`). They run against a `TMockTransport`
(scripted reads with optional "would block", recorded writes / writevs, write-size limits), the
equivalent of `tokio_test::io::Builder`.

| hyper test | port |
|---|---|
| `iobuf_write_empty_slice` (`#[ignore]`, body commented out) | port the intent: flush with nothing buffered makes no write call |
| `parse_reads_until_blocked` | two scripted reads (`HTTP/1.1 200 OK\r\n`, `Server: hyper\r\n`) then would-block: server variant uses a request head; assert `Parse` is Pending and the read buffer holds both pieces |
| `read_strategy_adaptive_increments` | literal |
| `read_strategy_adaptive_decrements` | literal |
| `read_strategy_adaptive_stays_the_same` | literal |
| `read_strategy_adaptive_max_fuzz` | literal (max from 8192 growing by 3/2 up to `High(SizeInt)`) |
| `write_buf_requires_non_empty_bufs` | debug-build assertion on `Buffer` with an empty buffer (expect `EAssertionFailed`) |
| `write_buf_flatten` | Flatten: head `hello ` + 3 buffers → exactly one write `hello world, it's hyper!`, queue count 0 |
| `write_buf_flatten_partially_flushed` | literal (cursor position 11, `MaybeUnshift` behaviour, capacity check against `INIT_BUFFER_SIZE`) |
| `write_buf_queue_disable_auto` | Queue with a non-vectored mock: 4 separate writes, queue empty after flush |
| (commented-out `write_buf_queue`) | port it too: vectored mock, one `writev` of 4 iovecs |

Added: `PipelineFlush` skip-while-read-buffer-not-empty; writev partial-write advance across a
chunk prefix/data/suffix boundary; sendfile entry between iovecs (socketpair + temp file);
`WriteZero` error; pool block return on idle.

### 8.2 Conn and dispatch level (M3.3-M3.4)

- `conn.rs` server tests (8): `conn_reads_request_head`, `conn_reads_partial_request_head`,
  `conn_accepts_eof_when_idle`, `conn_rejects_eof_during_partial_head`,
  `server_accepts_eof_while_busy`, `conn_reads_body_and_reports_end`,
  `closed_conn_cannot_read_or_write`, `conn_writes_chunked_body`. The client-only tests are not
  ported.
- `dispatch.rs`: its 3 tests are client-side; the server equivalent of `body_empty_chunks_ignored`
  (an empty data frame from a `TBodySource` never reaches `WriteBody`) is added.
- Ported integration regression tests: `tests/h1_flush_before_yield.rs` (body: data, Pending,
  end-of-stream within one poll loop → bytes flushed before yielding) and
  `tests/h1_shutdown_while_buffered.rs` (never `shutdown` with bytes buffered), both against the
  mock transport with a scripted write limit.
- State-machine tables: for each (Reading, Writing, KA) combination reachable, the transitions of
  `TryKeepAlive`, `StIdle`, `DisableKeepAlive`, `OnReadHeadError`; generated from the Rust code
  paths by hand, checked against hyper by running the same scripted IO through a small Rust
  harness (the M2 differential approach, `tests/unit/*_diff_rs`), extended to drive hyper's
  `server::conn::http1` over a mock IO and print the wire bytes.
- Exchange tests: answer inside `Call`; answer from a timer; answer from a worker; cancel during
  each; `Defer`/`Release` balance (heaptrc reports no leak); `want`/100-continue ordering.
- Loop tests (M3.1): timer wheel (random arm/cancel/advance against a sorted reference);
  MPSC stack with 8 producer threads; eventfd batching; closed-during-batch (F10 regression:
  close a connection from a completion that precedes its own event in the same batch).

### 8.3 The 105 wire cases

- Assertion mode: `runner run --server 'wdconf --handler-mode inline' cases/h1` and again with
  `--handler-mode blocking`, and with `--loops 4`. Target: 104 pass + 1 pending, same as the
  reference server.
- Diff mode: `runner diff --a target/release/reference-server --b 'wdconf' cases/h1` → `same=104`.
- Determinism: 3 consecutive runs of each, as the M1 manifest did for the reference server.
- Order of bring-up (M3.4 → M3.6): hello_world/unreachable cases first, then test_service without
  upgrades, then timeouts, then upgrades and graceful shutdown.

### 8.4 Production-profile wire check

The cases run against `HyperDefaultH1Config`. A second run uses `WdProductionH1Config` plus each
case's explicit config fields, in diff mode; the only allowed differences are `read_once`
segmentation (D1), which those cases already mark `diff_capture: false`. Any other difference is a
bug in the D1-D5 table.

### 8.5 Fuzz and soak

- Split fuzz: a `TMockTransport` that delivers the input in random-size reads and accepts random
  partial writes with random `EAGAIN`s; for every M1 case input and every M2 corpus request, the
  output bytes must equal the unsplit run. Thousands of seeds per CI run.
- Differential fuzz vs hyper: generated request streams (M2 parser corpus + mutations, pipelined,
  with bodies, chunked, trailers, expect) sent to the reference server and to `wdconf` with the
  same config; compare wire bytes (date normalized) and events (the runner's diff logic). Run
  as generated case files, so failures become regression cases.
- Slow clients: 10k connections sending a head one byte per 100 ms (exercises `PartialLen`
  incremental parsing and the header timer); CPU per byte must stay flat (no O(n²)).
- Soak: 1 h wrk mixed load (plaintext, a 64 KiB body, a chunked stream, a blocking handler with
  1 ms sleep), plus random client disconnects: RSS flat after warm-up, open fd count back to
  baseline, debug build with `-gh` (heaptrc) reports no leaks, `valgrind --tool=memcheck` run of a
  short soak for use-after-free (F10 class).

### 8.6 Performance measurement method and gate

- Same harness as section 1 (`bench2.sh`), against the real `bearings.server` plaintext app and the
  same hyper binary, every milestone from M3.4 on:
  - configuration A (server 0-7, wrk 8-15, 8 wrk threads) and configuration B (server 0-3, wrk
    4-15, 12 wrk threads);
  - c=256 and c=1024, depth 1 and 16; 3 runs per cell, median;
  - metrics: req/s, req per server CPU-second, p50, p99 (depth 1), RSS mid-run; idle-10k RSS
    (`idle.py`).
- Gate: every cell ≥ 0.80 × hyper (hard), report cells < 1.00; depth-1 p99 ≤ 1.25 × hyper's at
  c=256 and c=1024; idle RSS ≤ 2 KB per connection; active RSS ≤ hyper's.
- Latency under fixed load: wrk2 (`-R` at 50 % and 80 % of hyper's max) for p99/p99.9, because
  wrk's histogram is unreliable with pipelining.
- Profiles: `perf record -g` on the server for each milestone; any routine above 3 % that was not
  in the previous profile is investigated before moving on.
- The micro-benchmarks of T6 (`bench_role`, `reqcost`, `frames`) run in CI with a ±10 % budget.

---

## 9. Layout, implementation order, risks

### 9.1 Units

```
src/
  http1/                      (M2, kept; M3.0 edits marked *)
    bearings.http1.parser.pas
    bearings.http1.decode.pas
    bearings.http1.encode.pas       * trailer fixes, no managed fields
    bearings.http1.role.pas         * PByte destination, slice reason phrase
    bearings.http1.reason.pas
    bearings.http.headers.pas       * TryAdd/TryInsert/AddTrusted validation boundary
    bearings.http.uri.pas
    bearings.http.date.pas
    bearings.http1.io.pas           new: TReadStrategy, TH1Io, TH1WriteBuf, TTransport, TTcpTransport
    bearings.http1.conn.pas         new: TH1Conn
    bearings.http1.dispatch.pas     new: TH1Config, TH1Dispatcher
  http/
    bearings.http.body.pas          new: TBodyData, TBodySource, TChannelBody, TBodySink
    bearings.http.exchange.pas      new: TExchange, TResponseSpec, TUpgradeHandler, request-body slot
    bearings.http.service.pas       new: THttpService, TBlockingHandler
  rt/
    bearings.rt.sys.pas             new: raw syscalls (accept4, epoll_*, eventfd2, writev, sendfile,
                              sched_*), constants; returns -errno, no threadvar errno
    bearings.rt.cpu.pas             new
    bearings.rt.clock.pas           new: vDSO clock
    bearings.rt.timer.pas           new: TTimerWheel
    bearings.rt.mpsc.pas            new
    bearings.rt.bufpool.pas         new
    bearings.rt.loop.pas            new: TLoop, TIoSource, TConnDriver
    bearings.rt.listener.pas        new
    bearings.rt.stream.pas          new: TUpgradedStream
    bearings.rt.workers.pas         new: TWorkerPool
  server/
    bearings.server.pas             new: TServerConfig, TServer, TConnObserver
conformance/pascal-server/
  wdconf.pas                  program
  wdconf.spec.pas             JSON spec + validation
  wdconf.events.pas           TEventWriter, observer
  wdconf.service.pas          test_service / hello_world / unreachable, TScriptedBody
  wdconf.upgrade.pas          upgrade threads, latches
tests/unit/
  test_h1_io.pas, test_h1_conn.pas, test_h1_dispatch.pas, test_rt_timer.pas,
  test_rt_loop.pas, test_exchange.pas, test_headers_validate.pas, test_trailers_diff (*_rs)
bench/
  plaintext.pas (bearings.server app), bench2.sh, idle.py, pipeline.lua, hyper-tfb/ (Rust, test tooling)
```

### 9.2 Implementation order (each step has a check that can fail)

| step | content | verified by |
|---|---|---|
| M3.0 | M2 changes: header validation, trailer T1-T5, no managed fields in `TEncoder`/`TResponseHead`, `ServerEncode` to `PByte` | the 506 existing tests + new validation/trailer tests + trailer diff vs hyper; `bench_role` parse/encode not slower than 152/121 ns |
| M3.1 | `bearings.rt.*`: syscalls, cpu, clock, timer wheel, MPSC, buffer pool, loop, listener | unit tests (8.2 loop part); a raw static-response server on the loop matches `wdproto` within ±3 % in configuration B |
| M3.2 | `bearings.http1.io` | io.rs ports (8.1) |
| M3.3 | `bearings.http1.conn` | conn.rs ports, state tables, mock-IO diff vs hyper |
| M3.4 | dispatcher + exchange (inline only) + `bearings.server` + plaintext bench app; `wdconf` with hello_world/unreachable | first conformance cases; **perf gate** (8.6), the first real check of the 420 ns budget |
| M3.5 | `wdconf` complete for test_service (bodies, streams, delays, trailers, events, control) | 105 cases assertion + diff mode, inline |
| M3.6 | upgrades/CONNECT, `without_shutdown`, graceful shutdown, header timeout, `TServer.Stop` | the remaining cases; graceful stop test under load (no reset connections beyond R7) |
| M3.7 | worker pool, `Offload`, `ReadBodyBlocking`, `TChannelBody`, cross-thread answers | 105 cases with `--handler-mode blocking`; T3 numbers reproduced or better |
| M3.8 | sendfile, split fuzz, differential fuzz, soak, RSS, final perf matrix | 8.5 and 8.6 all green |

### 9.3 Risks and mitigations

| # | risk | mitigation |
|---|---|---|
| R1 | The full engine costs more than the 420 ns budget over the prototype (section 1.4) and lands below 80 % at depth 16. | Perf gate from M3.4 on; inline fast path with no atomics/allocation/strings; no implicit frames (T6); profile every milestone; keep `TH1Conn` an embedded record (no pointer chasing). |
| R2 | Edge-triggered bugs: a missed edge leaves a connection stuck. | Single readiness cache rule (set on event, clear only on EAGAIN or short read); `MaybeNotify` ported; split fuzz with random EAGAIN (8.5); a debug-mode watchdog that flags connections with `rdRead` set and no progress for 1 s. |
| R3 | Use-after-free between loop, workers and deferred frees (F10 happened in the prototype). | Free only after the batch; exchange reference counts; generation counter on wakes; heaptrc + valgrind in soak; F10 regression test. |
| R4 | Measurement noise and client limits on this hybrid CPU. | Configuration B + per-CPU-second metric + 3-run medians; re-run the matrix on the real 16-core target when available. |
| R5 | hyper quirks that are easy to "fix" by accident: pending upgrade surviving a non-101 response; `handler` started before the first poll; 100 Continue only on first body poll; `MidMessageDetectEof` skipped when bytes are buffered; header timer reset on idle. | Port function by function with hyper line references in comments; conn-level diff tests against hyper over mock IO; diff mode on all cases. |
| R6 | Blocking pool too slow for some apps (T3: ~5 us per request). | Route-level `inline`; measured tuning options (spin-then-park, per-loop affinity) in M3.7; document the cost. |
| R7 | `SO_REUSEPORT`: a stalled loop stops accepting for its share of connections; closing a listener resets queued connections. | Drain the accept queue before closing; `amSharedExclusive` option; a stall detector (loop iteration > 100 ms logged). |
| R8 | `PipelineFlush` default differs from hyper. | Conformance runs with hyper defaults; production-profile diff run (8.4); open question 1. |
| R9 | FPC 3.2.2 code generation (no SIMD intrinsics, setjmp exception frames, no inlining across units without `inline`). | Prototype already beats hyper with scalar code; SIMD scanners stay optional (M2 kept their contract); `{$inline on}` on small accessors; check generated asm for the hot loop. |
| R10 | Header validation adds cost on every response header. | Table-driven check (~20 ns per response); `AddTrusted` for constants; measured in M3.0. |

---

## Appendix A: prototype files and how to reproduce

All under `scratchpad/m3-perf-proto/` (absolute:
`/tmp/claude-1000/-home-jps-Code-wd-40/62837eb9-c099-4368-bb76-aa16b61b7d64/scratchpad/m3-perf-proto/`).

| file | what |
|---|---|
| `hyper-tfb/` | hyper TFB plaintext baseline (Cargo project; `PFLUSH=0` env switches `pipeline_flush` off; `THREADS` env) |
| `loop/wdproto.pas` | loop prototype (env `THREADS`, `PIN=1`, `LISTEN=exclusive`, `READSZ`, `FLUSH_EACH=1`, `POOL=1`) |
| `loop/wdpool.pas` | inline vs worker-pool offload (env `MODE=inline|pool`, `WORKERS`) |
| `micro/reqcost.pas`, `micro/frames.pas` | T6 micro-benchmarks |
| `bench2.sh` | wrk matrix with CPU and RSS (env `WRK_CPUS`, `WRK_THREADS`, `CONNS`, `DEPTHS`) |
| `pipeline.lua`, `idle.py` | TFB pipelining script; idle-connection RSS test |

Build: `fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fu/home/jps/Code/wd-40/src/http1 -FUunits -owdproto wdproto.pas`
(units are written to the scratchpad, nothing under the project). `cargo build --release` in
`hyper-tfb/`. wrk: `scratchpad/vendor/wrk/wrk`.

Example (configuration B):

```sh
WRK_CPUS=4-15 WRK_THREADS=12
THREADS=4 taskset -c 0-3 hyper-tfb/target/release/hyper-tfb 18080 &   ./bench2.sh hyper 18080 $!
POOL=1 taskset -c 0-3 loop/wdproto 18081 &                              ./bench2.sh wd 18081 $!
```
