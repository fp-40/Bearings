# 10. Connection upgrades

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
thread except what the caller does with a detached `Fd`.

## WebSocket (units `bearings.ws.handshake`, `bearings.ws.conn`)

The WebSocket protocol (RFC 6455) is built on the hand-off above. In the
call that sees `Ex.WantsUpgrade`:

1. `R := CheckRequest(Ex, Protocols)` checks the opening handshake (GET,
   HTTP/1.1, `Upgrade: websocket`, `Connection: upgrade`, a
   `Sec-WebSocket-Key` of 16 bytes in base64, `Sec-WebSocket-Version: 13`)
   and picks the subprotocol: the first one the client lists that is in
   `Protocols`. `CheckRequest(Ex, Protocols, Origins)` also refuses (403)
   a browser handshake whose `Origin` is not in `Origins`; a server that
   relies on cookies needs it, because a browser sends the cookies with a
   handshake opened by any site's page.
2. If `R.Ok`: `AcceptWebSocket(Ex, R, Handler, Cfg)` answers 101 with the
   handshake headers and arranges for a `TWebSocket` to take the connection
   over with the application's `TWebSocketHandler`. It owns `Handler` from
   then on (freed without callbacks if the upgrade does not happen).
   Otherwise `RespondHandshakeError(Ex, R)` answers 400, 403 for an
   origin that is not allowed, or 426 with `Sec-WebSocket-Version: 13`
   when only the version was wrong.

The handler's methods run on the loop thread: `OnOpen`, `OnText` and
`OnBinary` (a complete message; the bytes are valid during the call only),
`OnPong`, `OnWritable` (after a send returned `wsFull`, the queue went down
to half the mark), `OnError(Code, Msg)` (the connection failed: 1002, 1007,
1009 for client errors, 1011 when a handler method raised, 1006 for a
socket error), and `OnClose(Code, Reason)` once, last (the client's close
code; 1005 when its close frame had none; 1006 when no close frame came).
The `TWebSocket` and, by default, its handler are freed after `OnClose`.

Sending on the loop thread: `SendText`, `SendBinary`, `Ping`, `CloseWith(Code,
Reason)`, and `SendFrame(F)` for a prepared frame.

