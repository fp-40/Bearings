# bearings HTTP/1 conformance harness: contract

This document is the complete contract between three parties:

- **case files** (`cases/**/*.json`): hyper's HTTP/1 server tests, ported to data;
- **the runner** (`runner/`): plays the client, executes case steps, checks assertions;
- **a conformance server**: a process that implements the server side of this contract.
  Two implementations exist or will exist:
  - `reference-server/`: hyper v1.12.0 (git rev `7f67699ce32d717081deb7018b4da7d679277ac0`), the oracle;
  - the bearings Pascal conformance server (later milestone), built from this document.

A conformance server is a thin test wrapper around the HTTP implementation under test. The
wrapper reads a server spec, configures the HTTP/1 connection the way the spec says, installs
the handler the spec names, and reports what happened on stdout. **The wire behavior (framing,
status lines, header handling, keep-alive, error responses) is what the cases test. The wrapper
must not add, remove or rewrite anything on the wire.**

All of this is test tooling. Nothing here ships with bearings.

Contents:

1. Build and commands
2. Byte strings
3. Server process protocol
4. Server spec: `config`
5. Server spec: handlers and replies
6. Connection modes, graceful shutdown, upgrades
7. Server events
8. Case files
9. Steps
10. Assertions
11. Event patterns
12. Normalization and diff mode
13. Timing
14. Porting hyper tests to cases
15. Known limitations

---

## 1. Build and commands

Requirements: cargo/rustc (tested with 1.98.1) and network access on the first build, to fetch
hyper from GitHub.

```sh
cd conformance        # from the repository root
cargo build --release                     # builds target/release/{runner,reference-server,dumb-server}

# assertion mode: run cases against a server command
target/release/runner run cases/h1                         # default server: target/release/reference-server
target/release/runner run --server 'path/to/pascal-server' cases/h1
target/release/runner run --filter pipeline cases/h1/chunk2.json -v
target/release/runner run --jobs 4 --server 'path/to/pascal-server' cases/h1   # 4 cases at a time

# diff mode: run every case against two servers and compare transcripts
target/release/runner diff --a target/release/reference-server --b 'path/to/pascal-server' cases/h1

# mutation check: a server that answers every request head with a fixed 200 (MANIFEST.md)
target/release/runner run --server target/release/dumb-server cases/h1

# list cases (validates case syntax, does not start servers)
target/release/runner list cases/h1
```

- `PATH` arguments are case files or directories. Directories are searched recursively for
  `*.json`, in sorted order.
- `--server CMD`, `--a CMD`, `--b CMD`: a shell command line. The runner executes
  `sh -c 'exec CMD "$@"' sh --config <tmpfile>`, which appends `--config <tmpfile>` to CMD.
- `--filter S` (repeatable): run only cases whose `<file path>::<case name>` contains `S`. With
  several filters, a case runs if any filter matches.
- `--jobs N` (default 1): run N cases at a time, each against its own server process. The output
  keeps the case order: a case's lines are printed when it and every case before it are done.
  With `-v` and N > 1 the stderr transcript entries of different cases interleave.
- `-v`: print every step's transcript entry (stderr) and the server events of passing cases.

Output of `run`: one line per case, `PASS <id> (<ms> ms)`, `FAIL <id> (<ms> ms)` followed by
indented failure details, server events and the server's stderr tail, or `PEND <id>: <reason>`.
`<id>` is `<file stem>::<case name>`. The last line is
`SUMMARY passed=<n> failed=<n> pending=<n> total=<n>`. Exit status: 0 if no case failed, 1 if any
case failed or was invalid, 2 on usage errors or unreadable case files.

Output of `diff`: `SAME <id> ...` or `DIFF <id> ...` followed by the differing transcript entries
and event lists, then `SUMMARY same=<n> different=<n> pending=<n> invalid=<n> total=<n>`. Exit
status 1 if any case differs or is invalid, else 0. See section 12.

---

## 2. Byte strings

HTTP data is bytes. Every field this document calls a **byte string** uses this encoding.

**In events (server output) and transcripts:** a JSON string in which each character is one byte:
code point U+0000..U+00FF is the byte 0x00..0xFF (ISO-8859-1 / latin-1 mapping). Characters
above U+00FF never occur. Example: the bytes `61 0D 0A FF` are the JSON string `"a\r\nÿ"`.

**In case files**, a byte string is either:

- a JSON string, decoded with the same latin-1 mapping (a code point above U+00FF is an error);
- an array of parts, concatenated in order, where each part is
  - a JSON string (as above),
  - `{"repeat": <byte string>, "count": <n>}`: the byte string repeated `n` times,
  - `{"hex": "<hex digits>"}`: bytes from hex pairs; whitespace between digits is ignored.

Example: `["GET /", {"repeat": "a", "count": 65534}, " HTTP/1.1\r\n\r\n"]`,
`["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", {"hex": "00 00 00 04 00 00 00 00 00"}]`.

**Variables.** In byte strings and strings that the *runner* interprets (step `data`, assertion
values, regexes, event patterns), `${name}` is replaced by a variable value, and `$${` produces a
literal `${`. An unknown variable is an error. Variables:

| name | value |
|---|---|
| `port` | the port the runner's connections go to: the proxy port in `via_proxy` cases, else the server port |
| `server_port` | the conformance server's listening port |
| `proxy_port` | the proxy port (only in `via_proxy` cases) |

There is **no** substitution in the server spec (section 4 and 5): the server receives byte
strings exactly as written.

---

## 3. Server process protocol

### 3.1 Invocation

The runner starts one server process per case:

```
<server command> --config <path>
```

`<path>` is a JSON file holding the case's `server` object (sections 4 and 5), or `{}` if the case
has none. The reference server also accepts `--config-json '<json>'` and, with no arguments,
uses `{}`.

