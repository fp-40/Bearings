# Request bodies

The connection decodes the request body (`Content-Length` or chunked) and
passes it to your handler one chunk at a time. The next chunk is read from
the socket only after the handler took the previous one, so a slow handler
slows the client down instead of making the server buffer the body. A
chunk is a view into the read buffer, valid until the next body call.

## What the head tells you

`Ex.ContentLength` is the declared length: 0 for no body, -1 for a chunked
body. `Ex.ExpectsContinue` is True when the client sent `Expect:
100-continue` and waits for `100 Continue` before uploading. The server
sends that interim response when your handler first reads the body, so a
handler that rejects the request without reading spares the client the
upload. To say "I do not want the rest", call `Ex.DiscardBody`: the
connection reads and discards it, or closes.

## On a worker thread

Four blocking reads, all of which park the worker until data arrives:

- `ReadAll(var Dst: TBytes; Limit)`: the whole body, with a size limit.
  The simplest, and the one `kv3.pas` uses.
- `Read(Buf, Max)`: copies up to `Max` bytes; 0 at the end.
- `ReadChunk(out Chunk)`: the next chunk without a copy; False at the end.
- `ReadFrame(out Chunk)`: like `ReadChunk` but also reports the trailers.

A handler that processes a large upload chunk by chunk, writing each to a
file, uses `ReadChunk` and never holds more than one chunk in memory.

## On the loop thread

`TryRead(out Chunk)` never blocks. It returns `brData` with a chunk,
`brEnd` when the body ended, `brPending` when nothing has arrived yet, or
`brError` and `brCanceled`. On `brPending` the call returns `cpPending`
and is polled again when data arrives. The call object has to remember
where it was in the body between polls: `Ex.Tag` (a `PtrInt`) and
`Ex.User` (a `TObject`) are per-request fields reserved for that, reset
at every request. Reading a body inline is more work than on a worker; do
it when you have measured that the hand-off matters.
