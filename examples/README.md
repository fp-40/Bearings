# Examples

Four complete programs. Each one is explained in the comment at the top
of its source and in `docs/api.md`.

| Program      | What it shows |
|--------------|---------------|
| `hello.pas`  | A `TServer` with `ProductionServerConfig` (without its worker pool: `Workers := NO_WORKER_POOL`) and one service that answers "Hello" to every request, inline on the loop thread, with a static body (`BodyStatic`). The factory and the Started callback are plain routines (`CreateWithProc`, `RunUntilSignalProc`). |
| `worker.pas` | Every request is handed to a worker thread (`TOffloadCall`, `TBlockingHandler`). The worker reads the request body with `ReadAll` and echoes it back with `BodyString`; it handles `EBodyTooLarge`, `EBodyError`, `EClientGone` and `IsCanceled`; the error answers use `RespondText`. |
| `stream.pas` | A streamed response from a worker (`BeginStream`, `Write`, `Finish`: ten lines, one per 100 ms) and a file response (`BodyFile`, sent with sendfile). Routes are matched with `PathIs`. |
| `ws_echo.pas` | A WebSocket echo server (`CheckRequest`, `AcceptWebSocket`, a `TWebSocketHandler`). It keeps a backlog for sends refused with `wsFull` and sends it from `OnWritable`. Default port 9001; the second argument is the number of loops. Used for the Autobahn TestSuite and the WebSocket benchmark. |

## Build

From the repository root (Free Pascal 3.2.2, Linux x86_64):

```sh
mkdir -p build/examples/units
for p in hello worker stream ws_echo; do
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
```