If the spec is invalid (unknown field, wrong type, value hyper would reject), the server prints a
message to stderr and exits with status 2 **without** printing `LISTENING`. The runner reports
the case as failed and shows the stderr text.

### 3.2 Startup

1. Bind a TCP listener on `127.0.0.1`, port 0 (kernel-assigned).
2. Print exactly `LISTENING <port>\n` as the first line of stdout and flush.
3. Accept connections until the process exits. Each accepted connection is served concurrently
   and independently. Connections are numbered 1, 2, 3, ... in accept order (the `conn` field of
   events).

The runner waits up to 10 s for the `LISTENING` line.

### 3.3 Stdout

After the `LISTENING` line, stdout carries only events: one JSON object per line, UTF-8, ended
with `\n`, flushed after each line (section 7). A line must be written atomically (no
interleaving between concurrent connections). Anything else goes to stderr; the runner shows
stderr only when a case fails.

### 3.4 Stdin control commands

The runner writes commands to the server's stdin, one per line:

| line | effect | acknowledgement event |
|---|---|---|
| `graceful_shutdown` | start graceful shutdown on every connection open at that moment (section 6.2). Connections accepted later are not affected. The listener keeps accepting. | `{"event":"control_ack","command":"graceful_shutdown"}` |
| `signal <name>` | set the named latch. Every waiter on that name (upgrade `await_signal`, section 6.3) is released, now and in the future. Latches never reset. | `{"event":"control_ack","command":"signal","name":"<name>"}` |
| `exit` | exit the process immediately (status 0) | none |
| anything else | ignored | `{"event":"control_error","line":"<line>"}` |

The acknowledgement must be emitted **after** the command has taken effect, that is, after
every affected connection has been notified. When the runner gets the ack it continues with the
next step. The reference server makes this ordering safe by checking for shutdown before
reading new socket data.

End of stdin means the runner is gone: exit immediately.

### 3.5 Shutdown by the runner

At the end of a case the runner closes its client sockets, writes `exit`, closes stdin, waits up to
500 ms, then kills the process. It then waits until it has read the server's stdout to its end, so the case's events include every line the server wrote before it
exited.

---

## 4. Server spec: `config`

The `server` object of a case:

```json
{
  "config":   { ... },                 // optional, section 4
  "handler":  "test_service",          // optional, section 5
  "replies":  [ { ... }, ... ],        // optional, test_service only, section 5.2
  "bytes_read_events": false,          // optional, section 7
  "comment":  "free text"              // optional, ignored
}
```

`bytes_read_events` (bool, default `false`) is a harness option, not an HTTP setting: `true` makes
the server emit a `bytes_read` event after every socket read of the HTTP layer that returns data
(section 7). It must not change anything on the wire.

Unknown fields are errors. Every `config` field is optional. Defaults are hyper v1.12.0's
`http1::Builder::new()` defaults. A field that is absent means "do not call the builder method".

| field | type | default | hyper call | semantics the server must implement |
|---|---|---|---|---|
| `keep_alive` | bool | `true` | `keep_alive(v)` | `false`: every connection is closed after the first response (HTTP/1.1 responses get `connection: close`) |
| `half_close` | bool | `false` | `half_close(v)` | `false`: while a request is in progress (handler running or response pending), a read of EOF from the client aborts the connection (handler dropped, outcome `incomplete`, no response). `true`: the server does not poll for EOF while busy and still sends the response after the client shut down its write side |
| `title_case_headers` | bool | `false` | `title_case_headers(v)` | write response header names in Title-Case (`Content-Length`) instead of lowercase |
| `preserve_header_case` | bool | `false` | `preserve_header_case(v)` | record request header name case. With hyper's public API this has no visible effect on the wire for these handlers (the case map is private). Accept and ignore is a valid implementation as long as wire behavior is unchanged |
| `max_headers` | int | 100 | `max_headers(n)` | more than `n` request header fields: 431 response, outcome `parse_too_large`. Also the limit on trailer field count |
| `max_header_size` | int | none | `max_header_size(n)` | request head (request line + header fields) larger than `n` bytes: 431, outcome `parse_too_large`. Applies to an incomplete head once the buffered head reaches `n` bytes, and to a complete head longer than `n`. Also limits trailer bytes |
| `max_buf_size` | int ≥ 8192 | 8192 + 4096·100 = 417792 | `max_buf_size(n)` | maximum read buffer. An incomplete head that fills `n` bytes: 431, outcome `parse_too_large`. Values below 8192 are a config error (hyper panics) |
| `timer` | bool | `false` | `timer(TokioTimer)` | enables timeouts. Without a timer, hyper applies no header read timeout at all |
| `header_read_timeout_ms` | int, or `null` | absent = 30000 if `timer` is true, else none | `header_read_timeout(Duration)` / `header_read_timeout(None)` | if a request head is not complete this many ms after the server starts waiting for it, close the connection **without a response**, outcome `timeout`. The timer starts when the connection is accepted and again whenever the connection goes back to waiting for a new head after a response, so it also acts as a keep-alive idle timeout. `null` disables it. A number with `timer` false is a config error (hyper panics) |
| `writev` | bool | auto | `writev(v)` | write strategy (vectored vs flattened). No wire-visible effect is required |
| `pipeline_flush` | bool | `false` | `pipeline_flush(v)` | when pipelined requests are already buffered, aggregate the responses and flush them together (pipeline_enabled expects both responses in one read) |
| `auto_date_header` | bool | `true` | `auto_date_header(v)` | `false`: do not add a `date` header |
| `ignore_invalid_headers` | bool | `false` | `ignore_invalid_headers(v)` | silently skip malformed request header lines instead of answering 400 |
| `allow_multiple_spaces_in_request_line_delimiters` | bool | `false` | same name | accept several spaces between request-line elements |
| `conn_mode` | `"plain"` \| `"with_upgrades"` \| `"without_shutdown"` | `"plain"` | section 6.1 | how the connection is driven |
| `graceful_shutdown_on_accept` | bool | `false` | `graceful_shutdown()` before the first poll | start graceful shutdown on every connection right after accept (section 6.2) |

