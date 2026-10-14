# 6. The exchange and the service API

`TExchange` (`bearings.http.exchange`) is one request and its response. It
has three parts with separate rules: the request head (`TRequestHead`,
written by the dispatcher before `Call`, read-only afterwards, valid until the
request is released), the request body channel (`TBodyChan`), and the
response (`TResponseSlot`, written by the handler until the terminal call,
read by the dispatcher after it). Exchanges are pooled per loop
(`TExchangePool`); an HTTP/1 connection reuses its exchange for the next
request while nobody else holds a reference, so the inline path allocates
nothing. The [API guide](../api/index.md) says how each call is used; this section says why
they are shaped this way.

## 6.1 One terminal call

A call answers with exactly one of `Respond` (a body of known length),
`RespondStream` (a `TBodySource`), `BeginStream` (`RespondStream` with the
exchange's own `TChannelBody`) or `Fail` (no response; the connection closes
with a user error); `RespondText` is a shorthand for `Respond`. The state
(`TExchangeState`: `xsIdle`, `xsCalled`, `xsAnswered`, `xsCanceled`,
`xsDone`) moves with plain stores on an unshared
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

## 6.2 The request body channel

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

## 6.3 Response bodies

`TBodyData` (`bearings.rt.buf`) is one piece of response body with its
release rule, a plain record without managed fields: `BodyEmpty`,
`BodyStatic` (memory that outlives the write), `BodyString` (one reference
to the string held until the bytes were written, taken with a typecast
assignment so the caller needs no managed local), `BodyHeap` (`FreeMem`
after the write), `BodyFile` (a file range for `sendfile`; with `CloseAfter` the
descriptor is closed after the last byte or when the connection drops its
queue), and
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

## 6.4 Shared exchanges and the two counts

An exchange starts unshared: it belongs to its loop thread and every method
runs there without locks (builds with assertions check it). `Share` (loop
thread only: from `Poll`, or from a holder running on the loop thread;
`EExchangeState` when no call is in flight) switches it to shared mode and
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

## 6.5 Cancellation

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

## 6.6 Offloading

`TOffloadCall` is the ready-made call that offloads every request: its first
poll calls `Offload(Pool, Handler)` and returns pending; later polls return
ready once `Answered`. `Offload` runs once per request (a second call raises
`EExchangeState`: the exchange is the queue node and a second submission
would link it to itself), calls `Share` and `TrySubmit`; a pool that is shut
down takes the reference back and raises `EWorkerPoolStopped`, which aborts
the connection task. `SaturatedStatus` answers at once on the loop (for
example 503 with `Retry-After: 1`) when the pool's queue limit is reached,
without sharing. The worker's job (`TExchange.Execute`) runs the handler
inside `try/finally` so that its reference always goes back; an exception
from the handler becomes `Fail('handler raised <class>: <message>')`, or
`AbortStream` when the answer was a stream (section 2).

## 6.7 Upgrades from the application's side

`OnUpgrade(H)` registers a `TUpgradeHandler` on the loop thread before the
101 answer. After the HTTP part ended and the close was reported,
`H.Upgraded(U)` runs on the loop thread with a `TUpgraded`: `Attach(L)` keeps
it on the loop with a `TRawListener` whose `Readable`/`Writable` callbacks
follow the readiness rules (a callback with nothing to do costs no system
call; `TryRead` returns the leftover bytes first), or `Detach` leaves the
loop (the socket is unregistered and made blocking, the leftover bytes are
copied, and the caller owns the descriptor). The handler owns `U` from
`Upgraded` on; if `Upgraded` raises before taking it, the exchange closes `U`
and the exception goes on to the loop. When no upgrade happens,
`H.UpgradeFailed(Msg)` runs on the loop thread instead: `no upgrade
available` at once when the request has no upgrade slot, `upgrade expected
but low level API in use` in a mode that does not hand upgrades over (5.8),
`upgrade expected but not completed` when the connection ended first. The
listener's `Shutdown(U)` is called by a graceful stop (default: `U.Close`)
and `Aborted(U)` by `U.Abort` at the stop deadline, before the socket is
closed (5.9). An upgraded connection keeps its connection-limit slot until
the stream is closed or detached (`CloseProc`).

