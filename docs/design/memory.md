# 7. Memory

## 7.1 Ownership

| object | owner | lifetime |
|---|---|---|
| `TH1Dispatcher` (embeds `TH1Conn`, `TH1Io`, decoder, encoder, timers) | its loop | accept to close; freed after the event batch |
| read buffer block | `TReadBuf` while it holds bytes or views pin it; the loop's pool otherwise | 7.3 |
| write cursor block, queue array | `TWriteBuf` while bytes are buffered; the pool otherwise | 7.3 |
| queued body data | its `TBodyData` until written | released in `TBufList.Advance`, or right after the copy into the cursor |
| `TExchange` with its header lists and trailer list | the loop's `TExchangePool`; references: the connection plus `Share` | 6.4 |
| call objects | the service (singletons or its own pools) | `TServiceCall.Drop` returns them |
| `TUpgradeSlot` | reference-counted: the connection side and the exchange | the last `Release` frees it |
| `TUpgraded` | its loop, then the upgrade handler | until closed or detached |
| `TWebSocket` | reference-counted: the loop holds one reference until the connection ends, plus one per `AddRef` | the last `Release` (any thread) frees it |
| `TWebSocketHandler` | its `TWebSocket`, unless created with `AOwnsHandler = False` | freed after `OnClose` |
| `TWsFrame` (prepared frame) | the AnsiString reference count | the last reference: the caller's and one per queue entry until written |

## 7.2 Zero-copy slices and their lifetimes

| slice | points into | valid until | kept alive by |
|---|---|---|---|
| request method, target, URI parts, header names and values | the read buffer (head region) | the request is released: at the latest the call's completion (unshared) or the last holder's release (shared) | the head view's pin (`TRequestHead.View`) |
| request body chunk (`TryRead`, `ReadChunk`) | the read buffer (body region) | the next body call or the release of the request | `TBodyChan.Held` |
| request trailers | the exchange's `ReqTrailers` list (copied from the decoder scratch) | the exchange is recycled | the exchange |
| response headers | the exchange's response list arena | encode time | the exchange |
| `BodyStatic` | the caller's memory | forever | the caller |
| `BodyString`, `WriteString` | the string's heap block | the frame is written | one reference in `TBodyData.Ctx` |
| `BodyCopy`, `Write` | a pool or heap block owned by the body data or the stream ring | the frame is written | the `TBodyData` |
| leftover bytes of a `TUpgraded` | the read buffer | consumed, closed, or copied by `Detach` | the pin |
| WebSocket message bytes (`OnText`, `OnBinary`) | the connection's read block or reassembly buffer | the end of the call | the `TWebSocket` |

`TReadBuf.Reserve` never moves or compacts a block with pins: when the
buffer needs room it takes a new block, copies the unread bytes, and marks
the old one `Detached` so that the release of its last view frees it. Pins
are loop-thread counters; hyper pays an atomic reference count per head and
per chunk, bearings pays a plain increment. Debug builds fill freed blocks
with `$DD`.

## 7.3 Pooling

`TBlockPool` (one per loop): eight size classes from 8 KiB to 1 MiB, 64-byte
aligned, LIFO free lists (the most recently returned block is still in
cache), the total capped at `POOL_DEFAULT_MAX_BYTES` (64 MiB) per loop,
larger requests straight from the heap, no zero-fill. `Trim` runs after 1 s
without events and frees, per class, the blocks that were not needed since
the previous trim (the free list's low-water mark). The read buffer grows by
pool class and is compacted when unpinned; `TByteVec` grows to
`Max(2 * Cap, Len + Additional)`.

A connection gives its blocks back whenever it is idle (`TH1Io.ReleaseIdle`
at the end of a run that leaves `Reading = rdInit`, `Writing = wrInit`, an
empty unpinned read buffer and an empty write buffer), gives its exchange
back to the pool at the same moment, and frees its trailer scratch
(`ReleaseIdleScratch`). So an idle keep-alive connection holds the
dispatcher object and nothing else: about 1.3 KB measured with 10 000 idle
connections (hyper: 10.7 KB). `TExchangePool.Give` keeps the header lists'
capacity, so a reused exchange stops allocating once its lists are large
enough.

## 7.4 No reference-count traffic and no implicit exception frames

- Hot routines take `PByte` plus length. No `string`, `RawByteString` or
  dynamic-array locals, by-value parameters or temporaries, and no `try`:
  each of these makes FPC emit `fpc_pushexceptaddr` and `fpc_setjmp` on
  every call. `TEncoder`, `TDecoder`, `TResponseHead`, `THyperError`,
  `TBodyData` and the buffer records have no managed fields; trailer names
  and trailer bytes live in a per-connection scratch (`TConnScratch`) instead
  of managed fields of the codec records; the reason phrase is a slice.
- No management operators (`Initialize`/`Finalize`) on hot records: they
  would make every local of that type a managed local.
- No threadvars on the hot path: the date cache, the pools and the timers
  are reached through the loop object.
- `TTcpTransport` has no constructor of its own (`NewTcpTransport`): an FPC
  constructor always gets a frame.
- The HTTP transport touches an AnsiString reference count only for
  `BodyString` and `WriteString` (one increment, one decrement;
  `lock`-prefixed because the program is multi-threaded). A WebSocket's
  `SendFrame` and `PostFrame` hold a prepared frame the same way.
- The check: `tools/check-hot-asm.sh` compiles `bearings.server` and every
  unit it uses (all of `src/` except `src/ws`) with assembler listings in the
  production (`-O3`) and the test (`-O2 -Sa`) configuration and fails when any
  listed routine contains a frame call (`tools/hot-asm.py` parses the
  listings). The list covers the dispatcher's per-request routines, every
  method of `TH1Conn`, `TConnState`, `TH1Io`, `TReadBuf`, `TByteVec`,
  `TBytesView`, `TTcpTransport`, `TTimerWheel`, `TBodyChan`, the per-frame
  `TChannelBody` methods, the shared-exchange routines (`Release`, `Share`,
  `Offload`, `Wake`, the stream writer), the parse and encode entry points,
  `TLoop.RunIteration` and the `bearings.rt.sync` primitives. With `--s7` it
  also checks that the production listing of `bearings.http.exchange` holds no
  `Dbg*` routine and no assertion call, and that the test listing does.

## 7.5 Per-request allocations

Inline path: none (the exchange is reused, the call is a singleton, the
header lists are cleared and reused, read and write blocks come from the
pool, `TBodyData` is a record, a timer is embedded). Worker path: none in
steady state either (the exchange comes from the pool and is its own work
item; posting a message allocates nothing). A string built per request by
the application (`RespondText`, `BodyCopy`, `GetValue`) is the application's
cost; the [API guide](../api/performance.md), section 13, lists the rules a program must keep.
