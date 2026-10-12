# Handoff: WebSocket support in bearings

Written 2026-10-11 for a later session. The work has not started. Read this
whole file before writing code.

## 1. Goal

Add server-side WebSocket support (RFC 6455) to bearings, the event-loop and
HTTP/1.1 library at `/home/jps/Code/bearings`. bearings provides the
protocol: the handshake check, framing, control frames and the close
handshake, on top of the existing connection-upgrade hand-off.

Out of scope for this work:

- The application-level API of the wd-40 framework (channels, rooms,
  broadcasting). That lives in `/home/jps/Code/wd-40` and comes later.
- A WebSocket client.
- WebSockets over HTTP/2 (RFC 8441): bearings has no HTTP/2 yet.
- TLS (`wss://`): bearings has no TLS yet. Deployments put a proxy in front.

## 2. Context

- bearings was extracted from wd-40 on 2026-10-11 (fresh repository, no
  history). Units are named `bearings.<layer>.<name>`: `src/rt` (event
  loop, sockets, buffers, timers, workers, sync), `src/http1` (parser,
  encoder, connection state machine, dispatcher), `src/http` (the exchange:
  one request and its response), `src/server` (loops, listeners, worker
  pool, shutdown). `src/rt` does not depend on the HTTP units.
- Compiler: FreePascal 3.2.2, `{$mode objfpc}{$H+}`. No anonymous
  functions, no closures, no coroutines: callbacks are virtual methods of a
  handler class, and tasks are objects with an explicit state machine.
- Platform: Linux x86_64 only (epoll, raw syscalls in `bearings.rt.sys`).
- Every unit has a header comment that explains what it does for a reader
  who knows FreePascal but not web servers. Keep that style for new units:
  plain sentences, no mentions of other projects or of project history.
- The design document is `docs/design.md`; the performance measurements
  are in `docs/design/m3-perf-report.md`.
- `bearings.rt.loop` has one generic per-loop hook (`LoopTickProc`, with
  state in `TLoop.Ext`), already used by `bearings.http.date` for the cached
  Date header. Do not take it for WebSocket timers; use the timer wheel.

### What already exists for upgrades

Read these before designing anything:

1. `bearings.http.exchange`: a service sees `Ex.WantsUpgrade` (the request
   asked for an upgrade). To accept, it calls `Ex.OnUpgrade(H)` with a
   `TUpgradeHandler` before answering, and answers `101 Switching
   Protocols`. `H.Upgraded(U)` is called later on the loop thread with the
   connection; `H.UpgradeFailed(Msg)` if the upgrade did not happen.
2. `bearings.http1.dispatch` / `bearings.http1.conn`: after the 101 is
   written, the dispatcher stops speaking HTTP and hands the socket and the
   bytes it had already read past the request ("leftover" bytes) to a
   `TUpgraded`. The connection mode must allow upgrades (`TH1Config.Mode =
   cmWithUpgrades`; the production profile has it).
3. `bearings.rt.stream`: `TUpgraded` is a loop task that owns the socket.
   - `Attach(L: TRawListener)`: stay on the loop; `L.Readable(U)` and
     `L.Writable(U)` run on every socket event and every `Wake`.
     `U.TryRead` returns the leftover bytes first, then reads the socket;
     `TryRead`/`TryWrite` return `-EAGAIN` without a system call when the
     socket is not ready.
   - `Detach(out Fd, out Rest)`: leave the loop; the socket becomes
     blocking and belongs to the caller (for a handler that runs on a
     worker thread).
   - Ownership: the handler owns `U` from the moment `Upgraded(U)` is
     called. If `Upgraded` raises before attaching, detaching or closing
     `U`, the exchange closes it.
4. Example of a working upgraded-connection task:
   `conformance/pascal-server/beconf.upgrade.pas` (`TConfUpgrader`, a
   `TRawListener` with a small read/write state machine and a cross-loop
   signal through `TLoop.Post`). It is test tooling, but it shows the
   patterns to follow.
5. Timers: `bearings.rt.timer` (a wheel owned by each loop). Cross-thread
   wake: `TLoop.Post` with a `TLoopMsg`, or `Wake` on a task.

## 3. Proposed design

Treat this as a proposal; check it against the code and change it where the
code suggests something simpler. Ask the user before changing the scope.

### 3.1 Units (new folder `src/ws`)

