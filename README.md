# bearings

bearings is an HTTP/1.1 server library for Free Pascal: an event loop per
CPU, a pool of worker threads for code that blocks, an HTTP/1.1 parser and
encoder, and a `TServer` that ties them together. An application gives the
server a service object; the server calls it once per request with a
`TExchange` (the request and its response) and writes the response the
service produces.

It runs on Linux only: it calls epoll, eventfd, accept4, sendfile and
writev directly. x86_64 is the tested platform; an ARM64 (aarch64) build
exists and runs under emulation but has not run on ARM64 hardware yet
(section "ARM64").

## What it is and is not

bearings speaks HTTP/1.1 (and HTTP/1.0) over plain TCP: keep-alive,
pipelining, chunked bodies, trailers, `Expect: 100-continue`, connection
upgrades (the hand-off of the socket after a `101 Switching Protocols`
response), request body backpressure, streamed responses with
backpressure, file bodies with sendfile, graceful shutdown. It speaks the
WebSocket protocol (RFC 6455) on the event loop: the opening handshake,
fragmented messages, UTF-8 checks, ping/pong, the close handshake, a
message size limit, idle and close timeouts, send backpressure, and sends
from other threads (`src/ws`, section "WebSocket" below).

It has no TLS and no HTTP/2. For TLS, put a reverse proxy such as nginx in
front of it. The WebSocket code negotiates no extension (no
permessage-deflate compression); its handlers run on the loop thread or,
for code that blocks, on the worker pool, one event at a time per
connection. It
listens on TCP or on a Unix domain socket, runs under systemd socket
activation with readiness and watchdog notifications, can cap the number
of open connections, and can write an access log (JSON lines or the
Combined Log Format) and keep metrics with a Prometheus text export
(`docs/api.md`, section 2).

## Requirements

Free Pascal 3.2.2, Linux x86_64 (or ARM64, section "ARM64"). Nothing
else to run a program that uses the library.

The tests and benchmarks also use Python 3, Rust/cargo (the conformance
harness and the differential tests against hyper and httparse), and
valgrind, wrk and wrk2, fetched by `tools/get-tools.sh` into
`build/tools/`.

## Hello world

A server with the production configuration and one service that answers
"Hello" to every request, inline on the loop thread. The full program with
comments is `examples/hello.pas`.

```pascal
program hello;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.rt.buf, bearings.http.headers,
  bearings.http.exchange, bearings.server;

const
  GREETING: array[0..5] of AnsiChar = 'Hello'#10;

type
  THelloCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  THelloService = class(THttpService)
  private
    FCall: THelloCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;

constructor THelloService.Create;
begin
  inherited Create;
  FCall := THelloCall.Create;
end;

destructor THelloService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function THelloService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := THelloService.Create;
end;

procedure Started(Server: TServer);
begin
  WriteLn(StdErr, 'hello: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
  Sig: Integer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;     { answers inline: no worker threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  ApplySdListenFds(Cfg);             { under systemd: the passed socket }
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Sig := Srv.RunUntilSignalProc(@Started);   { until SIGTERM or SIGINT }
  WriteLn(StdErr, 'hello: stopped (signal ', Sig, ')');
  Srv.Free;
end.
```

What happens: `TServer.CreateWithProc` stores the configuration and the
factory (a plain function; `TServer.Create` takes a method instead, for a
program that keeps state in an object). `RunUntilSignalProc` binds the
port, starts one event loop thread per CPU (`DefaultLoopCount`), calls
`NewService` once per loop, calls `Started`, then waits for SIGTERM or
SIGINT; on the signal it stops the server gracefully (open connections
finish their current response, with a 30 s deadline, `GraceMs`) and
returns the signal number. For every request a loop parses, it calls
`THelloService.Call`, which returns the call object, and then polls
`THelloCall.Poll`, which answers. `Respond` with a body of known length
makes the encoder write a `Content-Length` header; a `Date` header is
added too.

The program prints nothing per request: its only output is the two
stderr lines above. Requests are logged only when the access log is on
(`Cfg.AccessLog.Enabled := True`: one JSON line per request to stdout,
or the Combined Log Format with `Format := alfCombined`; `docs/api.md`,
section 2, "Access log and metrics").

`ProductionServerConfig` starts a pool of worker threads for handlers
that block (`Workers = 0`: `Min(32, cpus + 4)` threads). This service
answers every request on the loop thread and never hands one to a worker,
so the program sets `Workers := NO_WORKER_POOL` (-1) and no worker thread
is started. Leave the default for a service that offloads
(`examples/worker.pas`).