## 6.8 Observer and parts

`TConnObserver` (`OnAccept`, `WrapTransport`, `OnStart`, `OnConnClose`,
`OnParts`) and `TConnParts` are hooks for tests and the conformance server;
nil in production costs nothing. They are declared in
`bearings.http.exchange`, and `TConnOutcome` in `bearings.http.error`, because
the dispatcher uses them and `bearings.server` uses the dispatcher: declaring
them in `bearings.server` would make the unit references circular.
`bearings.server` re-exports the names.

## 6.9 HTTP/2 fit

The service, call, exchange, body and worker types are protocol-neutral in
content, but some are declared in an HTTP/1 unit: `THttpMethod`,
`THttpVersion` (which has `hv2`) and `TResponseHead` live in
`bearings.http1.role`, and `FillHead` takes the parser's `TParsedRequestHead`.
An HTTP/2 session would move them to a neutral unit or fill the same records.
It would take one exchange per stream from the loop pool
(per-connection reuse is an HTTP/1 optimization only), fill the head from
decoded header frames, feed the single-slot channel from data frames and
return flow-control credit when the handler takes a chunk, and poll a
`TBodySource` for data frames. Nothing of that exists yet.

## 6.10 WebSocket

Four units in `src/ws`, on top of the upgrade hand-off (6.7); nothing in
`src/rt`, `src/http1` or `src/server` refers to them, and inside `src/ws`
`bearings.ws.conn` does not use `bearings.ws.topics` (the hook below).

**The handshake** (`bearings.ws.handshake`). `CheckRequest(Ex, Protocols)`
runs in the service call on the loop thread and checks RFC 6455 section 4.2:
GET, HTTP/1.1, an upgrade slot, `websocket` among the `Upgrade` tokens,
`upgrade` among the `Connection` tokens, one `Sec-WebSocket-Key` that is the
base64 form of 16 bytes, and `Sec-WebSocket-Version: 13`; it picks the first
client subprotocol that is in the application's list. The overload with an
`Origins` list also refuses a browser request from another site (an `Origin`
not in the list, or more than one), because the browser sends the site's
cookies with any handshake (cross-site WebSocket hijacking); a request
without `Origin` passes. `RespondHandshakeError` answers 426 with
`Sec-WebSocket-Version: 13` for a wrong version, 403 for a refused origin and
400 otherwise. `Sec-WebSocket-Extensions` is ignored. SHA-1 comes from FPC's
`sha1` unit; base64 is local, because the key check must refuse any other
alphabet.

**Accepting.** `bearings.ws.conn.AcceptWebSocket(Ex, R, Handler, Cfg)`
answers 101 (`Respond101`) and registers a `TWsUpgradeHandler`, whose
`Upgraded` creates a `TWebSocket` and attaches it as the `TUpgraded`'s
listener; it owns `Handler` in every case and frees it, without calling it,
when the upgrade fails. An application with its own `TUpgradeHandler` does
the same with `Respond101` and `TWebSocket`.

**Frames** (`bearings.ws.frame`). `TWsReader` takes the bytes in pieces of
any size and reports one event at a time: a piece of a data message
(unmasked in place in the caller's buffer, text checked as UTF-8 across
frame boundaries by `TUtf8Check`), a complete control frame, or an error
with the close code to send (1002 protocol error, 1007 invalid UTF-8, 1009
too large). The encoder writes server frame headers (never masked).
`WsTextFrame` and `WsBinaryFrame` build a prepared frame (`TWsFrame`, header
and payload in one string) that can be sent to many connections.

