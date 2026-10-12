# bearings design

This document explains how bearings is built and why: the decisions, the
invariants a contributor must respect, and the places where it behaves
differently from what an HTTP library usually does. It names the units,
types and routines that implement each part; the header comment of each unit
under `src/` describes that unit in more detail, and `docs/api.md` says how a
program uses the library. Where this document and the code disagree, the code
is right.

Contents:

1. Purpose and scope
2. Threading model
3. Readiness and I/O
4. Timers and the clock
5. Connection state machine and the request path
6. The exchange and the service API
7. Memory
8. Header validation
9. Verification
10. Deviations register
11. Risks and known limits

## 1. Purpose and scope

bearings is an HTTP/1.1 server library for Free Pascal 3.2.2 with three
parts: an event loop per CPU (`bearings.rt.loop`), a pool of worker threads
for code that blocks (`bearings.rt.workers`), and an HTTP/1.1 engine (parser,
encoder, body codec, connection state machine, dispatcher: the
`bearings.http1.*` units). `TServer` (`bearings.server`) ties them together.
An application gives the server a service object; the server calls it once
per request with a `TExchange` (`bearings.http.exchange`) and writes the
response the service produces.

It speaks HTTP/1.1 and HTTP/1.0 over plain TCP or a Unix domain socket:
keep-alive, pipelining, chunked bodies and trailers, `Expect: 100-continue`,
connection upgrades (the socket is handed over after a `101 Switching
Protocols` response), request body backpressure, streamed responses with
backpressure, file bodies with `sendfile(2)`, graceful shutdown, a connection
limit, systemd socket activation and notifications, an access log and
metrics.

It has no TLS, no HTTP/2 and no WebSocket protocol code. TLS belongs to a
reverse proxy such as nginx in front of the server. WebSocket support on top
of the upgrade hand-off is planned in `docs/handoff-websocket.md`. The types
of the service API are protocol-neutral so that an HTTP/2 session can use
them later (section 6).

Platform: Linux x86_64 only. The runtime calls the kernel through its own
system call stubs (`bearings.rt.sys`: `epoll_wait`, `epoll_ctl`, `eventfd2`,
`accept4`, `read`, `write`, `writev`, `sendfile`, `futex`,
`sched_getaffinity`, and the socket calls), not through the FPC RTL units.
The stubs return the raw kernel result, `-errno` on failure, and never write
FPC's errno threadvar. The lock-free code assumes the x86-64 memory model
(section 11). Programs are compiled with `{$mode objfpc}{$H+}` and must list
`cthreads` first.

Layers: `src/rt` (runtime, knows nothing about HTTP), `src/http1` (the
HTTP/1.1 engine), `src/http` (the exchange and the error type), `src/server`
(`TServer`, the access log, the metrics). `src/rt` uses nothing from the
other directories. The README has the table of units.

Two goals shape most decisions below. The first is throughput: the request
path of a service that answers on the loop thread allocates nothing, takes
no lock, executes no atomic instruction and enters no implicit exception
frame (section 7); the measured result is 0.85 to 0.98 of hyper's throughput
on the plaintext benchmark (`docs/design/m3-perf-report.md`). The second is
strictness on the wire: the parser and the body decoder reject what the
RFC 9110 and RFC 9112 grammars reject, because a server and a proxy in front
of it must agree on where each request ends (request smuggling). The
conformance harness checks the wire behaviour against hyper's reference
server (section 9); that is a fact about the test tooling, not a design
input.

## 2. Threading model

**One event loop per CPU.** `TServer.Start` creates `TServerConfig.Loops`
loops, or `DefaultLoopCount` (`bearings.rt.cpu`: the CPUs in the process's
affinity mask, capped by the cgroup CPU quota, at least 1) when that is 0.
Each `TServerLoop` runs one `TLoop` on its own thread and owns its listening
socket or its share of one (section 3), its own instance of the service
(`TServiceFactory` is called once per loop), its exchange pool, its block
pool, its timer wheel and the list of its open connections. `PinLoops` binds
loop i to the i-th usable CPU; it is off by default (it measured within 1 %).

**A connection lives on the loop that accepted it.** `TServerLoop.OnAccept`
creates the connection task (`TH1Dispatcher`, `bearings.http1.dispatch`) on
the accepting loop, and that task reads, parses, calls the service and
writes until the connection closes. Nothing on the inline request path
touches another loop's data, so there is no lock and no atomic instruction
on it. Cross-thread traffic exists only for exchanges handed to workers or
other threads, and for server-wide commands (stop, graceful shutdown, the
metrics snapshot, the watchdog ping, resuming listeners paused by the
connection limit).

**Loops never block.** Every socket is non-blocking. `TLoopTask.Run` does as
much work as it can without blocking and returns; the HTTP/1 task runs its
read/write/flush loop at most 16 times per `Run` (`TH1Dispatcher.PollLoop`)
and then yields, a listener accepts at most `ACCEPT_BATCH` (64) connections
per event, and a loop iteration runs at most `RUN_QUEUE_BUDGET` (61) queued
tasks before it polls epoll again. Code that blocks (a database, a file, a
blocking body read, `Sleep`) runs on the worker pool.

**One loop iteration** (`TLoop.RunIteration`):

1. `epoll_wait`, with timeout 0 when the run queue or the inbox is not
   empty, else the delay to the next timer (at most 1 s while the block pool
   holds memory, so that idle blocks are trimmed; without limit otherwise).
2. The clock is sampled once (`NowNs`, `NowMs`; section 4), the tick hook
   runs if due, and the block pool is trimmed after 1 s without events.
3. The event batch: a listener event accepts; a connection event adds the
   readiness bits to the task's `TIoSource` and calls `OnIo`, which runs the
   task at once; the eventfd is read to reset it.
4. The inbox is drained: `lmWakeExchange` wakes the exchange's connection
   task, `lmFreeExchange` recycles an exchange, `lmCall` runs a procedure.
5. `Timers.Advance(NowMs)` fires the due timers (their procedures wake
   tasks).
6. Up to 61 tasks from the run queue.
7. The tasks closed in this iteration are freed (`Close` only marks a task
   and puts it on a deferred-free list, because a later event of the same
   batch may still name it).

**The run queue** holds the reasons to run a task other than a socket
event: `Wake` (loop thread only) appends the task unless it is already
queued; a task that wakes itself while running is appended after `Run`
returns, so it runs once more in the same iteration if the budget allows
(this is how the HTTP/1 task yields after 16 iterations). A socket event
for a queued task only sets readiness bits; the queued run sees them.
Socket events call the task directly instead of going through the run
queue; the saved hop measured one read and one write per request batch.

**Cross-thread wakes** go through the loop's inbox (`TLoop.Post`): an
intrusive lock-free stack (`TMpscStack`, `bearings.rt.sync`) of `TLoopMsg`
records that live inside their senders (an exchange holds its `WakeMsg` and
`FreeMsg`), so posting allocates nothing. The eventfd is written only when
the push found the stack empty and the loop may be asleep: the loop sets
`Sleeping` to 1 before `epoll_wait` and then checks the inbox once more, so
a post that races with going to sleep is not lost, and a post to an awake
loop costs one compare-and-swap and no system call. `Post` counts itself in
`Posting` from before the push to its last access of the loop, because the
message may be handled, and the exchange that sent it recycled, while the
posting thread still reads the loop; `TServer.Destroy` waits for that count
to reach 0 before it frees a loop.

**Exceptions.** FPC enters a `try` block with `fpc_pushexceptaddr` and
`fpc_setjmp` (12 to 20 ns), so no per-request routine has one. `TLoop.Run`
holds a single `try/except` around the iteration loop. An exception that
escapes a task aborts that task: `LoopErrorProc` logs it (default: one line
on stderr), `Abort` releases everything without a completion event, `Close`
frees the task after the batch, and the loop resumes the interrupted event
batch at `FEventPos` without another `epoll_wait`. Inbox messages already
taken are kept in `FMsgHead`. Worker threads catch exceptions per job
(below), and the listener catches an exception from per-connection setup for
that connection only.

**The worker pool** (`TWorkerPool`): a fixed set of threads with a FIFO
queue under a pthread mutex. `TExchange.Offload` (loop thread) calls `Share`
and submits the exchange itself as the work item (`TExchange` derives from
`TWorkItem` and carries the queue link), so queueing allocates nothing. The
worker runs `TBlockingHandler.Run(Ex)` inside one `try/except`; an escaping
exception becomes a failed answer with the text `handler raised <class>:
<message>` (or an aborted stream if one was begun), and a handler that
returns without a terminal call is failed with `handler returned no
response` (section 6). The worker's terminal call changes the exchange's
state with a compare-and-swap and wakes the connection through the inbox.
An idle worker spins on the queue for `SpinNs` (20 us; at most one worker
spins) before it parks on a futex, so a steady stream of items costs no
futex wake; the measured cost of an offloaded request is about 2.3 to 2.7 us
of CPU over an inline one (`bench/run_offload.sh`). The default pool size
is `Min(32, DefaultLoopCount + 4)`; `NO_WORKER_POOL` (-1) starts none.

