# Bearings API guide

This guide is organized by what a program does with the library, not by unit. The last section is a reference table of every public type and routine of the units a program uses, with its threading rule.

Everything here was taken from the code and the header comments of the units under `src/`; where a detail matters, the unit is named so you can read the header comment, which is written for the same audience as this guide.

Example programs under `examples/` accompany it:

- `hello.pas` (inline answer, static body)
- `worker.pas` (every request on a worker, request body read with `ReadAll`, echoed back)
- `stream.pas` (a streamed response and a file response)
- `ws_echo.pas` (a WebSocket echo server)
- `ws_chat.pas` (a chat with rooms on the pub/sub topics)
- the four programs of the tutorial (`docs/index.md`): `kv1.pas`, `kv2.pas`, `kv3.pas` (a key-value store, per loop, shared, and on the worker pool) and `delay.pas` (a `TWakeTimer`).

You can find the build command for them in `examples/README.md`.

Contents:

1. [Concepts: loops, workers, the exchange, services and calls](concepts.md)
2. [Configuring and running a server](server.md)
3. [Answering inline on the loop](inline.md)
4. [Answering on a worker thread](workers.md)
5. [Response bodies](response-bodies.md)
6. [Reading the request body](request-body.md)
7. [The response head](response-head.md)
8. [Cancellation, keep-alive and pipelining](cancellation.md)
9. [Errors](errors.md)
10. [Connection upgrades](upgrades.md)
11. [The connection observer](observer.md)
12. [Debug build flags](debug.md)
13. [Performance rules](performance.md)
14. [Reference tables](reference.md)
