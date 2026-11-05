 <h1><img src="Bearings.png" height="128" align="middle"/> Bearings</h1>

Bearings is an HTTP/1.1 server library for Object Pascal (Free Pascal compiler): an event loop per CPU, a pool of worker threads for code that blocks, an HTTP/1.1 parser and encoder, and a `TServer` that ties them together. An application gives the server a service object; the server calls it once per request with a `TExchange` (the request and its response) and writes the response the service produces.

It runs natively only on Linux: x86_64, and ARM64 as an experimental target (it builds and passes the unit suites under qemu, and has not run on ARM64 hardware yet; [`docs/design/arm64.md`](docs/design/arm64.md)). On Windows it runs under WSL, and on macOS inside a container.

## Features

Bearings speaks HTTP/1.1 (and HTTP/1.0) over plain TCP and the WebSocket protocol (RFC 6455) on the event loop.

It listens on TCP or on a Unix domain socket, runs under systemd socket activation with readiness and watchdog notifications, can cap the number of open connections and the requests and lifetime of each, reads the PROXY protocol header (v1 and v2) from a proxy or load balancer in front so that the client's address is known behind it, and can write an access log (JSON lines with the keys of structlog's, or short console lines) and keep metrics with a Prometheus text export.

It has no TLS and no HTTP/2. For TLS, put a reverse proxy such as NGINX in front of it. The WebSocket code negotiates no extension (no permessage-deflate compression); its handlers run on the loop thread or, for code that blocks, on the worker pool, one event at a time per connection.

## Requirements

Free Pascal 3.2.2 and Linux 4.5 or later. Nothing else to run a program that uses the library.

The tests and benchmarks also use Python 3, Rust/cargo (only for the benchmark against hyper), and valgrind, wrk and wrk2, fetched by `tools/get-tools.sh` into `build/tools/`.

## Documentation

- [`docs/`](docs/index.md): from a server that answers "Hello" to a key-value store on the worker pool, a timer, streaming, WebSocket and shutdown.
- [`docs/api/`](docs/api/index.md): the API guide, organized by what a program does.
- [`examples/`](examples/README.md): complete and commented; four of them are the ones the tutorial writes.
- [`docs/design/`](docs/design/index.md): the design decisions and their reasons.

The header comment of every unit under `src/` also explains what the unit does.

## Building and testing

There is no build step for the library itself: programs compile its units
with `fpc -Mobjfpc -Sh -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws`.
Build output goes under `build/` (ignored by git).

The `Makefile` runs the tests in tiers:

- `make test`: the fast tier, about two minutes, run by CI on every push: the version check ([`tools/check-version.sh`](tools/check-version.sh)), the unit suites and their heaptrc runs, a split fuzz of 100 seeds, the expected-value tests, the hot-path assembler check and the Python tests.
- `make test-full`: the full tier: drd, the worker stress, the echo under memcheck, the split fuzz of 2000 seeds, and the wire conformance gate. It needs `tools/get-tools.sh`.
- `make test-autobahn` and `make benchmark`: the Autobahn suite and `bench/run_gate.sh`, by hand.
- The `arm64` workflow ([`.github/workflows/arm64.yml`](.github/workflows/arm64.yml)): the unit suites, the worker stress and the pybearings tests on GitHub's ARM64 runner. It is started by hand from the Actions tab, and before the wheels of a release are built; it does not run on a push.
- `make release BUMP=patch|minor|major|X.Y.Z`: [`tools/release.sh`](tools/release.sh) gives Bearings and pybearings the new version, runs every tier, and after a confirmation commits, tags, pushes and creates the GitHub release, which publishes pybearings to PyPI. `DRY_RUN=1` stops before the commit.

Both tiers are one pytest run ([`pytest.ini`](pytest.ini)); the tiers are the marks `fast` and `full`. pytest runs in the `python/` project environment, which builds `libbearings.so` for the Python tests: `uv run --project python pytest ...`. The test files in [`tests/`](tests) build and run the Pascal programs and report every fpcunit test method as a subtest, so the usual pytest selection applies to everything:

```sh
P="uv run --project python pytest"
$P -k h1_conn                               # one unit suite
$P -k h1_conn --fpc-suite=TTestConnState    # one suite class (or Class.Method)
$P -m golden                                # the expected-value tests
$P -m "full and not drd"                    # the full tier without the drd runs
$P -m conformance                           # the wire conformance gate
$P --lf                                     # what failed last time
$P -m "unit and not heaptrc" -n 4           # suites in parallel (pytest-xdist)
$P -m full -v                               # every test method as it starts and ends
```

A drd run takes minutes and prints nothing by itself. With `-v` (and without `-n`), each fpcunit test method is shown when it starts and when it ends, with its time, and the lines of the stress and echo scripts as they come. In any mode the same progress is in a file next to the run's output, which `tail -f` follows: `build/unit/drd/run-1.out.progress` for the first drd run of `test_workers`, `build/unit/<suite>.out.progress` for a unit suite.

