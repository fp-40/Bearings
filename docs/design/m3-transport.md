# M3 design: event loop, HTTP/1 connection engine, service API, Pascal conformance server

> Written while this code was part of wd-40 (where "wd-40" in the text means the project of that time). The unit names were changed to `bearings.*` when the transport moved to this repository; commit hashes refer to the wd-40 history.

Status: final M3 design. Date: 2026-10-07. Replaces the three candidates in `docs/design/m3-candidates/`
(`faithful.md`, `perf.md`, `api.md`) and fixes every flaw the three judges reported (section 0.4).

Inputs read for this document:

- hyper v1.12.0, rev `7f67699`: `src/proto/h1/{conn,dispatch,io,role,encode,decode}.rs`,
  `src/server/conn/http1.rs`, `src/upgrade.rs`, `src/body/{chan,incoming}.rs`, `src/common/task.rs`,
  `src/error.rs`. Short references below: `conn.rs:NNN` = hyper `src/proto/h1/conn.rs` line NNN.
- tokio 1.53.2 (`io/poll_evented.rs`, `runtime/io/scheduled_io.rs`, `runtime/task/harness.rs`,
  `runtime/scheduler/current_thread/mod.rs`), mio 1.2.4 (`net/tcp/listener.rs`,
  `sys/unix/selector/epoll.rs`), bytes 1.12.1 (`bytes_mut.rs`): the versions in `conformance/Cargo.lock`.
- `conformance/SPEC.md`, `conformance/reference-server/src/main.rs`, the 105 cases in `conformance/cases/h1/`.
- The interfaces of every unit in `src/http1/` (parser, decode, encode, role, headers, uri, date, reason).
- The three candidates, the three judge reports, the perf prototype in
  `scratchpad/m3-perf-proto/` and the judges' probes in `scratchpad/m3-judge-*/`.
- Proper docs: `app.md` (Request Lifecycle), `api.md` (Request/Response), `controllers.md`, `routing.md`.

Contents

- 0. Summary of decisions, assumptions, open questions, judges' flaws and their resolution
- 1. Threading and reactor
- 2. Connection state machine (port of io.rs, conn.rs, dispatch.rs)
- 3. Service API
- 4. Memory
- 5. Header value validation and the trailer fixes
- 6. The Pascal conformance server, SPEC item by SPEC item
- 7. Test plan and performance method
- 8. Unit layout, deviation register, risks
- 9. Implementation plan (verifiable steps)
- Appendix A. hyper to Pascal map

---

## 0. Summary

### 0.1 Decisions (one page)

| area | decision | origin |
|---|---|---|
| base | `perf.md` (highest total score, 22): its measured runtime design, buffer pooling, inline fast path and measurement method. The HTTP/1 engine and the service-call model come from `faithful.md`; the application surface, enforcement checks and wakeup details from `api.md` | judges |
| loops | one loop thread per usable CPU: `sched_getaffinity` popcount, capped by the cgroup v2 quota; `GetCPUCount` is not used (returns 1) | all |
| accept | production: one `SO_REUSEPORT` listener per loop (hyper's TFB layout, measured equal to `EPOLLEXCLUSIVE`); option: one shared listener with `EPOLLEXCLUSIVE`. Conformance: one listener configured exactly like mio's `TcpListener::bind` (`SO_REUSEADDR`, backlog 128, no `TCP_NODELAY`) | perf, faithful |
| epoll | connections edge-triggered `EPOLLIN|EPOLLOUT|EPOLLRDHUP|EPOLLET`, registered once, never modified; listener, eventfd and stdin level-triggered | all |
| readiness | tokio's rules: a read bit cleared on `EAGAIN` or a short read; a write bit cleared on `EAGAIN` or a short scalar write, but not on a short `writev`; the read-closed, write-closed and error bits are sticky and make the next read/write call the kernel even when the read/write bit is clear | faithful + judge fix |
| scheduling | epoll events call the connection driver directly (no run-queue hop); the run queue holds yields, local wakes and cross-thread wakes; a yielded task goes to the back of the run queue and may run again in the same loop iteration (tokio `wake_by_ref` semantics) within a budget of 61 run-queue polls per iteration | perf + judge fix |
| clock | libc `clock_gettime` (vDSO, 11 ns), read once right after `epoll_wait` returns; the Date cache is checked in the same place | perf |
| timers | per-loop hierarchical wheel, 6 levels of 64 slots, 1 ms resolution, deadlines rounded up like tokio; lazy re-arm and lazy cancel (one store per request for the header-read / keep-alive timer) | faithful + api |
| cross-thread | per-loop intrusive MPSC stack; the eventfd is written only when the push found the stack empty **and** the loop may be sleeping (`Sleeping` flag) | perf + api |
| exceptions | one `try/except` per loop iteration, not per poll; an escaping exception aborts the task that raised it (tokio aborts a panicked task: no `conn_close`), then the loop continues with the rest of the event batch | judge fix |
| HTTP/1 engine | written as a port of `Buffered`, `Conn`/`State`, `Dispatcher`/`Server`, with hyper's function names and line references (since T1 the goal is hyper's features, not its statement order: 2.1); `poll_inner` ported literally (shutdown before `take_error` for stored errors; no flush or shutdown for errors propagated from `poll_loop`) | faithful |
| read buffer | one block from the per-loop pool that grows to the next pool class (reads at most `max_buf_size - len` bytes) and is compacted when it runs out of room; hyper's adaptive read strategy decides how much room a read asks for (T1 replaced the `BytesMut` port) | perf, T1 |
| service call | `THttpService.Call(Ex)` runs in `recv_msg` and returns a `TServiceCall`; the handler body runs only in `TServiceCall.Poll(Ex)`, which the dispatcher calls from `poll_msg` inside `poll_write`, exactly where hyper polls the service future. Inline handlers answer inside their first `Poll` (a shared, stateless call object: no allocation) | faithful |
| request body | port of `body/chan.rs`: one slot, `want = not expect_continue`, the dispatcher prefetches one chunk before the first handler poll; pull API (`TryRead` on the loop, blocking `Read`/`ReadChunk` on workers); `ReleaseRequest` = hyper's `drop(req)` | faithful + api |
| exchange | one `TExchange` per HTTP/1 request (per HTTP/2 stream later), reused per connection while nobody else holds it; one atomic reference count touched only by `Share`/`Release` (the inline path never touches it) | perf + judge fix |
| blocking code | synchronous Proper controllers run on a worker pool (`MAX_THREADS` workers, one DB connection each); `Ex.Offload` from `Poll`; measured cost about 5 us per request, so inline routes stay on the loop | perf |
| M5 | the whole Proper pipeline (head_to_get .. update_session_cookie) runs on the worker; the loop only classifies a request as inline or worker, because `_method` can come from the form body | faithful + judge fix |
| memory | no managed types (AnsiString, dynamic arrays) in hot records or hot locals; `TEncoder`, `TDecoder`, `TResponseHead` lose their managed fields in step S0; a build check fails if a listed hot routine contains `fpc_pushexceptaddr`; read pins are counted on the loop thread only (no atomics) | api + perf |
| header validation | `THttpHeaders.Add/Insert/SetValue` validate (`HeaderName`/`HeaderValue` rules) and raise; `Try*` variants return a result; `*Trusted` variants skip checks for parser output and constants; encoders assert in test builds | api |
| trailers | T1 (grouping by name), T2 (CR/LF injection), T3 (`write_trailers` state rule) fixed in S0, first checked by a differential test against hyper's `encode_trailers`, now by fixed expectations (5.2) | all |
| HTTP/2 room | protocol-neutral loop, task, exchange, body source and service; preface detection by `TProtoSniffer` on the shared read buffer (hyper-util `auto`) | all |
| measurement | the perf prototype and the hyper-tfb harness are the permanent baseline; configuration B (server on CPUs 0-3, wrk on 4-15) is the gate configuration; 0.80 x hyper per cell is a hard gate from step S5 on | perf |

### 0.2 Measured numbers this design relies on

All measured by the `perf` candidate on this machine (i5-14400, 6P+4E, 16 logical CPUs, kernel 7.0.0,
governor `powersave`) with the prototype `scratchpad/m3-perf-proto/loop/beproto.pas` (real M2
`ServerParse` / `ServerEncode`, no state machine, no service layer) against hyper rev `7f67699` in its TFB
configuration. The performance judge re-ran configuration B and got the same ratios. I did not re-run
them for this document.

| measurement | value |
|---|---|
| prototype / hyper, configuration B (server CPUs 0-3, wrk 4-15), c256 d1 / c256 d16 / c1024 d1 / c1024 d16 | 1.05 / 1.07 / 1.08 / 1.10 (judge's re-run: 1.06 / 1.09 / 1.08 / 1.12) |
| requests per server CPU-second, depth 16, hyper vs prototype | 781 792 vs 834 796 (c256); 737 716 vs 794 849 (c1024) |
| per-request CPU budget for the full engine over the prototype, depth 16 | about 420 ns to stay at 0.80 x hyper; about 90 ns to stay at 1.00 x |
| idle keep-alive connection, 10 000 connections | hyper 10 698 B; prototype with pooled buffers 1 739 B |
| RSS at c=1024 d=16 | hyper 21 592 KB; prototype with pooling 4 832 KB |
| offloading every request to a worker pool | about 5.4 us extra CPU per request at depth 1; pipelined throughput 18-38 % of inline |
| `pipeline_flush(false)` at depth 16 | 4x lower throughput, for hyper and the prototype |
| a routine with a managed local (implicit `setjmp` frame), FPC 3.2.2 x86_64 | 19.5 ns per call (perf), 12.2-12.5 ns (perf judge); without: 0.66 ns |
| eager Proper-like request object (method, path, query, 6 headers as AnsiStrings) vs lazy | 360 ns vs 53 ns |
| libc `clock_gettime` (vDSO) vs FPC's | 11 ns vs 89 ns |
| threadvar access | 2.7 ns |

### 0.3 Assumptions and open questions

Assumptions (stated so they can be checked):

1. Linux x86_64, kernel >= 5.10, FPC 3.2.2 with `{$mode objfpc}{$H+}{$modeswitch advancedrecords}`, `cthreads`
   as the first unit of every program.
2. wd-40 is feature-equivalent to hyper 1.12.0, validated by hyper's wire tests (the 105 cases in
   assertion mode) and the request-acceptance differentials (parser vs httparse, `Server::parse`,
   body decoder vs `decode.rs`). Byte-identical writes, read sizes and event timing are not goals
   (user decision 2026-10-08; step T1). The performance target (>= 0.80 x hyper's requests/s per cell)
   stays.
3. The "16-core box" is this machine. Its 4 E-cores (CPUs 12-15) are slower, so the gate uses
   configuration B (section 7.6), where the server, not wrk, is the bottleneck.
4. The perf target is checked per cell (c256/c1024 x depth 1/16), not on an average.
5. The M2 note "trailer encoding deviates from role.rs in 3 ways" is not written down in the repository.
   Section 5.2 lists the deviations found by reading the code (the conformance judge verified T1 and T3).

Decisions on the former open questions (2026-10-07; the user delegated these decisions):

1. **`pipeline_flush`.** Production default `True` (only TCP segmentation differs from hyper). Decision 14 adds the one deliberate
   difference: the end-of-connection flush. Conformance runs use hyper's defaults (`false`).
   Benchmarks configure both servers exactly like hyper's TFB entry (`pipeline_flush(true)`, TFB main.rs:164).
2. **Gate vs report.** The only hard performance gate is requests/s >= 0.80 x hyper in every cell (the
   user's criterion). Depth-1 p99 <= 1.25 x hyper, RSS under load <= hyper, idle connection <= 2 KB are
   goals that are measured and reported, not gates.
3. **Header read timeout.** Always-on timer; default 30 s (hyper's default, server/conn/http1.rs:253).
   The benchmark configuration turns it off, matching hyper's TFB entry.
4. **Controllers** run on the worker pool by default; `inline` is an opt-in per route.
5. **Trailers.** T1-T3 (5.2) are confirmed. The fourth M2 finding (the `Trailer:` header-line list must
   accumulate across lines, skip non-visible-ASCII values and invalid names) was already fixed in M2
   (`Extra_encode_trailer_header_lines`, `IsValidHeaderName`).
6. **Load generator.** No second machine: configuration B on this box, with hyper and wd-40 given the same
   CPU set.

Decisions after S5 (2026-10-07; taken under the user's delegation, from the S0-S5 verifiers' findings).
Step H (before S6) implements 7-13 and corrects the text of the sections they name:

7. **S5-3 is fixed, not kept.** hyper 1.12.0 release builds write a parse-error 400 head between a queued
   response's head and its body (Queue strategy only; hyper debug builds panic at the `debug_assert!` in
   `WriteBuf::headers_mut`, so no hyper test depends on it). Rule: a head written while entries are
   queued is queued behind them (2.2.4). The H-13 conn-diff rule and the H-14 head-entry slot were
   removed in T1 with the machinery they served. `-Sa` builds no longer stop on this path.
8. **File entries and liveness (S3 design problem, DV-5).** An entry that arrives while something is
   queued is queued too, so FIFO order holds at run time, not only under `-Sa`; `PollFlush` writes a
   queued entry even when `pipeline_flush` would skip the flush (decision 8 covered file entries; T1
   extended it to every queued entry, 2.2.4). S8 test: 3 or more pipelined requests whose first response
   has a file body all complete.
9. **`TUpgradeSlot` ownership.** The slot has an atomic reference count, one reference per holder
   (connection, exchange); the last `Release` frees it. Pooling (2.7) is dropped: upgrades are rare.
10. **`TServiceCall` ownership.** The dispatcher owns the call and calls `Drop` exactly once, in `Finish`
    or on the cancel path; `TExchange.Cancel` does not (corrects 3.2.3 rule 6). A dispatcher test (not
    test scaffolding) asserts one `Drop` per cancelled call.
11. **Accept errors.** An exception from per-connection setup inside `OnAccept` is caught for that
    connection: close its fd, count it, log at most once per second, keep accepting. On `EMFILE`,
    `ENFILE`, `ENOBUFS` or `ENOMEM` the loop stops polling its listener for 1 s (timer) and then re-arms it.
    hyper 0.14's `AddrIncoming` (`sleep_on_errors`, src/server/tcp.rs) and axum's `serve` sleep 1 s on the
    same errors. Test: under a low `RLIMIT_NOFILE` with a full backlog, the loop's CPU use stays low and
    accepting resumes once fds are free. `TLoop.Create` sets `EpFd` and `WakeFd` to -1 before any syscall.
12. **Reproducible tooling.** Nothing in the project may depend on the session scratchpad.
    `tools/get-tools.sh` fetches and builds pinned versions of wrk and valgrind into `build/tools/`;
    scripts default to those paths. `run_all.sh` fails when valgrind is missing (no silent native run).
    The gate script becomes `bench/run_gate.sh`: it compares the response bytes with `cmp` before every gate
    run, and `compare.py` leaves client-bound runs out of the median (7.6).
13. **Test gaps found by the verifiers' mutants get tests.** These are: S3 m03 (`MaybeUnshift` with spare
    room exactly equal to `additional`), m07 (`max_header_size` boundary), m25 (`Headers.Reset` after a
    Flatten flush), and the slice count of `Test_write_buf_queue` (T1 removed the m03 test; it renamed
    the m25 test to `Cursor_flush_resets_cursor`, with the same assertions); T1 added a pooled
    `Parse_max_buf_size` case for the read clamp (DV-15); the four S4 survivors (leading CRLF then
    EOF while idle; `TryKeepAlive` after a body that ends once the response is in KeepAlive; a chunked
    terminator in its own read; `TBodyChan.PollNext` waking the sender only when needed); S5
    `Unbuffered_stream` (`TScriptIo` flags a write made while `WriteBlocked` is set, so a hot re-poll
    fails); a named test for item 7; the trailer differential's ERR output format (retired in T1); role
    differential `MaxHeaders` values above 100; `Library_callers_use_trusted_paths` made able to fail. Also
    `TConnScratch` trailer memory is released when the connection goes idle (4.3), and
    `EncodeHeadHeapFlags` loses its dynamic-array frame.

Decisions after S6 (2026-10-07; taken under the user's delegation, from the S6 verifier's findings):

14. **Flush at the end of a connection under `pipeline_flush`** (deviation S6-15). hyper 1.12.0's
    `poll_flush` writes nothing while the read buffer holds bytes (io.rs:279). When the connection is done
    at that moment (an upgrade or CONNECT hand-off with bytes after the request head, `without_shutdown`
    parts, or keep-alive off with a pipelined request behind), hyper drops the last response
    (`into_inner`, io.rs:270) or shuts down without it (`poll_shutdown` calls the same `poll_flush`).
    `ProductionH1Config` has `PipelineFlush = True` and upgrades, so it would lose 101 responses. wd-40
    flushes those bytes in `PollInner` once `IsDone` holds, before the hand-off or the shutdown. With
    `pipeline_flush` off (the conformance configuration) the condition is never true, so conformance
    behavior is hyper's. Under `pipeline_flush` on, wd-40 then differs from hyper only where hyper loses
    the response.

Decisions during S7 (2026-10-08; taken by Claude under the user's delegation "decide yourself the best
approach", from the three S7 verifiers' findings; all four confirmed by the user 2026-10-08). They are numbered
14-17 as the S7 task numbered them; "decision 14" in the sections before S7 means decision 14 after
S6 above, and the S7 text says "S7 decision 14" for the first one below. Implemented in the fourth S7
fix (deviations S7-27 to S7-30); the fifth S7 fix (from the fourth S7 verifiers' findings) corrected
decisions 15 and 16 where they were wrong or their implementation was (deviations S7-31 to S7-35;
the changes are marked "S7 fix round 5" below); the sixth (from the fifth S7 verifiers' findings)
corrected decision 15's reason for the unshared exchange and decision 16's failure path (deviations
S7-37 to S7-42, marked "S7 fix round 6"); the seventh (from the sixth S7 verifiers' findings)
corrected deviation S7-5's rule for the end of a stream nobody finished, which decision 15 relies on
for the echo (deviations S7-43 to S7-48, marked "S7 fix round 7"):

14. **Deviation S7-1 is accepted.** `chunk2::pipeline_enabled` is the one case allowed to fail in
    assertion mode in the worker-mode gate (7.4, 9 S7 exit; listed in
    `conformance/pascal-server/worker-exceptions.txt`), because `reference-server` (hyper) fails the
    same wire assertion when its second handler is Pending at its first poll (`extra/worker-probe.json`,
    checked by `gate_worker.sh` in every run). The inline gate stays 104/105 strict. Confirmed by the
    user 2026-10-08.
15. **Request-body lifetime on a shared exchange follows hyper** (confirmed by the user 2026-10-08). hyper's request (and its `Incoming`
    body) is owned by the service future and dropped with its last owner; the dispatcher feeds the body
    sender while the receiver lives (dispatch.rs:225-299), also after the response was sent, and when
    the receiver is dropped before the end it drains what one read gives or stops reading, so the
    connection is not kept alive (conn.rs:876-892 `poll_drain_or_close_read`). On a shared (worker)
    exchange the body receiver therefore stays open after the call completes (`Respond`, `Fail` or
    `BeginStream`) until the handler releases the request: `ReleaseRequest`, `DiscardBody`, or the
    `Release` of the last holder. S7 fix round 5 (deviation S7-32): the holders are the references
    `Share` handed out and the call in flight (hyper's service future owns `req` until it completes),
    so the request is never dropped while the call can still `Share` or `Offload`. A worker can stream
    its response while it reads the request body (`BeginStream`, then `ReadChunk`/`Write`: an echo).
    Rules: a read never returns a clean end of body unless the body really ended; when the loop's
    cancel wins against the handler's answer, the receiver closes and a blocking read raises
    `EClientGone` (3.2.3 rule 6); when the connection ends after the handler answered (whether or not
    the dispatcher had taken the answer), the sender goes with hyper's incomplete-message error, so
    the read gets the chunks that arrived and then raises `EBodyError` (S7 fix round 5, deviation
    S7-31: the decision as given listed "connection gone" with the closes that raise `EClientGone`;
    hyper's `SenderDropGuard` gives the body error, and round 4 gave `EClientGone` or `EBodyError` for
    the same event depending on the dispatcher's timing); every close of the receiver, by the loop or
    by a holder, unparks a parked reader (3.3), so no worker stays parked. This replaces the close at
    call completion of 3.3 and deviation S7-2. An unshared exchange is unchanged: its request is
    dropped at call completion. Corrected in the S7 fix round 6 (deviation S7-38; the round-5 text gave
    the reason "an inline handler cannot hold it longer", which is false: a response source polled on
    the loop after the completion can call `TryRead`): the read rule holds there too, so such a read
    reports `brCanceled` unless the reader saw the end, and a source that reads the body after the
    completion holds the request with `Share` in the call's `Poll` (3.2.3 rule 7).
16. **Response head writes on a shared exchange are single-threaded** (confirmed by the user
    2026-10-08). `Status`, `SetReason`,
    `ResponseVersion` and `ResponseHeaders` are written only by the thread that will make the terminal
    call, before that call. The answer claim of rule 5 (S7-23) protects `Resp.Body`, `Resp.Source`,
    `Resp.Failed` and `Resp.FailText` only. Builds with assertions check it (3.2.4) with the claim and
    the thread only: a cancel by the loop is not a terminal call, and a head write before the thread's
    own (losing) terminal call stays legal after it (S7 fix round 5, deviation S7-33). When the check
    of a claiming terminal call fails, the claim is given back before the assertion is raised and the
    call releases what it carried, so the job's own error answer (`handler raised ...`, which does not
    use the head and is not checked) still answers the request (S7 fix round 6, deviation S7-39).
17. **The debug checks of 3.2.4 (last paragraph) are implemented** (confirmed by the user
    2026-10-08). Builds with assertions assert
    `OnLoopThread` in every loop-only method of an unshared exchange, poison released head views (0xDD)
    and check a generation counter for the exchange's wake message. Release builds do not pay for them
    (`tools/check-hot-asm.sh --s7` and the performance gate).

### 0.4 The judges' flaws and how each is resolved

Ids: lens letter (C = conformance, P = performance, F = feasibility), candidate letter (F = faithful,
P = perf, A = api), number. "Section" points into this document.

| id | flaw (short) | resolution | section |
|---|---|---|---|
| C-F1 | hyper's `yield_now` is `wake_by_ref`; tokio puts the task at the back of the local run queue, not after the driver poll | Accepted (checked: `runtime/task/harness.rs:158`, `task/mod.rs:322`, `current_thread/mod.rs:709`). A yield pushes the task to the back of the run queue; it can run again in the same iteration within the 61-poll budget | 1.5 |
| C-F2 | readiness text does not say `READ_CLOSED` is sticky and bypasses the no-syscall `Pending` | Accepted. `rdReadClosed` and `rdWriteClosed` are never cleared and force the syscall (tokio 1.53.2 `ScheduledIo::clear_readiness`, `scheduled_io.rs:357-361`, keeps `READ_CLOSED` and `WRITE_CLOSED` only); `rdError` is also kept sticky by the port, while tokio can clear `ERROR` (it is not one of the two kept bits); harmless on TCP, where `EPOLLERR` comes with `EPOLLHUP`, which sets both closed bits (1.4); dedicated data+FIN test | 1.4, 7.3 |
| C-F3 | ARC-unique reserve summary wrong (`self.cap = new_cap`, not the whole block) | Accepted for the S2 port (checked by a Rust capacity table); T1 replaced the `BytesMut` port with a pooled block (2.2.1) | 2.2.1 |
| C-F4 | `THyperError` owns an `Obj`, moved by discipline | `THyperError` is plain data (no owned objects, no managed fields); dynamic text lives in one cold `RawByteString` field of the connection | 2.1 |
| C-F5 | worker-executor diff parity may be unachievable | Until T1 worker mode was gated in diff mode with an allowlist; since T1 both executors are gated in assertion mode (7.4) | 7.4 |
| C-P1 | handler runs inside `recv_msg`, so `handler_done` can appear where hyper emits `handler_dropped` | `Call` (in `recv_msg`) only creates the call; the handler body runs in `TServiceCall.Poll`, called only from `poll_msg` | 3.1 |
| C-P2 | push sink and `DropBody` in `Call` remove hyper's one-chunk prefetch | Request body is a port of `chan.rs` (pull, single slot, `want`), so the dispatcher prefetches as hyper does; the body receiver closes at `ReleaseRequest` or at call completion, as `drop(req)` (shared exchange: at `ReleaseRequest` or the handler's last `Release`, S7 decision 15) | 3.3 |
| C-P3 | read size `min(next, max - buffered)`, size-class blocks, no `BytesMut` port | S2 ported `BytesMut`; T1 replaced it: a pooled block, reads into the spare room up to `max_buf_size - len` (2.2.1) | 2.2 |
| C-P4 | "error end: close without shutdown" wrong for stored errors | `PollInner` is literal: `poll_shutdown` before `take_error`; propagated errors skip flush and shutdown | 2.4.2 |
| C-P5 | graceful shutdown without re-drive | `GracefulShutdown` = `DisableKeepAlive` then `Wake` (the reference server re-polls) | 1.11 |
| C-P6 | conformance listener uses `TCP_NODELAY` | conformance listener = mio options, no `TCP_NODELAY` on listener or accepted sockets | 6.1 |
| C-P7 | HUP not sticky | as C-F2 | 1.4 |
| C-P8 | small-chunk coalescing (D2) can reorder bytes | D2 dropped at first (two hyper strategies); T1 adopted it with an ordering rule: an entry that arrives while something is queued is queued (2.2.4) | 2.2.4 |
| C-P9 | signed `SizeInt` in `ReadStrategy`; 0.9/3.0 versions unspecified; `MaybeNotify` sets `NotifyRead` after a pending read | `TReadStrategy` uses `SizeUInt` (tests use `High(SizeUInt)` for `usize::MAX`); 0.9/3.0 abort the task (2.8); `MaybeNotify` returns on `Pending` without setting `NotifyRead` (conn.rs:543-560) | 2.2.2, 2.8, 2.3 |
| C-A1 | clock sampled before `epoll_wait` | sampled right after `epoll_wait` returns | 1.6 |
| C-A2 | single `ReadReady` flag cleared on a short read loses EOF | sticky closed bits (C-F2) | 1.4 |
| C-A3 | teardown always flushes and shuts down | literal `poll_inner` (C-P4) | 2.4.2 |
| C-A4 | handler in `recv_msg` not acknowledged | as C-P1 | 3.1 |
| C-A5 | 0.9/3.0 turned into `conn_close user` | `EncodeHead` checks the version where hyper panics and raises `EH1Panic`; the per-iteration handler aborts the connection task with no `conn_close` | 2.8, 1.10 |
| C-A6 | graceful shutdown without re-drive | as C-P5 | 1.11 |
| C-A7 | conformance listener uses `TCP_NODELAY` | as C-P6 | 6.1 |
| C-A8 | power-of-two classes; reads capped | as C-P3 | 2.2 |
| C-A9 | `procedure Record` does not compile | method is `Record_` (compiles: judge probe `m3-judge-conformance/p1.pas`, my probe `m3-final-probe/strhold.pas`) | 2.2.2 |
| C-A10 | worker variant only in assertion mode | as C-F5 | 7.4 |
| P-P1 | prototype has no state machine; 420 ns budget is an estimate | Kept as an estimate; checked at S5 with the dispatcher micro-benchmark over an in-memory transport (`bench/bench_dispatch.pas`, ns per request against `rawsrv`'s per-request work, S5-11) and gated at S5 end-to-end (7.6). S4 has no dispatcher, so its connection-level `bench_conn` number is reported only | 9 |
| P-P2 | read size `min(next, ...)` | as C-P3 | 2.2 |
| P-P3 | eventfd written whenever the stack was empty, even if the loop is awake | write only if the push found the stack empty and `Sleeping = 1` | 1.7 |
| P-P4 | production `PipelineFlush = True` differs from hyper | open question 1 | 0.3 |
| P-P5 | 19.5 ns frame cost vs 12.2-12.5 ns | both are measurements; the design states 12-20 ns; the rule (no frames in hot routines) does not depend on the exact value | 0.2 |
| P-P6 | `wrk 0.00` p99 cells, no wrk2, powersave governor, 1-2 runs | method: wrk2 at fixed rates for p99, 5 alternating runs per cell, median, governor recorded and set to `performance` when permitted | 7.6 |
| P-A1 | no measurements | this design starts from the measured prototype (0.2) | 0.2 |
| P-A2 | false claim that M2 has no implicit frames | confirmed false (`SetLengthEncoder`/`SetChunkedEncoder` get a frame; `TEncoder.FTrailerFields` is managed). S0 removes the managed fields and the asm check covers those routines | 4.4, 9 |
| P-A3 | full gate last, early gate 0.60 too loose | 0.80 per cell hard gate from S5 on; S1 raw loop within 3 % of the prototype | 9 |
| P-A4 | 0-7/8-15 split is client-bound at depth 1 | gate on configuration B; configuration A reported only; wrk CPU check | 7.6 |
| P-A5 | `AtomicOr` per inline request; global atomic connection id | no atomics on the inline path; connection ids are per loop (`LoopIndex shl 48 or Counter`) | 3.2.3, 1.3 |
| P-A6 | production `PipelineFlush = False` | as P-P4 | 0.3 |
| P-F1 | benchmark split puts wrk on the 4 E-cores | replaced by configuration B | 7.6 |
| P-F2 | first perf number at M3.6 | S1 (raw loop) and S5 (end-to-end gate) | 9 |
| P-F3 | copies tokio's run-queue hop, `epoll_wait(0)` every 61 polls, thread-id compare per wake | epoll events call the driver directly; the 61 budget only applies to run-queue tasks; local and remote wakes are separate methods, no thread-id compare | 1.5, 1.7 |
| P-F4 | atomic block refcounts per head and chunk; mutex body channel; vDSO date read per poll | loop-only pin counts; the body channel lock is taken only after `Share` (worker or other thread); date checked once per loop iteration | 4.2, 3.3, 1.6 |
| P-F5 | write head buffer is a managed `TBytes`; 4.3 vs 4.6 contradiction | head buffer is a pooled `TByteVec`, returned to the pool when idle | 2.2.4, 4.3 |
| P-F6 | unclear whether request/body objects are allocated per request | exchange reused per connection (pool when shared); the body channel is a record inside the exchange; call objects are singletons or pooled; zero allocations per request on the inline path | 4.5 |
| F-F1 | circular unit references | mutually dependent types share a unit; the interface `uses` graph in 8.1 is acyclic; S0 compiles interface skeletons of every unit | 8.1 |
| F-F2 | inline code must be poll state machines | inline handlers that answer at once are one `Poll` method; blocking controllers are plain sequential code on workers; only advanced loop-side code (timers, streams) is a state machine | 3.1, 3.8 |
| F-F3 | write buffer contradiction | as P-F5 | 2.2.4 |
| F-F4 | `try/except` per task poll costs a `setjmp` per poll | one `try/except` per loop iteration with resume | 1.10 |
| F-F5 | `Finalize` management operator on `BodyTx` | no management operators; ownership is explicit (`Drop` methods called by the dispatcher) | 2.4 |
| F-F6 | throughput first measured at M3.6 | as P-F2 | 9 |
| F-F7 | small inconsistencies (record vs class, property without read) | every type below is given once with its kind; S0 compiles the skeletons | 8.1, 9 |
| F-F8 | per-connection reused request/response objects do not fit HTTP/2 | one exchange per request/stream from the loop pool; per-connection reuse is an HTTP/1 optimization only | 3.2, 3.9 |
| F-P1 | nothing catches exceptions on loop threads (`ServerEncode` 0.9/3.0, validating `Add`) | per-iteration `try/except` aborts the faulty task; the version check happens before `ServerEncode` | 1.10, 2.8 |
| F-P2 | M5 runs steps 1-4 on the loop, breaking `_method` from the form body | the whole pipeline runs on the worker; the loop only classifies inline vs worker and never decides routing for form POSTs | 3.8 |
| F-P3 | read sizes deviate | as C-P3 | 2.2 |
| F-P4 | `bearings.http.body` / `bearings.http.exchange` circular | body, exchange and service types are in one unit, `bearings.http.exchange` | 8.1 |
| F-P5 | `out ErrMsg: RawByteString` in `PollFrame`; `TDecoder.FTrailerBuf` missed | `PollFrame` has no managed parameter (error text through the cold `Ex.SetBodyErrorText`); S0 also removes `TDecoder.FTrailerBuf` | 3.4, 4.4 |
| F-P6 | M5 section thin; head view invalid after answering | the head view lives until `ReleaseRequest` (hyper's `drop(req)`), not until the answer; M5 sketch with code | 3.2, 3.8 |
| F-P7 | `PipelineFlush` default | as P-P4 | 0.3 |
| F-A1 | clock before `epoll_wait` | as C-A1 | 1.6 |
| F-A2 | dual-mode refcount races (SSE example) | one atomic count changed only by `Share`/`Release`; `Share` is the only way to obtain a reference that may leave the loop thread, and it runs on the loop thread before publication | 3.2.3 |
| F-A3 | routing on the loop despite `_method` | as F-P2 | 3.8 |
| F-A4 | "cold" `try/except` is not cold | no `try` in any per-request routine; version pre-check; per-iteration handler | 1.10, 2.8 |
| F-A5 | wrong read cap / size-class claims | as C-P3 | 2.2 |
| F-A6 | M2 managed fields left in place | removed in S0 | 4.4 |
| F-A7 | M3.3 bundles too much; 0.60 gate | eleven steps S0-S10, each with its own tests and exit criteria | 9 |
| F-A8 | one large exchange with hard cross-thread invariants | the exchange is split into three records (head view, body channel, response slot) and every cross-thread field has one written rule (3.2.4); debug builds assert the owner thread | 3.2.4 |

---
## 1. Threading and reactor

### 1.1 Shape

```
TServer
  ├─ N x TLoop (one OS thread each, created with BeginThread; the main thread only supervises)
  │    ├─ epoll fd (connections edge-triggered), eventfd, TMpscStack inbox, Sleeping flag
  │    ├─ TTimerWheel, TDateCache, TBlockPool, TExchangePool, run queue, deferred-free list
  │    ├─ listener (own SO_REUSEPORT socket, or the shared EPOLLEXCLUSIVE one)
  │    └─ connection drivers: TH1Dispatcher (later TH2Session), TUpgraded streams, other TLoopTasks
  └─ TWorkerPool (W threads, optional) for blocking handlers
```

Shared-nothing: a connection lives and dies on the loop that accepted it. Nothing on the inline
request path takes a lock, uses an atomic instruction or touches another core's data. Cross-thread
traffic exists only for exchanges handed to workers or other threads, and for server-wide commands.

### 1.2 Loops per core and CPU count

```pascal
unit bearings.rt.cpu;
interface
type
  TCpuList = array of Integer;
{ sched_getaffinity(0, ...) via syscall 204: the CPU ids the process may run on, ascending. }
function UsableCpus: TCpuList;
{ A port of num_cpus 1.17.0 src/linux.rs (cgroups_num_cpus): the process's own cgroup, found
  through /proc/self/cgroup and /proc/self/mountinfo (Subsys::load_cpu, MountInfo::load_cpu,
  translate / strip_prefix); v2 cpu.max "quota period" or v1 cpu.cfs_quota_us /
  cpu.cfs_period_us; Ceil(quota / period); 0 when there is no quota. The literal
  /sys/fs/cgroup/cpu.max is the root cgroup's file and is right only for a process in the root. }
function CgroupCpuLimit: Integer;
{ Max(1, Min(Length(UsableCpus), CgroupCpuLimit if > 0)), num_cpus::get(). Falls back to
  parsing /sys/devices/system/cpu/online if the syscall fails (num_cpus uses sysconf there). }
function DefaultLoopCount: Integer;
{ sched_setaffinity(0, {Cpu}) via syscall 203. }
function PinCurrentThread(Cpu: Integer): Boolean;
```

Two details differ from num_cpus and change nothing on Linux as used here: the cgroup path is taken as
everything after the second `:` of a `/proc/self/cgroup` line (num_cpus takes the third field), and the
fallback reads `/sys/devices/system/cpu/online` instead of `sysconf(_SC_NPROCESSORS_ONLN)`.

`TServerConfig.Loops = 0` means `DefaultLoopCount`. Pinning is off by default (`PinLoops = False`):
hyper's TFB entry does not pin, and pinning measured within 1 % (perf T2).

### 1.3 Accept

| mode | sockets | used by |
|---|---|---|
| `amReusePort` (default) | one listener per loop: `SO_REUSEADDR`, `SO_REUSEPORT`, `TCP_NODELAY`, non-blocking, cloexec, backlog 4096 (hyper TFB `create_socket`). With port 0 the first loop binds, reads the port with `getsockname`, the others bind that port | production, benchmarks |
| `amSharedExclusive` | one listening socket (the `TListenSpec` options, no `SO_REUSEPORT`); every loop registers its own `dup` of it (`F_DUPFD_CLOEXEC`) with `EPOLLIN or EPOLLEXCLUSIVE`, so the kernel wakes one waiting loop per new connection (S8) | option for uneven load (measured equal throughput); `beconf --loops N` |
| `amSingle` | one listener on loop 0, configured like mio 1.2.4 `TcpListener::bind`: `SO_REUSEADDR`, backlog 128, **no** `TCP_NODELAY`; accepted sockets get no `TCP_NODELAY` | the conformance server |

Accepted sockets inherit `TCP_NODELAY` from the listener on Linux; S1 has a test that reads it back
with `getsockopt` and, if a kernel does not inherit it, the accept path sets it per socket.

Accept loop: on listener readiness, `accept4(fd, @Addr, @AddrLen, SOCK_NONBLOCK or SOCK_CLOEXEC)` up
to 64 times or until `EAGAIN`. `EINTR` and the connection errors `ECONNABORTED`, `ECONNRESET`,
`ECONNREFUSED` go on to the next `accept4`. Every other error (`EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`,
...) is counted, logged at most once per second, and the listener stops being polled for 1 s: it is
removed from the loop's epoll set (`EPOLL_CTL_DEL`; `EPOLLEXCLUSIVE` registrations cannot be modified)
and a 1 s loop timer adds it back. A level-triggered listener with a non-empty backlog would otherwise be
reported by every `epoll_wait` and the loop would spin at 100 % CPU until fds are free. hyper 0.14's
`AddrIncoming` (`sleep_on_errors`, src/server/tcp.rs) and axum's `serve` sleep 1 s on the same errors
(decision 11; deviation DV-9: hyper's TFB accept loop would end the runtime instead).

Per-connection setup runs in `OnAccept` (`TAcceptEvent`, called with `var Fd`): the handler sets
`Fd := -1` as soon as something else owns the socket. An exception from it is caught by the listener for
that connection only: the listener closes `Fd` if it is still `>= 0`, counts it (`SetupErrors`), logs at
most once per second and keeps accepting; the handler releases what it created (the server's `OnAccept`
aborts and closes its dispatcher, which closes the socket, and re-raises). One `try/except` per accepted
connection, none per request.

`TLoop.Create` sets `EpFd` and `WakeFd` to -1 before any syscall, so a constructor that fails part-way
(for example `eventfd2` with `EMFILE`) closes only the fds it opened.

Connection ids: `QWord(LoopIndex) shl 48 or Loop.NextConnSeq` (no atomic). The conformance server
runs one loop and numbers connections 1, 2, ... in accept order in its observer.

```pascal
unit bearings.rt.net;
interface
uses bearings.rt.sys, bearings.rt.loop;
type
  TAcceptMode = (amReusePort, amSharedExclusive, amSingle);
  TListenSpec = record
    Host: RawByteString;           { '0.0.0.0', '127.0.0.1', '::' }
    Port: Word;                    { 0 = kernel-assigned }
    Backlog: Integer;              { 4096 production, 128 for amSingle }
    Mode: TAcceptMode;
    NoDelay: Boolean;              { False for amSingle }
  end;

  { Called on the loop thread for every accepted socket. Fd is non-blocking; the handler sets
    Fd := -1 once something else owns it; an exception closes Fd (if >= 0) and is counted. }
  TAcceptEvent = procedure(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage) of object;

  TListener = class(TIoTask)
  public
    Accepted, AcceptErrors, SetupErrors, Pauses: QWord;   { statistics }
    constructor Create(ALoop: TLoop; Fd: cint; OnAccept: TAcceptEvent; Events: Cardinal = EPOLLIN);
    procedure OnIo(Events: Cardinal); override;   { accept batch of at most 64 }
    { accept until EAGAIN, then close (1.11). Close takes the fd out of the loop's epoll set first:
      an epoll entry lives as long as the open file, and the amSharedExclusive dups share it (S8) }
    procedure DrainAndClose;
    procedure Resume;                             { the 1 s timer: register again }
    property Paused: Boolean;                     { out of epoll after an accept error }
  end;

function OpenListener(const Spec: TListenSpec; ReusePort: Boolean; out Fd: cint;
  out BoundPort: Word; out Errno: cint): Boolean;
```

### 1.4 epoll mode and readiness (tokio rules)

Every connection socket is added once with `EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET` and the
`PIoSource` in `data.ptr`, and never modified (backpressure = not calling `read`/`write`). Removal is
implicit at `close`. Level-triggered epoll was rejected: it reports a socket on every `epoll_wait` while
its connection waits for the application, and toggling `EPOLLOUT` costs an `epoll_ctl` per blocked write.

```pascal
unit bearings.rt.loop;   { excerpt; full unit in 1.5 }
type
  TIoTask = class;                { forward: declared in 1.5, same unit }
  TReadyBit = (rdRead, rdWrite, rdReadClosed, rdWriteClosed, rdError);
  TReadySet = set of TReadyBit;

  PIoSource = ^TIoSource;
  TIoSource = record          { first field of every fd-owning task; epoll data.ptr points here }
    Fd: cint;
    Ready: TReadySet;
    Task: TIoTask;
  end;

{ Event bits -> readiness, as mio 1.2.4 selector/epoll.rs + tokio Ready::from_mio:
    EPOLLIN                                   -> rdRead
    EPOLLOUT                                  -> rdWrite
    EPOLLHUP, or (EPOLLIN and EPOLLRDHUP)     -> rdReadClosed   (sticky)
    EPOLLHUP, or (EPOLLOUT and EPOLLERR)      -> rdWriteClosed  (sticky)
    EPOLLERR                                  -> rdError        (sticky) }
function ReadyFromEpoll(Events: Cardinal): TReadySet; inline;
```

The TCP transport applies tokio 1.53.2 `PollEvented` rules (`io/poll_evented.rs`):

| call | kernel called when | after the call |
|---|---|---|
| `Read` | `Ready * [rdRead, rdReadClosed, rdError] <> []` | `EAGAIN`: exclude `rdRead`, return `-EAGAIN`. `0 < n < Len`: exclude `rdRead` (the socket buffer was drained). `n = Len`: keep. `n = 0`: EOF. The closed bits are **never** cleared (tokio); the port keeps `rdError` too (see below) |
| `Write` (scalar) | `Ready * [rdWrite, rdWriteClosed, rdError] <> []` | `EAGAIN` or `0 < n < Len`: exclude `rdWrite` |
| `WriteV` | same as `Write` | `EAGAIN`: exclude `rdWrite`; a short `writev` keeps `rdWrite` (tokio `poll_write_vectored` uses `poll_write_io`, which only clears on `WouldBlock`) |
| `SendFile` | same as `Write` | `EAGAIN`: exclude `rdWrite` |

How this compares with tokio 1.53.2: `Direction::mask` is `READABLE | READ_CLOSED` for reads and
`WRITABLE | WRITE_CLOSED` for writes (`runtime/io/driver.rs:346-351`), and
`ScheduledIo::clear_readiness` (`scheduled_io.rs:357-361`) removes everything it was given except
`READ_CLOSED` and `WRITE_CLOSED`. So tokio keeps only the two closed bits; its `ERROR` bit can be cleared.
The port also keeps `rdError` sticky and lets it force the syscall. On a TCP socket `EPOLLERR` arrives
together with `EPOLLHUP`, which sets both closed bits, so the difference is not observable there. On
`EAGAIN` tokio clears the readiness and polls readiness again; the port returns `Pending` at once, also
when a sticky closed bit is set; that differs only if a socket with a closed bit can return `EAGAIN`.

Why the sticky bits matter: when the client writes a request and closes, data and FIN often arrive in
one event (`EPOLLIN or EPOLLRDHUP`). The head read is short, so `rdRead` is cleared; without a sticky
`rdReadClosed` the next read (hyper's `mid_message_detect_eof`) would return `Pending` without a
syscall and the EOF would be lost (`disconnect_after_reading_request_before_responding` would hang).
With the sticky bit the read calls the kernel, gets 0, and the connection ends with `incomplete`.

`SIGPIPE` is ignored process-wide at server start (`fpSignal(SIGPIPE, SIG_IGN)`), as the Rust runtime
does; a write to a reset socket returns `EPIPE`, which becomes an io error.

### 1.5 Tasks, wakes and the run queue

```pascal
unit bearings.rt.loop;
interface
uses bearings.rt.sys, bearings.rt.clock, bearings.rt.sync, bearings.rt.timer, bearings.rt.buf, bearings.http.date;
type
  TLoop = class;

  { Anything the loop can run: a connection driver, an upgrade task, the control task. }
  TLoopTask = class
  private
    FRunNext: TLoopTask;           { intrusive run-queue link }
    FQueued: Boolean;              { in the run queue }
    FRunning: Boolean;             { inside Run / OnIo }
    FNotified: Boolean;            { woken while running: re-queue at the back afterwards }
    FClosed: Boolean;              { closed in this batch: no more runs, freed after the batch }
    FFreeNext: TLoopTask;
  public
    Loop: TLoop;
    { One poll. Loop thread only. }
    procedure Run; virtual; abstract;
    { Called instead of more polls when Run raised (1.10) or at the shutdown deadline.
      Releases everything, closes the fd, emits nothing (tokio: aborted task). }
    procedure Abort; virtual; abstract;
    { tokio wake_by_ref, loop thread only: queue at the back unless queued; while running,
      only mark FNotified (the loop re-queues after Run returns). }
    procedure Wake; inline;
    { Close: FClosed := True, Loop.DeferFree(Self) (freed after the event batch, finding F10). }
    procedure Close;
  end;

  TIoTask = class(TLoopTask)
  public
    Src: TIoSource;
    { Socket event: Src.Ready := Src.Ready + ReadyFromEpoll(Events); then, unless the task is
      queued or closed, call Run directly (no run-queue hop). }
    procedure OnIo(Events: Cardinal); virtual;
  end;
```

Semantics, matched to tokio's current-thread scheduler where it is observable:

- **Local wake** (`Wake`, loop thread only): push at the back of the run queue if not queued; if the
  task is running, set `FNotified` and push it at the back after its `Run` returns. This is what
  `wake_by_ref` during a poll does in tokio (`harness.rs:158` → `Schedule::yield_now` → `schedule` →
  `core.push_task`).
- **Yield** (hyper `task::yield_now` after 16 `poll_loop` iterations, dispatch.rs:222): `Wake` on itself
  while running, return Pending. The task goes to the back of the run queue and runs again in the same
  iteration if the 61-poll budget allows, before the next `epoll_wait`. (Correction of the faithful
  candidate, judge C-F1.)
- **Socket events** call `OnIo` → `Run` directly. tokio routes every IO wake through the run queue; the
  direct call removes that hop (perf finding: one read and one write per request batch). If the task is
  already queued (it yielded or was woken), the event only sets readiness bits; the queued run sees them.
- **Remote wake** (another thread): through the inbox (1.7), then `Wake` on the loop thread.

### 1.6 The loop iteration

```pascal
type
  TLoopMsgKind = (lmWakeExchange, lmFreeExchange, lmCall);
  PLoopMsg = ^TLoopMsg;
  TLoopMsgProc = procedure(Loop: TLoop; Arg: Pointer);
  TLoopMsg = record               { embedded in its sender: posting allocates nothing }
    Node: TMpscNode;              { first field: the inbox link (bearings.rt.sync) }
    Kind: TLoopMsgKind;
    Proc: TLoopMsgProc;           { lmCall }
    Arg: Pointer;                 { the exchange (lmWake*/lmFree*), or Proc's argument }
  end;

  TLoop = class
  public
    Index: Integer;
    ThreadId: TThreadID;
    EpFd, WakeFd: cint;
    NowNs, NowMs: Int64;          { CLOCK_MONOTONIC, sampled after epoll_wait }
    Date: TDateCache;             { per loop; not the M2 threadvar cache }
    Timers: TTimerWheel;
    Blocks: TBlockPool;
    Exchanges: Pointer;           { the loop's TExchangePool; the type lives in bearings.http.exchange }
    NextConnSeq: QWord;
    Sleeping: LongInt;            { 1 while the loop may be blocked in epoll_wait }
    Inbox: TMpscStack;
    procedure Run;                { thread body: while not Stopped do try RunIteration except ... }
    procedure RunIteration;
    procedure Post(M: PLoopMsg);  { any thread (1.7) }
    function Register(Src: PIoSource; Events: Cardinal): Boolean;   { EPOLL_CTL_ADD }
    procedure Unregister(Src: PIoSource);                           { EPOLL_CTL_DEL (upgrade Detach) }
    procedure DeferFree(T: TLoopTask);
    property Current: TLoopTask read FCurrent;   { task being run; used by 1.10 }
    { private fields (FCurrent, FEvents, FEventPos, FEventCount, run queue, free list, FStopped,
      FNextDateCheckNs) elided }
  end;

const
  RUN_QUEUE_BUDGET = 61;          { tokio current_thread event_interval }
  MAX_EVENTS = 1024;
```

`RunIteration` (one iteration):

```
 1. if FEventPos < FEventCount: goto 4            { resume a batch interrupted by an exception (1.10) }
 2. Timeout := 0 if run queue or inbox not empty, else Timers.NextTimeoutMs(NowNs) (-1 = none)
    if Timeout <> 0: InterlockedExchange(Sleeping, 1); if Inbox not empty: Timeout := 0
    FEventCount := epoll_wait(EpFd, @FEvents, MAX_EVENTS, Timeout); FEventPos := 0
    Sleeping := 0
 3. NowNs := MonoNowNs; NowMs := NowNs div 1000000
    if NowNs >= FNextDateCheckNs then Date.Check(RealNowUs) and set FNextDateCheckNs   (once per second)
 4. while FEventPos < FEventCount:
      E := FEvents[FEventPos]; Inc(FEventPos)
      listener   -> accept batch
      eventfd    -> read(WakeFd) to reset; drain Inbox (FIFO): lmWakeExchange -> owner.Wake;
                    lmFreeExchange -> recycle; lmCall -> Proc(Self, Arg)
      task       -> if not task.FClosed: FCurrent := task; task.OnIo(E.Events)
 5. Timers.Advance(NowMs)        { fired entries call their Proc; a Proc normally Wakes a task }
 6. Budget := RUN_QUEUE_BUDGET
    while (Budget > 0) and RunQueue.Pop(T): FCurrent := T; T.FRunning := True; T.Run;
      T.FRunning := False; if T.FNotified then re-queue at back; Dec(Budget)
 7. FCurrent := nil; free every task in the deferred-free list (F10: a task closed in this
    iteration may still be referenced by a later event of the same batch or by a queued wake)
```

Clock: read once per iteration, after `epoll_wait` (correction of api, judges C-A1/F-A1). hyper reads
`Instant::now()` when it arms the header timer; ours uses `NowNs` of the current iteration, which is
earlier by at most the time spent in that iteration (deviation DV-6). Date: hyper checks
`SystemTime::now()` at every dispatcher poll (`T::update_date()`, dispatch.rs:148); we check once per
iteration (DV-6); dates are normalized by the runner and the header is regenerated once per second
either way.

### 1.7 Wakeups across threads

```pascal
unit bearings.rt.sync;
interface
type
  PMpscNode = ^TMpscNode;
  TMpscNode = record Next: PMpscNode; end;   { first field of TLoopMsg (bearings.rt.loop) }
  TMpscStack = record              { intrusive, lock-free; producers CAS on Head }
    Head: PMpscNode;
    { any thread; True if the stack was empty before the push }
    function Push(N: PMpscNode): Boolean;
    { owner thread; the whole batch, already reversed to FIFO order, or nil }
    function TakeAll: PMpscNode;
  end;

  TParker = record                 { one waiter; futex (syscall 202) on State }
    State: LongInt;                { 0 empty, 1 notified, 2 a thread is parked }
    procedure Park(TimeoutMs: Integer = -1);   { consume a notification (1 -> 0), else 0 -> 2 and
                                                 futex_wait while State = 2; then State := 0 }
    procedure Unpark;                          { State := 1; futex_wake(1) only if State was 2 }
  end;

  { any number of waiters (TChannelBody's producers; added in the S7 fix, deviation S7-19) }
  TEventCount = record
    Seq, Waiters: LongInt;
    function Key: LongInt;                     { read under the caller's lock, before it waits }
    procedure Wait(K: LongInt);                { Waiters += 1; futex_wait while Seq = K; Waiters -= 1 }
    procedure NotifyAll;                       { Seq += 1; futex_wake(all) only if Waiters > 0 }
  end;

  TSpinLock = record               { used only by shared exchanges (3.2.3) }
    State: LongInt;
    procedure Acquire; inline;     { xchg loop with pause; falls back to sched_yield after 1000 spins }
    procedure Release; inline;
  end;
```

`TLoop.Post(M)`: `WasEmpty := Inbox.Push(M)`; if `WasEmpty and (InterlockedExchange(Sleeping, 0) = 1)`
then `write(WakeFd, 1)`. A post to an awake loop costs one CAS and no syscall (api's `Sleeping` flag
plus perf's "only the first push of a batch signals"). The loop re-checks the inbox after setting
`Sleeping` (step 2), so a post that races with going to sleep is not lost.

S7 fix round 6 (deviation S7-37): `Post` brackets these steps with `InterlockedIncrement(Posting)` /
`InterlockedDecrement(Posting)`. Once the message is pushed the loop may handle it, and an exchange's
last `FreeMsg` returns the exchange to its pool, while the posting thread still reads `Sleeping` and may
write the eventfd. A thread that frees the loop (`TServer.Destroy`) therefore waits for `Posting = 0`
after every exchange is back in its pool. Cost: two locked instructions per cross-thread post (off-loop
paths only; the inline path never posts).

Messages are embedded in the objects that send them (each exchange has `WakeMsg` and `FreeMsg`, 3.2.3),
so posting never allocates.

### 1.8 Timers

```pascal
unit bearings.rt.timer;
interface
type
  PTimer = ^TTimer;
  TTimerProc = procedure(T: PTimer);   { plain procedure; T^.Owner is the object }
  TTimer = record                      { embedded in its owner }
    Prev, Next: PTimer;
    Deadline: Int64;                   { ms (loop clock) the owner wants; 0 = not wanted }
    Due: Int64;                        { ms of the slot it is filed in; 0 = not filed }
    Level, Slot: SmallInt;
    Proc: TTimerProc;
    Owner: Pointer;
    Fired: Boolean;                    { set when Proc ran for the current Deadline }
  end;

  TTimerWheel = record                 { tokio runtime/time/wheel: 6 levels x 64 slots, 1 ms }
    procedure Init(NowMs: Int64);
    { Deadline in ms, rounded up from ns like tokio (deadline_to_tick). Lazy: when T is filed with
      Due <= DeadlineMs only Deadline is stored; when Due > DeadlineMs it is refiled. Fired := False. }
    procedure Arm(T: PTimer; DeadlineMs: Int64);
    { Lazy cancel: Deadline := 0 (the filed entry is dropped when its slot expires). }
    procedure Cancel(T: PTimer); inline;
    { Unlinks now: for owners about to be freed. }
    procedure Remove(T: PTimer);
    { Expires slots up to NowMs. An entry with Deadline = 0 is unlinked; Deadline > NowMs is refiled
      at Deadline; otherwise Fired := True and Proc(T). }
    procedure Advance(NowMs: Int64);
    function NextTimeoutMs(NowNs: Int64): Integer;   { -1 when nothing is filed }
  end;
```

A wheel, not a heap: the header-read timer is armed for every request of every keep-alive connection
and cancelled when the head is parsed (conn.rs:223-283). With lazy arm/cancel the common case is two
stores per request, and the occasional refile is O(1). Users in M3: the header read timeout (also the
keep-alive idle timeout, 2.3), application delays (`TWakeTimer`, 3.2), stream item delays in the
conformance server, the graceful-shutdown deadline. The wheel is tested against a sorted-list reference
with random arm/cancel/advance and against a table of tokio's rounding.

### 1.9 Clock and date

```pascal
unit bearings.rt.clock;
interface
function clock_gettime(Clk: cint; Tp: Pointer): cint; cdecl; external 'c';   { vDSO, 11 ns }
function MonoNowNs: Int64; inline;    { CLOCK_MONOTONIC }
function RealNowUs: Int64; inline;    { CLOCK_REALTIME, for the Date header }
```

`TEncodeContext.Date` (2.2.4) is `@Loop.Date` bytes, so `ServerEncode` never reads the M2 threadvar
`DateBuffer` (2.7 ns per access).

### 1.10 Exceptions on loop threads

FPC enters a `try` block with `fpc_pushexceptaddr` + `fpc_setjmp` (12-20 ns), so no per-request routine
has one. Instead:

```pascal
procedure TLoop.Run;
begin
  while not FStopped do
    try
      RunIteration;
    except
      on E: Exception do
        AbortCurrent(E);      { log; if FCurrent <> nil: FCurrent.Abort; FCurrent.Close }
    end;
end;
```

`RunIteration` resumes an interrupted event batch at `FEventPos` (step 1), so the events after the
faulty one are not lost and no extra `epoll_wait` happens. One `setjmp` per loop iteration, amortized
over the batch.

Semantics: an exception that escapes a task aborts that task, as a panic aborts a tokio task:
`TH1Dispatcher.Abort` runs the drop path (in-flight call dropped, body channels closed, fd closed) and
emits no `conn_close` (the reference server's `serve_conn` future is unwound, its `emit_conn_close` never
runs). Sources of such exceptions: `EH1Panic` for an HTTP/0.9 or HTTP/3.0 response version (2.8),
`EInvalidHeader` from a validating `THttpHeaders.Add` called by an inline handler, out-of-memory, range
errors in debug builds. Worker threads catch exceptions per job (3.5).

### 1.11 Graceful shutdown

Per connection (`Connection::graceful_shutdown`, dispatch.rs:90-100):

```pascal
procedure TH1Dispatcher.GracefulShutdown;
begin
  if FUpgraded then Exit;                                   { no effect after the hand-off }
  Conn.DisableKeepAlive;                                    { idle -> State.Close; else disable }
  if Conn.IsWriteClosed or Conn.HasInitialReadWriteState then
    Close_;                                                 { is_closing := True; close read+write }
  Wake;   { the reference server re-polls the connection; an idle connection must notice now }
end;
```

Server-wide:

```pascal
unit bearings.server;
type
  TServer = class
  public
    constructor Create(const Cfg: TServerConfig; Factory: TServiceFactory;
      Observer: TConnObserver = nil);
    procedure Start;               { bind, start loops and workers; returns }
    procedure Wait;                { until every loop thread has exited }
    { SPEC graceful_shutdown: GracefulShutdown on every connection open now, on every loop.
      Returns after every loop applied it (lmCall per loop + countdown + RTLEvent).
      Listeners keep accepting. }
    procedure GracefulShutdownConnections;
    { Stop: each loop drains its accept queue (accept4 until EAGAIN), closes the listener, applies
      GracefulShutdown to every connection, exits when it has none or at the deadline (remaining
      tasks: Abort). Returns at once; Wait joins the loops and then shuts the worker pool down.
      Any thread. }
    procedure Stop(GraceMs: Integer);
    { opt-in signal helper (S8): blocks SIGTERM and SIGINT in the calling thread, Start (the loop
      and worker threads inherit the mask), Started(Self), sigtimedwait for one of the two,
      Stop(Config.GraceMs), Wait; restores the mask; returns the signal number }
    function RunUntilSignal(Started: TServerEvent = nil): cint;
    property Port: Word read FPort;
  end;
```

What a client sees during `Stop` (S8; `tests/unit/test_server.pas`, `Stop_under_load*`): a request
the server has read (its `Call` was made) gets its full response, with `connection: close`, unless the
grace deadline aborts it. A connection on which no request byte was read when the stop reached its
loop (an idle keep-alive connection, a connection the drain accepted, a request still in the socket
buffer) is closed without a response, as hyper's `graceful_shutdown` closes a connection with no read
yet; the client sees EOF or a reset. A connection that reaches a listener's queue after its last
`accept4` and before its `close` is reset by the kernel (the accept window); connections after the
close are refused. Neither case can lose a request the server received.

### 1.12 System call layer

`bearings.rt.sys` has inline-asm `syscall` stubs (x86_64: rax = number, args in rdi, rsi, rdx, r10, r8, r9)
that return the raw kernel result, `-errno` on failure. They do not call FPC's `seterrno` (a threadvar
write) and do not touch the `Sockets` unit's `internal_socketerror` threadvar. Calls: `read`, `write`,
`writev`, `sendfile`, `accept4`, `epoll_create1`, `epoll_ctl`, `epoll_wait`, `eventfd2`, `shutdown`,
`close`, `setsockopt`, `getsockopt`, `getsockname`, `bind`, `listen`, `socket`, `futex`,
`sched_getaffinity`, `sched_setaffinity`. S1 verifies each stub against the FPC RTL equivalent.

---
## 2. Connection state machine: port of io.rs, conn.rs, dispatch.rs

### 2.1 Port rules and shared types

The engine was written as a port: each hyper function became one Pascal method with the hyper name in
Pascal case and a `{ conn.rs:NNN }` comment. Since step T1 (user decision 2026-10-08: hyper's features,
not its implementation) changes need not keep hyper's statement order or line references; the
conn/dispatch control flow stays (it implements keep-alive, pipelining, half-close, upgrades and
graceful shutdown). Client-only branches (`T::is_client()`,
`require_empty_read`, `h09_responses`, `on_informational`, `ReadStrategy::Exact`) are dropped;
`T::should_read_first()` is `True`, `T::should_error_on_parse_eof()` is `False`. Deviations are in the
register (8.2).

Wakers disappear: one task drives one connection, so "register the waker" means "the event that ends
this `Pending` wakes this connection's task". Section 2.4.5 lists the wake sources.

```pascal
type
  TPollResult = (prOk, prErr, prPending);        { Poll<Result<(), Error>> }
  TPollOpt = (poSome, poErr, poNone, poPending);  { Poll<Option<Result<T>>> }
```

| Rust | Pascal |
|---|---|
| `ready!(x)` | `if R = prPending then Exit(prPending);` |
| `x?` | `if R = prErr then Exit(prErr);` (the error is already in `var Err`) |
| `Option<T>` field | `T` plus `HasX: Boolean`, `nil` for objects, `-1` for sizes |
| `Reading::Body(Decoder)` | `Reading: TReading` plus `ReadDecoder: TDecoder` |
| `Pin<Box<dyn Future>>` | object reference with a virtual `Poll` |

```pascal
unit bearings.http.error;           { port of src/error.rs, server-side kinds }
interface
uses bearings.http1.role, bearings.http1.decode;
type
  THyperErrorKind = (hekNone, hekParse, hekUser, hekIncompleteMessage, hekUnexpectedMessage,
    hekCanceled, hekChannelClosed, hekIo, hekHeaderTimeout, hekBody, hekBodyWrite,
    hekBodyWriteAborted, hekShutdown);
  THyperUserKind = (hukNone, hukBody, hukService, hukUnsupportedStatusCode, hukNoUpgrade,
    hukManualUpgrade, hukHeader);
  TErrorCause = (ecNone, ecErrno, ecDecode, ecStatic, ecConnText, ecInner);

  { Plain data: no managed fields, no owned objects. Copying is a memcpy; routines with a
    THyperError local get no implicit exception frame. }
  THyperError = record
    Kind: THyperErrorKind;
    Parse: TH1ParseError;            { hekParse (h1peVersionH2 for the h2 preface) }
    User: THyperUserKind;            { hekUser }
    Cause: TErrorCause;
    Errno: cint;                     { ecErrno: an io::Error from the OS }
    Decode: TDecodeError;            { ecDecode: the body decoder's io::Error }
    StaticMsg: PAnsiChar;            { ecStatic: 'connection error', ... }
    InnerKind: THyperErrorKind;      { ecInner: one wrapped level (new_body(cause), new_user_body) }
    NotEofRemaining: QWord;          { hekBodyWriteAborted }
    { ecConnText: the text is in the owning connection's FErrorText (cold RawByteString field) }
    function IsParse: Boolean;  function IsParseTooLarge: Boolean;  function IsParseVersionH2: Boolean;
    function IsUser: Boolean;  function IsCanceled: Boolean;  function IsClosed: Boolean;
    function IsIncompleteMessage: Boolean;  function IsBodyWriteAborted: Boolean;
    function IsShutdown: Boolean;  function IsTimeout: Boolean;   { HeaderTimeout or ETIMEDOUT cause }
    function HasIoSource: Boolean;                                { SPEC 7.2 'io' }
  end;

function NewParse(E: TH1ParseError): THyperError;      function NewIncomplete: THyperError;
function NewTooLarge: THyperError;                      function NewVersionH2: THyperError;
function NewIo(Errno: cint): THyperError;               function NewHeaderTimeout: THyperError;
function NewBodyDecode(E: TDecodeError): THyperError;   function NewBodyIo(Errno: cint): THyperError;
function NewBodyStatic(Msg: PAnsiChar): THyperError;    function NewBodyWrite(Errno: cint): THyperError;
function NewBodyWriteAborted(Remaining: QWord): THyperError;
function NewShutdown(Errno: cint): THyperError;         function NewUserService: THyperError;
function NewUserBody: THyperError;                      function NewUserHeader: THyperError;
function NewUserUnsupportedStatusCode: THyperError;     function NewUserManualUpgrade: THyperError;
function NewClosed: THyperError;
{ hyper Display text, cold path (strings allowed). ConnText: the connection's FErrorText. }
function ErrorDescription(const E: THyperError; const ConnText: RawByteString): string;
```

### 2.2 io.rs: buffers, read strategy, write path

#### 2.2.1 `TReadBuf`: the read buffer

The read buffer is one block from the loop's block pool (4.3). `Ptr`/`Len` are the unread bytes; `Cap`
counts the bytes from `Ptr` to the end of the block. A request head or a body chunk leaves the buffer as
a `TBytesView` that pins the block (`SplitTo`).

```pascal
unit bearings.rt.buf;
interface
type
  PBlockPool = ^TBlockPool;
  PBufBlock = ^TBufBlock;
  TBufBlock = record
    Data: PByte;                 { 64-byte aligned, Size bytes }
    Size: SizeInt;               { pool class, or the exact size of a heap block }
    Pins: Integer;               { live views (TBytesView); loop thread only }
    Detached: Boolean;           { the TReadBuf left this block; free when Pins drops to 0 }
    Pool: PBlockPool;            { nil: a heap block }
    NextFree: PBufBlock;
  end;

  TBytesView = record            { a slice that keeps its block alive }
    P: PByte;
    Len: SizeInt;
    Block: PBufBlock;            { nil: static or caller-owned memory }
    procedure Release; inline;   { loop thread: Dec(Block^.Pins); free a Detached block at 0 }
  end;

  TReadBuf = record
    Block: PBufBlock;            { nil: no memory (never used, or given back while idle) }
    Ptr: PByte;                  { start of the unread bytes }
    Len: SizeInt;
    Cap: SizeInt;                { bytes from Ptr to the end of the block }
    function SpareCapacity: SizeInt; inline;             { Cap - Len }
    function SpareData: PByte; inline;                   { Ptr + Len }
    procedure Reserve(Additional: SizeInt; Pool: PBlockPool); inline;   { fast path, then ReserveSlow }
    procedure AdvanceMut(N: SizeInt); inline;            { after read(2): Len += N }
    procedure Advance(N: SizeInt); inline;               { drop N unread bytes }
    function SplitTo(N: SizeInt): TBytesView;            { the first N bytes as a pinned view }
    function Freeze: TBytesView;                         { into_inner: the rest as a view }
    procedure ReleaseIdle(Pool: PBlockPool);             { 4.3: only when Len = 0 and Pins = 0 }
    procedure Done;
  end;
```

`Reserve(N)` makes `Cap - Len >= N`:

- no block: take one of the pool class `>= N`;
- an unpinned block of at least `Len + N` bytes: move the unread bytes to its start (compaction);
- otherwise: take a block of the class `>= Len + N`, copy the unread bytes, and give the old block back
  (or mark it `Detached` while views pin it; the release of its last view frees it).

A read (2.2.3) asks for `next` bytes of room (hyper's adaptive `ReadStrategy`, 2.2.2), then reads into
the spare room, at most `max_buf_size - Len` bytes. So the buffer never holds more than `max_buf_size`
bytes, and a partial head that reaches it is answered with 431. Read sizes are not hyper's (hyper's come
from `BytesMut`'s capacity rules, which S2 ported and T1 removed: user decision 2026-10-08).

Pins are changed only on the owning loop thread (no atomics). A worker never releases a view itself;
it hands the release to the loop (3.3). Tests: `tests/unit/test_rt_readbuf.pas` (unit tests, and random
operation sequences checked against a model byte queue with heap blocks and with both pool settings).

#### 2.2.2 `TReadStrategy` (io.rs:372-458)

```pascal
unit bearings.http1.io;
const
  INIT_BUFFER_SIZE = 8192;                         { io.rs:15 }
  MINIMUM_MAX_BUFFER_SIZE = INIT_BUFFER_SIZE;      { io.rs:18 }
  DEFAULT_MAX_BUFFER_SIZE = 8192 + 4096 * 100;     { io.rs:23 }
  MAX_BUF_LIST_BUFFERS = 16;                       { io.rs:30 }
  MAX_WRITEV_BUFS = 64;                            { io.rs:288 }
type
  TReadStrategy = record            { ReadStrategy::Adaptive; unsigned like usize }
    DecreaseNow: Boolean;
    Next: SizeUInt;
    Max: SizeUInt;
    procedure InitWithMax(AMax: SizeUInt);
    procedure InitDefault;                          { WithMax(DEFAULT_MAX_BUFFER_SIZE) }
    procedure Record_(BytesRead: SizeUInt);         { io.rs:408-440; 'record' is a keyword }
  end;
function IncrPowerOfTwo(N: SizeUInt): SizeUInt; inline;   { saturating N * 2 }
function PrevPowerOfTwo(N: SizeUInt): SizeUInt; inline;   { (High(SizeUInt) shr ((63 - BsrQWord(N)) + 2)) + 1 }
```

#### 2.2.3 `TH1Io`: the read half of `Buffered`

```pascal
type   { TTransport and TTcpTransport are declared in bearings.rt.net; shown here with their users }
  { hyper rt::Read + rt::Write. Raw results: > 0 bytes, 0 EOF, < 0 -errno (-ESysEAGAIN = Pending). }
  TTransport = class
  public
    function Read(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    { Default: writes the first non-empty slice only (Rust's default poll_write_vectored). }
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; virtual;
    function IsWriteVectored: Boolean; virtual;              { default False }
    { -ESysENOSYS when unsupported (TLS later) }
    function SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt; virtual;
    function ShutdownWrite: SizeInt; virtual; abstract;      { shutdown(fd, SHUT_WR) }
    procedure Close; virtual; abstract;                      { drop: close(2), no shutdown }
  end;

  TTcpTransport = class(TTransport)      { tokio TcpStream behind TokioIo; rules of 1.4 }
  public
    Src: PIoSource;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;             { True, as tokio's TcpStream }
    function SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

  TIoPoll = (ipReady, ipPending, ipError);

  TH1Io = record                     { io.rs:32-40 Buffered<T, B> }
    FlushPipeline: Boolean;
    Io: TTransport;
    PartialLen: SizeInt;             { Option<usize>: -1 = None }
    ReadBlocked: Boolean;
    ReadBuf: TReadBuf;
    ReadBufStrategy: TReadStrategy;
    WriteBuf: TWriteBuf;             { 2.2.4 }
    Pool: PBlockPool;
    procedure Init(AIo: TTransport; APool: PBlockPool);
    procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetMaxBufSize(Max: SizeInt);                    { asserts Max >= MINIMUM_MAX_BUFFER_SIZE }
    function ReadBufPtr: PByte; inline;
    function ReadBufLen: SizeInt; inline;
    function CanHeadersBuf: Boolean; inline;                  { not WriteBuf.Queue.HasRemaining }
    function HasBufferedWrite: Boolean; inline;
    function CanBuffer: Boolean; inline;                      { FlushPipeline or WriteBuf.CanBuffer }
    procedure ConsumeLeadingLines;                            { io.rs:161-172 }
    { io.rs:174-229. On prOk: Msg filled, Headers filled with external entries whose base is the head
      start, Head = ReadBuf.SplitTo(Msg.HeadLen) (pinned). }
    function Parse(const Ctx: TH1ParseContext; Headers: THttpHeaders; out Msg: TParsedRequestHead;
      out Head: TBytesView; var Err: THyperError): TPollResult;
    { io.rs:231-268: next := Min(Next, Max - Len); Reserve(next); read into the spare room, at most
      Max - Len bytes; Record_(n); ReadBlocked on Pending. }
    function PollReadFromIo(out N: SizeInt; out Errno: cint): TIoPoll;
    function IsReadBlocked: Boolean; inline;
    { io.rs:361-369 MemRead::read_mem: a view of up to Len bytes; reads when the buffer is empty. }
    function ReadMem(Len: SizeInt; out View: TBytesView; out Errno: cint): TIoPoll;
    function PollFlush(out Errno: cint): TIoPoll;             { io.rs:278-316 }
    function PollFlushCursor(out Errno: cint): TIoPoll;       { write(2) of the cursor; queue empty }
    function PollFlushQueue(out Errno: cint): TIoPoll;        { writev + sendfile (2.2.4) }
    function PollShutdown(out Errno: cint): TIoPoll;          { io.rs:337-340: flush, then ShutdownWrite }
    procedure IntoInner(out AIo: TTransport; out Rest: TBytesView);   { io.rs:270: freeze }
  end;
```

`Parse` calls M2 `ServerParseHeaders(ReadBuf.Ptr, ReadBuf.Len, PartialLen, Ctx, Headers, Msg)` (which
runs `IsCompleteFast` when `PartialLen >= 0`), then the `max_header_size` and `max_buf_size` checks with
`>=` on `ReadBuf.Len` (io.rs:204-215), then `PollReadFromIo`; a 0-byte read is `NewIncomplete`.

Body decoding glue (hyper `Decoder::decode(cx, &mut io)` over `MemRead`): the M2 `TDecoder` works on a
byte range with an `AtEof` flag. `TH1Conn.DecodeFrame` loops: if the buffer is empty, `PollReadFromIo`
(Pending → Pending; 0 bytes → `AtEof := True`); `TDecoder.Decode(Ptr, Len, AtEof, Trailers, R)`;
framing bytes are consumed with `ReadBuf.Advance`; a data frame becomes `ReadBuf.Advance(R.DataOfs - consumed so far)` then
`ReadBuf.SplitTo(R.DataLen)` (a pinned view, as `read_mem` returns a `Bytes`). Reads happen only when
the buffer is empty, as in hyper's `read_mem`. The decoder differential (`test_codec_diff.sh`) compares
the decoder's frames with hyper's `decode.rs`.

#### 2.2.4 The write half: cursor and queue

```pascal
unit bearings.rt.buf;   { continued }
type
  { A growable byte vector over a pooled block (heap when Pool = nil). Growth: a block of at least
    Max(2 * Cap, Len + Additional) bytes; Cap is the block's size. Block = nil: no memory, Cap = 0. }
  TByteVec = record
    Data: PByte;
    Len: SizeInt;
    Cap: SizeInt;
    Block: PBufBlock;
    procedure Reserve(Additional: SizeInt; Pool: PBlockPool);
    procedure Append(P: PByte; N: SizeInt; Pool: PBlockPool);
    procedure DrainFront(N: SizeInt);
    procedure Clear; inline;                                    { len := 0, keep the block }
    procedure ReleaseIdle(Pool: PBlockPool);                    { Len = 0: block back, Cap := 0 }
  end;

unit bearings.http1.io;   { continued }
const
  QUEUE_SLOTS = 32;                  { ring: the 16 entries CanBuffer allows + heads queued behind them }
  MAX_COPY_SIZE = 4096;              { Buffer copies an entry of at most this size into the cursor }
type
  TCursor = record                   { io.rs Cursor<Vec<u8>>: the head cursor }
    Bytes: TByteVec;
    Pos: SizeInt;
    function Remaining: SizeInt; inline;
    function Chunk: PByte; inline;
    procedure Advance(N: SizeInt); inline;
    procedure MaybeUnshift(Additional: SizeInt);   { drops the written prefix when the block has no room }
    procedure Reset; inline;
  end;

  { qkBytes: owned bytes sent as one slice (a head written while entries are queued) }
  TQueuedKind = (qkEncoded, qkTrailers, qkFile, qkBytes);
  TQueuedBuf = record
    Kind: TQueuedKind;
    Enc: TEncodedBuf;                { M2: chunk-size prefix inline + data pointer + static suffix }
    Owner: TBodyData;                { releases the data after it was written (3.4); no managed fields }
    Trailers: TByteVec;              { qkTrailers: the encoded trailer section; qkBytes: the bytes }
    TrailersPos: SizeInt;
    FileFd: cint; FileOff, FileLen: Int64;      { qkFile }
    function Remaining: SizeInt;
  end;

  TBufList = record                  { a ring of QUEUE_SLOTS entries; the array is a pooled 8 KiB block }
    Items: PQueuedArray;             { nil until first use and while empty-and-idle }
    Head, Count: Integer;
    Files: Integer;                  { qkFile entries in the ring }
    function Remaining: SizeInt;
    function HasRemaining: Boolean; inline;
    procedure Push(const B: TQueuedBuf; Pool: PBlockPool);      { EH1Panic when the ring is full }
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;   { stops before a qkFile }
    procedure Advance(N: SizeInt);   { releases fully written entries (Owner, Trailers) }
  end;

  TWriteBuf = record
    Headers: TCursor;
    MaxBufSize: SizeInt;             { DEFAULT_MAX_BUFFER_SIZE }
    Queue: TBufList;
    procedure Buffer(const B: TQueuedBuf; Pool: PBlockPool);    { the rule below }
    function CanBuffer: Boolean;     { Remaining < MaxBufSize and Queue.Count < 16 }
    function HeadersMut: PCursor;    { asserts not Queue.HasRemaining }
    function Remaining: SizeInt;
    procedure Advance(Cnt: SizeInt);
    function ChunksVectored(Dst: PIoSlice; Max: Integer): Integer;
  end;
```

One write path (T1 merged hyper's Flatten and Queue strategies; user decision 2026-10-08):

- A response head is encoded straight into the cursor when nothing is queued (`CanHeadersBuf`).
- `TWriteBuf.Buffer` copies an entry into the cursor (after `MaybeUnshift`) and releases its data at once
  when the queue is empty, the entry is not a file and it has at most `MAX_COPY_SIZE` bytes. Otherwise it
  queues the entry. The cursor is written before the queue, so an entry that arrives while something is
  queued is queued too and the bytes keep their order.
- A head that must be written while entries are queued (the automatic 400/414/431 of `on_parse_error`,
  the automatic `100 Continue`) goes behind them (`TH1Io.BufferAfterQueue`, a `qkBytes` entry). hyper
  1.12.0's Queue strategy writes it into the cursor, between the queued response's head and its body
  (decision 7). The ring has room for such heads beyond the 16 entries `CanBuffer` allows.
- `CanBuffer`: `Remaining < MaxBufSize` and fewer than 16 queued entries. `TH1Io.CanBuffer` is also
  true under `pipeline_flush` while fewer than 16 entries are queued (the cursor is not bounded, as in
  hyper's Flatten strategy).
- `PollFlush`: nothing buffered: Ready. Under `pipeline_flush`, with bytes in the read buffer and nothing
  queued: Ready without writing (io.rs:279-280), so the responses to pipelined requests leave in one
  write. A queued entry is written at once even then: while it is queued `CanHeadersBuf` is false, the
  next response could not be buffered and nothing would wake the task (decision 8). Otherwise `write` of
  the cursor until it is empty when nothing is queued (`PollFlushCursor`), else `writev` of the cursor and
  the queued memory entries, at most 64 slices per call, and `sendfile` for a file entry at the front
  (`PollFlushQueue`). `n = 0` with bytes left is `WriteZero`.
- `PollShutdown` = `PollFlush` then `ShutdownWrite`, so it also skips the flush while `FlushPipeline` and
  unread bytes exist, as io.rs:337-340 (decision 14 adds the flush at the end of a connection).
- A transport without `writev` (`IsWriteVectored` false; TLS later) gets one slice per call from the
  default `TTransport.WriteV`. The bytes are the same.

Sendfile (DV-5, hyper has no file bodies): a known-length file body is a `qkFile` entry. Flush order: the
cursor, then the queued memory entries up to the file entry (`writev`), then `sendfile` until the entry is
done or `EAGAIN`, then the rest. The bytes on the wire equal a `Full` body with the file content. A file
frame (`bkFile`) reaches `TH1Conn.WriteBody` / `WriteBodyAndEnd` like a memory frame: the encoder frames
it for `Len` bytes and the framing goes around the file entry (chunk-size line, the file range, the
suffix), so a file frame in a chunked body (a `TBodySource` that returns `BodyFile` frames) also has the
bytes of a memory frame (S8). The entry owns the `TBodyData`: `CloseAfter` closes the fd after the last
byte, or when the connection drops its queue (an error, an abort).

Response head encoding writes straight into `Headers.Bytes` (S0 adds this `ServerEncode` overload; the
M2 `TBytes` overload stays for the M2 tests):

```pascal
{ bearings.http1.role (S0) }
type
  TEncodeContext = record
    Date: PByte;                      { the loop's 29 date bytes }
    Trailers: PTrailerFieldSet;       { per-connection scratch for declared trailer names (4.4) }
  end;
function ServerEncode(const Head: TResponseHead; const P: TServerEncodeParams;
  const Ctx: TEncodeContext; var Dst: TByteVec; Pool: PBlockPool;
  out Encoder: TEncoder): TServerEncodeResult; overload;
```

### 2.3 conn.rs: `TH1Conn`

```pascal
unit bearings.http1.conn;
interface
uses bearings.rt.buf, bearings.rt.timer, bearings.http1.io, bearings.http1.role, bearings.http1.encode, bearings.http1.decode,
  bearings.http.headers, bearings.http.error;
type
  TReading = (rdInit, rdContinue, rdBody, rdKeepAlive, rdClosed);   { conn.rs:992-999 }
  TWriting = (wrInit, wrBody, wrKeepAlive, wrClosed);               { conn.rs:1001-1006 }
  TKA = (kaIdle, kaBusy, kaDisabled);                               { default kaBusy }
  TWant = (wantUpgrade, wantExpect);
  TWants = set of TWant;

  TInFrameKind = (ifData, ifTrailers);
  TInFrame = record
    Kind: TInFrameKind;
    Data: TBytesView;                { ifData: pinned view of the read buffer }
  end;                               { ifTrailers: the decoder filled Conn.ReqTrailers }

  TConnState = record                { conn.rs:940-990, server fields }
    AllowHalfClose: Boolean;
    HasError: Boolean;
    Error: THyperError;
    KeepAlive: TKA;
    Method: THttpMethod;             { hmNone = None }
    ParseCtx: TH1ParseContext;
    HeaderReadTimeoutMs: Int64;      { -1 = None }
    HeaderReadTimer: TTimer;         { h1_header_read_timeout_fut (lazy arm/cancel) }
    HeaderReadTimeoutRunning: Boolean;
    DateHeader: Boolean;
    TitleCaseHeaders: Boolean;
    NotifyRead: Boolean;
    Reading: TReading;
    ReadDecoder: TDecoder;           { payload of rdContinue / rdBody (no managed fields after S0) }
    Writing: TWriting;
    WriteEncoder: TEncoder;          { payload of wrBody (no managed fields after S0) }
    Upgrade: TUpgradePending;        { Option<upgrade::Pending> (2.7) }
    Version: THttpVersion;           { starts hv11 }
    AllowTrailerFields: Boolean;
    procedure Close;  procedure CloseRead;  procedure CloseWrite;        { conn.rs:1062-1077 }
    function WantsKeepAlive: Boolean;
    procedure TryKeepAlive;                                              { conn.rs:1079-1101 }
    procedure DisableKeepAlive;  procedure Busy;
    procedure Idle;                  { conn.rs:1111-1140: sets NotifyRead when a timeout is configured }
    function IsIdle: Boolean;  function IsReadClosed: Boolean;  function IsWriteClosed: Boolean;
    procedure PrepareUpgrade(Ex: TObject);                               { conn.rs:1154-1158 }
  end;

  TH1Conn = record
    Io: TH1Io;
    State: TConnState;
    Owner: TObject;                  { the TH1Dispatcher (wake target of the header timer) }
    Scratch: TConnScratch;           { trailer names, decoder trailer bytes (4.4) }
    procedure Init(AIo: TTransport; APool: PBlockPool; AOwner: TObject);   { conn.rs:50-89 }
    procedure Done;                  { frees scratch, timers; no managed fields to finalize }
    { setters used by TH1Config.Apply (http1.rs:470-522) }
    procedure SetTimer(Enabled: Boolean);  procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetMaxBufSize(Max: SizeInt);  procedure SetParserConfig(const C: TParserConfig);
    procedure SetTitleCaseHeaders;  procedure SetMaxHeaders(N: Integer);
    procedure SetMaxHeaderSize(N: SizeInt);  procedure SetHeaderReadTimeout(Ms: Int64);
    procedure SetAllowHalfClose;  procedure DisableDateHeader;

    function IsReadClosed: Boolean;  function IsWriteClosed: Boolean;
    function CanReadHead: Boolean;                       { conn.rs:177-187 }
    function CanReadBody: Boolean;
    function HasInitialReadWriteState: Boolean;          { conn.rs:197-201 }
    function HasH2Prefix: Boolean;                       { conn.rs:208-211 }

    { conn.rs:213-337. poSome: Head = pinned head view, Headers filled, Wants set. }
    function PollReadHead(Headers: THttpHeaders; out Msg: TParsedRequestHead;
      out Head: TBytesView; out Wants: TWants; var Err: THyperError): TPollOpt;
    function OnReadHeadError(var Err: THyperError): TPollOpt;        { conn.rs:339-363 }
    { conn.rs:365-433 }
    function PollReadBody(Trailers: THttpHeaders; out Frame: TInFrame; var Err: THyperError): TPollOpt;
    function WantsReadAgain: Boolean;                                { conn.rs:435-439 }
    function PollReadKeepAlive(var Err: THyperError): TPollResult;   { conn.rs:441-451 }
    function IsMidMessage: Boolean;
    function MidMessageDetectEof(var Err: THyperError): TPollResult; { conn.rs:493-510 }
    function ForceIoRead(out N: SizeInt; out Errno: cint): TIoPoll;  { conn.rs:512-522 }
    procedure MaybeNotify;                                           { conn.rs:524-568 }
    procedure TryKeepAlive;                                          { conn.rs:570-573 }

    function CanWriteHead: Boolean;  function CanWriteBody: Boolean;  { conn.rs:575-591 }
    function CanBufferBody: Boolean;  function HasBufferedWrite: Boolean;
    procedure WriteHead(var Head: TResponseHead; const Body: TBodyLength);     { conn.rs:600-611 }
    function EncodeHead(var Head: TResponseHead; const Body: TBodyLength;
      out Enc: TEncoder): Boolean;                                   { conn.rs:613-668 + 2.8 check }
    procedure FixKeepAlive(var Head: TResponseHead);                 { conn.rs:671-698 }
    procedure EnforceVersion(var Head: TResponseHead);               { conn.rs:702-731 }
    procedure WriteBody(const Chunk: TBodyData);                     { conn.rs:733-756 }
    procedure WriteTrailers(Trailers: THttpHeaders);                 { conn.rs:758-779 (5.2 T3) }
    procedure WriteBodyAndEnd(const Chunk: TBodyData);               { conn.rs:781-799 }
    function EndBody(var Err: THyperError): Boolean;                 { conn.rs:801-829 }
    function OnParseError(var Err: THyperError): Boolean;            { conn.rs:836-853; True = Ok(()) }
    function PollFlush(out Errno: cint): TIoPoll;                    { conn.rs:855-860: + TryKeepAlive }
    function PollShutdown(out Errno: cint): TIoPoll;                 { conn.rs:862-872 }
    procedure PollDrainOrCloseRead;                                  { conn.rs:874-892 }
    procedure DisableKeepAlive;                                      { conn.rs:902-911 }
    function TakeError(var Err: THyperError): Boolean;               { conn.rs:913-919 }
  end;
```

`TResponseHead` (M2) gains slice fields in S0: `ReasonP: PByte; ReasonLen: SizeInt` replace the
`TReasonPhrase` field, and `Headers`/`CaseMap` stay `THttpHeaders` references, so the record has no
managed fields and `EnforceVersion`/`FixKeepAlive` can take it by `var`.

Behaviors that land exactly where hyper has them:

- **Header read timeout** (conn.rs:223-283). Before `Io.Parse`, if not running and a timeout is set:
  `Timers.Arm(@HeaderReadTimer, Loop.NowMs + timeout)` and running := True. On `Pending` while running:
  if `HeaderReadTimer.Fired` → running := False, return `NewHeaderTimeout` (no response). When a head is
  parsed: running := False, `Timers.Cancel` (lazy). `State.Idle` sets `NotifyRead` when a timeout is
  configured (conn.rs:1146-1151): the dispatcher loops once more and re-arms the timer right after the
  response, so the header timeout is also the keep-alive idle timeout. The timer's `Proc` wakes `Owner`.
- **`MaybeNotify`** (conn.rs:524-568): returns unless `Reading = rdInit` and `Writing <> wrBody`; if not
  read-blocked: with an empty buffer it tries one `PollReadFromIo`; `Pending` → **return** (no
  `NotifyRead`); 0 → `Close` if idle else `CloseRead`, return; error → `Close`, store `NewIo`, and fall
  through; then `NotifyRead := True`.
- **Keep-alive, `TryKeepAlive`, `Idle`, `Busy`, `DisableKeepAlive`**: line for line.
- **`PollReadKeepAlive`**: read-closed → Pending; mid-message → `MidMessageDetectEof`; otherwise
  (`require_empty_read`, client only) Pending.

### 2.4 dispatch.rs: `TH1Dispatcher`

#### 2.4.1 Type

```pascal
unit bearings.http1.dispatch;
interface
uses bearings.rt.loop, bearings.rt.buf, bearings.http1.io, bearings.http1.conn, bearings.http1.role, bearings.http.error,
  bearings.http.headers, bearings.http.exchange, bearings.http1.config;
type
  TDispatched = (dsShutdown, dsUpgrade);

  { The response body being written: hyper's body_rx: Pin<Box<Option<Bs>>>. }
  TOutBodyKind = (obNone, obData, obSource);
  TOutBody = record
    Kind: TOutBodyKind;
    Data: TBodyData;                 { obData: a one-shot body (Full / Empty / file) }
    Taken: Boolean;                  { obData: the frame was handed out }
    Source: TBodySource;             { obSource }
    function IsEndStream: Boolean;   { obData: (not Taken and Len = 0) or Taken; obSource: virtual }
    function SizeHint(out Exact: QWord): Boolean;
  end;

  TH1Dispatcher = class(TIoTask)
  public
    Conn: TH1Conn;                   { embedded: one allocation per connection }
    Service: THttpService;
    Mode: TH1ConnMode;
    { Server dispatch (dispatch.rs:46-52, 597-670) }
    InFlight: TServiceCall;          { in_flight; nil = None }
    Ex: TExchange;                   { the request in flight / the exchange whose body we feed or write }
    { Dispatcher fields (dispatch.rs:22-28) }
    BodyTx: Boolean;                 { body_tx: Ex.Chan sender is live (SenderDropGuard) }
    BodyRx: TOutBody;                { body_rx }
    IsClosing: Boolean;
    FUpgraded: Boolean;
    Observer: TConnObserver;         { nil in production }
    ConnId: QWord;
    FErrorText: RawByteString;       { cold: text for ecConnText errors }

    procedure Run; override;                       { one poll of the connection future }
    procedure Abort; override;                     { drop without completion events (1.10) }
    procedure GracefulShutdown;                    { 1.11 }
    { ports }
    function PollCatch(ShouldShutdown: Boolean; out D: TDispatched; var Err: THyperError): TPollResult;
    function PollInner(ShouldShutdown: Boolean; out D: TDispatched; var Err: THyperError): TPollResult;
    function PollLoop(var Err: THyperError): TPollResult;
    function PollRead(var Err: THyperError): TPollResult;
    function PollReadHead(var Err: THyperError): TPollResult;
    function PollWrite(var Err: THyperError): TPollResult;
    function PollFlush(var Err: THyperError): TPollResult;
    function PollMsg(var Err: THyperError): TPollOpt;           { Server::poll_msg }
    function RecvMsg(const Msg: TParsedRequestHead; const Head: TBytesView;
      Wants: TWants): Boolean;                                  { Server::recv_msg }
    procedure Close_;                                           { dispatch.rs:446-450 }
    function CanWriteAgain: Boolean;                            { dispatch.rs:454-456 }
    function IsDone: Boolean;                                   { dispatch.rs:458-473 }
    procedure ClearBodyRx;                                      { OptGuard: release BodyRx }
    procedure Finish(R: TPollResult; D: TDispatched; var Err: THyperError);   { 2.4.4 }
  end;
```

#### 2.4.2 `PollCatch`, `PollInner`, `PollLoop`

```pascal
procedure TH1Dispatcher.Run;
var R: TPollResult; D: TDispatched; Err: THyperError;
begin
  R := PollCatch(Mode <> cmWithoutShutdown, D, Err);
  if R = prPending then
  begin
    {$ifdef WD_DEBUG} AssertWakeArmed; {$endif}               { 2.4.5 }
    Exit;
  end;
  Finish(R, D, Err);
end;

function TH1Dispatcher.PollCatch(ShouldShutdown: Boolean; out D: TDispatched;
  var Err: THyperError): TPollResult;                          { dispatch.rs:123-141 }
begin
  Result := PollInner(ShouldShutdown, D, Err);
  if Result <> prErr then Exit;
  if BodyTx then                                               { body_tx.take(): send_error }
  begin
    Ex.Chan.SendError(NewBodyStatic('connection error'));
    BodyTx := False; Ex.Chan.CloseSender;
  end;
  { self.dispatch.recv_msg(Err(e))?: the server's recv_msg returns the error itself }
end;

function TH1Dispatcher.PollInner(ShouldShutdown: Boolean; out D: TDispatched;
  var Err: THyperError): TPollResult;                          { dispatch.rs:143-164 }
var Errno: cint;
begin
  { T::update_date(): done once per loop iteration (1.6, DV-6) }
  Result := PollLoop(Err);
  if Result <> prOk then Exit;          { Pending, or an error propagated with '?': no flush, no shutdown }
  if not IsDone then Exit(prPending);
  if Conn.Io.HoldsPipelinedWrite then   { decision 14, S6-15: not in hyper; never true without pipeline_flush }
    case Conn.Io.PollFlushHeld(Errno) of
      ipPending: Exit(prPending);
      ipError: begin Err := NewBodyWrite(Errno); Exit(prErr); end;
    end;
  if Conn.State.Upgrade.Active then     { self.conn.pending_upgrade() }
  begin
    TakePendingUpgrade;                 { moves State.Upgrade into FPendingUpgrade (2.7) }
    if Conn.TakeError(Err) then Exit(prErr);
    D := dsUpgrade; Exit(prOk);
  end
  else if ShouldShutdown then
    case Conn.PollShutdown(Errno) of    { flush + shutdown(SHUT_WR), BEFORE take_error }
      ipPending: Exit(prPending);
      ipError: begin Err := NewShutdown(Errno); Exit(prErr); end;
    end;
  if Conn.TakeError(Err) then Exit(prErr);   { stored errors: the 400/414/431 auto-responses, 1xx -> 500 }
  D := dsShutdown;
  Result := prOk;
end;

function TH1Dispatcher.PollLoop(var Err: THyperError): TPollResult;   { dispatch.rs:166-223 }
var
  I: Integer;
  R: TPollResult;
  WriteReady, FlushReady, WantsWriteAgain, WantsReadAgain: Boolean;
begin
  for I := 1 to 16 do
  begin
    if PollRead(Err) = prErr then Exit(prErr);               { let _ = self.poll_read(cx)?; }
    R := PollWrite(Err);  if R = prErr then Exit(prErr);  WriteReady := R = prOk;
    R := PollFlush(Err);  if R = prErr then Exit(prErr);  FlushReady := R = prOk;
    WantsWriteAgain := CanWriteAgain and (WriteReady or FlushReady);
    WantsReadAgain := Conn.WantsReadAgain;
    if not (WantsWriteAgain or WantsReadAgain) then Exit(prOk);
    if (not WantsReadAgain) and WantsWriteAgain then          { dispatch.rs:201-218 }
    begin
      R := PollWrite(Err);
      if R = prErr then Exit(prErr);
      if R = prPending then
      begin
        if Conn.HasBufferedWrite then                         { flush before yield (h1_flush_before_yield) }
          if PollFlush(Err) = prErr then Exit(prErr);
        Exit(prOk);
      end;
    end;
  end;
  Wake;                                                       { task::yield_now: back of the run queue }
  Result := prPending;
end;
```

#### 2.4.3 `PollRead`, `PollReadHead`, `PollWrite`, `PollMsg`, `RecvMsg`

`PollRead` (dispatch.rs:225-296) and `PollReadHead` (298-348) are ported the same way:

- `PollReadHead`: `Server::poll_ready` (`InFlight = nil`, else Pending); `Conn.PollReadHead`; on
  `poSome`: body length zero → no channel (`IncomingBody::empty()`), else the exchange's channel is
  opened with `Wanter := wantExpect in Wants` and `BodyTx := True`; `wantUpgrade` → `Conn.State.PrepareUpgrade(Ex)`;
  then `RecvMsg`. On `poErr`: `recv_msg(Err)` returns the error. On `poNone`: if write-closed, `Close_`.
- `PollRead` body branch: `Ex.Chan.PollReady` (receiver closed → `Conn.PollDrainOrCloseRead`;
  continue), `Conn.PollReadBody` → `TrySendData` / `TrySendTrailers` (failure: `CloseRead` if still
  reading body) / `Ready(None)` → drop the sender (`BodyTx := False`, `CloseSender`) /
  `SendError(NewBodyDecode or NewBodyIo)`.

`PollWrite` follows dispatch.rs:350-437 statement by statement:

```pascal
function TH1Dispatcher.PollWrite(var Err: THyperError): TPollResult;
var F: TFramePoll; Data: TBodyData; Trailers: THttpHeaders; BL: TBodyLength; N: QWord;
begin
  while True do
  begin
    if IsClosing then Exit(prOk)
    else if (BodyRx.Kind = obNone) and Conn.CanWriteHead and (InFlight <> nil) then
    begin
      case PollMsg(Err) of
        poPending: Exit(prPending);
        poErr: Exit(prErr);                                   { new_user_service; propagated }
        poNone: begin Close_; Exit(prOk); end;
      end;
      TakeResponseBody(BodyRx);                               { from Ex.Resp (3.2) }
      if BodyRx.IsEndStream then begin ClearBodyRx; BL.Kind := blkNone; end
      else if BodyRx.SizeHint(N) then begin BL.Kind := blkKnown; BL.Len := N; end
      else BL.Kind := blkUnknown;
      Conn.WriteHead(Ex.Resp.Head, BL);
    end
    else if not Conn.CanBufferBody then
    begin
      Result := PollFlush(Err);
      if Result <> prOk then Exit;
    end
    else if BodyRx.Kind <> obNone then
    begin
      if not Conn.CanWriteBody then begin ClearBodyRx; Continue; end;
      F := PollOutFrame(BodyRx, Data, Trailers);              { obData: one frame; obSource: virtual }
      case F of
        fpPending: Exit(prPending);
        fpError: begin ClearBodyRx; Err := NewUserBody; Exit(prErr); end;
        fpData:
          if BodyRx.IsEndStream then
          begin
            ClearBodyRx;
            if Data.Len = 0 then
            begin
              ReleaseBody(Data);                              { "discarding empty chunk" }
              if not Conn.EndBody(Err) then Exit(prErr);
            end
            else Conn.WriteBodyAndEnd(Data);
          end
          else if Data.Len = 0 then ReleaseBody(Data)
          else Conn.WriteBody(Data);
        fpTrailers: begin ClearBodyRx; Conn.WriteTrailers(Trailers); end;
        fpEnd: begin ClearBodyRx; if not Conn.EndBody(Err) then Exit(prErr); end;
      end;
    end
    else if Conn.CanWriteBody then
    begin
      if not Conn.EndBody(Err) then Exit(prErr);
    end
    else
      Exit(prPending);
  end;
end;
```

`PollMsg` (dispatch.rs:612-632) polls the service call; this is the only place where handler code runs:

```pascal
function TH1Dispatcher.PollMsg(var Err: THyperError): TPollOpt;
begin
  if InFlight.Poll(Ex) = cpPending then Exit(poPending);       { the future's poll }
  InFlight.Drop(Ex, True);                                     { in_flight.set(None) }
  InFlight := nil;
  Ex.CompleteCall;                       { drops the request: ReleaseRequest if the handler did not }
  if Ex.Resp.Failed then
  begin
    Err := NewUserService; SetErrorText(Ex.Resp.FailText);     { cold }
    Exit(poErr);
  end;
  Result := poSome;
end;
```

`RecvMsg` (dispatch.rs:634-646) fills the exchange (method, target, URI parts, version, head view,
headers already parsed into `Ex.ReqHeaders`, body channel state, upgrade slot), then
`InFlight := Service.Call(Ex)` (hyper's `self.service.call(req)`). `Call` must not run handler code
that has observable effects beyond creating the call (3.1).

#### 2.4.4 `Finish` and the drop order

`Finish(R, D, Err)` mirrors the reference server's `serve_conn` after the connection future resolved:

1. `cmWithUpgrades` and `R = prOk` and `D = dsUpgrade`: `IntoInner` (transport + `ReadBuf.Freeze`
   view), fulfill the pending upgrade (2.7); the dispatcher no longer owns the socket.
   `cmPlain` and `dsUpgrade`: `Pending.manual()` (2.7). `cmWithoutShutdown` and `R = prOk`: take
   `TConnParts` (transport + rest of the read buffer) before dropping.
2. Drop, in hyper's field order (`Dispatcher { conn, dispatch, body_tx, body_rx }` drops `conn` first):
   close the transport if still owned (`close(2)`, no shutdown); `InFlight.Drop(Ex, False)` if a call
   is in flight (the conformance call emits `handler_dropped`); if `BodyTx`, `Chan.SendError(NewIncomplete)`
   (`SenderDropGuard`) and close the sender; `ClearBodyRx` (`TBodySource.Done`); release the exchange;
   `Conn.Done`; a still-pending upgrade slot resolves to canceled ("upgrade expected but not completed").
3. `Observer.OnConnClose(ConnId, OutcomeOf(R, Err), Detail)` (SPEC 7.2 order, 2.8).
4. Hand-off actions: `cmWithUpgrades`: the upgrade delivery task is queued (it runs after this, so
   `conn_close` precedes `upgraded`); `cmWithoutShutdown`: `Observer.OnParts(ConnId, Parts)`.
5. `Close` (task freed after the batch).

`Abort` (exceptions, shutdown deadline) runs step 2 only.

#### 2.4.5 Wake sources and the debug check

A `Pending` is correct only if something will run the task again:

| pending on | wake source |
|---|---|
| socket read (`-EAGAIN`, `rdRead` cleared, no sticky bit) | epoll edge |
| socket write | `EPOLLOUT` edge |
| service call `Pending` | the call arranged `Ex.Wake`: a `TWakeTimer`, a worker answer, another thread, a body read |
| body channel `PollReady` pending (`want` false or slot full) | the receiver's next body call wakes the sender |
| service call reading the body (`TryRead` → `brPending`, receiver waker registered) | the sender's `TrySendData`, `TrySendTrailers`, `SendError` or `CloseSender` wakes the receiver (chan.rs: `receiver_waker.wake()`); inline both wakers are the connection task, so the dispatcher re-queues itself, as tokio re-polls a task that woke itself |
| response body `PollFrame` pending | the source arranged `Ex.Wake` (timer, producer thread) |
| header read timeout running | the timer's `Proc` |
| 16-iteration budget used | `Wake` (yield) |

Each chan.rs waker wakes only when it was registered and consumes the registration (a second wake
without a new registration does nothing); `TBodyChan` keeps one "registered" flag per side.

Debug builds (`-dWD_DEBUG`) assert at `Run` exit with `Pending` that at least one source is armed (what
counts as armed: deviation S5-7). A
stall detector (soak builds, `-dWD_STALL`, which needs `-dWD_DEBUG`) scans each loop's connections once
per second and reports any connection that is mid-message, has not run for 60 s and where the server
owes progress. Since step UB a connection that waits on its client is not reported: its last `Run`
returned `Pending` because a read or a write returned `EAGAIN`, while no call was in flight (or the call
in flight waited for body bytes: the body read found none), no body chunk waited for the receiver, no
response source was pending and the task was not woken. It is reported anyway when the task is
queued and has not run, or when a readiness event came for the side it waited on (read: `rdRead`,
`rdReadClosed`, `rdError`; write: `rdWrite`, `rdWriteClosed`, `rdError`) and the task did not run.

### 2.5 Configuration and connection modes (`http1::Builder`)

```pascal
unit bearings.http1.config;
interface
uses bearings.http1.parser, bearings.http1.role;
type
  TH1ConnMode = (cmPlain, cmWithUpgrades, cmWithoutShutdown);
  TTimeoutSetting = (tsDefault, tsDisabled, tsMs);          { absent / null / number }

  TH1Config = record                   { http1::Builder fields }
    KeepAlive: Boolean;                { True }
    HalfClose: Boolean;                { False }
    TitleCaseHeaders: Boolean;         { False }
    PreserveHeaderCase: Boolean;       { False; accepted, no wire effect (SPEC 4) }
    MaxHeaders: Integer;               { -1 = None (100) }
    MaxHeaderSize: SizeInt;            { -1 = None }
    MaxBufSize: SizeInt;               { -1 = None (DEFAULT_MAX_BUFFER_SIZE) }
    Timer: Boolean;                    { hyper .timer(..) }
    HeaderReadTimeout: TTimeoutSetting;
    HeaderReadTimeoutMs: Int64;
    PipelineFlush: Boolean;
    AutoDateHeader: Boolean;           { True }
    BodyReadTimeoutMs: Int64;          { step UB, not in hyper: 0 = off }
    BodyMinRate: Int64;                { step UB: bytes/s; 0 = off }
    Parser: TParserConfig;             { ignore_invalid_headers, allow_multiple_spaces... }
    Mode: TH1ConnMode;
  end;

function ConformanceH1Config: TH1Config;     { exactly http1::Builder::new(); body rule off }
function ProductionH1Config: TH1Config;     { Timer, 30 s timeout, PipelineFlush (open q. 1), cmWithUpgrades,
                                                body rule 30 s / 1 KiB/s (step UB) }
{ hyper's panics become False + message: max_buf_size < 8192; header_read_timeout number without
  timer (common/time.rs Time::check). Default timeout without timer = disabled. }
function ValidateH1Config(const C: TH1Config; out Msg: string): Boolean;
{ http1.rs:470-522 serve_connection: applies every setter to a fresh TH1Conn, in hyper's order;
  KeepAlive = False -> Conn.DisableKeepAlive at construction. }
procedure ApplyH1Config(const C: TH1Config; var Conn: TH1Conn);
```

**Request body rate rule (step UB, not in hyper; nginx's `client_body_timeout` is the model).**
With `BodyReadTimeoutMs > 0` (needs `Timer`; `ValidateH1Config` refuses it without one, a negative
value, and `BodyMinRate > 0` without `BodyReadTimeoutMs`), `TH1Conn` measures the time the server
waits for request body bytes: a wait starts when `PollReadBody` finds no byte (the dispatcher calls it
only while the body channel's receiver has room, so the server is ready for the bytes) and ends with
the next frame; time in which the handler does not take the body is not counted. The body fails when

1. one wait lasts `BodyReadTimeoutMs` (no byte for that long), or
2. with `BodyMinRate > 0`: the waits of this body since its first data byte add up to
   T >= `BodyReadTimeoutMs` and fewer than `BodyMinRate` x T / 1000 data bytes came (the average rate
   over the waiting time since the first byte, after the first `BodyReadTimeoutMs`, is below the
   minimum). The wait before the first byte is covered by rule 1 only (UB fix round, M2: a client that
   starts after 29 s and then sends at 1.1 x the minimum is served).

`BodyTimer` (wakes the owner) is armed at the earlier deadline. A failure is
`NewBodyIo(ETIMEDOUT)`: reading closes (no keep-alive), the receiver gets the body error
(`TExchange.BodyErrorIsTimeout` is True; a worker parked in a blocking read is released, as for
any body error), and the handler answers; the connection closes after that response, or after the
response already under way. Outcome `io` (hyper's `is_timeout` is false for an OS `ETIMEDOUT`).
The web framework answers 408 (M5 9.8). Defaults: off in `ConformanceH1Config` (the conformance
server and `gate.sh` are unchanged), 30 000 ms and 1 024 bytes/s in `ProductionH1Config`.

### 2.6 Behaviors: 100-continue, half-close, keep-alive, pipelining

- **Expect: 100-continue** (conn.rs:309-325, 411-422; chan.rs `want: !wanter`). A head with
  `expect_continue`, a non-empty body and version > 1.0 sets `rdContinue`; the channel starts with
  `Want = False`, so `PollReady` is Pending and nothing is read. The handler's first body call
  (`TryRead`, `Read`, `ReadChunk`, `ReadAll`) sets `Want` and wakes the connection; `PollReadBody` in
  `rdContinue` appends `HTTP/1.1 100 Continue\r\n\r\n` to the head cursor if `Writing = wrInit`,
  switches to `rdBody` and recurses once; the same iteration's flush sends it. If the handler drops the
  body unread (`ReleaseRequest`, `DiscardBody`, or completion), `PollDrainOrCloseRead` switches to
  `rdBody` without the 100 and makes one read attempt (`expect_continue_waits_for_body_poll`).
- **half_close** (conn.rs:493-510): with `AllowHalfClose = False` and an empty read buffer, a busy
  connection keeps a read pending (`MidMessageDetectEof`); EOF → `CloseRead`, `NewIncomplete`,
  propagated (no response, no shutdown), the in-flight call is dropped.
- **Pipelining**: the next head is parsed only when `CanReadHead` (`Reading = rdInit`), set by `Idle`
  after both sides reached keep-alive. With bytes already buffered, `MaybeNotify` only sets `NotifyRead`.
- **pipeline_flush**: `PollFlush` writes nothing while the read buffer holds bytes, so responses to a
  pipelined batch leave in one `write` (`pipeline_enabled`). Without it each response is flushed in its
  own iteration.

### 2.7 Upgrades and CONNECT with leftover bytes

```pascal
unit bearings.http.exchange;   { excerpt }
type
  TUpgradeState = (usNone, usPending, usFulfilled, usManual, usCanceled);
  { One per upgrade-capable request (not pooled: upgrades are rare). Holders: the connection side
    (hyper upgrade::Pending: TConnState.Upgrade, then the dispatcher's pending upgrade or the delivery
    task) and the exchange (OnUpgrade in the request extensions). State and handler calls: loop
    thread only. }
  TUpgradeSlot = class
  public
    State: TUpgradeState;
    Handler: TUpgradeHandler;        { set by Ex.OnUpgrade (hyper upgrade::on); nil = not taken }
    RxAlive: Boolean;                { Handler <> nil, or the request is not yet released }
    Upgraded: TUpgraded;             { usFulfilled: waiting for Deliver }
    procedure Fulfill(U: TUpgraded); { stores U; the delivery task calls Deliver after conn_close }
    procedure Deliver;               { Handler.Upgraded(U) if the receiver lives, else U.Close }
    procedure Manual;                { Handler.UpgradeFailed('upgrade expected but low level API in use') }
    procedure Cancel;                { Handler.UpgradeFailed('upgrade expected but not completed') }
    constructor Create;              { one reference }
    procedure AddRef;                { InterlockedIncrement }
    procedure Release;               { InterlockedDecrement; the last reference frees the slot }
  end;
  TUpgradePending = record Active: Boolean; Slot: TUpgradeSlot; end;   { conn side }

unit bearings.rt.stream;
type
  TRawListener = class
  public
    procedure Readable(U: TUpgraded); virtual;
    procedure Writable(U: TUpgraded); virtual;
  end;
  TUpgraded = class(TIoTask)         { upgrade.rs Upgraded = Rewind<io>: transport + leftover }
  public
    procedure Leftover(out P: PByte; out Len: SizeInt);    { hyper read_buf (pinned view) }
    procedure ConsumeLeftover(N: SizeInt);
    procedure Attach(L: TRawListener);                     { stay on the loop: callbacks on events }
    function TryRead(Buf: PByte; Max: SizeInt): SizeInt;   { > 0, 0 EOF, -errno }
    function TryWrite(Buf: PByte; Len: SizeInt): SizeInt;
    { Leave the loop: EPOLL_CTL_DEL, set blocking, copy the leftover to the heap (pins are loop-only),
      return the fd. The caller owns both. False (nothing changed) when the stream's socket is not
      its own (the innermost transport is not the TTcpTransport on this task's source). S8: the
      transport objects are freed without closing the socket and the task is closed. }
    function Detach(out Fd: cint; out Rest: RawByteString): Boolean;
    procedure Close;
    function Taken: Boolean;                               { attached, detached or closed (S8) }
  end;
```

Ownership (decision 9): the slot has an atomic reference count, one reference per holder. `PrepareUpgrade`
creates it (the connection's reference) and `Ex.LinkUpgrade` adds the exchange's. The connection's
reference moves from `TConnState.Upgrade` to the dispatcher's pending upgrade (`TakePendingUpgrade`) and
then to the `TUpgradeDelivery` task, and is released after `Manual`, after `Deliver`, or when the
connection is dropped (`Cancel`, then `Release`). The exchange releases its reference when it starts the
next request or is recycled. Either side may go first; the last `Release` frees the slot. hyper has the
same shape: `Pending` and `OnUpgrade` are the two halves of an `Arc` oneshot.

Flow (dispatch.rs:322-330, 152-160; http1.rs:562-592): a request with `Upgrade` (HTTP/1.1) or method
CONNECT gets `wantUpgrade`; `PrepareUpgrade` replaces any older slot (the older one is canceled) and
links the new slot to the exchange. A 101 response, or a 2xx to CONNECT, makes `ServerEncode` mark the
encoder `is_last` (role.rs:404-410), so writing ends in `wrClosed`; `TryKeepAlive` closes the read side;
`IsDone` becomes true and `PollInner` returns `dsUpgrade` without shutdown. Then `Finish` (2.4.4):

- `cmWithUpgrades`: `IntoInner`; `Slot.Fulfill(TUpgraded(transport, rest-of-read-buffer view))`;
  connection result Ok; delivery is a queued task, so it runs after `conn_close`.
- `cmPlain`: `Slot.Manual`; socket closed (drop, no shutdown).
- `cmWithoutShutdown`: result Ok; `TConnParts` go to the observer.

If the response is not an upgrade, the slot stays in `State.Upgrade` exactly as hyper keeps it: a later
upgrade request replaces it (the older handler gets "upgrade expected but not completed"), and if the
connection finishes while it is set, `PollInner` returns `dsUpgrade` (`upgrades_ignored`). This quirk is
kept on purpose (risk R5).

### 2.8 Error to response mapping, outcomes, panics

- Parse errors (conn.rs:339-363, 836-853): `OnReadHeadError` closes the read side, consumes leading
  CR/LF; when the error is a parse error or the buffer is not empty: `OnParseError`. With `wrInit` and
  the 24-byte h2 preface in the buffer → `NewVersionH2`, nothing written. Else `ServerErrorStatus(E)`
  (M2): 400 / 414 / 431 → `WriteHead` of a bodyless HTTP/1.1 head (keep-alive is disabled, so
  `EnforceVersion` adds `connection: close`; the encoder adds `content-length: 0` and `date`), error
  stored, return `poPending` (hyper's "XXX: wat?" `Pending`). The dispatcher flushes, `PollInner` shuts
  down the socket and then returns the stored error (outcome `parse` / `parse_too_large`). EOF while idle
  → `CloseWrite`, `poNone`, outcome `ok`.
- 1xx final status: M2 `ServerEncode` writes a 500 head and returns `serUnsupportedStatusCode`;
  `EncodeHead` stores `NewUserUnsupportedStatusCode`, sets `wrClosed`, keeps the bytes (outcome `user`).
  `serUserHeader` (bad CL/TE from the service): nothing written, error stored, `wrClosed`.
- **HTTP/0.9 and HTTP/3.0 response versions**: role.rs:444-445 panics. `EncodeHead` reproduces the
  condition before calling `ServerEncode`: after `EnforceVersion`, if the status is not a 1xx other
  than 101 (those become a default HTTP/1.1 500 first) and the version is `hv09` or `hv3`, it raises
  `EH1Panic`. The loop's handler (1.10) aborts the connection task: socket closed, no `conn_close`, as the
  reference server. No `try` block exists in any per-response routine.
- Outcome (SPEC 7.2), `OutcomeOf(R, Err)`: `ok` if `R = prOk`, else the first true predicate in this
  order: `IsTimeout`, `IsParseTooLarge`, `IsParseVersionH2`, `IsParse`, `IsIncompleteMessage`, `IsUser`,
  `IsCanceled`, `IsClosed`, `IsBodyWriteAborted`, `IsShutdown`, `HasIoSource` (`io`), else `other`.

### 2.9 HTTP/2 preface

- HTTP/1-only connections (M3, and the conformance `http1_only` case): the preface fails the request
  line parse; `OnParseError` sees `HasH2Prefix` → `parse_version_h2`, nothing written.
- Auto mode (M4, libnghttp2): `TProtoSniffer = class(TIoTask)` owns the `TH1Io` read side first, reads
  until 24 bytes or a mismatch, then builds `TH2Session` (bytes handed to `nghttp2_session_mem_recv2`) or
  a `TH1Dispatcher` around the same `TH1Io`, so no rewind copy is needed (hyper-util `auto::Builder`).
  TLS ALPN chooses directly.

### 2.10 Server, observer and outcome types

`TConnOutcome` and `OutcomeOf` are declared in `bearings.http.error`; `TConnParts` and `TConnObserver` in
`bearings.http.exchange` (they are protocol-neutral: an HTTP/2 session reports to the same observer).
`TH1Dispatcher` (in `bearings.http1.dispatch`) holds an `Observer: TConnObserver` field and `bearings.server` uses
`bearings.http1.dispatch`, so declaring them in `bearings.server` would make the interface `uses` graph cyclic (FPC:
"Circular unit reference"). `bearings.server` re-exports the three type names (`type TConnObserver =
bearings.http.exchange.TConnObserver;` and so on), so applications see them in `bearings.server`.

```pascal
unit bearings.http.error;      { excerpt }
type
  TConnOutcome = (coOk, coTimeout, coParseTooLarge, coParseVersionH2, coParse, coIncomplete,
    coUser, coCanceled, coClosed, coBodyWriteAborted, coShutdown, coIo, coOther);
function OutcomeOf(R: TPollResult; const E: THyperError): TConnOutcome;   { SPEC 7.2 order }

unit bearings.http.exchange;   { excerpt }
type
  { cmWithoutShutdown: what the HTTP layer hands back (hyper Parts { io, read_buf }). }
  TConnParts = record
    Transport: TTransport;           { owned by the receiver }
    Rest: TBytesView;                { unread bytes; pinned, loop thread }
    { the connection task's readiness source (fd, readiness bits). The task is freed after the
      event batch: a receiver that keeps the socket moves it before OnParts returns, with
      TUpgraded.CreateFrom(Loop, Transport, Rest, Src, True) (S6, deviation S6-2) }
    Src: PIoSource;
  end;

  { Hooks for tests and the conformance server. nil in production: zero cost. Loop thread. }
  TConnObserver = class
  public
    { Returns per-connection data passed to the other hooks (e.g. the conformance req counter). }
    function OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; virtual;
    { May wrap the transport (TCountingTransport for bytes_read). Default: T. }
    function WrapTransport(T: TTcpTransport; Data: Pointer): TTransport; virtual;
    { The connection task is set up and registered and has not run yet (graceful_shutdown_on_accept;
      S6, deviation S6-3). Default: nothing. }
    procedure OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask); virtual;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
      const Detail: string); virtual;
    { Default: releases Parts.Rest, closes and frees Parts.Transport (deviation S5-6). }
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); virtual;
  end;

unit bearings.server;
interface
uses bearings.rt.loop, bearings.rt.net, bearings.rt.buf, bearings.rt.workers, bearings.http.error, bearings.http.exchange,
  bearings.http1.config, bearings.http1.dispatch;
type
  TConnOutcome = bearings.http.error.TConnOutcome;          { re-exported }
  TConnParts = bearings.http.exchange.TConnParts;
  TConnObserver = bearings.http.exchange.TConnObserver;

  TServerConfig = record
    Listen: TListenSpec;
    Loops: Integer;                  { 0 = DefaultLoopCount }
    PinLoops: Boolean;
    H1: TH1Config;
    Workers: Integer;                { -1 = no pool; 0 = Min(32, cpus + 4) }
    WorkerQueueLimit: Integer;
    GraceMs: Integer;                { Stop deadline }
  end;

function ProductionServerConfig: TServerConfig;
function BenchmarkServerConfig: TServerConfig;   { TFB options: no timer, PipelineFlush, amReusePort }
```

---
## 3. Service API

### 3.1 The service and its call (hyper's `Service::call` and future, without closures)

```pascal
unit bearings.http.exchange;
interface
uses bearings.rt.sys, bearings.rt.sync, bearings.rt.loop, bearings.rt.timer, bearings.rt.buf, bearings.rt.stream, bearings.rt.workers,
  bearings.http.error, bearings.http.headers, bearings.http.uri, bearings.http1.role, bearings.http1.decode;
type
  TExchange = class;              { forward declarations: all in this unit }
  TBodySource = class;
  TUpgradeHandler = class;
  TBlockingHandler = class;
  TCallPoll = (cpPending, cpReady);

  { hyper's service future. }
  TServiceCall = class
  public
    { Called by the dispatcher from poll_msg (inside poll_write), on the loop thread, every time the
      connection runs while the call is in flight. cpReady only after a terminal call on Ex
      (Respond, RespondStream, BeginStream, Fail). cpPending: something must call Ex.Wake later. }
    function Poll(Ex: TExchange): TCallPoll; virtual; abstract;
    { The future is dropped, exactly once: Completed = True right after Poll returned cpReady;
      False when the connection abandons the call (client EOF, connection error, shutdown deadline),
      including a call that was never polled. A pooled call returns itself to its pool here. }
    procedure Drop(Ex: TExchange; Completed: Boolean); virtual;
  end;

  { hyper's Service. One instance per loop (TServiceFactory), so it may keep per-loop pools. }
  THttpService = class
  public
    { hyper Service::call, from recv_msg, loop thread, right after the head was parsed. Creates the
      call; must not answer or read the body (builds with assertions assert it: the terminal calls
      and TryRead raise EAssertionFailed while Call runs; S7 fix round 7, deviation S7-46; until
      then nothing asserted it). May emit a log line (the conformance server emits 'request' here,
      as the reference server's call()). }
    function Call(Ex: TExchange): TServiceCall; virtual; abstract;
  end;
  TServiceFactory = function(Loop: TLoop): THttpService of object;
```

Why two steps: hyper creates the future in `recv_msg` and polls it only in `poll_write`. Between the two,
the same `poll_loop` iteration runs the rest of `poll_read`: it prefetches the first body chunk, and it
may detect client EOF (`mid_message_detect_eof`), in which case the future is dropped without ever being
polled. Running the handler only in `Poll` keeps both behaviors (`handler_dropped` instead of
`handler_done` in `disconnect_after_reading_request_before_responding`; the drain count of
`poll_drain_or_close_read`), which the perf and api candidates lost (judges C-P1, C-P2, C-A4).

The inline fast path costs one virtual call more than calling the handler from `recv_msg`:

```pascal
type
  TPlaintextCall = class(TServiceCall)
    function Poll(Ex: TExchange): TCallPoll; override;
  end;
  TPlaintextService = class(THttpService)
    FCall: TPlaintextCall;                                     { stateless: one per service }
    function Call(Ex: TExchange): TServiceCall; override;     { Result := FCall }
  end;

function TPlaintextCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.AddTrusted(@HN_SERVER[1], 6, @HV_WD40[1], 5);    { constants; unit-tested }
  Ex.ResponseHeaders.AddTrusted(@HN_CTYPE[1], 12, @HV_TEXT[1], 10);
  Ex.Respond(BodyStatic(@HELLO[1], 13));                               { no copy, no refcount }
  Result := cpReady;
end;
```

No allocation, no atomic instruction, no string: the exchange is the connection's reused one, the call
is a singleton, the body is static memory, and `Respond` on an unshared exchange is plain stores.

### 3.2 The exchange

#### 3.2.1 Shape

One `TExchange` per request (per stream for HTTP/2 later). An HTTP/1 connection reuses its exchange for
the next request when nobody else holds a reference; otherwise it takes one from the loop's pool. The
exchange is split into three records with separate rules (judge F-A8):

```pascal
type
  TByteSlice = record P: PByte; Len: SizeInt; end;

  { 1. The request head. Written by the dispatcher before Call; read-only afterwards; valid until
       ReleaseRequest (hyper: drop(req)); at the latest until call completion (unshared exchange)
       or the handler's last Release (shared exchange, S7 decision 15). }
  TRequestHead = record
    View: TBytesView;                 { pinned head bytes in the read buffer }
    Method: THttpMethod;
    MethodSlice, Target: TSlice;      { offsets relative to View.P }
    Uri: TUriParts;
    Version: THttpVersion;
    Headers: THttpHeaders;            { external entries, ExternalBase = View.P; reused list }
    ContentLength: Int64;             { DecodedLength: 0 none, -1 chunked or close-delimited }
    ExpectContinue, WantsUpgrade: Boolean;
    Peer, Local: TSockAddrStorage;
    ConnId: QWord;
    RequestNo: LongWord;              { 1, 2, ... per connection }
    Released: Boolean;
  end;

  { 2. The request body channel: a port of body/chan.rs (3.3). }
  TBodyChan = record ... end;

  { 3. The response. Written by the handler until the terminal call; read by the dispatcher after. }
  TResponseSlot = record
    Head: TResponseHead;              { M2 record after S0: Status, Version, Reason slice, Headers }
    Body: TBodyData;                  { Respond }
    Source: TBodySource;              { RespondStream / BeginStream }
    Failed: Boolean;
    FailText: RawByteString;          { cold; Fail(Msg) }
    BodyErrorText: RawByteString;     { cold; set by a source before returning fpError }
  end;

  TBodyReadStatus = (brData, brTrailers, brEnd, brPending, brError, brCanceled);
  TWriteResult = (wrOk, wrWouldBlock, wrCanceled);
  TBodyErrorKind = (bekUnexpectedEof, bekInvalidData, bekInvalidInput, bekIo, bekOther);  { SPEC 7.1 }
  EClientGone = class(Exception);
  EBodyError = class(Exception) public Kind: TBodyErrorKind; end;
  EBodyTooLarge = class(Exception);
```

#### 3.2.2 Interface

```pascal
type
  TExchange = class
  private
    FState: LongInt;                { TExchangeState, CAS when shared }
    FShared: Boolean;
    FRefCount: LongInt;             { 1 = transport only }
    FOwner: TLoopTask;              { the connection driver; nil after cancel/detach }
    FLoop: TLoop;
    WakeMsg, FreeMsg: TLoopMsg;     { embedded messages (1.7) }
    FWakeQueued: LongInt;
    FUser: TObject; FTag: PtrInt;
    function GetStatus: Word;  procedure SetStatus(V: Word);
    function GetRespVersion: THttpVersion;  procedure SetRespVersion(V: THttpVersion);
  public
    Head: TRequestHead;
    Chan: TBodyChan;
    Resp: TResponseSlot;

    { ---- request head (any thread holding the exchange; valid until ReleaseRequest) ---- }
    function Method: THttpMethod; inline;
    function MethodBytes: TByteSlice;
    function Target: TByteSlice;                         { request-target as received }
    function Path: TByteSlice;                           { http Uri::path() rules (M2 TUriParts) }
    function Query(out Q: TByteSlice): Boolean;
    function Version: THttpVersion; inline;
    function Headers: THttpHeaders; inline;              { read-only by contract }
    function Header(const Name: RawByteString; out V: TByteSlice): Boolean;
    function ContentLength: Int64; inline;
    function ExpectsContinue: Boolean; inline;
    function WantsUpgrade: Boolean; inline;
    function ConnId: QWord; inline;
    function RequestNo: LongWord; inline;
    { M5 T-3 (m5-framework.md 12, added in step F6): @Head.Peer, the accepted socket's address,
      which the dispatcher copies into every request's head (TH1Dispatcher.Peer, set in
      TServerLoop.OnAccept: no accept-path change was needed); family 0 for a connection that
      was not accepted from a listener. Its text: bearings.rt.net.SockAddrToStr (IPv4 dotted quad,
      IPv6 by RFC 5952 4, an IPv4-mapped address as IPv4, '' for another family). }
    function PeerAddr: PSockAddrStorage; inline;
    { hyper drop(req): closes the body receiver (unread body: drain or close, never a 100) and
      unpins the head. Automatic at call completion (unshared exchange) or when the last holder
      goes (shared exchange, S7 decision 15, 3.2.3 rule 7). Request-wide: head accessors are
      invalid afterwards for every holder, so on a shared exchange only the request's one user
      (the holder that reads it) calls it. }
    procedure ReleaseRequest;

    { ---- request body (3.3) ---- }
    function TryRead(out Chunk: TByteSlice): TBodyReadStatus;      { never blocks; sets want }
    function Read(Buf: PByte; Max: SizeInt): SizeInt;              { worker only; blocks; 0 = end }
    function ReadChunk(out Chunk: TByteSlice): Boolean;            { worker only; blocks; zero-copy }
    function ReadAll(var Dst: TBytes; Limit: SizeInt): SizeInt;    { worker only; EBodyTooLarge }
    procedure DiscardBody;                                         { close the receiver only }
    function RequestTrailers: THttpHeaders;                        { after brTrailers / brEnd }
    function BodyErrorKind: TBodyErrorKind;
    function BodyErrorMessage: string;                             { SPEC 7.1 canonical text }

    { ---- response head (before the terminal call; shared exchange: only the thread that makes
         the terminal call writes it, S7 decision 16) ---- }
    property Status: Word read GetStatus write SetStatus;                        { 200 }
    property ResponseVersion: THttpVersion read GetRespVersion write SetRespVersion;  { hv11 }
    function SetReason(P: PByte; Len: SizeInt): Boolean;           { FindInvalidReasonByte; copied }
    function ResponseHeaders: THttpHeaders;                        { validating mutators (5.1) }

    { ---- terminal calls: exactly one; any thread holding the exchange; False if the exchange was
         canceled or already answered ---- }
    function Respond(const Body: TBodyData): Boolean;             { known length or empty (3.4) }
    function RespondStream(Source: TBodySource): Boolean;          { unknown length }
    function BeginStream(HighWater: SizeInt = 65536): Boolean;     { RespondStream(TChannelBody) }
    function Fail(const Msg: RawByteString): Boolean;              { hyper: the service returns Err }

    { ---- stream writer after BeginStream (any thread) ---- }
    function Write(P: PByte; Len: SizeInt): TWriteResult;          { worker: parks while full }
    function TryWrite(P: PByte; Len: SizeInt): TWriteResult;       { never blocks }
    function WriteString(const S: RawByteString): TWriteResult;    { keeps one reference, no copy }
    function Finish(Trailers: THttpHeaders = nil): Boolean;        { trailers copied; sent if allowed }
    procedure AbortStream(const Msg: RawByteString);               { body error: chunked left open }

    { ---- upgrades (hyper upgrade::on) ---- }
    procedure OnUpgrade(H: TUpgradeHandler);                       { loop thread, before answering }

    { ---- execution and lifetime ---- }
    function OnLoopThread: Boolean; inline;                        { not FShared (a query; not asserted) }
    procedure Offload(Pool: TWorkerPool; H: TBlockingHandler);     { loop thread, from Poll; shares }
    function Share: TExchange;      { loop thread: switch to shared mode, +1 reference (atomic);
                                      the call or a holder only (3.2.3 rules 2, 7) }
    procedure Release;              { any thread, after Share; last release posts the recycle }
    procedure Wake;                 { re-run the owning connection: local Wake, or Post if shared }
    function IsCanceled: Boolean;   { any thread }
    function Answered: Boolean;     { any thread }
    procedure SetBodyErrorText(const Msg: RawByteString);          { cold; for TBodySource }
    function Loop: TLoop; inline;
    property User: TObject read FUser write FUser;                 { per-request application state }
    property Tag: PtrInt read FTag write FTag;
    { internal, used by the dispatcher }
    procedure CompleteCall;
    procedure Cancel;
  end;

  TExchangeState = (xsIdle, xsCalled, xsAnswered, xsCanceled, xsDone);

  { An application timer that wakes the exchange's connection when it fires. Loop thread. }
  TWakeTimer = record
    T: TTimer;
    procedure Arm(Ex: TExchange; DelayMs: Int64);    { Loop.NowMs + DelayMs }
    function Fired: Boolean; inline;
    procedure Cancel(Ex: TExchange);                 { removes it (owner may be recycled) }
  end;
```

#### 3.2.3 Lifetime and sharing rules

1. The transport holds one reference (`FRefCount = 1`, a plain store at exchange start). The inline
   path never changes the count: no atomic instruction per request.
2. `Share` is the only way to obtain a reference that may be used off the loop thread or after the
   call completed. It runs on the owning loop thread, sets `FShared := True` and does
   `InterlockedIncrement(FRefCount)` before the reference is published (through the worker queue's mutex
   or by the caller's own synchronization). From then on, every cross-thread field is accessed under
   `Chan.Lock` or with interlocked operations. There is no other way to add a reference, so the race in
   api's SSE example (a non-atomic `AddRef` followed by an off-loop `Release`) cannot happen (judge F-A2).
   `Offload` calls `Share` itself. S7 fix round 5 (deviation S7-32): the first `Share` needs the call in
   flight (state `xsCalled` or `xsAnswered`; it raises otherwise), and a later `Share` needs a live holder
   (rule 7; it raises when the holder count is 0, the request is gone). S7 fix round 7 (deviation S7-45):
   `Offload` runs once per request; a second `Offload` raises (in every build) and changes nothing.
3. `Release` is `InterlockedDecrement`. Before it, the reference gives up its holder (rule 7), which may
   drop the request and end the stream; after it, `Release` touches the exchange only when the count
   reached 0 (S7-16, S7 fix round 7: one decrement, no compare-and-swap loop, deviation S7-43). At 0: on
   the loop thread, recycle into the loop pool unless a
   wake message is still queued (`FWakeQueued = 1`), in which case the recycle happens when that
   message is processed; on another thread, post `FreeMsg` (FIFO after any queued `WakeMsg`). Exchanges
   and their blocks are always recycled on their own loop.
4. The transport releases its reference when the call is done, the request-body sender is closed and the
   response body is finished, or when the connection ends. The next request reuses the exchange if the
   count is back to 1, else takes a fresh one from the pool.
5. Terminal calls: unshared → plain stores (`FState := xsAnswered`). Shared → `InterlockedCompareExchange(FState,
   xsAnswered, xsCalled)`; `Cancel` (loop) does `CAS(xsCanceled, xsCalled)`. Exactly one wins; the loser
   returns False. A worker's answer is followed by `Wake` (post). Amended in the second S7 fix (deviation
   S7-23): on a shared exchange the first terminal call claims the response slot before it writes it
   (`CAS(FAnswerClaim, 1, 0)`, with the state still `xsCalled`; `BeginStream` claims before it touches the
   channel); a call that finds the slot claimed returns False and writes nothing, so a second terminal
   call from another thread never changes the winner's response. The claimer then writes the slot and
   does the CAS on `FState` against `Cancel`; if `Cancel` won, the claimer takes back what it wrote.
   Corrected by S7 decision 16: the claim protects `Resp.Body`, `Resp.Source`, `Resp.Failed` and
   `Resp.FailText` only. The response head (`Status`, `SetReason`, `ResponseVersion`,
   `ResponseHeaders`) is not claimed: on a shared exchange it is written by one thread only, the thread
   that will make the terminal call, and only before that call. A thread that writes the head and then
   loses its terminal call has changed the winner's head; that is a program error, which builds with
   assertions report (3.2.4), not a race the exchange resolves.
6. `Cancel` (connection abandons the call, loop thread). Corrected in the S7 fix round 6 (the text said
   that `Cancel` also releases the request and the transport reference). Unshared: `FState :=
   xsCanceled` when the call is still `xsCalled`, `FOwner := nil`, and the request is released
   (`ReleaseRequest`). Shared: `CAS(xsCanceled, xsCalled)`; the cancel that wins closes the receiver for
   the handler and unparks a worker parked in a body read; then `FOwner := nil`, the released head and
   hand-backs are unpinned (`SyncShared`), a producer parked in a stream write is woken, and the call gives
   up its holder (rule 7). On a shared exchange `Cancel` does not release the request itself: the request
   goes with its last holder (rule 7, deviation S7-2). `Cancel` never releases the transport reference:
   the dispatcher's `ReleaseExchange` calls `TExchange.ReleaseTransport` for that (deviation S7-4).
   It does not call `TServiceCall.Drop`: the exchange holds no reference to its call object.
   The dispatcher owns the call (`InFlight`) and calls `Drop` exactly once: `Drop(Ex, True)` in
   `PollMsg` after `cpReady`, or `Drop(Ex, False)` when it abandons the call, right after `Ex.Cancel`
   (`DropAll`, which `Finish` and `Abort` run). A dispatcher test asserts one `Drop` per abandoned call
   (decision 10). The memory stays valid until the last `Release`; later terminal calls return False,
   blocking reads raise `EClientGone`, `Write` returns `wrCanceled`. A body read on a shared exchange
   reads the state under `Chan.Lock` (second S7 fix, deviation S7-23): `Cancel`'s CAS comes before it
   closes the receiver under that lock, so a read that finds the receiver closed by a cancel also finds
   `xsCanceled` and raises `EClientGone`; it never reports the close as the end of the body.
   Amended by S7 decision 15 and the S7 fix round 5 (deviation S7-31): only a cancel that wins the CAS
   closes the receiver for the handler (and unparks a reader parked in `Read`/`ReadChunk`/`ReadFrame`).
   A cancel that loses the CAS to the handler's answer (the connection ended between the answer and the
   dispatcher's next poll) leaves the request with its holders, as a completion does: the dispatcher
   then drops the body sender with hyper's incomplete-message error (`SenderDropGuard`, `DropAll`), so a
   reader gets the chunks that arrived and then `EBodyError` (or the end the body really had), the same
   as when the connection ends after the completion. Either way the call gives up its holder (rule 7).
7. Request lifetime on a shared exchange (S7 decision 15). The request (head view and body receiver)
   belongs to the handler side: it lives after the call completed until `ReleaseRequest` (or
   `DiscardBody` for the receiver alone) or until the last holder goes. The holders (`FHolders`, an
   interlocked count; the transport's reference is not one of them) are the references `Share` handed
   out and, since the S7 fix round 5 (deviation S7-32), the call in flight: the first `Share` counts it,
   and `CompleteCall` or `Cancel` gives it up (hyper: the service future owns `req` until it completes;
   round 4 did not count it, so a holder's `Release` during the call could drop the request while the
   call could still `Share` or `Offload`, and the next holder read a released head). The `Release` (or
   the completion, or the cancel) that takes the count to 0 drops the request, before that `Release`
   gives up its own reference, as hyper drops `req` with its last owner. Until then the dispatcher keeps
   feeding the body receiver, so a worker can answer first and read the body afterwards, or stream its
   answer while it reads (an echo). `ReleaseRequest` and `DiscardBody` are request-wide: they close the
   one receiver and invalidate the head for every holder. So on a shared exchange only the request's one
   user calls them: the holder that reads the body (or the call, before it shares, when no holder reads
   the request); another holder (an SSE producer that only writes) just `Release`s. A body nobody reads
   holds the connection (the slot stays full) until the last holder goes, so the reader releases the
   request as soon as it is done with it. If another holder closes the receiver anyway (a program
   error), a reader parked in a body read is unparked and its read raises `EClientGone` (the read
   reports `brCanceled`): a receiver closed before the reader saw the end is never reported as the end
   of the body (3.3). An unshared exchange drops the request at call completion, as before. S7 fix round
   6 (deviation S7-38): the same read rule holds there. A response source polled on the loop after the
   completion (hyper's inline echo, `Response::new(req.into_body())`) can still call `TryRead`; it gets
   `brCanceled`, not `brEnd`, unless it saw the end the body really had. To read the body after the
   completion, the call shares the exchange in its `Poll` and the source holds that reference (it
   `Release`s it in `Done`): the exchange is then shared and the request lives until that holder goes.
   The stream (S7 fix round 7, deviation S7-43, correcting the rule of deviation S7-5). The holders are
   also the producers of the exchange's stream (`BeginStream`): hyper ends a channel body when its last
   sender is dropped, and the senders live in the tasks that hold them and in the service future until
   it completes. The holder decrement that reaches 0 (the last `Release`, or the completion or cancel of
   the call when no reference is left) ends a stream nobody finished (`fpEnd`, no trailers), right after
   it drops the request and before that `Release` gives up its reference. That decrement is the only
   place the decision is made, and a count of 0 is final (`Share` raises), so no producer can be added
   after the decision. The call in flight counts: a producer that releases while the call can still
   `Share` or `Offload` another producer does not end the stream. Round 6 decided on the reference count
   `Release` loaded (2: itself and the transport) and decremented later with a compare-and-swap that
   compares values only: a count that went 2 -> 3 -> 2 in between (an `Offload` whose worker began the
   stream, wrote and released) let a no-op decision stand and nobody ended the stream; and a helper that
   released during the call ended the stream before the worker the call then offloaded could write.
   Unshared (deviation S7-44): the call is the stream's only producer (rule 2), so `CompleteCall` ends a
   stream the call began and did not finish, as hyper drops the future's sender with the future.

#### 3.2.4 Who writes what, when (cross-thread invariants)

| field | written by | when | read by |
|---|---|---|---|
| `Head.*` | loop (dispatcher) | before `Call` | handler (any thread) until `ReleaseRequest`; pins changed on the loop only |
| `Head.Released` | handler thread; loop at completion (unshared exchange); on a shared exchange the handler's `ReleaseRequest` or the last holder's `Release`, completion or cancel (rule 7), under `Chan.Lock` | once | loop (unpins head on loop) |
| `Chan.*` | loop (sender side) and handler (receiver side) | under `Chan.Lock` when shared; plain when unshared | both |
| `Resp.Body`, `Resp.Source`, `Resp.Failed`, `Resp.FailText` | handler (shared: only the terminal call that claimed the slot, rule 5) | before the terminal call's CAS | loop, after it observed `xsAnswered` (CAS = full barrier) |
| `Resp.Head` (`Status`, `SetReason`, `ResponseVersion`, `ResponseHeaders`) | handler; shared: one thread only, the one that makes the terminal call (S7 decision 16; not protected by the claim) | before the terminal call | loop, after it observed `xsAnswered` |
| `Resp.BodyErrorText` | the response source (loop thread, in `PollFrame`) | before `fpError` | loop |
| `FHolders` | the first `Share` (loop: 2, the call and the new reference), a later `Share` (loop, CAS from a count above 0), `Release` (any thread), `CompleteCall` / `Cancel` (loop: the call's holder, S7 fix round 5) | interlocked | the decrement that reaches 0 drops the request and ends a stream nobody finished (rule 7, S7 fix round 7) |
| `FState` | handler (terminal), loop (`Cancel`, completion) | CAS when shared | both |
| `FShared` | loop | in `Share`, before publication; never cleared until recycle | both |
| `FRefCount` | `Share`, `Release` | interlocked | both |
| `FOwner` | loop | at start, at `Cancel`/detach | loop only (wake messages are processed on the loop) |
| `FUser`, `FTag` | handler | any time | handler |

Debug builds assert `OnLoopThread` in every loop-only method of an unshared exchange and poison recycled
exchanges (0xDD in the head view, generation counter checked by `Wake`). As implemented (S7 decision 17,
deviation S7-29; first written in the S7 fix, S7-18): "debug builds" are the builds with assertions
(`-Sa`, `{$ifopt C+}`: every test build, the conformance server's debug profile). Release builds contain
neither the checks nor their calls (`tools/check-hot-asm.sh --s7` checks the production listing).

- Loop thread. An unshared exchange belongs to its loop thread, so every method of it is loop-only:
  the head accessors (`Method` .. `RequestNo`), `RequestTrailers`, `BodyErrorKind`/`Message`, `TryRead`
  (and through it `Read`, `ReadChunk`, `ReadAll`, `ReadFrame`), `DiscardBody`, `ReleaseRequest`, the response
  head (`Status`, `ResponseVersion`, `SetReason`, `ResponseHeaders`), the terminal calls, the stream writer
  (`Write`, `TryWrite`, `WriteString`, `Finish`, `AbortStream`), `IsCanceled`, `Answered`, `Wake`,
  `SetBodyErrorText`, `FillHead`, `LinkUpgrade` assert it when the exchange is not shared; `Share`,
  `Offload`, `OnUpgrade`, `BeginRequest`, `CompleteCall`, `Cancel` always. Not asserted: `Recycle`,
  `ReleaseTransport` and `TExchange.Destroy` (`TServerLoop.Destroy` runs them on the main thread after the
  loop thread exited), `Release` (it asserts `FShared` instead), `Execute` (the worker job of a shared
  exchange), `OnLoopThread`, `Loop`, `User`, `Tag`.
- Response head (S7 decision 16). On a shared exchange the first head write names its thread
  (`FHeadWriter`, an interlocked compare-and-swap); a head write from another thread, a head write after a
  terminal call claimed the response (`FAnswerClaim = 1`), and a claiming terminal call from another
  thread than the head's writer fail an assertion. The check reads the claim, not the state: the loop's
  `Cancel` is not a terminal call and changes the state at any time, so a head write that a cancel
  overtook is legal (S7 fix round 5, deviation S7-33; round 4 asserted `xsCalled` and failed it).
  `ResponseHeaders` is checked only while the response is not claimed: the loop reads the head after the
  answer. Release builds never write `FHeadWriter`. S7 fix round 6 (deviation S7-39): a claiming terminal
  call that fails the check gives the claim back, releases its body (or calls its source's `Done`) and
  then raises; the job's own error answer (`FailShared(..., CheckHead = False)` from `RunHandler` /
  `HandlerRaised`) is not checked, because a failed answer is a user-service error that does not use the
  head (2.8). Round 5 raised with the claim taken: the job's error answer could not claim, the request
  stayed unanswered and the body was never released.
- Poison. The bytes of a head view are overwritten with 0xDD when the view is unpinned (pool memory only):
  `ReleaseRequest`, `SyncShared`, `Recycle`.
- Generation. `FGen` is bumped by `BeginRequest` and `Recycle`. `Wake` asserts that the exchange is not
  recycled (state `xsIdle`) and, unshared, that it runs on the loop thread. A cross-thread `Wake` stores
  the generation in the exchange's wake message when it posts it (`FWakeGen`); the message's dispatch
  asserts that the generation is still the exchange's (no recycle, and no recycle and reuse, while the
  message was queued: rule 3) before it checks `FWakeQueued = 1` (a node pushed twice would be dispatched
  twice). A caller's own stale reference cannot be told from a live one without a generation of its
  own; the application timer has one (`TWakeTimer`).

### 3.3 Request body: the single-slot channel (body/chan.rs)

```pascal
type
  TChanItemKind = (ciNone, ciData, ciError);
  TBodyChan = record
    Lock: TSpinLock;                 { taken only when the exchange is shared }
    ItemKind: TChanItemKind;
    Item: TBytesView;                { pinned read-buffer view }
    ItemErr, PendingErr: THyperError;
    HasPendingErr: Boolean;
    HasTrailers, TrailersSent: Boolean;   { trailers are in Ex.ReqTrailers (exchange-owned list) }
    SenderOpen, ReceiverOpen, Want, Terminated: Boolean;
    Held: TBytesView;                { the view the receiver is using (TryRead/ReadChunk result) }
    ToRelease: TBytesView;           { shared mode: released by the loop on its next PollReady }
    Parker: TParker;                 { a worker waiting in Read / ReadChunk }
    { sender side: dispatcher, loop thread (chan.rs Sender) }
    procedure Open(Wanter: Boolean);               { want := not Wanter }
    function PollReady(out Closed: Boolean): Boolean;   { releases ToRelease first; Ready if want
                                                          and no item and no pending error }
    function TrySendData(const V: TBytesView): Boolean;
    function TrySendTrailers: Boolean;
    procedure SendError(const E: THyperError);
    procedure CloseSender;                         { drop(Sender): receiver sees end }
  end;
```

Receiver side (`TExchange.TryRead`, port of `Receiver::poll_next` + `Incoming::poll_frame`): release the
previous `Held` (unshared: unpin now; shared: move it to `ToRelease`); `Want := True` and wake the sender
if it was false; take the item (data → `Held`, return `brData` with the slice; error → `brError`); else a
pending error; else sender closed → trailers first (`brTrailers`, once) then `brEnd`; else `brPending`.
Taking an item wakes the sender (the slot is free). A worker's blocking `Read`/`ReadChunk` loop on
`TryRead` and park on `Chan.Parker` while `brPending`; the loop unparks after filling the slot, sending an
error, closing the sender, or closing the receiver (the cancel). S7 decision 15: every close of the
receiver unparks a parked reader: the loop's (`CloseReceiverFromLoop`, only a cancel that won the CAS)
and, since the S7 fix round 5, a holder's (`CloseReceiver`: `ReleaseRequest`, `DiscardBody`, the last
holder's `Release`, when another holder is parked in a read). On a shared exchange, and since the S7 fix
round 6 on an unshared one too (deviation S7-38: a response source that reads after the completion), a
read of a receiver that was closed before the reader saw the end of the body (the channel's `Terminated`
is not set) reports `brCanceled` (`EClientGone`), never `brEnd`; the sender is closed only when the body ended
(`brEnd` after the last chunk) or with an error first (`brError`). Round 4 marked the loop's close with
a flag (`LoopClosed`) that `Chan.Open` reset and the recycle did not: after a cancel, the next request
on the same exchange without a body (no `Open`) read `brCanceled` on a live connection (deviation
S7-31). `Terminated` belongs to the request's own channel, and a request without a body
(`Incoming::empty()`, `Chan.Active = False`) reads `brEnd` before any of it is looked at.

Properties carried over from hyper:

- `want` starts `False` only for `Expect: 100-continue`; with `want = True` the dispatcher fills the slot
  before the handler's first poll (the prefetch).
- One slot: the dispatcher decodes the next chunk only after the receiver took the previous one, so a
  slow consumer stops socket reads and TCP flow control pushes back on the client.
- `ReleaseRequest`, `DiscardBody` and call completion close the receiver; the dispatcher's next
  `PollReady` reports closed and calls `PollDrainOrCloseRead` (hyper `poll_drain_or_close_read`: one
  read of the rest of the body; if it does not end there, reading closes and the connection is not kept
  alive). S7 decision 15 replaces "call completion" for a shared exchange: there the receiver closes at
  `ReleaseRequest`, `DiscardBody` or when the last holder goes (3.2.3 rule 7), and the dispatcher
  feeds it after the completion as long as it is open (dispatch.rs:225-299 does the same while the
  receiver lives). Deviation S7-27: when that body ends after the response was finished, the
  dispatcher drops the ended body's sender at its next head read (hyper keeps it until a later
  request's body replaces it, so hyper's reader of a Content-Length body stays Pending after the last
  chunk).
- Views given to the handler are zero-copy slices of the read buffer, valid until the next body call or
  the terminal call (shared exchange: until the next body call, the request's release or the recycle,
  deviation S7-2). A worker never unpins; it hands the view back through `ToRelease`, which the loop
  processes before it fills the slot again (invariant: whenever the slot is filled, `ToRelease` is empty).

### 3.4 Response bodies

```pascal
{ bearings.rt.buf: TBodyData and its constructors (no HTTP types, so bearings.http1.io can queue them) }
type
  TBodyKind = (bkEmpty, bkMem, bkFile);
  TBodyOwnership = (boStatic, boString, boHeap, boExchange, boCustom);
  TBodyReleaseProc = procedure(Ctx: Pointer; Data: PByte);

  TBodyData = record                 { no managed fields }
    Kind: TBodyKind;
    P: PByte; Len: SizeInt;
    Own: TBodyOwnership;
    Ctx: Pointer;                    { boString: RawByteString payload with one reference held;
                                       boCustom: argument of ReleaseProc }
    ReleaseProc: TBodyReleaseProc;
    Fd: cint; Offset: Int64; CloseFd: Boolean;      { bkFile }
  end;

function BodyEmpty: TBodyData;                             { http_body_util::Empty }
function BodyStatic(P: Pointer; Len: SizeInt): TBodyData;  { memory that outlives the server }
function BodyString(const S: RawByteString): TBodyData;   { RawByteString(Result.Ctx) := S: +1 ref }
function BodyHeap(P: Pointer; Len: SizeInt): TBodyData;   { FreeMem after the write }
function BodyFile(Fd: cint; Offset, Len: Int64; CloseAfter: Boolean): TBodyData;   { sendfile }
procedure ReleaseBody(var B: TBodyData);                   { loop thread, after the bytes left }

{ bearings.http.exchange }
{ A copy of P^ in a block of the loop's block pool (heap without a loop); the block is owned by the
  returned TBodyData (boCustom) and goes back to the pool in ReleaseBody, after the bytes were written. }
function BodyCopy(Ex: TExchange; P: Pointer; Len: SizeInt): TBodyData;
type
  TFramePoll = (fpData, fpTrailers, fpEnd, fpError, fpPending);

  { http_body::Body. Polled on the loop thread only, only while the write buffer has room. }
  TBodySource = class
  public
    function SizeHint(out Exact: QWord): Boolean; virtual;    { default False (unknown) }
    function IsEndStream: Boolean; virtual;                   { default False }
    { fpPending: the source must arrange Ex.Wake. fpError: set Ex.SetBodyErrorText first (cold).
      fpTrailers: ownership of Trailers stays with the source until the next call. }
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; virtual; abstract;
    procedure Done(Ex: TExchange); virtual;                   { the transport dropped it }
  end;

  { Producer: any thread (after BeginStream); consumer: the dispatcher. Bounded by HighWater bytes;
    frame boundaries kept (one Write = one chunk on the wire). }
  TChannelBody = class(TBodySource)
  public
    constructor Create(HighWater: SizeInt);
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;                  { marks closed: producers get wrCanceled }
  end;
```

A stream begun with `BeginStream` and not finished ends when its last producer goes (deviation S7-5;
3.2.3 rule 7 as corrected in the S7 fix round 7, deviations S7-43 and S7-44): on a shared exchange the
holder decrement that reaches 0, on an unshared one `CompleteCall`. Like a dropped hyper `Sender`, it
ends with `fpEnd` and no trailers.

How the dispatcher uses them (dispatch.rs:349-437, 2.4.3): `Respond` with `bkEmpty` or `Len = 0` is
hyper's `is_end_stream()` → no body (content-length 0 except HEAD/204/304); otherwise `Known(Len)`; the one
frame is followed by end of stream, so it goes through `write_body_and_end` and a small response is one
contiguous buffer. `RespondStream`: `IsEndStream` / `SizeHint` choose None / Known / Unknown; `PollFrame`
only while `CanBufferBody`; empty data frames are skipped; trailers go to `WriteTrailers`; `fpError`
ends the connection with `user` and leaves a chunked body unterminated, as hyper. `BodyString` holds a
reference through a typecast assignment (`RawByteString(B.Ctx) := S`), which needs no managed local and
no exception frame (verified with a design-phase probe, `m3-final-probe/strhold.pas`: the generated
code is one `fpc_ansistr_assign` call).

`BodyCopy` does not use a buffer of the exchange: a queued (large) response body can outlive its
request, and the exchange is reused for the next request on the connection, which would
overwrite it. The copy lives in a pool block owned by the `TBodyData` until the frame is written.

### 3.5 Where application code runs

| work | thread | how |
|---|---|---|
| routing decisions that need only the head, static responses, plaintext/JSON from memory, health checks, redirects of inline routes, proxies written in poll style | loop | the call's `Poll` answers at once |
| waiting on a timer or on another loop event | loop | `TWakeTimer`, `Poll` returns Pending, answers on a later `Poll` |
| code that blocks: database, file reads, a blocking HTTP client, `Sleep` | worker | `Ex.Offload(Pool, H)` from `Poll`; `H.Run` uses `Read`/`ReadChunk`, `Respond`, `BeginStream`/`Write` |
| producing a stream from another thread (SSE, broadcaster) | any | `BeginStream`, `Share`, then `TryWrite`/`Write` from that thread, `Release` at the end (the last holder's `Release` also drops the request and ends the stream if nobody called `Finish`; the call in flight is a holder too, 3.2.3 rule 7). `ReleaseRequest` / `DiscardBody` are request-wide: only the request's one user calls them (the call itself, before it shares, when nobody reads the body), never a producer while another holder reads (S7 fix round 5) |

```pascal
unit bearings.rt.workers;
interface
uses bearings.rt.sync;
type
  TWorkItem = class                  { intrusive: the exchange embeds the link, no allocation }
  public
    FNextWork: TWorkItem;
    procedure Execute; virtual; abstract;
  end;
  TWorkerHooks = class
  public
    procedure ThreadStarted(Index: Integer); virtual;      { e.g. open the DB connection }
    procedure ThreadStopping(Index: Integer); virtual;
  end;
  TWorkerPool = class
  public
    { Threads = 0: Proper's MAX_THREADS rule, Min(32, DefaultLoopCount + 4). }
    constructor Create(Threads: Integer; Hooks: TWorkerHooks = nil; QueueLimit: Integer = 0);
    procedure Submit(Item: TWorkItem);    { FIFO under a mutex; idle workers park on a futex }
    function QueueLength: Integer;        { lets a router answer 503 inline above a limit }
    procedure Shutdown(WaitMs: Integer);  { finish queued items, join }
  end;

unit bearings.http.exchange;   { continued }
type
  TBlockingHandler = class
  public
    procedure Run(Ex: TExchange); virtual; abstract;   { worker thread; may block }
  end;

  { Shared, stateless call that offloads: one per (pool, handler). }
  TOffloadCall = class(TServiceCall)
  public
    Pool: TWorkerPool;
    Handler: TBlockingHandler;
    { First poll: Ex.Offload(Pool, Handler), Pending. Later polls: cpReady once Ex.Answered. }
    function Poll(Ex: TExchange): TCallPoll; override;
  end;
```

The worker job wraps `Handler.Run(Ex)` in `try/except` (one frame per job, not per request on the
loop): an escaping exception becomes `Ex.Fail('handler raised <class>: <message>')`; a handler that
returns without a terminal call gets `Ex.Fail('handler returned no response')`; then `Ex.Release`.

Cost (measured with the prototype, T3): an offloaded request costs about 5.4 us more CPU than an inline
one at depth 1. That is negligible for a handler that waits 100 us or more on a database and is why the
benchmark routes and other non-blocking routes run inline.

### 3.6 Backpressure and cancellation

| direction | mechanism |
|---|---|
| client → handler (request body) | single slot + `want`; read buffer bounded by `max_buf_size`; the TCP window closes when the handler is slow |
| handler → client (response body) | `PollFrame` only while `CanBufferBody` (write buffer below `max_buf_size`, queue below 16 entries); `TChannelBody` bounded by `HighWater`: `Write` parks the producer, `TryWrite` returns `wrWouldBlock` |
| work → worker pool | one request in flight per HTTP/1 connection, so the queue is bounded by open connections; optional `QueueLimit` |
| client gone | `half_close = False`: EOF while busy → `IncompleteMessage` → connection ends → `Cancel`: `TServiceCall.Drop(Ex, False)` on the loop, `IsCanceled` for workers, blocking calls raise `EClientGone`, terminal calls return False, `TChannelBody` producers get `wrCanceled` (a write of 0 bytes too, since the S7 fix round 6, deviation S7-40). A running database query is not interrupted; its result is discarded |

### 3.7 Upgrades from the application's side

`Ex.OnUpgrade(H)` registers before answering (hyper `upgrade::on(&mut req)`); the handler answers 101
(or 2xx to CONNECT). After the HTTP layer finished and `conn_close` was reported, `H.Upgraded(U)` runs on
the loop thread with a `TUpgraded` (2.7): stay on the loop with `U.Attach(Listener)` (WebSocket frame
handling, proxies), or `U.Detach` to a thread for blocking use (`Detach` itself is called on the loop
thread, for example inside `Upgraded`; the fd it returns can go to any thread). Plain mode: `H.UpgradeFailed(...)`.

Ownership of `U` (S8, fix HS6-3): the handler owns `U` from the call of `Upgraded` on, and is then
responsible for closing it (directly, through its listener, or after `Detach` through the fd). If
`Upgraded` raises while `U` is neither attached, detached nor closed (`U.Taken` is false), wd-40
closes `U` and the exception goes on to the loop, which logs it and aborts the delivery task (1.10);
before the fix the socket and its epoll entry leaked. Once the handler took `U`, an exception leaves it
alone (an attached listener keeps running).

```pascal
type
  TUpgradeHandler = class
  public
    procedure Upgraded(U: TUpgraded); virtual; abstract;      { loop thread }
    procedure UpgradeFailed(const Msg: string); virtual;      { loop thread }
  end;
```

### 3.8 M5: Proper-like Request/Response on top

Proper runs synchronous controller code on server threads (`MAX_THREADS`, one database connection per
thread), through a pipeline: head_to_get, method_override, match, redirect, copy_session, dispatch
(before callbacks, action, after callbacks), update_session_cookie (`app.md`, Request Lifecycle).
`method_override` reads `X-HTTP-Method-Override`, then `_method` in the query, then `_method` in the
**form body** (`controllers.md`), so the route of a form POST is not known before the body is read.
Therefore:

- The loop only **classifies** a request: inline route or worker. A request is inline only if its route
  is flagged `inline` and can be determined from the head: the method is not POST, or it is a POST whose
  override comes from the header or query, or whose content type is not a form. Every other request goes
  to the worker.
- The worker runs the **whole** pipeline from step 1 (it does not reuse the loop's classification), with
  the database connection management around it. An inline route runs the same pipeline code on the loop
  (its route was flagged by the app author as never blocking).

```pascal
unit wd.web.router;      { M5, sketch }
type
  TRouterService = class(THttpService)
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function TRouterService.Call(Ex: TExchange): TServiceCall;
var R: TRoute;
begin
  R := FApp.Routes.ClassifyHead(Ex);       { CPU only, slices, no strings; nil = needs the body }
  if (R <> nil) and R.Inline then Result := FInlineCall      { runs FApp.RunPipeline on the loop }
  else Result := FWorkerCall;               { TOffloadCall(Pool, TPipelineRunner) }
end;

type
  TPipelineRunner = class(TBlockingHandler)
    procedure Run(Ex: TExchange); override;
  end;

procedure TPipelineRunner.Run(Ex: TExchange);
var Req: TRequest; Res: TResponse;
begin
  Req := TRequest.Create(FApp, Ex);         { lazy fields: 53 ns vs 360 ns eager (T6) }
  Res := TResponse.Create(FApp, Ex);
  try
    try
      FApp.RunPipeline(Req, Res);           { around_request -> head_to_get ... update_session_cookie }
      Res.CommitTo(Ex);                     { status, validated headers, Set-Cookie, body (no copy) }
    except
      on EClientGone do Ex.Fail('client gone');
      on E: Exception do
      begin
        FApp.HandleError(E, Req, Res);      { router.error(...) controller, on_error hooks, 500 page }
        Res.CommitTo(Ex);
      end;
    end;
  finally
    FApp.RunTeardown(Req, Res);
    Res.Free; Req.Free;                     { Req.Free calls Ex.ReleaseRequest }
  end;
end;
```

| Proper (`api.md`) | M5 on the exchange |
|---|---|
| `request.method`, `request_method`, `path`, `query_string`, `http_version`, `headers` | lazy AnsiStrings built once from `Ex.MethodBytes`, `Ex.Path`, `Ex.Query`, `Ex.Version`; `headers` a MultiDict view over `Ex.Headers` |
| `host`, `port`, `protocol`, `remote_ip`, `is_secure` | `Host` header / URI authority, `Head.Peer`, forwarded headers |
| `content_length`, `content_type` | `Ex.ContentLength`, header |
| `form` (urlencoded, multipart) | `ReadChunk` on first access; `MAX_CONTENT_LENGTH` checked against `Ex.ContentLength` before reading (413), counted for chunked bodies; large parts spool to temp files |
| `cookies`, signed cookies, `session` | parse `Cookie`; HMAC via OpenSSL libcrypto |
| `response.status`, `headers`, `body`, `set_cookie`, `redirect_to`, cache helpers | M5 objects; `CommitTo` copies status and headers (validating `Add`), then `Ex.Respond(BodyString(Body))` |
| `send_file` | `BodyFile` (sendfile); `fstat` for length and headers |
| HEAD → GET, body dropped | nothing to do: the encoder sends `content-length` and no body for HEAD (hyper) |
| `current` | threadvar set by the worker for the duration of `Run` (2.7 ns per access is acceptable here) |
| `around_request`, `on_error`, `on_teardown` | inside `Run`'s `try/except/finally` |
| per-thread database connections | `TWorkerHooks.ThreadStarted/ThreadStopping` |
| controller callbacks (`before`, `after`) | published methods resolved by name once per class with `MethodAddress` (requires `{$M+}`), stored as `TMethod`; no per-request string lookups |

Streaming from a controller (CSV export; client disconnect stops the loop at the next `Write`):

```pascal
procedure TReportController.Export;          { worker thread }
var Q: TQuery;
begin
  Response.ContentType := 'text/csv';
  Response.Stream;                           { commits status + headers: Ex.BeginStream }
  Q := DB.Query('select id, title from cards order by id');
  try
    while Q.Next do
      if Ex.WriteString(Q.CsvLine) = wrCanceled then Exit;   { parks while 64 KiB are unsent }
    Ex.Finish;
  finally
    Q.Free;
  end;
end;
```

Server-sent events from another thread (the call answers at once, a ticker thread keeps the exchange):

```pascal
function TSseCall.Poll(Ex: TExchange): TCallPoll;      { loop thread }
begin
  Ex.ResponseHeaders.Add('content-type', 'text/event-stream');
  Ex.BeginStream(16 * 1024);
  Ticker.Subscribe(Ex.Share);                { Share: shared mode + atomic reference }
  Result := cpReady;
end;
{ ticker thread: if X.TryWrite(P, Len) = wrCanceled then begin X.Release; remove X; end }
```

### 3.9 HTTP/2 fit (M4, libnghttp2)

| nghttp2 callback | exchange operation |
|---|---|
| `on_begin_headers` | take an exchange from the loop pool (one per stream; no per-connection reuse) |
| `on_header` | `Ex.Head.Headers.AddTrusted` into the exchange's arena (nghttp2 validated; h2 has no read buffer to point into) |
| `on_frame_recv` (HEADERS with END_HEADERS) | `InFlight := Service.Call(Ex)`; poll it from the session driver |
| `on_data_chunk_recv` | copy into the exchange's body slot; `nghttp2_session_consume` when the handler takes it (flow control = backpressure, as hyper releases capacity on poll) |
| data provider `read_callback` | the stream's `TBodySource.PollFrame`; `fpPending` → `NGHTTP2_ERR_DEFERRED`; `Ex.Wake` → `nghttp2_session_resume_data` |
| trailers | `nghttp2_submit_trailer` from the `fpTrailers` frame |
| `on_stream_close` with an error code | `Ex.Cancel` for that stream only |

The service, call, exchange, body and worker types do not mention HTTP/1. `THttpVersion`/`THttpMethod`
move from `bearings.http1.role` to `bearings.http.types` when M4 starts (role re-exports them).

---
## 4. Memory

### 4.1 Ownership

| object | owner | lifetime |
|---|---|---|
| `TH1Dispatcher` (embeds `TH1Conn`, `TH1Io`, decoder, encoder, timers) | its loop | accept → close; freed after the event batch (F10) |
| read buffer block | `TReadBuf` while it holds bytes or views are pinned; the loop pool otherwise | 4.3 |
| head cursor block (`TByteVec`) | `TWriteBuf` while bytes are buffered; the loop pool otherwise | 4.3 |
| queue array (32 `TQueuedBuf` slots) | `TBufList` while entries exist; the loop pool otherwise | 4.3 |
| queued body data | its `TBodyData` until written | released in `TBufList.Advance`, or right after the copy into the cursor |
| `TExchange` (+ request header list, response header list, trailer list) | the loop's exchange pool; references: transport + `Share` | 3.2.3 |
| call objects | singletons (stateless) or the service's per-loop free lists | `TServiceCall.Drop` returns them |
| `TUpgraded` | its loop | until closed or detached |

### 4.2 Zero-copy slices and their lifetimes

| slice | points into | valid until | kept alive by |
|---|---|---|---|
| request method, target, URI parts, header names/values | read buffer (head region) | `ReleaseRequest` or call completion (hyper: the request is dropped); shared exchange: `ReleaseRequest` or the handler's last `Release` (S7 decision 15), unpinned on the loop | `Head.View` pin |
| request body chunk (`TryRead`/`ReadChunk`) | read buffer (body region) | the next body call or the terminal call | `Chan.Held` pin |
| request trailers | decoder scratch, parsed into the exchange's trailer list (arena copy) | exchange recycle | exchange |
| response headers | exchange's response list arena | encode time | exchange |
| `BodyStatic` | caller's memory | forever | caller |
| `BodyString`, `WriteString` | AnsiString heap block | the frame is written | one reference in `TBodyData.Ctx` |
| `BodyCopy`, `Write` | a pool block owned by the `TBodyData` / channel ring | the frame is written | the `TBodyData` (block freed in `ReleaseBody`) / channel |
| `TUpgraded` leftover | read buffer | `ConsumeLeftover` / `Close` / `Detach` (copied) | pin |

Rules enforced by `TReadBuf.Reserve` (2.2.1): a block with pins is never moved or compacted; when the
buffer needs room, the unread bytes move to a new block and the old block is freed when its last view
is released. Pins are loop-thread counters; workers hand releases to the loop
(3.3). Debug builds poison freed blocks (0xDD) and assert `Pins >= 0`.

hyper pays an atomic `Arc` increment for every `split_to().freeze()` (each head and body chunk); this
design pays a plain increment, since every pin and unpin happens on the loop thread.

### 4.3 Pooling and per-connection RSS

`TBlockPool` (one per loop): size classes 8, 16, 32, 64, 128, 256, 512 KiB and 1 MiB, LIFO free lists
(cache-hot), list lengths capped (default 64 MiB pooled per loop), larger blocks straight from the heap.
No zero-fill (blocks are written before they are read). `Trim` runs when a loop iteration finds the
loop idle for 1 s.

```pascal
{ bearings.rt.buf }
type
  TBlockPool = record                { one per loop; loop thread only }
    procedure Init(MaxPooledBytes: SizeInt);
    function Take(MinSize: SizeInt): PBufBlock;     { smallest class >= MinSize; heap above 1 MiB }
    procedure Give(B: PBufBlock);                   { requires B^.Pins = 0 }
    procedure Trim;                                 { free cold blocks down to the cap }
  end;

{ bearings.http.exchange }
type
  TExchangePool = class              { one per loop; loop thread only }
  public
    function Take(Loop: TLoop): TExchange;          { cleared exchange, FRefCount = 1 }
    procedure Give(Ex: TExchange);                  { recycle: lists cleared, capacity kept }
  end;
```

A connection gives its blocks back when it is idle: `Reading = rdInit`, `Writing = wrInit`, read
buffer empty with no pins, write buffer empty, no exchange in flight. The checks run at the end of
`TH1Dispatcher.Run` (a few compares). The next read or write takes a block from the pool again. The
exchange goes back to the exchange pool at the same moment
(when its count is 1), and the connection's trailer scratch (`TConnScratch.TrailerNames`,
`TrailerBytes`; both are per request in hyper) is freed (`TH1Conn.ReleaseIdleScratch`).

| item | bytes (estimate) | held |
|---|---|---|
| `TH1Dispatcher` + `TH1Conn` (decoder, encoder, timer, parse context, buffer descriptors, state) | ~800 | always |
| `TExchange` + request header list (16 external entries) + response header list (16 entries, 1 KiB arena) | ~3 000 | while a request is in progress |
| read block | 8 KiB; grows by pool class up to `max_buf_size` | while it holds bytes or pinned views |
| head cursor block | 8 KiB | while response bytes are unflushed |
| queue array (32 x `TQueuedBuf` slots, 200 B each = 6 400 B) | 8 KiB (the smallest pool class) | while entries are queued (bodies over 4 KiB, files, entries behind them) |
| trailer scratch (declared trailer names, decoder trailer bytes) | heap, as large as the trailers | during a request with trailers; given back when the connection is idle (decision 13) |

Idle keep-alive connection ≈ 0.8 KB (target ≤ 2 KB; prototype measured 1.7 KB, hyper 10.7 KB). The
targets are checked at every perf gate (7.6).

### 4.4 No refcount traffic and no implicit exception frames on the hot path

- Hot routines take `PByte` + length; no `string`, `RawByteString` or dynamic-array locals, parameters
  passed by value, or temporaries. Routines with any of these get a `fpc_pushexceptaddr` + `fpc_setjmp`
  frame (12-20 ns per call).
- **S0 removes the managed fields M2 has on the hot path:**
  - `TEncoder.FTrailerFields: array of RawByteString` → `FTrailers: PTrailerFieldSet`, a per-connection
    scratch (`TConnScratch`) holding the declared trailer names as slices in a small arena. Effect:
    `SetLengthEncoder`/`SetChunkedEncoder`/`MakeEncoder` and `ServerEncode`'s `out Encoder` lose their
    implicit frames (verified to exist today with `-al`, judge P-A2).
  - `TDecoder.FTrailerBuf: TBytes` → `FTrailerScratch: PByteVec` into `TConnScratch`.
  - `TResponseHead.Reason: TReasonPhrase` (a `RawByteString`) → `ReasonP: PByte; ReasonLen: SizeInt`;
    `TReasonPhrase` stays as the application-side validated type.
  - `EncodeTrailers` encodes into a `TByteVec` instead of returning a fresh `TBytes`.
- **Build check** (`tools/check-hot-asm.sh`, run by the unit-test target): compile the hot units with
  `-al`, extract the listed routines from the `.s` files, fail if any contains `fpc_pushexceptaddr` or
  `fpc_setjmp`. List: `TH1Dispatcher.{Run,PollLoop,PollRead,PollReadHead,PollWrite,PollFlush,PollInner,
  PollCatch,PollMsg,RecvMsg}`, every `TH1Conn` and `TH1Io` method, `TReadBuf.*`, `TByteVec.*`,
  `TTcpTransport.*`, `ServerParse*`, `ServerEncode`, `EncodeHead`, `MakeEncoder`, `SetLengthEncoder`,
  `SetChunkedEncoder`, `TEncoder.{Encode,EncodeAndEnd,Finish}`, `TDecoder.Decode`,
  `TExchange.{Respond,TryRead,ReleaseRequest}`, `TBodyChan.*`, `TTimerWheel.*`, `TLoop.RunIteration`.
- No threadvars on the hot path: date cache, pools and timers are reached through the loop object.
- No management operators (`class operator Initialize/Finalize`) in hot records: they make every local of
  that type a managed local (judge F-F5).
- `IsMultiThread` makes AnsiString refcounts `lock`-prefixed; the transport touches an AnsiString per
  request only for `BodyString`/`WriteString` (one increment, one decrement).

### 4.5 Per-request allocations

Inline path: none (exchange reused, call singleton, header lists cleared and reused, read and write
blocks from the loop pool, `TBodyData` is a record). Worker path: none in steady state either (the
exchange comes from the pool, the work item link is embedded); M5's `TRequest`/`TResponse` objects are
allocated per request on the worker, which is accepted at that layer.

---

## 5. Header value validation and the trailer fixes

### 5.1 Validation boundary (fix for CR/LF/NUL in values)

In hyper an invalid header cannot exist: `HeaderName::from_bytes` (tokens) and `HeaderValue::from_bytes`
(HTAB, bytes >= 0x20 except 0x7F) reject it when the application builds it, and the encoder copies bytes
without checking. The port puts the check at the same place, the `THttpHeaders` mutators:

```pascal
{ bearings.http.headers (S0) }
type
  THeaderCheck = (hcOk, hcBadName, hcBadValue);
  EInvalidHeader = class(Exception) public Check: THeaderCheck; end;

  THttpHeaders = class
  public
    { Validating (IsValidHeaderName, IsValidHeaderValue from M2). Raise EInvalidHeader. }
    function Add(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt; overload;
    function Add(const Name, Value: RawByteString): SizeInt; overload;
    function Append(const Name, Value: RawByteString): SizeInt;
    procedure Insert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure Insert(const Name, Value: RawByteString); overload;
    procedure SetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure SetValue(I: SizeInt; const Value: RawByteString); overload;
    { Same checks, no exception. }
    function TryAdd(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TryInsert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TrySetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    { No checks, in every build: bytes valid by construction (parser and decoder output, nghttp2,
      constants covered by a unit test, copies from another validated list). Tests store invalid bytes
      with them on purpose; the -Sa assertion is where bytes reach the wire (ServerEncode,
      EncodeTrailers), below. }
    function AddTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
    procedure InsertTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
    function AddExternal(NameOfs, NameLen, ValueOfs, ValueLen: SizeInt): SizeInt;   { unchanged }
    { ... rest of the M2 interface unchanged ... }
  end;
```

- M2 internal callers switch to the trusted variants: `ParseTrailers` in `bearings.http1.decode` (httparse
  rules already applied). (The helpers `AddChunked` and `SetContentLengthIfMissing`, also listed here
  at first, were later removed because nothing called them.)
  M2 tests that insert invalid bytes on purpose move to `AddTrusted` and get a twin test asserting the
  validating method raises.
- `ServerEncode` and `EncodeTrailers` assert every name and value they write in `-Sa` builds, so a missed
  path shows up in tests. The `*Trusted` methods do not assert (S0 requires "`*Trusted` do not check",
  and M2 tests store invalid names with `AddTrusted`). `-Sa` builds also count the validating mutator
  calls (`ValidatingMutatorCalls`), so `test_headers_validate` shows that the library callers use the
  trusted paths (decision 13).
- Reason phrase: `Ex.SetReason` uses `FindInvalidReasonByte` (M2); `TReasonPhrase.TryFrom` stays.
- Cost: one table lookup per byte (`HeaderValue::from_bytes` does the same work); constants use
  `AddTrusted`. Measured in S0 with `bench_role`.
- Where an exception from `Add` lands: in a worker, the job's `try/except` (3.5); in an inline handler,
  the loop's per-iteration handler aborts the connection (1.10), as a panic in a hyper service would.
- The conformance server validates reply headers, trailers and reasons at config load with `TryInsert`
  / `FindInvalidReasonByte` and exits with status 2, as the reference server does with
  `HeaderValue::from_bytes`.

### 5.2 Trailer encoding fixes

Found by comparing `encode.rs:167-222` (`encode_trailers`), `role.rs:868-998` and `conn.rs:758-779`
(`write_trailers`) with `bearings.http1.encode.pas` / `bearings.http1.role.pas`:

| # | hyper | M2 | wire effect | fix (S0, at unit level) |
|---|---|---|---|---|
| T1 | `encode_trailers` collects allowed fields into a new `HeaderMap`, and `write_headers` iterates it: values **grouped by name in order of first appearance** | `EncodeTrailers` writes in list order | `a: 1, b: 2, a: 3` is written `a, a, b` by hyper and `a, b, a` by M2 | write grouped, with the same done-flag walk `ServerEncode` already uses for response headers |
| T2 | names and values are valid by construction | any bytes are copied | CR/LF in a trailer value injects lines into the trailer section | 5.1 boundary + `-Sa` assertion in `EncodeTrailers` |
| T3 | `write_trailers`: nothing unless the request had `TE: trailers` (`allow_trailer_fields`); when `encode_trailers` returns `None` (no declared field survives, or `Chunked(None)`), the state stays `Body` and the next `poll_write` calls `end_body` (`0\r\n\r\n`); after trailers, `Closed` if `is_last` or close-delimited, else `KeepAlive` | `EncodeTrailers` returns a fresh `TBytes`; the conn-level rule does not exist yet | without the port, trailers would be sent without `TE: trailers` or a chunked body would stay unterminated | `TH1Conn.WriteTrailers` ports conn.rs:758-779; `EncodeTrailers(T: THttpHeaders; TitleCase: Boolean; var Dst: TByteVec; Pool: PBlockPool): Boolean` appends into a buffer that becomes a `qkTrailers` queue entry |

Also removed in S0 (no wire effect): the managed `FTrailerFields` (4.4) and the per-call allocation.

Verification: fixed expectations in `test_codec_encode`, `test_codec_extra` and `test_role_extra` (T1
and T3). Until step T1 a differential test also ran hyper's `Encoder::encode_trailers` on generated
inputs (`test_trailer_diff.sh`); T1 retired it with the other encode differentials (user decision
2026-10-08). T2 cannot be tested differentially: hyper cannot hold a header value with CR, LF or NUL
(`HeaderValue::from_bytes` rejects it), so T2 is tested at unit level only (`test_headers_validate`:
the validating mutators raise, `EncodeTrailers` / `ServerEncode` assert in `-Sa` builds). Conn-level
unit tests cover each `WriteTrailers` branch; the six `http1_trailer_*` cases cover the wire.

---

## 6. The Pascal conformance server (implements `conformance/SPEC.md`)

Location: `conformance/pascal-server/`: `beconf.lpr` (program) and units `beconf.spec` (JSON spec and
validation), `beconf.events` (event lines), `beconf.service` (handlers, replies, script bodies),
`beconf.upgrade` (upgrade tasks, latches), `beconf.control` (stdin task). Binary:
`build/conformance/beconf`. It is a thin wrapper: everything on the wire comes from `bearings.http1.*`.

Command line: `beconf [--executor inline|worker] [--loops N] --config <path>` (the runner appends
`--config`). Default: `--executor inline --loops 1`: one loop on the main thread, like the reference
server's current-thread runtime, so event order and timing follow the same model.

### 6.1 Process protocol (SPEC 3)

| SPEC item | implementation |
|---|---|
| `--config <path>` (and `--config-json`) | `beconf.spec` reads and parses with its own JSON parser (not `fpjson`, which drops `\u0000` and converts code pages; text corrected in S6, deviation S6-7). Unknown field, wrong type, a value hyper rejects (`max_buf_size < 8192`, `header_read_timeout_ms` number with `timer` false, invalid header name/value, invalid reason bytes, status outside 100..999, bad `version` string) → message on stderr, exit 2, no `LISTENING` |
| byte strings | JSON string → code points ≤ U+00FF → bytes; part arrays (`repeat`, `hex`) as SPEC 2 |
| bind `127.0.0.1:0`, `LISTENING <port>` | `amSingle` listener with mio's options: `SO_REUSEADDR`, backlog 128, no `TCP_NODELAY` (also not on accepted sockets); `getsockname`; one `write(1, ...)` of the line before the loop starts |
| connections numbered 1, 2, ... in accept order | observer counter at accept (one loop: exact). With `--loops N` the listener is `amSharedExclusive` and the counter is atomic; ordering across loops is then approximate (assertion mode only, 7.4) |
| stdout: one JSON object per line, atomic | `TEventWriter` builds the line (cold path, strings allowed) and writes it with one `write(1, ...)` loop under a mutex (needed only with `--loops N` or `--executor worker`) |
| stdin control | fd 0 non-blocking, registered level-triggered in loop 0's epoll; `TControlTask` splits lines. If `epoll_ctl` refuses fd 0 (a regular file), a reader thread posts lines to loop 0 instead |
| `graceful_shutdown` | `GracefulShutdown` on every live connection of every loop (1.11), synchronously on loop 0 (one loop) or with an `lmCall` + countdown per loop; then `control_ack`. The ack follows the effect, as SPEC 3.4 requires |
| `signal <name>` | latch registry (set of names, never reset) + waiter list of tasks; set, wake waiters, then ack |
| `exit`, stdin EOF | `fpExit(0)` immediately |
| other lines | `control_error` with the line; empty lines ignored |
| SPEC 7 ordering of `bytes_read` and `graceful_shutdown` | the read, the `bytes_read` event and the buffering happen inside one `Run` of the connection task; control lines are processed by another task, never inside a connection's `Run` |

### 6.2 `config` fields (SPEC 4), field by field

| field | mapping |
|---|---|
| `keep_alive` | `TH1Config.KeepAlive`; `False` → `Conn.DisableKeepAlive` at construction (http1.rs:481) |
| `half_close` | `HalfClose` → `SetAllowHalfClose` |
| `title_case_headers` | `TitleCaseHeaders` → encode params and `EncodeTrailers(TitleCase)` |
| `preserve_header_case` | `PreserveHeaderCase`: accepted; no wire effect (THttpHeaders always keeps request case; no response case map is produced), which SPEC 4 allows |
| `max_headers` | `SetMaxHeaders` → `ParseCtx.MaxHeaders` and the decoder's trailer count limit |
| `max_header_size` | `SetMaxHeaderSize` → the `Parse` check and the decoder's trailer byte limit |
| `max_buf_size` | `SetMaxBufSize` → `TReadStrategy.InitWithMax` and `WriteBuf.MaxBufSize` |
| `timer` | `TH1Config.Timer` (with `false` no header timeout is armed, even the default) |
| `header_read_timeout_ms` | absent → `tsDefault` (30 s, only with timer); `null` → `tsDisabled`; number → `tsMs` (config error without timer) |
| `writev` | checked as a boolean and ignored: one write path since T1 (2.2.4) |
| `pipeline_flush` | `PipelineFlush` → `SetFlushPipeline` |
| `auto_date_header` | `AutoDateHeader` → `DisableDateHeader` when false |
| `ignore_invalid_headers` | `Parser.IgnoreInvalidHeadersInRequests` |
| `allow_multiple_spaces_in_request_line_delimiters` | `Parser.AllowMultipleSpacesInRequestLineDelimiters` |
| `conn_mode` | `TH1ConnMode`: `plain` / `with_upgrades` / `without_shutdown` |
| `graceful_shutdown_on_accept` | `GracefulShutdown` right after the dispatcher is created, before its first `Run` (→ `HasInitialReadWriteState` → closed, outcome `ok`, nothing written) |
| `bytes_read_events` (server spec) | the socket's `TTcpTransport` is wrapped in `TCountingTransport = class(TTransport)` (the reference's `CountIo`): counts bytes, emits `bytes_read` after each read that returned data, before returning to `TH1Io` (so before parsing); delegates writes and `IsWriteVectored`; the upgrade hand-off unwraps it, so upgrade-task reads are not counted |

### 6.3 Handlers (SPEC 5.1), one by one

All three are `TConfService = class(THttpService)`. `Call` (in `recv_msg`) does what the reference
server's `call()` does: assigns `req` (per-connection counter), emits `request` (method token, target as
received, version, headers lowercased and grouped by first appearance of each name, as `HeaderMap`
iterates), takes the next reply for `test_service` (process-wide queue; `{}` when empty), and returns a
new `TConfCall` (one per call, freed by its `Drop`; text corrected in S6, deviation S6-17) whose `Drop(Ex, False)` emits `handler_dropped` (the reference's `DropGuard`, created
in `call()`, so a call that is never polled still emits it). `handler_done` is emitted inside `Poll`
right before it returns `cpReady` (`result` `response` + `status`, or `error` + `message`).

| handler | `TConfCall.Poll` |
|---|---|
| `hello_world` | first poll: `Respond(BodyStatic('hello'))` (exact length 5), `handler_done(response, 200)`, `cpReady`. The body is never read; the request is released at completion (as `handle` returns), so an unread body goes through drain-or-close without a 100 |
| `unreachable` | first poll: `Fail('request shouldn''t be received')`, `handler_done(error)`, `cpReady` → `poll_msg` error → outcome `user`, nothing written |
| `test_service` | the state machine of 6.4 |

### 6.4 `test_service`: the SPEC 5.5 sequence and the reply fields

`TConfCall` fields: `Reply`, `Step: (stUpgradeReg, stReadBody, stRelease, stDelay, stError, stUpgrade,
stRespond)`, collected body (`RawByteString`, cold), trailers flag, `Delay: TWakeTimer`.

1. `request` was emitted in `Call` (step 1); the reply was taken in `Call` (step 2: "at the moment the
   handler is called").
2. `upgrade.on_upgrade` true: `Ex.OnUpgrade(TConfUpgradeHandler.Create(Spec))` (step 3, before the
   request is released).
3. `read_body` true (default): loop `Ex.TryRead`: `brData` → append; `brTrailers` → copy
   `Ex.RequestTrailers` for the event; `brPending` → return `cpPending` (the channel wakes the
   connection); `brEnd` → emit `request_body` (`body`, plus `trailers` if the request had a trailer
   section); `brError` → emit `request_body_error` with `kind` (`unexpected_eof` / `invalid_data` /
   `invalid_input` from `DecodeErrorKind`, `io` for an errno, `other` for anything else, e.g. the
   "connection error" body error) and `message` (`DecodeErrorMessage` for decode errors, the OS text for
   errno, hyper's Display text otherwise), then `Fail('req body error')`, `handler_done(error)`, `cpReady`.
4. `Ex.ReleaseRequest` (step 5: `drop(req)`; with `read_body` false this is the first body interaction,
   so no 100 Continue is ever sent).
5. `delay_ms` > 0: `Delay.Arm(Ex, delay_ms)`, `cpPending` until `Delay.Fired` (step 6). If the connection
   ends first, `Drop(Ex, False)` removes the timer and emits `handler_dropped`.
6. `error` set: `Fail(error)`, `handler_done(error)`, `cpReady` (step 7).
7. `upgrade` set (step 8): with `on_upgrade` the handler registered in 2; without, the spec is stored in
   the connection's observer data for the `without_shutdown` hand-off.
8. Response (step 9):

| reply field | mapping |
|---|---|
| `status` | `Ex.Status` (1xx other than 101 passes through: the encoder writes a 500, outcome `user`) |
| `reason` | `Ex.SetReason` (validated at load) |
| `version` | `HTTP/1.0` → `hv10`, `HTTP/1.1` → `hv11`, `HTTP/2.0` → `hv2` (written as HTTP/1.1), `HTTP/0.9` → `hv09`, `HTTP/3.0` → `hv3` (the connection task aborts like the reference's panic: no `conn_close`, 2.8) |
| `headers` | `Ex.ResponseHeaders.Insert` per pair, in order (insert semantics: a repeated name replaces the earlier value at its position) |
| `body` absent | `Respond(BodyEmpty)` |
| `body.known` | `Respond(BodyString(b))` (an empty string is end-of-stream, as an empty `Full`) |
| `body.stream` | `RespondStream(TScriptBody)` (6.5) |
| `read_body`, `delay_ms`, `error`, `upgrade` | steps 3-7 above |

Then `handler_done(response, status)`, `cpReady`.

### 6.5 Bodies (SPEC 5.4)

| spec | Pascal |
|---|---|
| absent | `BodyEmpty`: end-of-stream, exact length 0 |
| `{"known": b}` | `BodyString(b)`: exact length; `IsEndStream` when empty |
| `{"stream": [...], "trailers": [...]}` | `TScriptBody = class(TBodySource)`, a port of the reference `ScriptBody`: `SizeHint` unknown, `IsEndStream` always False (like `StreamBody`). `PollFrame`: if a delay is armed, `fpPending` until it fired; next item: `delay_ms` > 0 and not yet slept → arm a `TWakeTimer`, `fpPending`; `data` → `fpData` with `BodyString` (one frame per item and per repetition of `times`, each repetition waits again); `error` → `SetBodyErrorText(message)`, `fpError` (the connection aborts, the chunked body stays unterminated); after the last item: `fpTrailers` once if `trailers` is present (built with insert semantics), then `fpEnd`. Items without delay are ready at the first poll |

### 6.6 Connection modes, graceful shutdown, upgrades (SPEC 6)

| item | implementation |
|---|---|
| `plain` | `cmPlain`; on `dsUpgrade` the slot's `Manual` → the registered handler emits `upgrade_error` "upgrade expected but low level API in use"; socket closed |
| `with_upgrades` | `cmWithUpgrades`; `Fulfill(TUpgraded)`; `conn_close` (`ok`) is emitted in `Finish`, the delivery task runs after it, so `conn_close` precedes `upgraded` |
| `without_shutdown` | `cmWithoutShutdown`; on Ok: `OnParts` → emit `conn_close`, then if a stored `on_upgrade: false` spec exists, run the upgrade task on `Parts.Transport` with `Parts.Rest` as `read_buf`, else close; on error: drop, `conn_close` (reference server: same) |
| graceful shutdown semantics (6.2) | `TH1Dispatcher.GracefulShutdown` (1.11): closes now when idle or untouched, else `connection: close` on the current response; no effect after a hand-off (`FUpgraded`) |
| upgrade task (6.3) | `TConfUpgrader = class(TRawListener)` attached to the `TUpgraded` (whose task runs on the same loop, as the reference's `tokio::spawn`; text corrected in S6, deviation S6-17): emit `upgraded` with `read_buf`; if `await_signal`: register as a latch waiter, Pending until set; `write`: non-blocking `TryWrite` until done (waits for `rdWrite` events); `read_to_eof` (default true): read until EOF, emit `upgrade_read` (`data`, `end` `eof`, or `error` + `message`); close. Errors → `upgrade_error`. The leftover is reported, not re-read |

### 6.7 Events (SPEC 7)

| event | emitted by |
|---|---|
| `conn_open` | accept hook, before the dispatcher's first `Run` |
| `request` | `TConfService.Call` |
| `request_body`, `request_body_error` | `TConfCall.Poll` (6.4 step 3) |
| `handler_done` | `TConfCall.Poll`, right before `cpReady` |
| `handler_dropped` | `TConfCall.Drop(Ex, False)`, which runs in `Finish` step 2, before `conn_close` |
| `conn_close` | `Observer.OnConnClose`: `outcome` = `OutcomeOf` (2.8), `detail` = `ErrorDescription` chain |
| `bytes_read` | `TCountingTransport` |
| `upgraded`, `upgrade_read`, `upgrade_error` | `TConfUpgradeTask` / `TConfUpgradeHandler.UpgradeFailed` |
| `control_ack`, `control_error` | `TControlTask` |

### 6.8 The worker executor (`--executor worker`)

`test_service` runs as a `TBlockingHandler` through `TOffloadCall` (`hello_world` and `unreachable`
too): SPEC 5.5 step 3 (`OnUpgrade`, a loop-thread call) in the call's first `Poll`, before it offloads;
the body with `ReadFrame` (a blocking `TryRead`, so the handler sees the trailer frame), delays
with `Sleep` on the worker (cancellation observed when it wakes), streamed bodies with `BeginStream` and
`WriteString` after each item's `Sleep`, errors with `Fail`/`AbortStream`. `handler_done` is emitted by the
worker only if its terminal call won the CAS (3.2.3), with the event lock held across the call and the
line, so no event of the loop thread comes between them; `handler_dropped` by `Drop(Ex, False)` on the loop
only if the cancel won (text corrected in S7, deviation S7-12). So each call emits exactly one of them, as SPEC 5.1 requires.

### 6.9 Running it

```sh
cd /home/jps/Code/wd-40/conformance
target/release/runner run  --server ../build/conformance/beconf cases/h1
target/release/runner run  --server '../build/conformance/beconf --executor worker' cases/h1
target/release/runner run  --server '../build/conformance/beconf --loops 4' cases/h1
target/release/runner diff --a target/release/reference-server --b ../build/conformance/beconf cases/h1   # a report, not a gate (T1)
```

The gates are `conformance/pascal-server/gate.sh` (inline) and `gate_worker.sh` (worker executor), 7.4.
`--loops N` (S8): N loops, loop 0 on the main thread; with N > 1 the listener (mio's options) is shared in
`amSharedExclusive` mode. Shared state of the tool is thread-safe: connection numbers and the reply
queue are atomic counters, `graceful_shutdown` reaches the other loops through an `lmCall` each (the
last loop to finish emits the ack), and the signal latches are under a lock, with a waiting upgrader
resumed by an `lmCall` to its own loop. `LOOPS=4 RUNS=3 conformance/pascal-server/gate.sh` is the
`--loops 4` gate.

---
## 7. Test plan and performance method

### 7.1 Test doubles

`tests/support/bearings.test.mocktransport.pas`: a port of `tokio_test::io::Builder` as a `TTransport`:

```pascal
type
  TMockTransport = class(TTransport)
  public
    function Read(const Data: RawByteString): TMockTransport;   { next read returns these bytes }
    function ReadPending: TMockTransport;                       { next read returns -EAGAIN }
    function ReadEof: TMockTransport;
    function ReadError(Errno: cint): TMockTransport;
    function Write(const Data: RawByteString): TMockTransport;  { next write must match exactly }
    function WriteLimit(N: SizeInt): TMockTransport;            { next write accepts at most N bytes }
    function WritePending: TMockTransport;
    function WriteError(Errno: cint): TMockTransport;
    function Vectored(Enabled: Boolean): TMockTransport;        { IsWriteVectored; default False }
    procedure AssertDone;                                       { every scripted action consumed }
  end;
```

Like Rust's default `poll_write_vectored`, a non-vectored mock's `WriteV` writes only the first non-empty
slice (what `write_buf_queue_disable_auto` relies on). `tests/support/bearings.test.loop.pas` drives tasks
deterministically with a fake clock (`Advance(Ms)`), so timer tests do not sleep.

### 7.2 Port of hyper io.rs's tests (`tests/unit/test_h1_io.pas`, step S3, adapted in T1)

io.rs has 10 test functions: 9 run, 1 is `#[ignore]` with a commented-out body; plus one commented-out
`write_buf_queue`. All are ported; T1 adapted the write tests to the one write path:

| hyper test (io.rs) | Pascal test | note |
|---|---|---|
| `iobuf_write_empty_slice` (`#[ignore]`) | `Test_iobuf_write_empty_slice` | ports the stated intent: `PollFlush` with nothing buffered makes no write call (mock with no writes, `AssertDone`) |
| `parse_reads_until_blocked` | same name | server bytes `GET / HTTP/1.1\r\n` + `Host: x\r\n` + `ReadPending` (the client role is not ported); asserts `Parse` is Pending and the read buffer holds both pieces |
| `read_strategy_adaptive_increments` | same name | `usize::MAX` → `High(SizeUInt)` |
| `read_strategy_adaptive_decrements` | same name | |
| `read_strategy_adaptive_stays_the_same` | same name | |
| `read_strategy_adaptive_max_fuzz` | same name | `max := (max div 2) * 3` saturating, up to `High(SizeUInt)`; power-of-two check |
| `write_buf_requires_non_empty_bufs` (`#[should_panic]`) | same name | `-Sa` build; expects `EAssertionFailed` from `Buffer` and from the queue's `Push` |
| `write_buf_flatten` | `Write_buf_small_pieces_copied` | small pieces are copied into the cursor: one write, queue empty |
| `write_buf_flatten_partially_flushed` | `Cursor_drops_written_prefix_when_full` | the written prefix stays while the block has room and is dropped when the next piece does not fit |
| `write_buf_queue_disable_auto` | `Queued_entries_non_vectored_transport` | large entries are queued; a non-vectored transport gets one slice per write |
| (commented-out) `write_buf_queue` | `Test_write_buf_queue` | vectored mock: one `writev` of the cursor and three queued entries |

Extra io tests: the `Buffer` rule (copy up to `MAX_COPY_SIZE`, queue larger entries and everything
behind a queued entry); `PipelineFlush` skips the flush while the read buffer is not empty and nothing is
queued, and writes a queued entry at once; `PollShutdown` never shuts down with bytes buffered; a partial
`writev` that ends inside a chunk prefix / data / suffix; `WriteZero`; a `qkFile` entry between memory
entries (socketpair + temp file); idle block release; read sizes from the read strategy; a head queued
behind 16 entries. `TReadBuf`: `test_rt_readbuf.pas` (2.2.1).

### 7.3 Conn-level and dispatcher-level unit tests (steps S4, S5)

- **conn.rs server tests** (`test_h1_conn.pas`): `conn_reads_request_head`,
  `conn_reads_partial_request_head`, `conn_accepts_eof_when_idle`, `conn_rejects_eof_during_partial_head`,
  `server_accepts_eof_while_busy`, `conn_reads_body_and_reports_end`, `closed_conn_cannot_read_or_write`,
  `conn_writes_chunked_body` (client-only tests are not ported).
- **dispatch.rs**: its three tests are client-side; `body_empty_chunks_ignored` is ported in server form
  (an empty data frame never reaches `WriteBody`).
- **hyper regression tests** as dispatcher tests over the mock: `h1_flush_before_yield.rs` (data,
  Pending, end within one loop iteration: the terminating chunk is flushed before `Run` returns),
  `h1_shutdown_while_buffered.rs` (the mock accepts 212 992 bytes then blocks: no `ShutdownWrite` while
  bytes are buffered), `unbuffered_stream.rs`, `ready_on_poll_stream.rs`.
- **Channel**: ports of the `chan.rs` / `incoming.rs` tests (`channel_abort`,
  `channel_abort_when_buffer_is_full`, `size_hint`, `error_queued_behind_accepted_data`,
  `trailers_follow_data_close`), `want` transitions, `ToRelease` invariant under a worker stress test.
- **State tables**: every reachable `(TReading, TWriting, TKA)` x event (head, body chunk, body end,
  response head, body frame, flush, EOF, graceful shutdown, timer) against a table written from conn.rs.
- **Expect/continue**: no 100 when the handler answers without reading; exactly one on the first read;
  none for HTTP/1.0 or an empty body.
- **Trailers**: each `WriteTrailers` branch and T1 ordering.
- **Pipelining**: 16 requests in one read → one write with `PipelineFlush`; 32 requests → a yield after 16
  iterations and the second half in the same loop iteration (run-queue budget).
- **Readiness** (`test_rt_net.pas`, real sockets): data+FIN in one segment and in two; the
  `rdReadClosed` bit makes the next read call the kernel; short `writev` keeps `rdWrite`; short `write`
  clears it.
- **Loop**: timer wheel vs a sorted list (random arm/cancel/advance); tokio rounding table; MPSC stack
  with 8 producers x 10^7 pushes; `Sleeping` + eventfd race test; F10 regression (close a connection from
  a completion that precedes its own event in the same batch); exception resume (a task raising in the
  middle of a batch; the other events of the batch are still processed).
- **Exchange**: answer in the first poll; answer from a timer; answer from a worker; cancel during each;
  `Share`/`Release` balance (heaptrc: no leak); wake after recycle is ignored.

**Differentials kept** (request acceptance, which matters for request smuggling): the parser against
httparse (`tests/unit/test_parser_diff.sh`), request-head parsing and URIs against hyper's own
`Server::parse` and `http::Uri` (`test_role_diff.sh`), the body decoder against hyper's `decode.rs`
(`test_codec_diff.sh`, `test_codec_replay`). Step T1 retired the conn-level differential harness
(`conformance/conn-diff/`, which compared write-call transcripts and event timing with hyper's) and
the response-encoding differentials (user decision 2026-10-08).

### 7.4 The 105 wire cases

| run | gate |
|---|---|
| assertion mode, inline (`gate.sh`) | `SUMMARY passed=104 failed=0 pending=1 total=105`, 5 runs in a row; the 25 extra cases (`extra/extra-cases.json`) pass |
| assertion mode, `--executor worker` (`gate_worker.sh`) | 104 passed, 5 runs, except the cases listed in `worker-exceptions.txt` (only `chunk2::pipeline_enabled`: deviation S7-1, accepted in S7 decision 14; `reference-server` fails the same assertion when its second handler is Pending at its first poll, `extra/worker-probe.json`, which `gate_worker.sh` checks in every run); the 25 extra cases pass |
| assertion mode, `--loops 4` (`LOOPS=4 RUNS=3 gate.sh`) | 104 passed, 3 runs; the 25 extra cases pass |
| diff mode vs `reference-server` | a report (`DIFF=1` in both gate scripts), not a gate (T1) |
| dumb-server control (MANIFEST.md) | unchanged: the cases still detect a broken server |

### 7.5 Fuzz and soak

- **Split fuzz** (in-process): `TMockTransport` delivers every M1 case input and every M2 corpus request
  in random-size reads with random `EAGAIN`, and accepts random partial writes; the output bytes must
  equal the unsplit run; invariants: no exception other than documented ones, pin counts back to 0,
  heaptrc reports no leaks. Thousands of seeds per CI run.
- **Differential stream fuzz** (`conformance/fuzz-diff/`, Rust): generated request streams (grammar +
  mutations of the case corpus and httparse's corpus: methods, targets, header lines, CL/TE combinations,
  chunk framing, trailers, pipelines, h2 preface) with random write splits, 0-5 ms gaps and half-closes,
  sent to the reference server and to `beconf` with the same spec; compares, per request, whether it is
  accepted or rejected (and with which status), the response status and body, and whether the
  connection stays open. Write segmentation, header order within a name group and event timing are not
  compared (T1). Failures are written as case files. Nightly: 100 000 streams.
- **Slow clients**: 10 000 connections sending a head one byte per 100 ms (incremental `PartialLen`
  parsing, header timer); CPU per byte must stay flat.
- **Soak**: 24 h of wrk (keep-alive and pipelined) plus a chaos client (partial heads, slow bodies,
  mid-response RST, idle sockets, upgrades) against a server with inline and worker routes. Pass: RSS
  flat after warm-up, open fds back to baseline, no stall-detector report, no crash.
- Debug builds for all tests: `-Ci -Cr -Co -Ct -Sa -gh -gl -dWD_DEBUG`; the conformance suite once under
  valgrind memcheck; the worker stress tests under `valgrind --tool=drd`.

### 7.6 Performance measurement and gate

Servers:

- hyper: `bench/hyper-tfb/` (from the design-phase `m3-perf-proto/hyper-tfb`, test tooling): TFB
  `frameworks/Rust/hyper/src/main.rs` with the DB routes removed, hyper pinned to rev `7f67699`, tokio
  1.53.2, one current-thread runtime per thread, `SO_REUSEPORT`, `TCP_NODELAY`, backlog 4096,
  `pipeline_flush(true)`, no timer, LTO, codegen-units 1.
- wd-40: `bench/plaintext.pas` on `TServer` with the inline service of 3.1, `PipelineFlush`, no timer,
  `amReusePort`, N loops. Response bytes equal hyper's after date normalization (`server: wd-40` has the
  length of `server: hyper`; `SERVER=hyper` makes them byte-equal); `bench/run_gate.sh` checks them with
  `cmp` (`bench/resp_bytes.py`: single, 16 pipelined, 404, `Connection: close`, HTTP/1.0) before every
  gate run and stops on a difference.
- Baseline: the raw loop prototype `bench/beproto.pas` (from the design-phase perf prototype).

Tools (decision 12): `tools/get-tools.sh` builds wrk and wrk2 at pinned commits and unpacks a pinned
valgrind package into `build/tools/`; every script defaults to those paths and nothing depends on a
session directory. `tools/cpu-burn.sh N` runs `stress-ng --cpu N` when stress-ng is on `PATH`, and
otherwise N busy processes (stress-ng is not installed here); either way they are killed when the
script exits, and a TERM, INT or HUP to the script ends it at once (the script waits with the `wait`
builtin, never on a foreground child). Forms: `cpu-burn.sh N` (until killed), `cpu-burn.sh N seconds`,
`cpu-burn.sh N -- command` (for the command's duration, with its exit status).

The gate script is `bench/run_gate.sh` (builds both servers, checks the response bytes, runs
`bench/compare.py`, records the governor, the load average before and after, VmRSS every second and
VmHWM, and fails when a cell is below 0.80).

Load: wrk (`build/tools/bin/wrk`) with TFB's headers and `pipeline.lua`:

| cell | command |
|---|---|
| c256 d1 | `wrk -t$T -c256 -d30s --latency http://127.0.0.1:8080/plaintext` |
| c1024 d1 | `wrk -t$T -c1024 -d30s --latency ...` |
| c256 d16 | `wrk -t$T -c256 -d30s -s pipeline.lua ... -- 16` |
| c1024 d16 | `wrk -t$T -c1024 -d30s -s pipeline.lua ... -- 16` |

CPU split on this machine (CPUs 0-11 = 6 P-cores with SMT, 12-15 = 4 E-cores):

- **Configuration B (gate)**: server on CPUs 0-3 (4 loops / 4 hyper threads), wrk on 4-15 with 12 threads.
  The server is the bottleneck (perf T2: both servers use 40 CPU-seconds per 10 s).
- Configuration A (reported): server 0-7, wrk 8-15 with 8 threads; client-bound at depth 1 (perf T1).
- Validity: wrk's CPU use is recorded (`/proc/stat` of the wrk CPUs); a run where wrk's CPUs are above
  90 % busy is client-bound and left out of the median (`compare.py`, decision 12); a cell with no valid
  run fails. The governor is set to `performance` when permitted (else recorded).

Method: 10 s warm-up discarded; 5 runs of 30 s per cell, alternating servers; median. Metrics:
requests/s; requests per server CPU-second (`/proc/<pid>/stat` utime+stime); p50/p99 from wrk at depth 1;
p99 and p99.9 from wrk2 at fixed rates of 50 % and 80 % of hyper's measured maximum (wrk's histogram is
unreliable when one write carries 16 requests); VmRSS mid-run and VmHWM; idle RSS with 10 000 keep-alive
connections (`bench/idle.py`); syscalls per request (`perf stat -e 'syscalls:sys_enter_*'` over 10 s).

Gate (every cell, configuration B): requests/s >= 0.80 x hyper (hard); cells below 1.00 are reported with
a profile; depth-1 p99 <= 1.25 x hyper (open question 2); idle RSS <= 2 KB per connection; RSS under load
<= hyper's. Expected syscalls per request: depth 1, one `read` + one `write` plus a share of `epoll_wait`;
depth 16, one `read` and one `write` per 16 requests.

Micro-benchmarks in CI with a +-10 % budget: `bench_role` (parse 152 ns, encode 121 ns; built with
`-O3 -CX -XX -Xs` and run with `taskset -c 2`), the dispatcher over an in-memory transport
(`bench/bench_dispatch.pas`, ns per request for depth 1 and depth 16 pipelines; budget: prototype cost +
420 ns, where the prototype cost is `rawsrv`'s per-request work over the same transport, S5-11),
`TReadBuf`/`TByteVec` operations, the exchange inline path.

---

## 8. Unit layout, deviation register, risks

### 8.1 Files under `/home/jps/Code/wd-40/src/`

The units below are listed in an order where every unit's interface `uses` only units above it, so the
graph is acyclic (`tools/compile-each-unit.sh` compiles each unit on its own and `tools/unit-graph.py`
checks the order; the directories interleave because the M2 units of `src/http1/` sit between runtime
units). Types that refer to each other are in one unit (`bearings.rt.loop`: loop + tasks; `bearings.http.exchange`:
service, call, exchange, bodies, upgrade slot, observer), which removes the cycles the feasibility judge
found in faithful (`bearings.rt.task` ↔ `bearings.rt.loop`) and perf (`bearings.http.body` ↔ `bearings.http.exchange`).

```
unit (file)                       contents                                                   interface uses
rt/bearings.rt.sys.pas                  raw syscall stubs returning -errno, constants              (none)
rt/bearings.rt.clock.pas                libc clock_gettime (vDSO): MonoNowNs, RealNowUs            (none)
rt/bearings.rt.timer.pas                TTimer, TTimerWheel                                        (none)
rt/bearings.rt.buf.pas                  TBlockPool, TBufBlock, TBytesView, TReadBuf, TByteVec,
                                  TBodyData                                                  (none)
rt/bearings.rt.sync.pas                 TMpscStack, TParker (futex), TEventCount, TSpinLock        sys
rt/bearings.rt.cpu.pas                  UsableCpus, CgroupCpuLimit, DefaultLoopCount, PinCurrentThread  sys
http1/bearings.http.date.pas            (M2)                                                       (none)
http1/bearings.http.headers.pas       * validating Add/Insert/SetValue, Try*, *Trusted             (none)
http1/bearings.http.uri.pas             (M2)                                                       (none)
http1/bearings.http1.parser.pas         (M2)                                                       (none)
http1/bearings.http1.reason.pas         (M2)                                                       (none)
http1/bearings.http1.decode.pas       * unmanaged trailer scratch; ParseTrailers -> AddTrusted     rt.buf headers
http1/bearings.http1.encode.pas       * unmanaged trailer names; EncodeTrailers T1-T3 into TByteVec rt.buf headers
http1/bearings.http1.role.pas         * reason slice; ServerEncode TByteVec overload; version check rt.buf parser headers uri
                                                                                             encode decode date reason
rt/bearings.rt.loop.pas                 TLoop, TLoopTask, TIoTask, TIoSource, TLoopMsg             sys clock sync timer buf
                                                                                             http.date
rt/bearings.rt.workers.pas              TWorkItem, TWorkerPool, TWorkerHooks                       sync
http/bearings.http.error.pas            THyperError, constructors, ErrorDescription, TConnOutcome,
                                  OutcomeOf                                                  http1.role http1.decode
rt/bearings.rt.net.pas                  TTransport, TTcpTransport, TListener, OpenListener          sys timer loop http1.encode
rt/bearings.rt.stream.pas               TUpgraded, TRawListener                                    sys loop net buf
http1/bearings.http1.io.pas             TReadStrategy, TCursor, TQueuedBuf, TBufList, TWriteBuf,
                                  TH1Io                                                      rt.buf rt.net headers encode
                                                                                             role http.error
http/bearings.http.exchange.pas         THttpService, TServiceCall, TExchange, TBodyChan,
                                  TBodySource, TChannelBody, TWakeTimer, TUpgradeSlot,
                                  TUpgradeHandler, TBlockingHandler, TOffloadCall,
                                  TExchangePool, TConnParts, TConnObserver                   rt.sys sync loop timer buf net
                                                                                             stream workers http.error
                                                                                             headers uri parser role decode
http1/bearings.http1.conn.pas           TConnState, TH1Conn, TConnScratch                          rt.buf timer loop net http1.io
                                                                                             parser role encode decode
                                                                                             headers http.error http.exchange
http1/bearings.http1.config.pas         TH1Config, ConformanceH1Config, ProductionH1Config,
                                  ValidateH1Config, ApplyH1Config                            parser role http1.conn
http1/bearings.http1.dispatch.pas       TH1Dispatcher, TOutBody, TUpgradeDelivery                  rt.sys loop buf net stream
                                                                                             http1.io http1.conn role
                                                                                             http.error headers
                                                                                             http.exchange http1.config
server/bearings.server.pas              TServerConfig, TServer; re-exports TConnObserver,
                                  TConnParts, TConnOutcome                                   rt.sys cpu timer loop net buf
                                                                                             workers http.error http.exchange
                                                                                             http1.config http1.dispatch
```

(* = M2 unit edited in S0.) Outside `src/`:

```
tests/unit/               test_h1_io, test_h1_conn, test_h1_dispatch, test_rt_timer, test_rt_loop,
                          test_rt_net, test_rt_readbuf, test_exchange, test_body_chan,
                          test_headers_validate, test_workers, test_server (S8)
tests/support/            bearings.test.mocktransport.pas (uses rt.net, http1.encode),
                          bearings.test.scriptio.pas (uses rt.sys, rt.net, http1.encode), bearings.test.loop.pas
tools/check-hot-asm.sh    the 4.4 build check
tools/get-tools.sh        wrk, wrk2, valgrind at pinned versions into build/tools/ (decision 12)
tools/cpu-burn.sh         N busy processes (stand-in for stress-ng --cpu N)
conformance/pascal-server/ beconf.lpr, beconf.spec, beconf.events, beconf.service, beconf.upgrade,
                          beconf.control, gate.sh, gate_worker.sh, worker-exceptions.txt
conformance/fuzz-diff/    Rust differential stream fuzzer (7.5)
bench/                    plaintext.pas, beproto.pas, rawsrv.pas, hyper-tfb/, run_gate.sh, compare.py,
                          resp_bytes.py, bench2.sh, idle.py, pipeline.lua
```

### 8.2 Deviation register

Every place where this design differs from hyper's structure. "Wire" says whether bytes, close timing or
outcomes can differ under hyper's default configuration.

| id | hyper | this design | reason | wire |
|---|---|---|---|---|
| DV-1 | `async`, `Future`, `Waker` | poll methods with explicit state; one task per connection is the waker | FPC 3.2.2 has no closures or async | no |
| DV-2 | generic `I`, `B`, `S` | virtual `TTransport`, `TBodySource`, `TServiceCall` | ~2 ns per virtual call; client role out of scope | no |
| DV-3 | IO wakes go through the run queue | epoll events call the driver directly; run queue for yields and other wakes | measured one read + one write per batch | ordering across connections only |
| DV-4 | `bytes::Bytes` atomic `Arc` | loop-only pin counts; workers release through the loop | no atomics per head/chunk | no |
| DV-5 | no file bodies | `BodyFile` + `qkFile` + `sendfile(2)`; entries behind a queued entry are queued too, and a queued entry is written even under `pipeline_flush` with unread bytes (decision 8, 2.2.4) | Proper `send_file` | same bytes as a `Full` body with the file content |
| DV-6 | `Instant::now()` when arming; date checked per dispatcher poll | loop clock sampled after `epoll_wait`; date checked once per iteration | one vDSO call per iteration | timers may fire earlier by at most the iteration's duration; dates differ only near a second boundary (normalized by the runner) |
| DV-7 | `HeaderMap`; `cached_headers` | `THttpHeaders` (wire order, external slices); one list per exchange | M2 decision | no (encoder groups like `HeaderMap::drain`) |
| DV-8 | header validity by type | checks in `THttpHeaders` mutators, `*Trusted` for library paths | no allocation-free newtypes in Pascal | no |
| DV-9 | TFB accept loop ends on accept error | on `EMFILE`/`ENFILE`/`ENOBUFS`/`ENOMEM` (any non-connection error): log at most once per second, take the listener out of epoll for 1 s, then add it back; a per-connection setup exception closes that socket only (decision 11, 1.3) | production server; hyper 0.14 `AddrIncoming` and axum sleep 1 s the same way | no (hyper itself does not accept) |
| DV-10 | panic aborts a tokio task | exception aborts the loop task (no completion event) | same observable result | no |
| DV-11 | buffers kept for the connection's life | blocks returned to the loop pool when idle (until T1 the logical capacities were kept so read sizes stayed hyper's; no longer) | RSS (measured 10.7 → 1.7 KB idle) | no |
| DV-12 | tokio coop budget (128 per task poll) | not ported; hyper's 16-iteration limit + 61 run-queue polls + 64 accepts per event | | ordering across connections only |
| DV-13 | Queue strategy: `on_parse_error`'s 400/414/431 head (and the automatic `100 Continue`) go into the head cursor, ahead of body bytes still queued (release build; debug builds panic in `WriteBuf::headers_mut`) | queued behind the queued entries (`qkBytes`, decision 7, 2.2.4) | the hyper behavior corrupts the previous response | yes, only when a parse error (or a 100) follows a request whose response body is still queued behind a blocked write |
| DV-14 | two write strategies (Flatten copies every body into the cursor, Queue copies none; chosen by `writev` and `pipeline_flush`) | one write path: entries up to 4 KiB copied into the cursor, larger ones queued for `writev`; the `writev` option has no effect (T1, 2.2.4) | user decision 2026-10-08 | write segmentation only; bytes and their order are the same |
| DV-15 | read sizes from `BytesMut`'s capacity rules | a pooled block that grows by pool class and is compacted; a read takes at most `max_buf_size - len` bytes (T1, 2.2.1) | user decision 2026-10-08 | `read(2)` sizes; hyper's buffer can exceed `max_buf_size` by its last reserve's slack, wd-40's cannot (a head that does not fit is always 431) |
| DV-16 | no request body timeout (`http1::Builder` has `header_read_timeout` only) | the body rate rule of 2.5 (step UB, deviation UB-1): `BodyReadTimeoutMs`, `BodyMinRate` | a slow upload must not hold a worker or a connection for ever (the user's decision of 2026-10-10) | no (off in `ConformanceH1Config`) |
| D-P1 | `pipeline_flush` default `false` | production default `true` (open question 1); conformance uses hyper's | 4x pipelined throughput | TCP segmentation of pipelined responses (production profile only) |
| D-P2 | no timer, no header timeout by default | production: timer with 30 s header timeout (open question 3) | idle connection cleanup | production profile only |

Dropped from the candidates: perf's D2 (small chunks copied into the head block in Queue mode), for the
reordering risk when queued entries exist (judge C-P8); T1 adopted it with the rule that removes that
risk (DV-14). Perf's D4 (handler in
`recv_msg`) is replaced by the call model (3.1).

### 8.3 Risks and mitigations

| # | risk | effect | mitigation |
|---|---|---|---|
| R1 | the full engine costs more than the ~420 ns budget over the prototype | below 0.80 at depth 16 | connection-level micro-benchmark at S4 (reported), dispatcher micro-benchmark and hard gate from S5; no atomics, allocation, strings or exception frames inline (asm check); profile every step; `TH1Conn` embedded (no pointer chasing) |
| R2 | edge-triggered lost wakeups | a stuck connection | tokio's readiness rules with sticky closed bits; wake-source assertion at `Run` exit; stall detector; split fuzz with random `EAGAIN`; data+FIN test |
| R3 | use-after-free between loop, workers and deferred frees | memory corruption | free after the batch (F10 test); exchange recycle only on its loop, after queued wakes; generation checks; heaptrc, valgrind, drd |
| R4 | a mistake in the order of poll operations | rare wire differences | the conn/dispatch control flow is hyper's (2.1); hyper's wire tests in assertion mode (7.4); request-acceptance differentials (7.3); differential stream fuzz (S9) |
| R5 | hyper quirks "fixed" by accident: pending upgrade surviving a non-101 response; handler not polled before EOF detection; 100 only on the first body poll; `MidMessageDetectEof` skipped with buffered bytes; header timer re-armed on idle; `PollShutdown` skipping the flush under `pipeline_flush` | wire differences | each quirk has a named unit test and a comment with the hyper line |
| R6 | read buffer wrong (bytes moved under a view, lost on compaction) | corrupt requests | `test_rt_readbuf` random operations against a model; heaptrc; the 105 cases incl. `max_buf_size*` |
| R7 | measurement noise and client limits on the hybrid CPU | wrong gate decisions | configuration B, per-CPU-second metric, 5 alternating runs, wrk CPU check; second machine if available |
| R8 | blocking code by mistake in an inline handler or on the loop | every connection of that loop stalls | inline is opt-in per route; debug watchdog logs loop iterations longer than 10 ms with the current task; `amSharedExclusive` option |
| R9 | worker pool saturation (slow database) | queued requests, latency | HTTP/1 bounds the queue by connections; `QueueLength` lets a router answer 503 inline; per-route inline/worker choice |
| R10 | cross-thread frees in FPC's heap (response header arena grown on a worker) | slower frees | arenas reach steady state; blocks and exchanges always recycled on their loop |
| R11 | header validation cost | slower responses | table-driven check; `AddTrusted` for constants; measured in S0 |
| R12 | `SO_REUSEPORT` imbalance; closing a listener resets queued connections | lower throughput, resets at shutdown | same strategy as hyper; drain-accept before close; `amSharedExclusive` option |

---
## 9. Implementation plan

Each step lists its files, the tests that must pass and the exit criteria. A step starts only when the
previous step's exit criteria hold. All earlier tests keep passing at every step (the 506 M2 tests
included).

### S0. M2 changes and interface skeletons

- Files: `src/http1/bearings.http.headers.pas`, `bearings.http1.encode.pas`, `bearings.http1.decode.pas`,
  `bearings.http1.role.pas` (5.1, 5.2, 4.4); `src/rt/bearings.rt.buf.pas` (`TByteVec` only, needed by the new
  `ServerEncode` overload); interface skeletons (types and signatures, empty bodies) of every unit in
  8.1; `tools/check-hot-asm.sh`.
- Tests: the 506 M2 tests; `test_headers_validate.pas` (each validating mutator raises on CR, LF, NUL,
  0x7F, a bad name; `Try*` return the right `THeaderCheck`; `*Trusted` do not check; T2 at unit level:
  hyper cannot hold a CR/LF/NUL value, 5.2); trailer differential test vs hyper's `encode_trailers` (T1,
  T3 inputs; retired in step T1); `bench_role`.
- Exit: all tests pass; trailer diff identical on 10 000 generated inputs; `check-hot-asm.sh` passes for
  `ServerParse*`, `ServerEncode`, `EncodeHead`, `MakeEncoder`, `SetLengthEncoder`, `SetChunkedEncoder`,
  `TEncoder.*`, `TDecoder.Decode`; parse <= 152 ns and encode <= 121 ns +10 % (`bench_role` built with
  `-O3 -CX -XX -Xs`, run pinned with `taskset -c 2`, a CPU of configuration B's server set; the budget's
  design-phase binary had no recorded flags, these are the flags both trees were measured with); every
  skeleton unit compiles on its own (proves the `uses` graph is acyclic).

### S1. Runtime core and the raw loop baseline

- Files: `src/rt/bearings.rt.{sys,clock,cpu,sync,timer,loop,net}.pas`, block pool part of `bearings.rt.buf`;
  `bench/rawsrv.pas` (on `TLoop`, `TListener` and `TTcpTransport`: the same per-request parse and encode
  work as `beproto` with `POOL=1` — `ServerParse`, the header list, `ServerEncode`, the body — and no
  connection state machine, so the +-3 % comparison measures the runtime alone; a server that copied
  fixed bytes would skip that work and fail the criterion by being faster); `bench/beproto.pas`,
  `bench/hyper-tfb/`, `bench/bench2.sh` moved from the design-phase perf prototype.
- Tests: `test_rt_timer` (sorted-list reference, tokio rounding table), `test_rt_loop` (MPSC 8x10^7,
  `Sleeping`/eventfd race, F10 regression, exception resume), `test_rt_net` (readiness rules incl.
  data+FIN, short write vs short writev, `TCP_NODELAY` inheritance read back), syscall stubs vs RTL,
  `DefaultLoopCount = nproc` and under `taskset -c 0-3` = 4.
- Exit: tests pass; `rawsrv` within +-3 % of `beproto` in all 4 cells of configuration B; an echo test
  moves 1 GB with random split sizes under valgrind without errors.

### S2. `TReadBuf` (`BytesMut` port) and `TByteVec`

(Done; step T1 replaced the `BytesMut` port and its Rust table test, 2.2.1.)

- Files: `src/rt/bearings.rt.buf.pas`; `tests/unit/test_bytesmut_rs/` (Rust generator), `test_rt_readbuf.pas`.
- Tests: generated capacity table (every `reserve_inner` branch, split views kept and dropped, idle
  release and re-acquire), `TByteVec` growth vs `Vec::reserve`.
- Exit: the Pascal table equals the Rust table for 10 000 random scripts and the hand-written ones.

### S3. `bearings.http1.io`

- Files: `src/http1/bearings.http1.io.pas`; `tests/support/bearings.test.mocktransport.pas`, `tests/unit/test_h1_io.pas`.
- Tests: the 11 io.rs tests (7.2) and the extra io tests.
- Exit: all pass; `check-hot-asm.sh` passes for `TH1Io.*`, `TReadBuf.*`, `TByteVec.*`.

### S4. Error type, exchange core, `bearings.http1.conn`

- Files: `src/http/bearings.http.error.pas`, `src/http/bearings.http.exchange.pas` (inline parts: service, call,
  exchange, body channel, `TBodyData`, `TBodySource`, `TWakeTimer`, upgrade slot), `src/http1/bearings.http1.conn.pas`,
  `bearings.http1.config.pas`; `tests/unit/test_h1_conn.pas`, `test_body_chan.pas`, `test_exchange.pas`.
- Tests: the conn.rs server tests, channel tests, state tables, expect/continue, trailers branches,
  exchange lifetime (inline only).
- Exit: all pass; heaptrc clean; `check-hot-asm.sh` passes for `TH1Conn.*`, `TBodyChan.*`,
  `TExchange.{Respond,TryRead,ReleaseRequest}`.

### S5. Dispatcher, server, first end-to-end performance gate

- Files: `src/http1/bearings.http1.dispatch.pas`, `src/server/bearings.server.pas`, `bench/plaintext.pas`,
  `tests/unit/test_h1_dispatch.pas`, `conformance/conn-diff/` (Rust harness + scripts; retired in T1).
- Tests: dispatcher tests incl. `h1_flush_before_yield`, `h1_shutdown_while_buffered`,
  `body_empty_chunks_ignored`, pipelining 16/32, wake-source assertion on in all tests; conn-diff
  harness: identical output on every hand-written script and on 10 000 generated scripts; dispatcher
  micro-benchmark.
- Exit: tests pass; **perf gate** (7.6) in configuration B: every cell >= 0.80 x hyper, idle RSS <= 2 KB
  per connection, RSS under load <= hyper's; dispatcher micro-benchmark within prototype + 420 ns per
  request at depth 16. If a cell is below 0.80, profile and fix before S6.

### H. Fixes after S5 (added 2026-10-07)

- Scope: decisions 7-13 of section 0.3 ("Decisions after S5"); the design-text corrections the S0-S5
  verifiers listed (each section named there gets corrected text, not an appended note); a Deviations log
  entry for every deviation the S0-S4 implementers reported (the log so far holds only S5's).
- Files: `tools/get-tools.sh`, `bench/run_gate.sh`, `tools/cpu-burn.sh` (fallback when `stress-ng` is
  not installed: N busy processes), plus the source and test files the decisions touch. Also written:
  `bench/resp_bytes.py` (the response bytes `run_gate.sh` compares with `cmp`) and `tools/h-mutants.py`
  (applies one mutant per decision 7-13 test to a copy of the tree and shows the test fails; the
  unmutated copy passes).
- Exit: every test named in decisions 7-13 exists, fails on a mutant of the code it covers (shown), and
  passes; `run_all.sh` passes from a clean build directory with the tools from `build/tools/` only (no
  scratchpad path anywhere in `src/`, `tests/`, `bench/`, `tools/`, `conformance/`); conn-diff hand and
  10 000 generated scripts pass under the decision 7 rule (conn-diff and `tools/h-mutants.py` were
  removed in T1); the perf gate (`bench/run_gate.sh`, 5 x 30 s)
  still has every cell >= 0.80 x hyper.

### S6. Conformance server, inline executor

- Files: `conformance/pascal-server/*` (6), `TCountingTransport`, upgrade delivery in `bearings.server`,
  `TUpgraded` (loop side, `Attach`) in `bearings.rt.stream`.
- Tests: the 105 cases. Bring-up order: `hello_world`/`unreachable` cases, `test_service` without
  upgrades, bodies and trailers, timeouts, upgrades and graceful shutdown.
- Exit: assertion mode 104/105 five runs in a row; diff mode `same=104` five runs in a row and five more
  under `stress-ng --cpu 16` (`tools/cpu-burn.sh 16` when `stress-ng` is missing, deviation S6-10; the
  loaded runs with the runner's `--settle-ms 100`, deviation S6-16). Since T1 the gate is assertion mode
  only (7.4).

### S7. Worker pool and cross-thread API

- Files: `src/rt/bearings.rt.workers.pas`; worker parts of `bearings.http.exchange` (`Share`, `Offload`,
  `TOffloadCall`, blocking `Read`/`ReadChunk`/`ReadAll`, `TChannelBody`, `BeginStream`/`Write`/`Finish`,
  cross-thread `Wake`, `FreeMsg`); `--executor worker` in `beconf`; `tests/unit/test_workers.pas`.
- Tests: park/unpark races, cancel at every point (queued, running, parked in `Read`, parked in `Write`),
  `Share`/`Release` balance under 16 threads, run under `valgrind --tool=drd`; since the S7 fix round 5
  (deviation S7-34) also the end-to-end stress `tests/unit/stress_workers.pas` (`tools/s7-stress.sh`:
  natively and under drd).
- Exit: worker-mode gates of 7.4 (assertion 104 x5; diff transcripts SAME; allowlist reviewed (the diff
  parts retired in T1); both
  with the exception for the listed `transcript` case `chunk2::pipeline_enabled`, amended in the S7 fix,
  deviation S7-1, accepted in S7 decision 14 (0.3); the inline gate stays 104/105 strict); drd clean; offload cost <= the prototype's 5.4 us per request (configuration B,
  depth 1); inline numbers of S5 unchanged.

### T1. Simplify: hyper's features, not its implementation (added 2026-10-09)

- Scope: the user decision of 2026-10-08 ("the idea is not to duplicate how Rust code works, but the
  features"; 0.3 assumption 2), items M3-1 to M3-3 of the audit
  (`build/session-save-2026-10-09/scratchpad/audit-pyexact/m3/m3-section.md`). Kept unchanged: the
  error kinds of `bearings.http.error`, the ownership debug checks, parser strictness, header validation, the
  S7 worker pool and its cross-thread API, the conn/dispatch control flow.
- M3-1, files: `conformance/conn-diff/` (deleted), `conformance/Cargo.toml` / `Cargo.lock`,
  `conformance/runner/src/{main,server}.rs` (`--settle-ms` removed), `conformance/SPEC.md`,
  `conformance/pascal-server/{gate.sh, gate_worker.sh, worker-exceptions.txt}` (assertion mode only;
  `classify_diff.py`, `worker_allowlist.py`, `worker-allowlist.txt` deleted),
  `tests/unit/test_role_diff{.pas,.sh,_rs/}` (the `Server::encode` cases removed; the parse and URI cases
  stay), `tests/unit/test_trailer_diff.{pas,sh}` and `tools/h-mutants.py` (deleted),
  `tests/unit/run_all.sh`. The reference server and the runner's diff mode stay, as a report.
- M3-2, files: `src/rt/bearings.rt.buf.pas` (`TReadBuf`, `TByteVec`, 2.2.1, 2.2.4),
  `src/http1/bearings.http1.io.pas` (`PollReadFromIo`), `tests/unit/test_rt_readbuf.pas` (rewritten),
  `tests/unit/test_bytesmut_rs/` and `test_rt_readbuf.sh` (deleted).
- M3-3, files: `src/http1/bearings.http1.io.pas` (one write path, 2.2.4), `bearings.http1.conn.pas`,
  `bearings.http1.config.pas` (no `Writev`), `conformance/pascal-server/beconf.spec.pas`, and the tests that
  pinned strategy-specific slice counts and `MaybeUnshift` boundaries (`test_h1_io`, `test_h1_conn`,
  `test_h1_dispatch`, `test_headers_validate`).
- Exit: `tests/unit/run_all.sh` passes (heaptrc 0 unfreed blocks, drd clean, asm check);
  `gate.sh` and `gate_worker.sh` pass; `tools/s7-stress.sh` passes natively and under drd;
  `tests/web/run_all.sh` passes; `test_parser_diff.sh`, `test_role_diff.sh` and `test_codec_diff.sh`
  pass; `bench/run_gate.sh` is not worse than before T1, measured back to back with the tree before T1
  under the same load, with idle memory per connection and p99 reported.

### S8. Sendfile, upgrades API, shutdown, multi-loop conformance

Status (2026-10-09): implemented, waiting for verification (deviations S8-1 to S8-9). Results:
`run_all.sh` passed (921 tests; heaptrc 0 unfreed blocks; drd 0 errors; asm check passed); `gate.sh`
104/0/1 x5, `gate_worker.sh` 103/1/1 x5 (listed `chunk2::pipeline_enabled`), `LOOPS=4 RUNS=3 gate.sh`
104/0/1 x3, extra cases 25/25 in each; `tests/web/run_all.sh` passed; `bench/run_gate.sh` wd-40 / hyper:
c256 d1 0.939, c256 d16 0.839, c1024 d1 0.952, c1024 d16 0.861.

- Files: `qkFile` path in `bearings.http1.io`, `BodyFile`, file frames in `bearings.http1.conn` (+ `TEncodedBuf.SplitData`
  in `bearings.http1.encode`); `TUpgraded.Detach` and `Taken` in `bearings.rt.stream`; the upgrade ownership fix
  (HS6-3) in `bearings.http.exchange`; `TServer.Stop` (drain-accept, grace deadline, pool shutdown in `Wait`),
  `TServer.RunUntilSignal`, `amSharedExclusive` in `bearings.server` and `bearings.rt.net`; `--loops N` in `beconf`
  (`beconf.lpr`, `.control`, `.upgrade`, `.service`, `.spec`), `LOOPS` in `gate.sh`;
  `tests/unit/test_server.pas` (in `run_all.sh`, also under heaptrc).
- Tests: sendfile (known length, between memory entries, partial `sendfile`, `EAGAIN`); upgrade
  attach/detach with leftover bytes; an `Upgraded` handler that raises without taking the stream;
  stop under load with in-flight requests (no reset beyond the documented accept-queue window, 1.11);
  `--loops 4` assertion mode.
- Exit: all pass; `--loops 4` 104/105 x3.

### S9. Fuzzing, soak, production profile

Status (2026-10-09): implemented, waiting for verification (deviations S9-1 to S9-11). Results:
- Split fuzz (`tests/unit/test_split_fuzz.pas`, in `run_all.sh`, built `-Ci -Cr -Co -Ct -Sa -gh -gl
  -dWD_DEBUG`): 123 case inputs (130 cases of `cases/h1` and `extra-cases.json`, 11 skipped: S9-5) in
  both profiles (the case's spec, `ProductionH1Config`) and 20 parser-corpus entries per seed. 2 000
  seeds (`build/m3/S9/fuzz/`): 572 246 runs, 2 778 891 read pieces, 1 389 041 `EAGAIN` reads, 0
  differences or failures; 1 752 late-error equivalents (S9-1) and 375 split HTTP/2 prefaces (S9-2)
  accepted; every one of the 106 942 corpus entries once (20 000 random, seed 1; `run_all.sh` now adds
  httparse's test inputs when its source is in the cargo registry: 107 615): 213 884 runs, 0 differences, 4 850 S9-1, 1 S9-2; heaptrc 0 unfreed blocks; 217 s
  for both. A mutant (`IsCompleteFast` scanning from `PrevLen` instead of `PrevLen - 3`) gives 157
  differences in 20 seeds.
- Differential stream fuzz (`conformance/fuzz-diff/`, beconf debug profile vs reference-server, 8
  server-spec profiles, 8 jobs on CPUs 8-15). Exit run of 100 000 streams (seed 1, 400 s, after the
  verification fix round; `build/m3/S9/fuzz-diff/run-seed1-100000/`, log
  `build/m3/S9/fuzz-diff-100k-r3.out`): 90 167 same; 9 827 documented deviations (S6-15 9 006,
  S9-3 493, S9-1 314, S9-2 13, S9-11 1); 6 timing (every wd-40 run's outcome was also given by a
  hyper run); 0 differences; 0 crashes. History: the first exit run (before the fix round,
  `fuzz-diff-100k.out`) had 7 differences, all of the S9-1 shape (a probe sending the first, `Nam`,
  `e`, `:`, ` valu`, 10 connections each with 0 and 20 ms between writes, got no response from
  either server: hyper also waits when its first read holds only `Nam`). The verifier found the S9-1
  recogniser too loose (it did not check for an end of head) and the timing rule too weak (one
  matching pair of runs was enough); after tightening both (S9-4), a second run
  (`fuzz-diff-100k-r2.out`) reported 986 differences: 966 were S6-15 cases where hyper dropped held
  200 (and 100) responses, not only the 400/101 the old recogniser named; 18 were S9-2 and S9-1
  limit cases (400 vs 431) that the stricter timing rule no longer absorbed; 1 was the 100 Continue
  of S9-11. The recognisers were rewritten to those exact shapes (S6-15: wd-40's extra responses
  must be the `handler_done` statuses of the events plus the outcome's automatic error) and the
  third run above is the result. Mutant check: a beconf whose parser returns Partial for an invalid
  header name (scratch copy, `build/m3/S9/mutant/`) gives 265 differences in 2 000 streams. A
  routine run (10 000 streams, seed 7): 9 019 same, 981 documented, 0 timing, 0 differences.
- Slow clients (`bench/slowclient.sh`, `soak_app` release build, 4 loops on CPUs 8-11, client on
  12-15; `build/m3/S9/slow/`): 10 000 connections, a 250-byte head one byte per 100 ms: all 10 000
  answered 200; server CPU per byte 2.7 us in the first 2 s window (connections still opening), then
  4.11-4.21 us in every 4 s window to the end (first third 3.80 us, last third 4.13 us, ratio 1.09):
  flat. 10 000 connections whose head never ends: every one closed by the server 30.0-30.1 s after its
  connect, none with a response byte. Server fds back to 15 at the end.
- Soak (`bench/soak.sh`, 2 h, `build/m3/S9/soak/`; samples every 10 s in
  `build/m3/S9/soak/samples.csv`): `soak_app` (`-Sa -dWD_DEBUG -dWD_STALL`, 4 loops, 8 workers),
  wrk keep-alive 106 307 138 requests (533 GB read), wrk pipelined 439 067 136 requests, chaos client
  63 835 actions, 0 errors, no non-2xx response, no socket error. RSS: 6 996 KiB at start, 12 428 KiB
  at the end of the 30 min warm-up, 12 576 KiB at the end (after warm-up min 12 428, max 12 576);
  least-squares slope over the last 90 minutes 83 KiB/h (criterion, fixed before the run: below
  1 024 KiB/h). Open fds: 15 before the load, at most 123 under load, 15 at the end (45 s after the
  load stopped). Stall reports 0; server exit status 0 on SIGTERM.
- `run_all.sh` (DRD_RUNS=1): passed (`build/m3/S9/run_all.out`, again after the fix round `run_all-r2.out`: 927 unit tests, heaptrc 0 unfreed blocks in every suite and in the split fuzz, drd 0 errors, the stress passed, asm check passed; the split fuzz in it: 2 000 seeds 572 246 runs and the 107 615 corpus entries once, 0 differences, 184 s + 24 s; after the fix round, with the end-of-head check in `LateErrorEquivalent`: the same counts, 1 860 + 4 795 S9-1 and 374 + 2 S9-2 accepted, 0 differences, 179 s + 23 s); `RUNS=3 gate.sh`: 104/0/1 x3, extra cases 25/25 (`build/m3/S9/gate.out`). The S9 source changes outside tests are inside `{$ifdef WD_STALL}` only, so the perf gate was not run. `src/web` not touched.

- Files: `conformance/fuzz-diff/` (`src/main.rs`, `src/gen.rs`, `run.sh`; workspace member),
  `conformance/pascal-server/beconf.events.pas` (`EventHook`), `tests/unit/test_split_fuzz.pas`,
  `tests/unit/test_split_fuzz_cases.py`, `tests/unit/run_all.sh`, `bench/soak.sh`, `soak_app.pas`,
  `soak_chaos.py`, `soak_mix.lua`, `soak_pipe.lua`, `soak_analyze.py`, `slowclient.sh`, `slowclient.py`;
  the stall detector (S9-7) in `src/http1/bearings.http1.dispatch.pas` and `src/server/bearings.server.pas`.
- Tests: split fuzz (thousands of seeds per CI run), differential stream fuzz (100 000 streams once for
  the exit, 10 000 in routine runs; user decision 2026-10-09, S9-6), slow-client test, 2 h soak (user
  decision 2026-10-09, S9-6); the split fuzz and the soak also run with
  `ProductionH1Config` (the production profile).
- Exit: no fuzz difference or crash; soak: RSS and fd count flat after warm-up, no stall report.

### UB. Body rate rule, stall detector (added 2026-10-10, the user's decisions on S9-8)

Paired with M5 step UB (request bodies buffered on the loop, M5 9.8), which fixes the starvation S9's
soak found (48 slow uploads held all 8 workers: the worker routes fell from 577 000 to 240 requests in
5 s).

- Files: `bearings.http1.config` (`BodyReadTimeoutMs`, `BodyMinRate`; defaults and validation, 2.5),
  `bearings.http1.conn` (`BodyWaitExpired`, `BodyProgress`, `StartBodyClock`, `SetBodyReadTimeout`, the
  `BodyTimer`), `bearings.http.exchange` (`TExchangeAttachment`, `TExchange.Attachment`, detached at
  `Recycle` and `BeginRequest`; `BodyErrorIsTimeout`), the stall detector in `bearings.http1.dispatch`
  (`StallClientWait`, `StallReason`) and `bearings.server`; `bench/soak_chaos.py` (no cap on pauses or on
  concurrent slow bodies; new actions `large_body`, `stalled_body`, `no_read`), `bench/ub_starve.sh`,
  `bench/ub_starve.py`.
- Tests: `test_h1_conn`'s `TTestConnBodyRate` (11: off by default, one wait, a frame restarts the
  wait, time not reading not counted, the rate part below and above the minimum, the end cancels the
  timer, a new body starts a new clock, the rate's clock starts at the first byte, silence before the
  first byte hits the wait limit, config fields, defaults, validation); `test_h1_dispatch`'s
  `TTestDispatchStall` (6, including a body chunk waiting for its receiver); through the framework M5's
  `TTestWireBodyRate` (4).
- Exit: `tests/unit/run_all.sh` (DRD_RUNS=1) passes; `RUNS=3 gate.sh` 104/0/1; `bench/run_gate.sh`
  >= 0.80 per cell; a 15-minute soak with the uncapped chaos client: no stall report, RSS and fds
  flat.

Status (2026-10-10): implemented, waiting for verification (Deviations log UB). Results (`build/UB/`):
`tests/unit/run_all.sh` (DRD_RUNS=1) passed (`TTestConnBodyRate` 9, `TTestDispatchStall` 5); `RUNS=3
gate.sh` 104/0/1 x3, extras 25/0; `bench/run_gate.sh` 0.959 (c256 d1), 0.853 (c256 d16), 0.986 (c1024
d1), 0.886 (c1024 d16) x hyper; starvation probe (`bench/ub_starve.sh`): worker routes 0 requests in
5 s with 48 slow uploads before, 1.007 x the baseline after; uploads below 1 KiB/s or stalled: 408 at
30.0-30.9 s. Soak, 15 min (`WARMUP=300 bench/soak.sh 900`, chaos client without caps): stall reports
0, server exit 0, chaos 7 395 actions 0 errors (`no_read` 279: responses held by the client 61-70 s,
not reported; `stalled_body` 270: 408 or close at 30 s; `large_body` 256), wrk keep-alive 13.3 M and
pipelined 55.0 M requests without a non-2xx; fds 15 before, at most 143, 15 at the end; RSS 6 960 KiB
at start, 20 972-23 348 KiB while wrk ran (300-900 s), 17 660 KiB at the end. `soak_analyze.py`
reports FAIL on its slope criterion (|slope| -6 299 KiB/h over all load samples: RSS fell when wrk
stopped while the chaos client finished its long actions; over 300-900 s +4 597 KiB/h, a noisy band
of 2.4 MiB): 10 minutes are too short for the 1 MiB/h bound the 2-hour soak was written for.

### S10. Final performance report

Status (2026-10-10): measured, report written (`docs/design/m3-perf-report.md`; raw outputs in
`build/m3/S10/`); not yet verified. Every gate of 7.6 met. Configuration B (`bench/run_gate.sh`, 5 x 30 s,
governor `powersave`, could not be set to `performance` without root) wd-40 / hyper: c256 d1 0.959, c256
d16 0.854, c1024 d1 0.984, c1024 d16 0.880. Configuration A (server CPUs 0-7, wrk 8-15): d16 0.870 and
0.897; d1 has no valid run (wrk 99.8-99.9 % busy in every run, client-bound as 7.6 expects). Depth-1 p99
(wrk at maximum load) 1.01 / 0.98 x hyper; wrk2 (rebuilt: `tools/get-tools.sh` now emits wrk2's Lua
bytecode as C source, which removes the start-up Lua PANIC) at 50 % and 80 % of hyper's maximum: 1.00-1.01
x hyper, except c256 at 80 % where both servers are noisy (median p99 wd-40 3.10 ms, hyper 11.92 ms).
Idle keep-alive connection (10 000): 1 305 B (hyper 10 703 B). VmHWM under load 5 324 KB (hyper 22 556
KB). System calls per request (`strace -c`, because `perf_event_paranoid` is 4 and `ptrace_scope` 1:
new `bench/syscalls.sh`): equal to hyper's, depth 1 1.0004 read + 1.0002 write + 0.0166 `epoll_wait`,
depth 16 0.0625 + 0.0625 + 0.0010. Micro-benchmarks: parse 138 ns, encode 83 ns (budgets 152 / 121),
`bench_dispatch` depth 16 583.3 ns <= prototype 367.2 + 420 ns. Web framework (`bench/web_gate.sh`):
inline 0.918 / 0.753 / 0.920 / 0.756, worker 0.960 / 0.978, every cell within the user's budgets. The
depth-16 cells below 1.00 have the same instruction count per request as hyper within 2.5 % (callgrind:
5 456 vs 5 324) and 17 % more CPU time per request. The p99, idle and RSS targets (decision 2) are for
the user to confirm. New measurement helpers: `bench/p99.sh`, `bench/idle_rss.sh`, `bench/syscalls.sh`;
`bench/run_gate.sh` takes the CPU split from the environment.

- Files: `docs/design/m3-perf-report.md` (numbers, profiles, syscall counts).
- Tests: the full matrix of 7.6 in configurations B and A; wrk2 p99 at 50 % and 80 % of hyper's max;
  idle 10 000-connection RSS; syscalls per request; the micro-benchmarks.
- Exit: every gate of 7.6 met (0.80 hard per cell; p99 and RSS targets as confirmed by the user).

---

## Appendix A. hyper to Pascal map

| hyper | Pascal |
|---|---|
| `Buffered::new` / `parse` / `poll_read_from_io` / `read_mem` | `TH1Io.Init` / `Parse` / `PollReadFromIo` / `ReadMem` |
| `Buffered::poll_flush` / `poll_flush_flattened` / `poll_shutdown` / `into_inner` | `TH1Io.PollFlush` / `PollFlushCursor` / `PollShutdown` / `IntoInner` |
| `ReadStrategy::{with_max,next,max,record}` | `TReadStrategy.InitWithMax` / `Next` / `Max` / `Record_` |
| `WriteBuf::{buffer,can_buffer,headers_mut,advance,chunks_vectored}`, `Cursor::{maybe_unshift,reset}` | `TWriteBuf` / `TCursor` same names (one write path, 2.2.4) |
| `BytesMut::{reserve,split_to,advance,freeze}` | `TReadBuf.Reserve` / `SplitTo` / `Advance` / `Freeze` (a pooled block, not a port: 2.2.1) |
| `Conn::poll_read_head` / `on_read_head_error` / `poll_read_body` | `TH1Conn.PollReadHead` / `OnReadHeadError` / `PollReadBody` |
| `Conn::poll_read_keep_alive` / `mid_message_detect_eof` / `force_io_read` | same names |
| `Conn::maybe_notify` / `try_keep_alive` / `wants_read_again` | same names |
| `Conn::write_head` / `encode_head` / `fix_keep_alive` / `enforce_version` | same names |
| `Conn::write_body` / `write_trailers` / `write_body_and_end` / `end_body` | same names |
| `Conn::on_parse_error` / `poll_drain_or_close_read` / `disable_keep_alive` / `take_error` | same names |
| `State::{close,close_read,close_write,try_keep_alive,idle,busy,is_idle,prepare_upgrade}` | `TConnState` methods |
| `Dispatcher::{poll_catch,poll_inner,poll_loop,poll_read,poll_read_head,poll_write,poll_flush}` | `TH1Dispatcher` same names |
| `Dispatcher::{close,can_write_again,is_done,disable_keep_alive}` | `Close_`, `CanWriteAgain`, `IsDone`, `GracefulShutdown` |
| `Server::{poll_msg,recv_msg,poll_ready,should_poll}` | `PollMsg`, `RecvMsg`, `InFlight = nil`, `InFlight <> nil` |
| `SenderDropGuard` / `OptGuard` | `Finish` step 2 / `ClearBodyRx` |
| `Service::call` / the service future | `THttpService.Call` / `TServiceCall.Poll` + `Drop` |
| `chan::Sender::{poll_ready,try_send_data,try_send_trailers,send_error}` | `TBodyChan.PollReady` / `TrySendData` / `TrySendTrailers` / `SendError` |
| `chan::Receiver::poll_next`, `Incoming::poll_frame` | `TExchange.TryRead` (loop) / `Read`, `ReadChunk` (worker) |
| `upgrade::on` / `Pending::fulfill` / `Pending::manual` / `Upgraded` | `Ex.OnUpgrade` / `TUpgradeSlot.Fulfill` / `Manual` / `TUpgraded` |
| `Builder::serve_connection` / `with_upgrades` / `without_shutdown` / `into_parts` | `ApplyH1Config` + `TH1Dispatcher` with `cmPlain` / `cmWithUpgrades` / `cmWithoutShutdown` / `TConnParts` |
| `Time::check` | `ValidateH1Config` |
| `task::yield_now` | `TLoopTask.Wake` on itself while running, return Pending |
| `date::update` / `date::extend` | `TLoop.Date.Check` per iteration / `TEncodeContext.Date` |

---

## Deviations log

Entries are added by the implementation steps. Each says what differs from the sections above and
why.

Step H (2026-10-07) added the S0-S4 entries from the implementers' reports. Where H corrected the
section text to match the code, the entry says so ("text corrected in H"); the entry stays as the
record of where the code first differed.

### S0 (M2 changes and interface skeletons)

| id | where | what | reason |
|---|---|---|---|
| S0-1 | 2.10, 8.1 | `TConnObserver`, `TConnParts` are declared in `bearings.http.exchange`; `TConnOutcome`, `OutcomeOf` in `bearings.http.error`; `bearings.server` re-exports the three names (text corrected in H) | declaring them in `bearings.server` is an interface cycle with `bearings.http1.dispatch` (FPC: "Circular unit reference between bearings.http1.dispatch and bearings.server") |
| S0-2 | 2.5, 8.1 | `bearings.http1.config` uses `bearings.http1.conn` (text corrected in H) | `ApplyH1Config` takes a `TH1Conn` |
| S0-3 | 8.1 | the list order did not satisfy "uses only point up the list" (`bearings.rt.loop` uses `bearings.http.date`, `bearings.rt.net` uses `bearings.http1.encode`, `bearings.http.error` uses `bearings.http1.role` / `decode`); the graph itself is acyclic (text corrected in H: the list is now in a valid order) | listing error |
| S0-4 | 5.1 | `*Trusted` do not assert in `-Sa` builds; the assertion is in `ServerEncode` and `EncodeTrailers` (text corrected in H) | S0's test list requires "`*Trusted` do not check" and M2 tests store invalid names with `AddTrusted`, and all unit tests build with `-Sa` |
| S0-5 | 5.2 | the trailer generator is in `tests/unit/test_role_diff_rs` (with `test_trailer_diff.pas` / `.sh`), not `test_codec_diff_rs` (text corrected in H) | that crate already holds hyper's `role.rs` and `encode.rs`, and the declared trailer names come from `role.rs` |
| S0-6 | 4.4, `ServerEncode` / `EncodeTrailers` | the M2 `TBytes` overloads stay; without a connection scratch they use a per-thread default trailer name set (encoder) and trailer buffer (decoder). Known limits (S0 verifier): a copied `TEncoder` shares the default set, a record moved to another thread keeps the first thread's pointer, threads other than the main one leak the default set at exit. The M3 path always passes the connection's `TConnScratch` | the 506 M2 tests run unchanged |
| S0-7 | 4.4, `ServerParseHeapSlots` | dynamic array replaced by `GetMem` / `FreeMem` | the asm check found an implicit frame; the path runs on every request when `MaxHeaders > 100` |
| S0-8 | interfaces of 2.x, 5.1 | additions the design implies: `SetValueTrusted`, string overloads of `AddTrusted` / `InsertTrusted`, `TBodyLength` (in `bearings.http1.conn`), `Run` / `Abort` overrides on `TListener` and `TUpgraded`, the dispatcher's private helpers; `EncodeTrailers` is a `TEncoder` method | it needs the encoder's declared names |
| S0-9 | M2 tests | `test_role_extra` / `test_role_diff` set `ReasonP` / `ReasonLen` from a `TReasonPhrase`; `test_codec_extra` stores `'e f'` and `'g@'` with `AddTrusted` (a twin test checks that `Add` rejects them); the M2 diff scripts get `-Fu src/rt` and `OUT_DIR`. No assertion was weakened | the S0 interface changes |
| S0-10 | 8.1, 9 S0 | not created in S0: `tests/support/bearings.test.loop.pas`, the `conformance/pascal-server` units (no interface in the design; their own steps); no Makefile: `tests/unit/run_all.sh` is the unit-test target | nothing to compile against |
| S0-11 | 7.6, 9 S0 | the S0 parse/encode budget is measured with `-O3 -CX -XX -Xs` and `taskset -c 2` (text corrected in H) | the design-phase binary is stripped and its flags were not recorded |
| S0-12 | 2.2.4, `SinkReserve` (found by the S0 verifier) | the head buffer reserves one computed upper bound where hyper reserves `30 + n * AVERAGE_HEADER_SIZE` and grows through `extend`; the logical capacity of the head vector can differ from hyper's (example: 8192 holding 8000 bytes plus a 100-byte head doubles here, not in hyper). Bytes on the wire are the same; later `maybe_unshift` decisions can differ | one reserve per head; no change in S0-H |

### S1 (runtime core, raw loop baseline)

| id | where | what | reason |
|---|---|---|---|
| S1-1 | 9 S1 | `rawsrv` does `beproto`'s per-request parse and encode work on `TLoop`, without a state machine (text corrected in H) | otherwise the +-3 % comparison with `beproto` measures parse and encode, not the runtime |
| S1-2 | 1.4, `TTcpTransport` | no constructor; `NewTcpTransport(Src)` creates it | an FPC constructor always gets an implicit exception frame, and the 4.4 check covers `TTcpTransport.*` |
| S1-3 | 1.2 | `bearings.rt.cpu` ports num_cpus 1.17.0 `linux.rs` (the process's own cgroup through `/proc/self/cgroup` and `/proc/self/mountinfo`), not the literal `/sys/fs/cgroup/cpu.max` (text corrected in H) | the two requirements conflicted; `cpu.max` at the root is wrong for a process in a child cgroup |
| S1-4 | 1.4, `ReadyFromEpoll` | follows mio 1.2.4 more closely than the 1.4 listing: `EPOLLPRI` counts as readable, an event that is exactly `EPOLLERR` sets `rdWriteClosed` | mio's `is_readable` / `is_write_closed` |
| S1-5 | 1.5, 1.6, 1.10 | `Run` holds one `try/except` for many iterations and is re-entered only after an exception (same semantics as one per iteration); inbox messages are drained after the event batch, not at the eventfd's position in it; the sleep timeout is computed from a fresh clock read; `lmWakeExchange` / `lmFreeExchange` go through `LoopMsgHandlers`; added `Create(Index)`, `Start`, `RequestStop`, `StopNow`, `WaitFor`, `NextConnId` and statistics counters | one `setjmp` for the loop's life; the rest are the minimum the tests and `bearings.server` need |
| S1-6 | 4.3, `TBlockPool.Trim` | "cold" = blocks no `Take` needed since the previous trim; the loop trims after 1 s idle, so pooled blocks are freed after 2 s idle | the design did not define cold |
| S1-7 | 1.3, `TListener.Create` | extra `Events` parameter | `amSharedExclusive` passes `EPOLLEXCLUSIVE` |
| S1-8 | 9 S1, tests | the syscall-stub and CPU-count tests are in `test_rt_sys.pas`; `tests/support/bearings.test.loop.pas` was not written | the design named no file |
| S1-9 | 7.5, valgrind runs | valgrind sees nothing inside FPC's own heap; `test_rt_echo` is built with `cmem` and `-dWD_DEBUG` (recycled pool blocks filled with 0xDD). S6 memcheck and S7 drd runs need the same | a planted use-after-free gave 0 errors with FPC's heap and 1 with `cmem` |

### S2 (`TReadBuf`, `TByteVec`)

| id | where | what | reason |
|---|---|---|---|
| S2-1 | 2.2.1 | **No longer needed since T1** (the `BytesMut` port and its table test are gone, 2.2.1). the "once unique, a reserve that fits sets `Cap := Len + Additional`" consequence is unreachable through hyper's operations (text corrected in H); `TReadBuf.SplitOff` (bytes `split_off`, unused by hyper) was added so the table test reaches that branch | the port follows bytes; only the text was wrong |
| S2-2 | 2.2.1 | **No longer needed since T1** (these routines were removed with the `BytesMut` port). added `InitWithCapacity`, `VecCapacity`, `Done`, `SplitOff`, and the out-of-line `ReserveInner`, `Materialize`, `GrowBlock` (the inline `Reserve` keeps the fast path) | tests and the inline fast path |
| S2-3 | 2.2.1, 2.2.3 | **No longer needed since T1** (no logical state is kept while idle; `Reserve` takes a block when there is none). after `ReleaseIdle`, `Reserve(N)` with `N > 0` takes a block back even when the logical room is there; `PollReadFromIo` calls `Reserve(next)` also when `Block = nil` (hyper calls `reserve` only when `remaining_mut < next`) | the block is given back while idle (4.3); the logical state does not change |
| S2-4 | 2.2.1, `Freeze` | with an empty remainder it returns a view without a block; Rust's empty `Bytes` keeps the allocation | memory only, nothing on the wire |
| S2-5 | 2.2.1, `SplitTo` / `SplitOff` | **No longer needed since T1** (`SplitTo` on a buffer without a block returns an empty view; `SplitOff` is gone). on a buffer without a block (only with length 0) they take a heap block | the signatures have no pool parameter; hyper never does this |
| S2-6 | 2.2.1 verification | **No longer needed since T1** (the table test is gone). the table compares more columns than `(len, capacity, offset)` (allocation capacity, live allocations, checksums, view count); the checksums are sampled (all bytes up to 4 KiB, else the first and last 2 KiB); the Pascal side compares the whole buffer around every moving `Reserve` | full hashing made the Rust side quadratic (85 s) |

### S3 (`bearings.http1.io`)

| id | where | what | reason |
|---|---|---|---|
| S3-1 | M2 `bearings.http1.role`, 2.2.3 | new field `TParsedRequestHead.HeadSplit`: set when the parse error came after role.rs:225 (`split_to`), so `TH1Io.Parse` drops the head bytes then and keeps them for earlier errors | with `pipeline_flush`, whether the read buffer is empty decides whether the error response is flushed |
| S3-2 | 9 S3/S4 | S4 pieces written in S3: `NewParse`, `NewIncomplete`, `NewTooLarge`, `NewIo` in `bearings.http.error`; the `TBodyData` constructors and `ReleaseBody` in `bearings.rt.buf` | S3 code calls them |
| S3-3 | 9 S3/S8 | the `qkFile` (sendfile) path of `bearings.http1.io` was written in S3 | S3's own extra tests require a `qkFile` entry between memory entries |
| S3-4 | 2.2.3, 2.2.4 | API additions: `TQueuedBuf.TrailersPos`, `TBufList.ItemsBlock`, `Push(..., Pool)`, `TWriteBuf.Init`, `TH1Io.HeadersBuf` / `Buffer` / `PollFlushQueue` / `ReleaseIdle` / `Done`, `QueuedEncoded` / `QueuedTrailers` / `QueuedFile`, `IO_ERRNO_WRITE_ZERO = -1`, `SENDFILE_MAX_CHUNK` | hyper names and needs of the port (a partially written trailer section needs a position; WriteZero has no OS errno) |
| S3-5 | 2.2.4, `TBufList.Push` | **Changed in T1:** the ring holds 32 entries; `Push` raises only when it is full; `CanBuffer` keeps callers at 16. a 17th queued entry raises `EH1Panic` (H-14: a 17th entry from `Push`; the decision 7 head has a slot of its own) | hyper's queue is unbounded, but its `can_buffer` check keeps the dispatcher at 16 |
| S3-6 | 2.2.4 | **No longer needed since T1** (one write path; the copy reserves once per entry). kept from hyper on purpose: the Flatten copy appends one segment at a time (the cursor grows like hyper's); a queued trailer section is 3 `writev` slices (hyper's chain of three buffers) | same capacities and slice counts as hyper |
| S3-7 | 7.1, `TMockTransport` | follows tokio_test: a write takes bytes from consecutive expected writes (reads skipped), a read whose next action is a write returns `EAGAIN`; it logs every read length (`ReadLens`) | the design text said "the next write must match exactly", which tokio_test does not do |

### S4 (error type, exchange core, `bearings.http1.conn`)

| id | where | what | reason |
|---|---|---|---|
| S4-1 | 2.8, `bearings.http.error` | `IsUser` is true for `hekBodyWriteAborted` | hyper's body-write-aborted is `Kind::User(..)`, and the reference server tests `is_user` before `is_body_write_aborted`, so the outcome is `user` |
| S4-2 | 2.3, 3.2, 3.3 | additions: `TH1Conn.Loop`, `TConnState.HasTimer`, `TConnScratch.ErrHeaders` (the automatic 400/414/431 list), `TH1Conn.DecodeFrame`; `TBodyChan` receiver side, wake target, two "waker registered" flags; `TExchange.ReqTrailers`, `BeginRequest`, `FillHead`, `LinkUpgrade`, `Recycle`; `TWakeTimer` target and generation; `TUpgradeSlot.Upgraded` / `Deliver` | needs of the port and the tests |
| S4-3 | 2.4.5 | the body channel wakes the receiver as chan.rs does (a wake only to a registered waker, which it consumes); inline both wakers are the connection task (text corrected in H) | hyper's self-wakes re-poll the connection |
| S4-4 | 3.4, 4.2, `BodyCopy` | the copy is in a pool block owned by the `TBodyData`, not an exchange buffer (text corrected in H) | a queued body can outlive its request when the exchange is reused (Queue strategy) |
| S4-5 | 3.2.3 rule 6 | `TExchange.Cancel` does not call `TServiceCall.Drop`; the dispatcher does, once (text corrected in H, decision 10) | the exchange has no reference to its call |
| S4-6 | 3.1, `CompleteCall` | a call that returns `cpReady` without a terminal call is a service failure, text "handler returned no response" | the design forbids it; hyper cannot express it |
| S4-7 | 2.7 | upgrade slots are created per upgrade request, not pooled (H: no pooling, reference counted, decision 9) | upgrades are rare |
| S4-8 | 2.8, `ErrorDescription` | returns the reference server's full chain (description, then ": " and each cause) | SPEC 7.2 `detail` |
| S4-9 | code comments | line references point at the real conn.rs lines; several in the design are off by a few lines (the `test_h1_conn` comments are still off by about 26 lines, S4 verifier) | correctness of references |
| S4-10 | 9 S4/S7/S8 | deferred: `bkFile` in `WriteBody` / `WriteBodyAndEnd` (S8); the locked shared-channel paths, `Share` / `Release` and answers from workers (S7) | step order |

### S5 (dispatcher, server, first performance gate)

| id | where | what | reason |
|---|---|---|---|
| S5-1 | 3.3, `TBodyChan.CloseReceiver` (S4 code) | Dropping the receiver no longer releases an item it never took; the item (and the pin on its read-buffer block) is released when the sender is closed too (`ReleaseItemIfUnowned`). `test_body_chan` `Close_receiver_releases_pins` now asserts this (previously it asserted the old behavior) | hyper chan.rs:218-227: `Drop for Receiver` only clears `receiver_open`; the item stays in the shared state until the `Sender` drops. The pin decides `BytesMut::reserve`'s branch for the drain's read, so read capacities differed from hyper (found by the conn-diff harness, 3 of 10 000 generated scripts) |
| S5-2 | 2.4.3, `PollRead` | When the receiver is closed, `PollDrainOrCloseRead` runs before the sender is dropped | hyper's taken `body` sender lives until the end of its block, after `poll_drain_or_close_read` (follows from S5-1) |
| S5-3 | hyper quirk kept (replaced in step H by decision 7: H-1) | A parse error while the previous response's body is still queued (Queue strategy, write blocked) writes the 400 head into the head cursor, so it goes out between that response's head and its body. Release builds do this exactly like hyper 1.12.0's release build. `-Sa` builds stop at `EncodeHead`'s `Assert(CanWriteHead)`, which corresponds to hyper's `debug_assert!` (`Conn::encode_head`, `WriteBuf::headers_mut`) | Faithful to hyper's release behavior; the conn-diff Pascal runner is built without `-Sa` to compare release with release. This is a hyper bug (response corruption); fixing it is a decision for the user |
| S5-4 | 2.4.4, 2.7 | The `cmWithUpgrades` hand-off is implemented: `TUpgraded.CreateFrom` (the transport, the leftover view, the readiness source moved and the epoll entry re-pointed with `EPOLL_CTL_MOD`), `Leftover`, `ConsumeLeftover`, `Close`, and the queued `TUpgradeDelivery` task. `Attach`, `TryRead`, `TryWrite` and `Detach` stay S6/S8 | `Finish` needs a hand-off that does not leak the socket |
| S5-5 | 1.11, `TServer.Stop` | A first `Stop` exists (drain-accept and close the listener, `GracefulShutdown` on every connection, exit when none is left or at `GraceMs`, then `Abort` the rest). `amSharedExclusive` raises in `Start`, `Workers` is accepted and ignored, signals are not handled | Tests and benchmarks need a clean stop; the full behavior and its tests are S8 (and S7 for workers) |
| S5-6 | 2.10 | `TConnObserver.OnParts` default releases the rest view and closes and frees the transport | the design says "default: close"; the S0 skeleton was empty (a leak) |
| S5-7 | 2.4.5 | The wake-source check counts as armed: a self-wake (`Notified`/`Queued`), a transport read or write that returned Pending in this `Run` (new `TH1Io.PendingReads`/`PendingWrites` counters), the header read timer, a service call or response body source that returned Pending in this `Run`, a body channel waiting for its receiver. Calls and sources are trusted to arrange `Ex.Wake`. `TLoopTask` gained a read-only `Notified` property | the dispatcher cannot see inside a call; the check catches a Pending with none of the dispatcher's own sources |
| S5-8 | 4.3, 3.2 | The connection takes its exchange from the loop pool before a head is parsed (the head is parsed into the exchange's header list) and gives it back, with its blocks, at the end of every `Run` that leaves it idle | the parse needs the list; an idle connection holds no exchange (1 208 B per idle connection measured) |
| S5-9 | 1.3 | After an accept the dispatcher is not woken explicitly | `EPOLL_CTL_ADD` reports the socket's current readiness (at least `EPOLLOUT`), which runs the dispatcher once |
| S5-10 | 8.1 uses graph | `bearings.http1.dispatch` also uses `bearings.rt.sys`, `bearings.rt.net`, `bearings.rt.stream` | `TUpgraded` hand-off and the transport type; the graph stays acyclic (checked with `tools/compile-each-unit.sh`) |
| S5-11 | 7.6 micro-benchmark | "Prototype cost" is measured: `bench/bench_dispatch.pas` runs `bench/rawsrv.pas`'s per-request work and `TH1Dispatcher.Run` over the same in-memory transport | the design names the budget, not the baseline program |
| S5-12 | performance changes in earlier steps' code | `BodyEmpty` copies a typed constant; `QueuedEncoded` stores every field instead of `Default()`; `THttpHeaders.AddTrusted` checks arena and entry capacity once; `TeIsTrailers` skips the list search when no 2-byte name exists; `TExchange.BeginRequest` resets only `Kind`/`Cause` of the body error | the first end-to-end gate run had one depth-16 cell below 0.80 x hyper; these removed `FillChar` calls and duplicate capacity checks found with callgrind (perf is not usable on this machine: `perf_event_paranoid = 4`). All M2/S0-S4 tests and differential suites still pass |

### H (fixes after S5)

| id | where | what | reason |
|---|---|---|---|
| H-1 | S5-3, 2.2.4, `TH1Conn.EncodeHead` | S5-3 is replaced: the error head written while entries are queued goes behind them (`TH1Io.BufferAfterQueue`, `qkBytes`); `EncodeHead`'s assertion accepts this caller (`ErrorHeadPending`), so `-Sa` builds no longer stop; conn-diff accepts the difference under the decision 7 rule (`compare.py` third argument, hyper `--flatten`). Seed 1: hand `rule7=1` (parse_error_behind_queued_body), generated `rule7=2` (gen-1462, gen-4438); after H-14 the hand corpus has 122 scripts and `rule7=3` (plus parse_error_behind_15_queued_entries, parse_error_behind_16_queued_entries) | decision 7 |
| H-2 | 1.3, `TListener` | the 1 s pause applies to every `accept4` error except `EAGAIN`, `EINTR`, `ECONNABORTED`, `ECONNRESET`, `ECONNREFUSED` (decision 11 names `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`); `TAcceptEvent` takes `var Fd` so the listener knows whether the handler owns the socket when it raises; if re-registering fails, the pause repeats | axum and hyper 0.14 sleep on every non-connection error; a persistent error would otherwise spin like `EMFILE` |
| H-3 | 2.2.4, `TH1Conn.PollReadBody` | the decision 7 rule is also applied to the automatic `100 Continue` (`ContinueAfterQueue`). Through the dispatcher it is not reachable: the call is polled only when `CanWriteHead` (queue empty), and `Call` must not read the body; tested at conn level (`Continue_queued_behind_body`) | the same hyper ordering bug (headers_buf while queued); without it a `-Sa` build would stop at `HeadersMut` if the API ever allowed it |
| H-4 | 2.2.4, `TWriteBuf.CanBuffer`, `TH1Io.CanBuffer` | **Changed in T1:** one `CanBuffer` rule for the one write path (2.2.4). Flatten `CanBuffer` also requires fewer than 16 queued entries, and `pipeline_flush` no longer makes `TH1Io.CanBuffer` true when the ring is full | with decision 8 entries can queue behind a file in Flatten mode; a 17th would raise `EH1Panic` (S3-5). hyper's Flatten queue is always empty, so nothing changes for it |
| H-5 | decision 8 test | the S8 test named in decision 8 (3 or more pipelined requests whose first response has a file body all complete) stays in S8: `TH1Conn.WriteBody` does not take `bkFile` yet (S4-10). H tests the rule at io level: `Pipeline_flush_writes_queued_file` (requests 2 and 3 buffered, file queued: written, the next head can be buffered) and `Flatten_queues_behind_file` | file bodies at conn level are S8 |
| H-6 | 7.3, `Unbuffered_stream` | the hot-polling check: at most 2 write calls may come before the readiness edge (`MaxBlockedRun <= 2`); `TScriptIo.StrictWriteBlock` (opt-in) makes such calls Pending without consuming the script and counts them. hyper's `UnbufferedStream` fails the 5th `poll_write` counted by `poll_cnt`, which is reset to 0 when the sleep has completed, before the write is accepted. After the first write of the stream (no reset, `poll_cnt` = 1) that allows the scripted Pending (`wp`) plus 2 blocked calls; after every later write, `wp` plus 3. The bound of 2 equals hyper's for the first write and is one stricter for later ones (text corrected in H after the H verifier; before, it said the accepted write always counts). The dispatcher makes 1-2 (hyper too: `poll_write` flushes and `poll_loop` flushes again). conn-diff keeps the old behavior (the Rust mock consumes the next action) | decision 13 asked for a check that can fail; zero would be stricter than hyper |
| H-7 | 5.1, `bearings.http.headers` | `-Sa` builds count the validating mutator calls (`ValidatingMutatorCalls`, declared under `{$IFOPT C+}`); `Library_callers_use_trusted_paths` asserts the count does not change (`ParseTrailers`; the helpers `AddChunked` and `SetContentLengthIfMissing` were later removed as unused); the connection's callers (`FixKeepAlive`, `EnforceVersion`: `connection: keep-alive` / `close`) are counted in `test_h1_conn` `Http10_keep_alive_fix` and `Http11_close_when_keep_alive_disabled` (added after the H verifier) | valid bytes cannot tell the two paths apart (the library callers write constants and parser output) |
| H-8 | 5.2, differential generators | trailer cases get a 9th field (an optional `content-length` line from its own RNG; illegal values give `ERR User(UnexpectedHeader)`, 274 of 10 000 cases with seed 1); the role differential appends `n_parse / 20` requests with 90-330 header lines and `max_headers` in {101, 128, 150, 200, 256, 300, None} (own RNG, so the earlier cases are unchanged) | decision 13: the ERR format and `MaxHeaders > 100` had no differential coverage |
| H-9 | 2.2.1 / 4.4, `EncodeHeadHeapFlags` | `AllocMem` / `FreeMem` instead of a dynamic array; if `EncodeHead` raises (only a `-Sa` assertion) the block leaks | no implicit exception frame (decision 13) |
| H-10 | 4.3, `TH1Conn.ReleaseIdleScratch` | the idle connection frees the trailer name set and the decoder's trailer bytes completely (logical capacity not kept) | both are per request in hyper (a fresh `HeaderMap` / `BytesMut` per message), so no capacity is observable |
| H-11 | `TServerLoop.OnAccept` | releases the connection's objects and re-raises to the listener, which counts and logs; a transport not yet given to the dispatcher is freed there (S5 verifier: it leaked). Test (added after the H verifier): `test_h1_dispatch` `Server_setup_failure_closes_connection_and_continues` (the observer raises in `OnAccept`, then in `WrapTransport`: both connections are closed without a response, the next two are served, `SetupErrors` = 2; the heaptrc build shows the transport freed) | decision 11 |
| H-12 | 7.6, tools | `tools/get-tools.sh` builds wrk with the system OpenSSL (`WITH_OPENSSL=/usr`) instead of wrk's bundled OpenSSL 1.1.1i; valgrind is the Ubuntu 26.04 package `1:3.26.0-0ubuntu1`, checked by sha256, unpacked without installing | the benchmarks use plain HTTP; no root |
| H-13 | decision 7 conn-diff rule, 7.3, `compare.py` | **No longer needed since T1** (conn-diff is retired). the rule is applied to scripts where hyper's Queue and Flatten bytes are the same bytes in a different order (equal as multisets); there the Pascal bytes must be hyper's Flatten bytes, and keeping hyper's Queue bytes fails. Every other script must equal hyper's transcript exactly. Decision 7's text ("when hyper's Queue-strategy byte stream differs from its Flatten-strategy byte stream") is broader | the two strategies also differ legitimately: in generated script gen-259 (seed 1) hyper's Flatten strategy buffers the next response while the first is unflushed (5 153 bytes before EOF) and its Queue strategy cannot (52 bytes); the Pascal dispatcher runs the Queue strategy and matches hyper's Queue transcript line for line. The literal rule would fail that script, and a rule that only looked at differing transcripts would accept the old S5-3 behavior |
| H-14 | decision 7, 2.2.4, 4.3, `TBufList`, `TH1Io.BufferAfterQueue` (found by the H verifier) | **No longer needed since T1** (no head-entry slot and no `BufsCnt` adjustment; a head queued behind the entries is an ordinary entry, the ring has room for it). the error head (or `100 Continue`) queued behind the entries is pushed with `TBufList.PushHeadEntry` into a slot of its own: the ring has 32 slots (16 entries from `Push`, 1 head entry; a power of two keeps the index a mask; 32 x 200 B = 6 400 B, still one 8 KiB pool block). `TBufList.BufsCnt` = `Count - HeadEntries`, and `TWriteBuf.CanBuffer` / `TH1Io.CanBuffer` use it. A second head entry raises `EH1Panic` | H-1 pushed the head with `Push`: with 16 entries queued (a chunked response of 15 data frames plus the terminator, blocked write, then a request body end and a malformed head) the 17th push raised `EH1Panic`, the connection was aborted, no 400 and no `conn_close` (verifier's conn-diff script q16b; hyper Queue writes 229 bytes, outcome parse). Counting the head in `BufsCnt` was also wrong: with 15 entries plus the head, hyper's `can_buffer` is true (the head is in its cursor) and wd-40's was false, so wd-40 made one more `poll_flush` write call than hyper in that poll (hand script `parse_error_behind_15_queued_entries`). Hand scripts added: `parse_error_behind_{15,16}_queued_entries` (Queue: rule7) and `..._flatten` (identical); tests `Head_entry_behind_16_queued_entries` (test_h1_io), `Parse_error_behind_16_queued_entries` (test_h1_dispatch) |


### S6 (conformance server, inline executor)

| id | where | what | reason |
|---|---|---|---|
| S6-1 | 2.7, 6.2, `TTransport.Wrapped` / `DisownWrapped` (bearings.rt.net), `TUpgraded.CreateFrom` | a transport that wraps another one returns it from `Wrapped` (default nil). `CreateFrom` frees an owned wrapper (after `DisownWrapped`) and keeps the transport inside, and it moves the readiness source (fd, readiness bits, epoll entry) when the innermost transport is the `TTcpTransport` reading `FromSrc`, also through a wrapper it does not own. Test: `test_h1_dispatch` `Server_upgrade_through_wrapping_observer` (a mutant without the walk through wrappers fails it: the dispatcher's free closed the socket) | 6.2 says the hand-off unwraps `TCountingTransport` but gave no API; the S5 verifier's latent finding (with a wrapper nothing moved and `TIoTask.Destroy` closed the upgraded socket) |
| S6-2 | 2.10, `TConnParts.Src` (text corrected in S6) | new field: the connection task's readiness source; `Finish` sets it. A `without_shutdown` receiver that keeps the socket moves it with `TUpgraded.CreateFrom(Loop, Parts.Transport, Parts.Rest, Parts.Src, True)` before `OnParts` returns. Test: `Server_without_shutdown_parts_keep_socket` | the connection task owns the fd and its epoll entry and is freed after the event batch |
| S6-3 | 2.10, 6.2, `TConnObserver.OnStart` (text corrected in S6) | new hook, called by `TServerLoop.OnAccept` after the connection is registered and before its first `Run`; the conformance server calls `GracefulShutdown` there for `graceful_shutdown_on_accept`. Test: `Server_observer_on_start` | 6.2 asks for `GracefulShutdown` "right after the dispatcher is created, before its first `Run`"; the observer had no hook between those two points |
| S6-4 | 6, `TServer.StartCallerRunsLoop0` / `RunLoop0` | `Start` without a thread for loop 0; the caller registers its tasks (stdin) and runs loop 0 | 6: "one loop on the main thread"; `Start` always started a thread per loop |
| S6-5 | 2.7, `TUpgradeSlot.Deliver` / `Manual` / `Cancel` | the handler is cleared before it is called (the slot is a oneshot). `test_exchange` `Upgrade_handlers` asserted that a `Cancel` after `Manual` reached the handler a second time; it now asserts that it reaches nobody, and checks the `Cancel` text on a second slot | a handler may free itself in its callback; hyper's `Pending::manual` and `drop(Pending)` consume the one sender, so a handler gets one result |
| S6-6 | 2.7, 3.7, `TUpgraded` loop side | `Attach(L)` wakes the task once; every socket event and every `Wake` call `L.Readable`, then `L.Writable` if the stream is still open and attached; `TryRead` returns the leftover first (hyper `Rewind`), then reads the socket; `TryRead` / `TryWrite` follow the transport's readiness rules (no syscall while the bit is clear). `Detach` stays S8 | the design gives the methods, not the callback order |
| S6-7 | 6.1 (text corrected in S6) | `beconf.spec` has its own JSON parser instead of `fpjson` | `fpjson` drops `\u0000` and converts string code pages (M5 probe F0.8); SPEC 2 byte strings need the exact code points |
| S6-8 | 6 command line, 6.1 `graceful_shutdown` | `--executor worker` (S7) and `--loops N` with N > 1 (S8) exit 2 with a message. `graceful_shutdown` walks every loop's connection list synchronously on loop 0, which is correct only with one loop; S8 must use the `lmCall` per loop of 6.1 | step order |
| S6-9 | 6.4, 6.6, `TConfUpgradeHandler.Armed`, `TConfCall` | a handler registered at SPEC 5.5 step 3 reports nothing until step 8 arms it (the reference spawns the task that awaits `OnUpgrade` only at step 8, so a handler that fails earlier drops it silently); an armed handler's failure is emitted from a queued task (after `conn_close`, as the reference's spawned task). `on_upgrade` on a request without an upgrade emits `upgrade_error` "no upgrade available" from a queued task. Checked against the reference by `conformance/pascal-server/extra/extra-cases.json` (23 cases at first, 25 after the S6 fixes; diff mode, messages included) | the reference server's behavior |
| S6-10 | 9 S6 exit, 7.4 | `stress-ng` is not installed; the loaded runs use `tools/cpu-burn.sh 16` (16 busy shell loops, decision 12) | no root, many dependencies |
| S6-11 | 9 S6 exit criterion "diff `same=104` five more [runs] under `stress-ng --cpu 16`", 7.4 | **No longer needed since T1** (the diff-mode gate is retired; assertion mode only). **infeasible as written** (harness race, not a beconf difference). Gate run (`build/S6-impl/gate2.out`): beconf vs reference under load gave same=101/97/102/101/103; all 16 DIFF entries are a trailing `conn_close` that one side reported and the other did not, with identical transcripts (`classify_diff.py`); reference vs reference under the same load gave same=104/103/103/104/104 (2 DIFF of the same kind), and an earlier run of the 13 via-proxy cases gave 11 such DIFF in 130 reference-vs-reference case runs. Cause: these cases do not wait for that event; at the end the runner closes its sockets, writes `exit`, and takes its event snapshot as soon as the process exited, while its stdout reader thread is detached and not joined (`runner/src/server.rs` `stop`); strace showed beconf writing `conn_close` 0.4 ms before it read `exit` and the event still missing from the snapshot. In via-proxy cases the proxy's upstream FIN can also arrive after `exit` (seen for the reference). beconf exits faster after `exit` than the reference (whose stdin goes through a blocking-pool thread), so it lost the race more often (12 of the 16; the reference side 4). `gate.sh` reports the strict result and the classification (exit 3 = everything else passes and every loaded DIFF is a trailing `conn_close`). Resolved by S6-16 (the S6 verifier showed that joining the reader alone is not enough) | evidence above |
| S6-12 | finding, no code change; 0.3 open question 1, `ProductionH1Config` | hyper 1.12.0 with `pipeline_flush(true)` drops the 101 (or CONNECT 2xx) response when bytes follow the upgrade request in the read buffer: `poll_flush` skips the flush while the read buffer is not empty, `is_done` is true, and `into_inner` drops the write buffer. wd-40 does the same (probe: the `upgrades` and `upgrades_new` cases with `pipeline_flush: true`: the reference and beconf both time out waiting for the 101, diff SAME). `ProductionH1Config` has `PipelineFlush = True` and `cmWithUpgrades`, so production would lose the 101 when a client sends data right after the upgrade request. The S6 unit tests use `PipelineFlush = False` | needed a decision; decided after the S6 verification (0.3 decision 14) and implemented as S6-15 |
| S6-13 | 7.5, `conformance/pascal-server/build.sh` | default profile `debug` (`-O2 -gl -Ci -Cr -Co -Ct -Sa -dWD_DEBUG`, the wake-source check on), `PROFILE=release` for `-O2 -gl`; no `-gh`: beconf leaves with `exit_group` (SPEC `exit`), so heaptrc never reports | 7.5 lists `-gh` |
| S6-14 | 9 S6 files | also written: `conformance/pascal-server/{build.sh, gate.sh, classify_diff.py, extra/extra-cases.json}`; `TCountingTransport` is in `beconf.service`; the three `TTestDispatchServer` tests of S6-1..S6-3 in `test_h1_dispatch` | gate, evidence beyond the 105 cases |
| S6-15 | 0.3 decision 14, 2.4.2 `PollInner`, `TH1Io.HoldsPipelinedWrite` / `PollFlushHeld` | **Partly obsolete since T1:** the flush at the end of a connection stays; the conn-diff `rule14` count is gone with conn-diff. once `IsDone` holds, a write buffer that `PollFlush` left unwritten because of `pipeline_flush` (read buffer not empty, no file entry) is flushed before the upgrade hand-off, the `without_shutdown` parts or the shutdown; `Pending` waits for the writable edge, an error is `NewBodyWrite` as in `Dispatcher::poll_flush`. Tests (`test_h1_dispatch`): `Pipeline_flush_upgrade_101_before_hand_off`, `Pipeline_flush_upgrade_101_write_pending`, `Pipeline_flush_keep_alive_off_pipelined`, `Pipeline_flush_parts_response_written`, `Server_upgrade_pipeline_flush_keeps_101`; `No_pipeline_flush_unchanged_at_end` checks that hyper's defaults are untouched. A mutant with the flush removed fails the first five. conn-diff gets a decision 14 rule (`conformance/conn-diff/scripts/compare.py` `rule14`, hyper's third run `--no-pipeline-flush` in `run.sh`): such a script must equal hyper's transcript with only flush write lines inserted before hyper's `shutdown`/`close` (or, when that write fails on a scripted write action, without the shutdown and with result `io`), and the bytes must equal (after a failed write: be a prefix of) hyper's complete byte stream without `pipeline_flush`; 1908 of the 10 000 generated scripts (seed 1) are such scripts, 0 of the hand-written ones. Corrupting one byte of the last non-empty write in each of the 1741 of them that have one makes every one of them fail the rule (the other 167 write only `write 0`) With `pipeline_flush: true`, the cases `upgrades_new` and `http_connect_new` now pass against beconf in assertion mode; the reference server still fails them (diff mode reports them as different, by design) | S6-12: hyper 1.12.0 drops these bytes (`into_inner`, io.rs:270) or shuts down without them (io.rs:337-339 -> 279); production (`ProductionH1Config`: `PipelineFlush`, `cmWithUpgrades`) would lose 101 responses. Decision 14 |
| S6-16 | 9 S6 exit criterion 3, `conformance/runner/src/server.rs` `stop`, `runner/src/main.rs` (M1 harness) | **Partly obsolete since T1:** (a) stays; the `--settle-ms` option and its use in the gates are removed. (a) `stop` joins the stdout reader thread after the server exited, so the final event snapshot holds every line the server wrote (always on; it only adds events a server wrote before it exited). (b) New option `--settle-ms N` (default 0, M1 behavior): `stop` waits N ms after the client sockets are closed and before it writes `exit`. `gate.sh` uses `--settle-ms 100` for the loaded diff runs and the loaded reference-vs-reference baseline; the unloaded assertion and diff runs use the default (0). Both servers get the same runner, so the comparison stays symmetric. `conformance/SPEC.md` 1 and 3.5 describe both | S6 verifier: with only (a), 21 trailing-`conn_close` DIFFs in 5 loaded runs (the client's or the proxy's FIN reaches the server after `exit`); with (a) + a 100 ms wait, `same=104` in 5 of 5 loaded runs; reference vs reference under the same load also lost the event without the wait. Changing the M1 harness is the user's call: (b) is opt-in, so every M1 command line behaves as before. Gate after the S6 fixes (`build/S6-fix1/gate-debug.out`, load 0.27 before, 18.5 at the end of the loaded runs): beconf vs reference under `cpu-burn.sh 16` with `--settle-ms 100`: `same=104` in 5 of 5 runs, extra cases 25/25; reference vs reference under the same load: 104, 104, 104, 103, 104, the one DIFF not a `conn_close` (`max_buf_size_split_header_boundary`: the runner's write after the server closed returned `error` in one run and `ok` in the other) |
| S6-17 | 6.3, 6.6 (text corrected in S6) | `TConfService.Call` allocates one `TConfCall` per call (freed by its `Drop`), not a pooled one; the upgrade task is `TConfUpgrader`, a `TRawListener` attached to the `TUpgraded`, not a `TConfUpgradeTask = class(TLoopTask)` | test tooling: one call object per request does not matter for conformance; the listener runs on the `TUpgraded`'s own task, which already owns the socket's readiness (S6-1, S6-6), so a second task would only forward events |


### S7 (worker pool and cross-thread API)

| id | where | what | reason |
|---|---|---|---|
| S7-1 | 9 S7 exit "worker-mode gates of 7.4 (assertion 104 x5; diff transcripts SAME)", 7.4 | **infeasible as written for one case.** `chunk2::pipeline_enabled` (`pipeline_flush: true`, two pipelined requests) fails under `--executor worker` in every run: the first `read_once` gets only the first response, the second gets the second (assertion 103/105, diff `same=103 different=1`, 5 runs each, `conformance/pascal-server/gate_worker.sh`). Both responses can go out in one write only if the second handler answers in its first poll; a worker handler is Pending at its first poll, and with the read buffer empty after the second head `poll_flush` (io.rs:279) writes the first response alone. The reference server does the same when its second handler is Pending: `conformance/pascal-server/extra/worker-probe.json` (the case with `delay_ms` 1 or 50 on the second reply) fails the same wire assertion on reference-server (`passed=0 failed=2`) and is SAME against `beconf --executor worker` and inline `beconf`. The case is listed in `worker-allowlist.txt` with kind `transcript`. The other 103 cases pass and are SAME (events included) in all 5 runs. **Decision (S7 fix, under the user's delegation; the S7 verifier confirmed the analysis; accepted in S7 decision 14, 0.3, 2026-10-08):** 7.4 rows 3 and 4 and the 9 S7 exit are amended: a case listed as `transcript` may fail in assertion mode and differ in diff mode when `reference-server` fails the same assertion with a handler that is Pending at its first poll (`gate_worker.sh` checks the probe in every run and prints that the row as first written is not met); `gate_worker.sh` exits 0 under the amended rows (it exited 3). Smallest change: the exception names one case and needs the reference's own failure as evidence; every other case keeps the strict rows. The user may still overturn it (then S7's worker gate is not met and cannot be under any executor whose handlers are Pending at their first poll). Gate after the S7 fix (`build/S7-fix2/gate_worker.out`, after S7-22, debug profile, CPUs 0-11, load 1.23 before, 0.40 after): assertion runs 1-5 `passed=103 failed=1` (only `chunk2::pipeline_enabled`), diff runs 1-5 `same=103 different=1` (the same case, listed), extra cases `same=27`, probe on reference-server `passed=0 failed=2`, probe diff `same=2`; exit 0 under the amended rows. The extra cases were also SAME in 15 more worker runs and 3 inline runs; inline: assertion 104 x2, diff `same=104` x2 (`build/S7-fix2/conf/more`). Under CPU overload (8 `test_workers` processes on the same 4 CPUs as both servers and the runner) the extra cases differ in 1-6 cases per run under both executors (worker 6 of 6 runs, inline 5 of 6), always only by a `conn_close` event that one server's list has and the other's does not: the runner's event collection at the end of a case races with the close. That is a property of the M1 runner under overload, not of the worker executor; the gate runs on an idle machine | the case tests the inline timing of hyper's test service, not a property a worker executor can have |
| S7-2 | 3.2.3 rules 4 and 6, `TExchange.CompleteShared` / `CancelShared` | on a shared exchange, call completion and `Cancel` close the request-body receiver for the handler but keep the head view and the chunk the handler holds pinned until the handler calls `ReleaseRequest` or its next body call hands the chunk back, or until the recycle. 3.2.3 rule 6 says `Cancel` releases the request | pins are loop-thread counters (4.2): unpinning while a worker may still read the head or the chunk would let the loop reuse the block under the reader. The read-buffer capacities can then differ from inline mode (6.8); no case of the 105 or of the extras differed **Changed by S7 decision 15 (S7 fix round 4, S7-27):** call completion no longer closes the receiver of a shared exchange (the request lives until the handler's `ReleaseRequest` or last `Release`); the cancel still closes it as described here, and now also unparks a parked reader and makes its read raise `EClientGone` |
| S7-3 | 3.3 `TBodyChan` | `ToRelease2`: a second hand-back slot (between two loop-side releases a worker can hand back two views: the chunk it held when the slot was filled and the one it took); the loop also releases them when a cross-thread wake reaches it (`SyncShared`). In shared mode `PollNext` registers the parked worker (`ParkingReceiver` / `ReceiverParks`) instead of the receiver waker, and the wakes a call finds under `Lock` run after `Lock.Release` (`DeferWake`, `DeferUnpark`) | the design names one slot and "park on `Chan.Parker`" without the registration; `Ex.Wake` posts to the inbox and must not run under the spin lock |
| S7-4 | 3.2.2 interface additions | `ReadFrame` (a `TryRead` that parks instead of returning `brPending`; worker only), `ReleaseTransport` (the transport's reference, 3.2.3 rule 4; the dispatcher's `ReleaseExchange` calls it), `Execute` (`TExchange = class(TWorkItem)`: the exchange is its own work item, no allocation per offload), read-only `Shared`, `RefCount`, `Offloaded` | `ReadChunk` skips the trailer frame, which the conformance worker must report (S7-12); the dispatcher needs one call for "give back or let the last reference recycle" |
| S7-5 | 3.4, 3.6 `TChannelBody` | a FIFO ring of `TBodyData` under a `TSpinLock`; `Write` / `TryWrite` copy the bytes into a heap block (`BodyHeap`), `WriteString` keeps a reference (no copy); a frame is accepted while the queue is empty or stays within `HighWater`; `BeginStream` uses the exchange's own channel (created on first use, reused per request, freed with the exchange). New rule: when a `Release` leaves only the transport's reference and the stream was not finished, the stream ends (`AutoFinish`: `fpEnd`, no trailers), like a dropped `Sender`; since the S7 fix the stream is ended before the reference goes (S7-16). Corrected in the S7 fix round 7 (S7-43, S7-44): the last producer is the last holder, the call in flight included, the decision is the holder decrement that reaches 0, and on an unshared exchange the call's completion ends the stream. Producers waiting for room wait on a `TEventCount` (S7-19); `Finish` claims the end before it copies the trailers (S7-20) | the design gives the bound, not the structure; without the rule a handler that returns without `Finish` would leave the response open forever |
| S7-6 | 3.5 `TWorkerPool` | additions: `TrySubmit`, `Saturated` (QueueLimit check), `Alive`, `ThreadCount`, `Executed`, `SpinNs`, `CurrentWorkerIndex`, `EWorkerPoolStopped`. Spin-then-park: when the queue is empty one worker at a time watches it for `SpinNs` (default 20 us) before it parks; while it spins `Submit` wakes nobody. `Shutdown` refuses new items, finishes the queued ones, waits up to `WaitMs`; `Destroy` leaks the pool if a worker is still running | the spin saves the futex wake and the wake-up latency per item when items arrive less than 20 us apart: offload cost (S7-15, c256 d1) 2.75 us with the spin, 7.61 us with `WORKER_SPIN_NS=0` (3 runs of 10 s, `build/S7-impl/offload-spin0`), above the 5.4 us bound; the spinning CPU is counted in both numbers |
| S7-7 | 1.7 `TParker` (text corrected in S7) | three states (0 empty, 1 notified, 2 parked); `Unpark` makes the `futex_wake` call only when a thread is parked | an unpark of a running worker costs one exchange and no system call |
| S7-8 | 7.5 "the worker stress tests under `valgrind --tool=drd`" | builds with `-dWD_DRD` (with `cmem` since S7-22) give drd the happens-before edges of the futex parker, the spin lock, the MPSC stack, the exchange's CAS / reference count and the pool's thread exit (`HappensBefore` / `HappensAfter` = drd.h `ANNOTATE_HAPPENS_BEFORE` / `AFTER` client requests, bearings.rt.sync); racy-by-design word reads and writes go through `AtomicLoad` / `AtomicStore` (not inlined in those builds), and `tools/drd.supp` suppresses reports whose top frame is one of these primitives or an FPC RTL internal (reference counts, the heap's cross-thread free lists). FPC threads detach themselves when they end (cthreads `CEndThread`), so `WaitForThreadTerminate` gives drd no edge; the pool's `FAlive` decrement is annotated. `run_all.sh` runs the drd build 3 times (`WD_ITER=20`) and requires 0 errors; `tools/s7-mutants.py` shows the run finds a removed lock (`drd-channel-push-unlocked`, `drd-channel-poll-frame-unlocked`). S7 fix: `TEventCount` is annotated like `TParker` (suppression `wd-event-count`); `TLoop.ThreadId` goes through `AtomicLoadThreadId` / `AtomicStoreThreadId` (S7-18); `TExchange.RefCount` is an `AtomicLoad` | drd understands pthread mutexes and condition variables, not futexes or lock-prefixed instructions |
| S7-9 | 1.6, `TLoop` | `Sleeping := 0` after `epoll_wait` is an `AtomicStore`; `TLoop.Create` sets `ThreadId` to the creating thread (until `Run` sets the loop thread); new `ProcessInbox` (dispatches the inbox on the calling thread, which takes the loop thread's place) | `TExchange` compares `ThreadId` to tell loop-thread calls; tests drive loops on the test thread; `TServer.Destroy` must recycle the exchanges workers released after the loop threads exited |
| S7-10 | 1.11, `TServer` | `Start` creates the pool (`Workers >= 0`; 0 = `Min(32, DefaultLoopCount + 4)`) before the services, so a factory can read `TServer.Workers`. New config fields `WorkerHooks` (not owned) and `WorkerWaitMs` (default 30 000). `Destroy`, after the loop threads exited: aborts the connections still open (a parked worker is woken and sees the cancel), shuts the pool down, runs every loop's `ProcessInbox`, then frees the loops; if a worker is still running after `WorkerWaitMs` the loops and pools are not freed. **Extended in the S7 fix round 5 (S7-35):** the connections are aborted also without a pool, and before the loops are freed `Destroy` processes their inboxes until every exchange is back in its loop's pool (new `TExchangePool.Outstanding`: taken and not given back), at most `WorkerWaitMs` more; a reference `Share` gave to another thread than the pool's (an SSE producer, 3.5) is released into a live loop. If one is still held after the wait, the loops and pools are not freed (a leak, reported on stderr, instead of a use after free). Contract: every reference `Share` handed out is released; `TServer.Free` waits up to `WorkerWaitMs` for it. **Corrected in the S7 fix round 6 (S7-37):** the exchange is back in its pool once its `FreeMsg` was handled, while the releasing thread can still be inside `TLoop.Post` (after the push it reads `Sleeping` and may write the eventfd), so round 5's "released into a live loop" did not hold; `Destroy` now also waits until no thread is inside `Post` (`TLoop.Posting`) | a worker or another holder may still post to a loop; freeing it under them would be a use-after-free |
| S7-11 | 3.2.3 rule 2, `TExchange.Share` / `Offload` | `Share` raises when the exchange is not from its loop's pool (`Loop.Exchanges`; a dispatcher with a private pool cannot share). `Offload` raises `EWorkerPoolStopped` when the pool is shut down (the reference goes back; the exception aborts the connection task, 1.10) | the last `Release` recycles into the loop's pool, which must outlive the connection |
| S7-12 | 6.8, `beconf.service` (text corrected in S7) | `--executor worker`: `TConfWorkerCall` (a `TOffloadCall` per call, reference-counted by the loop's `Drop` and the worker's `Run`); `hello_world` and `unreachable` also run on the worker; SPEC 5.5 step 3 runs in the first `Poll` on the loop; the body is read with `ReadFrame`; `handler_done` is emitted under the event lock held across the terminal call (`LockEvents`, beconf.events); a `no upgrade available` error found by the worker is emitted by the loop after `cpReady` | `OnUpgrade` is a loop-thread call (3.7); without the lock a `conn_close` of the loop could come between the CAS and `handler_done` |
| S7-13 | 3.4 `BodyCopy` | on a shared exchange called off the loop thread the copy goes to a heap block | the loop's block pool is a loop-thread structure |
| S7-14 | 9 S7 files | also written: `conformance/pascal-server/{gate_worker.sh, worker_allowlist.py, worker-allowlist.txt, extra/worker-probe.json}`, `tools/{drd.supp, s7-mutants.py}`, `bench/run_offload.sh`; `bench/plaintext.pas` `OFFLOAD=1` (`WORKERS`, `WORKER_SPIN_NS`); `run_all.sh` runs `test_workers` (plain, heaptrc, drd). S7 fix: `tools/check-hot-asm.sh --s7` (the `run_all.sh` default); `run_all.sh` makes its output directory absolute (with a relative `OUT_DIR` the drd runs, which `cd` into `$OUT/drd`, could not open their logs and failed) | gate and evidence |
| S7-15 | 9 S7 exit "offload cost <= 5.4 us per request", 0.2 | method (`bench/run_offload.sh`): `plaintext` inline against `plaintext OFFLOAD=1` (every request answered by a `TBlockingHandler` on the default pool, 8 workers with 4 loops), both with 4 loops pinned to CPUs 0-3 with their workers, wrk on 4-15, depth 1, c256 and c1024, `compare.py` (10 s warm-up, 5 alternating runs of 30 s, median); cost = 1e6 / offload req per server CPU-second - 1e6 / inline req per server CPU-second. Result (2026-10-07, `build/S7-impl/offload`): c256 d1 2.75 us (6.18 vs 8.93 us per request), c1024 d1 3.19 us (6.43 vs 9.62). After the S7 fix (`build/S7-fix2/offload`, 2026-10-08, load 0.51 before, 10.75 after; CPUs 12-15 97-98 % idle after): c256 d1 2.28 us (6.83 vs 9.11), c1024 d1 2.74 us (7.03 vs 9.77), no client-bound run (the inline and offload numbers per request are both higher than on 2026-10-07; hyper's were too, see the gate). Again after S7-22 on the final code (`build/S7-fix2/offload2`, load 2.98 before (CPUs 12-15 40-50 % busy with another workflow when it started), 9.88 after, CPUs 12-15 98 % idle after): c256 d1 2.26 us (6.81 vs 9.07), c1024 d1 2.72 us (7.00 vs 9.72), no client-bound run. Inline gate after the S7 fix (`bench/run_gate.sh`, `build/S7-fix2/gate`, load 6.25 before (the offload run just ended), 7.47 after; CPUs 12-15 95-98 % idle after): c256 d1 0.937, c256 d16 0.840, c1024 d1 0.962, c1024 d16 0.871 x hyper, no client-bound run (hyper c256 d1 156 083 req per CPU-second here); this gate ran before S7-22, which does not touch the inline path (`ReleaseTransport` of an unshared exchange returns before the changed lines; `Share`, `CancelShared` and the other changed routines run only for shared exchanges or streams), and the inline numbers of `offload2` after S7-22 (6.81 / 7.00 us per request) match those of `offload` before it (6.83 / 7.03); an earlier run before the S7-21 test work (`build/S7-fix/gate`) gave 0.955, 0.841, 0.977, 0.868; before S7 (step H, `build/H-verify2/gate`) 0.946, 0.840, 0.962, 0.867: the inline numbers did not change. (The S5 numbers 0.95 / 0.87 / 0.97 / 0.88 were measured before step H; c256 d16 has been 0.84 since H) | 0.2 gives the prototype's number, not the method; requests per CPU-second include the workers' spinning |
| S7-16 | 3.2.3 rule 3, `TExchange.Release` (S7 fix; S7 verifier finding, major) | `Release` decrements with a CAS loop and, when the count it replaces is 2 (this reference and the transport's), ends an open stream (`AutoFinish`, deviation S7-5) BEFORE its decrement, while it still holds its reference; after the decrement it touches the exchange only when it took the count to 0. The S7 code ended the stream after the decrement: the transport could release (1 -> 0), the exchange be recycled into the loop's pool and a new request start a stream on the same object, which the stale `AutoFinish` then ended (and could wake from the worker thread). A count of 2 with an open stream always means this reference and the transport's: the transport releases only after the stream was taken to its end or dropped (`Done` closes the channel first). Builds with assertions have `ReleaseTestHook`, called right after the decrement. Test: `Release_after_recycle_leaves_the_new_stream` (the hook holds the worker 300 ms after its decrement; the loop recycles the exchange and begins a stream for a new request on the same object; the stream is still open after the stale release returned); the mutant with the old order (`autofinish-after-decrement`) fails it. `Stream_two_producers_one_releases`: a release that leaves a second producer does not end the stream (`v-autofinish-at-any-count` fails it). One edge stays: a loop-thread `Share` that comes between the count-2 read and the CAS finds the stream already ended (its writes get `wrCanceled`), as if it came after the release. Superseded in the S7 fix round 7 (S7-43): that edge and its reverse (a no-op decision followed by 2 -> 3 -> 2, after which nobody ended the stream) are gone; the decision is the holder decrement that reaches 0, still made before the reference goes | a released reference must not be used; the verifier's demonstration (`build/S7-verify1/race-demo`: the new request's `WriteString` returned `wrCanceled`) |
| S7-17 | 7.4 row 4, `conformance/pascal-server/extra/extra-cases.json` `disconnect_during_delay` (S7 fix; S7 verifier finding, major) | the case's runner step waits for `request_body` instead of `request` before it closes. Under `--executor worker` the body is read on a worker after the `request` event; a close right after `request` could reach the loop before that read, the read then returned `brCanceled`, and `beconf` emitted no `request_body` (the reference reads the empty body in its first poll, so it always emits it; the verifier saw the difference in 2 of 9 runs). After the change the close comes during the handler's delay under every executor, which is what the case is named for; inline `beconf` and the reference emit `request_body` in the same poll as `request`, so the change does not change what the case checks for them. No allowlist entry is needed | the case's purpose is a disconnect during the delay; the alternative, an `events` allowlist entry, would accept any event difference in the case |
| S7-18 | 3.2.4 last paragraph (text corrected in the S7 fix; S7 verifier finding, minor) | implemented in builds with assertions (`-Sa`; `{$ifopt C+}`): loop-thread assertions in `TryRead`, `Respond`, `RespondStream`, `Fail`, `ReleaseRequest`, `DiscardBody`, `Wake` (unshared exchange) and `Offload`, `OnUpgrade`, `BeginRequest`, `CompleteCall`, `Cancel`; a head view is overwritten with 0xDD when it is unpinned (`PoisonAndRelease`: `ReleaseRequest`, `SyncShared`, `Recycle`; pool memory only); `Wake` asserts the exchange is not recycled (`xsIdle`); the wake message's handler asserts `FWakeQueued = 1` (a node pushed twice would be dispatched twice). `Wake` has no generation to compare, so the design's "generation counter checked by `Wake`" became the `xsIdle` check plus the loop-thread check of an unshared exchange (a stale off-loop `Wake` of a reused unshared exchange fails it). Not asserted: `Recycle`, `ReleaseTransport`, `TExchange.Destroy` (`TServerLoop.Destroy` runs them on the main thread after the loop thread exited). `TLoop.ThreadId` is now written with `AtomicStoreThreadId` and read with `AtomicLoadThreadId` (bearings.rt.sync; a plain load and store, not inlined in `-dWD_DRD` builds): `TServer.Destroy` takes the loop thread's place while a worker may still read it in `OnOwnLoop`. Test: `Debug_checks_and_poison` (mutants `debug-no-poison`, `debug-wake-no-recycled-check`, `debug-try-read-no-thread-check` fail it); the 105 wire cases and the extra cases run against the debug profile (`-Sa`) of `beconf`, inline and worker | the design names the checks, not the build or the methods **Extended by S7 decision 17 (S7 fix round 4, S7-29):** every loop-only method of an unshared exchange, the response-head checks of decision 16, and a generation check of the wake message (3.2.4) |
| S7-19 | 1.7, 3.5, `TChannelBody` producers (S7 fix; S7 verifier finding, minor) | the producers of a `TChannelBody` wait on a `TEventCount` (new, bearings.rt.sync: `Key` read under the channel lock, `Wait(Key)`, `NotifyAll` with `futex_wake(all)` only while a thread waits) instead of a `TParker`, which supports one waiter: two threads blocked in `Write` on the same full channel could leave one in `futex_wait` forever. Design 3.5 lets any thread write after `Share`, so several producers may block at once. Test: `Stream_two_blocked_producers` (two producers blocked in `Write` on a channel of one frame, 50 iterations; every frame arrives); the mutant that wakes one waiter (`event-count-wakes-one`). The request body's `Chan.Parker` stays a `TParker`: the body has one reader at a time (`Held` is one view, 3.3) | the verifier's analysis of `TParker.Park` with two waiters |
| S7-20 | 3.4 `TChannelBody.FinishStream`, `Enqueue` (S7 fix; S7 verifier findings, minor) | `FinishStream` claims the end under the lock first (`FFinishing`: frames, `Finish` and `AbortStream` of other producers are refused from then on), copies the trailers without the lock, and publishes `FFinished` under the lock; a refused `Finish` touches nothing (it rewrote the trailer list the dispatcher was reading, and two first calls could each create the list and leak one). Test: `Second_finish_leaves_the_trailers` (mutant `finish-no-claim`). The ring growth is its own routine (`Grow`), so `Enqueue` has no implicit exception frame; `tools/check-hot-asm.sh --s7` (the `run_all.sh` default now) checks `Enqueue`, `Push`, `PollFrame`, the other per-frame `TChannelBody` routines, `TExchange.Release`, `Write`, `WriteString`, `Wake`, `TryReadShared` and the bearings.rt.sync primitives | design 4.4 |
| S7-21 | 9 S7 tests (S7 fix; S7 verifier finding, minor: 13 of its 14 mutants survived) | new tests in `test_workers` for the surviving mutants: `Cancel_keeps_the_chunk_a_worker_holds` (S7-2), `Stream_first_frame_above_high_water` (S7-5), `Stream_two_producers_one_releases` (S7-5), `Server_destroy_recycles_what_workers_release` (S7-10; new counter `ExchangesLive` in bearings.http.exchange), `Offload_on_a_stopped_pool` (S7-11), `Released_head_unpinned_on_wake` (`SyncShared` from the wake message), `Read_all_limit_without_content_length`, `Wake_posts_one_message_while_queued` (the `FWakeQueued` dedupe with another exchange's message between the two posts), `Burst_behind_a_spinner_runs_in_parallel` (the chain wake of `PopLocked`), `Unpark_at_park_entry` (an `Unpark` timed to land while the other thread enters `Park`; the S7 mutant `park-loses-notification` survived `Ping_pong_has_no_lost_wakeup` in 3 of 3 runs here when pinned, and in 2 of 4 unpinned runs; the new test killed it in 5 of 5 unpinned runs and 1 of 3 runs pinned to the E-cores 12-15), and in `Answer_from_worker` a `Fail` after the answer that must leave the response slot alone. The verifier's mutants are in `tools/s7-mutants.py` (ids `v-*`), with the S7 fix mutants: 45 of 45 detected (`build/S7-fix2/mutants.out`: 40; the 5 whose snippets moved with S7-22, `build/S7-fix2/mutants-5`: 5; the base copy passes every named test and its drd run has 0 errors). `v-release-transport-no-wake-producer` and `v-complete-shared-no-done` have no test: the producer is also woken by `Done` (called before the transport's release whenever the stream was the answer), and `xsDone` and `xsAnswered` are read the same way by every reader (`Answered`, `ReleaseTransport`, the terminal calls' `xsCalled` check), so both are equivalent mutants as far as found. The off-loop actions of the new tests run on the test pool's workers (`RunOnPool`), not on raw `BeginThread` threads: a raw thread that allocates gives drd heap reports at its exit (FPC threads detach themselves) | the verifier's mutants |
| S7-22 | 9 S7 exit "drd clean", 7.5 (S7 fix, found by this fix's own runs) | `run_all.sh`'s drd runs run one at a time on an idle machine; run 12 or 16 at a time (CPUs 0-11 or 0-7, `build/S7-fix2/pe/drd1`, `drd2`, `drd3`), 33 of 36 runs reported errors and 9 had a failed test. Fixed: (1) `TExchange.FChannel` was created by the thread of the first stream (a worker) with a plain store and read by the loop thread (`CancelShared`, `ReleaseTransport`) and by other producers without an ordering: it is now published with `AtomicStorePtr` after construction (`HappensBefore`) and read with `AtomicLoadPtr` (`HappensAfter`) in `BeginStream`, `StreamWriter`, `Release`, `ReleaseTransport` and `CancelShared` (new `AtomicLoadPtr` / `AtomicStorePtr` in bearings.rt.sync; on x86-64 a plain aligned load / store, so the generated code is the same outside `-dWD_DRD`); (2) `ReleaseTransport` read `Resp.Source` before its `HappensAfter(@FState)`: it now reads the state once, then the edge, then the slot; (3) `Share` wrote `FShared := True` again on an already shared exchange (a second producer) while a worker read it: it writes only when it is False; (4) FPC's own heap hands a block freed by one thread to another through lock-free lists drd cannot see, which gave false conflicts in `SysFreeMem_Fixed`, `FillChar` and `NewAnsiString` when the block was reused: the `-dWD_DRD` build of `test_workers` uses `cmem` (the C heap, which valgrind replaces and drd tracks; as deviation S1-9 already asks for memcheck), and `tools/drd.supp` gets `fpc-initheapthread` (the RTL's unlocked read of `heap_lock_use` at thread start, > 0 from the main thread's `RelocateHeap` until the last thread ends); (5) two tests assumed timing: `Answer_from_worker` asserted `RefCount = 2` right after the offload (the worker may already have released: now 2, or 1 with the handler finished), and `Worker_reads_body_with_continue` failed when a wake came before the take that makes the channel ready (wakes may be spurious: it now polls again after each wake, at most 3). After the fixes: 36 drd runs 12 at a time and 32 runs 16 at a time on 8 CPUs: 0 errors, 0 failed tests (`drd5`, `drd6`); 36 native runs 12 at a time on 4 CPUs: 0 failed tests; `run_all.sh`: 3 drd runs, 0 errors. Not resolved: in the first `run_all.sh` of this fix (2026-10-08 00:47, before these changes; its log was overwritten by the later `run_all.sh`, the summary line was `test_workers (drd run 3): Time:17.540 N:44 E:0 F:1`) drd run 3 failed `Unpark_at_park_entry` once (one park waited for its 1 s timeout, the test took 8.8 s instead of 7.8 s); not reproduced in 10 runs of that test alone and 68 full runs under drd, nor in 40 native runs; the test's message now says when the other thread's `Unpark` started and returned relative to the round, which tells a lost wakeup (the `Unpark` came early) from a stalled thread (it came late) the next time | the exit criterion "drd clean" must hold whatever the scheduling, not only in one serial run |
| S7-23 | 3.2.3 rules 5 and 6, 3.2.4 `Resp.*` row (second S7 fix; second S7 verifier: one major, one minor finding, and its design problem 2) | (1) `TExchange.TryReadShared` reads the state under `Chan.Lock` (it read it before the lock): `CancelShared` does its CAS before `CloseBodyFromLoop` takes the lock, so a read that finds the receiver closed by a cancel also finds `xsCanceled` and returns `brCanceled` (blocking reads raise `EClientGone`). Before, a cancel between the state read and the lock made the read return `brEnd` and `ReadAll` / `ReadChunk` gave a truncated body as complete. (2) Terminal calls on a shared exchange first claim the response slot (`ClaimAnswer`: state `xsCalled` and `CAS(FAnswerClaim, 1, 0)`, new field reset in `BeginRequest`); a call that finds it claimed returns False and writes nothing; `BeginStream` claims before it touches the channel (two concurrent `BeginStream` could reset the winner's channel); the claimer writes the slot and does the `FState` CAS against `Cancel`, and takes back what it wrote if `Cancel` won. 3.2.2 said "False if ... already answered", but the check-write-CAS order let a losing `Fail` leave `Resp.Failed` set after a winning `Respond` (the connection then closed) or a losing `Respond` replace the winner's body. Rules 5 and 6 and the 3.2.4 row are amended in the text. Cost: one more CAS per shared terminal call only; the inline path gets one plain store (`FAnswerClaim := 0` in `BeginRequest`). Tests: `Cancel_before_the_read_takes_the_lock` (`TryReadTestHook`, builds with assertions: the worker's read waits 300 ms right before the lock while the loop cancels; mutant `v2-try-read-state-before-lock`: the read returned the end, `ErrClass` empty), `Concurrent_terminal_calls_leave_the_winner` (`AnswerTestHook`: the worker's `Fail` waits 300 ms after its claim while the loop thread's `Respond` must return False; mutant `v2-no-answer-claim`: the `Respond` returned True) | the design promises EClientGone after a cancel and a clean False to the second terminal call; the verifier's demonstrations (`scratchpad/s7v2`: 8 clean ends in 3000 iterations; `Respond=TRUE Fail=FALSE Resp.Failed=TRUE`) |
| S7-24 | 6.8, `beconf.service` (second S7 fix; second S7 verifier, two minor findings) | (1) `--executor worker`: the handler's step 8 no longer writes `UpHandler.Armed` or `TConnData.PendingUpgrade` from the worker; it sets `ArmUpgrade` / `PendingUpgrade` on its `TConfWorkerCall`, and the loop applies them in the `Poll` that returns `cpReady` (as `EmitNoUpgrade` already did). The worker wrote objects the loop frees at connection end (`UpgradeFailed` frees `UpHandler`, `OnConnClose` frees the `TConnData`) with no check, a use-after-free when the connection ended between the worker's `ReleaseRequest` and step 8. The flags are written before the terminal call, whose CAS the loop sees (`Answered`) before it reads them. When the connection ends after the worker's answer and before the loop polls, no `upgrade_error` follows (`Armed` stays False); the reference has no such window (its handler returns the response to the dispatcher in the same poll). (2) `TConfWorkerCall.Poll` takes the worker's reference back when `Offload` raises (`EWorkerPoolStopped`): the call object leaked. Checked by `gate_worker.sh` (the upgrade cases), not by a unit test (test tooling) | found by reading; a worker must not touch loop-owned objects after the loop may have freed them |
| S7-25 | 7.5, `run_all.sh` drd runs, `tools/s7-mutants.py` (second S7 fix; S7-22's open `Unpark_at_park_entry` failure) | the drd runs use `--fair-sched=yes`. Analysis: `TParker` with one waiter has no lost-wakeup path (the S7 verifier read it the same way): `Unpark` sets 1 and wakes only a parked thread (2); `Park` consumes 1, or announces 2 with a CAS from 0 that fails only when an `Unpark` came in between (then it consumes), and after each futex return it consumes 1 or, on its timeout, gives the wait up with a CAS from 2 that fails only when an `Unpark` came (then it consumes). The one failure is consistent with a stalled thread instead: valgrind runs one thread at a time under a lock, and its default lock (`--fair-sched=no`, a pipe) lets a running thread take it back again and again while another waits for it (valgrind manual, `--fair-sched`); in `Unpark_at_park_entry` the main thread busy-waits (`CpuRelax`) for the round the parker thread publishes, and the parker's round clock starts before that publication, so a parker that lost the lock after its `T0` and before its store waits while the main thread spins, and the park returns late. `--fair-sched=yes` (a ticket lock) removes that starvation; it does not change what drd checks (happens-before analysis). Not proven: the failure was seen once and not reproduced (S7-22); after the change `run_all.sh`'s 3 drd runs had 0 errors and 0 failed tests | a test of the parker must not fail because of the tool's scheduler |
| S7-26 | 9 S7 tests and measurements (second S7 fix; second S7 verifier, minor finding on test gaps) | new tests in `test_workers` for its surviving mutants: `Complete_closes_body_and_transport_release_detaches` (`CompleteShared` closes the receiver for a handler that answered without reading the body: the dispatcher's `PollReady` sees it closed and the handler's later read ends; after `ReleaseTransport` the worker's `ReleaseRequest` wakes the loop but not the owner; mutants `v2-complete-shared-no-close`, `v2-release-transport-keeps-owner`), `Cancel_releases_the_untaken_item` (`CancelShared` closes the receiver, so the chunk the connection sent and nobody took is unpinned when the sender goes; the head stays pinned, S7-2; mutant `v2-cancel-shared-no-close`), `Stream_frame_wakes_the_waiting_consumer` (the consumer waits before the producer writes, and nothing else wakes it; mutant `stream-no-consumer-wake-2`, the deterministic form of `stream-no-consumer-wake`, which `Stream_backpressure_frames_and_trailers` detects only when the consumer happens to wait), and the two tests of S7-23. Left without a test, as equivalent: `CancelShared` without `FOwner := nil` (the dispatcher calls `ReleaseTransport`, which clears it, in the same loop-thread step as `Cancel`, before any inbox message runs), and the four the verifier itself classed as equivalent or harmless. `tools/s7-mutants.py`: 51 mutants, 51 detected (`build/S7-fix3/mutants.out`; `queued-job-skips-cancel-check` and `v-respond-shared-no-state-check` follow the moved code). Results of the second S7 fix (2026-10-08): `run_all.sh` passed (`build/S7-fix3/run_all.out`: 871 unit tests, `test_workers` N:49 plain, heaptrc 0 unfreed blocks, 3 drd runs 0 errors; conn-diff 122 hand + 10 000 generated, 0 different; echo 1 GiB under memcheck 0 errors; `check-hot-asm.sh --s7` with `TExchange.ClaimAnswer` added: passed); 24 drd runs 12 at a time on CPUs 0-11: 0 errors, 0 failed tests; 12 native runs at a time on CPUs 0-3: 0 failed tests. `gate_worker.sh` debug profile 5 runs (`build/S7-fix3/gate_worker.out`, load 1.55 before, 0.30 after): assertion `passed=103 failed=1` (only `chunk2::pipeline_enabled`), diff `same=103 different=1` (listed), extras `same=27`, probe `passed=0 failed=2` on reference-server and `same=2`; release profile 2 runs: the same. Inline `gate.sh` (RUNS=2): assertion 104 x2, diff `same=104` x2, loaded diffs 0. Offload cost (`bench/run_offload.sh`, `build/S7-fix3/offload`, load 0.32 before, 10.33 after; CPUs 12-15 97-99 % idle before and after): c256 d1 2.32 us (6.83 vs 9.15 us per request), c1024 d1 2.76 us (7.02 vs 9.78), limit 5.4. Inline gate (`bench/run_gate.sh`, `build/S7-fix3/gate`, load 7.10 before (the offload run had just ended), 5.97 after; CPUs 12-15 97-99 % idle before and after): c256 d1 0.937, c256 d16 0.839, c1024 d1 0.967, c1024 d16 0.861 x hyper, no client-bound run; the same as after the first S7 fix (0.937, 0.840, 0.962, 0.871) | the verifier's mutants; the exit criteria |
| S7-27 | 3.2.3 rules 6 and 7, 3.3, `TExchange.Release` / `CompleteShared` / `CancelShared` / `TryReadShared`, `TBodyChan.CloseReceiverFromLoop`, `TH1Dispatcher.PollReadHead` (S7 fix round 4: S7 decision 15; third S7 verifier, major finding and design problem 6) | (1) A new interlocked count `FHolders` (references `Share` gave out and `Release` did not take back; the transport's reference is not one): the `Release` that takes it to 0 drops the request (`ReleaseRequestShared`: the receiver closes, the head is unpinned on the loop, the loop is woken) before it gives up its own reference; `Offload` takes its holder back when the pool refuses the item. (2) `CompleteShared` no longer closes the receiver, so the dispatcher keeps feeding the body after the completion; a worker can answer first and read afterwards, or stream while it reads. (3) `CloseReceiverFromLoop` (now only the cancel's) unparks a parked reader (`ReceiverParks` → `DeferUnpark`; `CancelShared`'s own `Parker.Unpark` moved there) and sets `Chan.LoopClosed`; `TryReadShared` returns `brCanceled` for it, so a cancel that lost the CAS to the answer gives `EClientGone`, not the end of the body. **Replaced by S7-31 (S7 fix round 5):** the flag survived the recycle (a stale `EClientGone` on the next request without a body); a cancel that lost the CAS no longer closes the receiver (the reader gets `EBodyError` through the dispatcher's guard, as after the completion), and a receiver closed before the reader saw the end reads as `brCanceled` from the channel's own `Terminated`. (4) When the connection ends after the completion, `DropAll` drops the body sender with the incomplete-message error (unchanged, hyper's `SenderDropGuard`), so the read raises `EBodyError`. (5) Dispatcher deviation from hyper: `PollReadHead` drops a body sender that is still set (`BodyTx`) before it reads the next head. That happens only when the body's last frame went out after the response was finished (reading went `KeepAlive` → `Init` in the same `PollReadBody`), which only a shared exchange allows. hyper keeps that sender (`body_tx`) until a later request with a body replaces it or the connection ends, so its reader of a Content-Length body is Pending after the last chunk (`Incoming::poll_frame` only counts the length down); wd-40's reader gets the end the body really had at once, and the shared exchange is released with its sender closed (without this step, `AcquireExchange` releases the exchange with the sender open, `BodyTx` then refers to the next exchange, and the reader waits for ever: mutant `d15-dispatcher-keeps-ended-sender`). Unreachable for an unshared exchange (its receiver closes at completion, before the response can end), so inline behavior and the conformance bytes do not change. (6) The edge of S7-16 applies: a loop-thread `Share` that comes after the holder count reached 0 finds the request released. **Superseded by S7-32 (S7 fix round 5):** that edge was a use of a released head (the fourth S7 verifiers: `EAccessViolation` in the worker); the call in flight is now a holder, and a `Share` with no holder left raises. Cost: one interlocked decrement per `Release` and one per `Share`; a `Release` of a handler that did not release the request takes `Chan.Lock` and posts a wake | design 3.3 and S7-2 closed the receiver at call completion: a worker parked in a body read stayed parked for ever (the close woke only the sender), and with the unpark added a read after the completion reported a clean end of a body that had not ended; hyper's request lives as long as its owner (decision 15) |
| S7-28 | 3.2.3 rule 5, 3.2.4 `Resp.*` rows (S7 fix round 4: S7 decision 16; third S7 verifier, minor finding) | the text: the answer claim protects `Resp.Body`, `Resp.Source`, `Resp.Failed`, `Resp.FailText`; the response head is written by the thread that will make the terminal call, before it. The check, in builds with assertions: `TExchange.DbgHeadWrite` (called by `Status`, `ResponseVersion`, `SetReason`, and by `ResponseHeaders` while the response is not claimed) records the first writer of a shared exchange's head (`FHeadWriter`, compare-and-swap) and asserts that every later head write comes from the same thread and before the claim; `DbgHeadClaim` (in `ClaimAnswer`, after a successful claim) asserts that the claimer is the head's writer or that nobody wrote the head; unshared, the head write asserts the loop thread. A losing terminal call from another thread is still allowed (it returns False). `FHeadWriter` exists in every build (the class layout does not depend on `-Sa`); release builds never write it (true since S7-33: `Recycle` wrote it in every build). The check asserted `FState = xsCalled` too, which the loop's cancel breaks: corrected in S7-33 | the amended row claimed that the claim protects every `Resp.*` field, but the head setters write before any claim |
| S7-29 | 3.2.4 last paragraph (S7 fix round 4: S7 decision 17; first S7 verifier, minor finding, partly done in S7-18) | builds with assertions: `TExchange.DbgLoopOnly` asserts the loop thread for an unshared exchange in every method listed in 3.2.4 (the head accessors, `RequestTrailers`, `BodyErrorKind`/`Message`, the response head, `BeginStream`, the stream writer, `IsCanceled`, `Answered`, `SetBodyErrorText`, `FillHead`, `LinkUpgrade`, besides S7-18's); the generation check: a cross-thread `Wake` stores `FGen` in `FWakeGen` when it posts the wake message, and `ExchangeWakeMsg` asserts `FWakeGen = FGen` before its `FWakeQueued` check. The design's "generation counter checked by `Wake`" became this check of the message's generation: `Wake` itself has no generation to compare (the caller passes none), and the message is the cross-thread part of `Wake`. `tools/check-hot-asm.sh --s7` now also fails when the production listing of `bearings.http.exchange` has a `TExchange.Dbg*` routine or an `fpc_assert` call (and when the test listing has none) | the design names the checks; the generation needs something to compare against |
| S7-30 | 9 S7 tests and measurements (S7 fix round 4: S7 decisions 14-17; third S7 verifier's findings) | new tests in `test_workers` (61 tests): `V3_complete_while_parked_in_read` and `V3_stream_then_read_parked` (the verifier's tests in their decision-15 form: after the completion the parked read gets the chunks the loop sends and then the end the body really had; the echo writes each chunk back while the body is still open), `Cancel_after_answer_while_parked_in_read` (a cancel that lost to the answer: `EClientGone`), `Connection_gone_after_answer_while_parked` (`EBodyError`, not the end), `Last_release_drops_the_request`, `Respond_take_back_releases_the_body`, `Stream_take_back_calls_done`, `Begin_stream_claims_before_the_channel` (the verifier's mutants B, C, D; `AnswerTestHook` is now also called by `RespondShared` and `PublishStream` right after the claim), `Head_built_by_one_thread`, `Terminal_call_by_another_thread_than_the_head` (decision 16), `Debug_loop_only_and_wake_generation` (decision 17), and in `TTestWorkerServer` `Server_worker_reads_after_its_answer` (through the dispatcher: an echo that streams while it reads, and an answer before the body whose end the worker sees while the connection stays open, then the next request on it). `Complete_closes_body_and_transport_release_detaches` became `Complete_keeps_body_and_transport_release_detaches` (it asserted the close at completion that decision 15 removed). `tools/s7-mutants.py`: 65 mutants, 65 detected (`build/S7-fix4-impl/mutants.out`: 62 of 65; the 3 that changed after that run, `build/S7-fix4-impl/mutants-3.out`: 3 of 3). New: `d15-*` (6, including the pre-fix code `d15-complete-shared-closes-no-unpark` and the dispatcher's `d15-dispatcher-keeps-ended-sender`), `v3-*` (the verifier's B, C, D), `d16-*` (3), `d17-*` (3). Changed: `v2-complete-shared-no-close` removed (its mutation is decision 15's code); `cancel-no-unpark-reader` follows the unpark into `CloseReceiverFromLoop`; `respond-no-wake` now names `V3_complete_while_parked_in_read` (a handler that returns after its answer also wakes the loop by its last `Release`, which drops the request, so `Answer_from_worker` no longer detects it); `v2-try-read-state-before-lock` also disables the `LoopClosed` check (alone it is now equivalent: `LoopClosed` turns a cancel's close into `brCanceled` too). Results (2026-10-08): `run_all.sh` from a clean directory passed (`build/S7-fix4-impl/run_all.out`: 883 unit tests, `test_workers` N:61, heaptrc 0 unfreed blocks in the 5 suites, 3 drd runs 0 errors, conn-diff 122 hand + 10 000 generated 0 different, echo 1 GiB passed, `check-hot-asm.sh --s7` passed with the new production check: 0 `TExchange.Dbg*` routines and 0 `fpc_assert` calls in the production listing, 3 and 36 in the test listing); 12 drd runs at a time on CPUs 0-11: 0 errors, 0 failed tests; 12 native runs at a time on CPUs 0-3: 0 failed tests; `tests/web/run_all.sh` passed (the M5 suite uses `Offload`, `ReadAll` and the terminal calls). `gate_worker.sh` (debug profile, 5 runs): the first run (`build/S7-fix4-impl/gate_worker.out`, load 3.36 before, CPUs 14-15 100 % busy with the other workflow's job) failed on one unlisted difference in diff run 4: `chunk1::get_with_body`, a trailing `conn_close` that only beconf's event list had (`classify_diff.py`: trailing-conn-close, the harness race of S6-11); 40 single-case diff runs of that case each with the new and the third round's `beconf` and 8 full worker diff runs of each, alternating, gave no such difference; the second run on an idle machine (`gate_worker2.out`, load 2.25 before, 2.35 after) passed: assertion `passed=103 failed=1` x5 (only `chunk2::pipeline_enabled`), diff `same=103 different=1` x5 (listed), extras `same=27`, probe `passed=0 failed=2` on reference-server and `same=2`; release profile 2 runs (`gate_worker_rel.out`): the same. Inline `gate.sh` RUNS=5 (`gate_inline.out`): assertion 104 x5, diff `same=104` x5, extras `same=27`, 5 loaded diff runs `same=104`, 0 differences to classify. Offload cost (`bench/run_offload.sh`, `build/S7-fix4-impl/offload`, load 1.79 before, 9.98 after, CPUs 12-15 98-99 % idle after, no client-bound run): c256 d1 2.35 us (6.82 vs 9.17 us per request), c1024 d1 2.75 us (6.98 vs 9.74), limit 5.4. Inline gate (`bench/run_gate.sh`, `build/S7-fix4-impl/gate`, load 6.88 before (the offload run had just ended), 6.71 after, CPUs 12-15 96-99 % idle before and after, no client-bound run): c256 d1 0.939, c256 d16 0.838, c1024 d1 0.970, c1024 d16 0.861 x hyper; after the second S7 fix 0.937, 0.839, 0.967, 0.861 | the third verifier's findings and mutants; decisions 14-17; the exit criteria |
| S7-31 | 0.3 S7 decision 15, 3.2.3 rules 6 and 7, 3.3; `TBodyChan` (`LoopClosed` removed, `CloseReceiver`), `TExchange.TryReadShared`, `CancelShared`, `ReadChunk` (S7 fix round 5; fourth S7 verifiers: race lens major, contract lens major and design problems 4 and 6) | (1) **Stale close flag (major).** Round 4's `Chan.LoopClosed` was reset only by `Chan.Open`, which runs only for a request with a body; after a cancel closed an open receiver the exchange was recycled with the flag set, and the next request on it without a body (a GET) read `brCanceled`: `EClientGone` on a live connection, "handler returned no response", the connection closed without a response (12 failures in 6 of 10 stress seeds, `build/S7-verify4-race`; here 4 of 6 seeds of `stress_workers` against the round-4 code, `build/S7-fix5/before-stress`). The flag is gone: on a shared exchange a read of a receiver that was closed before the reader saw the end (the channel's `Terminated` not set) reports `brCanceled`; a request without a body (`Chan.Active = False`) reads `brEnd` before that, so nothing of an earlier request's channel is looked at. (2) **A holder's close (major).** `ReleaseRequest`/`DiscardBody`/the last `Release` from one holder closed the receiver without unparking another holder parked in a read, and a later read returned `brEnd` (0 of 10 bytes). `CloseReceiver` now unparks a parked reader and the read reports `brCanceled` (`EClientGone` with the message "the request was released before its body ended"); 3.2.3 rule 7 and 3.5 now say that only the request's one user calls `ReleaseRequest` / `DiscardBody` (they are request-wide), other holders only `Release`. (3) **A cancel that lost the CAS (minor; differs from S7 decision 15 as given).** Round 4 closed the receiver on every cancel, so the same event (the connection ends after the worker answered) gave `EClientGone` with any untaken chunk dropped when the dispatcher had not yet taken the answer, and the chunks then `EBodyError` when it had. hyper has one behaviour: the spawned task's `Incoming` keeps the channel, and the dispatcher's `SenderDropGuard` sends the incomplete-message error (dispatch.rs `body_tx` drop guard; conn.rs keeps nothing else). Now only a cancel that wins the CAS closes the receiver; one that lost leaves the request with its holders, `DropAll`'s guard (right after `Cancel`) ends the body with the incomplete error, and the reader gets the chunks that arrived and then `EBodyError`, or the end the body really had. The decision as given listed "connection gone" with the closes after which a blocking read raises `EClientGone`; hyper gives the body error, which the decision also asks to follow, and the round-4 text already said `EBodyError` after the completion: the decision text in 0.3 now says this. A cancel that wins still gives `EClientGone` (3.2.3 rule 6). Tests: `Stale_cancel_does_not_end_the_next_request`, `Second_holder_release_request_unparks_the_reader`, `Cancel_lost_with_complete_body_keeps_the_chunk` (the verifier's X2 and X3), `Cancel_after_answer_while_parked_in_read` (now `EBodyError`, was `EClientGone`), `Server_abort_after_answer_gives_body_error` (through the dispatcher: the guard's error reaches a worker reading after its answer; the verifier's mutant my6 passed every test before) | the verifiers' reproductions; hyper's behaviour (decision 15: "check what hyper does and do the same") |
| S7-32 | 3.2.3 rules 2 and 7, 3.2.4 `FHolders` row, 3.5; `TExchange.Share`, `DropHolder`, `CompleteShared`, `CancelShared`, `Release` (S7 fix round 5; race lens major, design problem 1) | the call in flight is a holder of the request: the first `Share` sets `FHolders := 2` (the call and the new reference) and `CompleteShared` / `CancelShared` give the call's holder up (`DropHolder`; the decrement that reaches 0 drops the request). Round 4 counted only the references `Share` gave out, so a holder that released during the call took the count to 0 and dropped the request while the call could still `Share` or `Offload`; the next holder read a released, poisoned head (`repro_share_after_drop`: `EAccessViolation` in the worker; S7-27 (6) had accepted this as an edge). hyper's service future owns `req` until it completes. `Share` now raises without a call in flight (first `Share`: state not `xsCalled`/`xsAnswered`) and when no holder is left (a later `Share` CASes the count up from a value above 0). Effect on the request's lifetime: a worker that answers and returns without releasing the request no longer drops it at its `Release`; the completion (one loop poll later) does. Cost: one interlocked decrement per shared call (offload path only). Tests: `Share_during_the_call_keeps_the_request`, `Share_after_the_last_holder_raises`, `Release_leaving_another_holder_keeps_the_request` (the verifier's mutant my4), `Last_release_drops_the_request` (changed: the request goes at the completion, after the worker's release) | the request must not be dropped while its owner (the call) can still hand it out |
| S7-33 | 3.2.2, 3.2.4 (response head, loop-only list), S7-28, S7-29; `TExchange.DbgHeadWrite`, `ResponseHeaders`, `DiscardBody`, `Recycle` (S7 fix round 5; contract lens major and minors) | (1) the decision-16 check asserted `FState = xsCalled` besides the claim, so a head write that the loop's cancel overtook (a disconnect the worker cannot see atomically) raised `EAssertionFailed` in every `-Sa` build, also in the M5 suite's `TResponse.CommitTo` (4-12 per stress run). It asserts the claim (`FAnswerClaim = 0`) and the thread only; `ResponseHeaders` is checked under the same condition. (2) `DiscardBody` asserted the loop thread after its early exit for a request without a body: the check comes first now. (3) `Recycle` wrote `FHeadWriter` in every build, against S7-28's text: the write is inside `{$ifopt C+}`. (4) 3.2.2 said `OnLoopThread` is debug-asserted; it is a query and is not (3.2.4 lists it under "Not asserted"): the 3.2.2 text is corrected. Tests: `Head_write_after_cancel_is_legal` (the verifier's X1), `Debug_loop_only_and_wake_generation` (now 8 loop-only calls, `DiscardBody` of a request without a body added) | the design's own text (3.2.4); decision 16 protects the head by the claim |
| S7-34 | 7.5, 9 S7 exit "drd clean", 7.4 gates; `TExchange.Release` / `DropHolder` (annotations), `StreamWriter`, `TChannelBody.EmptyWrite`, bearings.http.headers `ValidatingMutatorCalls`, `tests/unit/stress_workers.pas`, `tools/s7-stress.sh`, `tools/drd.supp`, `gate_worker.sh`, `gate.sh`, `worker_allowlist.py`, `tools/s7-mutants.py` (S7 fix round 5; race lens minors, gate lens minors) | **Partly obsolete since T1:** the gate parts (`--settle-ms`, `classify_diff.py`, the trailing-conn_close classification) are removed; the drd and stress parts stay. (1) drd: `Release` announced `HappensBefore(@FRefCount)` before `AutoFinish` (and the wake it posts), so drd reported `Recycle`, `TExchangePool.Take`, `BeginRequest`, `Share` and `Cancel` against them; the annotation is now inside the CAS loop right before the CAS. The `FHolders` decrement has its own edge (`HappensBefore` before it, `HappensAfter` at 0). `StreamWriter` read `TChannelBody.FActive` without the lock (a data race with `Reset` / `Deactivate`): it no longer reads it (`Push`, `FinishStream`, `AbortWith` check it under the lock; a write of 0 bytes asks `EmptyWrite`, under the lock). `ValidatingMutatorCalls` (test builds) is incremented with `InterLockedIncrement64` (workers build response heads). (2) The end-to-end stress of the race verifier is in the repository (`tests/unit/stress_workers.pas`, with `ONLY_MODE`, `max_request_ms`, the helper shared before or after the offload, `B2S` instead of `BoolToStr`, whose lazy initialization drd reports); `tools/s7-stress.sh` runs 10 seeds natively (each also with the server destroyed while traffic runs) and 3 runs under drd. `tools/drd.supp` gets two FPC RTL entries that only the stress reaches: `fpc_popobjectstack` writes the plain global `System.ErrorAddr` on every exception pop, and `CBeginThread` sets `IsMultiThread`. Under drd every thread runs in turn and a request of mode 8 (`Read` in 1-13 byte pieces with busy waits) took up to 74 s (`build/S7-fix5/m8`, mode 8 only: with a 60 s client timeout 2 requests timed out, with 400 s none, `max_request_ms=73501`), and up to 104 s in a mixed run (`build/S7-fix5/s7-stress`, drd run 3): the drd runs use a 600 s client timeout. (3) The gates: every diff run of `gate_worker.sh` and the unloaded ones of `gate.sh` use the runner's `--settle-ms` (default 100, deviation S6-16); an unlisted DIFF in `gate_worker.sh` that is only a trailing `conn_close` (`classify_diff.py`, the harness race of S6-11 that reference-server shows against itself) is reported as such, with exit status 3 (as `gate.sh` does for its loaded runs), not as a pass. (4) `tools/s7-mutants.py`: `stream-no-consumer-wake` is removed (its test detects it only when the consumer happens to wait; S7-26 says so, and it survived one full run of the verifier); its deterministic form `stream-no-consumer-wake-2` stays. Snippets follow the round-5 code; new mutants `r5-*`, the verifier's my4 (`r5-release-drops-at-one`) and my6 (`d15-loop-closed-reads-end`, now on the dispatcher's guard) | the exit criterion "drd clean" beyond the unit suite; a gate whose result depends on a known harness race is not evidence |
| S7-35 | S7-10, 1.11; `TServer.Destroy`, `TExchangePool.Outstanding` (S7 fix round 5; race lens minor) | see S7-10's extension: `Destroy` processes the loops' inboxes until every exchange is back in its pool (at most `WorkerWaitMs`), else leaks the loops. Before, a holder outside the server's pool that released after `TServer.Free` read `FLoop.ThreadId` of a freed loop and posted to it (`repro_destroy_with_holder`: 7 invalid accesses under memcheck). Test: `Server_destroy_waits_for_an_outside_holder` (the holder releases 300 ms after `Free` began; before the fix `Free` returned first) | the design lets any thread hold a `Share`d reference (3.5); S8 owns the rest of shutdown |
| S7-36 | 9 S7 tests and measurements (S7 fix round 5: the fourth S7 verifiers' findings) | new tests in `test_workers` (70 tests): `Head_write_after_cancel_is_legal`, `Second_holder_release_request_unparks_the_reader`, `Cancel_lost_with_complete_body_keeps_the_chunk`, `Stale_cancel_does_not_end_the_next_request`, `Share_during_the_call_keeps_the_request`, `Share_after_the_last_holder_raises`, `Release_leaving_another_holder_keeps_the_request`, `Server_abort_after_answer_gives_body_error`, `Server_destroy_waits_for_an_outside_holder`; changed: `Cancel_after_answer_while_parked_in_read` (`EBodyError`, S7-31), `Last_release_drops_the_request` (dropped at the completion, S7-32), `Debug_loop_only_and_wake_generation` (8 calls, S7-33). Against the round-4 sources (`build/S7-fix5/before`) 10 of the 12 fail (the other two, `Release_leaving_another_holder_keeps_the_request` and `Server_abort_after_answer_gives_body_error`, close test gaps: they kill the verifier's mutants my4 and my6). Results (2026-10-08, `build/S7-fix5/`): `run_all.sh` passed (`run_all.out`: 892 unit tests, `test_workers` N:70, heaptrc 0 unfreed blocks in the 5 suites, 3 drd runs 0 errors, conn-diff 122 hand + 10 000 generated 0 different, echo 1 GiB passed, `check-hot-asm.sh --s7` passed: 0 `TExchange.Dbg*` routines and 0 `fpc_assert` calls in the production listing); `run_all2.out`, the run with the short stress step added (3 seeds × 2 natively, 1 drd run): passed, the same counts, the stress all `STRESS PASSED` with 0 drd errors. `tools/s7-stress.sh` (`s7-stress.out`, CPUs 6-11): 10 seeds × (normal, server destroyed at 300 ms) all `STRESS PASSED` (about 5 000 requests per normal run; 0 violations, 0 handler or loop assertions, 0 `head_write_after_cancel`, 0 hangs, 0 client errors, every exchange freed; `max_request_ms` at most 193), 3 drd runs 0 errors and `STRESS PASSED`. The round-4 sources with the same program: 4 of 6 seeds failed with client errors (the stale flag) and every seed had 4-5 `head_write_after_cancel` assertions (`before-stress`); 2 drd runs gave 45 and 51 errors, among them `Recycle`, `TExchangePool.Take`, `BeginRequest`, `Share`, `TChannelBody.Reset` and `THttpHeaders.Add` (`before-drd`). `tools/s7-mutants.py` (`mutants.out`, CPUs 0-5): 76 mutants, 76 detected; the base copy passes every named test and its drd run. `tests/web/run_all.sh` passed (`web_run_all.out`; it wrote its build into its default directory `build/m5/FX1-impl`). `gate_worker.sh` debug profile 5 runs (`gate_worker.out`, load 1.86 before, 0.58 after): assertion `passed=103 failed=1` x5 (only `chunk2::pipeline_enabled`), diff `same=103 different=1` x5 (listed), extras `same=27`, probe `passed=0 failed=2` on reference-server and `same=2`; release profile 2 runs (`gate_worker_rel.out`): the same. Inline `gate.sh` RUNS=5 (`gate_inline.out`): assertion 104 x5, diff `same=104` x5, extras `same=27`, 5 loaded diff runs `same=104`, 0 differences to classify. Offload cost (`bench/run_offload.sh`, `offload.out`, load 3.84 before, 13.37 after, CPUs 12-15 97-98 % idle after, no client-bound run): c256 d1 2.44 us (6.92 vs 9.36 us per request), c1024 d1 3.20 us (7.59 vs 10.80), limit 5.4. Inline gate (`bench/run_gate.sh`, `gate.out`, load 4.65 before, 9.60 after, CPUs 12-15 91-94 % idle after, no client-bound run): c256 d1 0.946, c256 d16 0.840, c1024 d1 0.967, c1024 d16 0.877 x hyper (req per CPU-second); after round 4 0.939, 0.838, 0.970, 0.861: the inline numbers did not change | the fourth S7 verifiers' findings; the exit criteria |
| S7-37 | 1.7, 1.11, S7-10, S7-35; `TLoop.Post` / `Posting` / `PostsInProgress`, `TServer.Destroy` (S7 fix round 6; fifth S7 verifiers: race lens major, design problem 1) | `TServer.Destroy` freed the loops once every exchange was back in its pool (S7-35), but an exchange is back when its `FreeMsg` was handled, and the thread that posted it can still be inside `TLoop.Post`: after the push it runs `InterlockedExchange(Sleeping, 0)` on the loop and, when the loop slept, writes the eventfd and increments `WakeWrites`. Freed in that window, the holder read and wrote freed memory (the verifier's `r1_destroy_post`: "loops freed while the holder was still inside TLoop.Post: TRUE"; memcheck "Invalid read of size 4 at TLOOP.POST ... inside a block of size 15,936 free'd", 3 errors). Fix (the verifier's suggestion): `Post` counts itself in `TLoop.Posting` (an interlocked increment before the push, a decrement as its last access to the loop); `Destroy` reads it per loop after `Outstanding` and frees the loops only when both are 0 (within the same `WorkerWaitMs`, else the loops leak as before). A `Post` can start only from a holder (counted in `Outstanding`) or a worker (`Shutdown` waited for `FAlive = 0`), so 0 after `Outstanding = 0` means no thread is or will be inside `Post`. `TLoop.Destroy` asserts `Posting = 0`. Builds with assertions get `PostAfterPushHook` (called right after the push). The round-5 test `Server_destroy_waits_for_an_outside_holder` asserted a flag the holder sets after its `Release` returned, which `Destroy` does not order with `Free` (the verifier: unreliable); both holder tests now assert what `Destroy` guarantees: the holder's `Post` happened and was left before `Free` returned. Cost: two locked instructions per cross-thread `Post` (the offload path; the inline path never posts) | a holder's release must not run into a freed loop (S7-10's own contract) |
| S7-38 | 0.3 S7 decision 15, 3.2.3 rule 7, 3.3; `TExchange.TryRead` (unshared path) (S7 fix round 6; contract lens major, design problem 3) | on an unshared exchange a read of a receiver that was closed before the reader saw the end (the request dropped at the call's completion, by `ReleaseRequest` or `DiscardBody`) returned `brEnd`. A response source polled on the loop after the completion can read (hyper's `examples/echo.rs` answers `Response::new(req.into_body())` inline): the verifier's inline echo sent `transfer-encoding: chunked ... 0 CRLF CRLF` for a 10-byte body, a clean end with 0 bytes. Decision 15 exempted the unshared exchange because "an inline handler cannot hold it longer", which is false. Fix (no hot-path cost: only the closed branch changed): the unshared read reports `brCanceled` unless the channel's `Terminated` is set, as `TryReadShared` does; decision 15's text is corrected. The unshared request still goes at the completion (hyper keeps `req.into_body()` alive while the response body lives; wd-40 does that only on a shared exchange): a source that reads the body after the completion holds the request with `Share` in the call's `Poll` and `Release`s it in `Done` (the verifier's `C_inline_echo_shared` echoes the whole body). Smallest change: keeping the unshared request alive after the completion would change the inline dispatcher's drop path, which conformance covers byte for byte. Tests: `Read_after_the_request_was_dropped_is_not_the_end` (unshared: after `DiscardBody` and after `ReleaseRequest` before the end `brCanceled`; after the real end `brEnd`), `Server_inline_echo_needs_share` (through `TServer`: unshared, no terminating chunk and the connection closes; shared, the whole body echoed) | decision 15's rule "a read never returns a clean end of body unless the body really ended" |
| S7-39 | 0.3 S7 decision 16, 3.2.4 (response head); `TExchange.ClaimAnswer`, `DbgHeadClaimOk`, `DbgClaimRefused`, `RespondShared`, `RespondStreamShared`, `FailShared`, `BeginStream`, `HandlerRaised`, `RunHandler`, `Execute` (S7 fix round 6; race lens minor) | (1) In builds with assertions the decision-16 check of a claiming terminal call ran after the claim's CAS and raised with the claim taken: the job's `Fail("handler raised ...")` could not claim, the request was never answered (the client waited until it disconnected) and the `Respond` body was never released (the verifier's `r3_claim_assert`: "client got no response in 3 s (recv -1, errno 11)", "Respond body released: 0 time(s)"). Now a failed check gives the claim back (`FAnswerClaim := 0`) and `ClaimAnswer` returns False; the caller releases its body (or calls its source's `Done`) and then raises (`DbgClaimRefused`, a threadvar flag in `-Sa` builds). The job's own error answers (`RunHandler`, `HandlerRaised`) call `FailShared(Msg, False)`, which skips the check: a failed answer is a user-service error (the dispatcher closes the connection, 2.8) and does not use the head; the program error is in the message (`handler raised EAssertionFailed: ...`). With the fix the repro prints "recv 0" (the connection closed, the user-service error) and "Respond body released: 1 time(s)". (2) `TExchange.Execute` was `RunHandler; Release` without `try/finally`: an exception escaping the job's error path skipped the worker's `Release` (a leaked reference; `TServer.Destroy` then waits `WorkerWaitMs` and leaks the loops). It is `try RunHandler finally Release end` now (one explicit frame per offloaded request, on the worker). Tests: `Claim_refused_by_the_head_check_lets_the_job_answer`, `Job_error_path_exception_releases_the_reference` (`AnswerTestHook` raises in the job's `Fail`); `Terminal_call_by_another_thread_than_the_head` changed: after the loop's refused `Respond` the worker's own `Respond` (the head's builder) answers (round 5 kept the claim taken, so it lost) | a debug check must report the error, not turn it into a hang and a leak |
| S7-40 | 3.2.3 rule 6, 3.6; `TChannelBody.Reset`, `TChannelBody.EmptyWrite` (S7 fix round 6; race lens minors, contract lens minors) | (1) `Reset` cleared the managed string `FAbortMsg` after it released `FLock`, while `AbortWith` (any holder's thread, also `HandlerRaised` on the worker while another holder begins the stream) assigns it under the lock: the two unsynchronized string assignments lost or double-released references (the verifier's `r2_channel`, 2 000 000 iterations under heaptrc: "18581 unfreed memory blocks" and a corrupted heap count; with the fix: "0 unfreed memory blocks"). It is cleared inside the locked section. (2) `EmptyWrite` (a write of 0 bytes) asked only `FActive`, so after `Finish`, `AbortStream` or `Done` (the client went) it returned `wrOk` where a frame gets `wrCanceled`, and on a recycled exchange whose channel an earlier request used `FActive` was still set. It asks `Ended`, as `Push` does. Tests: `Reset_and_abort_race_keeps_the_message_counts` (a thread resets while the test thread aborts with 200 000 distinct strings; each must keep exactly the test's reference; the round-5 code gave 4-56 wrong counts per run, and one run of five hung in the corrupted heap; under drd the race is a reported conflict), `Empty_write_after_the_stream_ended` (`wrOk` on an open stream; `wrCanceled` after `Finish`, after `Done`, after `AbortStream`, and on the reused exchange without a stream) | 3.6: producers get `wrCanceled` once the stream is gone; a lock protects a field only if every write takes it |
| S7-41 | 7.5, 9 S7 exit "drd clean"; `tools/drd.supp`, bearings.rt.sync `AtomicXchg` / `AtomicInc` / `AtomicDec` / `AtomicInc64`, `TLoop.Post` / `RunIteration`, `tools/s7-stress.sh` (S7 fix round 6; race lens design problem 2, gate lens minor) | (1) `tools/drd.supp` suppressed every conflict whose top frame was `TLoop.Post` (`wd-loop-post`), so drd could not report a plain access racing with `Post`. FPC inlines the `Interlocked*` calls, which is why the atomic exchange of `Sleeping` was attributed to `Post` (the entry's comment said it was a frameless routine). `Post` and `RunIteration` now do their atomic operations through bearings.rt.sync routines (not inlined in `-dWD_DRD` builds, covered by the existing `wd-atomic-load-store` entry; release builds get the same locked instructions inline) and the `wd-loop-post` entry is removed: two drd runs of `test_workers` without it reported 0 errors (`build/S7-fix6/drd2/nopost-*.err`); with `Post`'s inlined `Interlocked*` calls (before this change) and the entry removed, a drd run stopped after about 7 minutes had reported 19 conflicts, all at `Post`'s exchange of `Sleeping` (`build/S7-fix6/drd/nopost.out`). The other part of the finding stays as a stated limit: drd reports a conflict at its second access, and the entries for the atomic routines (`wd-atomic-interlocked`, `wd-atomic-load-store`, the lock and parker methods) hide a plain access racing with an atomic word when the atomic access comes second; "drd clean" does not cover those pairs (the file's comment says so now). (2) `tools/s7-stress.sh` documented drd requests "up to 104 s"; the verifier's drd run 3 (seed 316187) had `max_request_ms=115635`. The comment now gives the measured values (116 s for the verifier, 123 s here: `build/S7-fix6/s7-stress`, drd run 3, `max_request_ms=122550`) and says the maximum depends on the load and is reported per run; the 600 s client timeout, about 5 times the largest value seen, is unchanged | the evidence for "drd clean" must say what it covers |
| S7-42 | 9 S7 tests and measurements (S7 fix round 6: the fifth S7 verifiers' findings) | new tests in `test_workers` (78 tests): `Server_destroy_waits_for_a_poster_to_leave_post` (S7-37), `Read_after_the_request_was_dropped_is_not_the_end` and `Server_inline_echo_needs_share` (S7-38), `Claim_refused_by_the_head_check_lets_the_job_answer` and `Job_error_path_exception_releases_the_reference` (S7-39), `Reset_and_abort_race_keeps_the_message_counts` and `Empty_write_after_the_stream_ended` (S7-40), `Read_after_the_end_and_release_is_the_end` (the contract verifier's surviving mutant my9: a read after the real end and a later close is still the end); changed: `Server_destroy_waits_for_an_outside_holder`, `Terminal_call_by_another_thread_than_the_head` (S7-37, S7-39). Each fix has a mutant in `tools/s7-mutants.py` that puts the round-5 code back (`r6-*`, 13 mutants; `r6-reset-abort-msg-unlocked` also as a drd run): every one is detected by its test. The run of round 6 was cut short by the reboot of 2026-10-08 during the inline conformance gate; every check below was run again after it, against the same sources, in `build/S7-fix7/`. Results (2026-10-08): `run_all.sh` passed (`run_all.out`: 900 unit tests, `test_workers` N:78, heaptrc 0 unfreed blocks in the 5 suites, 3 drd runs of `test_workers` 0 errors, the short stress 3 seeds × 2 and 1 drd run passed, conn-diff 122 hand + 10 000 generated 0 different, echo 1 GiB under memcheck 0 errors, `check-hot-asm.sh --s7` passed: 0 `TExchange.Dbg*` routines and 0 `fpc_assert` calls in the production listing). `tools/s7-mutants.py` (`mutants.out`): 89 mutants, 89 detected; the base copy passes the 68 named tests and its drd run (round 6's own run had stopped at a mutant whose snippet the round's edits had changed, `v-respond-shared-no-state-check`; its snippet is the current `FailShared` now). `tools/s7-stress.sh` (`s7-stress.out`, CPUs 6-11): 10 seeds × (normal, server destroyed at 300 ms) all passed with 0 violations, 0 handler or loop assertions, 0 hangs, 0 client errors, every exchange freed, `max_request_ms` at most 220; 3 drd runs 0 errors (`max_request_ms` 51 663, 1 689, 121 847). The verifiers' reproductions against these sources (`r1/`, `contract/`): `r1_destroy_post` 3 of 3 runs "loops freed while the holder was still inside TLoop.Post: FALSE", its cmem build under memcheck "ERROR SUMMARY: 0 errors"; `r2_channel` under heaptrc "0 unfreed memory blocks", EmptyWrite after Done `wrCanceled`; `r3_claim_assert` "recv 0" (the connection closes, the user-service error of 2.8) and "Respond body released: 1 time(s)"; the contract verifier's program: `WriteString(empty)` after Done and after Finish = 2 (`wrCanceled`), read after `DiscardBody` unshared = 5 (`brCanceled`); its `C_inline_echo_unshared` still fails as written, because it accepts only the full echo while its message also allows "the read fails": the unshared echo now fails the read and the connection closes without a terminating chunk (`<EOF>`), and `C_inline_echo_shared` echoes the whole body (S7-38). `tests/web/run_all.sh` (`web_run_all3.out`): every suite passed (`test_web_extra` N:185 E:0 F:0); its `m5-buildcheck` step failed to compile `src/web/wd.web.route.pas` (`Identifier not found "K"`, a file the M5 chain was editing at that moment, not a transport unit); `tools/m5-buildcheck.sh --fx1` run again afterwards passed (`buildcheck.out`). Two earlier web runs (`web_run_all.out`, `web_run_all2.out`) used a relative `OUT_DIR`; with it `test_send_file_rows` makes a symlink whose target is relative to the working directory, which does not resolve (`symlink_outside`); the same binary passes with absolute paths. `gate_worker.sh` debug profile 5 runs (`gate_worker.out`, load 1.11 before, 1.07 after): assertion `passed=103 failed=1` x5 (only `chunk2::pipeline_enabled`), diff `same=103 different=1` x4 and `same=104` x1 (listed), extras `same=27`, probe `passed=0 failed=2` on reference-server and `same=2`; release profile 2 runs (`gate_worker_rel.out`): the same. Inline `gate.sh` RUNS=5 (`gate_inline.out`, load 1.54 before, 21.68 after the cpu-burn runs): assertion 104 x5, diff `same=104` x5, extras `same=27`, 5 diff runs under cpu-burn 16 `same=104`, 0 differences to classify. Offload cost (`bench/run_offload.sh`, `offload.out`, load 16.66 before (the end of the cpu-burn runs), 10.42 after, CPUs 12-15 98-99 % idle after, no client-bound run): c256 d1 2.43 us (6.96 vs 9.39 us per request), c1024 d1 2.92 us (7.18 vs 10.10), limit 5.4. Inline gate (`bench/run_gate.sh`, `gate.out`, load 8.34 before, 8.22 after; an M5 mutant run held CPU 13 at nice 19 after it, the other three 97-98 % idle; no client-bound run): c256 d1 0.944, c256 d16 0.847, c1024 d1 0.969, c1024 d16 0.882 x hyper (req per CPU-second); after round 5 0.946, 0.840, 0.967, 0.877: the inline numbers did not change. Not changed (the race verifier's note): its mutants my1 (`CancelShared` without `DropHolder`) and my2 (a failed `Offload` that keeps the call's holder) change no observable behavior, because after a cancel the transport's release and the last reference's `Recycle` drop the request at the same point; no test can tell them apart from the code | the fifth S7 verifiers' findings; the exit criteria |
| S7-43 | 3.2.3 rules 3 and 7, 3.2.4 `FHolders` row, 3.4, 3.5, S7-5, S7-16; `TExchange.Release`, `TExchange.DropHolder` (S7 fix round 7; sixth S7 verifiers: race lens, two major findings and design problems 1 and 2) | the end of a stream nobody finished (S7-5) is decided by the holder decrement that reaches 0, the one that also drops the request (rule 7): the producers of the exchange's stream are its holders, the references `Share` handed out and the call in flight (hyper: every clone of the channel sender, and the service future until it completes). `DropHolder` at 0 drops the request (`ReleaseRequestShared`) and then calls `AutoFinish` on the exchange's channel (a no-op when it is finished, aborted, dropped by the transport or another request's); `Release` calls `DropHolder` and then decrements the reference count once (`InterLockedDecrement`; the compare-and-swap loop and its decision on the loaded count are gone). The order of S7-16 stays: both happen before the reference goes. A holder count of 0 is final (`Share` raises from 0), so no producer can be added after the decision. Round 6 had two defects. (1) ABA: `Release` decided on the reference count it loaded (2 = itself and the transport) and decremented later with a CAS that compares values only; a helper that loaded 2 before the stream existed (its `AutoFinish` a no-op) and was preempted before its CAS let the count go 2 -> 3 -> 2 (the loop's `Offload`, whose worker began the stream, wrote and released, seeing 3); the CAS then succeeded and nobody ended the stream: the client never got the terminating chunk (the verifier's `r2_autofinish_aba` "RESULT: no end of the body after 3 s"; the delay-injected stress: two hangs in about 260 runs, `s3/b-25-25287-0.err`, `h4/2-5.err`). (2) The call in flight was a holder of the request (S7-32) but not a producer of the stream: a helper `Release` during the call ended the stream while the call could still `Offload` a worker in the same `Poll` (`r1_autofinish`: 1 674 of 2 000 complete chunked bodies without the worker's frames, whose writes got `wrCanceled`). Tests: `Last_producer_is_decided_at_the_holder_decrement` (a new debug-only hook, `ReleaseBeforeDecrementHook`, stops the helper right before its reference count decrement while the loop offloads a worker that streams and releases; before the fix, with the hook at the same window of round 6's code, right before the CAS: "the stream ended with its last producer (got 4)", fpPending; mutant `r7-round6-autofinish-rule-b` puts the round-6 code back and fails it), `Call_in_flight_keeps_the_stream_for_its_next_producer` (the call begins the stream, a helper writes and releases, the call then writes and offloads a worker; before: "the call still writes after the helper released (got 2)", wrCanceled; mutant `r7-round6-autofinish-rule`); `Release_after_recycle_leaves_the_new_stream` extended (the new request shares its exchange too, so a stale holder decrement after the reference went would end its stream: mutant `autofinish-after-decrement` in its round-7 form); `Stream_ends_when_last_producer_releases` and `Stream_two_producers_one_releases` unchanged (mutants `stream-no-auto-finish`, `v-autofinish-at-any-count` in their round-7 form) | the verifiers' design problems 1 and 2: the decision needs a linearization point that no `Share` can undo, and the call in flight can add producers |
| S7-44 | 3.2.3 rule 7 (unshared), 3.4; `TExchange.CompleteCall` (unshared path) (S7 fix round 7; contract lens minor, design problem 3) | an unshared call that began a stream and completed without `Finish` left the response open forever (the verifier's `K_inline_stream_without_finish`: no terminating chunk within 2 s), since nobody may write to an unshared exchange after its completion (rule 2). `CompleteCall` now ends it (`AutoFinish` on the exchange's channel when it has one: one load and compare on the inline path, nil for an exchange that never streamed; the asm check passes). This is hyper's behavior (the future's sender is dropped with the future) and the same rule as the shared case (S7-43). Test: `Inline_stream_without_finish_ends_at_completion` (before: "the completion ended the stream (got 4)"; mutant `r7-unshared-completion-keeps-stream`). `Stream_first_frame_above_high_water` wrote to its unshared stream after `CompleteCall`, which rule 2 forbids; its `CompleteCall` now comes after its `Finish` (what it tests, the first-frame rule, is unchanged) | a stream that can never end; hyper ends it |
| S7-45 | 3.2.3 rule 2, 3.5; `TExchange.Offload` (S7 fix round 7; race lens minor) | a second `Offload` of one request raises `Exception('TExchange.Offload: the request was already offloaded')` before it changes anything, in every build (one compare on the offload path). Before, it overwrote `FHandler`, added a holder and a reference and submitted the exchange, an intrusive work item, again: with the first submission still queued, `TrySubmit` links the item to itself (`FTail.FNextWork := Self`), a cycle in the pool's queue (found by reading the code; the verifier's `K_offload_twice` raised nothing). `TOffloadCall` already offloads once (it checks `FHandler = nil`). Test: `Second_offload_raises` (before: "a second Offload of the request raises" failed; mutant `r7-second-offload-allowed`) | the design defined no second `Offload`; refusing it costs nothing |
| S7-46 | 3.1 `THttpService.Call`; `TExchange.DbgServiceCall` / `FInServiceCall`, `TH1Dispatcher.RecvMsg`, `TExchange.TryRead`, `Respond`, `RespondStream`, `BeginStream`, `Fail` (S7 fix round 7; contract lens minor) | design 3.1 said "must not answer or read the body (debug builds assert)", but no build asserted it: the verifier's `K_call_answers_in_call` was answered from `Call` in a `-Sa` build. Builds with assertions now mark the exchange while `Service.Call` runs (`DbgServiceCall`, a public method that exists only in those builds; the field exists in every build so the layout does not depend on `-Sa`; `BeginRequest` clears it after a `Call` that raised), and `TryRead` (and through it every body read), `Respond`, `RespondStream`, `BeginStream` and `Fail` assert that the mark is off. Release builds contain neither the calls nor the checks. Tests: `Call_that_answers_asserts`, `Call_that_reads_asserts` in `test_h1_dispatch` (before: no exception, the answer was written; mutants `r7-call-not-marked`, `r7-respond-in-call-unchecked`, `r7-try-read-in-call-unchecked`; `tools/s7-mutants.py` builds `test_h1_dispatch` for `DISP:` tests) | the design's own rule, which it stated as checked |
| S7-47 | 7.5, 9 S7 tests; `tests/unit/stress_workers.pas`, `tools/s7-stress.sh` (S7 fix round 7; race lens minors and the finding that the stress could not see S7-43 (2)) | (1) A complete streamed response of mode 7 must hold every frame the worker wrote (`frame1;` .. `frameN;`, N drawn from the seed as the handler draws it), since the stream ends only when its last producer is gone; before, the stress accepted the `wrCanceled` results that hid S7-43 (2). (2) New mode 12, the verifier's repro r1: the call begins the stream, writes `call;`, shares it with a helper that writes one frame and releases at once, offloads the worker that writes its frames without `Finish`, and returns `cpReady` (it answered on the loop, so a Pending call would never be woken); the same check. Against the round-6 sources mode 12 alone (`ONLY_MODE=12`, 16 clients x 150 connections) gave 67, 94 and 106 violations in 3 seeds ("a complete stream without the worker's frame 1 of 8: call;helper1"); with the fix 0. (3) A connection reset (`ECONNRESET`) in a mode that may leave the request body unread (0, 4, 5, 7, 11, 12 with a body) is counted as `reset_with_unread_body`, not as a client error: the server closes such a connection after its response (hyper's drain or close), and closing a socket with unread bytes makes the kernel send a reset that can discard the end of the response that was not yet transmitted (the verifier's three "errno 104 data 0" runs under injected delays). A reset in any other mode, a timeout (hang) and every check of the response stay errors. 13 handler modes (`NMODES`), printed `streams_checked` | the stress must see the defects it is meant to find, and must not fail on hyper's own drain-or-close behavior |
| S7-48 | 9 S7 tests and measurements (S7 fix round 7: the sixth S7 verifiers' findings) | new tests: in `test_workers` (83 tests) `Last_producer_is_decided_at_the_holder_decrement`, `Call_in_flight_keeps_the_stream_for_its_next_producer` (S7-43), `Inline_stream_without_finish_ends_at_completion` (S7-44), `Second_offload_raises` (S7-45), `Post_counts_the_poster_before_the_push` (the verifier's test gap: a new debug-only hook `PostBeforePushHook` runs right before the push and reads `PostsInProgress`; it must be 1; the mutant `r7-post-count-after-push`, the verifier's surviving one, gives 0); in `test_h1_dispatch` `Call_that_answers_asserts`, `Call_that_reads_asserts` (S7-46); changed: `Release_after_recycle_leaves_the_new_stream`, `Stream_first_frame_above_high_water`, the comment of `Stream_ends_when_last_producer_releases`; `TWCase.TearDown` clears `ReleaseBeforeDecrementHook` after the pool's threads were joined (cleared in the test, drd reported the store against the workers' reads in `Release`: 1 error in each of 3 drd runs of `build/S7-fix8/unit`). Before the fix (the round-6 sources plus only the two debug hooks, `build/S7-fix8/before/before.out`) the six new tests of S7-43 to S7-46 failed with the messages quoted there; `Post_counts_the_poster_before_the_push` passes on the current code and fails on its mutant. The verifier's three other surviving mutants (`CloseReceiverFromLoop` without `WakeSender`, `ClaimAnswer` without the state check, `Reset` keeping `FConsumerWaiting`): I read them as the verifier did, equivalent or unobservable (the only caller of the first drops the sender right after; the state CAS that follows the claim refuses a canceled call; the third gives at most one spurious wake), so no test. Not changed: deviation S7-38 (hyper's inline echo needs `Share`), which the verifier lists as a difference from hyper, not a defect. `tools/s7-mutants.py`: 97 mutants (round 7: `r7-*` 8, a `DISP:` test kind that builds `test_h1_dispatch`, several (old, new) pairs in one mutant; the snippets of `stream-no-auto-finish`, `autofinish-after-decrement`, `v-autofinish-at-any-count`, `r6-post-no-count`, `d15-release-keeps-request` follow the round-7 code): the full run (`mutants.out`) detected 96 and stopped on the then stale snippet of `d15-release-keeps-request`, which was fixed and detected in its own run (`mutants-d15.out`); the base copy passes all 75 named tests. Results (2026-10-08, `build/S7-fix8/`): `run_all.sh` passed (`run_all2.out`, load 0.38 before, 1.44 after: 907 unit tests, heaptrc 0 unfreed blocks in the 5 suites, 3 drd runs of `test_workers` 0 errors, the short stress passed, conn-diff 122 hand + 10 000 generated 0 different, echo 1 GiB under memcheck 0 errors, `check-hot-asm.sh --s7` passed with 0 `TExchange.Dbg*` routines and 0 `fpc_assert` calls in the production listing). `tests/web/run_all.sh` all passed (`web_run_all.out`). `tools/s7-stress.sh` (`s7-stress.out`, CPUs 0-5): 10 seeds x (normal, stop) passed, 0 violations, 0 hangs, 0 client errors, every exchange freed, 586-639 streams checked per normal run; 3 drd runs 0 errors (`max_request_ms` 96 496, 1 664, 37 686). Delay-injected runs (`delay/`: the verifier's `inject.py` adapted to the round-7 code, 2 more sites in `DropHolder` and `CompleteCall`, every site hit): `stress3` (the verifier's 18-mode stress) 48 runs as its `s3` batch and 550 runs as its `h4` loop (`RACE_PCT=25`, 32 clients x 60 connections), the round-7 `stress_workers` 72 runs as its `dl` batch: 670 runs, 0 hangs, 0 violations, 0 assertions; the same `stress_workers` against the delay-injected round-6 sources: 6 of 6 runs failed (26 mode-12 violations). The verifiers' repros against the fixed sources (`repro/`, `contract/`): `r1_autofinish` force 3 of 3 "h1;w1;w2;", natural 2 000 requests 0 missing frames, 0 canceled writes; `r2_autofinish_aba` with the hook at the round-7 window "RESULT: the stream ended (0 chunk received)" (control HOOK=0 the same); `test_c6` `TTestK` 8 of 8 passed (`K_inline_stream_without_finish` gets `0 CRLF CRLF`, `K_call_answers_in_call` raises the `TryRead` assertion, `K_offload_twice` raises). `gate_worker.sh` debug profile 5 runs (`gate_worker.out`, load 2.16 before, 3.82 after): assertion `passed=103 failed=1` x5 (only `chunk2::pipeline_enabled`), diff `same=103 different=1` x5 (listed), extras `same=27`, probe `passed=0 failed=2` on reference-server and `same=2`; release profile 2 runs (`gate_worker_rel.out`): the same. Inline `gate.sh` RUNS=5 (`gate_inline.out`, load 8.73 before, 16.33 after the cpu-burn runs): assertion 104 x5, diff `same=104` x5, under cpu-burn 16 `same=104` x5, extras `same=27` (also loaded). Offload cost (`bench/run_offload.sh`, `offload.out`, governor powersave, load 1.46 before, 17.53 after, 0 client-bound runs): c256 d1 2.39 us (6.94 vs 9.33 us per request), c1024 d1 3.19 us (7.49 vs 10.68), limit 5.4; CPUs 12-15 were 96-100 % busy (nice: the Proper pytest job) right after it, so wrk had fewer free CPUs; both cells passed with margin, so the run was not repeated. Inline gate (`bench/run_gate.sh`, `gate.out`, load 15.49 before (the end of the offload run), 10.74 after, 0 client-bound runs): wd40 / hyper c256 d1 0.95, c256 d16 0.85, c1024 d1 0.97, c1024 d16 0.87 (S5: about 0.94 / 0.84 / 0.96 / 0.86): unchanged; VmHWM wd40 4 868 KB, hyper 22 756 KB | the sixth S7 verifiers' findings; the exit criteria |

### T1 (simplify: hyper's features, not its implementation)

| id | where | what | reason |
|---|---|---|---|
| T1-1 | 0.3 assumption 2, 2.1, 2.2, 4.3, 5.2, 7.2-7.5, 8, 9, Appendix A | Retired: conn-diff, the response-encoding and trailer differentials, the diff-mode gates (`same=104`, `classify_diff.py`, `worker_allowlist.py`, the runner's `--settle-ms`), the `BytesMut` port (logical capacities, `reserve_inner`, the Rust table test), `TByteVec`'s copy of `Vec::reserve`, the second write strategy and the decision 7 head entry (H-13, H-14). Kept: the parser, `Server::parse` and decoder differentials, the 105 cases and 25 extra cases in assertion mode (both executors), the reference server and diff mode as a report. New: one write path (copy up to 4 KiB into the cursor, queue larger entries; DV-14), a pooled read block with compaction and reads capped at `max_buf_size - len` (DV-15); the `writev` option has no effect. Deviations marked "no longer needed since T1" above lost their reason with the machinery. Performance, back to back with the tree before T1 (`bench/run_gate.sh`, configuration B, 5 x 30 s, governor `powersave`), wd-40 / hyper per cell, before → after: c256 d1 0.930 → 0.938; c256 d16 0.850 → 0.838 (second pair: 0.844 → 0.843); c1024 d1 0.981 → 0.961 (second pair: 0.986 → 0.978); c1024 d16 0.874 → 0.869. The in-memory dispatcher benchmark (`bench_dispatch`, two runs each) is unchanged: 699.5 / 703.1 → 701.4 / 701.2 ns per request at depth 16. Idle keep-alive connection (10 000, `bench/idle.py`): 1 206 → 1 178 bytes (hyper 10 697). VmHWM under load: 4 876 → 4 744 KB (hyper about 22 700) | user decision 2026-10-08: hyper's features and the performance target stay; its implementation and byte-identical behaviour are no longer goals |

### S8 (sendfile, upgrades API, shutdown, multi-loop conformance)

| id | where | what | reason |
|---|---|---|---|
| S8-1 | 1.11, `TServer.Stop` | `Stop` posts the stop to every loop and returns; `Wait` joins the loop threads and then shuts the worker pool down (`Destroy` calls `Shutdown` again, which does nothing) | `Stop` may be called from a loop thread (a handler, the conformance control task on loop 0), which cannot wait for its own loop |
| S8-2 | 1.11, signals | not automatic: `TServer.RunUntilSignal(Started)` is an opt-in helper (blocks SIGTERM/SIGINT before `Start` so the loop and worker threads inherit the mask, `sigtimedwait`, `Stop(Config.GraceMs)`, `Wait`, restores the mask) | tests and embedders are not forced into signal handling (S8 scope) |
| S8-3 | 1.3, `amSharedExclusive` | every loop registers its own `dup` (`F_DUPFD_CLOEXEC`) of the one listening socket; `TListener` takes its fd out of the loop's epoll set before closing it (`CloseFd`) | an epoll entry lives as long as the open file, not the fd: with one shared fd, the first loop to close it would leave the other loops with a closed fd, and with dups and no `EPOLL_CTL_DEL` the closed loop's entry would keep firing |
| S8-4 | 1.11 | written down: what a client sees during `Stop` (a request the server read gets its full response; a connection with no request byte read when the stop reached its loop is closed without a response, as hyper's `graceful_shutdown` does; the kernel resets connections queued between the last `accept4` and the `close`) | the design named only the accept-queue reset; the stop test checks these outcomes |
| S8-5 | 2.2.4, `TH1Conn.WriteBody` / `WriteBodyAndEnd` | file frames work under every encoder, also chunked: the encoder's framing goes around the `qkFile` entry (`TEncodedBuf.SplitData`, added to the M2 unit `bearings.http1.encode`, cold); a file longer than a `Length` encoder still owes is cut like a memory chunk | a `TBodySource` may return `BodyFile` frames; a user `transfer-encoding: chunked` header makes a known-length body chunked |
| S8-6 | 2.7, `TUpgraded.Detach` | returns False (nothing changed) when the stream's innermost transport is not the `TTcpTransport` on its own source (a test transport); on success it frees the owned transport objects without closing the socket and closes the task; `Taken` added | the fd must be the stream's own to be handed out |
| S8-7 | 3.7, HS6-3 | ownership rule: the handler owns `U` from the call of `Upgraded` on; when `Upgraded` raises and `U` is not `Taken`, `TUpgradeSlot.Deliver` closes `U` and re-raises (one `try/except` per upgrade, cold path); the loop logs and aborts the delivery task as before | the socket and its epoll entry leaked |
| S8-8 | 6.9, `beconf --loops N` | connection numbers and the reply queue are atomic counters (with N > 1 two loops accepting at the same moment may emit their `conn_open` lines in either order); `graceful_shutdown` reaches the other loops with one `lmCall` each, the last loop emits the ack; latches under a lock, a waiting upgrader resumed by an `lmCall` to its loop (it no longer reads the latch set itself). `TServer.GracefulShutdownConnections` is not used there (it blocks until every loop applied it, and loop 0 would wait for itself) | thread safety of the tool's shared state |
| S8-9 | 9 S8 tests | the partial-`sendfile` and `EAGAIN` cases are the io-level tests of step S3 (`test_h1_io`: `File_entry_partial_sendfile_and_eagain` with a 4 KiB `SO_SNDBUF`, `File_entry_between_memory_entries`); `test_server` adds the end-to-end cases (a 32 MiB file to a client that starts reading 300 ms late, pipelined file responses with and without `pipeline_flush`, chunked file frames, fd closed or kept, fd closed when the client resets mid-file) without counting `EAGAIN`s | outcome tests over real sockets cannot see the server's syscall results |
| S8-10 | 1.11, `TServer.Stop` / `RunUntilSignal` | verifier minors fixed: `Stop` claims the stop with `InterlockedExchange` (two threads calling it at once must not post the same intrusive `FStopMsg` twice); `RunUntilSignal` waits with a 200 ms `sigtimedwait` timeout and also returns (result 0) when a `Stop` came from elsewhere, e.g. a handler. Test `Run_until_signal_ends_on_external_stop`. `Detach` is called on the loop thread (stated in 3.7 and `bearings.rt.stream`) | "any thread; a second call does nothing" must hold; an app that stops itself must not hang in `RunUntilSignal` |


### S9 (fuzzing, soak, production profile)

| id | where | what | reason |
|---|---|---|---|
| S9-1 | 7.5 split fuzz; `bearings.http1.role.IsCompleteFast` (hyper role.rs `parse_headers` / `is_complete_fast`) | an invalid request head whose error is visible before its end is answered 400 when it arrives in one read; when it arrives in several reads, it is parsed again only once its bytes hold an end of head (CRLF CRLF or LF LF), so a head without one is never rejected: the client's EOF ends the connection as `incomplete` with nothing written (`ok` when what is left is only CR/LF bytes, which the EOF path drops as leading empty lines). The same applies to which limit wins: a 2 KiB `max_header_size` gives 431 when the buffer reaches it before the end of head arrives, 400 when the read that crosses it also brings the end. The split fuzz accepts this difference only in that shape (`LateErrorEquivalent`: the split run wrote and reported a prefix of the one-read run's output and ended `incomplete`, or `ok` when the input ends with CR or LF, where the one-read run ended with a parse error); the differential fuzz shows hyper giving both outcomes for the same stream (its `timing` class), and `fuzz-diff` recognizes the shape (one side `parse`, the other `incomplete`, same requests, the incomplete side's responses a prefix, and the stream holds no more end-of-head markers, after leading CR/LF, than requests were parsed; also the 431-or-400 limit case) as S9-1; the split fuzz applies the same end-of-head check | hyper does the same (the incremental check is its feature); the outcome depends only on segmentation |
| S9-2 | 7.5 split fuzz; `TH1Conn.OnParseError` (hyper conn.rs `on_parse_error`, `has_h2_prefix`) | the HTTP/2 preface is recognized only when the version error is found with all 24 preface bytes buffered; split so that `PRI * HTTP/2` is parsed earlier, the head is an invalid HTTP/1 version: 400, outcome `parse`, instead of `parse_version_h2` and nothing written. Accepted by the split fuzz in that shape only (`H2PrefaceEquivalent`: input starts with the preface, the one-read run ended `parse_version_h2` with nothing written, the split run wrote one 400 and ended `parse`); hyper gives both outcomes in the differential fuzz | hyper does the same |
| S9-3 | 7.5 differential fuzz; 2.6 half-close | a client that half-closes right after a complete request, with `half_close` off: if the FIN is there when the server reads the request, the request is dropped (`handler_dropped`, `incomplete`, no response); if it comes a little later the request is answered. Both servers do both (a probe: 20 connections each sending `GET / HTTP/1.1` + Host and `shutdown(SHUT_WR)` at once: reference 15 answered / 5 dropped, beconf 3 / 17; with an obs-text header value 12 / 8 and 19 / 1). In the fuzz's timing (two client threads, the FIN a few microseconds after the data) hyper usually sees the FIN first and wd-40 usually answers first, so the same stream can give the two outcomes 10 times in a row; `fuzz-diff` recognizes this shape (one side dropped the last request, the other answered it, same requests, earlier responses equal) as `S9-3` | a race between the client's FIN and the server's read, decided by how fast the server reads after the data arrives; no feature differs |
| S9-4 | 7.5 differential fuzz, comparison | per stream: the responses (status, header fields without `date` and without their order, body), bytes after the last complete response, whether the connection was closed for the client (EOF and reset count as closed: a reset only says the server closed with unread client bytes, which depends on timing) or still open after 100 ms without data, and the server's events of the connection without `message`/`detail`, `bytes_read` and `conn_open`, with header and trailer fields sorted by name (hyper's `HeaderMap::remove` of a content-length next to transfer-encoding moves the last field into the removed slot) and the request target turned back into bytes (reference-server writes `uri().to_string()`, the target as UTF-8 text, where SPEC 2 asks for latin-1; beconf writes latin-1). A stream that differs runs 9 more times on both servers: when some run of one server equals some run of the other (or a documented deviation explains the pair), the stream is `timing` (segmentation or FIN races; the first 200 are written as `timing-<n>.json`), else a `difference` (`fail-<n>.json`). A stream is `timing` only when every wd-40 run's outcome equals some hyper run's (or a documented deviation pairs them); a wd-40 outcome never seen from hyper is a difference. Known deviations recognized by the tool, each in an exact shape: S9-1, S9-2, S9-3, S9-11 and S6-15 (with `pipeline_flush`, hyper drops every response left in its write buffer, 200s and 100 Continue included, when the connection ends while unparsed bytes remain in its read buffer; wd-40 flushes them: recognized only when the events and end are the same and wd-40's extra responses are exactly the events' `handler_done` statuses plus the outcome's automatic 400/431/414) | T1: outcomes, not bytes or timing |
| S9-5 | 7.5 split fuzz | the transport is `bearings.test.scriptio.TScriptIo` (records what is written, scripts only the answers), not `TMockTransport`, which asserts the exact bytes of every write and cannot be scripted without knowing the output. The inputs are the client bytes of each named connection of each case (its `write` steps concatenated; `${port}` = 80), served with the case's spec through the conformance server's own handlers in-process (`beconf.service.TConfService`, inline; events collected through the new `beconf.events.EventHook`); every `delay_ms` removed and a numeric `header_read_timeout_ms` set to 600 000 (a run must not depend on time); the 11 cases with an `upgrade` reply or `pending` skipped (the upgrade task needs a socket). The other steps (reads, sleeps, control, half-close) do not exist in-process: the input is delivered, the connection driven until it has nothing to do, then the client's EOF. Documented exceptions: only `EH1Panic` (hyper's panics, 2.8; a handler's HTTP/0.9 or HTTP/3.0 response version), handled as the loop would (task aborted) and compared like any outcome | the design named the mock; the fuzz needs a transport that accepts any output |
| S9-6 | 7.5, 9 S9 (user decision 2026-10-09) | the soak runs 2 hours, not 24; the 100 000-stream differential run is done once for the S9 exit, not nightly (`conformance/fuzz-diff/run.sh` defaults to 10 000 streams for routine runs) | user trims |
| S9-7 | 2.4.5 stall detector (it did not exist before S9); `bearings.server` (`StallReports`, `StallTimerProc`), `TH1Dispatcher.LastRunMs` / `StallCandidate` | implemented for builds with `-dWD_STALL` only (the soak build), not for every `-dWD_DEBUG` build: each loop arms a 1 s timer (before its thread starts) that scans its connections and reports on stderr, once per connection, one that is mid-message (state not idle, or read bytes buffered, or response bytes not flushed), has no header read timer armed and has not run for 60 s; `StallReports` counts the reports. Checked once (`build/m3/S9/stallcheck/`): a POST whose body stops for 64 s gave one report after 60.5 s ("reading 2, writing 0"), and the request was answered when the body came; by the design's definition a client that stops in the middle of a body for 60 s is reported too, so the soak's chaos client pauses at most 0.5 s per piece | a 1 s timer in every loop changes the idle behaviour (epoll timeouts, idle block trim) that the debug-build unit tests observe; the soak is where a stall would show |
| S9-8 | 7.5 soak | the soak server is a wd-40 web app (`bench/soak_app.pas`: `TApp` on `ProductionServerConfig`, i.e. `ProductionH1Config`; inline route, worker routes, a body-reading worker route, `SendFile`, `Router.Static`), built with `-Sa -dWD_DEBUG -dWD_STALL`. The load uses `wrk` for both keep-alive and pipelined traffic, throttled with `delay()` (4 ms per connection between requests or batches), because `build/tools/bin/wrk2` stops at start with a Lua PANIC; the chaos client (`bench/soak_chaos.py`) runs at most 3 slow request bodies at a time (an open question for the user: soak_app reads request bodies on its 8 workers, blocking, so 48 concurrent slow bodies starved the worker routes of the wrk load: 240 pipelined requests in 5 s instead of 577 000) | the user asked for the real stack; wrk2 unusable here |
| S9-9 | 7.5 slow clients | the client is Python (`bench/slowclient.py`, one thread, non-blocking sockets, one byte per connection per 100 ms tick); the server is `soak_app` built `-O2` on `ProductionServerConfig`; "CPU per byte flat" is checked as the server's CPU time per byte received in the last third of the heads at most 1.5 x the first third; the header timer check is a second phase whose heads never end | the design gave no method |
| S9-11 | 7.5 differential fuzz; `TH1Dispatcher` end of connection | a request with `Expect: 100-continue` whose body read fails at the client's EOF (half-close, body never sent): whether the `100 Continue` reaches the client before the close is a race on both servers (the S9 verifier, 10 connections each: hyper sent it on 6, wd-40 on 9; events identical, outcome `user` on both). Seen once in 100 000 streams; recognized only in that shape (same events and end, outcome `user`, wd-40's responses are hyper's plus one 100) | the interim response is harmless; the connection fails in both |
| S9-10 | `conformance/pascal-server/beconf.events.pas` | `EventHook`: when set, `EmitLine` hands the line to it instead of writing stdout (the split fuzz links the conformance handlers in-process); unset in `beconf` | reuse of the conformance handlers |

### UB (body rate rule, stall detector; 2026-10-10)

| id | where | what | reason |
|---|---|---|---|
| UB-1 | 2.5; `bearings.http1.conn` `PollReadBody` | a request body rate rule hyper does not have (`BodyReadTimeoutMs`, `BodyMinRate`): a body whose one wait for bytes reaches the limit, or whose average rate over its waiting time is below the minimum after the first `BodyReadTimeoutMs` of waiting, fails with `NewBodyIo(ETIMEDOUT)` (outcome `io`). Only time in which the server waits for body bytes counts (a wait starts when `PollReadBody` finds no byte, which happens only while the receiver has room). The transport does not answer: the receiver gets the body error and answers (M5: 408); reading is closed, so the connection closes after that response, or after the response already under way. Off in `ConformanceH1Config` (conformance and `gate.sh` unchanged), 30 s and 1 KiB/s in `ProductionH1Config` | the user's decision of 2026-10-10 (S9-8): a slow upload must not hold a worker for ever; nginx's `client_body_timeout` is a wait limit only, the rate part stops a client that sends a byte just before each limit |
| UB-2 | `bearings.http.exchange` | `TExchangeAttachment` and `TExchange.Attachment`: per-request service state the transport detaches on the loop thread at `Recycle` (after the last reference) and at `BeginRequest`; `BodyErrorIsTimeout` | M5 9.8 frees a buffer a worker read only after the worker is done, on the loop (the budget is loop-thread state) |
| UB-3 | 2.4.5 stall detector (S9-7) | reports only connections where the server owes progress: not one whose last `Pending` came from a read or write `EAGAIN` while no call was in flight (or the call waited for body bytes), no body chunk waited for its receiver, no response source was pending and the task was not woken; reported anyway when the task is queued or a readiness event for the side it waited on came and the task did not run. `-dWD_STALL` needs `-dWD_DEBUG` (it reads the wake-source flags); `test_h1_dispatch` is built with both (`TTestDispatchStall`) | the user's decision of 2026-10-10: S9's detector counted a client that stops for 60 s as a stall, so the soak capped the chaos client's pauses at 0.5 s (S9-7); the cap and the 3-slow-bodies limit (S9-8) are gone |
| UB-4 | 2.4.5, 3.3 | a request waiting for the M5 body budget (only a request that holds no reserved bytes ever waits, M5 9.8 after the UB fix round B1) does not take its body chunk, so the transport does not read its socket and does not see its client go away (hyper's dispatcher does not read for a receiver that is not ready either); it is closed when its turn comes (M5 9.8). Such a wait is server-side, so the stall detector reports it after 60 s ("a body chunk waits for the receiver") | the budget's backpressure is the point; the request holds no memory meanwhile |

