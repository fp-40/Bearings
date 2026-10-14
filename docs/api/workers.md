# 4. Answering on a worker thread

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

- One `Offload` per request. A second one raises `EExchangeState`.
  `Offload` with the pool shut down raises `EWorkerPoolStopped`; either
  exception aborts the connection task.
- `Run` must make exactly one terminal call. If it returns without one,
  that is a program error: the exchange is failed with the message
  `handler returned no response` (the connection closes with a user error,
  section 9) and `NoResponseFailures` is incremented, in every build; a
  build with assertions (`-Sa`) then also raises `EAssertionFailed` on the
  worker, naming the request, after the exchange was failed and before the
  worker's reference goes back, so the exception ends in the worker pool's
  safety net (one line on stderr). A test that drives this on purpose
  calls `Ex.NoResponseIsExpected` first (section 12). If `Run` raises, the
  exception is caught: the exchange is failed with `handler raised
  <class>: <message>`, or, when a stream was already begun, the stream is
  aborted (`AbortStream`), and nothing reaches the worker pool's safety
  net.
- On a worker the blocking body reads are allowed (section 6), and `Write`
  parks while the stream queue is full (section 5).
- `TOffloadCall.SaturatedStatus` (default 0) decides what happens when the
  pool is saturated (`TWorkerPool.Saturated`: `Config.WorkerQueueLimit`
  queued items). 0: the request is queued anyway. Another value, for
  example 503: a request whose first poll finds the pool saturated is
  answered at once on the loop thread with that status, a `Retry-After: 1`
  header and a short `text/plain` body (`server busy, retry later`); it is
  not shared or offloaded, and the handler does not run for it. A service
  with its own call object checks `Srv.Workers.Saturated` in its `Poll`
  before calling `Offload` to do the same.
- The connection does not reuse a shared exchange for its next request; it
  takes another one from the loop's pool.

## Share, Release, Wake: your own threads

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

## The pool itself

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
