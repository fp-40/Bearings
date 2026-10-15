# 5. Response bodies

## A body of known length: Respond(Body)

`Respond(const Body: TBodyData): Boolean` sends the head and the body with
a `Content-Length` (the encoder writes it; the application does not).
`TBodyData` (unit `bearings.rt.buf`) is a plain record built by one of:

Constructor | Memory / file | Who releases it, and how
----------- | ------------- | ------------------------
`BodyEmpty` | no bytes | nothing
`BodyStatic(P, Len)` | memory that outlives the write (a constant, a global) | nothing
`BodyString(S)` | the bytes of a `RawByteString`, no copy | one reference to `S` is held until the bytes were written, then dropped
`BodyHeap(P, Len)` | memory from `GetMem` | `FreeMem(P)` after the write; the server owns `P` from the call on
`BodyCopy(Ex, P, Len)` (unit `bearings.http.exchange`) | a copy of `P^` in a block from the loop's pool (on the loop thread) or the heap (elsewhere) | the block goes back after the write
`BodyFile(Fd, Offset, Len, CloseAfter)` | `Len` bytes of the open file `Fd` from `Offset`, sent with `sendfile(2)` | `Fd` is closed after the last byte when `CloseAfter`; also when the connection dies before that

`TBodyData` values may be built on any thread; the release
(`ReleaseBody`) runs on the loop thread after the bytes were written. If
`Respond` returns False (the exchange was canceled or already answered),
the body is released at once; the response is not sent.

A `TBodyOwnership` of `boCustom` with a `ReleaseProc(Ctx, Data)` exists in
the record for other arrangements; no constructor builds it.

For a response to a HEAD request, a 1xx, 204 or 304 status, or a 2xx to
CONNECT, no body bytes go on the wire; for HEAD the `Content-Length` the
body would have had is kept in the head.

## A text with a status: RespondText

`RespondText(Status, Text, ContentType = 'text/plain; charset=utf-8'):
Boolean` is `Respond(BodyString(Text))` with the status and the
`Content-Type` header set first: it assigns `Status`, sets the header with
`ResponseHeaders.Insert` (one `Content-Type` entry, the value validated:
`EInvalidHeader` on a bad value, and the exchange stays unanswered), then
responds. It returns False, and touches neither the head nor the body,
when the exchange is canceled or already answered. It is for error
answers and the worker path (`examples/worker.pas`, `examples/stream.pas`):
it builds a string reference per call, so the inline fast path keeps
`BodyStatic` (section 13).

## A body of unknown length: BeginStream, Write, Finish

`BeginStream(HighWater = 65536): Boolean` is the terminal call for a body
produced piece by piece. The head goes out at once with
`Transfer-Encoding: chunked` (HTTP/1.1) or without framing, closing the
connection at the end (HTTP/1.0). Then, from any thread holding the
exchange:

- `Write(P, Len): TWriteResult` queues a copy of the bytes as one chunk.
  Off the loop thread it parks while about `HighWater` bytes are queued,
  so a slow client slows the producer down instead of making the server
  buffer everything. On the loop thread it cannot park and returns
  `wrWouldBlock` when the queue is full.
- `TryWrite(P, Len)` never parks: `wrWouldBlock` when full.
- `WriteString(S)` queues the string without a copy (one reference kept).
- All three return `wrCanceled` when the exchange was canceled (the client
  went away) or the stream has ended; the producer stops then. A write of
  zero bytes returns `wrOk` while the stream is active.
- `Finish(Trailers = nil): Boolean` ends the body (the last chunk). False
  when the stream had already ended. Trailers are copied; they are written
  only when the response is chunked, the client announced it accepts them
  (`TE: trailers`), and the response head listed their names in a
  `Trailer` header.
- `AbortStream(Msg)` ends the body with an error: what was written before
  it (the head and the earlier frames) is flushed, the chunked encoding is
  left without its last chunk, so the client sees an incomplete body, and
  the connection closes. `Msg` becomes the body error text
  (`SetBodyErrorText`) that the connection reports when it closes.

A stream left open when the last holder of the exchange releases it (the
worker's `Run` returned, every `Share` reference released) is finished
normally. `examples/stream.pas` writes ten lines, one per 100 ms, from a
worker.

## Your own source: RespondStream(Source)

`RespondStream(Source: TBodySource): Boolean` is the general form:
`BeginStream` is `RespondStream` with the exchange's own `TChannelBody`.
A `TBodySource` is polled on the loop thread, only while the socket can
take more:

- `PollFrame(Ex, out Data: TBodyData, out Trailers: THttpHeaders):
  TFramePoll` returns `fpData` with one frame, `fpTrailers` (the source
  keeps ownership of `Trailers` until the next call), `fpEnd`, `fpError`
  (call `Ex.SetBodyErrorText` first) or `fpPending` (the source must
  arrange `Ex.Wake`).
- `SizeHint(out Exact): Boolean` (default False: unknown length; True
  gives the body a `Content-Length` instead of chunked framing),
  `IsEndStream` (default False), `Done(Ex)` (the connection is done with
  the source; default nothing).

The application owns a source it created and frees it after `Done`. A
`TChannelBody` the application creates itself (`Create(HighWater)`,
`Reset(Ex, HighWater)`, `Push`, `FinishStream`, `AbortWith`) can be given
to `RespondStream`; it is the application's to free once its producers are
done.

## Fail(Msg)

`Fail(const Msg): Boolean` is the fourth terminal call: no response is
written and the connection closes with a user error; `Msg` becomes the
connection's error text. Use it when nothing sensible can be sent. A plain
`500` with `Respond` is usually better for a client.
