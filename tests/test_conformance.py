"""The wire conformance gate (conformance/SPEC.md; docs/design.md section 9):
the cases of conformance/cases and the extra cases against the Pascal
conformance server beconf, in assertion mode, each case a subtest.

- inline executor: the 102 cases must give passed=101 failed=0 pending=1
  (one case is pending by design, MANIFEST.md), RUNS times in a row (default
  1; RUNS=5 before a commit catches intermittent failures), JOBS cases at a
  time (default 4: the 9.2 s header-read timeout case then sets the run
  time); then the 23 extra cases (behaviours the 102 do not reach);
- LOOPS=4 runs the same with `beconf --loops 4` (four loops sharing one
  listener; the 7.4 gate is LOOPS=4 RUNS=3);
- worker executor (`beconf --executor worker`): the same, except that a
  case listed in pascal-server/worker-exceptions.txt may fail (only
  chunk2::pipeline_enabled: S7 decision 14); the output names the exception
  whenever it was used; and the evidence for the exception
  (extra/worker-probe.json): both probe cases must fail.

PROFILE=debug (default: -Ci -Cr -Co -Ct -Sa -gl -dWD_DEBUG) or release (-O2
-gl, the production code path) selects the beconf build. Logs:
build/conformance/.
"""

import os
import shlex
import sys
from pathlib import Path

import pytest
from harness import HOST_FPC, ROOT, fpc_build


def crun():
    """The case runner (conformance/runner/crun), imported when first needed."""
    sys.path.insert(0, str(ROOT / "conformance/runner"))
    import crun
    return crun


pytestmark = [pytest.mark.full, pytest.mark.conformance, pytest.mark.hostonly]

CONF = ROOT / "conformance"
PS = CONF / "pascal-server"
OUT = Path(os.environ.get("OUT_DIR", ROOT / "build/conformance")).resolve()
RUNS = int(os.environ.get("RUNS", "1"))
JOBS = int(os.environ.get("JOBS", "4"))
LOOPS = os.environ.get("LOOPS")
PROFILE = os.environ.get("PROFILE", "debug")
PROFILE_FLAGS = {
    "debug": ["-Mobjfpc", "-Sh", "-O2", "-gl", "-Ci", "-Cr", "-Co", "-Ct", "-Sa", "-dWD_DEBUG"],
    "release": ["-Mobjfpc", "-Sh", "-O2", "-gl"],
}
CASES = CONF / "cases/h1"
EXTRA = PS / "extra/extra-cases.json"
PROBE = PS / "extra/worker-probe.json"
WANT_CASES = (101, 0, 1, 102)
WANT_EXTRA = (23, 0, 0, 23)
WANT_PROBE = (0, 2, 0, 2)


@pytest.fixture(scope="module")
def beconf() -> str:
    """The conformance server command (built once per module)."""
    binary = fpc_build(PS / "beconf.lpr", OUT, OUT / f"units-{PROFILE}", PROFILE_FLAGS[PROFILE],
                       extra_units=["conformance/pascal-server"], fpc=HOST_FPC,
                       output=OUT / "beconf")
    return shlex.quote(str(binary))


def counts(results):
    return (sum(r.status == "PASS" for r in results), sum(r.status == "FAIL" for r in results),
            sum(r.status == "PEND" for r in results), len(results))


def run_gate(subtests, server: str, paths, log: Path, want, allowed_failures=()):
    """Runs the cases in `paths` against `server`; every case is a subtest
    (a listed exception may fail: it is reported, not failed); then the
    summary must be `want`, counting a used exception as a pass."""
    runner = crun()
    cases = runner.load_cases([str(p) for p in paths])
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "w") as f:
        results = runner.run_cases(cases, server, jobs=JOBS, report=lambda r: print(r.text, file=f))
        print(runner.summary_line(results), file=f)
    used = []
    for r in results:
        with subtests.test(msg=r.id):
            if r.status == "FAIL" and r.id in allowed_failures:
                used.append(r.id)
                print(f"listed exception used: {r.id}")
            else:
                assert r.status != "FAIL", r.text
    passed, failed, pending, total = counts(results)
    got = (passed + len(used), failed - len(used), pending, total)
    note = f" (only listed exception cases fail: {' '.join(used)})" if used else ""
    assert got == want, f"{runner.summary_line(results)} (see {log}); expected " \
        f"passed={want[0]} failed={want[1]} pending={want[2]} total={want[3]}{note}"
    print(f"{runner.summary_line(results)}{note}")


def listed_exceptions() -> set[str]:
    """The case ids of worker-exceptions.txt (`<id> | <reason>` lines)."""
    ids = set()
    for line in (PS / "worker-exceptions.txt").read_text().splitlines():
        if line and not line.startswith("#") and "|" in line:
            ids.add(line.split("|", 1)[0].strip())
    return ids


@pytest.mark.parametrize("run", range(1, RUNS + 1), ids=lambda n: f"run{n}")
def test_inline_cases(beconf, run, subtests):
    server = f"{beconf} --loops {LOOPS}" if LOOPS else beconf
    log = OUT / ("gate" + (f"-loops{LOOPS}" if LOOPS else "")) / f"run-{run}.log"
    run_gate(subtests, server, [CASES], log, WANT_CASES)


def test_inline_extra(beconf, subtests):
    server = f"{beconf} --loops {LOOPS}" if LOOPS else beconf
    log = OUT / ("gate" + (f"-loops{LOOPS}" if LOOPS else "")) / "extra.log"
    run_gate(subtests, server, [EXTRA], log, WANT_EXTRA)


@pytest.mark.parametrize("run", range(1, RUNS + 1), ids=lambda n: f"run{n}")
def test_worker_cases(beconf, run, subtests):
    run_gate(subtests, f"{beconf} --executor worker", [CASES], OUT / "gate-worker" / f"run-{run}.log",
             WANT_CASES, allowed_failures=listed_exceptions())


def test_worker_extra(beconf, subtests):
    run_gate(subtests, f"{beconf} --executor worker", [EXTRA], OUT / "gate-worker" / "extra.log",
             WANT_EXTRA)


def test_worker_probe(beconf):
    """The evidence for the exception: both probe cases fail under the
    worker executor (the second handler is Pending at its first poll)."""
    runner = crun()
    cases = runner.load_cases([str(PROBE)])
    log = OUT / "gate-worker" / "probe-wd.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "w") as f:
        results = runner.run_cases(cases, f"{beconf} --executor worker", jobs=JOBS,
                                   report=lambda r: print(r.text, file=f))
        print(runner.summary_line(results), file=f)
    assert counts(results) == WANT_PROBE, \
        f"{runner.summary_line(results)} (see {log}); expected both to fail"
