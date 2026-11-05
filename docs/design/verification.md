# 9. Verification

**Unit suites** (`tests/test_unit_suites.py`, built with `-Sa -Cr -Co -Ct`):
`test_parser`, `test_codec`, `test_role`, `test_headers_validate`,
`test_rt_sys`, `test_rt_timer`, `test_rt_loop`, `test_rt_net`,
`test_rt_readbuf`, `test_h1_io`, `test_h1_conn`, `test_body_chan`,
`test_exchange`, `test_h1_dispatch` (built with `-dWD_DEBUG -dWD_STALL`, so
the wake-source check runs in every test), `test_workers`, `test_server`,
`test_server_ops` (real sockets through `TServer`), `test_ws_frame`,
`test_ws_handshake`, `test_ws_conn` and `test_ws_echo` (a WebSocket echo
server on real sockets). Every test method is a pytest subtest (about
1100 of them). The suites that own memory across threads
(`test_h1_conn`, `test_body_chan`, `test_exchange`, `test_h1_dispatch`,
`test_workers`, `test_server`, `test_server_ops`, `test_ws_conn`,
`test_ws_echo`) run once more under heaptrc (`-gh`) and must report 0
unfreed blocks. `test_workers` also runs three times under
`valgrind --tool=drd` (built with `-dWD_DRD` and the C heap, with
`tools/drd.supp` and `--fair-sched=yes`) and must report 0 errors, and so
do the WebSocket worker-handler and topics suites (`test_ws_echo
--suite=TTestWsWorker` and `--suite=TTestWsTopics`, once each, with
`WD_ITER=20`, the C heap too); what the suppressions hide and what "drd
clean" does not cover is stated in that file. The test doubles are `tests/support/bearings.test.mocktransport`
(scripted reads and exact expected writes), `bearings.test.scriptio`
(scripted answers, recorded writes, for the dispatcher and the fuzz) and
`bearings.test.ws` (masked client frames, a log of `TWsReader` events, a
reader of server frames).

**The worker stress** (`tests/unit/stress_workers.pas`, `tools/s7-stress.sh`):
a server with 16 workers, 24 client threads, 13 handler modes (answer before
or after reading the body, stream while reading, a second holder, random
disconnects and resets, pipelining); it checks that a handler never sees a
clean end of a body that did not end, never sees wrong bytes, that nothing
hangs and that every exchange is freed; it runs natively, once more with the
server destroyed under load, and under drd.

