# 1. Purpose and scope

Bearings is an HTTP/1.1 server library for Free Pascal 3.2.2 with three parts:

- an event loop per CPU (`bearings.rt.loop`)
- a pool of worker threads for code that blocks (`bearings.rt.workers`),
- and an HTTP/1.1 engine: parser, encoder, body codecs, connection state machine, and dispatcher (`bearings.http1.*` units).
  
`TServer` (`bearings.server`) ties them together. An application gives the server a service object; the server calls it once per request with a `TExchange` (`bearings.http.exchange`) and writes the response the service produces.

## Scope

It speaks HTTP/1.1 and HTTP/1.0 over plain TCP or a Unix domain socket. This means
"keep-alive", pipelining, chunked bodies and trailers, `Expect: 100-continue`, connection upgrades (the socket is handed over after a `101 Switching Protocols` response), request body backpressure, streamed responses with backpressure, file bodies with `sendfile(2)`, graceful shutdown, a connection limit, systemd socket activation and notifications, an access log and metrics.

WebSocket (RFC 6455) runs on top of the upgrade hand-off (`bearings.ws.*`, section 6.10).

It has no TLS and no HTTP/2. TLS belongs to a reverse proxy such as nginx in front of the server. The WebSocket layer negotiates no extension (no `permessage-deflate`). The types of the service API are protocol-neutral in content so that an HTTP/2 session can use them later (section 6.9).

## Layers

- `src/rt` (runtime, knows nothing about HTTP)
- `src/http1` (the HTTP/1.1 engine)
- `src/http` (the exchange and the error type)
- `src/server` (`TServer`, the access log, the metrics)
- `src/ws` (WebSocket: the frame codec, the opening handshake, the connection and the pub/sub topics; it uses `src/rt`, the exchange and the header list, and nothing else uses it)
- `src/rt` uses nothing from the other directories.

## Platforms

It runs natively only on Linux, x86_64 and ARM64. But can run on Windows through its WSL layer, or on MacOS in a Docker container.

The runtime calls the kernel through its own system call stubs (`bearings.rt.sys`, one include file of assembler routines per architecture: `epoll_wait`, `epoll_ctl`, `eventfd2`, `accept4`, `read`, `write`, `writev`, `sendfile`, `futex`, `sched_getaffinity`, and the socket calls), not through the FPC RTL units. A few cold setup calls use the RTL's `BaseUnix` (`fcntl` when an upgraded socket is detached and for systemd's descriptors, `unlink`, `chmod`, `chown` and `lstat` of a Unix socket file).

The stubs return the raw kernel result, `-errno` on failure, and never write FPC's errno threadvar. The lock-free code was reasoned about in the x86-64 memory model; on ARM64 the `Atomic*` wrappers of `bearings.rt.sync` add the barriers that give each access the same guarantee (section 11). Programs are compiled with `{$mode objfpc}{$H+}` and must list `cthreads` first.

## Goals

Two goals shape most decisions.

The first is throughput: the request path of a service that answers on the loop thread allocates nothing, takes no lock, executes no atomic instruction and enters no implicit exception frame (section 7); the measured result is 0.85 to 0.98 of hyper's throughput on the plaintext benchmark.

The second is strictness on the wire: the parser and the body decoder reject what the RFC 9110 and RFC 9112 grammars reject, because a server and a proxy in front of it must agree on where each request ends (request smuggling). The conformance harness checks the wire behaviour against hyper's reference server (section 9); that is a fact about the test tooling, not a design input.