Broadcast. A message for many connections is encoded once:
`F := WsTextFrame(S)` (or `WsBinaryFrame`, unit `bearings.ws.frame`) gives
the complete frame as a `RawByteString`, and `SendFrame(F)` on each
connection sends it without encoding or copying it again: a frame of 1 KiB
or more that has to wait in a connection's queue is kept there by reference
(the string's reference count), and the last reference frees it. For
connections on several loops, post one message per loop (`TLoop.Post`)
whose handler calls `SendFrame` for that loop's connections, rather than one
`PostFrame` per connection; `tests/unit/test_ws_echo.pas`
(`TRoomHandler`) does this. A prepared frame must not be changed after it
was built. `Abort` closes the socket without the close handshake (for a
client that does not read, whose close frame would wait behind its
backlog); `OnClose` follows with 1006. A send returns `wsOk`, `wsFull` (the output queue holds
`SendHighWater` bytes or more; nothing was queued) or `wsClosed`. While the
queue is at the mark the connection also stops reading. From another
thread: `PostText`, `PostBinary`, `PostFrame`, after taking a reference with `AddRef` on
the loop thread (for example in `OnOpen`); `Release` gives it back.

`TWsConfig` (`DefaultWsConfig`): `MaxMessage` 16 MiB, `IdleTimeoutMs` 60000
(then `CloseWith(1001)`), `PingIntervalMs` 25000 (the client's pongs reset
the idle timer, so only a client that is gone reaches it), `CloseTimeoutMs`
5000, `SendHighWater` 1 MiB, `ReceiveHighWater` 1 MiB (worker handlers,
below). No extension is negotiated (no permessage-deflate).
`examples/ws_echo.pas` is a complete server.

A handler on the worker pool. A handler that blocks (a database, an
outgoing HTTP call) derives from `TWsWorkerHandler` instead and is
accepted with `AcceptWebSocket(Ex, R, Handler, Pool, Cfg)`, `Pool` being
`TServer.Workers` (the server's pool, so `Cfg.Workers` must not be
`NO_WORKER_POOL`) or a pool of the application's own. Its methods are the
same events, run on a worker thread, one at a time per connection and in
order: `OnOpen`, `OnText(WS, Msg)` and `OnBinary(WS, Msg)` (`Msg` is the
handler's own copy, valid after the call), `OnPong`, `OnWritable`,
`OnError` and `OnClose`. An idle connection holds no thread: the loop
queues each message and submits the connection's job to the pool only when
no worker is running it; the job handles what is queued and returns. From
the worker the handler sends with `PostText`, `PostBinary` and
`PostFrame`, and closes with `PostClose(Code, Reason)`; `SendText` and
`CloseWith` are loop-thread calls and must not be used there. A post
returns `wsFull` when `SendHighWater` bytes are already posted and not
yet moved to the output; `OnWritable` then runs on the worker once they
were. Backpressure on the way in: when the connection's queued, unhandled
messages reach `ReceiveHighWater` bytes the loop stops reading that socket
until the worker has drained the queue, so a client cannot fill memory
faster than the handler works. An exception from a handler method fails
the connection with 1011 (reported on stderr); `OnError` and `OnClose`
still run. At a server stop, a connection whose handler is busy sends its
close frame after the handler returned, so an answer in progress still goes
out; no further message is delivered to it. `examples/ws_echo.pas` with
the argument `worker` is the echo on the pool;
`tests/unit/test_ws_echo.pas` (`TTestWsWorker`) covers it, also under drd.

Pub/sub topics (unit `bearings.ws.topics`). For a message that goes to
every connection interested in something (a chat room, a sensor), the
application keeps no list of connections: it creates one `TWsTopics` for
the server, subscribes connections to topics and publishes to a topic.

```pascal
Topics := TWsTopics.Create;                           { one per server; freed after it }
Topics.Subscribe(WS, 'chat/room1');                   { loop thread of WS, or a worker handler }
Topics.Unsubscribe(WS, 'chat/room1');
Topics.Publish('chat/room1', 'hola');                 { text (UTF-8); any thread }
Topics.PublishBinary('sensors/x/temp', Data);
Topics.PublishFrame('chat/room1', F);                 { a prepared WsTextFrame / WsBinaryFrame }
Topics.Publish('chat/room1', 'hola', WS);             { everyone but WS (the sender) }
Topics.CloseOnBackpressure := True;                   { a subscriber that cannot take a message is aborted }
```

The rules:

- Topics are `/`-separated levels. A subscription may use the MQTT
  wildcards: `+` matches one level, `#` matches the rest of the levels,
  including none (`chat/#` matches `chat/room1`, `chat/a/b` and `chat`;
  `sensors/+/temp` matches `sensors/x/temp`). Each wildcard must be a
  whole level and `#` the last one. A publish names a concrete topic, with
  no `+` or `#` in it. `EArgumentException` otherwise (`WsPatternValid`
  and `WsTopicValid` check without raising).
- A publish encodes the message once and posts one message per loop; each
  loop sends the frame to its subscribers with `SendFrame`. Messages
  published by one thread reach each subscriber in that order; between
  publishers on different threads there is no order. A connection
  subscribed to two patterns that both match gets the message once.
- `Subscribe` and `Unsubscribe` on the connection's loop thread (`OnOpen`,
  `OnText`) take effect at once. From a `TWsWorkerHandler` method they are
  posted to the loop and take effect shortly after: a publish in between
  may miss the new subscriber (the same as uWebSockets).
- A connection's subscriptions are removed when it ends; `OnClose` has
  nothing to do. A connection that is `Closing` cannot subscribe.
- A slow subscriber (its output queue is at `SendHighWater`, so
  `SendFrame` would return `wsFull`) does not get the message: it is
  dropped for that connection and counted in `TWebSocket.DroppedMessages`
  (loop thread). With `CloseOnBackpressure` the connection is aborted
  instead (no close frame: the client is not reading). Nothing is queued
  without a bound.
- Excluding the sender is the explicit `Exclude` parameter, never the
  default. The caller must hold the connection (its loop thread or a
  reference); the publish takes a reference and releases it when done.
- Nothing is retained: a subscriber gets what is published after it
  subscribed.
- `Publish` needs the loops alive: not after the server stopped. The
  registry is freed after the server, when every connection has ended.

`examples/ws_chat.pas` is a chat with rooms on it;
`tests/unit/test_ws_echo.pas` (`TTestWsTopics`) covers it, also under drd.
[Design](../design/exchange.md), section 6.10, has the per-loop table and the publish object.

Server shutdown: `TServer.Stop` calls `Shutdown` on every upgraded
connection (each loop keeps them in a list from the hand-off on). A
`TWebSocket` answers with `CloseWith(1001, 'server shutdown')`, and the loop
waits for these connections to end as it does for its HTTP connections.
At the deadline the ones left are aborted: `TRawListener.Aborted` runs
(a `TWebSocket` releases everything and calls `OnClose` with 1006), then
the stream is closed. A `TRawListener` of another protocol overrides
`Shutdown` to end that protocol; the default closes the stream at once.