**The echo test** (`tests/unit/test_rt_echo.sh`) moves 1 GiB through a
`TLoop`, a `TListener` and a `TTcpTransport` with random read and write
sizes, the server under valgrind memcheck with the C heap (valgrind sees
nothing inside FPC's own heap) and 0 errors required.

**The split fuzz** (`tests/unit/test_split_fuzz.pas`, in process): every
conformance case input without an upgrade reply and 20 000 generated request
heads are
served by the real dispatcher and the conformance server's handlers over a
scripted transport, once in a single read and then in random pieces with
random `EAGAIN` and partial writes: each of 2 000 seeds runs every case
input, in the case's profile and in `ProductionH1Config`, and 20 corpus
entries drawn by the seed, and every corpus entry also runs once with its
index as the seed; the bytes written, the events and the outcome must be
equal, no task may abort, every block must be back in the pool, and heaptrc
must report no leak. Two shapes are accepted as equivalent because they
depend only on segmentation (section 10): an invalid head without an end of
head, and an HTTP/2 preface split before its 24th byte.

**The hot-path check** (`tools/check-hot-asm.sh --s7`, section 7.4) runs
last.

**Expected-value tests** (`tests/test_golden.py`, in the fast tier):
the parser over 136 942 generated inputs (`test_parser_corpus.py`, 50 000
of them random, seed 1; the script checks the corpus's SHA-256), request-head
parsing and URIs over 41 000 cases, the body decoder over 10 000 cases and
the header helpers over 20 000. Each driver prints one result line per case,
and the lines must equal the files in `tests/golden`. Every driver runs once
more with its input against a `PROT_NONE` guard page, so a read past the
input faults: the parser and codec at its end and at its start, the role
test at its end. They cover request acceptance and framing, which is what
request smuggling depends on; response encoding is checked by the fixed
expectations of the unit suites.

The expected values were frozen on 2026-11-04 from the Rust originals:
httparse 1.10.1 for the parser, hyper v1.12.0's `Server::parse`,
`http::Uri`, `decode.rs` and `headers.rs` for the others. Bearings matched
them on every case except where it differs from hyper on purpose (section
10: `Host`, a bare LF in the trailer section); each of those differences was
checked against its rule before it was frozen. Until then these were
differential tests that ran hyper and httparse next to the Pascal code;
they were replaced because a difference from hyper had become a reason to
investigate, not a defect (the bare-LF trailer bug was in hyper too, so the
differential test could not see it). After an intended change of
behaviour, `UPDATE=1 pytest -m golden` lists every line that
changes and rewrites the expected files.

**The conformance harness** (`conformance/`): `SPEC.md` is the contract
between the case files (hyper's 105 HTTP/1 server tests ported to data,
`cases/h1/*.json`; the expected values in them are hyper's behaviour, with the
deviations of section 10), the runner (the client, a Python program of the standard library that shares no code with the server) and a conformance
server. The Pascal conformance server
(`conformance/pascal-server/beconf`) is a thin wrapper around
`bearings.server`: everything on the wire comes from the library, the
wrapper only configures the connection from the spec, installs the named
handler and reports events. `tests/test_conformance.py` runs the
cases in assertion mode, four cases at a time (`JOBS`), once by default
(`RUNS=5` before a commit catches intermittent failures), and requires
`passed=101 failed=0 pending=1` every time (one case is pending by design in `MANIFEST.md`), then
the 23 extra cases of `extra/extra-cases.json` (behaviours the 105 do not
reach); `LOOPS=4` runs the same with four loops sharing one listener.
The same test runs them with every handler on a worker; one case,
`chunk2::pipeline_enabled`, is allowed to fail there
(`worker-exceptions.txt`): its wire assertion needs the second handler to
answer in its first poll, which no worker handler does; the probe cases of
`extra/worker-probe.json` show the same failure with a pending inline
handler (hyper's reference server failed them the same way while it was
part of the harness, until 2026-11-04). Byte-identical write segmentation
and event timing are not goals.

**The performance gate** (`bench/run_gate.sh`): `bench/plaintext.pas` against
`bench/hyper-tfb` (hyper in its TechEmpower configuration), both with 4
loops pinned to CPUs 0-3 and wrk on CPUs 4-15, four cells (256 and 1 024
connections, pipeline depth 1 and 16), 5 alternating runs of 30 s per
server, the median of the runs whose wrk CPUs were under 90 % busy
(`bench/compare.py`); the response bytes of the two servers are compared
with `cmp` first. Gate: every cell at or above 0.80 of hyper's requests per
second. `bench/run_offload.sh` measures the offload cost (limit 5.4 us per
request); `bench/bench_role.pas`, `bench_conn.pas` and `bench_dispatch.pas`
are the micro-benchmarks; `bench/p99.sh`, `idle_rss.sh` and `syscalls.sh`
measure latency, idle memory and system calls per request. The soak and slow-client tools that
produced the stall detector's evidence are not in this repository, and their
results are not recorded in it.

**WebSocket.** Besides the four unit suites, `conformance/autobahn/run.sh`
runs the Autobahn TestSuite (fuzzingclient mode, in Docker) against
`examples/ws_echo.pas` and exits non-zero when a case has the result
`FAILED`; it is run by hand and is not a gate. `bench/ws_bench.pas` is the
WebSocket echo benchmark client.

**Debug build flags** ([API guide](../api/debug.md), section 12): `-Sa` (the threading and
no-response checks, poisoned head views, the encoder assertions),
`-dWD_DEBUG` (the wake-source check, poisoned pool blocks), `-dWD_STALL`
(the stall detector, needs `WD_DEBUG`), `-dWD_DRD` (drd annotations).
