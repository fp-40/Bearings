# 7. The response head

Written before the terminal call, by the thread that will make it (on a
shared exchange, only that thread; builds with assertions check this):

- `Status: Word` (default 200). The encoder writes the standard reason
  phrase of the status (`bearings.http1.reason`). A 1xx status other than
  101 cannot be sent: a `500` head is written instead and the connection
  closes with a user error.
- `ResponseVersion: THttpVersion` (default `hv11`).
- `SetReason(P, Len): Boolean` sets a custom reason phrase (the bytes are
  copied); False, and nothing changes, when it holds an invalid byte.
- `ResponseHeaders: THttpHeaders` is the header list of the response. It
  is cleared at every request and keeps its capacity, so a list reused by
  a connection stops allocating once it is large enough.

`THttpHeaders` (unit `bearings.http.headers`) keeps the fields in
insertion order, keeps the case of each name and looks names up ignoring
case. Mutators:

- `Add(Name, Value)` (two overloads: `RawByteString` or `PByte` + length)
  appends a field; `Append` is the same. `Insert(Name, Value)` sets the
  only value of `Name`: the first entry gets the value, later entries with
  that name are removed, or the field is appended. `SetValue(I, Value)`
  replaces the value of entry `I`. These **validate** their input and raise
  `EInvalidHeader` (with `Check: THeaderCheck` = `hcBadName` or
  `hcBadValue`) on a bad name or value; the list is then unchanged. A name
  must be an RFC 9110 token (1 to 65 535 bytes of `ALPHA DIGIT ! # $ % & '
  * + - . ^ _ \` | ~`); a value may hold HTAB and any byte >= 0x20 except
  0x7F. CR, LF and NUL are refused because a value that contained them
  would end the header line early or add header lines of its own
  (response splitting), letting whatever supplied the value inject headers
  or a second response.
- `TryAdd`, `TryInsert`, `TrySetValue` make the same checks and return a
  `THeaderCheck` instead of raising.
- `AddTrusted`, `InsertTrusted`, `SetValueTrusted` skip the checks, for
  bytes that are valid by construction (constants, parser output). The
  library's own code uses these.
- `Delete(I)`, `Remove(Name)` (returns how many), `Clear`.

Lookups: `IndexOf(Name, StartIndex = 0)`, `LastIndexOf`, `Contains`,
`CountOf`, `Get(Name, out Value, out ValueLen)` (a slice; no allocation),
`GetValue(Name)` (a new string; allocates), `NamePtr(I)` / `NameLen(I)` /
`ValuePtr(I)` / `ValueLen(I)` (slices, valid until the next call that adds
bytes to the list), `Name(I)` / `Value(I)` (copies), `NameIs(I, Name)`,
`Count`, `Entries[I]`.

Framing headers are the encoder's: it writes `Content-Length` for
`Respond` and for a `TBodySource` with a `SizeHint`, `Transfer-Encoding:
chunked` otherwise (HTTP/1.1), and `Date` unless the application set one
(`AutoDateHeader`). A `Content-Length` or `Transfer-Encoding` header set
by the application that is invalid or contradicts the body makes the
response a user error: the connection closes. One exception, as in
hyper: with a body of known length (`Respond`), the application's
`Content-Length` is written as given and assumed to match; a wrong one
breaks the framing of the connection. Builds with assertions (`-Sa`)
check it. The C interface leaves that header out and writes the length. On a request header list
(`Ex.Headers`) the application only reads.
