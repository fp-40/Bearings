# 15. The C interface

`src/capi/` makes the server a C library, for programs written in other
languages: `bearings.capi.pas` holds the routines (its header comment
describes them in full), `libbearings.pas` exports them from a shared
library, and `bearings.h` declares them for C. The Python package in
`python/` (`pybearings`, imported as `bearings`) is built on it, with cffi.

```sh
fpc -Mobjfpc -Sh -O2 -fPIC -Fusrc/rt -Fusrc/http -Fusrc/http1 \
    -Fusrc/server -Fusrc/ws -Fusrc/capi -FUbuild/capi \
    -obuild/capi/libbearings.so src/capi/libbearings.pas
```

Every routine is `cdecl` and lets no Pascal exception out: a failure is a
return value. Every name starts with `bearings_`.

## The model

It is the model of `examples/worker.pas`: every request is handed to the
worker pool, and a worker calls the program's request callback with the
exchange and the request head. The callback may block (it reads the body,
it waits for a database). It answers with exactly one of
`bearings_respond`, `bearings_respond_file` or `bearings_begin_stream`
(then `bearings_write`, and `bearings_finish` or `bearings_abort_stream`)
before it returns. The exchange is valid only during the callback; a
callback that returns without answering gets a 500. When the body's
length is known (`bearings_respond` with a body, `bearings_respond_file`),
a `Content-Length` among the headers is left out and the server writes
that length: a wrong one would break the framing of the connection.

`bearings_server_new` blocks every signal while it starts the server's
threads, which inherit that mask: the process's signals go to the threads
of the host program, so an interpreter that handles `SIGINT` on its main
thread keeps doing so.

## The configuration

`bearings_config` (`TBearingsConfig`) is a C struct; zeroed fields take the
defaults of `ProductionServerConfig`.

Field | Meaning
----- | -------
`host`, `port` | where to listen; `NULL`/`""` is `0.0.0.0`, port 0 a free port (`bearings_server_port`); an address, not a host name
`unix_path`, `unix_mode` | a Unix socket instead of a port, and its file's permission bits (0 = `0660`)
`inherited_fd` | an open listening socket to serve from (for example one systemd passed)
`loops`, `workers` | event loops (0 = one per CPU) and worker threads (0 = `min(32, CPUs + 4)`)
`worker_queue_limit`, `saturated_status` | past this many queued requests, a new one is answered at once with `saturated_status` (503)
`max_connections` | connections open at once (0 = no limit)
`access_log` | 0 off, 1 JSON lines, 2 console lines (`23:59:59.123456Z [info]  200 GET /x  (0.412ms; 16.03 KB)`), on stdout
`access_log_level` | the access log's lines below this level of Python's `logging` are dropped (0 = none); a line has the level of its status: 40 (error) for a 4xx or a 5xx, 20 (info) for the others
`access_log_user_agent`, `access_log_referer` | 1 = the lines have the request's User-Agent / Referer header
`access_log_colors` | 1 = the console lines have the level in structlog's ANSI color
`metrics` | 1 keeps the counters of `bearings_metrics`
`ws_path` | WebSockets are accepted on this path (`NULL`/`""` = none); other requests to it go to the request callback
`ws_origins` | the `Origin` values allowed, one per line, compared ignoring case and a final `/`
`ws_same_host`, `ws_any_port` | also allow an `Origin` whose `host[:port]` is the `Host` header, or any port of its name
`ws_ping_ms`, `ws_idle_ms` | pings (0 = 25 000; -1 = none) and the idle timeout (0 = 60 000; -1 = none)
`ws_max_message`, `ws_send_high_water` | the largest message (0 = 16 MiB; larger closes with 1009) and the output a connection may queue (0 = 1 MiB)
`ws_close_on_backpressure` | 1 = a subscriber that is behind is closed when a publish reaches it, not skipped
`ws_ignore_text` | a text message equal to this never reaches the callback (the answer to a ping of the program's own)

## The request head

The request callback gets the head as one buffer of fields, each ended by
a NUL byte: the method, the path (as received, percent-escapes kept), the
query (without the `?`; empty when there is none), the version
(`HTTP/1.1`), the client's address and port (empty on a Unix socket), then
a name and a value for each header field, in the order received. The
parser refuses NUL in every one of them, so the separators are
unambiguous. Response header lists use the same layout: a name, NUL, a
value, NUL, for each field.

## Routines

Routine | Thread | Result
------- | ------ | ------
`bearings_version()` | any | the version text
`bearings_server_new(cfg, cb, ws_cb, ctx, err, err_len)` | owner | the server, or `NULL` with the reason in `err` (a port taken: `... errno 98`)
`bearings_server_port(srv)` | any | the port it listens on (0 on a Unix socket)
`bearings_server_stop(srv, grace_ms)` | any | starts the graceful shutdown and returns; no publish after it
`bearings_server_wait(srv)`, `bearings_server_free(srv)` | owner | waits for the loops and the workers; frees everything
`bearings_metrics(srv, buf, len)` | any but a loop | the Prometheus text's length; copied when it is less than `len`
`bearings_read(ex, buf, max)` | the callback | bytes of the body (0 at its end); -1 a body error (`bearings_body_error` has its text), -2 the request was canceled
`bearings_respond(ex, status, headers, hlen, body, blen)` | the callback | 0; 1 canceled or already answered; -1 an invalid header (nothing changed: the callback may answer again)
`bearings_respond_file(ex, status, headers, hlen, fd, offset, len)` | the callback | the same; the server owns `fd` from the call on, and closes it
`bearings_begin_stream(ex, status, headers, hlen)`, `bearings_write(ex, data, len)`, `bearings_finish(ex)` | the callback | the same; `bearings_write` blocks while the client is behind
`bearings_abort_stream(ex, msg)` | the callback | ends the body with an error: what was written is flushed, the last chunk is left out, the connection closes
`bearings_is_canceled(ex)` | the callback | 1 when the client went away

## WebSockets

With a `ws_path`, the server accepts WebSockets there. On the loop, the
handshake's `Origin` is checked (a refused one gets 403) and the upgrade
answered; then the connection's events go to the WebSocket callback, on the
worker pool, one at a time per connection, in order:

Event | Data
----- | ----
1, opened | the handshake, laid out as a request head
2, text; 3, binary | the message
4, closed (the last) | the close code in decimal, NUL, the client's reason

The opened event gives the connection an id. The program reaches the
connection by that id, from any thread:

Routine | Result
------- | ------
`bearings_ws_send(srv, id, data, len)` | 0; 1 closing or gone; 2 its output is at the high-water mark (nothing was queued)
`bearings_ws_close(srv, id, code, reason)` | 0; 1 closing or gone
`bearings_ws_subscribe(srv, id, topic, len)`, `bearings_ws_unsubscribe(...)` | 0; 1 closing or gone; -1 not a valid pattern (`bearings.ws.topics`: `/` levels, `+` and `#`)
`bearings_ws_publish(srv, topic, tlen, data, len)` | 0; 1 after the stop; -1 not a valid topic. A text message to every subscriber, encoded once; one made after `bearings_ws_subscribe` returned reaches the new subscriber
`bearings_ws_count(srv)` | the WebSockets open

The tests are `tests/unit/test_capi.pas` (real sockets, also run with
heaptrc), and the Python package's own suite.
