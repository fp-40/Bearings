# Handoff: WebSocket pub/sub with topics (`bearings.ws.topics`)

Status: design approved by the project owner on 2026-10-12; no code
written. This document is what a fresh session needs to implement it.
Delete it when the feature is merged.

## 1. What to build

A topic registry for WebSocket connections, modelled on uWebSockets'
`subscribe` / `publish`: a message published to a topic is encoded once
and sent to every subscribed connection on every loop, without the
application keeping lists of connections itself. Today that is
application code (`tests/unit/test_ws_echo.pas`, `TRoomHandler` at line
43, `BroadcastProc` at line 276, the test `Broadcast_to_a_room_on_two_loops`
at line 884): one prepared frame, one `TLoop.Post` per loop, `SendFrame`
on each member. The feature moves that into the library and adds
hierarchical topics with wildcards.

### API (new unit `src/ws/bearings.ws.topics.pas`)

```pascal
Topics := TWsTopics.Create;                           { one per server; the application creates and frees it }
Topics.Subscribe(WS, 'chat/room1');                   { loop thread of WS, or a worker handler (posted to the loop) }
Topics.Unsubscribe(WS, 'chat/room1');
Topics.Publish('chat/room1', 'hola');                 { text, UTF-8; any thread }
Topics.PublishBinary('sensors/x/temp', Data);
Topics.PublishFrame('chat/room1', F);                 { a prepared TWsFrame (WsTextFrame / WsBinaryFrame) }
Topics.Publish('chat/room1', 'hola', WS);             { Exclude: everyone but WS (the sender) }
Topics.CloseOnBackpressure := False;                  { True: a subscriber that cannot take a message is aborted }
```

A connection's subscriptions are removed when it ends; `OnClose` has
nothing to do. `TWebSocket.DroppedMessages` (new, loop thread) counts
the published messages a connection did not get because its output queue
was full.

### Semantics (approved)

1. Topics are `/`-separated levels. A subscription may use MQTT wildcards:
   `+` matches one level, `#` matches the rest (`chat/#`, `sensors/+/temp`).
   A publish names a concrete topic (no wildcards).
2. Fan-out per loop, no lock on the hot path: each loop has its own
   subscription table, touched by its thread only. `Publish` builds one
   prepared frame (`WsTextFrame`, `bearings.ws.frame` line 159) and posts
   one `lmCall` message per loop (`TLoop.Post`, `bearings.rt.loop` line
   691; `TLoopMsg` at line 150 is embedded in its sender, so a post
   allocates nothing beyond the publish object). Each loop walks its table
   and calls `SendFrame` (`bearings.ws.conn` line 1133), which shares the
   frame's bytes by reference for frames of 1 KiB or more.
3. Messages published by one thread reach each subscriber in that order.
4. A slow subscriber (`SendFrame` returns `wsFull`): the message is
   dropped for that connection and counted; with `CloseOnBackpressure` the
   connection is aborted instead (`TWebSocket.Abort`, line 583: no close
   frame, since the client is not reading). Never queue without a bound.
5. `Subscribe` / `Unsubscribe` from a thread other than the connection's
   loop (a `TWsWorkerHandler` method) are posted to the loop and take
   effect shortly after; a publish in between may miss the new subscriber.
   Same as uWebSockets.
6. Exclusion of the sender is an explicit parameter, not the default.
7. Nothing is retained: a subscriber gets only what is published after it
   subscribed.

## 2. Design notes

- **Per-loop table.** A trie keyed by level. Each node: a list of
  subscribers with an exact subscription ending there, a `+` child and a
  `#` child among the children. Publishing walks the trie with the topic's
  levels, following the exact child, the `+` child and the `#` child (the
  last collects at once). A connection subscribed to two patterns that
  both match must get the message once: mark the per-connection record
  with the publish's sequence number before sending.
- **Per-connection record** (one per `TWebSocket` that subscribed): the
  registry, its loop table, the list of trie nodes it is in (for
  `Unsubscribe` and for the removal at close), the last publish sequence
  seen. Store it in a new private field of `TWebSocket` (not `User`, line
  358, which belongs to the application). `TWebSocket.Finish` (line 1474)
  must call the registry to remove the record: add a small abstract hook
  class in `bearings.ws.conn` (`TWsConnHook` with `procedure Finished(WS:
  TWebSocket); virtual; abstract`) that `bearings.ws.topics` implements, so
  `bearings.ws.conn` does not use `bearings.ws.topics` (layer rule: nothing
  below uses `src/ws`, and inside `src/ws` keep the uses graph acyclic;
  `tools/compile-each-unit.sh` checks it).