**Which thread may call what.** `THttpService.Call`, `TServiceCall.Poll` and
`Drop`, `TBodySource.PollFrame`, the upgrade callbacks and the observer
hooks run on the loop thread and must not block. `TBlockingHandler.Run`
runs on a worker and may block. An unshared exchange may be used only on
its loop thread; after `Share` any holder may use it (section 6). `TServer`
is created, started, waited for and freed by one owning thread; `Stop` may
be called from any thread. `docs/api.md` section 1 and 14 have the full
tables.

**Synchronization primitives** (`bearings.rt.sync`): `TMpscStack` (the
inbox), `TParker` (one waiter: idle workers, a worker waiting for body
bytes), `TEventCount` (any number of waiters: producers of a stream waiting
for room), `TSpinLock` (a shared exchange's body channel and stream queue,
held for a few instructions and never across a system call). The futex
primitives make the system call only when a thread is, or is about to be,
asleep. The code relies on x86-64 ordering: locked instructions are full
barriers and aligned word loads and stores are atomic. Builds with
`-dWD_DRD` give valgrind's drd race detector the happens-before edges of
these primitives through client requests (section 9).

**Other threads.** The access log's flusher thread (`bearings.server.accesslog`)
and the systemd watchdog thread (`bearings.server`) are the only threads
besides the loops, the workers and the owner. Each loop formats access-log
lines into its own double buffer under a spin lock; the flusher swaps the
areas and writes outside the lock, so a slow sink costs dropped lines, never
a stalled loop. The metrics are per-loop records written only by their loop;
a snapshot asks each running loop for a copy on its own thread.

**Server-wide shutdown.** `TServer.Stop(GraceMs)` posts a stop message to
every loop and returns. Each loop accepts what is still in its accept queue
(`TListener.DrainAndClose`, until `EAGAIN`), closes the listener, calls
`GracefulShutdown` on every connection, and leaves its `Run` when its last
connection closed or when the grace period passed, aborting what is left.
`Wait` joins the loop threads, shuts the worker pool down (queued items still
run, up to `WorkerWaitMs`) and flushes the access log. `Destroy` then aborts
any connection still open, processes every loop's inbox until every exchange
is back in its pool and no thread is inside `Post`, and only then frees the
loops and pools; if a worker or an outside holder is still alive after
`WorkerWaitMs`, the loops and pools are leaked on purpose, because another
thread may still post to them.

## 3. Readiness and I/O

**Registration.** A connection socket is added to the loop's epoll set once,
with `EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET` and `data.ptr` pointing
at the task's `TIoSource` (`TLoop.Register`), and the registration is never
modified; backpressure is simply not calling `read` or `write`. Removal is
implicit at `close`, except for a detached upgraded connection
(`TLoop.Unregister`). Level-triggered epoll was rejected: it reports a
socket on every `epoll_wait` while its connection waits for the application,
and toggling `EPOLLOUT` costs an `epoll_ctl` per blocked write. Listening
sockets and the eventfd are level-triggered (`data.ptr = nil` for the
eventfd).

**Readiness bits** (`TReadyBit`, `ReadyFromEpoll` in `bearings.rt.loop`):
`EPOLLIN` or `EPOLLPRI` sets `rdRead`; `EPOLLOUT` sets `rdWrite`;
`EPOLLHUP`, or `EPOLLIN` together with `EPOLLRDHUP`, sets `rdReadClosed`;
`EPOLLHUP`, `EPOLLOUT` with `EPOLLERR`, or an event that is exactly
`EPOLLERR`, sets `rdWriteClosed`; `EPOLLERR` sets `rdError`. The closed and
error bits are sticky: once set they stay, because the condition cannot go
away.

**The transport rules** (`TTcpTransport`, `bearings.rt.net`): `Read` calls
`read(2)` only when one of `rdRead`, `rdReadClosed`, `rdError` is set; on
`EAGAIN` or a short read (fewer bytes than asked) it clears `rdRead`. A short
read is taken to mean that the kernel's receive buffer is empty, which is how
Linux behaves for TCP. `Write` calls `write(2)` only when one of `rdWrite`,
`rdWriteClosed`, `rdError` is set; `EAGAIN` or a short write clears
`rdWrite`. `WriteV` and `SendFile` clear `rdWrite` only on `EAGAIN`: a short
`writev` or `sendfile` keeps the bit, so the caller tries again and gets the
`EAGAIN` if the buffer really is full. When the needed bit is clear the call
returns `-EAGAIN` without a system call. An edge-triggered socket must be
used until `EAGAIN` before the task waits, or the next edge never comes;
these rules guarantee that a missing bit always means the kernel said
`EAGAIN` (or gave a short transfer) since the last event.

