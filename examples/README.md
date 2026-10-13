# Examples

These are nine functional programs, each one explained in the comment at the top of its source and in `docs/api.md`.

Program      | What it shows
-------------|---------------
`hello.pas`  | A `TServer` with `ProductionServerConfig` (without its worker pool: `Workers := NO_WORKER_POOL`) and one service that answers "Hello" to every request, inline on the loop thread, with a static body (`BodyStatic`). The factory and the Started callback are plain routines (`CreateWithProc`, `RunUntilSignalProc`).
`worker.pas` | Every request is handed to a worker thread (`TOffloadCall`, `TBlockingHandler`). The worker reads the request body with `ReadAll` and echoes it back with `BodyString`; it handles `EBodyTooLarge`, `EBodyError`, `EClientGone` and `IsCanceled`; the error answers use `RespondText`.
`stream.pas` | A streamed response from a worker (`BeginStream`, `Write`, `Finish`: ten lines, one per 100 ms) and a file response (`BodyFile`, sent with sendfile). Routes are matched with `PathIs`.
`ws_echo.pas` | A WebSocket echo server (`CheckRequest`, `AcceptWebSocket`, a `TWebSocketHandler`). It keeps a backlog for sends refused with `wsFull` and sends it from `OnWritable`. Default port 9001; the second argument is the number of loops; a third argument `worker` runs the echo on the worker pool instead (a `TWsWorkerHandler`, for handlers that block). Used for the Autobahn TestSuite and the WebSocket benchmark.
`kv1.pas`    | A key-value store over HTTP (`GET /kv/<key>`, `PUT /kv/<key>?<value>`) with one store per event loop, answered inline. The `x-loop` response header shows that a value stored on one loop is not seen by the others. Tutorial chapter 3 (`docs/tutorial/handling-requests.md`).
`kv2.pas`    | The same store shared by every loop under a `TCriticalSection`, with the factory and `Started` as methods (`TServer.Create`, `RunUntilSignal`). Tutorial chapter 4 (`docs/tutorial/shared-state.md`).
`kv3.pas`    | The shared store on the worker pool (`TOffloadCall`, `TBlockingHandler`): `PUT` reads the value from the request body with `ReadAll` and handles `EBodyTooLarge`, `EBodyError` and `EClientGone`. Tutorial chapter 5 (`docs/tutorial/workers.md`).
`delay.pas`  | `GET /delay` answered one second later on the loop thread with a `TWakeTimer`: a call object per request that returns `cpPending`, is woken by the timer, and frees itself in `Drop`. Tutorial chapter 8 (`docs/tutorial/loops-in-depth.md`).
`ws_chat.pas` | A WebSocket chat with rooms on the pub/sub topics of `bearings.ws.topics` (`TWsTopics`: `Subscribe`, `Unsubscribe`, `Publish` with the sender excluded). A client joins a room with the path `/room/<name>` or with a first message `join <name>`; every message it sends goes to the other members of the room, on every loop. Default port 9002; the second argument is the number of loops.

## Build

From the repository root (Free Pascal 3.2.2, Linux x86_64; for ARM64 replace `fpc` with `build/tools/bin/fpc-aarch64`, README.md section "ARM64"):

```sh
mkdir -p build/examples/units
for p in hello worker stream kv1 kv2 kv3 delay ws_echo ws_chat; do
  fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
      -FUbuild/examples/units -FEbuild/examples examples/$p.pas
done
```

The binaries land in `build/examples/`. `-FU` is where the compiled units
go and `-FE` where the executable goes; both directories must exist.

## Run

Each program takes the port as its first argument (default 8080) and stops
on SIGTERM or SIGINT (`RunUntilSignal`).

```sh
build/examples/hello 8080 &
curl -i http://127.0.0.1:8080/
kill %1

build/examples/worker 8080 &
curl -i --data-binary 'some text' -H 'content-type: text/plain' http://127.0.0.1:8080/
kill %1

build/examples/stream 8080 /etc/os-release &
curl -N http://127.0.0.1:8080/          # one line per 100 ms
curl -i http://127.0.0.1:8080/file      # the file, with its Content-Length
kill %1

build/examples/kv3 8080 &
curl -X PUT --data-binary 'world' http://127.0.0.1:8080/kv/hello
curl http://127.0.0.1:8080/kv/hello
kill %1

build/examples/ws_chat 9002 &
websocat ws://127.0.0.1:9002/room/general   # in two terminals: what one types the other sees
kill %1
```
