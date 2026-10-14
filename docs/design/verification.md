# 9. Verification

**Unit suites** (`tests/unit/run_all.sh`, built with `-Sa -Cr -Co -Ct`):
`test_parser`, `test_codec`, `test_role`, `test_headers_validate`,
`test_rt_sys`, `test_rt_timer`, `test_rt_loop`, `test_rt_net`,
`test_rt_readbuf`, `test_h1_io`, `test_h1_conn`, `test_body_chan`,
`test_exchange`, `test_h1_dispatch` (built with `-dWD_DEBUG -dWD_STALL`, so
the wake-source check runs in every test), `test_workers`, `test_server`,
`test_server_ops` (real sockets through `TServer`), `test_ws_frame`,
`test_ws_handshake`, `test_ws_conn` and `test_ws_echo` (a WebSocket echo
server on real sockets). The script prints the total (`unit tests run: N`;
1089 at the time of writing). The suites that own memory across threads
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
heads (plus httparse's own test inputs when its source is present) are
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

**Differential tests** against the Rust originals, run from their own
scripts: `tests/unit/test_parser_diff.sh` (the parser against httparse
1.10.1), `test_role_diff.sh` (request-head parsing and URIs against hyper's
own `Server::parse` and `http::Uri`), `test_codec_diff.sh` (the body decoder
and the header helpers against hyper's `decode.rs` and `headers.rs`). All
three run once more with the input against a `PROT_NONE` guard page, so a
read past the input faults: the parser and codec diffs at its end and at its
start, the role diff at its end. They cover request acceptance and framing,
which is what request smuggling depends on; response encoding is checked by
fixed expectations.

**The conformance harness** (`conformance/`): `SPEC.md` is the contract
between the case files (hyper's 105 HTTP/1 server tests ported to data,
`cases/h1/*.json`), the runner (the client, in Rust) and a conformance
server; `reference-server` is hyper itself. The Pascal conformance server
(`conformance/pascal-server/beconf`) is a thin wrapper around
`bearings.server`: everything on the wire comes from the library, the
wrapper only configures the connection from the spec, installs the named
handler and reports events. `conformance/pascal-server/gate.sh` runs the
cases in assertion mode, four cases at a time (`JOBS`), once by default
(`RUNS=5` before a commit catches intermittent failures), and requires
`passed=104 failed=0 pending=1` every time (one case is pending by design in `MANIFEST.md`), then
the 25 extra cases of `extra/extra-cases.json` (behaviours the 105 do not
reach); `LOOPS=4` runs the same with four loops sharing one listener.
`gate_worker.sh` runs it with every handler on a worker; one case,
`chunk2::pipeline_enabled`, is allowed to fail there
(`worker-exceptions.txt`): its wire assertion needs the second handler to
answer in its first poll, which no worker handler does, and the script
proves each run that the reference server fails the same assertion when its
handler is pending (`extra/worker-probe.json`). The runner's diff mode
against the reference server is a report, not a gate: byte-identical write
segmentation and event timing are not goals.

**The differential stream fuzz** (`conformance/fuzz-diff/`, Rust): generated
request streams (a grammar plus mutations of the case corpus and httparse's
corpus) with random write splits, gaps and half-closes are sent to the
reference server and to `beconf` under the same spec, and compared per
request on acceptance, status and body, the end of the connection and the
server events; a stream that differs is replayed nine more times on both,
and counts as a difference only when some bearings outcome was never seen
from the reference server. The known deviations of section 10 are recognised
in their exact shapes. `run.sh` runs 10 000 streams by default.

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
