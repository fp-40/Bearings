# bearings API guide

This guide is organized by what a program does with the library, not by
unit. The last section is a reference table of every public type and
routine of the units a program uses, with its threading rule. Everything
here was taken from the code and the header comments of the units under
`src/`; where a detail matters, the unit is named so you can read the
header comment, which is written for the same audience as this guide.

Three complete programs under `examples/` accompany it: `hello.pas`
(inline answer, static body), `worker.pas` (every request on a worker,
request body read with `ReadAll`, echoed back), `stream.pas` (a streamed
response and a file response). `examples/README.md` has the build command.

Contents:

1. Concepts: loops, workers, the exchange, services and calls
2. Configuring and running a server
3. Answering inline on the loop
4. Answering on a worker thread
5. Response bodies
6. Reading the request body
7. The response head
8. Cancellation, keep-alive and pipelining
9. Errors
10. Connection upgrades
11. The connection observer
12. Debug build flags
13. Performance rules
14. Reference tables

## 1. Concepts

### Event loops

A `TServer` runs N event loops (`TLoop`, unit `bearings.rt.loop`), each on
its own thread. N is `TServerConfig.Loops`, or `DefaultLoopCount` (unit
`bearings.rt.cpu`: the CPUs the process may use, capped by the cgroup CPU
quota, at least 1) when that field is 0. Every socket is non-blocking; a
loop asks the kernel which sockets are ready (`epoll_wait`), runs the code
of each ready connection until it would block again, and waits again. A
connection is accepted by one loop and stays on that loop for its whole
life. One loop thread serves many connections, so **code that runs on a
loop thread must never block**: no `Sleep`, no blocking file or socket
call, no waiting on a lock another thread holds for long.

Each loop owns its own buffer pool, exchange pool and one instance of the
application's service, so per-loop state needs no locks.

### Worker threads

Code that may block runs on the worker pool (`TWorkerPool`, unit
`bearings.rt.workers`), a fixed set of threads with a FIFO queue. A request
is handed to the pool with `TExchange.Offload` (section 4). A worker may
block: in a request body read, in a stream write to a slow client, in a
database call, in `Sleep`. The pool is created by `TServer.Start` when
`TServerConfig.Workers >= 0` (0 picks `Min(32, DefaultLoopCount + 4)`
threads; -1 means no pool) and is reachable as `TServer.Workers`.

The rule for what may run where:

| Code | Runs on | May block? |
|------|---------|------------|
| `THttpService.Call` | loop thread | no; must not answer or read the body either |
| `TServiceCall.Poll`, `TServiceCall.Drop` | loop thread | no |
| `TBlockingHandler.Run` | worker thread | yes |
| `TBodySource.PollFrame`, `TBodySource.Done` | loop thread | no |
| `TUpgradeHandler.Upgraded`, `UpgradeFailed`, `TRawListener` callbacks | loop thread | no |
| `TConnObserver` hooks | loop thread | no |
| `TWorkerHooks.ThreadStarted`, `ThreadStopping` | the worker thread | yes |
| a thread holding a reference from `TExchange.Share` | that thread | yes (its own code); exchange calls follow section 14 |

### The exchange

A `TExchange` (unit `bearings.http.exchange`) is one request and its
response. The connection task fills in the request head, asks the service
for a call, polls the call until the application made exactly one
*terminal call* on the exchange (`Respond`, `RespondStream`, `BeginStream`
or `Fail`), writes the response, and on a keep-alive connection starts the
next request on the same exchange object. An exchange is pooled per loop
and reused; a program must not keep a pointer to it past the end of the
call unless it holds a reference from `Share` (section 4).

The exchange has three parts:

- the request head: `Method`, `MethodBytes`, `Target`, `Path`, `Query`,
  `Version`, `Headers`, `Header(Name, out V)`, `ContentLength`,
  `ExpectsContinue`, `WantsUpgrade`, `ConnId`, `RequestNo`, `PeerAddr`.
  The method, target and header bytes point into the connection's read
  buffer; they are not copied. They are valid until the request is
  released, which happens at the latest when the call completes (section
  3) or when the last holder of a shared exchange releases it (section 4).
  `TByteSlice` (`P: PByte; Len: SizeInt`) is how the head hands out bytes.
- the request body: `TryRead` on the loop, `Read`, `ReadChunk`, `ReadAll`,
  `ReadFrame` on a worker, `DiscardBody`, `RequestTrailers` (section 6).
- the response: `Status`, `ResponseVersion`, `SetReason`,
  `ResponseHeaders` (section 7), then the terminal call (sections 3 to 5).

### Services and calls

`THttpService` is the application. The server calls the `TServiceFactory`
(a method `function(Loop: TLoop): THttpService of object`) once per loop
in `Start`, so there is one service instance per loop. For every request
the loop calls `THttpService.Call(Ex)` on the loop thread, right after the
request head was parsed. `Call` returns a `TServiceCall` and must not
answer or read the body (builds with assertions check this). It may look at
the head to pick a call object, and may write a log line.

`TServiceCall` is the handling of one request as the connection sees it:

- `Poll(Ex): TCallPoll` runs on the loop thread every time the connection
  runs while the call is in flight. It returns `cpReady` only after a
  terminal call was made on `Ex`. It returns `cpPending` when the answer is
  not ready yet; then something must call `Ex.Wake` later, otherwise the
  connection stays stuck until a timeout. Sources of a later wake: a
  `TryRead` that returned `brPending` (the call is polled again when body
  data arrives), a `TWakeTimer`, a worker's terminal call (section 4), or
  any thread holding a `Share` reference that calls `Ex.Wake`.
- `Drop(Ex, Completed)` is called exactly once at the end, on the loop
  thread: `Completed = True` right after `Poll` returned `cpReady`;
  `False` when the connection abandoned the call (the client closed the
  connection, a connection error, the shutdown deadline), including a call
  that was never polled. A call object that is pooled returns itself to its
  pool here. The default `Drop` does nothing.

A stateless call object (one instance returned for every request) is the
cheapest: `examples/hello.pas` and `bench/plaintext.pas` do that.

## 2. Configuring and running a server

```pascal
Cfg := ProductionServerConfig;
Cfg.Listen.Port := 8080;
Srv := TServer.Create(Cfg, @App.NewService);   { Observer = nil }
Sig := Srv.RunUntilSignal(@App.Started);       { or Start ... Stop(GraceMs); Wait }
Srv.Free;
```

### TServerConfig (unit `bearings.server`)

| Field | Meaning |
|-------|---------|
| `Listen: TListenSpec` | where and how to listen (below) |
| `Loops: Integer` | number of event loops; 0 = `DefaultLoopCount` |
| `PinLoops: Boolean` | pin loop i to the i-th usable CPU (`sched_setaffinity`) |
| `H1: TH1Config` | the HTTP/1.1 connection options (below) |
| `Workers: Integer` | worker threads; -1 = no pool; 0 = `Min(32, cpus + 4)` |
| `WorkerQueueLimit: Integer` | `TWorkerPool.Saturated` is True at this many queued items; 0 = no limit |
| `WorkerHooks: TWorkerHooks` | per-worker-thread start and stop callbacks; nil = none; not owned |
| `WorkerWaitMs: Integer` | how long `Wait` and `Destroy` wait for queued and running work items; 0 = 30 000 |
| `GraceMs: Integer` | the grace period `RunUntilSignal` passes to `Stop` |

`TListenSpec` (unit `bearings.rt.net`): `Host` (`'0.0.0.0'`,
`'127.0.0.1'`, `'::'`), `Port` (0 = a free port, read it back from
`TServer.Port`), `Backlog` (the accept queue length), `NoDelay`
(TCP_NODELAY on every accepted socket), and `Mode: TAcceptMode`:

- `amReusePort`: one listening socket per loop, all bound to the same port
  with SO_REUSEPORT; the kernel spreads new connections over the loops.
  With port 0 the first loop binds a free port and the others bind that
  port.
- `amSingle`: one listening socket on loop 0; loop 0 serves every
  connection.
- `amSharedExclusive`: one listening socket, registered by every loop with
  EPOLLEXCLUSIVE, so the kernel wakes one loop per new connection.

### TH1Config (unit `bearings.http1.config`)