For a handler that answers with a text, `Ex.RespondText(404, 'not
found')` sets the status and the `Content-Type` header and responds in
one call; `SliceToStr`, `SliceEquals` and `PathIs` turn the request head's
byte slices (`Ex.Path`, header values) into strings or compare them
(`examples/stream.pas`, `examples/worker.pas`).

Compile and run, from the repository root:

```sh
mkdir -p build/examples/units
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
    -FUbuild/examples/units -FEbuild/examples examples/hello.pas
build/examples/hello 8080 &
curl -i http://127.0.0.1:8080/
kill %1
```

`-Mobjfpc -Sh` select the object Pascal mode with long strings, which every
unit of the library uses. `cthreads` must be the first unit of the program:
the server starts threads. With the units installed as a package (section
"Installing as a package") the `-Fu` options go away.

## WebSocket

A service accepts a WebSocket in its call: `CheckRequest` checks the
handshake, `AcceptWebSocket` answers `101 Switching Protocols` and hands
the connection to a `TWebSocket`, which calls the application's
`TWebSocketHandler` on the loop thread. The connection mode must allow
upgrades (`TH1Config.Mode = cmWithUpgrades`, which `ProductionServerConfig`
sets). The full program is `examples/ws_echo.pas`.

```pascal
uses ..., bearings.ws.frame, bearings.ws.handshake, bearings.ws.conn;

type
  TChat = class(TWebSocketHandler)
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

procedure TChat.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
begin
  WS.SendText(P, Len);               { wsOk, wsFull (wait for OnWritable) or wsClosed }
end;

procedure TChat.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  { the last call; WS and this handler are freed after it }
end;

function TMyCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
begin
  if Ex.WantsUpgrade and PathIs(Ex, '/chat') then
  begin
    R := CheckRequest(Ex, ['chat.v1']);        { the subprotocols it supports }
    if R.Ok then
      AcceptWebSocket(Ex, R, TChat.Create, DefaultWsConfig)
    else
      RespondHandshakeError(Ex, R);            { 400, or 426 for a wrong version }
  end
  else
    Ex.RespondText(404, 'not found');
  Result := cpReady;
end;
```

`DefaultWsConfig`: messages up to 16 MiB, a ping every 25 s, a 60 s idle
timeout (the pongs keep a live client from reaching it), a 5 s close
timeout, and 1 MiB send and receive queue limits. A server that authenticates with
cookies passes the allowed origins too (`CheckRequest(Ex, Protocols,
['https://example.com'])`): a handshake from another site's page is
refused with 403. At a graceful stop the server sends each WebSocket a
close frame with code 1001 and waits for it to end. To send one message
to many connections, encode it once with `WsTextFrame` and call
`SendFrame` on each: the connections share the frame's bytes instead of
copying them.

A handler that blocks (a database query per message, for example) derives
from `TWsWorkerHandler` and is accepted with the server's pool:

```pascal
type
  TStore = class(TWsWorkerHandler)
  public
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
  end;

procedure TStore.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  Db.Insert(Msg);                    { blocks: this runs on a worker thread }
  WS.PostText('stored');             { sends from any thread }
end;

  ...
  AcceptWebSocket(Ex, R, TStore.Create, Server.Workers, DefaultWsConfig);
```

Its events run on a worker thread, one at a time per connection and in
order, and an idle connection holds no thread: the loop queues the messages
and hands the connection to the pool only while there is something to
handle. The loop stops reading a connection whose unhandled messages reach
`ReceiveHighWater` (1 MiB by default). `examples/ws_echo.pas worker` is
the echo this way; `docs/api.md`, section 10, has the rules. The unit
headers of `bearings.ws.conn`, `bearings.ws.frame` and
`bearings.ws.handshake` describe the behaviour in full.

## Running under systemd

bearings talks to systemd without libsystemd (unit `bearings.rt.sd`):

- **Socket activation.** With a `.socket` unit, systemd opens the listening
  socket and starts the service with it as file descriptor 3. The service
  calls `ApplySdListenFds(Cfg)` before `Start`: when systemd passed
  sockets, `Cfg.Listen` (and `Cfg.AlsoListen`) use them instead of binding
  a port. Because systemd keeps the socket open, connections that arrive
  while the service restarts wait in the accept queue instead of being
  refused.
- **Readiness.** With `Type=notify`, `Start` sends `READY=1` once every
  listener is open and the loops run, and `Stop` sends `STOPPING=1`.
- **Watchdog.** With `WatchdogSec=`, the server (when `Cfg.Watchdog` is
  set, as in `ProductionServerConfig`) sends `WATCHDOG=1` every half
  interval, but only while every event loop is making progress. A loop
  blocked in a handler stops the heartbeat and systemd restarts the
  service.

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