Why the sticky bits matter: when a client writes a request and closes, the
data and the FIN often arrive in one event. The head read is short, so
`rdRead` is cleared; without a sticky `rdReadClosed` the next read (the one
that detects the client's EOF while the response is in progress, section 5)
would return `-EAGAIN` without a system call and the EOF would be lost. With
the sticky bit the read calls the kernel, gets 0, and the connection ends.

**The transport interface** (`TTransport`): `Read`, `Write`, `WriteV`,
`SendFile`, `ShutdownWrite`, `Close`, each non-blocking and returning the
raw result (bytes, 0 for EOF, `-errno`). A transport may wrap another
(`Wrapped`, `DisownWrapped`): the conformance server counts bytes that way,
and the upgrade hand-off follows the chain down to the socket. The default
`WriteV` writes the first non-empty slice only and reports
`IsWriteVectored = False`; the default `SendFile` returns `-ENOSYS`, which a
future TLS transport would do too.

**Accepting** (`TListener`, a level-triggered `TIoTask`): on each event
`accept4` with `SOCK_NONBLOCK or SOCK_CLOEXEC`, at most 64 times or until
`EAGAIN`. `EINTR`, `ECONNABORTED`, `ECONNRESET` and `ECONNREFUSED` lose only
that connection and the loop takes the next one. Any other error (`EMFILE`,
`ENFILE`, `ENOBUFS`, `ENOMEM`, ...) is counted, logged at most once per
second, and the listener leaves the epoll set for `ACCEPT_PAUSE_MS` (1 s,
through a loop timer); a level-triggered listener with a non-empty accept
queue would otherwise be reported by every `epoll_wait` and the loop would
spin until descriptors are free. Connections wait in the kernel's queue
meanwhile. An exception from per-connection setup in `OnAccept` is caught by
the listener for that connection: the socket is closed, `SetupErrors`
counted, the error logged at most once per second, and accepting goes on.
`TLoop.Create` sets its descriptors to -1 before any system call, so a
constructor that fails part-way closes only what it opened. Connection ids
are `QWord(LoopIndex) shl 48 or NextConnSeq`, unique per server without an
atomic.

**Three accept modes** (`TAcceptMode`, set up by `bearings.server`):
`amReusePort` (production default): one listening socket per loop, all bound
to the same port with `SO_REUSEPORT`; the kernel spreads new connections
over them; with port 0 the first loop binds a free port and the others bind
that port. `amSharedExclusive`: one listening socket; every loop registers
its own `dup` (`F_DUPFD_CLOEXEC`) with `EPOLLIN or EPOLLEXCLUSIVE`, so the
kernel wakes one waiting loop per connection; each loop takes its dup out of
its epoll set before closing it, because an epoll entry lives as long as the
open file, not the descriptor. `amSingle`: one listener on loop 0. The
listening socket gets `SO_REUSEADDR`, the configured backlog (4096 in the
production preset) and `TCP_NODELAY` when `NoDelay` is set; Linux copies
`TCP_NODELAY` to every accepted socket. A Unix domain socket
(`TListenSpec.UnixPath`) replaces `amReusePort` by `amSharedExclusive`
(there is one path); a listening socket passed in by systemd
(`InheritedFd`) is shared the same way.

**The connection limit** (`TServerConfig.MaxConnections`) is one atomic
counter shared by all loops; a listener takes a slot before each `accept4`
and, at the limit, leaves epoll (`PauseForLimit`) instead of refusing: new
clients wait in the accept queue. The closing connection gives the slot back
(`TConnHooks.ConnDone`), resumes its own loop's listeners and posts a
message to the other loops to resume theirs; a 1 s timer is the fallback.
With the limit off the accept path tests one integer.

`SIGPIPE` is ignored process-wide at `Start` (`IgnoreSigPipe`): a write to a
reset socket then returns `-EPIPE`, which ends that connection only.

## 4. Timers and the clock

**The clock** (`bearings.rt.clock`) is libc's `clock_gettime`, which runs in
the vDSO (about 11 ns; FPC's own wrapper makes a system call, about 89 ns).
The loop samples `CLOCK_MONOTONIC` once per iteration, right after
`epoll_wait` returns (`TLoop.NowNs`, `NowMs`), and every timeout, deadline
and duration in the library is measured with that value: no connection
reads the clock itself. A consequence: a request answered in the iteration
that read it has a measured duration of 0 (access log, metrics), and a timer
armed late in a long iteration is measured from the iteration's start.
`CLOCK_REALTIME` is read only to build the Date header.

**The timer wheel** (`TTimerWheel`, `bearings.rt.timer`): 6 levels of 64
slots at 1 ms resolution (level L covers 64^L ms per slot), one per loop,
loop thread only. A wheel, not a heap, because a server arms a timer per
request of every keep-alive connection and cancels nearly all of them before
they expire: arm, cancel and move are O(1), and the next expiry is found with
bit operations over the occupancy masks. Lazy arm: moving a deadline later
only stores the new deadline (the entry is filed again when its slot
expires); lazy cancel sets the deadline to 0 and the entry is dropped when
its slot expires. So the header-read timer of a keep-alive connection costs
two stores per request. A deadline is rounded up to the next tick and the
current time rounded down, so a timer never fires before its deadline.
Timers are `TTimer` records embedded in their owners (no allocation);
`Remove` unlinks one before its owner is freed. Users: the header read timer
and the body timer of a connection, the listener's resume timer, the stop
deadline of a loop, the application's `TWakeTimer`, and the stall detector's
scan.

**The Date header** (`bearings.http.date`) is formatted once per second per
loop. `src/rt` does not depend on the HTTP units, so the loop offers one
generic hook: `LoopTickProc`, a procedure the loop calls once at creation
and again when the delay the last call returned has elapsed (one comparison
per iteration), with per-loop storage in `TLoop.Ext` (`LOOP_EXT_BYTES`, 64
bytes, zeroed). `bearings.http.date` assigns the hook in its initialization
and keeps the `TDateCache` in `Ext`; the response encoder copies the 29
bytes from `LoopDate(Loop)`, so no threadvar is read on the request path.
Code outside a loop uses the threadvar cache (`DateBuffer`).

## 5. Connection state machine and the request path

Three units: `bearings.http1.io` (`TH1Io`: the read buffer, the write buffer
and the flush), `bearings.http1.conn` (`TH1Conn` and `TConnState`: the
HTTP/1.1 state machine of one connection), `bearings.http1.dispatch`
(`TH1Dispatcher`: the loop task that drives the state machine and moves
requests between it and the service). `bearings.http1.config` holds the
options (`TH1Config`), the two presets (`ConformanceH1Config`,
`ProductionH1Config`), their validation and `ApplyH1Config`.

### 5.1 Reading a request head

`TH1Dispatcher.PollReadHead` takes an exchange from the loop's pool before
anything is parsed, because the head is parsed into the exchange's header
list. `TH1Io.Parse` calls `ServerParseHeaders` (`bearings.http1.role`) on the
unread bytes; the parser (`bearings.http1.parser`) checks the syntax byte by
byte against the RFC 9110 and 9112 grammars, and `bearings.http1.role` applies
the HTTP rules. Nothing is copied: the header list gets external entries
whose offsets are relative to the head, the target is split into slices by
`bearings.http.uri`, and the head leaves the read buffer as a pinned view
(`TReadBuf.SplitTo`). A head that arrives in pieces is parsed again only when
the new bytes hold an end of head (`IsCompleteFast` scans from 3 bytes
before the previous length), so a slow client costs no repeated full parse.

Each read asks the socket for `TReadStrategy.Next` bytes: 8 KiB at first,
doubled after a read that filled it, halved after two reads in a row that
used less than half, and never more than `max_buf_size - Len`, so the read
buffer never holds more than `max_buf_size` (`DEFAULT_MAX_BUFFER_SIZE`,
417 792 bytes; minimum 8192). Limits with their automatic responses: a
request-target over `MAX_URI_LEN` (65 534 bytes) gives 414; more than
`MaxHeaders` fields (100 by default), a head over `MaxHeaderSize`, a head
that reaches `max_buf_size`, or a header name of 64 KiB or more gives 431;
any other syntax error gives 400 (`ServerErrorStatus`).

**Framing and smuggling.** `bearings.http1.role` decides the body length
(RFC 9112 section 6.3): `Transfer-Encoding: chunked` wins over
`Content-Length`; when both are present the `Content-Length` lines are
dropped from the list and the connection closes after the response; a
`Transfer-Encoding` whose last coding is not `chunked`, a `Transfer-Encoding`
in an HTTP/1.0 request, an invalid `Content-Length`, or several
`Content-Length` values that differ are rejected with 400. The lenient
options of `TParserConfig` are all off by default. The body decoder
(`TDecoder`, `bearings.http1.decode`) is a resumable state machine that
returns slices of the read buffer and ends the connection on any malformed
chunk-size line, missing CRLF, overflowing size or oversized extension;
trailers are copied into a per-connection scratch buffer and parsed into the
exchange's `ReqTrailers` list under the same header limits.

### 5.2 States and keep-alive

`TConnState` keeps the reading and the writing side apart: `Reading` is
`rdInit` (waiting for or parsing a head), `rdContinue` (head read with
`Expect: 100-continue`, body not asked for yet), `rdBody`, `rdKeepAlive`
(request complete; wait for the response) or `rdClosed`; `Writing` is
`wrInit`, `wrBody`, `wrKeepAlive` or `wrClosed`. `KeepAlive` (`TKA`) is
`kaBusy` during a request, `kaIdle` between requests and `kaDisabled` once
the connection must close after the current response. When both sides reach
their keep-alive state, `TryKeepAlive` resets both to `Init` or, if keep-alive
is disabled, closes both. `Idle` sets `NotifyRead` when a header read timeout
is configured, so the dispatcher loops once more and re-arms the timer right
after the response; the header read timeout therefore also bounds an idle
keep-alive connection. After a response, `MaybeNotify` tries one read when
the buffer is empty and sets `NotifyRead` when bytes are buffered, so a
pipelined request is parsed without waiting for another readiness event.

HTTP/1.1 keeps the connection open unless either side sent
`Connection: close`; HTTP/1.0 closes unless the client sent
`Connection: keep-alive`. `EnforceVersion` answers a 1.0 client with a 1.0
response and adds `connection: close` to a 1.1 response when the server will
close (`FixKeepAlive` for 1.0). A response body of unknown length to a 1.0
client can only end by closing the connection.

**One request at a time.** The next head is parsed only when no service
call is in flight (`InFlight = nil`) and the state is back to `rdInit`.
Pipelined requests wait unparsed in the read buffer, and responses leave in
request order without any reordering structure, because nothing on the wire
says which request a response answers. A slow handler delays the later
requests of its own connection, not those of other connections.

### 5.3 The service call

`RecvMsg` fills the exchange's head and opens the body channel, then calls
`THttpService.Call(Ex)`, which returns a `TServiceCall` and must not answer
or read the body (builds with assertions check it). The handler's code runs
only in `TServiceCall.Poll`, which `PollMsg` calls from `PollWrite` every
time the connection runs while the call is in flight, until it returns
`cpReady` after exactly one terminal call. Two steps instead of one because
the same `PollLoop` iteration runs the rest of `PollRead` between them: it
fetches the first body chunk into the channel before the handler's first
poll (so a handler that reads finds data), and it may detect the client's
EOF, in which case the call is dropped (`Drop(Ex, False)`) without ever
being polled. A stateless call object returned for every request costs one
virtual call and no allocation.

### 5.4 Writing

A response head is encoded by `ServerEncode` straight into the write cursor
(`TWriteBuf.Headers`, a `TByteVec` over a pooled block) when nothing is
queued. The encoder chooses the framing and returns a `TEncoder`
(`bearings.http1.encode`): `Content-Length` when the length is known,
`Transfer-Encoding: chunked` when it is not (HTTP/1.1), close-delimited for a
1.0 client; it adds `Date` and a zero `Content-Length` when needed, removes
framing headers from responses that must not have a body (HEAD, 1xx, 204,
304, a 2xx to CONNECT), groups header lines of one name at the position of
the first, joins `Connection`, `Transfer-Encoding` and `Trailer` lines, and
writes names in lowercase unless `TitleCaseHeaders`. A 1xx status other than
101 cannot be sent on this path: a 500 head is written instead and the
connection ends with a user error. An HTTP/0.9 or HTTP/3.0 response version
raises `EH1Panic` before the encoder runs; the loop aborts the connection
task (no response, no completion event).

Body pieces go through `TWriteBuf.Buffer`: an entry of at most
`MAX_COPY_SIZE` (4 KiB) is copied into the cursor and its data released at
once; a larger entry, a file range, and every entry that arrives while
something is queued goes into the queue (`TBufList`, a ring of
`QUEUE_SLOTS` = 32 entries in a pooled block). The cursor is always written
before the queue, so copying a later piece would send it before the queued
bytes; that is why "everything behind a queued entry is queued", and why a
head that must be written while entries are queued (the automatic
400/414/431 of a parse error, the automatic `100 Continue`) is queued behind
them as a `qkBytes` entry (`BufferAfterQueue`) instead of being written into
the cursor between an earlier response's head and body.

`PollFlush` writes the cursor with `write(2)` when nothing is queued, else
the cursor and the queued memory entries with one `writev(2)` (at most
`MAX_WRITEV_BUFS` = 64 slices), and a file entry at the front with
`sendfile(2)` (at most `SENDFILE_MAX_CHUNK` per call). The bytes on the wire
for a file body equal those of a memory body with the file's content; a file
frame in a chunked body gets the chunk framing around the file range
(`BufferFileFrame`). A write that returns 0 with bytes left is reported as
`IO_ERRNO_WRITE_ZERO`. `CanBuffer` bounds the memory one response can hold:
the dispatcher polls the body source only while the write buffer holds less
than `max_buf_size` and fewer than 16 entries are queued.

**Pipeline flush** (`TH1Config.PipelineFlush`, on in the production preset):
while the read buffer still holds bytes of further requests and nothing is
queued, `PollFlush` writes nothing, so the responses to a pipelined batch
leave in one write (measured 4x the pipelined throughput). A queued entry is
written even then, because while it is queued no later head can be buffered
and nothing would wake the task. Once the connection is done, `PollInner`
flushes what pipeline flush held (`HoldsPipelinedWrite`, `PollFlushHeld`)
before an upgrade hand-off, the parts hand-off or the shutdown; without it a
101 response followed by client bytes would be lost (section 10).

### 5.5 Expect, half-close, draining

**`Expect: 100-continue`.** A head with the field, a non-empty body and a
version above 1.0 sets `rdContinue`, and the body channel starts without a
request for data. The connection writes `HTTP/1.1 100 Continue` only when the
handler first reads the body and no response head was written yet
(`PollReadBody` in `rdContinue`), then switches to `rdBody`. A handler that
answers without reading never asks for it, and the client is spared the
upload; a body left unread then goes through draining without a 100.

**Half-close.** With `HalfClose` off (the default) a connection in the
middle of a request keeps one read pending while the response is in progress
(`MidMessageDetectEof`, skipped while the read buffer holds a pipelined
request): EOF there closes the read side and ends the connection with
`incomplete` (no response, no shutdown; the call in flight is dropped). With
`HalfClose` on, the response is finished first.

**Draining.** When the application finished without reading the whole body,
`PollDrainOrCloseRead` reads once and discards what arrives; if the body has
not ended by then, reading is closed and the connection is not reused.

### 5.6 Errors and automatic responses

`OnParseError` runs when a head cannot be parsed. If the read buffer starts
with the HTTP/2 connection preface (`H2_PREFACE`, all 24 bytes), nothing is
written and the outcome is `parse_version_h2`. Otherwise, if no response
was started, a bodyless head with the status of `ServerErrorStatus` (400,
414 or 431) is written with `connection: close`, `content-length: 0` and
`date`, the error is stored, and the dispatcher flushes, shuts the socket
down and then reports the stored error (`TakeError` runs after
`PollShutdown`). Errors are `THyperError` values (`bearings.http.error`), a
plain record whose `Kind` says what failed and whose `Cause` adds an errno, a
decoder error, a fixed text or the connection's cold error text; copying one
is a memory copy and a routine with such a local gets no exception frame.
`OutcomeOf` maps the final result to a `TConnOutcome` in the order of
`conformance/SPEC.md` 7.2 (`ok`, `timeout`, `parse_too_large`,
`parse_version_h2`, `parse`, `incomplete`, `user`, ..., `io`, `other`); the
response body ending before its declared length counts as a user error.

### 5.7 Timeouts

The **header read timeout** (`HeaderReadTimer`; `tsDefault` is 30 s when the
connection has a timer, none without) limits the time from the start of a
head read to a complete head. It is armed lazily before `Parse` and cancelled
lazily when a head is parsed; on expiry the head read fails with
`hekHeaderTimeout` and nothing is written. Because `Idle` re-arms it, it is
also the idle keep-alive timeout.

The **body rate rule** (`BodyReadTimeoutMs`, `BodyMinRate`; 30 s and
1 KiB/s in the production preset, off in the conformance preset) measures
only the time the server waits for request body bytes: a wait starts when
`PollReadBody` finds no byte, which happens only while the handler's channel
has room, and ends with the next frame. The body fails with
`NewBodyIo(ETIMEDOUT)` when one wait lasts `BodyReadTimeoutMs`, or when the
waits since the first byte add up to T >= `BodyReadTimeoutMs` and fewer than
`BodyMinRate` x T / 1000 bytes came (the wait before the first byte counts
only for the first rule). Reading closes, the handler sees a body error
(`BodyErrorIsTimeout`) and answers, and the connection closes after that
response. The outcome is `io`. Both timeouts need `TH1Config.Timer`;
`ValidateH1Config` refuses a timeout without one.

### 5.8 Upgrades and CONNECT

A request with an `Upgrade` header (HTTP/1.1) or the CONNECT method sets
`wantUpgrade`; `PrepareUpgrade` creates a reference-counted `TUpgradeSlot`
(one reference for the connection side, one for the exchange; an older slot
still pending is cancelled) and links it to the exchange. A 101 response, or
a 2xx to CONNECT, makes the encoder mark the response as the connection's
last (`IsLast`), so writing ends in `wrClosed`, `TryKeepAlive` closes the
read side, and `PollInner` sees the pending slot and ends with `dsUpgrade`
without a shutdown. `Finish` then acts by `TH1ConnMode`: `cmWithUpgrades`
takes the transport and the unread bytes out of `TH1Io` (`IntoInner`: the
bytes stay in their pinned block, no copy), builds a `TUpgraded`
(`bearings.rt.stream`) that takes over the socket's readiness source, and
fulfils the slot; a `TUpgradeDelivery` task queued after the observer's
`OnConnClose` calls the handler, so the close is reported before the upgraded
connection starts. `cmPlain` tells the handler `upgrade expected but low
level API in use` and closes the socket. `cmWithoutShutdown` hands the
transport and the unread bytes to the observer as `TConnParts` whenever the
connection ends without error. A slot whose response was not an upgrade
stays with the connection: a later upgrade request replaces it (the older
handler gets `upgrade expected but not completed`), and a connection that
finishes while it is set ends through the upgrade path.

### 5.9 The end of a connection

`PollInner`: after `PollLoop`, once `IsDone` holds, flush what pipeline flush
held, then either prepare the upgrade or, when the mode asks for it,
`PollShutdown` (flush, then `shutdown(SHUT_WR)`, so the client reads the whole
last response followed by EOF) before `TakeError`; an error propagated from
`PollLoop` skips flush and shutdown. `PollCatch` turns an error into the body
channel's `connection error` for a handler still reading. `Finish` then: the
hand-off (5.8); `DropAll` in a fixed order (close the transport if still
owned, cancel the upgrade slot still held by the connection state, cancel
the exchange and drop the call in flight with `Completed = False`, close the
body sender with the incomplete-message error, release the response body
source, cancel and release a pending upgrade not handed on, release the
exchange, `TH1Conn.Done`, unlink from the loop's list, `TConnHooks.ConnDone`);
the outcome to `TConnObserver.OnConnClose`; the hand-off actions; `Close`. `Abort` (an exception, the stop deadline) runs
`DropAll` only, with no completion event.

**Graceful shutdown of one connection** (`GracefulShutdown`): nothing after
the hand-off; else keep-alive is disabled, a connection with nothing read or
written (or writing already closed) is closed at once, and the task is woken
so that an idle connection notices now. What a client sees during
`TServer.Stop`: a request the server has read gets its full response with
`connection: close`; a connection on which no request byte was read when the
stop reached its loop (idle keep-alive, just accepted, a request still in the
socket buffer) is closed without a response; a connection that enters the
accept queue between the last `accept4` and the close is reset by the
kernel.

### 5.10 Wake sources

A task may return "pending" only when something will run it again: a socket
read or write that returned `EAGAIN` in this run (the next readiness event),
a timer, a service call or body source that returned pending (they must
call `Ex.Wake`), a body channel waiting for its receiver (the receiver's next
read wakes the sender), or the task's own wake (yield, the channel's wake).
Builds with `-dWD_DEBUG` check this at the end of every run that returns
pending (`AssertWakeArmed`, counted in `WakeAssertFailures`). Builds with
`-dWD_STALL` add the stall detector: each loop scans its connections once per
second and reports, once, a connection that is mid-message, has not run for
`STALL_MS` (60 s) and waits on the server rather than on the client
(`TH1Dispatcher.StallCandidate`); a connection whose last run waited on a
read or write `EAGAIN` with nothing owed is not reported.

**Server hooks.** `TConnHooks` (`RequestStarted`, `RequestDone`, `ConnDone`,
`UpgradedClosed`) is how the server layer attaches the connection limit, the
metrics and the access log; it is nil when none is on, and the dispatcher
then tests one pointer per event.

## 6. The exchange and the service API

`TExchange` (`bearings.http.exchange`) is one request and its response. It
has three parts with separate rules: the request head (`TRequestHead`,
written by the dispatcher before `Call`, read-only afterwards, valid until the
request is released), the request body channel (`TBodyChan`), and the
response (`TResponseSlot`, written by the handler until the terminal call,
read by the dispatcher after it). Exchanges are pooled per loop
(`TExchangePool`); an HTTP/1 connection reuses its exchange for the next
request while nobody else holds a reference, so the inline path allocates
nothing. `docs/api.md` says how each call is used; this section says why
they are shaped this way.

### 6.1 One terminal call

A call answers with exactly one of `Respond` (a body of known length),
`RespondStream` (a `TBodySource`), `BeginStream` (`RespondStream` with the
exchange's own `TChannelBody`) or `Fail` (no response; the connection closes
with a user error). The state (`TExchangeState`: `xsIdle`, `xsCalled`,
`xsAnswered`, `xsDone`, `xsCanceled`) moves with plain stores on an unshared
exchange. On a shared exchange the first terminal call claims the response
slot (`ClaimAnswer`: a compare-and-swap on `FAnswerClaim` while the state is
still `xsCalled`), writes the slot, and then does the state
compare-and-swap against a cancel; a second terminal call from any thread
finds the slot claimed, returns False and writes nothing, and a claimer that
lost to a cancel takes its body back. The response head (`Status`,
`ResponseVersion`, `SetReason`, `ResponseHeaders`) is not covered by the
claim: it is written by the one thread that will make the terminal call,
before that call; builds with assertions record the first writer and check
every later head write and the claiming call against it. A call that
completes without a terminal call, or a worker handler that returns without
one, is a program error: every build counts it (`NoResponseFailures`) and
fails the exchange (`handler returned no response`); a build with assertions
also raises after the exchange was left consistent.

### 6.2 The request body channel

`TBodyChan` holds at most one chunk. The dispatcher (the sender) decodes the
next chunk from the socket only after the receiver took the previous one and
asked for more (`Want`), so a slow handler stops socket reads and TCP flow
control pushes back on the client; the server never buffers a body beyond
the read buffer. `Want` starts false only for `Expect: 100-continue`;
otherwise the dispatcher fills the slot before the handler's first poll. A
chunk is a pinned view of the read buffer, valid until the next body call.
On the loop the receiver uses `TryRead` (never blocks; `brPending` means the
call is polled again when data arrives); on a worker `Read`, `ReadChunk`,
`ReadAll` and `ReadFrame` park the thread on the channel's `TParker` until
the loop changes the channel. Each side wakes the other only when it
registered for a wake and the registration is consumed by the wake.

Closing the receiver (`ReleaseRequest`, `DiscardBody`, or the release of the
request) makes the dispatcher's next `PollReady` see it closed and run the
drain of 5.5. A read never reports a clean end of body unless the body really
ended (`Terminated`): a receiver closed before that gives `brCanceled` (the
blocking reads raise `EClientGone`), on shared and unshared exchanges alike.
A request without a body reads `brEnd` at once. Body errors arrive as
`brError` with `BodyErrorKind` and the canonical message of
`conformance/SPEC.md` 7.1; after the dispatcher drops the sender at the end
of a connection the reader gets the chunks that arrived and then the
incomplete-message error.

### 6.3 Response bodies

`TBodyData` (`bearings.rt.buf`) is one piece of response body with its
release rule, a plain record without managed fields: `BodyEmpty`,
`BodyStatic` (memory that outlives the write), `BodyString` (one reference
to the string held until the bytes were written, taken with a typecast
assignment so the caller needs no managed local), `BodyHeap` (`FreeMem`
after the write), `BodyFile` (a file range for `sendfile`, the descriptor
closed after the last byte or when the connection drops its queue), and
`BodyCopy` (`bearings.http.exchange`: a copy in a pooled block owned by the
record, not in an exchange buffer, because a queued body can outlive its
request when the exchange is reused). `ReleaseBody` runs on the loop thread
after the bytes left. `Respond` with an empty body writes no body
bytes (the encoder adds `content-length: 0` where the response may carry a
body); otherwise the one frame and the end go out together (`WriteBodyAndEnd`), so a small response is one
contiguous buffer.

A `TBodySource` is polled on the loop thread (`PollFrame`), only while the
write buffer has room (5.4); it returns a frame, trailers, the end, an error
(the connection ends with a user error and a chunked body is left
unterminated) or pending (it must call `Ex.Wake`). `TChannelBody`, the queue
behind `BeginStream`, is a FIFO ring of `TBodyData` under a spin lock,
bounded by `HighWater` bytes (a frame larger than that is accepted when the
queue is empty, so no frame is refused forever): `Write` parks a worker while
the queue is full (`TEventCount`, any number of producers) and returns
`wrWouldBlock` on the loop thread, which cannot park; `TryWrite` never
parks; frame boundaries are kept (one `Write` is one chunk). `Finish` claims
the end under the lock before it copies the trailers, so a second `Finish`
touches nothing. A stream nobody finished ends normally when its last
producer goes (6.4). `AbortStream` ends it with a body error: no last chunk,
so the client sees a truncated body and the connection closes.

### 6.4 Shared exchanges and the two counts

An exchange starts unshared: it belongs to its loop thread and every method
runs there without locks (builds with assertions check it). `Share` (loop
thread only, from `Poll` or from a holder) switches it to shared mode and
hands out one reference; it is the only way to obtain a reference that may
leave the loop thread or outlive the call. From then on the body channel and
the stream queue work under their locks and the state changes by
compare-and-swap. Two counters keep a shared exchange alive:

- `FRefCount`: the transport's reference plus one per `Share`. `Release`
  decrements it; the decrement that reaches 0 recycles the exchange into its
  pool, on its loop (directly when the releaser is the loop thread, else by
  posting `FreeMsg`, which the inbox delivers after any `WakeMsg` the same
  thread posted). A connection does not reuse a shared exchange for its next
  request: `ReleaseTransport` drops the connection's reference and the
  connection takes a fresh one from the pool.
- `FHolders`: the call in flight plus one per `Share`. The decrement that
  reaches 0 (`DropHolder`, from `Release`, `CompleteCall` or `Cancel`)
  releases the request (head unpinned on the loop, receiver closed) and ends
  a response stream still open (`AutoFinish`). That decrement is the one
  place where this is decided, before the releaser's own reference goes, and
  a count of 0 is final (`Share` raises `EExchangeState` from 0), so no
  producer can be added after the decision. The call in flight counts
  because it may still `Share` or `Offload` another producer after a helper
  released. On an unshared exchange the request is released at the
  completion and `CompleteCall` ends a stream the call left open.

So a worker can answer first and read the body afterwards, or stream its
answer while it reads (an echo): the dispatcher keeps feeding the channel
while a holder exists. When such a body ends after the response was
finished, the dispatcher closes the ended body's sender at its next head
read, so the reader sees the end and the exchange is released with its
sender closed. `ReleaseRequest` and `DiscardBody` are request-wide, so only
the request's one user calls them; a producer that only writes just
`Release`s.

Pins on read-buffer blocks are plain integers changed on the loop thread
only, so a worker never unpins a view: it hands the view back through
`TBodyChan.ToRelease` (two slots), which the loop unpins before it fills the
slot again or when a cross-thread wake reaches it (`SyncShared`).

### 6.5 Cancellation

When the client disconnects, the connection fails or the stop deadline
passes while a call is in flight, the dispatcher calls `Cancel` and then
`Drop(Ex, False)`. Unshared: the state becomes `xsCanceled` and the request
is released. Shared: a compare-and-swap from `xsCalled`; the cancel that wins
closes the receiver for the handler, unparks a reader parked in a body read
(`EClientGone`) or a producer parked in a stream write (`wrCanceled`), and
gives up the call's holder. A cancel that loses to the handler's answer
leaves the request with its holders, as a completion does; the connection's
end then drops the body sender with the incomplete-message error, so a
reader gets the chunks that arrived and then `EBodyError`. Later terminal
calls return False and release their body; a long-running handler checks
`IsCanceled`. A running database query is not interrupted; its result is
discarded.

### 6.6 Offloading

`TOffloadCall` is the ready-made call that offloads every request: its first
poll calls `Offload(Pool, Handler)` and returns pending; later polls return
ready once `Answered`. `Offload` runs once per request (a second call raises
`EExchangeState`: the exchange is the queue node and a second submission
would link it to itself), calls `Share` and `TrySubmit`; a pool that is shut
down takes the reference back and raises `EWorkerPoolStopped`, which aborts
the connection task. `SaturatedStatus` answers at once on the loop (for
example 503 with `Retry-After: 1`) when the pool's queue limit is reached,
without sharing. The worker's job (`TExchange.Execute`) runs the handler
inside `try/finally` so that its reference always goes back.

### 6.7 Upgrades from the application's side

`OnUpgrade(H)` registers a `TUpgradeHandler` on the loop thread before the
101 answer. After the HTTP part ended and the close was reported,
`H.Upgraded(U)` runs on the loop thread with a `TUpgraded`: `Attach` keeps it
on the loop with `Readable`/`Writable` callbacks that follow the readiness
rules (a callback with nothing to do costs no system call; `TryRead` returns
the leftover bytes first), or `Detach` leaves the loop (the socket is
unregistered and made blocking, the leftover bytes are copied, and the caller
owns the descriptor). The handler owns `U` from `Upgraded` on; if `Upgraded`
raises before taking it, the exchange closes `U` and the exception goes on to
the loop. An upgraded connection keeps its connection-limit slot until the
stream is closed or detached (`CloseProc`).

### 6.8 Observer and parts

`TConnObserver` (`OnAccept`, `WrapTransport`, `OnStart`, `OnConnClose`,
`OnParts`) and `TConnParts` are hooks for tests and the conformance server;
nil in production costs nothing. They are declared in
`bearings.http.exchange`, and `TConnOutcome` in `bearings.http.error`, because
the dispatcher uses them and `bearings.server` uses the dispatcher: declaring
them in `bearings.server` would make the unit references circular.
`bearings.server` re-exports the names.

### 6.9 HTTP/2 fit

The service, call, exchange, body and worker types do not mention HTTP/1. An
HTTP/2 session would take one exchange per stream from the loop pool
(per-connection reuse is an HTTP/1 optimization only), fill the head from
decoded header frames, feed the single-slot channel from data frames and
return flow-control credit when the handler takes a chunk, and poll a
`TBodySource` for data frames. Nothing of that exists yet.

## 7. Memory

### 7.1 Ownership

| object | owner | lifetime |
|---|---|---|
| `TH1Dispatcher` (embeds `TH1Conn`, `TH1Io`, decoder, encoder, timers) | its loop | accept to close; freed after the event batch |
| read buffer block | `TReadBuf` while it holds bytes or views pin it; the loop's pool otherwise | 7.3 |
| write cursor block, queue array | `TWriteBuf` while bytes are buffered; the pool otherwise | 7.3 |
| queued body data | its `TBodyData` until written | released in `TBufList.Advance`, or right after the copy into the cursor |
| `TExchange` with its header lists and trailer list | the loop's `TExchangePool`; references: the connection plus `Share` | 6.4 |
| call objects | the service (singletons or its own pools) | `TServiceCall.Drop` returns them |
| `TUpgradeSlot` | reference-counted: the connection side and the exchange | the last `Release` frees it |
| `TUpgraded` | its loop, then the upgrade handler | until closed or detached |

### 7.2 Zero-copy slices and their lifetimes

| slice | points into | valid until | kept alive by |
|---|---|---|---|
| request method, target, URI parts, header names and values | the read buffer (head region) | the request is released: at the latest the call's completion (unshared) or the last holder's release (shared) | the head view's pin (`TRequestHead.View`) |
| request body chunk (`TryRead`, `ReadChunk`) | the read buffer (body region) | the next body call or the release of the request | `TBodyChan.Held` |
| request trailers | the exchange's `ReqTrailers` list (copied from the decoder scratch) | the exchange is recycled | the exchange |
| response headers | the exchange's response list arena | encode time | the exchange |
| `BodyStatic` | the caller's memory | forever | the caller |
| `BodyString`, `WriteString` | the string's heap block | the frame is written | one reference in `TBodyData.Ctx` |
| `BodyCopy`, `Write` | a pool or heap block owned by the body data or the stream ring | the frame is written | the `TBodyData` |
| leftover bytes of a `TUpgraded` | the read buffer | consumed, closed, or copied by `Detach` | the pin |

`TReadBuf.Reserve` never moves or compacts a block with pins: when the
buffer needs room it takes a new block, copies the unread bytes, and marks
the old one `Detached` so that the release of its last view frees it. Pins
are loop-thread counters; hyper pays an atomic reference count per head and
per chunk, bearings pays a plain increment. Debug builds fill freed blocks
with `$DD`.

### 7.3 Pooling

`TBlockPool` (one per loop): eight size classes from 8 KiB to 1 MiB, 64-byte
aligned, LIFO free lists (the most recently returned block is still in
cache), the total capped at `POOL_DEFAULT_MAX_BYTES` (64 MiB) per loop,
larger requests straight from the heap, no zero-fill. `Trim` runs after 1 s
without events and frees, per class, the blocks that were not needed since
the previous trim (the free list's low-water mark). The read buffer grows by
pool class and is compacted when unpinned; `TByteVec` grows to
`Max(2 * Cap, Len + Additional)`.

A connection gives its blocks back whenever it is idle (`TH1Io.ReleaseIdle`
at the end of a run that leaves `Reading = rdInit`, `Writing = wrInit`, an
empty unpinned read buffer and an empty write buffer), gives its exchange
back to the pool at the same moment, and frees its trailer scratch
(`ReleaseIdleScratch`). So an idle keep-alive connection holds the
dispatcher object and nothing else: about 1.3 KB measured with 10 000 idle
connections (hyper: 10.7 KB). `TExchangePool.Give` keeps the header lists'
capacity, so a reused exchange stops allocating once its lists are large
enough.

### 7.4 No reference-count traffic and no implicit exception frames

- Hot routines take `PByte` plus length. No `string`, `RawByteString` or
  dynamic-array locals, by-value parameters or temporaries, and no `try`:
  each of these makes FPC emit `fpc_pushexceptaddr` and `fpc_setjmp` on
  every call. `TEncoder`, `TDecoder`, `TResponseHead`, `THyperError`,
  `TBodyData` and the buffer records have no managed fields; trailer names
  and trailer bytes live in a per-connection scratch (`TConnScratch`) instead
  of managed fields of the codec records; the reason phrase is a slice.
- No management operators (`Initialize`/`Finalize`) on hot records: they
  would make every local of that type a managed local.
- No threadvars on the hot path: the date cache, the pools and the timers
  are reached through the loop object.
- `TTcpTransport` has no constructor of its own (`NewTcpTransport`): an FPC
  constructor always gets a frame.
- The transport touches an AnsiString reference count only for `BodyString`
  and `WriteString` (one increment, one decrement; `lock`-prefixed because
  the program is multi-threaded).
- The check: `tools/check-hot-asm.sh` compiles every unit with assembler
  listings in the production (`-O3`) and the test (`-O2 -Sa`) configuration
  and fails when any listed routine contains a frame call (`tools/hot-asm.py`
  parses the listings). The list covers the dispatcher's per-request
  routines, every method of `TH1Conn`, `TConnState`, `TH1Io`, `TReadBuf`,
  `TByteVec`, `TBytesView`, `TTcpTransport`, `TTimerWheel`, `TBodyChan`, the
  per-frame `TChannelBody` methods, the shared-exchange routines
  (`Release`, `Share`, `Offload`, `Wake`, the stream writer), the parse and
  encode entry points, `TLoop.RunIteration` and the `bearings.rt.sync`
  primitives. With `--s7` it also checks that the production listing of
  `bearings.http.exchange` holds no `Dbg*` routine and no assertion call, and
  that the test listing does.

### 7.5 Per-request allocations

Inline path: none (the exchange is reused, the call is a singleton, the
header lists are cleared and reused, read and write blocks come from the
pool, `TBodyData` is a record, a timer is embedded). Worker path: none in
steady state either (the exchange comes from the pool and is its own work
item; posting a message allocates nothing). A string built per request by
the application (`RespondText`, `BodyCopy`, `GetValue`) is the application's
cost; `docs/api.md` section 13 lists the rules a program must keep.

## 8. Header validation

An invalid header field must not reach the wire: a name that is not a token,
or a value holding CR, LF or NUL, would end the header line early or add
lines of its own (response splitting), letting whatever supplied the value
inject headers or a second response. The check is at the mutators of
`THttpHeaders` (`bearings.http.headers`), where the bytes enter the list,
not in the encoder: `Add`, `Append`, `Insert` and `SetValue` validate and
raise `EInvalidHeader`; `TryAdd`, `TryInsert` and `TrySetValue` return a
`THeaderCheck`; `AddTrusted`, `InsertTrusted` and `SetValueTrusted` skip the
check for bytes that are valid by construction (parser and decoder output,
constants covered by a unit test), and `AddExternal` (the parser's zero-copy
entries) never checks. A name is 1 to 65 535 token bytes; a value may hold
HTAB and any byte from `$20` on except `$7F`. The cost is one table lookup
per byte, which an application avoids for constants with the trusted
variants. In `-Sa` builds `ServerEncode` and `EncodeTrailers` assert every
name and value they write, so a path that missed the boundary shows up in
tests, and the validating mutator calls are counted
(`ValidatingMutatorCalls`), so a test can prove that the library's own
callers use the trusted paths. Where an exception from `Add` lands: in a
worker, the job's `try/except`; in an inline handler, the loop's handler
aborts the connection.

The same rule holds for the reason phrase (`bearings.http1.reason`: HTAB, SP,
visible ASCII and obs-text only; `SetReason` refuses anything else) and for
trailers: `EncodeTrailers` writes only fields whose names the response
announced in its `Trailer` header, grouped by name in order of first
appearance, and `TH1Conn.WriteTrailers` writes nothing unless the request
sent `TE: trailers`; when no field survives, the body is ended normally
instead.

## 9. Verification

**Unit suites** (`tests/unit/run_all.sh`, built with `-Sa -Cr -Co -Ct`):
`test_parser`, `test_codec`, `test_role`, `test_headers_validate`,
`test_rt_sys`, `test_rt_timer`, `test_rt_loop`, `test_rt_net`,
`test_rt_readbuf`, `test_h1_io`, `test_h1_conn`, `test_body_chan`,
`test_exchange`, `test_h1_dispatch` (built with `-dWD_DEBUG -dWD_STALL`, so
the wake-source check runs in every test), `test_workers`, `test_server` and
`test_server_ops` (real sockets through `TServer`). The script prints the
total (`unit tests run: N`; 975 at the time of writing). The suites that
own memory across threads (`test_h1_conn`, `test_body_chan`,
`test_exchange`, `test_h1_dispatch`, `test_workers`, `test_server`,
`test_server_ops`) run once more under heaptrc (`-gh`) and must report 0
unfreed blocks. `test_workers` also runs three times under
`valgrind --tool=drd` (built with `-dWD_DRD` and the C heap, with
`tools/drd.supp` and `--fair-sched=yes`) and must report 0 errors; what the
suppressions hide and what "drd clean" does not cover is stated in that
file. The test doubles are `tests/support/bearings.test.mocktransport`
(scripted reads and exact expected writes) and `bearings.test.scriptio`
(scripted answers, recorded writes, for the dispatcher and the fuzz).

**The worker stress** (`tests/unit/stress_workers.pas`, `tools/s7-stress.sh`):
a server with 16 workers, 24 client threads, 13 handler modes (answer before
or after reading the body, stream while reading, a second holder, random
disconnects and resets, pipelining); it checks that a handler never sees a
clean end of a body that did not end, never sees wrong bytes, that nothing
hangs and that every exchange is freed; it runs natively, once more with the
server destroyed under load, and under drd.

**The echo test** (`tests/unit/test_rt_echo.sh`) moves 1 GiB through a
`TLoop`, a `TListener` and a `TTcpTransport` with random read and write
sizes, the server under valgrind memcheck with the C heap (valgrind sees
nothing inside FPC's own heap) and 0 errors required.

**The split fuzz** (`tests/unit/test_split_fuzz.pas`, in process): every
conformance case input and 20 000 generated request heads (plus httparse's
own test inputs when its source is present) are served by the real
dispatcher and the conformance server's handlers over a scripted transport,
once in a single read and then, for each of 2 000 seeds, in random pieces
with random `EAGAIN` and partial writes, in the case's profile and in
`ProductionH1Config`; the bytes written, the events and the outcome must be
equal, no task may abort, every block must be back in the pool, and heaptrc
must report no leak. Two shapes are accepted as equivalent because they
depend only on segmentation (section 10): an invalid head without an end of
head, and an HTTP/2 preface split before its 24th byte.

**The hot-path check** (`tools/check-hot-asm.sh --s7`, section 7.4) runs
last.

**Differential tests** against the Rust originals, run from their own
scripts: `tests/unit/test_parser_diff.sh` (the parser against httparse
1.10.1), `test_role_diff.sh` (request-head parsing and URIs against hyper's
own `Server::parse` and `http::Uri`, also against a guard page),
`test_codec_diff.sh` (the body decoder and the header helpers against hyper's
`decode.rs` and `headers.rs`). They cover request acceptance and framing,
which is what request smuggling depends on; response encoding is checked by
fixed expectations.

**The conformance harness** (`conformance/`): `SPEC.md` is the contract
between the case files (hyper's 105 HTTP/1 server tests ported to data,
`cases/h1/*.json`), the runner (the client, in Rust) and a conformance
server; `reference-server` is hyper itself. The Pascal conformance server
(`conformance/pascal-server/beconf`) is a thin wrapper around
`bearings.server`: everything on the wire comes from the library, the
wrapper only configures the connection from the spec, installs the named
handler and reports events. `conformance/pascal-server/gate.sh` runs the
cases in assertion mode five times and requires `passed=104 failed=0
pending=1` every time (one case is pending by design in `MANIFEST.md`), then
the 25 extra cases of `extra/extra-cases.json` (behaviours the 105 do not
reach); `LOOPS=4` runs the same with four loops sharing one listener.
`gate_worker.sh` runs it with every handler on a worker; one case,
`chunk2::pipeline_enabled`, is allowed to fail there
(`worker-exceptions.txt`): its wire assertion needs the second handler to
answer in its first poll, which no worker handler does, and the script
proves each run that the reference server fails the same assertion when its
handler is pending (`extra/worker-probe.json`). The runner's diff mode
against the reference server is a report, not a gate: byte-identical write
segmentation and event timing are not goals.

**The differential stream fuzz** (`conformance/fuzz-diff/`, Rust): generated
request streams (a grammar plus mutations of the case corpus and httparse's
corpus) with random write splits, gaps and half-closes are sent to the
reference server and to `beconf` under the same spec, and compared per
request on acceptance, status and body, the end of the connection and the
server events; a stream that differs is replayed nine more times on both,
and counts as a difference only when some bearings outcome was never seen
from the reference server. The known deviations of section 10 are recognised
in their exact shapes. `run.sh` runs 10 000 streams by default.

**The performance gate** (`bench/run_gate.sh`): `bench/plaintext.pas` against
`bench/hyper-tfb` (hyper in its TechEmpower configuration), both with 4
loops pinned to CPUs 0-3 and wrk on CPUs 4-15, four cells (256 and 1 024
connections, pipeline depth 1 and 16), 5 alternating runs of 30 s per
server, the median of the runs whose wrk CPUs were under 90 % busy
(`bench/compare.py`); the response bytes of the two servers are compared
with `cmp` first. Gate: every cell at or above 0.80 of hyper's requests per
second. `bench/run_offload.sh` measures the offload cost (limit 5.4 us per
request); `bench/bench_role.pas`, `bench_conn.pas` and `bench_dispatch.pas`
are the micro-benchmarks; `bench/p99.sh`, `idle_rss.sh` and `syscalls.sh`
measure latency, idle memory and system calls per request. The numbers and
the method are in `docs/design/m3-perf-report.md`. The soak and slow-client
tools that produced the stall detector's evidence are not in this
repository; the report records their last results.

**Debug build flags** (`docs/api.md` section 12): `-Sa` (the threading and
no-response checks, poisoned head views, the encoder assertions),
`-dWD_DEBUG` (the wake-source check, poisoned pool blocks), `-dWD_STALL`
(the stall detector, needs `WD_DEBUG`), `-dWD_DRD` (drd annotations).

## 10. Deviations register

Every place where bearings behaves differently from what RFC 9110/9112 or a
common server would lead a reader to expect, with the reason. "Observable"
says whether a client can see the difference. Entries that compare with the
reference server (hyper) are listed only where the difference is
observable.

| topic | bearings | reason | observable |
|---|---|---|---|
| **Parsing** | a bare LF ends a line, and CR/LF bytes before a request line are ignored | RFC 9112 2.2 allows both | yes, lenient |
| Parsing | every other deviation from the grammar is a 400; the lenient parser options are off by default | request smuggling: the server and a proxy must agree on where a request ends | yes, strict |
| Parsing | `Transfer-Encoding` wins over `Content-Length`, the `Content-Length` lines are removed and the connection closes after the response; several differing `Content-Length` values, a `Transfer-Encoding` in HTTP/1.0 or one whose last coding is not `chunked` are 400 | RFC 9112 6.3; smuggling | yes |
| Parsing | a head that reaches `max_buf_size` is answered 431; the read buffer never exceeds it | the read is capped at `max_buf_size - Len`; hyper's buffer can exceed its limit by its last reserve's slack | only at the limit |
| Parsing | an invalid head whose error is visible before its end is answered 400 when it arrives in one read, but a head split across reads is parsed again only when its bytes hold an end of head, so an invalid head without one is never rejected: the client's EOF ends the connection as `incomplete` | the incremental end-of-head check avoids re-parsing a slow head; the reference server does the same | depends on segmentation |
| Parsing | the HTTP/2 preface is recognised only with all 24 bytes buffered; split earlier, it is an invalid HTTP/1 version and gets a 400 | same as above | depends on segmentation |
| **Automatic responses** | 400/414/431 are bodyless, with `connection: close`, `content-length: 0` and `date`; the preface gets no response; a 1xx final status other than 101 is answered 500 and ends the connection as a user error; an HTTP/0.9 or HTTP/3.0 response version aborts the connection without a response | the parser's errors need no application; the encoder cannot write the others | yes |
| Automatic responses | an automatic head written while response entries are queued goes behind them | hyper writes it into its head buffer, between the queued response's head and body, corrupting that response | only in that situation |
| **Keep-alive** | HTTP/1.0 closes unless `Connection: keep-alive`; a 1.0 client gets a 1.0 response; `connection: close` is added when the server will close | RFC 9112 9.3 | no |
| Keep-alive | the header read timeout (30 s in production) also closes an idle keep-alive connection, because it is re-armed when the connection goes idle | one timer per connection; a client that stops mid-head and an idle client are the same risk | yes, after 30 s idle |
| **Pipelining** | one call in flight per connection; later requests wait unparsed in the read buffer | responses must leave in request order; no reordering structure | a slow handler delays its own connection only |
| Pipelining | with `PipelineFlush` (production default) responses are held while another request is buffered, so a batch leaves in one write; the conformance preset has it off | 4x pipelined throughput | TCP segmentation only |
| Pipelining | when the connection ends while pipeline flush holds bytes (an upgrade or CONNECT with bytes after the request, keep-alive off with a request behind, the parts hand-off), the held bytes are written first | hyper drops them (a 101 would be lost in production); conformance runs have pipeline flush off, so they never see this | yes, under pipeline flush |
| Pipelining | under the worker executor the second of two pipelined requests leaves in its own write, so `chunk2::pipeline_enabled` fails its wire assertion | a worker handler is pending at its first poll; the reference server fails the same assertion with a pending handler | only in that test |
| **100-continue** | the 100 is sent only when the handler first reads the body, never when it answers without reading; a body left unread is drained once or the connection closes | spares the client the upload when the answer does not need it | yes |
| **Half-close** | with `HalfClose` off (the default) the client's EOF while a request is in progress ends the connection as `incomplete` without a response, even when the request was complete and the handler running; whether a request followed at once by a half-close is answered depends on whether the FIN is there when the server reads | HTTP/1.1 servers usually treat an early EOF as abandonment; the race exists on both servers | yes, timing-dependent |
| **Trailers** | written only when the request sent `TE: trailers` and the names were announced in the `Trailer` header; grouped by name in order of first appearance; dropped otherwise and the body ended normally | RFC 9110 6.5; a client that did not announce trailers may not parse them | yes |
| **Response head** | header names lowercase (or title case by option); lines of one name grouped at the first position; `Connection`, `Transfer-Encoding` and `Trailer` joined into one line each; `PreserveHeaderCase` accepted and ignored | one encoder path; field order within a name is kept, which is what RFC 9110 5.3 requires | yes, cosmetic |
| **Clock** | every duration and deadline is measured with the loop's clock, sampled once per iteration | one vDSO call per iteration | a timer armed during an iteration is measured from the iteration's start, so it can fire up to one iteration's length early; a request answered in its own iteration has duration 0 |
| **Body timeouts** | the body rate rule (30 s per wait, 1 KiB/s after that much waiting; production preset) fails the body with an I/O error (outcome `io`); the handler answers (a framework sends 408) and the connection closes after that response | a slow upload must not hold a worker or a connection forever; the model is nginx's `client_body_timeout`, with a rate part so that a byte just before each limit does not pass | yes |
| **Accepting** | `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM` and every other non-connection accept error pause the listener for 1 s; connection errors skip that connection | a level-triggered listener would spin; hyper 0.14 and axum sleep the same way | connections wait, none refused |
| Accepting | at the connection limit new clients wait in the accept queue, bounded by the backlog | refusing would make the client retry at once | yes |
| Accepting | no per-IP limit | the policy belongs to the proxy or the firewall; behind a proxy every connection has one address | - |
| **Shutdown** | a connection with no request byte read when the stop reaches its loop is closed without a response; a connection entering the accept queue between the last `accept4` and the close is reset by the kernel | the drain accepts what is queued; the window cannot be removed | yes, at stop |
| **Upgrades** | a pending upgrade slot of a request answered without 101 stays with the connection: a later upgrade request replaces it (the older handler gets `upgrade expected but not completed`) and a connection that finishes while it is set ends through the upgrade path | the reference server keeps the slot the same way | only with a registered handler |
| Upgrades | `cmPlain` (the conformance preset) does not hand upgrades over: the handler gets `upgrade expected but low level API in use` | hand-over is opt-in per configuration | yes |
| **Request lifetime** | on a shared exchange the request (head and body) lives until the last holder releases it; a worker may answer first and read afterwards, or stream while reading | the request belongs to its holders, as a future owns its request | no |
| Request lifetime | when such a body ends after the response was finished, the dispatcher closes the ended body's sender at its next head read | hyper keeps the sender until a later body replaces it, so its reader of a `Content-Length` body stays pending after the last chunk; here the reader sees the end at once | only to a worker |
| Request lifetime | on an unshared exchange the request is released at the call's completion; a response source polled afterwards that reads the body gets `brCanceled`, not a clean end; an inline echo must `Share` in `Poll` | a read must never report a clean end of a body that did not end; keeping the unshared request alive would change the inline drop path that conformance covers | only to such a source |
| Request lifetime | a cancel that loses to the handler's answer leaves the request with its holders; the connection's end then gives the reader the chunks that arrived and an `EBodyError` | one behaviour whether or not the dispatcher had taken the answer; the body's sender is dropped with the incomplete-message error | only to a worker |
| **Streams** | a stream left open ends normally when its last producer goes (the last holder, or the call's completion when unshared); a write of 0 bytes is `wrOk` while the stream is active and `wrCanceled` after | a response must not stay open forever; a dropped sender ends a channel body | yes, as a normal end |
| **Handler errors** | an exception from a worker handler becomes a failed answer `handler raised <class>: <message>` (or an aborted stream); a handler or call that gives no answer is failed with `handler returned no response`; the connection closes without a response in both cases | nothing sensible can be sent; the text reaches the observer and the log | yes, the connection closes |
| **Memory** | an idle connection holds no buffers (blocks go back to the pool), so its memory is about 1.3 KB | ten thousand idle keep-alive connections at 8 KiB of buffer each would be 80 MiB | no |
| **Unix sockets** | a connection accepted on a Unix socket has a peer record with `AF_UNIX` and no address; `SockAddrToStr` gives `''`; the access log writes `unix` | a Unix socket has no peer address; the client address comes from the proxy's forwarding headers | yes, in logs |
| **Access log** | automatic error responses to unparsable requests are not logged | the log line needs a parsed head | yes |

## 11. Risks and known limits

| risk or limit | effect | mitigation or status |
|---|---|---|
| The lock-free code (`bearings.rt.sync`, `TLoop.Post`, the exchange's counters and claim) assumes x86-64 ordering: locked instructions are full barriers, aligned word loads and stores are atomic and keep program order among themselves | wrong on ARM64 (weaker ordering) | an ARM64 port must review every plain load and store of a synchronization word and add the needed barriers; the drd annotations mark the places |
| Linux only: raw system calls, epoll, eventfd, `accept4`, `sendfile`, futex, `sched_getaffinity` | no other platform | by design; `bearings.rt.sys` is the one place that knows the call numbers |
| No TLS | plain TCP only | a reverse proxy in front; a transport without `writev` and `sendfile` already has a defined behaviour (`IsWriteVectored = False`, `SendFile = -ENOSYS`) |
| No HTTP/2, no WebSocket protocol code | HTTP/1.1 only; upgrades are handed over raw | the service types are protocol-neutral (6.9); the WebSocket plan is `docs/handoff-websocket.md` |
| Throughput at pipeline depth 16 is 0.85 to 0.88 of hyper (depth 1: 0.96 to 0.98) | the gate (0.80) is met, parity is not | the instruction count per request equals hyper's within 3 %; the difference is CPU time per instruction (`docs/design/m3-perf-report.md` section 8) |
| Edge-triggered sockets can lose a wakeup when a readiness bit is cleared without the kernel having said `EAGAIN` | a stuck connection | the transport rules of section 3 with sticky closed bits; the wake-source check in debug builds; the split fuzz with random `EAGAIN`; the data-plus-FIN test |
| A short `read(2)` is taken to mean an empty receive buffer | a lost edge if a kernel ever returned fewer bytes than available with more pending | Linux TCP returns everything available up to the buffer size; new data raises a new event anyway |
| Use after free between loops, workers and deferred frees | memory corruption | tasks are freed after the event batch; exchanges are recycled only on their loop after queued wakes; `Posting` and `Outstanding` gate `TServer.Destroy`; heaptrc, memcheck and drd runs; the stress test |
| Blocking code on a loop thread by mistake | every connection of that loop stalls | inline is a choice per route; the watchdog stops its heartbeat when a loop stops making progress; the stall detector exists only in `-dWD_STALL` builds |
| Worker pool saturation (a slow database) | queued requests, latency | HTTP/1 bounds the queue by open connections; `TOffloadCall.SaturatedStatus` answers 503 inline above `WorkerQueueLimit` |
| The access log drops lines when a loop fills its buffer faster than the flusher writes | lost lines, counted in `Dropped` | the loop never blocks on the sink; the buffer size and the flush period are configurable |
| `SO_REUSEPORT` spreads connections by hash, not by load | uneven loops under few long-lived connections | `amSharedExclusive` as the alternative (measured equal throughput) |
| The soak and slow-client tools are not in this tree | the stall detector and the long-run memory behaviour are not re-checked by the repository's own scripts | the perf report records the last results; the unit, stress and fuzz suites are in the tree |