The options of one HTTP/1.1 connection. The defaults in parentheses are
those of `ConformanceH1Config`.

| Field | Meaning |
|-------|---------|
| `KeepAlive` (True) | serve more requests on the connection after the first one |
| `HalfClose` (False) | when the client closes its sending side, still finish the response in progress |
| `TitleCaseHeaders` (False) | write response header names as `Content-Type` instead of `content-type` |
| `PreserveHeaderCase` (False) | accepted and ignored (request names are always kept as received) |
| `MaxHeaders` (-1 = 100) | most header fields in a request head; more gives 431 |
| `MaxHeaderSize` (-1 = no own limit) | most bytes in a request head; more gives 431 |
| `MaxBufSize` (-1 = about 408 KiB) | largest read buffer; a request head must fit; minimum 8192 |
| `Timer` (False) | the connection may arm timers; every timeout needs it |
| `HeaderReadTimeout: TTimeoutSetting` (tsDefault) | `tsDefault`: 30 s with a timer, none without; `tsDisabled`; `tsMs`: `HeaderReadTimeoutMs` |
| `HeaderReadTimeoutMs` | used with `tsMs` |
| `PipelineFlush` (False) | while a pipelined request is still buffered, hold the response so several go out in one write |
| `AutoDateHeader` (True) | add a `Date` header unless the application set one |
| `BodyReadTimeoutMs` (0 = off) | longest wait for one request body byte |
| `BodyMinRate` (0 = off) | bytes/s the client must keep up after `BodyReadTimeoutMs` of waiting |
| `Parser: TParserConfig` | leniency switches of the head parser (`bearings.http1.parser`) |
| `Mode: TH1ConnMode` (cmPlain) | what happens after a `101` response and at the end of the connection (section 10) |

Presets: `ConformanceH1Config` is the base (no timer, so no timeouts;
upgrades not handed over). `ProductionH1Config` is the base plus `Timer`,
the 30 s header read timeout, `PipelineFlush`, `cmWithUpgrades` and the
body rate rule (30 s, 1 KiB/s). `ValidateH1Config` rejects invalid
combinations (`MaxBufSize` below 8192, a `tsMs` header timeout or a body
timeout without a timer, negative values, `BodyMinRate` without
`BodyReadTimeoutMs`); `TServer.Start` runs it and raises `EServerError`
with its message.

Server presets: `ProductionServerConfig` listens on 0.0.0.0:8080, backlog
4096, `amReusePort`, `NoDelay`, `Loops` 0, `ProductionH1Config`, `Workers`
0 (a pool), `GraceMs` 30 000. `BenchmarkServerConfig` is for throughput
measurements: `ConformanceH1Config` with `PipelineFlush`, no timer,
`cmPlain`, no worker pool (`Workers` -1), `GraceMs` 1000.

### Lifecycle (TServer)

- `Create(Cfg, Factory, Observer = nil)`: stores them; nothing runs yet.
- `Start`: validates `Cfg.H1`, ignores SIGPIPE, creates the worker pool
  (before the services, so a factory may read `Workers`), creates the
  loops, calls the factory once per loop, binds the listening sockets and
  starts the loop threads. Returns when the sockets are bound and the
  threads run. Raises `EServerError` when the port is in use (`listen on
  host:port failed: errno n`), when the factory is nil, or on a second
  `Start`. `Port` is the bound port; `Started` is True after a completed
  `Start`.
- `Stop(GraceMs)`: any thread; returns at once; a second call does
  nothing. Each loop then accepts what is still in its accept queue, closes
  its listener, turns keep-alive off on every connection (idle ones close
  now, a connection in the middle of a request closes after its response)
  and leaves when its last connection closed or when `GraceMs` passed; the
  connections still open then are aborted (closed without completion
  events; their calls get `Drop(Ex, False)`). A connection that reaches the
  accept queue between the last accept and the close is reset by the
  kernel; that window cannot be removed.
- `Wait`: joins the loop threads, then shuts the worker pool down (queued
  items still run, for up to `WorkerWaitMs`). Returns at once when the
  server never started.
- `RunUntilSignal(Started = nil)`: `Start`, `Started(Self)` (a
  `TServerEvent`, for example to print `Port`), then wait on the calling
  thread for SIGTERM or SIGINT, `Stop(Config.GraceMs)`, `Wait`. Returns the
  signal number, or 0 when a `Stop` from elsewhere (a handler, another
  thread) ended the wait (checked every 200 ms). The two signals are
  blocked in the calling thread from the call on; the threads `Start`
  creates inherit that mask, so the signals stay pending until the calling
  thread takes them. The previous mask is restored before it returns.
- `GracefulShutdownConnections`: closes every connection open now after
  its current response, while the listeners keep accepting. Any thread
  except a loop thread (it waits until every loop ran it).
- `StartCallerRunsLoop0` / `RunLoop0`: like `Start`, except loop 0 gets no
  thread; the caller runs it with `RunLoop0` until `Stop`. Between the two
  calls the caller may register tasks on `Loops[0].Loop`. Tests and the
  conformance server use this to run one loop on the main thread.
- `Destroy`: if started and not stopped, `Stop(0)` and `Wait`; then the
  connections still open are aborted, the worker pool is shut down (waiting
  up to `WorkerWaitMs`), and the calling thread processes every loop's
  inbox until every exchange is back in its pool. If workers are still
  running, or exchanges are still held by other threads after that wait,
  the loops and pools are not freed (they leak on purpose, with a line on
  stderr): another thread may still post to them.
- `Workers` (nil without a pool), `Config`, `LoopCount`, `Loops[I]` (a
  `TServerLoop`: `Loop`, `Service`, `Pool`, `Index`, `Cpu`).

`Create`, `Start`, `StartCallerRunsLoop0`, `RunLoop0`, `Wait`,
`RunUntilSignal` and `Destroy` are called by the thread that owns the
server. `Stop` may be called from any thread.

## 3. Answering inline on the loop

The cheapest way to answer: do it inside `Poll`, on the loop thread.

```pascal
function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;
```

Rules on the loop thread:

- Never block. The only body read allowed is `TryRead`, which returns
  `brPending` instead of waiting; the call is polled again when data
  arrives, so a call that reads the body inline keeps its position in the
  body between polls (the `Ex.User` or `Ex.Tag` field, or the call object,
  can hold that state).
- `Write` on the loop thread never parks: when the stream queue is full it
  returns `wrWouldBlock`, like `TryWrite`. A streaming producer on the
  loop is better written as a `TBodySource` (section 5).
- An exception that escapes `Poll` aborts the connection task: the loop
  catches it, logs it through `LoopErrorProc` (default: one line on
  stderr) and closes the connection without a response.
- A call that returns `cpPending` must arrange a wake. `TWakeTimer` is the
  application timer for this: `Arm(Ex, DelayMs)` on the loop thread wakes
  the exchange's connection after `DelayMs`, so `Poll` runs again;
  `Fired` tells whether it did; `Cancel(Ex)` removes it. The record must
  not move while armed, and a timer armed for one request does not wake a
  later request on the same exchange (it checks the exchange's
  generation).
- Once the call completes (`Poll` returned `cpReady` and the connection
  took the response), the request is released: the head accessors are
  invalid and the body receiver is closed. A body that was not read is
  read and discarded, or the connection is closed.

Per-request state: `Ex.User: TObject` and `Ex.Tag: PtrInt` are free for
the application and are reset to nil / 0 at every request; the exchange
does not free `User`. `Ex.Attachment: TExchangeAttachment` is for state
the connection must detach itself: the exchange calls `Detach(Ex)` on the
loop thread when it is recycled or begins its next request.

## 4. Answering on a worker thread

A handler that may block runs on the worker pool. The ready-made way is
`TOffloadCall` (a `TServiceCall`) with a `TBlockingHandler`:

```pascal
type
  TEchoHandler = class(TBlockingHandler)
    procedure Run(Ex: TExchange); override;   { worker thread; may block }
  end;

constructor TEchoService.Create(Srv: TServer; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Srv.Workers;         { created by Start before the services }
  FCall.Handler := H;
end;

function TEchoService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;                   { one call object for every request }
end;
```

