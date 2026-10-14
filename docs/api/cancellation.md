# 8. Cancellation, keep-alive and pipelining

**Cancellation.** When the client disconnects, the connection fails, or
the server's shutdown deadline passes while a call is in flight, the
connection cancels the exchange and calls `Drop(Ex, False)`. From then on:
terminal calls return False and send nothing (their body is released);
`TryRead` returns `brCanceled`; the blocking reads raise `EClientGone`;
stream writes return `wrCanceled`; a worker parked in a body read or a
full-queue write is woken. A long-running handler that is not in a body
call checks `IsCanceled` now and then. Nothing is sent to a client that is
gone, so a handler may simply return.

**Keep-alive.** With `TH1Config.KeepAlive` (the default), an HTTP/1.1
connection stays open after a response unless either side sent
`Connection: close`; an HTTP/1.0 connection stays open only when the client
sent `Connection: keep-alive`. Each request on the connection is a new
call on the same (unshared) exchange object; `RequestNo` counts them (1, 2,
...) and `ConnId` identifies the connection (unique per server).

**Pipelining.** A client may send several requests without waiting for
the responses. The connection keeps **one call in flight at a time**: the
next pipelined request stays unparsed in the read buffer until the
current call completed, and responses go out in request order. So a slow
handler delays the later requests of its own connection, not those of
other connections. With `PipelineFlush`, responses to pipelined requests
are held while another request is already buffered, so several leave in
one write.

**Idle connections.** The header read timeout (`HeaderReadTimeout`, 30 s
with `ProductionH1Config`) closes a connection whose client does not send
a complete request head in time; this also bounds idle keep-alive
connections. Without a timer (`Timer = False`) nothing times out.