**The connection** (`TWebSocket`, a `TRawListener`). It reads into a pooled
64 KiB block, at most 8 blocks per run before it yields. A message that
arrives whole in one read goes to `OnText`/`OnBinary` straight from the read
block; a fragmented message, or one split across reads, is joined in a
reassembly buffer, bounded by `MaxMessage` (1009 above it). A send is
written at once when nothing is queued (header and payload in one `writev`),
else queued; the queue holds copied bytes and prepared frames by reference
(frames of `WS_SHARE_MIN`, 1 KiB, or more; smaller ones are copied), at most
`WS_MAX_IOV` segments per `writev`. Backpressure: a data send is refused with
`wsFull` while `SendHighWater` or more bytes are queued (`OnWritable` follows
when the queue went down to half), and the connection stops reading while
the queue is over the mark, so a client that sends faster than it reads is
slowed down by TCP. Control frames are always queued. Pings go out every
`PingIntervalMs` and any received byte resets the idle timer, so with the
defaults (ping 25 s, idle 60 s) only a client that is gone hits the idle
timeout (`CloseWith(1001)`). The close handshake: a client's close is echoed;
`CloseWith` sends the close frame and reads, dropping data messages, until
the client's close or `CloseTimeoutMs`; a protocol error sends its close
code and ends without waiting. Ending the connection shuts the write side
down and reads until the client closes or `CloseTimeoutMs` passes, because
closing a socket with unread bytes makes the kernel send a reset that can
lose the close frame. `Abort` closes without the handshake; `OnClose` gets
1006.

**Threads.** Everything runs on the loop thread of the `TUpgraded` except
`PostText`, `PostBinary`, `PostFrame`, `AddRef` and `Release`. A post copies
the message (or takes a reference on a prepared frame) into a list under a
spin lock, bounded by `SendHighWater` too, and posts an `lmCall` message
that moves it into the output queue. A thread that uses a `TWebSocket` holds
a reference (`AddRef` on the loop thread, for example in `OnOpen`); the loop
holds one until the connection ends, and the last `Release` frees the
object. A broadcast from another thread is cheaper as one `TLoop.Post` per
loop whose procedure calls `SendFrame` for that loop's connections than as
one `PostFrame` per connection.

**A handler on the worker pool** (`TWsWorkerHandler`, `AcceptWebSocket`
with a `TWorkerPool`). The same events run on a worker thread for a
handler that blocks, without holding a thread per connection: the loop
copies each message into the connection's event queue (under the same spin
lock as the posted sends) and, when no job is queued or running for the
connection (`FJobActive`), takes a reference and submits the connection's
`TWsJob` (a `TWorkItem` created with the connection, so a submit allocates
nothing). The job takes the whole queue, calls the handler for each event
in order, repeats while events arrived meanwhile, clears `FJobActive` under
the lock and releases its reference. One job at a time per connection
gives in-order delivery and a handler never entered by two threads, and the
cost of the pool is proportional to the messages in flight, not to the
connections open. `OnOpen`, `OnPong`, `OnWritable`, `OnError` and `OnClose`
are events of the same queue; the close event is the last one queued
(`FInClosed`), and the handler object is freed with the connection, after
the job's reference went. Backpressure: the loop stops reading a socket
while the queue holds `ReceiveHighWater` bytes or more of unhandled
messages (`ReadBlocked`, the same pause as for an unread output, with
`FInPaused` remembered under the lock); the worker clears `FInPaused` when
it took the queue and asks the loop for a run through the posted-sends
message (`PostWake`, one message in flight at a time, a reference per
message). An exception from the handler is written to stderr and recorded
under the lock; the loop fails the connection with 1011 on its next run
(`FWorkerErr`). Server stop: `Shutdown` with a job active sets
`FStopPending` instead of sending the close frame; no further message is
delivered; the job wakes the loop when done and the loop then sends the
close frame (1001). A pool that refuses the job (shut down) aborts the
connection and no further event runs; `TServer` shuts its pool down only
after every loop ended (section 2), so inside the server this does not
happen. A blocking receive (a worker that waits for the next message) is
deliberately not offered: it would hold a pool thread for the life of a
connection, and the pool is small by design. Autobahn against the echo on
the pool (`WS_ECHO_MODE=worker conformance/autobahn/run.sh`): no case
fails; seven are NON-STRICT (3.2, 3.3, 4.1.3, 4.1.4, 4.2.3, 4.2.4, 5.15)
where the loop handler is OK: a valid message followed by a protocol error
in the same read is still echoed by the worker before the close frame goes,
because the echo is posted from another thread; the strict expectation is
that nothing follows the error.

