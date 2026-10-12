# Handoff: operations features in bearings

Written 2026-10-11 for a later session. The work has not started. Read this
whole file before writing code.

## 1. Goal

Add four features that matter when bearings runs in production:

1. A listener on a Unix domain socket, so a reverse proxy on the same
   machine (nginx, Caddy) can talk to bearings without TCP.
2. systemd socket activation (`LISTEN_FDS`), so the service can restart
   without refusing connections.
3. Limits on simultaneous connections: in total, and optionally per client
   IP address.
4. An access log and basic metrics: open connections, requests, latency.

Each one is a separate step with its own tests and commit. Suggested order:
1 and 2 first (both change how listening sockets are created), then 3, then
4 (4 reuses the counting that 3 adds).

Out of scope: TLS, HTTP/2, WebSockets (see `docs/handoff-websocket.md`),
and anything in the wd-40 framework (`/home/jps/Code/wd-40`), such as an
HTTP endpoint that serves the metrics. bearings provides the data and the
hooks; the framework decides how to expose them.

## 2. Context

- bearings is the event-loop and HTTP/1.1 library at
  `/home/jps/Code/bearings`, extracted from wd-40 on 2026-10-11. Layers:
  `src/rt` (event loop, sockets, buffers, timers, workers, sync; it does not
  depend on the HTTP units), `src/http1` (parser, encoder, connection state
  machine, dispatcher), `src/http` (the exchange: one request and its
  response), `src/server` (loops, listeners, worker pool, shutdown). Units
  are named `bearings.<layer>.<name>`.
- FreePascal 3.2.2, `{$mode objfpc}{$H+}`, no closures: hooks are virtual
  methods of a class or procedure variables. Linux x86_64 only.
- Every unit has a header comment written for a reader who knows
  FreePascal but not web servers. Keep that style: plain sentences, no
  mentions of other projects or of project history.
- Performance matters. The request path allocates nothing and sets up no
  implicit exception frames in the routines listed in
  `tools/check-hot-asm.sh`. A feature that is turned off must cost at most
  one test of a configuration value per request or per connection.
  Throughput is gated by `bench/run_gate.sh` (at least 0.80 of hyper per
  cell; current results are in `docs/design/m3-perf-report.md`).

### Code to read first

- `src/rt/bearings.rt.net.pas`: `TListenSpec` (Host, Port, Backlog, Mode,
  NoDelay), `OpenListener` (socket, `SO_REUSEADDR`, `SO_REUSEPORT`,
  `TCP_NODELAY`, bind, listen), `MakeSockAddr`, `SockAddrToStr`,
  `TListener` (accepts in batches; `Pause`/`Resume` take the listener out
  of epoll for a while after `EMFILE` and similar errors; counters `Pauses`,
  `SetupErrors`), `TTcpTransport`.
- `src/server/bearings.server.pas`: `TServerConfig` (with `Listen:
  TListenSpec`), the three accept modes (`amReusePort`: one listening
  socket per loop; `amSharedExclusive`: one socket, a dup per loop,
  `EPOLLEXCLUSIVE`; `amSingle`), `TServerLoop.OnAccept` (creates the
  `TH1Dispatcher` for each accepted socket and calls the observer),
  `Stop`/`Wait`/`RunUntilSignal` (graceful shutdown).
- `src/http/bearings.http.exchange.pas`: `TConnObserver` (`OnAccept`,
  `WrapTransport`, `OnStart`, `OnConnClose` with the outcome, `OnParts`).
  The conformance server (`conformance/pascal-server/beconf.*.pas`) uses
  it; it is the existing per-connection hook.
- `src/http1/bearings.http1.dispatch.pas`: one connection task; `Finish`
  reports the outcome. Where a request starts (`PollReadHead`) and where its
  response is fully written are the points an access log needs.
- `src/rt/bearings.rt.clock.pas`: the cached clock of each loop iteration
  (`Loop.NowMs` and the nanosecond clock), for request durations without a
  system call.

## 3. The four features

These are proposals; check them against the code and ask the user where
noted.

### 3.1 Unix domain socket listener