- `bearings.ws.handshake`
  - `CheckRequest(Ex): TWsHandshakeResult`: method GET, HTTP/1.1,
    `Upgrade: websocket` (case-insensitive), `Connection` contains the
    token `upgrade`, `Sec-WebSocket-Key` is base64 of exactly 16 bytes,
    `Sec-WebSocket-Version: 13`. On a wrong version the answer is `426
    Upgrade Required` with `Sec-WebSocket-Version: 13`; other failures are
    `400`.
  - `AcceptValue(Key)`: base64(SHA-1(Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
    Test vector from RFC 6455 section 1.3: key
    `dGhlIHNhbXBsZSBub25jZQ==` gives `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
  - Subprotocol choice (`Sec-WebSocket-Protocol`): the application passes
    the list it supports; the first client token in that list wins.
  - `Respond101(Ex, Accept, Protocol, Handler)`: sets the 101 head and calls
    `Ex.OnUpgrade`.
  - SHA-1 and base64: bearings has neither (wd-40's `wd.web.crypto` has
    SHA-256 and base64url only). First check whether FPC 3.2.2's packages
    provide them (`sha1` in the hash package, `base64` in fcl-base) and
    whether using them is acceptable; otherwise write a small SHA-1 and
    standard base64 in `src/ws` or `src/rt`.
- `bearings.ws.frame`
  - An incremental frame parser (bytes may arrive in any split): FIN,
    RSV1-3, opcode, mask bit, 7/16/64-bit length, masking key, payload.
  - Rules: client frames must be masked (unmasked: close with 1002);
    RSV bits must be 0 unless an extension was negotiated; unknown opcodes
    are a protocol error; control frames (close, ping, pong) carry at most
    125 bytes and are never fragmented; a 64-bit length must have its top
    bit clear; text messages must be valid UTF-8, checked incrementally
    across fragments (invalid: close with 1007).
  - A frame encoder for server frames (never masked).
- `bearings.ws.conn`
  - `TWebSocket`: a `TRawListener` attached to the `TUpgraded`. It reads
    into a pooled buffer (`bearings.rt.buf`), runs the parser, reassembles
    fragmented messages up to a size limit (too large: close with 1009),
    answers pings with pongs, and runs the close handshake (send close,
    wait for the client's close or a timeout, then close the socket).
  - `TWebSocketHandler` (virtual methods, no closures): `OnOpen`,
    `OnText`, `OnBinary`, `OnClose(Code, Reason)`, `OnError`.
  - Sending: `SendText`, `SendBinary`, `Ping`, `CloseWith(Code, Reason)`
    on the loop thread. Output goes into a queue that is flushed on
    `Writable`; when the queue passes a high-water mark, sending reports
    "full" (backpressure) instead of growing without limit.
  - Sending from another thread: post the frame to the connection's loop
    (`TLoop.Post`), like the exchange does for worker answers. Decide
    whether the queue is loop-only (simplest) and other threads only post.
  - Timers: idle timeout and optional periodic ping, close-handshake
    timeout, from `bearings.rt.timer`.
- Optional, after the above works: a blocking API for worker threads over
  the fd returned by `Detach` (read a message, write a message), for
  handlers that block.
- Optional, second phase: `permessage-deflate` (RFC 7692), with FPC's zlib
  units. Ask the user whether it is wanted in the first version.

### 3.2 How an application will use it

```pascal
{ in the application's THttpService call, on the loop thread }
if Ex.WantsUpgrade then
begin
  R := CheckRequest(Ex);
  if R.Ok then
    Respond101(Ex, R.Accept, R.Protocol, TMyWsUpgradeHandler.Create)
  else
    RespondHandshakeError(Ex, R);       { 400 or 426 }
end;

{ TMyWsUpgradeHandler.Upgraded(U): create a TWebSocket with the app's
  TWebSocketHandler and attach it to U }
```

The exact names are up to the implementation; keep the API small.

## 4. Tests

- Unit tests (new `tests/unit/test_ws_*.pas`, added to
  `tests/unit/run_all.sh`):
  - handshake: the RFC vector, every refusal case, subprotocol choice;
  - frame parser: every length form, masking, every protocol error with
    its close code, UTF-8 across fragment boundaries, and a split fuzz like
    `tests/unit/test_split_fuzz.pas` (the same frames delivered in random
    pieces must give the same messages);
  - the connection: ping/pong, the close handshake both ways, the size
    limit, backpressure, a client that disconnects mid-frame (no leak:
    heaptrc reports 0 unfreed blocks).
- An echo server example (in `examples/` or `bench/`) used by a real-socket
  test.
- Conformance: the Autobahn TestSuite (`fuzzingclient` mode) is the
  standard WebSocket conformance suite. It needs Docker or Python 2 and a
  download: ask the user before installing anything or using the network.
- Performance: an echo benchmark (messages per second, small and large
  messages). There is no target yet; report the numbers.

## 5. Working rules (from the user)

- Plain, direct sentences in code comments, docs and reports. No metaphors.
  State assumptions; ask when something is unclear.
- Do not push anywhere. Commit after each verified step.
- Never run a program that is meant to crash (segfault, abort): on this
  machine a crash opens a desktop dialog. Prefix test runs with
  `ulimit -c 0`.
- `tests/unit/run_all.sh` needs valgrind: bearings has no `build/tools`
  yet, so either run `tools/get-tools.sh` or set
  `VALGRIND=/home/jps/Code/wd-40/build/tools/bin/valgrind`.
- Pin test runs with `taskset -c 8-15 nice -n 19`. Run each suite once;
  do not run suites while still editing; run only the suites the change
  can affect. No performance gate unless the HTTP hot path changes.
- Implement features, not other projects' exact behaviour: match RFC 6455,
  not a particular library's quirks.
- Do not modify `/home/jps/Code/proper` or any Proper checkout.

## 6. Done when

- An application can accept a WebSocket on bearings with a handler class,
  exchange text and binary messages, and close cleanly, on the loop thread.
- All the tests of section 4 pass; `tests/unit/run_all.sh` and the
  conformance gate (`conformance/pascal-server/gate.sh`, 104/0/1) still
  pass.
- Autobahn results are reported if the user allowed installing it.
- The new units have header comments in the style of the existing ones,
  and `README.md` lists WebSocket support.

## 7. Questions to ask the user at the start

1. Is `permessage-deflate` needed in the first version?
2. Is a blocking API for worker threads needed, or only the loop API?
3. May the session install the Autobahn TestSuite (Docker or Python)?
4. Default limits: maximum message size, idle timeout, ping interval.
