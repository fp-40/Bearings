# 8. Header validation

An invalid header field must not reach the wire: a name that is not a token,
or a value holding CR, LF or NUL, would end the header line early or add
lines of its own (response splitting), letting whatever supplied the value
inject headers or a second response. The check is at the mutators of
`THttpHeaders` (`bearings.http.headers`), where the bytes enter the list,
not in the encoder: `Add`, `Append`, `Insert` and `SetValue` validate and
raise `EInvalidHeader`; `TryAdd`, `TryInsert` and `TrySetValue` return a
`THeaderCheck`; `AddTrusted`, `InsertTrusted` and `SetValueTrusted` skip the
check for bytes that are valid by construction (parser and decoder output,
constants covered by a unit test), and `AddExternal` (the parser's zero-copy
entries) never checks. A name is 1 to 65 535 token bytes; a value may hold
HTAB and any byte from `$20` on except `$7F`. The cost is one table lookup
per byte, which an application avoids for constants with the trusted
variants. In `-Sa` builds `ServerEncode` and `EncodeTrailers` assert every
name and value they write, so a path that missed the boundary shows up in
tests, and the validating mutator calls are counted
(`ValidatingMutatorCalls`), so a test can prove that the library's own
callers use the trusted paths. Where an exception from `Add` lands: in a
worker, the job's `try/except`; in an inline handler, the loop's handler
aborts the connection.

The same rule holds for the reason phrase (`bearings.http1.reason`: HTAB, SP,
visible ASCII and obs-text only; `SetReason` refuses anything else) and for
trailers: `EncodeTrailers` writes only fields whose names the response
announced in its `Trailer` header, grouped by name in order of first
appearance, and `TH1Conn.WriteTrailers` writes nothing unless the request
sent `TE: trailers`; when no field survives, the body is ended normally
instead.