**Pub/sub topics** (`bearings.ws.topics`, `TWsTopics`). A registry in
which connections subscribe to topics (`/`-separated levels, MQTT `+` and
`#` wildcards in a subscription) and any thread publishes a message to a
concrete topic, once encoded, to every subscriber on every loop. Modelled
on uWebSockets. The choices:

- *A table per loop, touched by its thread only.* Each loop has a trie
  keyed by level: a node holds the subscribers whose pattern ends there,
  its named children in a small hash table, and the `+` and `#` children.
  A publish walks the trie with the topic's levels, following the exact
  child, the `+` child and the `#` child (whose subscribers match at once,
  the rest of the levels or none). No lock on the fan-out path; the only
  lock is a spin lock on the array of tables, which grows when a
  connection on a new loop subscribes and which `Publish` copies.
- *The publish object.* One heap object per publish: the prepared frame,
  the topic's levels, the excluded connection (a reference is taken), a
  count of loops still to run it, and one embedded `TLoopMsg` per loop, so
  the posts allocate nothing (`TLoop.Post`). Each loop runs its message
  (`lmCall`), walks its table and calls `SendFrame`, which shares the
  frame's bytes by reference for frames of 1 KiB or more; the last loop
  frees the object (`AtomicDec` with the happens-before edge for drd, as
  `TWebSocket.Release`). A publish from a loop thread posts to its own
  loop too, so every publish goes through the inbox and messages published
  by one thread reach each subscriber in that order. A sequence number per
  loop marks the per-connection record during the walk, so a connection
  matched by two patterns is sent to once.
- *The per-connection record* (the loop table, the trie nodes the
  connection is in with the pattern of each, the sequence mark) lives in
  `TWebSocket.HookData`, not in `User`, which belongs to the application.
  `TWebSocket.Finish` calls `TWebSocket.Hook` (a `TWsConnHook`, the
  abstract class in `bearings.ws.conn` that `TWsTopics` implements) first,
  so the subscriptions go before `OnClose` and `bearings.ws.conn` does not
  use `bearings.ws.topics`. Nodes left empty are pruned on unsubscribe and
  at the end of a connection; an unsubscribe that a handler makes inside a
  publish (`OnError` after a write error in `SendFrame`) is deferred until
  the walk is done.
- *Subscribe from another thread* (a `TWsWorkerHandler` method): an
  `lmCall` posted to the connection's loop with a reference taken, as
  `PostText`; the loop does nothing if the connection is `Closing` by
  then. So a publish in between may miss the new subscriber, as in
  uWebSockets.
- *Backpressure: drop, never queue without a bound.* A subscriber whose
  queue is at `SendHighWater` does not get the message; it is counted in
  `DroppedMessages`. The alternative, a per-subscriber backlog, is what
  the application-level broadcast had to do by hand and what makes a slow
  client hold memory for everyone's messages. `CloseOnBackpressure` aborts
  the connection instead (no close frame: the client is not reading), as
  uWebSockets' `closeOnBackpressureLimit`.
- *Nothing retained*, no retained messages or queued history: a subscriber
  gets what is published after it subscribed.

`tests/unit/test_ws_echo.pas` (`TTestWsTopics`, real sockets) covers the
fan-out on two loops in order, the wildcards, the exclusion, unsubscribe
and the removal at close, subscribe and publish from a worker handler,
a subscriber that does not read (drops; aborted with
`CloseOnBackpressure`) and a publish from a plain thread, also under drd
and heaptrc. `examples/ws_chat.pas` is a chat with rooms on it.
