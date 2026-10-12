# Handoff: rewrite the design document

Written 2026-10-11 for a later session. The work has not started. Read this
whole file before changing anything.

## 1. Goal

Replace `docs/design/m3-transport.md` (3 832 lines) with a design document
of the library as it is: the decisions and their reasons, the invariants a
contributor must respect, and the deviations from what an HTTP library
would usually do. Target length: a quarter of the current one or less.

Keep `docs/design/m3-perf-report.md` as it is: it is the only record of the
measured numbers and of how they were measured, and the README, `docs/api.md`
and `docs/handoff-operations.md` cite it.

Delete `docs/design/m3-candidates/` (three design proposals compared before
the current design was chosen; the chosen one is the current design) and
`docs/design/m3-verify/` (verification verdicts of early implementation
steps). Nothing references them. Decided by the user on 2026-10-11.

## 2. Why

The current document was written in October 2026 inside the wd-40 project,
before the code existed, as a plan for porting hyper (a Rust HTTP library)
to Free Pascal step by step. Three things make it a poor design document
for bearings today:

1. It describes a port of another library. Section 2 is titled "Connection
   state machine: port of io.rs, conn.rs, dispatch.rs", 1.4 "epoll mode and
   readiness (tokio rules)", and Appendix A maps hyper names to Pascal
   names. The user decided on 2026-10-08 that bearings reproduces hyper's
   features and performance, not its implementation; the code comments were
   rewritten on that basis on 2026-10-11 (no mentions of other projects or
   of project history), and the design document should match them.
2. A quarter of it is history: section 9 "Implementation plan" (steps
   S0-S10, H, T1, UB with their exit criteria and fix rounds) and the
   "Deviations log" organized by step. Eight test files and `tools/drd.supp`
   cite sections of it by number (see section 5 below), which pins the
   current structure in place.
3. Parts are stale after the extraction: 8.1 lists files under
   `/home/jps/Code/wd-40/src/`; 3.8 describes the wd-40 framework layer,
   which is a separate project now; 0.2, 0.3 and 0.4 record assumptions,
   open questions and a review of design candidates that were resolved
   months ago.

## 3. Context

- bearings: `/home/jps/Code/bearings` (Free Pascal 3.2.2, Linux x86_64).
  Layers `src/rt`, `src/http1`, `src/http`, `src/server`; units named
  `bearings.<layer>.<name>`. The unit headers are the most accurate
  description of each part and were written for readers who know Free
  Pascal but not web servers; `docs/api.md` is the user-facing API guide;
  `README.md` has the overview and a hello world.
- The code is the source of truth. Where the current design document and
  the code disagree, the code wins; say what the code does. The code
  comments were checked against the code on 2026-10-11; the design
  document was not.
- Style rules for the new document: plain, direct sentences; no metaphors;
  no mentions of other projects except where a comparison truly helps
  (for example "a reverse proxy such as nginx" or a one-line note that the
  conformance harness compares against hyper's reference server, which is
  a fact about the test tooling); no step names, round numbers, dates of
  changes or reviewer verdicts; RFC references and Linux system call names
  are good.

## 4. What the new document should contain

Suggested shape; adjust it to the code. Each section should say what the
design is and why, and name the units and types that implement it.

1. **Purpose and scope.** What bearings is (event loop + HTTP/1.1 server
   library + worker pool), what it is not yet (TLS, HTTP/2, WebSocket; link
   the handoffs), and the platform limits (Linux x86_64, epoll, raw system
   calls).
2. **Threading model.** One event loop per CPU, a connection lives on the
   loop that accepted it for its whole life, loops never block, blocking
   code runs on the worker pool, how a worker answers (the exchange is
   shared, the loop is woken through its inbox). Which thread may call
   what. Sources: current 1.1-1.7, 1.10, 3.5, 3.6 and the unit headers of
   `bearings.rt.loop`, `bearings.rt.workers`, `bearings.rt.sync`.
3. **Readiness and I/O.** Edge-triggered epoll for connections, level for
   listeners and the eventfd, the readiness bits and when they are
   cleared, the accept batch and the pause after EMFILE, the three listener
   modes. Sources: 1.3, 1.4, `bearings.rt.net` header.
4. **Timers and the clock.** The wheel, the cached clock, the Date header
   through the loop's tick hook (note: this changed at the extraction;
   `src/rt` no longer depends on the HTTP units). Sources: 1.8, 1.9 and
   the unit headers, which are more current than the document.
5. **Connection state machine and the request path.** Reading a head,
   framing (Content-Length, chunked, trailers), keep-alive, pipelining with
   one call in flight per connection, 100-continue, upgrades, the automatic
   400/414/431 answers, timeouts (header timeout, body rate rule), graceful
   shutdown of a connection. Write the behaviour, not the port rules: drop
   2.1 ("Port rules and shared types") and every "io.rs:231-268" style
   reference. Sources: 2.2-2.9 and the headers of `bearings.http1.conn`,
   `bearings.http1.io`, `bearings.http1.dispatch`.
6. **The exchange and the service API.** The one-terminal-call rule, the
   request body channel and its backpressure, response bodies (the five
   constructors and who owns memory and descriptors), streaming, shared
   exchanges and the two reference counts, cancellation, the observer
   hooks. Sources: 3.1-3.7, 3.9 (keep the HTTP/2 fit as a short forward
   note), `docs/api.md` (do not duplicate it: the design document says
   why, the API guide says how).
