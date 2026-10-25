# 2. Configuring and running a server

```pascal
Cfg := ProductionServerConfig;
Cfg.Listen.Port := 8080;
Srv := TServer.Create(Cfg, @App.NewService);   { Observer = nil }
Sig := Srv.RunUntilSignal(@App.Started);       { or Start ... Stop(GraceMs); Wait }
Srv.Free;
```

`NewService` and `Started` are methods of some object here
(`TServiceFactory`, `TServerEvent`). With plain routines instead, use
`TServer.CreateWithProc(Cfg, @NewService)` and
`Srv.RunUntilSignalProc(@Started)` (`TServiceProc`, `TServerProc`), as
`examples/hello.pas` does; the compiler cannot tell the two pointer kinds
apart in an overload, hence the separate names.

## TServerConfig (unit `bearings.server`)

Field | Meaning
----- | -------
`Listen: TListenSpec` | where and how to listen (below)
`Loops: Integer` | number of event loops; 0 = `DefaultLoopCount`
`PinLoops: Boolean` | pin loop i to the i-th usable CPU (`sched_setaffinity`)
`H1: TH1Config` | the HTTP/1.1 connection options (below)
`Workers: Integer` | worker threads; -1 (`NO_WORKER_POOL`) = no pool; 0 = `Min(32, cpus + 4)`
`WorkerQueueLimit: Integer` | `TWorkerPool.Saturated` is True at this many queued items; 0 = no limit (section 4: `TOffloadCall.SaturatedStatus`)
`WorkerHooks: TWorkerHooks` | per-worker-thread start and stop callbacks; nil = none; not owned
`WorkerWaitMs: Integer` | how long `Wait` and `Destroy` wait for queued and running work items; 0 = 30 000
`GraceMs: Integer` | the grace period `RunUntilSignal` passes to `Stop`
`AlsoListen: array of TListenSpec` | more places to listen on; every loop serves all of them (below)
`MaxConnections: Integer` | connections open at once over all loops; 0 = no limit (below)
`AccessLog: TAccessLogConfig` | one line per completed request, off by default (below)
`Metrics: Boolean` | keep the counters `TServer.Metrics` reports (below)
`Watchdog: Boolean` | send the systemd watchdog heartbeat while every loop makes progress (below; the production preset sets it)

`TListenSpec` (unit `bearings.rt.net`): `Host` (`'0.0.0.0'`,
`'127.0.0.1'`, `'::'`), `Port` (0 = a free port, read it back from
`TServer.Port`), `Backlog` (the accept queue length), `NoDelay`
(TCP_NODELAY on every accepted socket), the Unix socket fields below, and
`Mode: TAcceptMode`:

- `amReusePort`: one listening socket per loop, all bound to the same port
  with SO_REUSEPORT; the kernel spreads new connections over the loops.
  With port 0 the first loop binds a free port and the others bind that
  port.
- `amSingle`: one listening socket on loop 0; loop 0 serves every
  connection.
- `amSharedExclusive`: one listening socket, registered by every loop with
  EPOLLEXCLUSIVE, so the kernel wakes one loop per new connection.

A Unix domain socket instead of a TCP port, for a reverse proxy on the same
machine: set `UnixPath` (the socket file; `Host`, `Port` and `NoDelay` are
then ignored and `TServer.Port` is 0). `UnixMode` is the file's permission
bits (0 = `&660`: the owner and the group can connect); `UnixGroup`, when
set, is the group name the file is given (`chown`), for example the
proxy's group. `Start` removes a stale socket file at the path (a regular
file there makes it fail), creates the socket and applies the mode and
group; the file is removed when the server stops. `amReusePort` is mapped
to `amSharedExclusive` (one path, one socket shared by the loops). A
connection accepted on it has a peer record with `Family = AF_UNIX` and no
address (`SockAddrToStr` gives `''`); the client's address is then in the
forwarding headers the proxy adds. A `unix:/path` string form is not part
of bearings; an application that accepts one fills `UnixPath` itself.

`AlsoListen: array of TListenSpec` lists more places to listen on; every
loop serves `Listen` and each entry (for example a TCP port and a Unix
socket). `TServer.Port` is the port of `Listen`.

`InheritedFd` names a listening socket that is already open (a value
greater than 0; `Host`, `Port` and `UnixPath` are then ignored). `Start`
sets it non-blocking and close-on-exec, reads its address with
`getsockname` (so `TServer.Port` is its port) and sets `TCP_NODELAY` when
`NoDelay` is set; a descriptor that is not a listening socket fails
`Start`. The loops share the socket (`amReusePort` is mapped to
`amSharedExclusive`). An inherited Unix socket's file is not removed at
stop: it belongs to whoever created it.

## Connection limit