---

## 5. Server spec: handlers and replies

### 5.1 Handlers

`handler` is one of:

| handler | hyper origin | behavior |
|---|---|---|
| `"test_service"` (default) | tests/server.rs `TestService` (L3765-3818), the t! macro server (tests/support/mod.rs L362-389), and the per-test `service_fn`s | takes the next reply from the reply queue and acts on it (5.3) |
| `"hello_world"` | tests/server.rs `HelloWorld` (L3822-3833) | responds 200 with a fixed-length body `hello` (5 bytes). Never reads the request body. `replies` must be empty |
| `"unreachable"` | tests/server.rs `unreachable_service` (L3835-3842) | the handler fails immediately (no response; outcome `user`). `replies` must be empty |

For every handler, each call emits `request` when it starts and exactly one of `handler_done` or
`handler_dropped` (section 7).

### 5.2 The reply queue

`replies` is a list of reply objects. It is **one queue per server process, shared by all
connections**. Each `test_service` call removes the first reply at the moment the handler is
called (when the request head has been parsed). If the queue is empty, the call uses the default
reply `{}`. hyper's ReplyBuilder queue behaves the same way when, as in all ported tests, the
replies are queued before the requests arrive.

### 5.3 Reply object

All fields are optional. `{}` is the default reply: status 200, no headers, empty body.

| field | type | default | meaning |
|---|---|---|---|
| `status` | int 100..999 | 200 | response status code. A 1xx status as the final response is passed to the HTTP layer unchanged (hyper then sends a 500 and fails the connection: outcome `user`) |
| `reason` | byte string | standard phrase | custom reason phrase (hyper `ext::ReasonPhrase`). Must be valid reason-phrase bytes (HTAB, SP, VCHAR, obs-text) |
| `version` | `"HTTP/1.0"` \| `"HTTP/1.1"` \| `"HTTP/2.0"` \| `"HTTP/0.9"` \| `"HTTP/3.0"` | `"HTTP/1.1"` | the response version the handler sets. In hyper, `HTTP/1.0` without a `connection: keep-alive` header makes the connection close after this response (http_10_close_on_no_ka). The Pascal server maps this to its own way of saying "this response is HTTP/1.0" |
| `headers` | array of `[name, value]` byte-string pairs | `[]` | response header fields, applied in order with **insert** semantics: an entry whose name (case-insensitive) already appeared replaces that earlier value and keeps the earlier position. Names are case-insensitive tokens; the HTTP layer decides the written case (hyper writes lowercase). The resulting order is the order the handler hands to the HTTP layer |
| `body` | body spec (5.4) | empty | response body |
| `error` | string | none | after reading the body and the delay, the handler fails with this message instead of responding (hyper `Reply::Error`): no response is written for this request, outcome `user` |
| `read_body` | bool | `true` | `true`: read the whole request body before responding and emit `request_body` / `request_body_error`. `false`: drop the request body without reading any of it (no 100 Continue is ever triggered, expect_continue_waits_for_body_poll) |
| `delay_ms` | int | 0 | sleep this many ms after the body step and before failing (`error`) or responding |
| `upgrade` | upgrade spec (6.3) | none | take over the connection after the response |
| `comment` | any | | ignored |

### 5.4 Body spec

| form | hyper equivalent | meaning |
|---|---|---|
| absent | `http_body_util::Empty` | empty body whose length is known to be 0 |
| `{"known": <byte string>}` | `Full::new(bytes)` | body with a length known in advance (exact size hint). An empty `known` body behaves like an absent body |
| `{"stream": [items], "trailers": [[name, value], ...]}` | `StreamBody` / tests' `StreamBodyWithTrailers` | body of **unknown** length (no size hint), produced as a sequence of frames |

Stream items, in order:

- `{"data": <byte string>, "delay_ms": <n>, "times": <k>}`: wait `delay_ms` (default 0) and then
  yield one data frame; `times` (default 1) repeats the item `k` times (each repetition waits
  `delay_ms` again). Each data frame is handed to the HTTP layer separately (hyper writes one
  chunk per frame when chunked).
- `{"error": "<message>", "delay_ms": <n>}`: wait, then the body fails with that message (the
  HTTP layer aborts the response).

After the last item, if `trailers` is present, a trailers frame is yielded, built with insert
semantics like `headers`. Which trailer fields reach the wire is the HTTP layer's decision
(hyper: only when the request had `TE: trailers`, only fields named in the `trailer` response
header, never forbidden fields such as `host`).

Without delays, every frame is available immediately (the first poll returns it).

### 5.5 test_service call sequence

For each request, in this order:

1. Emit `request` (section 7). Assign `req` = 1, 2, ... per connection.
2. Take the next reply (5.2).
3. If the reply has `upgrade` with `on_upgrade` true, register for the upgrade now (hyper
   `upgrade::on(&mut req)`), before the request is released.
4. If `read_body` is true: read the request body to the end, collecting data and trailers.
   - On success emit `request_body` (with `trailers` when the request had any).
   - On a body error emit `request_body_error` and fail the handler with message
     `req body error`. Stop here: no response for this request.
5. Release the request (drop it, including any unread body).
6. If `delay_ms` > 0, sleep.
7. If `error` is set, fail the handler with that message. Stop.
8. If `upgrade` is set: with `on_upgrade` true, start the upgrade task (6.3); with `on_upgrade`
   false, remember the spec for the `without_shutdown` hand-off (6.1).
9. Return the response: status, reason, version, headers (5.3), body (5.4).

When the handler fails (steps 4 or 7), the HTTP layer writes nothing for that request and the
connection ends with outcome `user`.

---

