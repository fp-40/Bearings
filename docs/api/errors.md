# 9. Errors

Exceptions a program meets:

Exception | Unit | When
--------- | ---- | ----
`EServerError` | `bearings.server` | `Start` failed (port in use, invalid `H1`, no factory, started twice), `RunLoop0` without `StartCallerRunsLoop0`
`EInvalidHeader` | `bearings.http.headers` | a validating header mutator got a bad name or value
`EBodyError` | `bearings.http.exchange` | a blocking body read: the body could not be read (`Kind: TBodyErrorKind`)
`EClientGone` | `bearings.http.exchange` | a blocking body read after a cancel or a release
`EBodyTooLarge` | `bearings.http.exchange` | `ReadAll`: the body is over the limit
`EExchangeState` | `bearings.http.exchange` | a call the exchange's state does not allow: a second `Offload` of one request; `Share` with no call in flight or after the request's last holder released it
`EWorkerPoolStopped` | `bearings.rt.workers` | `Submit` or `Offload` after `Shutdown` started
`EH1Panic` | `bearings.http.error` | a program error inside the HTTP/1 code (for example a response version the encoder cannot write); the loop aborts the connection

The HTTP layer's own error value is `THyperError` (unit
`bearings.http.error`), a plain record: `Kind: THyperErrorKind` says what
failed, `Cause: TErrorCause` adds what is known (`ecErrno` with `Errno`,
`ecDecode` with `Decode`, `ecStatic` with `StaticMsg`, `ecConnText`: the
text the application passed to `Fail` or `AbortStream`, `ecInner`). The
kinds: `hekParse` (malformed or too large request head; `Parse` holds the
parser's reason, `h1peVersionH2` means an HTTP/2 preface), `hekUser` (the
application did something wrong: `User: THyperUserKind` = `hukService`,
`hukBody`, `hukHeader`, `hukUnsupportedStatusCode`, `hukNoUpgrade`,
`hukManualUpgrade`), `hekBodyWriteAborted` (the response body ended before
its declared length; `NotEofRemaining` bytes missing), `hekIncompleteMessage`
(the connection closed in the middle of a message), `hekIo`,
`hekHeaderTimeout`, `hekBody`, `hekBodyWrite`, `hekShutdown`;
`hekCanceled`, `hekChannelClosed` and `hekUnexpectedMessage` exist but the
server code does not create them. The predicates `IsParse`,
`IsParseTooLarge`, `IsParseVersionH2`, `IsUser`, `IsCanceled`, `IsClosed`,
`IsIncompleteMessage`, `IsBodyWriteAborted`, `IsShutdown`, `IsTimeout`,
`HasIoSource` classify one. `ErrorDescription(E, ConnText)` builds the log
text. The `New*` constructors build the values; a program normally only
reads them.

A program sees these through the connection observer (section 11):
`OnConnClose(ConnId, Data, Outcome: TConnOutcome, Detail)`. `TConnOutcome`
is how the connection ended: `coOk`, `coTimeout`, `coParseTooLarge`,
`coParseVersionH2`, `coParse`, `coIncomplete`, `coUser`, `coCanceled`,
`coClosed`, `coBodyWriteAborted`, `coShutdown`, `coIo`, `coOther`;
`OutcomeOf(R: TPollResult, E)` maps a result to one, in that order of
tests (`conformance/SPEC.md` 7.2). The parser's own error responses (400
for a malformed head, 414 for a too long request-target, 431 for a too
large head) are sent by the connection without involving the service.