What happens (`TOffloadCall.Poll`): the first poll calls
`Ex.Offload(Pool, Handler)` and returns `cpPending`; later polls return
`cpReady` once `Ex.Answered`. `Offload` runs on the loop thread, from
`Poll`: it calls `Share` (the exchange becomes *shared*, the worker gets its
own reference) and queues the exchange itself on the pool (`TExchange` is a
`TWorkItem`, so queueing allocates nothing). A worker then runs
`Handler.Run(Ex)`. The worker's terminal call wakes the connection through
the loop's inbox. When `Run` returns, the worker's reference is released.

Rules:

- One `Offload` per request. A second one raises. `Offload` with the pool
  shut down raises `EWorkerPoolStopped`; the exception aborts the
  connection task.
- `Run` must make exactly one terminal call. If it returns without one, the
  exchange is failed with the message `handler returned no response`
  (the connection closes with a user error, section 9). If `Run` raises,
  the exception is caught: the exchange is failed with `handler raised
  <class>: <message>`, or, when a stream was already begun, the stream is
  aborted (`AbortStream`). Nothing reaches the worker pool's own safety
  net.
- On a worker the blocking body reads are allowed (section 6), and `Write`
  parks while the stream queue is full (section 5).
- `TWorkerPool.Saturated` (`Config.WorkerQueueLimit` reached) is not
  checked by `TOffloadCall`. A service that wants to answer `503` instead
  of queueing checks `Srv.Workers.Saturated` in its own `Poll` before
  calling `Offload`.
- The connection does not reuse a shared exchange for its next request; it
  takes another one from the loop's pool.

### Share, Release, Wake: your own threads

`Offload` is built on three calls you can use directly:

- `Share: TExchange` (loop thread, for example from `Poll`): switches the
  exchange to shared mode and adds one reference. From then on the body
  channel works under a lock and state changes are atomic, so the exchange
  may be used from the thread that got the reference. A thread holding a
  reference also counts as a *holder* of the request: the request head
  stays valid and a response stream stays open until the last holder
  releases.
- `Release` (any thread): drops the reference. The release that takes the
  holder count to 0 releases the request and finishes a stream still open
  (as if `Finish` had been called); the release that takes the reference
  count to 0 posts the recycle of the exchange to its loop.
- `Wake` (any thread on a shared exchange; loop thread on an unshared
  one): runs the owning connection task again, so `Poll` is called again.
  From another thread it is a message to the loop's inbox; at most one is
  queued at a time.

This is how a producer of server-sent events on its own thread works:
`Share` in `Poll`, `BeginStream`, return `cpPending`; the producer thread
calls `Write` and finally `Finish` and `Release`; the `Poll` after the
`BeginStream` wake returns `cpReady` (`Answered`). `TServer.Destroy` waits
for such references for `WorkerWaitMs`.

### The pool itself

`TWorkerPool` (unit `bearings.rt.workers`): `Create(Threads, Hooks,
QueueLimit)` starts the threads at once. `Submit(Item)` queues a
`TWorkItem` (raises `EWorkerPoolStopped` after `Shutdown`), `TrySubmit`
returns False instead. `QueueLength` (a hint), `Saturated`, `ThreadCount`,
`Alive`, `Executed`, `SpinNs` (nanoseconds an idle worker watches the
queue before it parks; default `DEFAULT_SPIN_NS` = 20 000; at most one
worker spins). `Shutdown(WaitMs)` refuses new items, runs the queued ones
and joins the threads. `TWorkerHooks.ThreadStarted(Index)` /
`ThreadStopping(Index)` run on the worker thread, for example to open one
database connection per worker. `CurrentWorkerIndex` returns the calling
worker's index, or -1. An exception that escapes a `TWorkItem.Execute` is
written to stderr and the worker goes on.

## 5. Response bodies

### A body of known length: Respond(Body)

`Respond(const Body: TBodyData): Boolean` sends the head and the body with
a `Content-Length` (the encoder writes it; the application does not).
`TBodyData` (unit `bearings.rt.buf`) is a plain record built by one of:

| Constructor | Memory / file | Who releases it, and how |
|-------------|---------------|--------------------------|
| `BodyEmpty` | no bytes | nothing |
| `BodyStatic(P, Len)` | memory that outlives the write (a constant, a global) | nothing |
| `BodyString(S)` | the bytes of a `RawByteString`, no copy | one reference to `S` is held until the bytes were written, then dropped |
| `BodyHeap(P, Len)` | memory from `GetMem` | `FreeMem(P)` after the write; the server owns `P` from the call on |
| `BodyCopy(Ex, P, Len)` (unit `bearings.http.exchange`) | a copy of `P^` in a block from the loop's pool (on the loop thread) or the heap (elsewhere) | the block goes back after the write |
| `BodyFile(Fd, Offset, Len, CloseAfter)` | `Len` bytes of the open file `Fd` from `Offset`, sent with `sendfile(2)` | `Fd` is closed after the last byte when `CloseAfter`; also when the connection dies before that |

`TBodyData` values may be built on any thread; the release
(`ReleaseBody`) runs on the loop thread after the bytes were written. If
`Respond` returns False (the exchange was canceled or already answered),
the body is released at once; the response is not sent.

A `TBodyOwnership` of `boCustom` with a `ReleaseProc(Ctx, Data)` exists in
the record for other arrangements; no constructor builds it.

For a response to a HEAD request, a 1xx, 204 or 304 status, or a 2xx to
CONNECT, no body bytes go on the wire; for HEAD the `Content-Length` the
body would have had is kept in the head.

### A body of unknown length: BeginStream, Write, Finish

`BeginStream(HighWater = 65536): Boolean` is the terminal call for a body
produced piece by piece. The head goes out at once with
`Transfer-Encoding: chunked` (HTTP/1.1) or without framing, closing the
connection at the end (HTTP/1.0). Then, from any thread holding the
exchange:

- `Write(P, Len): TWriteResult` queues a copy of the bytes as one chunk.
  Off the loop thread it parks while about `HighWater` bytes are queued,
  so a slow client slows the producer down instead of making the server
  buffer everything. On the loop thread it cannot park and returns
  `wrWouldBlock` when the queue is full.
- `TryWrite(P, Len)` never parks: `wrWouldBlock` when full.
- `WriteString(S)` queues the string without a copy (one reference kept).
- All three return `wrCanceled` when the exchange was canceled (the client
  went away) or the stream has ended; the producer stops then. A write of
  zero bytes returns `wrOk` while the stream is active.
- `Finish(Trailers = nil): Boolean` ends the body (the last chunk). False
  when the stream had already ended. Trailers are copied; they are written
  only when the response is chunked, the client announced it accepts them
  (`TE: trailers`), and the response head listed their names in a
  `Trailer` header.
- `AbortStream(Msg)` ends the body with an error: the chunked encoding is
  left without its last chunk, so the client sees an incomplete body, and
  the connection closes. `Msg` becomes the body error text
  (`SetBodyErrorText`) that the connection reports when it closes.