## 6. Connection modes, graceful shutdown, upgrades

### 6.1 `conn_mode`

| value | hyper call | meaning |
|---|---|---|
| `plain` | `serve_connection(io, svc).await` | upgrades are not supported. The connection ends when the HTTP layer is done |
| `with_upgrades` | `serve_connection(io, svc).with_upgrades().await` | after a 101 response (or a 2xx response to CONNECT) to a request whose handler registered with `on_upgrade`, the HTTP layer hands the connection to the upgrade task, together with the bytes it had already read past the request head. The connection outcome is `ok` |
| `without_shutdown` | `serve_connection(io, svc).without_shutdown().await` | the connection is driven to completion without shutting down the socket. After a 101 / CONNECT-2xx response the HTTP layer stops and returns the socket plus its unread buffered bytes (hyper `Parts { io, read_buf }`). If the request's reply had `upgrade` with `on_upgrade` false, the upgrade actions (6.3) then run on that socket |

`conn_close` is emitted when the HTTP layer finishes, **before** any upgrade actions run.

### 6.2 Graceful shutdown

Triggered by the `graceful_shutdown` control command or `graceful_shutdown_on_accept`. Semantics
(hyper `Connection::graceful_shutdown`, `Dispatcher::disable_keep_alive`):

- If the connection has read no bytes yet and has written nothing (or if the connection is idle
  between requests with nothing buffered): close it now. Outcome `ok`, no bytes written.
- Otherwise (a request head is partly or fully received, or a request is in progress): disable
  keep-alive. The current request is completed normally, its response carries
  `connection: close` (HTTP/1.1), and the connection then closes. Outcome `ok`.
- After an upgrade hand-off, graceful shutdown has no effect.

### 6.3 Upgrade spec

```json
"upgrade": {"on_upgrade": true, "await_signal": "read_101", "write": "foo=bar", "read_to_eof": true}
```