## Documentation

- `docs/api.md`: the API guide, organized by what a program does
  (configure, answer inline or on a worker, read request bodies, stream
  responses, upgrades, shutdown), with a reference table of every public
  type and routine and its threading rule.
- `examples/`: four complete programs (`hello.pas`, `worker.pas`,
  `stream.pas`, `ws_echo.pas`) and the command that builds them
  (`examples/README.md`).
- The header comment of every unit under `src/` explains what the unit does.
- `docs/design.md`: the design: the decisions and their reasons, the
  invariants a contributor must respect, and the deviations from what an
  HTTP library usually does.
- `docs/perf-report.md`: the performance measurements and how they were
  made.
- `docs/ideas.md`: notes on features under consideration.

## Layers

`src/rt` uses nothing from the other directories. `src/http` uses the
parser, encoder and decoder of `src/http1`, and the connection and
dispatcher units of `src/http1` use `src/http`. `src/server` uses all of
them. `src/ws` uses `src/rt`, `src/http1` and `src/http`; nothing uses
`src/ws`.

| Directory     | Units                    | What it does |
|---------------|--------------------------|--------------|
| `src/rt`      | `bearings.rt.*`, `bearings.version` | Runtime: system calls, clocks, the per-thread event loop (`bearings.rt.loop`), timers, buffer pool, TCP and Unix socket listener and transport, worker threads, systemd integration (`bearings.rt.sd`). Knows nothing about HTTP. |
| `src/http1`   | `bearings.http1.*`, `bearings.http.date`, `bearings.http.headers`, `bearings.http.uri` | HTTP/1.1: request parser, response encoder, body decoder, connection state machine, dispatcher. `bearings.http.date` keeps each loop's Date header through the loop's tick hook (`LoopTickProc`, `TLoop.Ext`). |
| `src/http`    | `bearings.http.exchange`, `bearings.http.error` | The request/response exchange that a service (application) handles, inline on the loop or on a worker thread. |
| `src/server`  | `bearings.server`, `bearings.server.accesslog`, `bearings.server.metrics` | `TServer`: listeners, loops, workers, signals, graceful stop, the connection limit; the access log and the metrics. |
| `src/ws`      | `bearings.ws.handshake`, `bearings.ws.frame`, `bearings.ws.conn` | WebSocket (RFC 6455): the opening handshake, the frame reader and encoder, the connection on the event loop. |

An application puts all five directories on its unit path (`-Fu`). The
units a program normally uses directly are `bearings.server`,
`bearings.http.exchange`, `bearings.rt.buf` (the body constructors),
`bearings.http.headers`, `bearings.http1.config`, `bearings.rt.loop`,
`bearings.rt.workers`, for upgrades `bearings.rt.stream`, for WebSocket
`bearings.ws.handshake` and `bearings.ws.conn`, and under systemd
`bearings.rt.sd` (through `ApplySdListenFds` in `bearings.server`).

## Building and testing

There is no build step for the library itself: programs compile its units
with `fpc -Mobjfpc -Sh -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws`.
Build output goes under `build/` (ignored by git).

- `examples/README.md`: the command that builds the four example programs
  into `build/examples/`.
- `tools/get-tools.sh`: fetches valgrind, wrk and wrk2 into `build/tools/`.
- `tests/unit/run_all.sh`: every unit suite (also under heaptrc and
  valgrind drd), the worker stress test, the echo test under valgrind, the
  split fuzz and the hot-path assembler check (`tools/check-hot-asm.sh`,
  which fails when a routine of the request path got an implicit
  exception frame). `TARGET=aarch64 tests/unit/run_all.sh` cross-compiles
  the unit suites for ARM64 and runs them under qemu (section "ARM64").
- `tools/get-cross-aarch64.sh`: builds the ARM64 cross compiler into
  `build/tools/` (section "ARM64").
- `tools/install-package.sh`: installs the units as an FPC package, so that
  programs compile without `-Fu` (section "Installing as a package").
- `conformance/pascal-server/gate.sh`: the wire conformance cases
  (`conformance/cases`) against the Pascal conformance server; the runner,
  the hyper reference server and the differential fuzzer (`fuzz-diff`)
  are in the Cargo workspace `conformance/`.
- `conformance/autobahn/run.sh`: the Autobahn WebSocket test suite
  (Docker) against `examples/ws_echo.pas`; run by hand.
- `bench/`: the throughput benchmarks against hyper (`bench/run_gate.sh`,
  `bench/plaintext.pas`), the offload cost (`bench/run_offload.sh`),
  micro-benchmarks (`bench/bench_dispatch.pas`) and the WebSocket echo
  benchmark client (`bench/ws_bench.pas`).