A stream left open when the last holder of the exchange releases it (the
worker's `Run` returned, every `Share` reference released) is finished
normally. `examples/stream.pas` writes ten lines, one per 100 ms, from a
worker.

### Your own source: RespondStream(Source)

`RespondStream(Source: TBodySource): Boolean` is the general form:
`BeginStream` is `RespondStream` with the exchange's own `TChannelBody`.
A `TBodySource` is polled on the loop thread, only while the socket can
take more:

- `PollFrame(Ex, out Data: TBodyData, out Trailers: THttpHeaders):
  TFramePoll` returns `fpData` with one frame, `fpTrailers` (the source
  keeps ownership of `Trailers` until the next call), `fpEnd`, `fpError`
  (call `Ex.SetBodyErrorText` first) or `fpPending` (the source must
  arrange `Ex.Wake`).
- `SizeHint(out Exact): Boolean` (default False: unknown length; True
  gives the body a `Content-Length` instead of chunked framing),
  `IsEndStream` (default False), `Done(Ex)` (the connection is done with
  the source; default nothing).

The application owns a source it created and frees it after `Done`. A
`TChannelBody` the application creates itself (`Create(HighWater)`,
`Reset(Ex, HighWater)`, `Push`, `FinishStream`, `AbortWith`) can be given
to `RespondStream`; it is the application's to free once its producers are
done.

### Fail(Msg)

`Fail(const Msg): Boolean` is the fourth terminal call: no response is
written and the connection closes with a user error; `Msg` becomes the
connection's error text. Use it when nothing sensible can be sent. A plain
`500` with `Respond` is usually better for a client.

## 6. Reading the request body

The request head tells what to expect: `ContentLength` is the declared
length, 0 for no body, -1 for a chunked body (or one that ends when the
connection closes). `ExpectsContinue` is True when the client sent
`Expect: 100-continue`: it waits for `100 Continue` before it sends the
body, and the server sends that interim response when the handler first
reads the body. A handler that answers without reading spares the client
the upload.

The connection decodes the body (Content-Length or chunked) and passes it
to the handler one chunk at a time through a channel that holds at most
one chunk. The next chunk is read from the socket only after the handler
took the previous one, so a slow handler slows the client down instead of
making the server buffer the body. A chunk is a view into the connection's
read buffer, not a copy, and it is valid until the next body call.

### On the loop thread: TryRead

`TryRead(out Chunk: TByteSlice): TBodyReadStatus` never blocks:

| Result | Meaning |
|--------|---------|
| `brData` | `Chunk` holds bytes, valid until the next body call |
| `brPending` | nothing yet; the call is polled again when data arrives (return `cpPending`) |
| `brTrailers` | the body ended with trailers: `RequestTrailers` holds them; `brEnd` follows |
| `brEnd` | the body ended (a request without a body gives `brEnd` at once) |
| `brError` | the body could not be read: `BodyErrorKind`, `BodyErrorMessage`, `BodyErrorIsTimeout` |
| `brCanceled` | the exchange was canceled, or the request was already released |

### On a worker thread: Read, ReadChunk, ReadAll, ReadFrame

These block until data arrives (the worker is parked; the loop wakes it
when the channel changes):

- `ReadFrame(out Chunk): TBodyReadStatus`: `TryRead` that blocks instead
  of returning `brPending`. For a handler that must see the trailers.
- `ReadChunk(out Chunk): Boolean`: the next chunk without a copy; False at
  the end. It skips the trailer frame (`RequestTrailers` still holds the
  trailers afterwards). Raises `EBodyError` on a body error and
  `EClientGone` when the exchange was canceled or the request was released
  before the body ended.
- `Read(Buf, Max): SizeInt`: copies up to `Max` bytes; 0 at the end. Same
  exceptions.
- `ReadAll(var Dst: TBytes; Limit): SizeInt`: appends the whole body to
  `Dst` and returns the number of bytes appended. With `Limit > 0` it
  raises `EBodyTooLarge` when `ContentLength` is over the limit (before
  reading anything) or when the bytes read exceed it. Same exceptions as
  `ReadChunk`.

`DiscardBody` closes the receiver only: the handler does not want the
rest. The connection then reads and discards it, or closes the connection
(no `100 Continue` is sent for an unread body). The head stays valid.
`RequestTrailers: THttpHeaders` holds the trailers after `brTrailers` or
`brEnd`.

Body errors (`TBodyErrorKind`): `bekUnexpectedEof` (the connection closed
in the middle of the body), `bekInvalidData` (a malformed chunked
encoding), `bekInvalidInput`, `bekIo` (a socket error), `bekOther`.
`BodyErrorIsTimeout` is True when the body rate rule
(`TH1Config.BodyReadTimeoutMs`, `BodyMinRate`) failed the body: the client
sent nothing for too long or too slowly. `BodyErrorMessage` is the text of
`conformance/SPEC.md` 7.1. `EBodyError.Kind` carries the same
`TBodyErrorKind`.

`examples/worker.pas` shows the three exceptions handled.

## 7. The response head

Written before the terminal call, by the thread that will make it (on a
shared exchange, only that thread; builds with assertions check this):

- `Status: Word` (default 200). The encoder writes the standard reason
  phrase of the status (`bearings.http1.reason`). A 1xx status other than
  101 cannot be sent: a `500` head is written instead and the connection
  closes with a user error.
- `ResponseVersion: THttpVersion` (default `hv11`).
- `SetReason(P, Len): Boolean` sets a custom reason phrase (the bytes are
  copied); False, and nothing changes, when it holds an invalid byte.
- `ResponseHeaders: THttpHeaders` is the header list of the response. It
  is cleared at every request and keeps its capacity, so a list reused by
  a connection stops allocating once it is large enough.

`THttpHeaders` (unit `bearings.http.headers`) keeps the fields in
insertion order, keeps the case of each name and looks names up ignoring
case. Mutators:

- `Add(Name, Value)` (two overloads: `RawByteString` or `PByte` + length)
  appends a field; `Append` is the same. `Insert(Name, Value)` sets the
  only value of `Name`: the first entry gets the value, later entries with
  that name are removed, or the field is appended. `SetValue(I, Value)`
  replaces the value of entry `I`. These **validate** their input and raise
  `EInvalidHeader` (with `Check: THeaderCheck` = `hcBadName` or
  `hcBadValue`) on a bad name or value; the list is then unchanged. A name
  must be an RFC 9110 token (1 to 65 535 bytes of `ALPHA DIGIT ! # $ % & '
  * + - . ^ _ \` | ~`); a value may hold HTAB and any byte >= 0x20 except
  0x7F. CR, LF and NUL are refused because a value that contained them
  would end the header line early or add header lines of its own
  (response splitting), letting whatever supplied the value inject headers
  or a second response.
- `TryAdd`, `TryInsert`, `TrySetValue` make the same checks and return a
  `THeaderCheck` instead of raising.
- `AddTrusted`, `InsertTrusted`, `SetValueTrusted` skip the checks, for
  bytes that are valid by construction (constants, parser output). The
  library's own code uses these.
- `Delete(I)`, `Remove(Name)` (returns how many), `Clear`.

Lookups: `IndexOf(Name, StartIndex = 0)`, `LastIndexOf`, `Contains`,
`CountOf`, `Get(Name, out Value, out ValueLen)` (a slice; no allocation),
`GetValue(Name)` (a new string; allocates), `NamePtr(I)` / `NameLen(I)` /
`ValuePtr(I)` / `ValueLen(I)` (slices, valid until the next call that adds
bytes to the list), `Name(I)` / `Value(I)` (copies), `NameIs(I, Name)`,
`Count`, `Entries[I]`.

Framing headers are the encoder's: it writes `Content-Length` for
`Respond` and for a `TBodySource` with a `SizeHint`, `Transfer-Encoding:
chunked` otherwise (HTTP/1.1), and `Date` unless the application set one
(`AutoDateHeader`). A `Content-Length` or `Transfer-Encoding` header set
by the application that is invalid or contradicts the body makes the
response a user error: the connection closes. On a request header list
(`Ex.Headers`) the application only reads.

## 8. Cancellation, keep-alive and pipelining

**Cancellation.** When the client disconnects, the connection fails, or
the server's shutdown deadline passes while a call is in flight, the
connection cancels the exchange and calls `Drop(Ex, False)`. From then on:
terminal calls return False and send nothing (their body is released);
`TryRead` returns `brCanceled`; the blocking reads raise `EClientGone`;
stream writes return `wrCanceled`; a worker parked in a body read or a
full-queue write is woken. A long-running handler that is not in a body
call checks `IsCanceled` now and then. Nothing is sent to a client that is
gone, so a handler may simply return.

**Keep-alive.** With `TH1Config.KeepAlive` (the default), an HTTP/1.1
connection stays open after a response unless either side sent
`Connection: close`; an HTTP/1.0 connection stays open only when the client
sent `Connection: keep-alive`. Each request on the connection is a new
call on the same (unshared) exchange object; `RequestNo` counts them (1, 2,
...) and `ConnId` identifies the connection (unique per server).

**Pipelining.** A client may send several requests without waiting for
the responses. The connection keeps **one call in flight at a time**: the
next pipelined request stays unparsed in the read buffer until the
current call completed, and responses go out in request order. So a slow
handler delays the later requests of its own connection, not those of
other connections. With `PipelineFlush`, responses to pipelined requests
are held while another request is already buffered, so several leave in
one write.

**Idle connections.** The header read timeout (`HeaderReadTimeout`, 30 s
with `ProductionH1Config`) closes a connection whose client does not send
a complete request head in time; this also bounds idle keep-alive
connections. Without a timer (`Timer = False`) nothing times out.

## 9. Errors

Exceptions a program meets:

| Exception | Unit | When |
|-----------|------|------|
| `EServerError` | `bearings.server` | `Start` failed (port in use, invalid `H1`, no factory, started twice), `RunLoop0` without `StartCallerRunsLoop0` |
| `EInvalidHeader` | `bearings.http.headers` | a validating header mutator got a bad name or value |
| `EBodyError` | `bearings.http.exchange` | a blocking body read: the body could not be read (`Kind: TBodyErrorKind`) |
| `EClientGone` | `bearings.http.exchange` | a blocking body read after a cancel or a release |
| `EBodyTooLarge` | `bearings.http.exchange` | `ReadAll`: the body is over the limit |
| `EWorkerPoolStopped` | `bearings.rt.workers` | `Submit` or `Offload` after `Shutdown` started |
| `EH1Panic` | `bearings.http.error` | a program error inside the HTTP/1 code (for example a response version the encoder cannot write); the loop aborts the connection |

The HTTP layer's own error value is `THyperError` (unit
`bearings.http.error`), a plain record: `Kind: THyperErrorKind` says what
failed, `Cause: TErrorCause` adds what is known (`ecErrno` with `Errno`,
`ecDecode` with `Decode`, `ecStatic` with `StaticMsg`, `ecConnText`: the
text the application passed to `Fail` or `AbortStream`, `ecInner`). The
kinds: `hekParse` (malformed or too large request head; `Parse` holds the
parser's reason, `h1peVersionH2` means an HTTP/2 preface), `hekUser` (the
application did something wrong: `User: THyperUserKind` = `hukService`,
`hukBody`, `hukHeader`, `hukUnsupportedStatusCode`, `hukNoUpgrade`,
`hukManualUpgrade`), `hekBodyWriteAborted` (the response body ended before
its declared length; `NotEofRemaining` bytes missing), `hekIncompleteMessage`
(the connection closed in the middle of a message), `hekIo`,
`hekHeaderTimeout`, `hekBody`, `hekBodyWrite`, `hekShutdown`;
`hekCanceled`, `hekChannelClosed` and `hekUnexpectedMessage` exist but the
server code does not create them. The predicates `IsParse`,
`IsParseTooLarge`, `IsParseVersionH2`, `IsUser`, `IsCanceled`, `IsClosed`,
`IsIncompleteMessage`, `IsBodyWriteAborted`, `IsShutdown`, `IsTimeout`,
`HasIoSource` classify one. `ErrorDescription(E, ConnText)` builds the log
text. The `New*` constructors build the values; a program normally only
reads them.

