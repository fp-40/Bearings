# 1. Concepts

## Event loops

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

## Worker threads

Code that may block runs on the worker pool (`TWorkerPool`, unit
`bearings.rt.workers`), a fixed set of threads with a FIFO queue. A request
is handed to the pool with `TExchange.Offload` (section 4). A worker may
block: in a request body read, in a stream write to a slow client, in a
database call, in `Sleep`. The pool is created by `TServer.Start` when
`TServerConfig.Workers >= 0` (0 picks `Min(32, DefaultLoopCount + 4)`
threads; -1 means no pool) and is reachable as `TServer.Workers`.

The rule for what may run where:

Code | Runs on | May block?
---- | ------- | ----------
`THttpService.Call` | loop thread | no; must not answer or read the body either
`TServiceCall.Poll`, `TServiceCall.Drop` | loop thread | no
`TBlockingHandler.Run` | worker thread | yes
`TBodySource.PollFrame`, `TBodySource.Done` | loop thread | no
`TUpgradeHandler.Upgraded`, `UpgradeFailed`, `TRawListener` callbacks | loop thread | no
`TConnObserver` hooks | loop thread | no
`TWorkerHooks.ThreadStarted`, `ThreadStopping` | the worker thread | yes
a thread holding a reference from `TExchange.Share` | that thread | yes (its own code); exchange calls follow section 14

## The exchange

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
  `TByteSlice` (`P: PByte; Len: SizeInt`) is how the head hands out bytes;
  `SliceToStr(S)` copies one into a `RawByteString`, `SliceEquals(S, Text)`
  compares one with a string byte for byte, and `PathIs(Ex, Text)` is
  `SliceEquals(Ex.Path, Text)`.
- the request body: `TryRead` on the loop, `Read`, `ReadChunk`, `ReadAll`,
  `ReadFrame` on a worker, `DiscardBody`, `RequestTrailers` (section 6).
- the response: `Status`, `ResponseVersion`, `SetReason`,
  `ResponseHeaders` (section 7), then the terminal call (sections 3 to 5).

## Services and calls

`THttpService` is the application. The server calls the `TServiceFactory`
(a method `function(Loop: TLoop): THttpService of object`; or a
`TServiceProc`, the same as a plain function, with `TServer.CreateWithProc`)
once per loop in `Start`, so there is one service instance per loop. For
every request
the loop calls `THttpService.Call(Ex)` on the loop thread, right after the
request head was parsed. `Call` returns a `TServiceCall` and must not
answer or read the body (builds with assertions check this). It may look at
the head to pick a call object, and may write a log line.

`TServiceCall` is the handling of one request as the connection sees it:

- `Poll(Ex): TCallPoll` runs on the loop thread every time the connection
  runs while the call is in flight. It returns `cpReady` only after a
  terminal call was made on `Ex`; `cpReady` without one is a program
  error: the exchange is failed (`handler returned no response`, the
  connection closes with a user error) and `NoResponseFailures` is
  incremented, and a build with assertions also raises (section 12). It
  returns `cpPending` when the answer is
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