7. **Memory.** Ownership rules, zero-copy slices and their lifetimes,
   pooling, why there is no reference-count traffic and no implicit
   exception frame on the hot path, the per-request allocation budget.
   Sources: section 4; keep most of it, it is design, not history.
8. **Header validation.** The validation boundary (CR/LF/NUL) and why
   framework constants may bypass it. Source: 5.1.
9. **Verification.** What exists and what each proves: the unit suites,
   heaptrc and drd, the conformance harness (105 wire cases against a
   reference server, assertion mode, the one documented exception), the
   split fuzz and the differential stream fuzz, the slow-client test, the
   soak, `tools/check-hot-asm.sh`, the performance gate. Sources: 6
   (condense: the conformance server implements `conformance/SPEC.md`,
   which is the real specification; the design document needs only how it
   is used), 7.1-7.6. State the current test counts from the current tree,
   not from the old text.
10. **Deviations register.** One table: every place where bearings behaves
    differently from what RFC 9110/9112 or common servers would lead a
    reader to expect, with the reason. Build it from the current
    "Deviations log" (3 595-3 832) and 8.2, but reorganize by topic, not by
    step, and drop entries that record a past bug fix rather than a current
    behaviour. Keep the entries that name a difference from the reference
    server's behaviour only where the difference is observable (for
    example S6-15: the reference server drops a buffered 400 under
    pipeline_flush; bearings writes it).
11. **Risks and known limits.** From 8.3 and from the handoffs: x86-64
    memory ordering assumed by the lock-free code (an ARM64 port must
    review it), Linux-only, no TLS, the depth-16 throughput gap (see the
    perf report), the stall detector only in debug builds.

Leave out entirely: 0.2-0.4 (resolved assumptions, judges' review), 2.1,
3.8 (the framework layer; it is another project), 8.1 (file list under a
path that no longer exists; the README's layer table replaces it), section
9 (the plan), Appendix A (the hyper-to-Pascal name map), and the
step-by-step deviations log once its content is in section 10.

## 5. References that pin the old section numbers

These cite `m3-transport.md` sections by number in comments or headers.
Update each to the new document's section names (or drop the reference
where the comment stands on its own):

- `tests/unit/test_exchange.pas:2` (3.1-3.4, 3.7, 4.2, 4.5, 7.3)
- `tests/unit/test_rt_timer.pas:1` (1.8)
- `tests/unit/test_server.pas:1` (1.3, 1.11, 2.2.4 DV-5, 2.7, 3.7)
- `tests/unit/stress_workers.pas:1` (9 S7, 7.5)
- `tests/unit/test_h1_io.pas:1` (2.2.2-2.2.4, 7.2)
- `tests/unit/test_rt_echo.sh:3` (section 9, S1)
- `tests/unit/test_split_fuzz_cases.py:3` (7.5)
- `tools/drd.supp:2`
- `README.md:162`, `docs/api.md:842`, `docs/handoff-websocket.md:36-37`,
  `docs/handoff-operations.md:45` (these cite the two documents by file
  name; keep the perf report citations, update the design document ones).

Also grep the whole tree for `m3-transport`, `design [0-9]`, `DV-`, and
step names (`S[0-9]`, `T1`, `UB`) in comments after the rewrite; the code
comments were already cleaned on 2026-10-11, so hits should be in tests,
tools and docs only.

## 6. Procedure

1. Delete `docs/design/m3-candidates/` and `docs/design/m3-verify/` (one
   commit).
2. Write the new document as `docs/design.md` (one file at the top of
   `docs/`, next to `api.md`), from the code, the unit headers and the
   sources listed above. Check every type and routine name against the
   code (grep); check every behavioural statement against the code, not
   against the old text.
3. Update the references of section 5 and the README's documentation
   section. Remove `docs/design/m3-transport.md`. Move
   `docs/design/m3-perf-report.md` to `docs/perf-report.md` and update its
   citations, or leave it where it is; say which.
4. Verify: `tests/unit/run_all.sh` once (comment-only changes to tests
   must still compile and pass; `build/tools/bin/valgrind` exists), and a
   grep that no identifier the new document names is missing from the
   code.
5. Commit (one for the deletion, one for the new document and the
   reference updates), each message ending with
   `Claude-Session: https://claude.ai/code/session_012uykENRJLVqeYkz8sJok8V`.
   Do not push unless the user asks.

## 7. Working rules (from the user)

- Plain, direct sentences; no metaphors. State assumptions; ask when
  something is unclear.
- Do not push anywhere without being asked. Commit after each verified
  step.
- Never run a program that is meant to crash; prefix test runs with
  `ulimit -c 0`; pin with `taskset -c 8-15 nice -n 19`; run each suite
  once, at the end.
- The compile flags keep the `WD_` prefix (`WD_DEBUG`, `WD_STALL`,
  `WD_DRD`).
- Do not modify `/home/jps/Code/wd-40` or any Proper checkout.

## 8. Open questions

None about the content: the user asked for this rewrite on 2026-10-11 and
approved deleting the two directories. Ask only if the code contradicts
something in this file, or if the new document would need to be much longer
than a quarter of the old one to stay accurate.