A program sees these through the connection observer (section 11):
`OnConnClose(ConnId, Data, Outcome: TConnOutcome, Detail)`. `TConnOutcome`
is how the connection ended: `coOk`, `coTimeout`, `coParseTooLarge`,
`coParseVersionH2`, `coParse`, `coIncomplete`, `coUser`, `coCanceled`,
`coClosed`, `coBodyWriteAborted`, `coShutdown`, `coIo`, `coOther`;
`OutcomeOf(R: TPollResult, E)` maps a result to one, in that order of
tests (`conformance/SPEC.md` 7.2). The parser's own error responses (400
for a malformed head, 414 for a too long request-target, 431 for a too
large head) are sent by the connection without involving the service.

## 10. Connection upgrades

A client may ask to switch the connection to another protocol with an
`Upgrade` header (WebSocket is the common case). `Ex.WantsUpgrade` is
True for such a request. The handler that accepts:

1. calls `Ex.OnUpgrade(H)` with a `TUpgradeHandler`, on the loop thread,
   before answering (for an offloaded request, this means in `Poll` before
   `Offload`, or in `THttpService.Call`);
2. answers with status 101 (`Status := 101`, then `Respond(BodyEmpty)`);
   the `Upgrade` and `Connection` response headers the protocol requires
   are the application's to set.

What happens next depends on `TH1Config.Mode`:

- `cmWithUpgrades` (`ProductionH1Config`): after the 101 response was
  written, the socket and the bytes already read after the request are
  handed to the handler on the loop thread: `H.Upgraded(U: TUpgraded)`.
- `cmPlain`: upgrades are not handed over; `H.UpgradeFailed(Msg)` is
  called and the connection ends.
- `cmWithoutShutdown`: like `cmPlain` for upgrades; when the HTTP
  connection ends, the socket and the unread bytes go to the observer's
  `OnParts` instead of being closed (section 11).

If the upgrade does not happen (no 101, the connection failed),
`UpgradeFailed` is called instead of `Upgraded`. `OnUpgrade` on a request
that did not ask for an upgrade calls `UpgradeFailed('no upgrade
available')` at once. The default `UpgradeFailed` does nothing.

`TUpgraded` (unit `bearings.rt.stream`) is the connection after the
hand-off. The handler owns it from `Upgraded(U)` on and must take it
(`Taken` becomes True) in one of two ways, or close it:

- `Attach(L: TRawListener)`: stay on the loop. On every socket event and
  every wake the task calls `L.Readable(U)` and then, if still open and
  attached, `L.Writable(U)`. Inside them, `TryRead(Buf, Max)` (> 0 bytes,
  0 at EOF, a negative errno such as -EAGAIN) and `TryWrite(Buf, Len)`
  follow the readiness rules, so a callback with nothing to do costs no
  system call. `TryRead` returns the leftover bytes first; `Leftover` and
  `ConsumeLeftover` give direct access to them. `Attach(nil)` removes the
  listener. `Close` closes the socket.
- `Detach(out Fd, out Rest): Boolean`: leave the loop for blocking use on
  another thread. The socket is removed from epoll and made blocking, the
  leftover bytes are copied into `Rest`, the task is closed, and the caller
  owns `Fd` and must close it. False, and nothing changes, when the socket
  does not belong to this task (an observer wrapped the transport with
  something that is not a plain TCP transport).

If `Upgraded` raises while `U` is not taken, `U` is closed before the
exception goes on to the loop. Everything in `TUpgraded` runs on the loop
thread except what the caller does with a detached `Fd`. The WebSocket
protocol itself (framing, the handshake check) is not in the library yet;
`docs/handoff-websocket.md` is the plan.

## 11. The connection observer

`TConnObserver` (declared in `bearings.http.exchange`, re-exported by
`bearings.server`) is a set of per-connection hooks for tests, the
conformance server and instrumentation. Pass an instance as the third
argument of `TServer.Create`; nil costs nothing. All hooks run on the loop
thread:

| Hook | When | Default |
|------|------|---------|
| `OnAccept(Loop, ConnId, Peer): Pointer` | a socket was accepted; returns per-connection data passed to the other hooks | nil |
| `WrapTransport(T: TTcpTransport, Data): TTransport` | may wrap the socket transport (for example to count bytes) | returns `T` |
| `OnStart(ConnId, Data, Task)` | the connection task is set up and registered, before its first run | nothing |
| `OnConnClose(ConnId, Data, Outcome, Detail)` | the connection ended; `Outcome` is a `TConnOutcome`, `Detail` the error text | nothing |
| `OnParts(ConnId, Data, var Parts: TConnParts)` | `cmWithoutShutdown` only: the HTTP connection ended; `Parts.Transport` (owned by the receiver), `Parts.Rest` (unread bytes, a pinned view) and `Parts.Src` are handed over | closes them |

A receiver that keeps the socket open in `OnParts` builds a `TUpgraded`
with `TUpgraded.CreateFrom(Loop, Transport, Rest, Src, True)` before
`OnParts` returns.

## 12. Debug build flags

The library has no build step; the flags are `-d` defines (and `-Sa`) of
the program that compiles it. They keep the `WD_` prefix.

- `-Sa` (assertions): the threading rules are checked (an unshared
  exchange is used only on its loop thread; the response head is written
  only by the thread that makes the terminal call; `THttpService.Call`
  neither answers nor reads the body; a recycled exchange is never woken),
  the encoders assert every header name and value they write, and a
  released request head is overwritten with `$DD` bytes so code that reads
  it late sees that pattern. Release builds contain none of these checks
  (`tools/check-hot-asm.sh --s7` verifies that no `Dbg*` routine and no
  assertion call is in a production build of `bearings.http.exchange`).
