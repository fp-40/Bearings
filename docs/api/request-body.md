# 6. Reading the request body

The request head tells what to expect: `ContentLength` is the declared
length, 0 for no body, -1 for a chunked body (or one that ends when the
connection closes). `ExpectsContinue` is True when the client sent
`Expect: 100-continue`: it waits for `100 Continue` before it sends the
body, and the server sends that interim response when the handler first
reads the body. A handler that answers without reading spares the client
the upload.

The connection decodes the body (Content-Length or chunked) and passes it
to the handler one chunk at a time through a channel that holds at most
one chunk. The next chunk is read from the socket only after the handler
took the previous one, so a slow handler slows the client down instead of
making the server buffer the body. A chunk is a view into the connection's
read buffer, not a copy, and it is valid until the next body call.

## On the loop thread: TryRead

`TryRead(out Chunk: TByteSlice): TBodyReadStatus` never blocks:

Result | Meaning
------ | -------
`brData` | `Chunk` holds bytes, valid until the next body call
`brPending` | nothing yet; the call is polled again when data arrives (return `cpPending`)
`brTrailers` | the body ended with trailers: `RequestTrailers` holds them; `brEnd` follows
`brEnd` | the body ended (a request without a body gives `brEnd` at once)
`brError` | the body could not be read: `BodyErrorKind`, `BodyErrorMessage`, `BodyErrorIsTimeout`
`brCanceled` | the exchange was canceled, or the request was already released

## On a worker thread: Read, ReadChunk, ReadAll, ReadFrame

These block until data arrives (the worker is parked; the loop wakes it
when the channel changes):

- `ReadFrame(out Chunk): TBodyReadStatus`: `TryRead` that blocks instead
  of returning `brPending`. For a handler that must see the trailers.
- `ReadChunk(out Chunk): Boolean`: the next chunk without a copy; False at
  the end. It skips the trailer frame (`RequestTrailers` still holds the
  trailers afterwards). Raises `EBodyError` on a body error and
  `EClientGone` when the exchange was canceled or the request was released
  before the body ended.
- `Read(Buf, Max): SizeInt`: copies up to `Max` bytes; 0 at the end. Same
  exceptions.
- `ReadAll(var Dst: TBytes; Limit): SizeInt`: appends the whole body to
  `Dst` and returns the number of bytes appended. With `Limit > 0` it
  raises `EBodyTooLarge` when `ContentLength` is over the limit (before
  reading anything) or when the bytes read exceed it. Same exceptions as
  `ReadChunk`.

`DiscardBody` closes the receiver only: the handler does not want the
rest. The connection then reads and discards it, or closes the connection
(no `100 Continue` is sent for an unread body). The head stays valid.
`RequestTrailers: THttpHeaders` holds the trailers after `brTrailers` or
`brEnd`.

Body errors (`TBodyErrorKind`): `bekUnexpectedEof` (the connection closed
in the middle of the body), `bekInvalidData` (a malformed chunked
encoding), `bekInvalidInput`, `bekIo` (a socket error), `bekOther`.
`BodyErrorIsTimeout` is True when the body rate rule
(`TH1Config.BodyReadTimeoutMs`, `BodyMinRate`) failed the body: the client
sent nothing for too long or too slowly. `BodyErrorMessage` is the text of
`conformance/SPEC.md` 7.1. `EBodyError.Kind` carries the same
`TBodyErrorKind`.

`examples/worker.pas` shows the three exceptions handled.
