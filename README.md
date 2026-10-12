# bearings

bearings is an HTTP/1.1 server library for Free Pascal: an event loop per
CPU, a pool of worker threads for code that blocks, an HTTP/1.1 parser and
encoder, and a `TServer` that ties them together. An application gives the
server a service object; the server calls it once per request with a
`TExchange` (the request and its response) and writes the response the
service produces.

It runs on Linux x86_64 only: it calls epoll, eventfd, accept4, sendfile
and writev directly.

## What it is and is not

bearings speaks HTTP/1.1 (and HTTP/1.0) over plain TCP: keep-alive,
pipelining, chunked bodies, trailers, `Expect: 100-continue`, connection
upgrades (the hand-off of the socket after a `101 Switching Protocols`
response), request body backpressure, streamed responses with
backpressure, file bodies with sendfile, graceful shutdown.

It has no TLS, no HTTP/2 and no WebSocket protocol code yet. For TLS, put a
reverse proxy such as nginx in front of it. WebSocket support on top of the
existing upgrade hand-off is planned work: `docs/handoff-websocket.md`. A
Unix domain socket listener, systemd socket activation, a connection limit
and an access log are planned too: `docs/handoff-operations.md`.

## Requirements

Free Pascal 3.2.2, Linux x86_64. Nothing else to run a program that uses
the library.

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

var
  Cfg: TServerConfig;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;     { answers inline: no worker threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.RunUntilSignal;                { until SIGTERM or SIGINT }
  Srv.Free;
end.
```

What happens: `TServer.CreateWithProc` stores the configuration and the
factory (a plain function; `TServer.Create` takes a method instead, for a
program that keeps state in an object). `RunUntilSignal` binds the port,
starts one event loop thread per CPU (`DefaultLoopCount`), calls
`NewService` once per loop, then waits for SIGTERM or SIGINT; on the
signal it stops the server gracefully (open connections finish their
current response, with a 30 s deadline) and returns. For every request a
loop parses, it calls `THelloService.Call`, which returns the call object,
and then polls `THelloCall.Poll`, which answers. `Respond` with a body of
known length makes the encoder write a `Content-Length` header; a `Date`
header is added too.

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
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server \
    -FUbuild/examples/units -FEbuild/examples examples/hello.pas
build/examples/hello 8080 &
curl -i http://127.0.0.1:8080/
kill %1
```

`-Mobjfpc -Sh` select the object Pascal mode with long strings, which every
unit of the library uses. `cthreads` must be the first unit of the program:
the server starts threads.

## Documentation

- `docs/api.md`: the API guide, organized by what a program does
  (configure, answer inline or on a worker, read request bodies, stream
  responses, upgrades, shutdown), with a reference table of every public
  type and routine and its threading rule.
- `examples/`: three complete programs (`hello.pas`, `worker.pas`,
  `stream.pas`) and the command that builds them (`examples/README.md`).
- The header comment of every unit under `src/` explains what the unit does
  for a reader who knows Free Pascal but not web servers.
- `docs/design/m3-transport.md` and `docs/design/m3-perf-report.md`: the
  design and the performance measurements (written while this code was part
  of another project; the unit names were updated).

## Layers

`src/rt` uses nothing from the other directories. `src/http` uses the
parser, encoder and decoder of `src/http1`, and the connection and
dispatcher units of `src/http1` use `src/http`. `src/server` uses all of
them.

| Directory     | Units                    | What it does |
|---------------|--------------------------|--------------|
| `src/rt`      | `bearings.rt.*`, `bearings.version` | Runtime: system calls, clocks, the per-thread event loop (`bearings.rt.loop`), timers, buffer pool, TCP listener and transport, worker threads. Knows nothing about HTTP. |
| `src/http1`   | `bearings.http1.*`, `bearings.http.date`, `bearings.http.headers`, `bearings.http.uri` | HTTP/1.1: request parser, response encoder, body decoder, connection state machine, dispatcher. `bearings.http.date` keeps each loop's Date header through the loop's tick hook (`LoopTickProc`, `TLoop.Ext`). |
| `src/http`    | `bearings.http.exchange`, `bearings.http.error` | The request/response exchange that a service (application) handles, inline on the loop or on a worker thread. |
| `src/server`  | `bearings.server`        | `TServer`: listeners, loops, workers, signals, graceful stop. |

An application puts all four directories on its unit path (`-Fu`). The
units a program normally uses directly are `bearings.server`,
`bearings.http.exchange`, `bearings.rt.buf` (the body constructors),
`bearings.http.headers`, `bearings.http1.config`, `bearings.rt.loop`,
`bearings.rt.workers` and, for upgrades, `bearings.rt.stream`.

## Building and testing

There is no build step for the library itself: programs compile its units
with `fpc -Mobjfpc -Sh -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server`.
Build output goes under `build/` (ignored by git).

- `examples/README.md`: the command that builds the three example programs
  into `build/examples/`.
- `tools/get-tools.sh`: fetches valgrind, wrk and wrk2 into `build/tools/`.
- `tests/unit/run_all.sh`: every unit suite (also under heaptrc and
  valgrind drd), the worker stress test, the echo test under valgrind, the
  split fuzz and the hot-path assembler check (`tools/check-hot-asm.sh`,
  which fails when a routine of the request path got an implicit
  exception frame).
- `conformance/pascal-server/gate.sh`: the wire conformance cases
  (`conformance/cases`) against the Pascal conformance server; the runner
  and the hyper reference server are in the Cargo workspace `conformance/`.
- `bench/`: the throughput benchmarks against hyper (`bench/run_gate.sh`,
  `bench/plaintext.pas`), the offload cost (`bench/run_offload.sh`) and
  micro-benchmarks (`bench/bench_dispatch.pas`).

## Version and license

Version: `bearings.version.BEARINGS_VERSION` (0.1.0).

License: MIT (see `LICENSE`).