- `-dWD_DEBUG`: the connection task checks, at the end of every run that
  returns "pending", that a wake source is armed (a socket wait, a timer, a
  pending call or body source, or a body channel waiting for its
  receiver); a failure increments `WakeAssertFailures`
  (`bearings.http1.dispatch`) and raises with `-Sa`. A pending connection
  without a wake source would stay stuck until a timeout. Also, freed
  buffer-pool blocks are filled with `$DD` (`bearings.rt.buf`), so a use
  after release shows up.
- `-dWD_STALL` (requires `WD_DEBUG`): the stall detector of
  `bearings.server`. Each loop scans its connections once per second and
  reports on stderr, once per connection, every connection that is in the
  middle of a message, has not run for `STALL_MS` (60 000 ms) and waits on
  the server rather than on the client. `StallReports` counts the reports.
  For soak tests.
- `-dWD_DRD`: builds for valgrind's `drd` race detector
  (`bearings.rt.sync`). The spin locks, parkers and atomic accessors get
  happens-before annotations through valgrind client requests and are not
  inlined, so `tools/drd.supp` can suppress the reports on the
  synchronization words themselves. `tests/unit/run_all.sh` runs the
  worker tests this way.

## 13. Performance rules

The measured speed (`docs/design/m3-perf-report.md`: 0.85 to 0.98 of hyper
on the plaintext benchmark; an idle keep-alive connection at about 1.3 KB)
depends on the *inline path* allocating nothing and touching no atomic
instruction per request. The library keeps its side of this: the exchange
is reused per connection, header lists are cleared and reused, the body
channel is a record inside the exchange, posting a message to a loop
allocates nothing. A program that wants the same speed for its inline
answers must keep its side:

- Return one shared, stateless call object from `THttpService.Call`
  (or a pooled one, given back in `Drop`). Creating a call object per
  request is one allocation per request.
- Use `BodyStatic` for constant bodies and `BodyString` for strings that
  already exist; `BodyCopy` and `BodyHeap` allocate. Building a
  `RawByteString` per request (concatenation, `IntToStr`) allocates.
- Add constant headers with `AddTrusted` and constants (`bench/plaintext.pas`
  does this). `Add` validates the bytes (a few comparisons per byte) and
  copies them into the list's arena; the arena is reused per connection,
  so there is no heap allocation once the list is warm. The
  `RawByteString` overloads cost nothing extra with string constants; a
  string built per request does.
- Do not `Share` or `Offload` on the inline path: both touch atomics and
  the offloaded request costs a thread hand-off (measured at about 2.3 to
  2.7 us per request on the benchmark machine, `bench/run_offload.sh`).
- Do not read `Ex.Headers` with `GetValue` (it allocates a string); use
  `Header(Name, out V)` or `Get`, which return slices.
