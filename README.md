# bearings

bearings is the event loop, the HTTP/1.1 server and the worker pool that
were the lower layers of the wd-40 web framework, moved into a library of
their own. It is written in Free Pascal and runs on Linux x86_64 only
(epoll, eventfd, accept4, sendfile, writev called directly).

Requirements: Free Pascal 3.2.2, Linux x86_64. The tests and benchmarks
also use Python 3, Rust/cargo (the conformance harness and the
differential tests against hyper and httparse), and valgrind, wrk and wrk2
fetched by `tools/get-tools.sh` into `build/tools/`.

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

An application (for example a web framework) puts all four directories on
its unit path (`-Fu`).

## Building and testing

There is no build step for the library itself: programs compile its units
with `fpc -Mobjfpc -Sh -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server`.

- `tools/get-tools.sh`: fetches valgrind, wrk and wrk2 into `build/tools/`.
- `tests/unit/run_all.sh`: every unit suite (also under heaptrc and
  valgrind drd), the worker stress test, the echo test under valgrind, the
  split fuzz and the hot-path assembler check (`tools/check-hot-asm.sh`).
- `conformance/pascal-server/gate.sh`: the wire conformance cases
  (`conformance/cases`) against the Pascal conformance server; the runner
  and the hyper reference server are in the Cargo workspace `conformance/`.
- `bench/`: the benchmarks against hyper (`bench/run_gate.sh`,
  `bench/plaintext.pas`) and micro-benchmarks (`bench/bench_dispatch.pas`).

Design notes: `docs/design/m3-transport.md` and
`docs/design/m3-perf-report.md` (written while this code was part of
wd-40).

Version: `bearings.version.BEARINGS_VERSION` (0.1.0).