What the test files run:

- [`tests/test_unit_suites.py`](tests/test_unit_suites.py): every fpcunit suite with the unit-test flags, then the suites that own memory across threads again under heaptrc (0 unfreed blocks). `TARGET=aarch64` cross-compiles them for ARM64 and runs them under qemu (`docs/design/arm64.md`); the other tests are host-only then.
- [`tests/test_golden.py`](tests/test_golden.py): the parser, the request head rules and the body decoder against the expected values in `tests/golden` (`UPDATE=1` rewrites them after an intended change).
- [`tests/test_split_fuzz.py`](tests/test_split_fuzz.py): the split fuzz, 100 seeds in the fast tier and 2000 in the full tier.
- [`tests/test_checks.py`](tests/test_checks.py): the version check and the hot-path assembler check ([`tools/check-hot-asm.sh`](tools/check-hot-asm.sh), which fails when a routine of the request path got an implicit exception frame).
- [`tests/test_full_tier.py`](tests/test_full_tier.py): the worker, WebSocket and C-interface suites under valgrind drd, the worker stress ([`tools/s7-stress.sh`](tools/s7-stress.sh)) and the echo test under valgrind memcheck ([`tests/unit/test_rt_echo.sh`](tests/unit/test_rt_echo.sh)).
- [`tests/test_conformance.py`](tests/test_conformance.py): the wire conformance cases (`conformance/cases`) against the Pascal conformance server `beconf`, with the inline and the worker executor; the case runner is a Python program in `conformance/runner/crun` (standard library only, no Bearings code).
- `python/tests`: the pybearings tests (`cd python && make test` runs them on their own, with the doctests).

Other scripts:

- [`examples/README.md`](examples/README.md): the command that builds the four example programs into `build/examples/`.
- [`tools/get-tools.sh`](tools/get-tools.sh): fetches valgrind, wrk and wrk2 into `build/tools/`.
- [`tools/get-cross-aarch64.sh`](tools/get-cross-aarch64.sh): builds the ARM64 cross compiler into `build/tools/` (`docs/design/arm64.md`).
- [`tools/install-package.sh`](tools/install-package.sh): installs the units as an FPC package, so that programs compile without `-Fu` (section "Installing as a package").
- [`conformance/autobahn/run.sh`](conformance/autobahn/run.sh): the Autobahn WebSocket test suite (Docker) against `examples/ws_echo.pas`; run by hand.
- `bench/`:
  - the throughput benchmarks against hyper ([`bench/run_gate.sh`](bench/run_gate.sh) and [`bench/plaintext.pas`](bench/plaintext.pas))
  - the offload cost ([`bench/run_offload.sh`](bench/run_offload.sh)),
  - micro-benchmarks ([`bench/bench_dispatch.pas`](bench/bench_dispatch.pas)), and
  - the WebSocket echo benchmark client ([`bench/ws_bench.pas`](bench/ws_bench.pas)).

## Installing as a package

Instead of passing the five `-Fu` paths, install the units once with FPC's
own package tool (`fpmake.pp` at the repository root, built on `fpmkunit`):

```sh
tools/install-package.sh          # x86_64
tools/install-package.sh aarch64  # the ARM64 cross build
```

The units go to `~/.fppkg/lib/fpc/3.2.2/units/<cpu>-linux/bearings/`, a directory `/etc/fpc.cfg` already searches (and so does `build/tools/bin/fpc-aarch64`). A program then compiles with no paths:

```sh
fpc -Mobjfpc -Sh hello.pas
build/tools/bin/fpc-aarch64 -Mobjfpc -Sh hello.pas
```

Re-run the script after changing the library: the installed units are a copy. `fpmake.pp` lists the units and the compiler options (`-O2`); the script adds the two directories fpmake needs (`--prefix`, and `--globalunitdir`, where the compiler's own units are, which fpmake needs to check the dependency on the RTL). `PREFIX` overrides `~/.fppkg`. The fpmake output stays in `units/` and `build/fpmake/` (ignored by git).

## Other languages

`src/capi/` makes the server a C library, `libbearings.so` ([API guide, section 15](docs/api/capi.md)): `bearings.capi.pas` holds the routines and explains the model, `libbearings.pas` exports them, and `bearings.h` declares them for C. Every request runs a callback on the worker pool. With a WebSocket path, the server also accepts WebSockets there, checks their Origin, and hands their events to a second callback, also on the worker pool; the topics of `bearings.ws.topics` are reached by the connection's id.

`python/` is the Python package built on it, `pybearings` (imported as `bearings`): a WSGI server. Its README has the details.

## Version and license

Version: `bearings.version.BEARINGS_VERSION` (0.5.0).

License: MIT (see `LICENSE`).
