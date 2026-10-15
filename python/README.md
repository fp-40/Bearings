# pybearings

[Bearings](../README.md), the Free Pascal HTTP/1.1 server, as a WSGI server for Python. Linux only (x86_64 and ARM64); free-threaded Python works.

```python
from bearings import serve

serve(app, port=8000)  # until SIGINT or SIGTERM
```

The event loops are Bearings' own threads and never run Python. Every request runs the WSGI app on a thread of the worker pool, so the app may block.

`Server(app, **options)` starts and stops a server from code (tests, a process that does other things): `start()`, `port`, `stop(grace)`, `wait()`, `metrics()`, or `with Server(app) as server:`. Its docstring lists the options: the address, a Unix socket or an inherited socket, the number of event loops and workers, a queue limit answered with 503, a connection limit, the access log and the metrics.

With `websocket=`, a `WebSocketHandler`, the server also accepts WebSockets on `ws_path`: its `opened`, `received` and `closed` run on the worker pool, one event at a time per connection, and `ws_send`, `ws_close`, `subscribe`, `unsubscribe` and `publish` reach the connections by id, from any thread. A publish goes to every subscriber of a topic, encoded once.

The package loads `libbearings.so` (`src/capi/` in this repository) with cffi in ABI mode, so it needs no C compiler: building the wheel needs Free Pascal 3.2.2 (`fpc`), which `hatch_build.py` runs.

## Development

```sh
uv sync --python 3.14t     # compiles libbearings.so into src/bearings/
uv run pytest
```

## Wheels

`uv build --wheel` builds the wheel for this machine's CPU
(`manylinux_2_34_x86_64` here). For ARM64, give it the cross compiler of
`tools/get-cross-aarch64.sh`; the wheel is tagged for the CPU that compiler
targets:

```sh
PYBEARINGS_FPC=../build/tools/bin/fpc-aarch64 uv build --wheel   # manylinux_2_34_aarch64
```

`./test-aarch64.sh` does that, installs the wheel in a free-threaded CPython
for ARM64 run under qemu-user, and runs the tests against it. qemu-user runs
on the host's memory model, which is stronger than ARM's: it shows that the
wheel builds, loads and works, not races that only ARM hardware has.
