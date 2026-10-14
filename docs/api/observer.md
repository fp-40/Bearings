# 11. The connection observer

`TConnObserver` (declared in `bearings.http.exchange`, re-exported by
`bearings.server`) is a set of per-connection hooks for tests, the
conformance server and instrumentation. Pass an instance as the third
argument of `TServer.Create`; nil costs nothing. All hooks run on the loop
thread:

Hook | When | Default
---- | ---- | -------
`OnAccept(Loop, ConnId, Peer): Pointer` | a socket was accepted; returns per-connection data passed to the other hooks | nil
`WrapTransport(T: TTcpTransport, Data): TTransport` | may wrap the socket transport (for example to count bytes) | returns `T`
`OnStart(ConnId, Data, Task)` | the connection task is set up and registered, before its first run | nothing
`OnConnClose(ConnId, Data, Outcome, Detail)` | the connection ended; `Outcome` is a `TConnOutcome`, `Detail` the error text | nothing
`OnParts(ConnId, Data, var Parts: TConnParts)` | `cmWithoutShutdown` only: the HTTP connection ended; `Parts.Transport` (owned by the receiver), `Parts.Rest` (unread bytes, a pinned view) and `Parts.Src` are handed over | closes them

A receiver that keeps the socket open in `OnParts` builds a `TUpgraded`
with `TUpgraded.CreateFrom(Loop, Transport, Rest, Src, True)` before
`OnParts` returns.