## Installing as a package

Instead of passing the five `-Fu` paths, install the units once with FPC's
own package tool (`fpmake.pp` at the repository root, built on `fpmkunit`):

```sh
tools/install-package.sh            # x86_64
tools/install-package.sh aarch64    # the ARM64 cross build (section "ARM64")
```

The units go to `~/.fppkg/lib/fpc/3.2.2/units/<cpu>-linux/bearings/`, a
directory `/etc/fpc.cfg` already searches (and so does
`build/tools/bin/fpc-aarch64`). A program then compiles with no paths:

```sh
fpc -Mobjfpc -Sh hello.pas
build/tools/bin/fpc-aarch64 -Mobjfpc -Sh hello.pas
```

Re-run the script after changing the library: the installed units are a
copy. `fpmake.pp` lists the units and the compiler options (`-O2`); the
script adds the two directories fpmake needs (`--prefix`, and
`--globalunitdir`, where the compiler's own units are, which fpmake needs
to check the dependency on the RTL). `PREFIX` overrides `~/.fppkg`. The
fpmake output stays in `units/` and `build/fpmake/` (ignored by git).

## ARM64

The library compiles for aarch64-linux (ARM64) as well as x86_64-linux.
Two units know the architecture: `bearings.rt.sys` (the system call
stubs: `syscall` with the x86_64 call numbers in
`bearings.rt.sys.x86_64.inc`, `svc #0` with the generic call numbers in
`bearings.rt.sys.aarch64.inc`, where `epoll_pwait` stands in for the
missing `epoll_wait`; and `struct epoll_event`, packed on x86_64 only) and
`bearings.rt.sync` (the spin-wait hint, the valgrind client request for
drd builds, and the memory ordering below). Everything else is the same
source.

Memory ordering. The lock-free code (`bearings.rt.sync`, `TLoop.Post`,
the exchange's state, counters and claims, the WebSocket's references)
was written against the x86-64 model: locked instructions are full
barriers, and plain aligned loads and stores keep program order among
themselves. ARM64 is weaker, and FPC 3.2.2's `Interlocked*` routines on
ARM64 are plain `ldxr`/`stxr` loops with no barrier at all. So every
shared-word access of the library goes through the `Atomic*` wrappers of
`bearings.rt.sync`, never through `Interlocked*` directly, and on ARM64
the wrappers add the barriers that give each access the x86-64 guarantee:
a load barrier after an `AtomicLoad*`, a full barrier before an
`AtomicStore*`, and a full barrier on both sides of each read-modify-write
(`AtomicXchg`, `AtomicCas`, `AtomicInc`, ...). This is deliberately
conservative: correct by construction, with more barriers than a per-site
acquire/release analysis would need. On x86_64 the wrappers compile to the
same instructions as before.

Status: not verified on hardware. The ARM64 build has been exercised only
under `qemu-aarch64` on an x86_64 host, which runs the ARM64 instructions
on a strongly ordered CPU and so cannot show a missing barrier. What that
run checks: the system call stubs (`test_rt_sys` compares each one with
the FPC RTL), the record layouts, and every unit suite with its heaptrc
run. What it does not check: the memory ordering argument above, and the
test programs' own direct `Interlocked*` calls (relaxed on ARM64; they are
counters checked after a join, but they have not been reviewed). The first
run on an ARM64 machine should be `TARGET=aarch64` with `RUN=` empty and
`FPC=fpc` on that machine, then `tools/s7-stress.sh`.

Setup on an x86_64 host (Ubuntu or Debian): install
`binutils-aarch64-linux-gnu`, `libc6-arm64-cross` and `qemu-user`, then
run `tools/get-cross-aarch64.sh`. It builds the FPC 3.2.2 cross compiler,
RTL and packages from the FPC source (fetched and checked by hash) into
`build/tools/fpc-aarch64/`, with one patch to the C start-up code for
glibc 2.34 and later, fetches the ARM64 `libgcc_s` package without
installing it, and writes two wrappers: `build/tools/bin/fpc-aarch64`
(fpc for the cross target) and `build/tools/bin/run-aarch64` (runs an
ARM64 binary under qemu). `TARGET=aarch64 tests/unit/run_all.sh` then
builds and runs the unit suites and their heaptrc runs in
`build/unit-aarch64/`; the valgrind, drd, stress, echo, split-fuzz and
hot-asm steps are x86_64-only and skipped. `FPC=build/tools/bin/fpc-aarch64
tools/compile-each-unit.sh` compiles every unit on its own for ARM64.

## Version and license

Version: `bearings.version.BEARINGS_VERSION` (0.1.0).

License: MIT (see `LICENSE`).