`MaxConnections` caps the connections open at once, over all loops, with
one shared atomic count. A listener takes a slot before each `accept4`;
at the limit it leaves epoll instead of accepting, so new clients wait in
the kernel's accept queue (bounded by `Backlog`) and are not refused. The
slot goes back when the connection task has released everything; a
connection handed to an upgrade handler keeps its slot until the
`TUpgraded` stream is closed or detached. The closing loop resumes its own
listeners and posts a message to the other loops to resume theirs (a one
second timer is the fallback). `TServer.CountedConnections` is the count,
`TServer.OpenConnections` the HTTP connections in the loops' lists.
`TListener.LimitPauses` and `LimitPaused` (per loop) show the listener's
side. There is no per-IP limit: that policy belongs to the reverse proxy or
the firewall (behind a proxy every connection has the proxy's address); an
application facing clients directly can close a connection in
`TConnObserver.OnAccept`, which receives the peer address. With the limit
off, the accept path tests one integer and the connection task one
pointer.

## Access log and metrics (units `bearings.server.accesslog`, `bearings.server.metrics`)

Both are off by default. When off, a request costs one pointer test; when
on, the loop does the work itself with no allocation and no atomic
operation.

`AccessLog: TAccessLogConfig` writes one line per completed request (the
response's last bytes handed to the write buffer; automatic error
responses to unparsable requests are not logged):

Field | Meaning
----- | -------
`Enabled` | turn the log on
`Format` | `alfJson` (default): one JSON object per line with the keys of structlog's lines, so a log collector reads the server's lines and a Python app's the same way: `timestamp` (RFC 3339 UTC, microseconds), `level` (`"error"` for a 4xx or a 5xx, `"info"` for the others), `logger` (`"bearings"`), `event` (the method and the path, `"GET /x"`), `request_id` (when the response has an `X-Request-ID` header, as an application sets it to find the request in its own logs), `method`, `path`, `query` (when present), `status`, `size` (the body bytes), `duration` (seconds, by the loop's clock, which is sampled once per iteration: a request answered in the iteration that read it shows 0), `client` (`"unix"` on a Unix socket), `user_agent` (when present and `UserAgent` is set), `referer` (when present and `Referer` is set); `alfConsole`: one short line for people, `23:59:59.123456Z [info]  200 GET /x?a=1  (0.412ms; 16.03 KB)`: the time of day (UTC), `[level]` padded to the width of `[error]` so that the statuses line up, the status, the method, the request target, the duration in milliseconds and the body size in the largest unit it reaches (`164 bytes`, `1.60 KB`, `15.65 MB`, `1.53 GB`; 1 KB = 1024 bytes; GB above); the other fields are only in the JSON
`Sink: TLogSink` | where the lines go; nil = stdout (`TFdSink`); an application's own sink overrides `Write(P, Len)`, which runs on the flusher thread and may block
`BufferBytes` | per-loop buffer size (two areas of this size); 0 = 64 KiB
`FlushMs` | the flusher thread's period; 0 = 100 ms; a half-full buffer wakes it early
`UserAgent` | include the User-Agent header
`Referer` | include the Referer header
`Colors` | `alfConsole` only: the level in structlog's ANSI color (bright green for info, red for error); the rest of the line has none
`MinLevel: TLogLevel` | the lines below it are dropped, in both formats: a line has the level of its status (`AccessLevel`: `llError` for a 4xx or a 5xx, `llInfo` for the others), so `llWarning` or `llError` keeps only the requests that failed; `llDebug` (the default) keeps every line

The loop formats each line into its buffer under a spin lock; the flusher
thread swaps the buffer's two areas and writes the full one to the sink.
A line that does not fit is dropped and counted (`TServer.AccessLog.Dropped`,
`bearings_access_log_dropped_total`), so a slow sink never stalls a loop.
`Wait` flushes the last lines after the loops stopped.

Cost (bench/run_gate.sh on 2026-10-12, `ACCESS_LOG=/dev/null METRICS=1`,
four loops): formatting one JSON line takes about 180 ns; with the log and
the metrics on, the gate's cells ran at 0.86 and 0.88 of hyper at pipeline
depth 1 (0.96 and 0.98 with them off) and at 0.61 and 0.64 at depth 16
(0.85 and 0.88 off), where the server logs about 1.9 million lines per
second. The metrics alone cost about 2 %. With both off the cost is one
pointer test per request and the cells match the report.

`Metrics: Boolean` keeps per-loop counters; `TServer.Metrics(out S:
TMetricsSnapshot)` adds them together (each running loop copies its own on
its thread; not from a loop thread) and `TServer.PrometheusText` renders
the snapshot with `MetricsToPrometheus`: `# HELP` and `# TYPE` lines,
names with the `bearings_` prefix, fixed label sets. The metrics:

Metric | Kind | Meaning
------ | ---- | --------
`bearings_connections_open` | gauge | HTTP connections in the loops' lists
`bearings_connections_counted` | gauge | the connection limit's count (0 without a limit)
`bearings_connections_accepted_total` | counter | accepted by the listeners
`bearings_connections_closed_total{outcome=...}` | counter | by `TConnOutcome` (`ok`, `timeout`, `parse_too_large`, `parse_version_h2`, `parse`, `incomplete`, `user`, `canceled`, `closed`, `body_write_aborted`, `shutdown`, `io`, `other`)
`bearings_requests_total` | counter | request heads read
`bearings_requests_in_flight` | gauge | connections with a service call in progress or a response body being written (counted at snapshot time)
`bearings_responses_total{status=...}` | counter | completed responses by class `1xx` .. `5xx`, `other`
`bearings_request_bytes_total`, `bearings_response_bytes_total` | counter | HTTP bytes: heads and bodies
`bearings_request_duration_seconds` | histogram | head read to complete response; buckets `le` = 2^K microseconds, K = 0..23, plus `+Inf`; `_sum`, `_count`
`bearings_listener_pauses_total{reason="error"|"limit"}` | counter | listeners taken out of epoll
`bearings_worker_queue_length`, `bearings_worker_threads` | gauge | the worker pool
`bearings_buffer_pool_bytes` | gauge | bytes held in the loops' buffer pools
`bearings_access_log_dropped_total` | counter | see above
`bearings_loops` | gauge | event loops

Serving the text at an HTTP path such as `/metrics` is the application's
job; `MetricsToPrometheus` does no I/O.

## systemd (unit `bearings.rt.sd`)

The unit talks to systemd without libsystemd. Sample units are at the end
of this section.

Routine | Meaning
------- | -------
`SdListenFds(out Fds, out Names): Integer` | the sockets systemd passed (`LISTEN_FDS`, descriptors from 3 on, set close-on-exec) when `LISTEN_PID` is this process; removes the three variables from the environment; `Names` from `LISTEN_FDNAMES`
`ApplySdListenFds(var Cfg: TServerConfig): Integer` (unit `bearings.server`) | `Cfg.Listen.InheritedFd` gets the first passed socket and `Cfg.AlsoListen` the others; 0 (nothing passed) leaves `Cfg` unchanged
`SdNotifyEnabled: Boolean` | `NOTIFY_SOCKET` is set
`SdNotify(State): Boolean` | sends one datagram (`'READY=1'`, `'STATUS=...'`, `'WATCHDOG=1'`, lines separated by LF) to `NOTIFY_SOCKET` (a path, or an abstract name starting with `@`)
`SdWatchdogUsec: Int64` | the watchdog interval when `WATCHDOG_USEC` is set and `WATCHDOG_PID` (if set) is this process; else 0

`TServer` uses them itself: `Start` sends `READY=1` (with a `STATUS=` line)
once every listener is open and the loops run, `Stop` sends `STOPPING=1`,
and with `TServerConfig.Watchdog` set (the production preset sets it) and
`WATCHDOG_USEC` in the environment, a heartbeat thread sends `WATCHDOG=1`
every half interval while every loop is making progress: each round it
posts a message to every loop and, in the next round, sends the heartbeat
only when every loop handled it. An idle loop is woken by the message and
counts as alive; a loop blocked in a handler does not, the heartbeat stops
and systemd restarts the service. `TServer.WatchdogRunning` says whether
the thread runs; `Wait` joins it after a `Stop`.

A program that supports socket activation calls `ApplySdListenFds` before
`Start`. Because systemd keeps the socket open, connections that arrive
while the service restarts wait in the accept queue instead of being
refused.

```pascal
Cfg := ProductionServerConfig;
Cfg.Listen.Port := 8080;            { used when systemd passed no socket }
ApplySdListenFds(Cfg);
Srv := TServer.CreateWithProc(Cfg, @NewService);
Srv.RunUntilSignalProc(nil);        { SIGTERM from systemctl stop }
```

Sample units (`/etc/systemd/system/myapp.socket` and `myapp.service`):

```ini
[Unit]
Description=myapp listening socket

[Socket]
ListenStream=8080
# or a Unix socket for a reverse proxy on the same machine:
# ListenStream=/run/myapp/http.sock
# SocketMode=0660
# SocketGroup=www-data
Backlog=4096
NoDelay=true

[Install]
WantedBy=sockets.target
```

```ini
[Unit]
Description=myapp
Requires=myapp.socket
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/myapp
Restart=on-failure
WatchdogSec=30
KillSignal=SIGTERM
TimeoutStopSec=40

[Install]
WantedBy=multi-user.target
```

`systemctl start myapp.socket` listens; the service starts on the first
connection. Without systemd the same program can be tried with
`systemd-socket-activate -l 8080 ./myapp`.

