# 2. Threading model

## One event loop per CPU

`TServer.Start` creates `TServerConfig.Loops` loops, or `DefaultLoopCount` (`bearings.rt.cpu`: the CPUs in the process's affinity mask, capped by the cgroup CPU quota, at least 1) when that is 0.

Each `TServerLoop` runs one `TLoop` on its own thread and owns its listening socket or its share of one (section 3), its own instance of the service (`TServiceFactory` is called once per loop), its exchange pool, its block pool, its timer wheel, the list of its open connections and the list of its upgraded connections (`Upgraded`). `PinLoops` binds loop i to the i-th usable CPU; it is off by default (it measured within 1 %).

## A connection lives on the loop that accepted it

`TServerLoop.OnAccept` creates the connection task (`TH1Dispatcher`, `bearings.http1.dispatch`) on the accepting loop, and that task reads, parses, calls the service and writes until the connection closes. Nothing on the inline request path touches another loop's data, so there is no lock and no atomic instruction on it.

Cross-thread traffic exists only for exchanges handed to workers or other threads, and for server-wide commands (stop, graceful shutdown, the metrics snapshot, the watchdog ping, resuming listeners paused by the connection limit), and for messages posted to a WebSocket from another thread (`TWebSocket.PostText`, `PostBinary`, `PostFrame`).

## Loops never block

Every socket is non-blocking. `TLoopTask.Run` does as much work as it can without blocking and returns; the HTTP/1 task runs its read/write/flush loop at most 16 times per `Run` (`TH1Dispatcher.PollLoop`) and then yields, a listener accepts at most `ACCEPT_BATCH` (64) connections per event, and a loop iteration runs at most `RUN_QUEUE_BUDGET` (61) queued tasks before it polls epoll again.

Code that blocks (a database, a file, a blocking body read, `Sleep`) runs on the worker pool.

## One loop iteration (`TLoop.RunIteration`)

1. `epoll_wait`, with timeout 0 when the run queue or the inbox is not empty, else the delay to the next timer (at most 1 s while the block pool holds memory, so that idle blocks are trimmed; without limit otherwise).
2. The clock is sampled once (`NowNs`, `NowMs`; section 4), the tick hook runs if due, and the block pool is trimmed after 1 s without events.
3. The event batch: a listener event accepts; a connection event adds the readiness bits to the task's `TIoSource` and calls `OnIo`, which runs the task at once; the eventfd is read to reset it.
4. The inbox is drained: `lmWakeExchange` wakes the exchange's connection task, `lmFreeExchange` recycles an exchange, `lmCall` runs a procedure.
5. `Timers.Advance(NowMs)` fires the due timers (their procedures wake tasks).
6. Up to 61 tasks from the run queue.
7. The tasks closed in this iteration are freed (`Close` only marks a task and puts it on a deferred-free list, because a later event of the same batch may still name it).

**The run queue** holds the reasons to run a task other than a socket event: `Wake` (loop thread only) appends the task unless it is already queued; a task that wakes itself while running is appended after `Run` returns, so it runs once more in the same iteration if the budget allows (this is how the HTTP/1 task yields after 16 iterations).

A socket event for a queued task only sets readiness bits; the queued run sees them. Socket events call the task directly instead of going through the run queue; the saved hop measured one read and one write per request batch.

## Cross-thread wakes

Cross-thread wakes go through the loop's inbox (`TLoop.Post`): an intrusive lock-free stack (`TMpscStack`, `bearings.rt.sync`) of `TLoopMsg` records that live inside their senders (an exchange holds its `WakeMsg` and `FreeMsg`), so posting allocates nothing.

The eventfd is written only when the push found the stack empty and the loop may be asleep: the loop sets `Sleeping` to 1 before `epoll_wait` and then checks the inbox once more, so a post that races with going to sleep is not lost, and a post to an awake loop costs one compare-and-swap and no system call.

`Post` counts itself in `Posting` from before the push to its last access of the loop, because the message may be handled, and the exchange that sent it recycled, while the posting thread still reads the loop; `TServer.Destroy` waits for that count to reach 0 before it frees a loop.

## Exceptions

FPC enters a `try` block with `fpc_pushexceptaddr` and `fpc_setjmp` (12 to 20 ns), so no per-request routine has one. `TLoop.Run` holds a single `try/except` around the iteration loop.

An exception that escapes a task aborts that task: `LoopErrorProc` logs it (default: one line on stderr), `Abort` releases everything without a completion event, `Close` frees the task after the batch, and the loop resumes the interrupted event batch at `FEventPos` without another `epoll_wait`.

Inbox messages already taken are kept in `FMsgHead`.

Worker threads catch exceptions per job (below), and the listener catches an exception from per-connection setup for that connection only.

A `TWebSocket` catches an exception from a method of its handler, reports it to `LoopErrorProc` and fails that connection with close code 1011.

## The worker pool (`TWorkerPool`)

A fixed set of threads with a FIFO queue under a pthread mutex. `TExchange.Offload` (loop thread) calls `Share` and submits the exchange itself as the work item (`TExchange` derives from `TWorkItem` and carries the queue link), so queueing allocates nothing.

The worker runs `TBlockingHandler.Run(Ex)` inside one `try/except`; an escaping exception becomes a failed answer with the text `handler raised <class>: <message>` (or an aborted stream if one was begun), and a handler that returns without a terminal call is failed with `handler returned no response` (section 6).

The worker's terminal call changes the exchange's state with a compare-and-swap and wakes the connection through the inbox.

An idle worker spins on the queue for `SpinNs` (20 us; at most one worker spins) before it parks on a futex, so a steady stream of items costs no futex wake; the measured cost of an offloaded request is about 2.3 to 2.7 us of CPU over an inline one (`bench/run_offload.sh`). The default pool size is `Min(32, DefaultLoopCount + 4)`; `NO_WORKER_POOL` (-1) starts none.

## Which thread may call what

`THttpService.Call`, `TServiceCall.Poll` and `Drop`, `TBodySource.PollFrame`, the upgrade callbacks and the observer hooks, and the methods of `TWebSocketHandler` run on the loop thread and must not block.

`TBlockingHandler.Run` runs on a worker and may block.

`TWebSocket.PostText`, `PostBinary`, `PostFrame` and `Release` may be called from any thread, `AddRef` from the loop thread or from a thread that already holds a reference.

An unshared exchange may be used only on its loop thread; after `Share` any holder may use it (section 6). `TServer` is created, started, waited for and freed by one owning thread; `Stop` may be called from any thread. The API guide has the full tables, in [section 1](../api/concepts.md) and [section 14](../api/reference.md).

## Synchronization primitives (`bearings.rt.sync`)

- `TMpscStack` (the inbox)
- `TParker` (one waiter: idle workers, a worker waiting for body bytes)
- `TEventCount` (any number of waiters: producers of a stream waiting for room)
- `TSpinLock` (a shared exchange's body channel and stream queue, a WebSocket's list of messages posted from other threads, the access log's buffers; held for a few instructions and never across a system call).

The futex primitives make the system call only when a thread is, or is about to be, asleep. The code relies on x86-64 ordering: locked instructions are full barriers and aligned word loads and stores are atomic; every such access goes through the `Atomic*` wrappers of `bearings.rt.sync`, which on ARM64 add the barriers that reproduce that ordering (section 11).

Builds with `-dWD_DRD` give valgrind's drd race detector the happens-before edges of these primitives through client requests (section 9).

## Other threads

The access log's flusher thread (`bearings.server.accesslog`) and the systemd watchdog thread (`bearings.server`) are the only threads besides the loops, the workers and the owner.

Each loop formats access-log lines into its own double buffer under a spin lock; the flusher swaps the areas and writes outside the lock, so a slow sink costs dropped lines, never a stalled loop. The metrics are per-loop records written only by their loop; a snapshot asks each running loop for a copy on its own thread.

## Server-wide shutdown

`TServer.Stop(GraceMs)` stops the watchdog heartbeat, tells systemd `STOPPING=1`, posts a stop message to every loop and returns.

Each loop accepts what is still in its accept queue (`TListener.DrainAndClose`, until `EAGAIN`), closes the listener (loop 0 also removes a Unix socket file), calls `GracefulShutdown` on every connection and `TUpgraded.Shutdown` on every upgraded connection (a WebSocket sends close 1001), and leaves its `Run` when its last connection and its last upgraded connection closed, or when the grace period passed, aborting what is left (`TH1Dispatcher.Abort`, `TUpgraded.Abort`; a WebSocket's `OnClose` then gets 1006).

`Wait` joins the loop threads and, after a `Stop`, the watchdog thread, stops the access log (its last lines are flushed), and then shuts the worker pool down (queued items still run, up to `WorkerWaitMs`).

`Destroy` aborts any connection still open (upgraded ones included), shuts the worker pool down, processes every loop's inbox until every exchange is back in its pool and no thread is inside `Post`, and only then frees the loops and pools; if a worker or an outside holder is still alive after `WorkerWaitMs`, the loops and pools are leaked on purpose, because another thread may still post to them.