| field | type | default | meaning |
|---|---|---|---|
| `on_upgrade` | bool | `true` | `true`: the handler registers for the upgrade (hyper `upgrade::on`), and the actions run when the HTTP layer hands over the connection (`conn_mode` `with_upgrades`). `false`: the handler does not register; the actions run on the socket returned by `without_shutdown` |
| `await_signal` | string | none | before writing, wait until the runner sends `signal <name>` (stands in for the oneshot channels hyper's tests use to wait until the client has read the 101) |
| `write` | byte string | none | write these bytes on the raw socket |
| `read_to_eof` | bool | `true` | then read from the raw socket until EOF |

Upgrade task, in order: emit `upgraded` with the hand-over bytes (`read_buf`); wait for the
signal; write; read to EOF and emit `upgrade_read`; close the socket. Errors emit
`upgrade_error` and close.

---

## 7. Server events

Every event is a JSON object with an `event` field. `conn` is the connection number (3.2), `req`
the per-connection request number (5.5). Byte-string fields use the latin-1 mapping (section 2).
Fields named `message` and `detail` are implementation-specific text: they are reported, they are
ignored in diff mode, and a case may assert on them only where this table gives canonical text.

| event | fields | emitted when |
|---|---|---|
| `conn_open` | `conn` | a connection is accepted, before anything is read |
| `request` | `conn`, `req`, `method`, `target`, `version`, `headers` | the handler is called (request head parsed). `method`: method token. `target`: the request-target as received (origin-form `/a?b`, absolute-form `http://h:p/`, authority-form `localhost:80`, `*`). `version`: `"HTTP/1.0"` or `"HTTP/1.1"`. `headers`: array of `[name, value]`, names **lowercased**, values as received (OWS trimmed), ordered by **first appearance of each name**, all values of a name together in received order (http::HeaderMap iteration order; example: `A:1, B:2, a:3` is reported as `[["a","1"],["a","3"],["b","2"]]`) |
| `request_body` | `conn`, `req`, `body`, optional `trailers` | test_service read the whole body. `body`: all data bytes. `trailers`: present only if the request had a trailer section; same format as `headers` |
| `request_body_error` | `conn`, `req`, `kind`, `message` | reading the body failed (table 7.1) |
| `handler_done` | `conn`, `req`, `result`, then `status` (if `result` is `"response"`) or `message` (if `"error"`) | the handler finished and handed a response, or a failure, to the HTTP layer |
| `handler_dropped` | `conn`, `req` | the HTTP layer abandoned the handler before it finished (for example the client disconnected while the handler slept). Emitted before that connection's `conn_close` |
| `conn_close` | `conn`, `outcome`, optional `detail` | the HTTP layer finished with the connection. `outcome` (table 7.2) |
| `bytes_read` | `conn`, `total` | only when the server spec sets `bytes_read_events`. Emitted after each socket read by the HTTP layer that returns at least one byte, after the bytes are in the HTTP layer's read buffer and before the HTTP layer parses them. `total`: bytes read from this connection's socket so far, counting this read. Reads of EOF, errors and reads that would block emit nothing. Reads done by the upgrade task after the hand-off (6.3) are not counted. A case uses it to wait until the server holds a given prefix of the input, e.g. `{"event":"bytes_read","conn":1,"total":16}`; because nothing more is sent until the wait ends, an event with exactly that total is emitted however the server splits its reads |
| `upgraded` | `conn`, `read_buf` | upgrade hand-off. `read_buf`: bytes the HTTP layer had read past the request head |
| `upgrade_read` | `conn`, `data`, `end` | the upgrade task read to EOF. `end`: `"eof"`, or `"error"` (then also `message`) |
| `upgrade_error` | `conn`, `message` | the upgrade task failed |
| `control_ack` | `command`, optional `name` | section 3.4 |
| `control_error` | `line` | section 3.4 |

Ordering: events of one connection appear in the order they happen. Events of different
connections may interleave.

A `graceful_shutdown` sent after a `bytes_read` event has been seen must find those bytes
already buffered (section 6.2: the connection is "partly received", not "read no bytes yet").
The reference server guarantees this because the read, the event and the buffering happen in one
poll of the connection task, and that task checks for shutdown before its next poll.

### 7.1 `request_body_error.kind` and canonical `message`

These are hyper's body-decoder errors (src/proto/h1/decode.rs). `kind` comes from the
`io::ErrorKind`. A conformance server must use the same `kind` and should use the same
`message` for the same condition.

| kind | message | condition |
|---|---|---|
| `unexpected_eof` | `end of file before message length reached` | EOF before Content-Length bytes, or inside chunk data |
| `unexpected_eof` | `unexpected EOF during chunk size line` | EOF while reading a chunk-size line |
| `invalid_data` | `invalid chunk size: overflow` | chunk size does not fit in 64 bits |
| `invalid_data` | `chunk trailers bytes over limit` | trailer section larger than the limit (`max_header_size`, default 16 KiB in hyper) |
| `invalid_data` | `chunk trailers count overflow` | more trailer fields than `max_headers` |
| `invalid_data` | `invalid chunk extension contains newline` | bare LF inside a chunk extension |
| `invalid_data` | `chunk extensions over limit` | more than 16 KiB of chunk-extension bytes in one body |
| `invalid_input` | `Invalid chunk size line: missing size digit` | size line with no hex digit |
| `invalid_input` | `Invalid chunk size line: Invalid Size` | bad byte inside the size digits |
| `invalid_input` | `Invalid chunk size linear white space` | bad byte after whitespace following the size |
| `invalid_input` | `Invalid chunk size LF` | CR not followed by LF after the size line |
| `invalid_input` | `Invalid chunk body CR` / `Invalid chunk body LF` | chunk data not followed by CRLF |
| `invalid_input` | `Invalid chunk end LF` / `Invalid trailer end LF` | bad final CRLF |
| `invalid_input` | `Invalid header name: ...` / `Invalid header value: ...` / `Partial header` / httparse error text | malformed trailer field |
| `io` | OS error text | socket error while reading the body |
| `other` | error text | anything else |

### 7.2 `conn_close.outcome`

Exactly one class, checked in this order (hyper `Error` predicates):

| outcome | hyper predicate | when |
|---|---|---|
| `ok` | `Ok(())` | the connection ended without error: client EOF while idle, keep-alive off after a response, graceful shutdown, upgrade hand-off |
| `timeout` | `is_timeout()` | header read timeout fired (no response written) |
| `parse_too_large` | `is_parse_too_large()` | request head over `max_buf_size` / `max_header_size`, too many headers, a header name of 65536 bytes or more (431 written), or a request-target longer than 65534 bytes (414 written) |
| `parse_version_h2` | `is_parse_version_h2()` | the HTTP/2 connection preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` arrived on the HTTP/1 connection (nothing written) |
| `parse` | `is_parse()` | any other request-head parse error: method, request-target, version, header syntax, invalid Content-Length or Transfer-Encoding (400 written) |
| `incomplete` | `is_incomplete_message()` | EOF in the middle of a request head, or EOF while a request was in progress with `half_close` false |
| `user` | `is_user()` | the handler failed (including test_service body errors), or the handler returned a 1xx final status (hyper writes a 500) |
| `canceled`, `closed`, `body_write_aborted`, `shutdown` | the matching predicate | rare internal cases |
| `io` | source is an `io::Error` | socket error; in bearings also a request body error (malformed framing, a socket error, the body rate rule) after the handler answered, where hyper reports `ok` (docs/design.md section 10) |
| `other` | none of the above | |

---

## 8. Case files

A case file is a JSON object:

```json
{
  "description": "free text",
  "cases": [ <case>, ... ]
}
```

Case names must be unique within a file. Case fields (unknown fields are errors):

| field | required | meaning |
|---|---|---|
| `name` | yes | hyper test name, e.g. `response_body_lengths::fixed_response_known`, `get_1 [run1 h1 direct]` |
| `source` | no | `file:line` of the hyper test |
| `notes` / `comment` | no | free text: what hyper asserts, which assertions were unenforced, port decisions |
| `pending` | no | a string (or any non-false value): the case is skipped and counted as pending. Use it for tests that are `#[ignore]` upstream or that the harness cannot express yet |
| `server` | no | server spec (sections 4, 5); default `{}` |
| `via_proxy` | no | `"h1"`: the runner starts an in-process HTTP/1 proxy equivalent to hyper's `naive_proxy` (tests/support/mod.rs L493-593) in front of the server, and all `connect` steps go to the proxy. Used for the integration.rs "via proxy" runs. The proxy serves one client connection at a time; for each request it rewrites the URI to `http://127.0.0.1:<server_port><path>` (the query is dropped), sends it upstream on a new connection with hyper's http1 client, removes `Connection` from the response, and streams the body back |
| `steps` | yes | array of steps (section 9), executed in order |
| `expect_events` | no | event patterns that must all match, **in order** (section 11) |
| `forbid_events` | no | event patterns that must match no event |
| `events_timeout_ms` | no | how long to wait for `expect_events` after the last step; default 1000 |
| `events_settle_ms` | no | wait before checking `forbid_events`; default 200 |

Case execution:

1. Start the server (3.1). Start the proxy if `via_proxy`.
2. Run the steps in order. In `run` mode, the first failing step ends the case (failed).
3. Wait until all `expect_events` match in order, up to `events_timeout_ms`.
4. If `forbid_events` is non-empty, sleep `events_settle_ms`, then check every event received so
   far against every forbidden pattern.
5. If the server process exited on its own during the case, the case fails.
6. Close client sockets, stop the server (3.5).

---

## 9. Steps

Every step is an object with `op`. Common optional fields on every step:

- `conn`: connection name, default `"main"`. Several named connections may be open at once.
- `mark`: a name. The instant the step finishes is recorded under that name (for `timing`).
- `comment`: ignored.

Unknown fields are errors.

### 9.1 Connection and write steps

| op | fields | semantics |
|---|---|---|
| `connect` | `nodelay` (bool, default false) | open a TCP connection to `127.0.0.1:${port}` (5 s connect timeout). Records the mark `connect:<conn>`. Nagle is left on by default, as with std `TcpStream` in hyper's tests |
| `write` | `data` (byte string), `timeout_ms` (default 1000), `may_fail`, `expect_fail` (bools) | write all bytes (write timeout = `timeout_ms`, like the tests' 1 s `set_write_timeout`). A failed write fails the step unless `may_fail`. With `expect_fail`, the step fails if the write succeeds. On Linux the first write after the peer closed usually succeeds, so `expect_fail` is rarely reliable |
| `sleep` | `ms` | sleep |
| `shutdown_write` | | `shutdown(SHUT_WR)`: send FIN, keep reading |
| `close` | | close the socket (drop). Unread received data makes the kernel send RST. Mirrors a hyper client thread that ends and drops its TcpStream |
| `control` | `command`: `"graceful_shutdown"` or `"signal"` (+ `name`) | send the control line (3.4) and wait up to 2 s for its `control_ack` |
| `await_event` | `match` (pattern), `timeout_ms` (default 1000) | wait until an event matching the pattern arrives. Each `await_event` searches only events after the one the previous `await_event` matched |

### 9.2 Read steps

Each connection keeps a buffer of bytes received but not yet consumed by a step. A read step
first consumes from that buffer, then reads from the socket. **`timeout_ms` (default 1000) is a
per-read inactivity timeout**: each socket read waits at most that long, like the tests'
`set_read_timeout(1 s)`. A read that times out fails the step unless the op says otherwise. After
the peer's FIN or RST, the connection's end state is sticky (`eof` or `reset`).

Common read-step fields: `timeout_ms`; `allow_reset` (bool, default false: an RST fails the step;
true: RST ends the step like EOF, end state `reset`); `expect` (array of assertions, section 10);
`timing` (section 13); `diff_capture` (bool, default true; `false`: diff mode does not compare this
step's capture, section 12). The bytes a read step consumed are its **capture**.

| op | fields | semantics | step completes |
|---|---|---|---|
| `read_once` | `max` (default 4096), `allow_timeout` (bool, default false) | one `read()`: if the buffer has bytes, take up to `max` of them without reading the socket; otherwise one socket read, then take up to `max`. EOF gives an empty capture with end `eof` (not a failure). A timeout fails the step unless `allow_timeout` is true; then the step succeeds with an empty capture and end `open`. The step's **read result** (assertion `read_result`) is `"data"` if the capture is non-empty, else `"timeout"`, `"reset"` or `"eof"`. Mirrors `stream.read(&mut [0; max])`; `allow_timeout` + `allow_reset` + `{"read_result": ["data", "timeout", "reset"]}` mirrors `if let Ok(n) = stream.read(..) { assert_ne!(n, 0) }` | when the read returns or times out |
| `read_exact` | `len` | read exactly `len` bytes; EOF earlier fails. Mirrors `read_exact` | when `len` bytes are there |
| `read_until` | `until`: exactly one of `{"ends_with": b}`, `{"contains": b}`, `{"starts_with": b}`, `{"min_len": n}`; `max` (default 8192) | read until the (date-normalized) capture satisfies `until`. Fails on EOF, RST, timeout, or when `max` bytes have been captured without a match. The capture may extend past the match point (everything read so far). Mirrors server.rs `read_until` with its 8192-byte buffer | when the condition first holds |
| `read_to_eof` | `max` (default 64 MiB), `deadline_ms` (optional total limit) | read until EOF (or RST with `allow_reset`). Mirrors `read_to_end` / `read_to_string` | when EOF / RST is observed |
| `read_response` | `method` (set `"HEAD"` for a response to HEAD) | read exactly one HTTP/1.x response and leave any following bytes in the buffer. Framing per RFC 9112 6.3: no body if the request was HEAD or the status is 1xx, 204 or 304; else chunked if the last transfer-coding is `chunked` (trailers are parsed); else Content-Length; else read to EOF. A 1xx response is returned on its own; use another `read_response` for the final response | when the response is complete |
| `expect_open` | `for_ms`, `diff_capture` | keep reading for `for_ms`; fails if EOF or RST arrives in that window. Bytes received are captured (and can be asserted). Mirrors "a read within 1 s must not return 0" | after `for_ms` |

---

## 10. Assertions

`expect` is an array of assertion objects, checked in order against the step's capture. Each
assertion has exactly one **kind** key, plus optional modifiers.

### 10.1 Byte assertions

| kind | value | passes when the subject... |
|---|---|---|
| `equals` | byte string | is exactly the value |
| `starts_with` | byte string | starts with the value |
| `ends_with` | byte string | ends with the value |
| `contains` | byte string | contains the value |
| `not_contains` | byte string | does not contain the value |
| `regex` / `not_regex` | regex string | does / does not match (Rust `regex::bytes`, Unicode off, so `.` is any byte except `\n`; use `(?s)` for any byte; `\A` / `\z` anchor the whole subject) |
| `len` / `min_len` / `max_len` | int | has exactly / at least / at most this many bytes |

Modifiers:

- `scope`: what the subject is.
  - `"all"` (default): the whole capture.
  - `"head"`: the capture up to, not including, the first `\r\n\r\n` (the whole capture if there is
    none). This is hyper's `has_header` region.
  - `"after_head"`: the bytes after the first `\r\n\r\n` (empty if there is none).
  - `"body"`: the decoded body (`read_response` only).
- `ci`: ASCII case-insensitive comparison (byte kinds and regex).
- `raw`: use the capture before date normalization (section 12).

### 10.2 Other assertions

| kind | value | passes when |
|---|---|---|
| `end` | `"eof"`, `"reset"`, `"open"`, `"closed"` (eof or reset) | the connection end state after the step |
| `read_result` | one of `"data"`, `"eof"`, `"reset"`, `"timeout"`, or a non-empty array of them | (`read_once`) the step's read result (9.2) is the value or one of the array's values |
| `status` | int | (`read_response`) status code |
| `reason` | byte string | (`read_response`) reason phrase |
| `version` | string, e.g. `"HTTP/1.1"` | (`read_response`) status-line version |
| `framing` | `"none"`, `"content-length"`, `"chunked"`, `"close"` | (`read_response`) how the body was delimited |
| `body` | byte string | (`read_response`) decoded body equals |
| `header` | field name | (`read_response`) with one or more of: `"value": b` (the first field with that name, case-insensitive, equals `b`; like `HeaderMap::get`), `"values": [b, ...]` (all values in order), `"present": bool`, `"count": n` |
| `trailer` | field name | same as `header`, on the trailer section |

---

## 11. Event patterns

`expect_events`, `forbid_events` and `await_event` use patterns matched against event objects:

- an object pattern matches an object that has every listed field with a matching value; other
  fields are ignored;
- a string matches an equal string (after `${var}` substitution);
- an array matches an array of the same length, element by element;
- numbers, booleans and null match equal values;
- an object with a single key starting with `$` is an operator:
  - `{"$absent": true}`: the field must be missing;
  - `{"$any": true}`: the field must be present;
  - `{"$not": p}`: does not match `p`;
  - `{"$bytes": <byte string>}`: string equal to the latin-1 form of the byte string (for long or
    binary values, e.g. `{"$bytes": [{"repeat": "x", "count": 100000}]}`);
  - `{"$contains": <byte string>}`: string containing it;
  - `{"$regex": "..."}`: string matching the (Unicode) regex;
  - `{"$includes": [p, ...]}`: an array in which every `p` matches some element (any order).
    Example: `{"event":"request","headers":{"$includes":[["expect","100-continue"]]}}`.

`expect_events` is matched in order: pattern *k+1* must match an event that comes after the event
pattern *k* matched.

---

## 12. Normalization and diff mode

**Date normalization.** Before assertions and transcripts, every match of

```
(?i)(\r\ndate:[ \t]*)(Mon|Tue|Wed|Thu|Fri|Sat|Sun), DD (Jan|...|Dec) YYYY HH:MM:SS GMT
```

in a capture has its date value replaced by `Sun, 06 Nov 1994 08:49:37 GMT` (same length, 29
bytes, so length assertions keep working). Only valid IMF-fixdate values after a `date` field name
at the start of a line are replaced; other values (e.g. `date: let me through`) are left as is.
`read_until` conditions are evaluated on the normalized capture. Header values in `read_response`
assertions are not normalized.

**Transcript.** In both modes the runner records one entry per executed step: `step` (index),
`op`, `conn`, and for read steps `received` (normalized capture as a latin-1 string), `end`, plus
`read_result` for `read_once`, `status`, `body`, `framing` for `read_response`, and
`"diff_capture": false` when the step sets it; for writes `bytes` and `result` (`ok` / `error`);
for `await_event` the matched `event`; and `error` if the step failed.

**Diff mode** (`runner diff --a A --b B`) runs every non-pending case against A and then against
B. Both runs execute **all** steps (a failing step is recorded and the next step runs). Two runs
are the SAME when:

1. the transcripts are equal entry by entry, where an entry marked `"diff_capture": false` is
   compared without its `received`, `end`, `read_result`, `status`, `body` and `framing` fields
   (so only `step`, `op`, `conn` and `error` are compared), and
2. the event lists are equal after (a) removing `bytes_read` events (how a server splits its
   socket reads is implementation-specific), (b) removing `message` and `detail` fields, (c)
   grouping by `conn` (order kept within a connection; events without `conn` form their own group).

Before comparison, `127.0.0.1:<server_port>` and `127.0.0.1:<proxy_port>` are replaced by
`127.0.0.1:${server_port}` / `127.0.0.1:${proxy_port}` in all strings, so that different port
numbers do not count as differences. The assertion-failure count of each side is printed for
information only.

Diff mode compares exact read boundaries. `read_once` captures depend on how the server
splits its writes, so cases meant for diffing should prefer `read_until`, `read_exact`,
`read_response` and `read_to_eof`. A case that must mirror a hyper test's single `read()` calls
whose results depend on write batching (pipeline_disabled) sets `"diff_capture": false` on those
steps: run mode still checks their assertions, and diff mode still reports a step that fails on
one side only (the `error` field differs).

---

## 13. Timing

Defaults, chosen to mirror hyper's tests:

| item | value | origin |
|---|---|---|
| per-read timeout | 1000 ms | `connect()` sets `set_read_timeout(1 s)`, tests/server.rs L3844-3849 |
| write timeout | 1000 ms | same, `set_write_timeout(1 s)` |
| `read_until` buffer | 8192 bytes | tests/server.rs `read_until` L3992-4016 |
| control ack wait | 2000 ms | harness |
| `expect_events` wait | 1000 ms (`events_timeout_ms`) | harness |
| `forbid_events` settle | 200 ms (`events_settle_ms`) | harness |
| `LISTENING` wait | 10 s | harness |
| server stop | 500 ms, then kill | harness |

**`timing` assertion** on a read step:

```json
"timing": {"since": "connect", "min_ms": 1500, "max_ms": 2600}
```

checks the instant the step completed (table 9.2), measured from `since`:

- `"step"` (default): the start of this step;
- `"connect"`: the `connect` of this step's connection;
- `"case"`: the start of the case;
- any other string: a `mark` set by an earlier step.

hyper's tests contain almost no timing assertions; they rely on the 1 s read timeout. When a case
adds a timing window (for example to check that a header-read timeout fires near its configured
value), use a lower bound of about 85 % of the nominal value and an upper bound of nominal plus
500 ms, and say in `notes` that the window is a port decision, not a hyper assertion.

---

## 14. Porting hyper tests to cases

| hyper construct | case equivalent |
|---|---|
| `serve()` / `serve_opts()` fixture | `"handler": "test_service"` with `config` from `ServeOptions` (`keep_alive`, `pipeline_flush`). `serve_opts().http2()` is out of scope (HTTP/2) |
| `server.reply().status(..).header(..).body(..)` | one entry in `replies`, in the order the test queues them |
| `.body_stream(stream::once(..))` | `{"stream": [{"data": ...}]}` |
| `.body_stream_with_trailers(s, headers)` | `{"stream": [...], "trailers": [...]}` |
| `.version(Version::HTTP_10)` / `.reason_phrase("Cool")` | `"version": "HTTP/1.0"` / `"reason": "Cool"` |
| `HelloWorld` / `unreachable_service()` | `"handler": "hello_world"` / `"unreachable"` |
| a custom `service_fn` | `test_service` with a reply using `read_body`, `delay_ms`, `status`, `error`, `upgrade` |
| `http1::Builder::new().xxx(..)` | `config.xxx` |
| `.timer(TokioTimer)` | `"timer": true` |
| `.with_upgrades()` / `.without_shutdown()` | `"conn_mode": "with_upgrades"` / `"without_shutdown"` |
| `connect(addr)` | `{"op":"connect"}` |
| `write_all(b)` | `{"op":"write","data":b}` |
| `req.read(&mut [0; N])` | `{"op":"read_once","max":N}` |
| `if let Ok(n) = req.read(&mut [0; N]) { assert_ne!(n, 0) }` | `{"op":"read_once","max":N,"allow_timeout":true,"allow_reset":true,"expect":[{"read_result":["data","timeout","reset"]}]}` |
| `read_exact` | `read_exact` |
| `read_until(&mut req, \|buf\| buf.ends_with(x))` | `{"op":"read_until","until":{"ends_with":x}}` |
| `read_to_end` / `read_to_string` | `read_to_eof` |
| `shutdown(Shutdown::Write)` | `shutdown_write` |
| client thread ends (stream dropped) | `close` |
| `thread::sleep(d)` | `sleep` |
| `has_header(&s, "x")` | `{"scope":"head","contains":"x"}` |
| text after the first blank line is empty (`lines.skip_while(..)`) | `{"scope":"after_head","len":0}` |
| `server.body()` == x | `expect_events: [{"event":"request_body","body":x}]` |
| `server.body_err()` (+ message check) | `{"event":"request_body_error","message":{"$contains":"overflow"}}` |
| `server.trailers()` | `{"event":"request_body","trailers":[...]}` |
| assertions inside a service fn (`req.headers()["expect"] == ..`) | pattern on the `request` event, e.g. `$includes` |
| `serve_connection(..).await` Ok / Err / `is_timeout()` | `{"event":"conn_close","outcome":"ok"}` / the matching outcome class |
| "response future should have been dropped" | `{"event":"handler_dropped"}` plus `forbid_events: [{"event":"handler_done"}]` |
| oneshot "client has read the 101" | `control` `signal` + upgrade `await_signal` |
| `conn.graceful_shutdown()` | `control` `graceful_shutdown`, or `graceful_shutdown_on_accept` |
| the server has polled (read) the first `n` bytes before the test acts | `"bytes_read_events": true` in the server spec + `{"op":"await_event","match":{"event":"bytes_read","conn":1,"total":n}}` |
| `parts.read_buf` / upgraded IO `read_to_end` | `upgraded.read_buf` / `upgrade_read.data` events |
| t! macro (integration.rs) | `test_service` with one reply per message; the request bytes the hyper h1 client sends: absolute-form `GET http://127.0.0.1:${port}/path HTTP/1.1`, no Host header, `content-length` only for non-empty bodies; `[run3 h1 via proxy]` adds `"via_proxy": "h1"` |
| `#[ignore]` | `"pending": "#[ignore] upstream: <reason>"` |

**Encoding rules.**

- Encode what the hyper test asserts, and nothing more.
- Where the catalog notes that a client-thread assertion is not enforced (the thread is never
  joined), encode the intended assertion anyway, confirm it passes against the reference
  server, and say so in `notes`.
- Where a hyper assertion is a literal case-sensitive substring check of a header name (e.g.
  `has_header(.., "content-length")`), the case may add `"ci": true` to check the intent. Record
  this in `notes`.
- Use `"source": "tests/server.rs:<line>"` and the exact catalog name.

---

## 15. Known limitations

- **Request header case.** hyper's public API does not expose the original case of request header
  names (the case map is a private extension), so `request.headers` reports names lowercased and
  grouped by name (section 7). The original received order across different names is not
  recoverable when a name repeats non-adjacently.
- **HTTP/2.** Out of scope for this milestone. Only `http1_only` touches HTTP/2, by sending the
  preface bytes to an HTTP/1 server.
- **Timing-dependent reads.** `read_once` mirrors hyper's single `read()` calls, so its capture
  depends on how the server's writes are batched. hyper's `pipeline_disabled` comments on this
  race. Such steps set `"diff_capture": false` (section 12).
- **`read_once` errors other than timeout and RST** (for example `EHOSTUNREACH`) always fail the
  step. hyper's `if let Ok(..) = read(..)` would accept them. They do not occur on loopback in
  practice.
- **RST on close.** When a server closes a socket with unread request bytes, Linux sends RST. Data
  that arrived before the RST is still readable. Cases where hyper closes with unread input
  (e.g. `max_buf_size`) should set `allow_reset` on the read steps that may see the RST.