- **Loop discovery.** The registry learns a loop when a connection on it
  subscribes (`WS.Loop`). Keep the per-loop tables in an array that only
  grows, under a `TSpinLock` (`bearings.rt.sync`); `Publish` reads the
  array under the lock (short) and posts to each loop. Loops are few and
  fixed for the server's life.
- **The publish object.** One heap object per publish: the frame, the
  exclusion, a sequence number, an array of `TLoopMsg` (one per loop) and
  a counter of loops still to run it (`AtomicDec`; the last frees the
  object). Posting from a loop thread to itself is fine (`TLoop.Post`
  handles it).
- **Subscribe from another thread.** Post an `lmCall` to `WS.Loop` with a
  small object holding the topic and a reference to the connection
  (`AddRef` before the post, `Release` in the proc; the reference pattern
  of `PostText`, `bearings.ws.conn` lines 1265 to 1295). The connection
  may have finished by then: the proc must check `WS.Closing` and do
  nothing.
- **Memory ordering.** Everything shared between threads goes through
  `bearings.rt.sync` (`TSpinLock`, `AtomicInc/AtomicDec`, `TLoop.Post`);
  never `Interlocked*` directly (README "ARM64").
- **drd.** Builds with `-dWD_DRD` annotate happens-before edges. A
  reference count needs `HappensBefore(@FRefs)` before the decrement and
  `HappensAfter(@FRefs)` when it reaches zero (`TWebSocket.Release`, line
  597, is the model). Cross-thread frees of heap blocks are already
  suppressed in `tools/drd.supp` (entries `fpc-heap-*`); each new
  suppression must say why the access is not a race.

## 3. Where things are

| Need | Where |
|---|---|
| Connection object, sends, references, finish | `src/ws/bearings.ws.conn.pas`; unit header for the threading rules |
| Prepared frames | `src/ws/bearings.ws.frame.pas` (`WsTextFrame`, `WsBinaryFrame`, `TWsFrame = RawByteString`) |
| Loop messages | `src/rt/bearings.rt.loop.pas` (`TLoopMsg`, `TLoop.Post`, `TLoop.Index`) |
| Locks, atomics, drd annotations | `src/rt/bearings.rt.sync.pas` |
| Worker-pool handlers (subscribe from a worker) | `bearings.ws.conn` header, "A handler on the worker pool"; `docs/api.md` section 10 |
| The application-level broadcast to replace | `tests/unit/test_ws_echo.pas` lines 43 to 60 and 276 to 300 |
| Server's loops (for a test that checks fan-out across loops) | `TServer.LoopCount`, `TServer.Loops[I].Loop` (`src/server/bearings.server.pas`) |

## 4. Tests (all in `tests/unit/test_ws_echo.pas`, real sockets; a new suite `TTestWsTopics`)

1. Two loops, three clients subscribed to `chat/room1`, one publish from
   a loop handler: every client gets it once, in order with a second one.
2. Wildcards: `chat/#`, `chat/+`, `sensors/+/temp`; a client subscribed to
   both `chat/#` and `chat/room1` gets each message once.
3. Exclude the sender.
4. Unsubscribe, and removal at close: publish after a client closed must
   not touch it (`WebSocketsLive` back to the start; heaptrc run).
5. Subscribe and publish from a `TWsWorkerHandler` (path `/worker` of the
   test service).
6. A subscriber that does not read: `DroppedMessages` grows; with
   `CloseOnBackpressure` it is aborted and the others keep receiving.
7. Publish from a plain thread (not a loop, not a worker).

Run them also under drd: add the suite to the `test_ws_echo` drd step of
`tests/unit/run_all.sh` (today it runs `--suite=TTestWsWorker`; the
console runner takes one suite per run, so add a second invocation or
move both suites under one class). Then `TARGET=aarch64 tests/unit/run_all.sh`
under qemu (`tools/get-cross-aarch64.sh` builds the toolchain).

## 5. Example and docs

- `examples/ws_chat.pas`: rooms by path or by a first message `join <room>`;
  a message is published to the room; `--worker` not needed.
- `README.md` section "WebSocket": a short paragraph and the API.
- `docs/api.md` section 10 (WebSocket): the API and the rules.
- `docs/design.md` 6.10: the per-loop table, the publish object, the
  backpressure choice; section 11: remove nothing, add a row if a limit
  stays.
- `examples/README.md`: the new program.

## 6. Verification before the commit

`tests/unit/run_all.sh` (x86_64, with drd), `TARGET=aarch64
tests/unit/run_all.sh`, `tools/compile-each-unit.sh` for the layer rule,
`conformance/autobahn/run.sh` unchanged (the echo does not use topics).