- Managed locals (strings, dynamic arrays, interfaces) in a routine make
  the compiler add an implicit exception frame to it (`fpc_pushexceptaddr`
  / `fpc_setjmp` calls on entry and exit), which costs on every call. The
  **hot-asm check**, `tools/check-hot-asm.sh`, compiles the library with
  `-al` (assembler listings) in the production (`-O3`) and test (`-O2 -Sa`)
  configurations and fails when any routine of the request path got such a
  frame (`tools/hot-asm.py` reads the listings; the list of routines is in
  the script). It checks the library's routines only; a program can apply
  the same rule to its own `Poll` by keeping managed types out of it
  (`bench/plaintext.pas`'s `Answer` has none).

On the worker path these rules are relaxed: a worker request already costs
a thread hand-off, and `ReadAll`, `BodyString` and ordinary string code
are the normal way to write a handler there.

## 14. Reference tables

Threading rule abbreviations: **loop** = the loop thread that owns the
exchange or object; **worker** = a worker thread (or any thread holding a
`Share` reference, not the loop); **any** = any thread; **owner** = the
thread that owns the server. "internal" marks members that exist for the
dispatcher, the pool or the tests and that a program does not call;
members whose names start with `Dbg`, the test hooks (`ReleaseTestHook`,
`TryReadTestHook`, `AnswerTestHook`, `ReleaseBeforeDecrementHook`,
`PostAfterPushHook`, `PostBeforePushHook`) and the `TBodyChan` record's
methods are internal and are left out.

### bearings.server

| Member | Description | Thread |
|--------|-------------|--------|
| `TServerConfig` | the options (section 2) | plain value |
| `TServer.Create(Cfg, Factory, Observer = nil)` | stores the configuration, the service factory and the observer | owner |
| `TServer.Start` | binds, starts loops and workers; returns | owner |
| `TServer.StartCallerRunsLoop0` | `Start` without a thread for loop 0 | owner |
| `TServer.RunLoop0` | runs loop 0 on the calling thread until `Stop` | owner |
| `TServer.Stop(GraceMs)` | starts the graceful shutdown; returns at once | any |
| `TServer.Wait` | joins the loop threads, then shuts the worker pool down | owner |
| `TServer.RunUntilSignal(Started = nil): cint` | `Start`, wait for SIGTERM/SIGINT, `Stop`, `Wait`; the signal number or 0 | owner |
| `TServer.GracefulShutdownConnections` | closes every open connection after its current response; listeners keep accepting | any except a loop thread |
| `TServer.Destroy` | stops if needed, aborts what is left, frees loops and pools (or leaks them on purpose) | owner |
| `TServer.Port` | the bound port | any after `Start` |
| `TServer.Started` | `Start` completed | any |
| `TServer.Workers` | the worker pool, nil without one | any after `Start` |
| `TServer.Config`, `LoopCount`, `Loops[I]` | the configuration, the loops | any after `Start` |
| `TServerEvent` | `procedure(Server: TServer) of object`, the `Started` callback | owner |
| `TServerLoop` | one loop and what it owns: `Loop`, `Listener`, `Service`, `Pool`, `Conns`, `Index`, `Cpu`, `Thread`, `Running`, `Stopping`, `GraceMs`; `AbortConnections` and `Destroy` are internal | loop (read by tests after the loop stopped) |
| `EServerError` | `Start` / `RunLoop0` errors | - |
| `ProductionServerConfig`, `BenchmarkServerConfig` | the two presets | any |
| `TConnOutcome`, `TConnParts`, `TConnObserver` | re-exported from `bearings.http.error` and `bearings.http.exchange` | see there |
| `STALL_MS`, `StallReports` | `WD_STALL` builds only (section 12) | any (atomic) |

### bearings.http.exchange

| Member | Description | Thread |
|--------|-------------|--------|
| `THttpService.Call(Ex): TServiceCall` | picks the call of a request; must not answer or read the body | loop |
| `TServiceFactory` | `function(Loop: TLoop): THttpService of object`; one call per loop | owner (inside `Start`) |
| `TServiceCall.Poll(Ex): TCallPoll` | runs the handler; `cpReady` after a terminal call, else `cpPending` | loop |
| `TServiceCall.Drop(Ex, Completed)` | called exactly once at the end | loop |
| `TCallPoll` | `cpPending`, `cpReady` | - |
| `TBlockingHandler.Run(Ex)` | the handler of an offloaded request; may block | worker |
| `TOffloadCall` (`Pool`, `Handler`, `Poll`) | a stateless call that offloads every request | loop |
| `TExchangeAttachment.Detach(Ex)` | per-request state the exchange detaches at recycle or next request | loop |
| `TByteSlice` | `P: PByte; Len: SizeInt` | - |
| `TRequestHead` (`Ex.Head`) | the parsed head: `View`, `Method`, `MethodSlice`, `Target`, `Uri`, `Version`, `Headers`, `ContentLength`, `ExpectContinue`, `WantsUpgrade`, `Peer`, `Local`, `ConnId`, `RequestNo`, `Released`; read through the accessors below | any holder, until the request is released |
| `TExchange.Method`, `MethodBytes`, `Target`, `Path`, `Query(out Q)`, `Version`, `Headers`, `Header(Name, out V)`, `ContentLength`, `ExpectsContinue`, `WantsUpgrade`, `ConnId`, `RequestNo`, `PeerAddr` | request head accessors; valid until the request is released; `Headers` is read-only by contract | loop when unshared; any holder when shared |
| `TExchange.ReleaseRequest` | the application is done with the request: body receiver closed, head unpinned | loop when unshared; any holder when shared |
| `TExchange.TryRead(out Chunk): TBodyReadStatus` | non-blocking body read | loop when unshared; any holder when shared |
| `TExchange.Read(Buf, Max): SizeInt` | blocking copy read; 0 = end | worker |
| `TExchange.ReadChunk(out Chunk): Boolean` | blocking zero-copy read; False = end; skips trailers | worker |
| `TExchange.ReadAll(var Dst, Limit): SizeInt` | blocking; appends the body to `Dst`; `EBodyTooLarge` | worker |
| `TExchange.ReadFrame(out Chunk): TBodyReadStatus` | `TryRead` that blocks instead of `brPending` | worker |
| `TExchange.DiscardBody` | closes the body receiver only | loop when unshared; any holder when shared |
| `TExchange.RequestTrailers: THttpHeaders` | the request trailers after `brTrailers` / `brEnd` | same as `TryRead` |
| `TExchange.BodyErrorKind`, `BodyErrorMessage`, `BodyErrorIsTimeout` | the last body error | same as `TryRead` |
| `TExchange.Status`, `ResponseVersion` | the status (default 200) and version (default `hv11`) | the answering thread, before the terminal call |
| `TExchange.SetReason(P, Len): Boolean` | a custom reason phrase; False for an invalid byte | the answering thread, before the terminal call |
| `TExchange.ResponseHeaders: THttpHeaders` | the response header list | the answering thread, before the terminal call |
| `TExchange.Respond(Body): Boolean` | terminal: known length or empty | any holder |
| `TExchange.RespondStream(Source): Boolean` | terminal: a `TBodySource` | any holder |
| `TExchange.BeginStream(HighWater = 65536): Boolean` | terminal: the exchange's own channel body | any holder |
| `TExchange.Fail(Msg): Boolean` | terminal: no response, the connection closes with a user error | any holder |
| `TExchange.Write(P, Len)`, `WriteString(S)`: `TWriteResult` | queue a chunk; park while full off the loop (`wrWouldBlock` on the loop) | any holder, after `BeginStream` |
| `TExchange.TryWrite(P, Len): TWriteResult` | queue a chunk; never parks | any holder, after `BeginStream` |
| `TExchange.Finish(Trailers = nil): Boolean` | end the streamed body | any holder, after `BeginStream` |
| `TExchange.AbortStream(Msg)` | end the streamed body with an error | any holder, after `BeginStream` |
| `TExchange.OnUpgrade(H)` | register the upgrade handler | loop, before answering |
| `TExchange.OnLoopThread: Boolean` | the caller is the loop thread (a query) | any |
| `TExchange.Offload(Pool, H)` | `Share` and queue on the pool; a worker runs `H.Run` | loop, from `Poll`, once per request |
| `TExchange.Share: TExchange` | switch to shared mode, +1 reference | loop |
| `TExchange.Release` | -1 reference; the last one recycles the exchange | any, after `Share` |
| `TExchange.Wake` | run the owning connection again | loop when unshared; any when shared |
| `TExchange.IsCanceled`, `Answered: Boolean` | the state | any (loop only when unshared) |
| `TExchange.SetBodyErrorText(Msg)` | the error text a `TBodySource` sets before `fpError` | loop |
| `TExchange.Loop: TLoop` | the owning loop | any |
| `TExchange.User: TObject`, `Tag: PtrInt` | per-request application state; nil / 0 at every request; not freed by the exchange | the holder |
| `TExchange.Attachment` | per-request state with a `Detach` callback | loop (set before `Offload` when a worker reads it) |
| `TExchange.Shared`, `RefCount`, `Offloaded`, `Owner`, `Generation`, `UpgradeSlot` | read-only state | any (`RefCount` atomic) |
| `TExchange.Head`, `Chan`, `Resp`, `ReqTrailers` | the public fields; `Chan` and `Resp` are the dispatcher's | internal except `Head` (read) |
| `TExchange.BeginRequest`, `FillHead`, `LinkUpgrade`, `CompleteCall`, `Cancel`, `Recycle`, `ReleaseTransport`, `Execute` | the dispatcher's and the pool's entry points | internal |
| `TBodyReadStatus` | `brData`, `brTrailers`, `brEnd`, `brPending`, `brError`, `brCanceled` | - |
| `TWriteResult` | `wrOk`, `wrWouldBlock`, `wrCanceled` | - |
| `TBodyErrorKind` | `bekUnexpectedEof`, `bekInvalidData`, `bekInvalidInput`, `bekIo`, `bekOther` | - |
| `EClientGone`, `EBodyError` (`Kind`), `EBodyTooLarge` | body read exceptions (section 6) | - |
| `TExchangeState` | `xsIdle`, `xsCalled`, `xsAnswered`, `xsCanceled`, `xsDone` | - |
| `TWakeTimer.Arm(Ex, DelayMs)`, `Fired`, `Cancel(Ex)` | an application timer that wakes the connection | loop |
| `TBodySource.SizeHint`, `IsEndStream`, `PollFrame`, `Done` | a response body produced piece by piece | loop (called by the dispatcher) |
| `TFramePoll` | `fpData`, `fpTrailers`, `fpEnd`, `fpError`, `fpPending` | - |
| `TChannelBody.Create(HighWater)`, `Reset(Ex, HighWater)`, `Push(var B, Block)`, `FinishStream(Trailers)`, `AbortWith(Msg)`, `Queued`, `EmptyWrite`, `Closed` | the bounded frame queue behind `BeginStream`; usable with `RespondStream` | producers: any; `PollFrame`/`Done`: loop |
| `TChannelBody.AutoFinish`, `WakeProducer`, `Deactivate` | called by the exchange | internal |
| `TUpgradeHandler.Upgraded(U)`, `UpgradeFailed(Msg)` | the upgrade callbacks | loop |
| `TUpgradeSlot`, `TUpgradeState`, `TUpgradePending` | the connection side of an upgrade | internal |
| `TExchangePool` (`Take`, `Give`, `FreeCount`, `Outstanding`) | the per-loop exchange pool | internal (loop) |
| `TConnObserver` hooks (section 11) | per-connection hooks | loop |
| `TConnParts` | `Transport`, `Rest`, `Src` handed over by `OnParts` | loop |
| `BodyCopy(Ex, P, Len): TBodyData` | a body that is a copy of `P^` in a pooled or heap block | any |
| `UpgradeSlotsLive`, `ExchangesLive` | object counters for tests | any (atomic) |
| `TBodyChan`, `TChanItemKind`, `TChanPoll`, `TResponseSlot` | the body channel record and the response slot | internal |

### bearings.rt.buf (the body API)

| Member | Description | Thread |
|--------|-------------|--------|
| `TBodyData` | one piece of response body: `Kind: TBodyKind` (`bkEmpty`, `bkMem`, `bkFile`), `P`, `Len`, `Own: TBodyOwnership`, `Ctx`, `ReleaseProc`, `Fd`, `Offset`, `CloseFd` | build: any; release: loop |
| `TBodyOwnership` | `boStatic`, `boString`, `boHeap`, `boExchange`, `boCustom` (how the memory is released) | - |
| `TBodyReleaseProc` | `procedure(Ctx: Pointer; Data: PByte)` for `boCustom` | loop |
| `BodyEmpty` | no bytes | any |
| `BodyStatic(P, Len)` | memory that outlives the write | any |
| `BodyString(S)` | a string; one reference held until released | any |
| `BodyHeap(P, Len)` | `GetMem` memory; `FreeMem` after the write | any |
| `BodyFile(Fd, Offset, Len, CloseAfter)` | a file range sent with sendfile | any |
| `ReleaseBody(var B)` | releases per `Own`, closes the file if `CloseFd`; `B` becomes `BodyEmpty` | loop (the dispatcher) |
| `TBlockPool`, `TBufBlock`, `TReadBuf`, `TBytesView`, `TByteVec`, `BlockAlloc`, `BlockFree`, `PoolClassIndex`, `POOL_*` | the buffer pool and the connection buffers | internal (loop) |

### bearings.http.headers

| Member | Description | Thread |
|--------|-------------|--------|
| `THttpHeaders.Create(AEntryCapacity = 16, ADataCapacity = 1024)` | an empty list | any |
| `Clear` | removes every entry; keeps capacity | one thread at a time |
| `Add(Name, Value)` (2 overloads), `Append(Name, Value)` | append a field; validate; `EInvalidHeader` | one thread at a time |
| `Insert(Name, Value)` (2 overloads) | set the only value of `Name`; validate | one thread at a time |
| `SetValue(I, Value)` (2 overloads) | replace a value; validate | one thread at a time |
| `TryAdd`, `TryInsert`, `TrySetValue` | the same without exceptions: `THeaderCheck` | one thread at a time |
| `AddTrusted` (2 overloads), `InsertTrusted` (2 overloads), `SetValueTrusted` | no validation | one thread at a time |
| `AddExternal(NameOfs, NameLen, ValueOfs, ValueLen)` | a field whose bytes stay in the external buffer (the parser uses it) | one thread at a time |
| `Delete(I)`, `Remove(Name): SizeInt` | remove entries | one thread at a time |
| `SetExternalBase(Base)`, `Detach`, `ExternalBase` | the external buffer (parser side) | one thread at a time |
| `IndexOf` (2 overloads), `LastIndexOf`, `Contains`, `CountOf`, `Get`, `GetValue` | lookups (case-insensitive) | one thread at a time |
| `NamePtr`, `NameLen`, `ValuePtr`, `ValueLen`, `Name`, `Value`, `NameIs` | entry access | one thread at a time |
| `WireLength`, `WriteTo(Dst, NameCase)`, `AppendTo(var Buf, var Len, NameCase)` | serialization as `name: value\r\n` lines | one thread at a time |
| `Count`, `Entries[I]` | the entries (`THttpHeaderEntry`) | one thread at a time |
| `THeaderNameCase` | `hncLower`, `hncTitle`, `hncAsIs` | - |
| `THeaderCheck`, `EInvalidHeader` (`Check`) | the validation result and exception | - |
| `IsValidHeaderName`, `IsValidHeaderValue`, `CheckHeaderField`, `RaiseInvalidHeader`, `IsVisibleAscii` | the checks | any |
| `AsciiLower`, `AsciiEqualIgnoreCase`, `AsciiEqualIgnoreCaseStr`, `WriteTitleCase`, `WriteDecimal`, `FromDigits` | byte helpers | any |
| `ConnectionKeepAlive`, `ConnectionClose`, `ConnectionHas`, `ConnectionAnyClose`, `TeIsTrailers`, `HeaderValueListHas`, `ContentLengthParse`, `ContentLengthParseAll`, `TransferEncodingIsChunked`, `IsChunkedValue` | interpretation of header values | any |
| `HN_*` constants, `DEFAULT_MAX_HEADERS`, `MAX_HEADER_NAME_LEN` | lowercase header names and limits | - |
| `ValidatingMutatorCalls` | `-Sa` builds only: a counter for tests | any (atomic) |

### bearings.http1.config

| Member | Description | Thread |
|--------|-------------|--------|
| `TH1Config` | the connection options (section 2) | plain value |
| `TH1ConnMode` | `cmPlain`, `cmWithUpgrades`, `cmWithoutShutdown` | - |
| `TTimeoutSetting` | `tsDefault`, `tsDisabled`, `tsMs` | - |
| `ConformanceH1Config`, `ProductionH1Config` | the presets | any |
| `ValidateH1Config(C, out Msg): Boolean` | checks a configuration | any |
| `ApplyH1Config(C, var Conn)` | applies it to a connection; `TServer` calls it | internal (loop) |

### bearings.rt.stream

| Member | Description | Thread |
|--------|-------------|--------|
| `TRawListener.Readable(U)`, `Writable(U)` | callbacks of an attached stream | loop |
| `TUpgraded.CreateFrom(Loop, Transport, Rest, FromSrc, OwnsTransport)` | the hand-off constructor (the dispatcher, or an `OnParts` receiver) | loop |
| `TUpgraded.Transport` | the transport | loop |
| `TUpgraded.Run`, `Abort` | the loop task's entry points | internal |
| `TUpgraded.Leftover(out P, out Len)`, `ConsumeLeftover(N)` | the bytes read before the hand-off | loop |
| `TUpgraded.Attach(L)` | stay on the loop with callbacks; nil removes them | loop |
| `TUpgraded.TryRead(Buf, Max)`, `TryWrite(Buf, Len)` | non-blocking socket calls; `> 0`, `0` EOF, `-errno` | loop |
| `TUpgraded.Detach(out Fd, out Rest): Boolean` | leave the loop; the caller owns the blocking `Fd` | loop (then `Fd`: any) |
| `TUpgraded.Close` | closes the socket and the task | loop |
| `TUpgraded.Taken: Boolean` | attached, detached or closed | loop |

### bearings.http.error

| Member | Description | Thread |
|--------|-------------|--------|
| `THyperError` and its predicates (`IsParse`, `IsParseTooLarge`, `IsParseVersionH2`, `IsUser`, `IsCanceled`, `IsClosed`, `IsIncompleteMessage`, `IsBodyWriteAborted`, `IsShutdown`, `IsTimeout`, `HasIoSource`) | why an HTTP message failed (section 9) | any (plain value) |
| `THyperErrorKind`, `THyperUserKind`, `TErrorCause` | its enumerations | - |
| `TPollResult` (`prOk`, `prErr`, `prPending`), `TPollOpt` (`poSome`, `poErr`, `poNone`, `poPending`) | results of the connection code's poll routines | internal |
| `EH1Panic` | a program error inside the HTTP/1 code | - |
| `TConnOutcome` | how a connection ended | - |
| `New*` (`NewParse`, `NewIncomplete`, `NewTooLarge`, `NewVersionH2`, `NewIo`, `NewHeaderTimeout`, `NewBodyDecode`, `NewBodyIo`, `NewBodyStatic`, `NewBodyWrite`, `NewBodyWriteAborted`, `NewShutdown`, `NewUserService`, `NewUserBody`, `NewUserHeader`, `NewUserUnsupportedStatusCode`, `NewUserManualUpgrade`, `NewClosed`) | constructors of error values (the connection code uses them) | any |
| `ErrorDescription(E, ConnText): string` | the log text of an error | any |
| `OutcomeOf(R, E): TConnOutcome` | maps a result to an outcome | any |

### Also used directly

- `bearings.rt.loop`: `TLoop` (the loop a `TServiceFactory` receives:
  `Index`, `NowMs`, `NowNs`, `Timers`, `Blocks`, `Post(M)` from any
  thread, `Register` / `Unregister` on the loop thread), `TLoopTask`,
  `TIoTask`, `TLoopMsg` (`lmCall` runs `Proc(Loop, Arg)` on the loop),
  `LoopErrorProc` (the exception logger; default one line on stderr),
  `LoopTickProc` (assigned by `bearings.http.date`), `ReadyFromEpoll`.
  Everything runs on the loop thread except `Post`, `RequestStop` and
  `PostsInProgress`.
- `bearings.rt.workers`: `TWorkerPool`, `TWorkItem`, `TWorkerHooks`,
  `EWorkerPoolStopped`, `DEFAULT_SPIN_NS`, `CurrentWorkerIndex` (section
  4). `Submit`, `TrySubmit`, `QueueLength`, `Saturated`, `Alive`,
  `Executed`, `SpinNs`: any thread; `Shutdown`, `Destroy`: the owner, never
  a worker.
- `bearings.rt.net`: `TListenSpec`, `TAcceptMode`, `TSockAddrStorage`,
  `SockAddrToStr(Addr)` (the text of `Ex.PeerAddr^`).
- `bearings.rt.cpu`: `DefaultLoopCount`, `UsableCpus`, `CgroupCpuLimit`,
  `PinCurrentThread`.
- `bearings.http1.role`: `THttpMethod` (`hmNone`, `hmOptions`, `hmGet`,
  `hmPost`, `hmPut`, `hmDelete`, `hmHead`, `hmTrace`, `hmConnect`,
  `hmPatch`, `hmExtension`), `THttpVersion` (`hv09`, `hv10`, `hv11`,
  `hv2`, `hv3`), `TResponseHead` (the record behind `Ex.Resp.Head`).
- `bearings.version`: `BEARINGS_VERSION`, `FPC_VERSION_TEXT`.