Behind a reverse proxy (nginx on the Unix socket above, HAProxy, a cloud
load balancer) the peer of every connection is the proxy. Set
`Cfg.H1.ProxyProtocol := True` (TH1Config, below) and configure the proxy
to send the header: in nginx, `proxy_protocol on` in the `server` block
that proxies to the program; in HAProxy, `send-proxy` or `send-proxy-v2`
on the backend server.

## TH1Config (unit `bearings.http1.config`)

The options of one HTTP/1.1 connection. The defaults in parentheses are
those of `ConformanceH1Config`.

Field | Meaning
----- | -------
`KeepAlive` (True) | serve more requests on the connection after the first one
`HalfClose` (False) | when the client closes its sending side, still finish the response in progress
`TitleCaseHeaders` (False) | write response header names as `Content-Type` instead of `content-type`
`PreserveHeaderCase` (False) | accepted and ignored (request names are always kept as received)
`MaxHeaders` (-1 = 100) | most header fields in a request head; more gives 431
`MaxHeaderSize` (-1 = no own limit) | most bytes in a request head; more gives 431
`MaxBufSize` (-1 = about 408 KiB) | largest read buffer; a request head must fit; minimum 8192
`Timer` (False) | the connection may arm timers; every timeout needs it
`HeaderReadTimeout: TTimeoutSetting` (tsDefault) | `tsDefault`: 30 s with a timer, none without; `tsDisabled`; `tsMs`: `HeaderReadTimeoutMs`
`HeaderReadTimeoutMs` | used with `tsMs`
`PipelineFlush` (False) | while a pipelined request is still buffered, hold the response so several go out in one write
`AutoDateHeader` (True) | add a `Date` header unless the application set one
`BodyReadTimeoutMs` (0 = off) | longest wait for one request body byte
`BodyMinRate` (0 = off) | bytes/s the client must keep up after `BodyReadTimeoutMs` of waiting
`ProxyProtocol` (False) | every connection starts with a PROXY protocol header, v1 or v2 (`bearings.rt.proxyproto`), from the proxy or load balancer in front: the address it carries becomes the peer (`TExchange.PeerAddr`, the access log's `client`); a connection without a valid header is closed without a response (outcome `parse`), one closed before any byte is a normal end. Only for listeners that only the proxy can reach: the header is trusted
`MaxRequests` (0 = no limit) | most requests one connection serves; the last allowed response carries `Connection: close` (nginx `keepalive_requests`)
`MaxConnectionMs` (0 = no limit) | once a connection is this old, its next response carries `Connection: close` and closes it; a request in progress is never cut, and an idle connection past the age stays until its next request or the header read timeout (nginx `keepalive_time`)
`Parser: TParserConfig` | leniency switches of the head parser (`bearings.http1.parser`)
`Mode: TH1ConnMode` (cmPlain) | what happens after a `101` response and at the end of the connection (section 10)

Presets: `ConformanceH1Config` is the base (no timer, so no timeouts;
upgrades not handed over). `ProductionH1Config` is the base plus `Timer`,
the 30 s header read timeout, `PipelineFlush`, `cmWithUpgrades` and the
body rate rule (30 s, 1 KiB/s). `ValidateH1Config` rejects invalid
combinations (`MaxBufSize` below 8192, a `tsMs` header timeout or a body
timeout without a timer, negative values, `BodyMinRate` without
`BodyReadTimeoutMs`, a negative `MaxRequests` or `MaxConnectionMs`);
`TServer.Start` runs it and raises `EServerError`
with its message.

Server presets: `ProductionServerConfig` listens on 0.0.0.0:8080, backlog
4096, `amReusePort`, `NoDelay`, `Loops` 0, `ProductionH1Config`, `Workers`
0 (a pool), `GraceMs` 30 000. `BenchmarkServerConfig` is for throughput
measurements: `ConformanceH1Config` with `PipelineFlush`, no timer,
`cmPlain`, no worker pool (`Workers` -1), `GraceMs` 1000.

`ProductionServerConfig` starts the worker pool even when the service
never uses it. Set `Workers := NO_WORKER_POOL` (-1) for a service that
answers every request inline and never offloads: no worker thread is
started, `TServer.Workers` is nil, and `Wait` and `Destroy` have no pool to
shut down (`examples/hello.pas`).

## Lifecycle (TServer)

- `Create(Cfg, Factory, Observer = nil)`: stores them; nothing runs yet.
  `CreateWithProc(Cfg, Factory: TServiceProc, Observer = nil)` is the same
  with a plain function as the factory.
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
  `RunUntilSignalProc(Started: TServerProc)` is the same with a plain
  procedure as the callback.
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

`Create`, `CreateWithProc`, `Start`, `StartCallerRunsLoop0`, `RunLoop0`,
`Wait`, `RunUntilSignal`, `RunUntilSignalProc` and `Destroy` are called by
the thread that owns the server. `Stop` may be called from any thread.