- Extend `TListenSpec` with a path (for example a `UnixPath` field, or a
  Host of the form `unix:/run/app.sock`; pick one and document it), plus
  the file mode of the socket file (so the proxy's user can connect).
- `OpenListener`: `socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK |
  SOCK_CLOEXEC)`, remove a stale socket file before bind (only if it is a
  socket), bind, `chmod`, listen. `SO_REUSEPORT` and `TCP_NODELAY` do not
  apply: with several loops use one listening socket shared through
  `amSharedExclusive`. Remove the socket file on `Stop`.
- Accepted connections have no IP address. Check every user of the peer
  address (`TH1Dispatcher.Peer`, `SockAddrToStr`, `TExchange.PeerAddr`) and
  define what a Unix peer looks like (for example an empty address and
  family `AF_UNIX`). Note for the wd-40 side (not this work): behind a
  proxy on a Unix socket, the client IP comes from forwarding headers, and
  wd-40's `TRUSTED_PROXIES` needs a way to trust the Unix socket.
- `sendfile`, `writev` and the readiness rules work the same on Unix stream
  sockets; confirm with tests.
- Tests: serve requests over a Unix socket (`TTcpTransport` should work
  unchanged); stale socket file; file mode; several loops sharing it; Stop
  removes the file. Manual check: `curl --unix-socket /path http://x/`.

### 3.2 systemd socket activation

- systemd opens the listening sockets itself and starts the service with
  them already open: file descriptors 3, 4, ... and the environment
  variables `LISTEN_PID` (must equal the process id, otherwise ignore),
  `LISTEN_FDS` (how many) and optionally `LISTEN_FDNAMES`. During a restart
  systemd keeps the sockets open, so connections wait in the kernel queue
  instead of being refused.
- Add a listen source "inherited descriptor": `TServer` uses the received
  socket instead of creating one. Set it non-blocking and close-on-exec;
  read its family and address with `getsockname`; then unset the
  variables so child processes do not see them.
- With several loops, one inherited socket is shared like
  `amSharedExclusive` (a dup per loop). Several inherited sockets (for
  example TCP and Unix): decide whether each loop listens on all of them.
- sd_notify (decided by the user, 2026-10-11): when `NOTIFY_SOCKET` is
  set (a service with `Type=notify`), send short datagrams to that Unix
  socket (an abstract address when the path starts with `@`), with no
  libsystemd dependency:
  - `READY=1` once `Start` has opened every listener and started the loops;
  - `STOPPING=1` when `Stop` begins;
  - optional `STATUS=...` (for example the open connection count);
  - the watchdog, as an option: when `WATCHDOG_USEC` is set (and
    `WATCHDOG_PID`, if present, equals the process id), send `WATCHDOG=1`
    about every half of that interval, but only while every loop is making
    progress (each loop records the time of its last iteration; a loop
    that has not iterated within the interval stops the heartbeat, so
    systemd restarts the service). The heartbeat must not run on a loop
    thread it is checking. A loop that is merely idle in `epoll_wait` must
    still count as alive: wake it with its timer or check it differently.
  Tests: a test creates a Unix datagram socket, sets `NOTIFY_SOCKET` for a
  child process (or for the server in-process), and checks the messages;
  a loop blocked on purpose (in a test hook, not a crash) stops the
  watchdog messages.
- Tests without systemd: a test starts a child process with a listening
  socket on fd 3 and the variables set, and connects to it (fork/exec with
  the fd kept open, or a small helper program). Manual check with
  `systemd-socket-activate -l 8080 ./program`. Document a sample `.socket`
  and `.service` unit in the README.

### 3.3 Connection limits

- Total limit: `TServerConfig.MaxConnections` (0 = no limit). Count in
  `TServerLoop.OnAccept` and decrement when the connection task ends
  (`Finish`, or wherever the dispatcher is freed; an upgraded connection
  also counts until it closes). The count is shared by all loops: an
  atomic counter.
- What happens at the limit (ask the user): either stop accepting (take
  the listeners out of epoll like `TListener.Pause`, and put them back when
  a connection closes; new clients wait in the kernel's accept queue), or
  accept and close at once. Stopping accept is the usual choice; it keeps
  the waiting clients instead of failing them.
- Per-IP limit (optional): `MaxConnectionsPerIp`. With `SO_REUSEPORT` the
  kernel spreads one client's connections over several loops, so the count
  must be shared: a small hash table of address -> count under a lock, or
  sharded by address hash. A connection over the limit is closed right
  after accept. Behind a reverse proxy all connections come from the proxy,
  so this limit only makes sense when bearings faces clients directly;
  document that.
- Tests: N+1 connections with a limit of N (the last waits, or is closed,
  per the chosen rule; it proceeds when one closes); the per-IP case from
  127.0.0.1 and 127.0.0.2; counts return to 0 after Stop; no leak.

### 3.4 Access log and metrics

- Access log: one line per completed request with the time, the client
  address, the method, the request target, the status, the response body
  bytes, the duration, and optionally the user agent. Ask the user for the
  format (the Common/Combined log format of web servers, or JSON lines).
  - Get the data where it exists: the request head is in the exchange; the
    status and the number of bytes written are known to the connection
    state machine; the start time is when the head was read.
  - The loop must never block on the log: write lines into a per-loop
    buffer and flush it from a background thread (or with non-blocking
    writes), and drop and count lines if the buffer is full. A sink class
    with a virtual `Write` lets an application send lines elsewhere.
  - Off by default; when off, the request path does one test and nothing
    else.
- Metrics: per-loop counters written only by their loop (no atomic
  operations on the hot path); a reader adds the loops together.
  - Gauges: open connections (from 3.3), requests in flight, worker queue
    length, buffer pool use.
  - Counters: connections accepted and closed by outcome (the
    `TConnOutcome` values), requests, responses by status class
    (1xx-5xx), bytes in and out, listener pauses, parse errors.
  - Latency: a histogram with fixed buckets (powers of two in
    microseconds is enough), per loop, merged when read.
  - API: `TServer.Metrics(out Snapshot)` returning a record.
  - Prometheus text format (decided by the user, 2026-10-11): add a pure
    function in bearings that turns a snapshot into the Prometheus text
    exposition format (`# HELP` / `# TYPE` lines, metric names with a
    `bearings_` prefix, labels such as `{outcome="..."}` or
    `{status="2xx"}`, the latency histogram as cumulative `_bucket{le="..."}`
    lines plus `_sum` and `_count`). It does no I/O; serving it at an HTTP
    path such as `/metrics` is the framework's job (wd-40). Keep the label
    sets fixed and small.
- Tests: counts after a known sequence of requests (including errors and
  client disconnects); the histogram; access-log lines for normal, error
  and HEAD requests; the log does not block when the sink is slow; the
  Prometheus text for a known snapshot (exact output, including the
  cumulative histogram buckets).

## 4. Verification

- New tests in `tests/unit` (real sockets as in `tests/unit/test_server.pas`)
  and added to `tests/unit/run_all.sh`.
- Run `tests/unit/run_all.sh` and `conformance/pascal-server/gate.sh`
  (expect 104/0/1) once at the end of each step.
- Steps 3.3 and 3.4 touch the accept and request paths: run
  `tools/check-hot-asm.sh` (part of `run_all.sh`) and `bench/run_gate.sh`
  once at the end of each of those steps, with the feature off and on.
  Report both. The gate needs an idle machine.
- `tests/unit/run_all.sh` needs valgrind: bearings has no `build/tools`
  yet, so run `tools/get-tools.sh` or set
  `VALGRIND=/home/jps/Code/wd-40/build/tools/bin/valgrind`.
- The wd-40 framework builds against bearings (`BEARINGS` defaults to
  `../bearings`). After changing a public type, run wd-40's
  `tests/web/run_all.sh` once to confirm it still compiles and passes.

## 5. Working rules (from the user)

- Plain, direct sentences in code comments, docs and reports. No
  metaphors. State assumptions; ask when something is unclear.
- Do not push anywhere. Commit after each verified step.
- Never run a program that is meant to crash (segfault, abort): on this
  machine a crash opens a desktop dialog. Prefix test runs with
  `ulimit -c 0`.
- Pin test runs with `taskset -c 8-15 nice -n 19` (the performance gate
  pins itself). Run each suite once, at the end of a step, not while still
  editing; run only the suites the change can affect.
- Compile flags keep the `WD_` prefix (`WD_DEBUG`, `WD_STALL`, `WD_DRD`);
  the user decided this on 2026-10-11.
- Implement the features, not other servers' exact behaviour.
- Do not modify `/home/jps/Code/proper` or any Proper checkout.

## 6. Questions to ask the user at the start

1. Unix socket: the configuration form (a path field or `unix:` in Host),
   and the default file mode.
2. Connection limit: stop accepting or accept-and-close at the limit? Is
   the per-IP limit wanted?
3. Access log format (Common/Combined or JSON lines) and the default
   destination (stderr or a file).
