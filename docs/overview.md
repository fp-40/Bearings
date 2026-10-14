# Overview

Bearings is an HTTP/1.1 server library for Free Pascal. It runs one event
loop per CPU, keeps a pool of worker threads for code that blocks, and
hands your program one `TExchange` per request: the parsed request and the
response to fill in. It runs on Linux only, because it calls epoll,
eventfd, accept4, sendfile and writev directly.

This tutorial takes you through the library step by step, from a server
that answers "Hello" to a small key-value store that reads request bodies,
streams responses, and serves a WebSocket chat. Each chapter builds on the
one before it and ends with a program you can compile and try with curl.

## Bearings' role in your program

A network server has to serve many connections at once while most of them
are idle. The usual Free Pascal answer is a thread per connection, which
works until the connection count grows, and which spends its time in
`Sleep`, blocking reads and lock contention. Bearings takes the other
approach: a fixed number of threads, each running an event loop that asks
the kernel which sockets are ready and runs the code of those sockets
only. Your code is called when there is something to do and must return
quickly.

Bearings gives you:

- The event loops, with timers, a buffer pool and a message inbox per
  loop, so that per-loop state needs no locks.
- An HTTP/1.1 parser, encoder and body codec that handle keep-alive,
  pipelining, chunked bodies, trailers, `Expect: 100-continue` and
  connection upgrades.
- A worker pool for code that blocks, with backpressure between a worker
  and the loop that owns the connection.
- A WebSocket implementation (RFC 6455) with pub/sub topics.
- A `TServer` that ties them together: listeners, signals, graceful
  shutdown, a connection limit, an access log, metrics, and systemd socket
  activation and watchdog notifications.

It has no TLS and no HTTP/2. Put a reverse proxy such as nginx in front of
it for both, and turn on the PROXY protocol so the client's address is
still known behind the proxy.

## Advantages

- The path for a request answered on the loop thread allocates nothing
  and touches no atomic instruction. On the plaintext benchmark the library
  runs at 0.85 to 0.98 of hyper, the Rust HTTP library
  (`bench/run_gate.sh` runs the comparison).
- A connection is accepted by one loop and stays there, and every queue
  in the library is bounded: a slow client slows its producer down instead
  of making the server buffer everything.
- There is no build step and no dependency beyond the Free Pascal RTL. A
  program puts five directories on its unit path and compiles.
- Every public routine has a documented threading rule ([API guide](api/reference.md),
  section 14), and a build with assertions checks the rules at run time.

## When not to use Bearings

- You need TLS or HTTP/2 in the process. Bearings speaks plain HTTP/1.1.
  A reverse proxy covers both, but if you cannot run one, Bearings is not
  the right choice.
- You want a web framework. Bearings has no router, no templates and no
  sessions. It is the layer a framework would be built on.
- Your handlers are CPU-bound. The worker pool keeps blocking code off
  the loops, but a server whose work is long computation is better served
  by a thread per CPU and a plain blocking socket library.

## Getting help

`docs/api/` is the API guide, organized by what a program does.
`docs/design/` explains the decisions behind the library and the
invariants a contributor must respect.

The header comment of every unit under `src/` describes that unit.

The programs under `examples/` are complete and commented; four of them are the ones the tutorial writes.
