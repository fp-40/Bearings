# Next steps

The tutorial covered the shape of the library: a server, a service per
loop, a call per request, one terminal call per exchange, workers for code
that blocks, and bounded queues everywhere. Where to go next:

- `docs/api.md` covers what this tutorial left out: the connection
  observer, the access log and metrics, the connection limit, the PROXY
  protocol, `TBodySource`, trailers, upgrades to protocols other than
  WebSocket, the debug build flags, and a reference table of every public
  routine with its threading rule.
- `docs/api.md`, section 13, has the performance rules for an inline
  handler that wants the benchmark's speed: a stateless call object,
  `BodyStatic` for constant bodies, no string building per request, and
  no managed locals in `Poll` (the compiler adds an exception frame to a
  routine that has them). The key-value store in this tutorial breaks
  every one of those rules on purpose, to stay readable; a program that
  needs the speed looks at `bench/plaintext.pas`.
- `docs/design.md` explains why the library is built the way it is, and
  lists the invariants that the code relies on.
- Compile with `-Sa` during development. The threading rules of every
  routine are then checked at run time, and a call that completes without
  a terminal call raises an assertion that names the request.
