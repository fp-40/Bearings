"""The full tier (make test-full; docs/design.md section 9): the worker tests
under valgrind --tool=drd, the end-to-end worker stress and the echo under
valgrind memcheck. valgrind comes from tools/get-tools.sh (VALGRIND names
another one); a missing valgrind fails these tests, it does not skip them
(decision 12).

drd: the suites are built with -dWD_DRD (bearings.rt.sync's happens-before
client requests; the C heap, as with the FPC heap a frame freed on one loop
and reused on another shows up as a conflict drd cannot see through),
tools/drd.supp, WD_ITER=20 (loop counts at 20 %): drd must report 0 errors
and every test must pass. --fair-sched=yes: valgrind runs one thread at a
time; its default lock lets a thread that spins (the tests' CpuRelax loops)
take the lock back again and again while the thread it waits for cannot
run (deviation S7-25). DRD_RUNS (default 3) runs of test_workers.
"""

import os
from pathlib import Path

import pytest
from harness import (
    DRD_TIMEOUT,
    OUT,
    ROOT,
    TEST_FLAGS,
    VALGRIND,
    fpc_build,
    report_fpcunit,
    require_valgrind,
    run_fpcunit,
    run_script,
    valgrind_errors,
)


pytestmark = [pytest.mark.full, pytest.mark.hostonly]
DR = OUT / "drd"
DRD_RUNS = int(os.environ.get("DRD_RUNS", "3"))


def drd_run(binary: Path, out_dir: Path, name: str, subtests, suite: str | None = None):
    """One run of an fpcunit binary under drd: the tests as subtests, then
    the drd error count."""
    out, err = out_dir / f"{name}.out", out_dir / f"{name}.err"
    r = run_fpcunit(binary, out, suite=suite, env={"WD_ITER": "20"}, timeout=DRD_TIMEOUT,
                    cwd=out_dir, stderr=err,
                    prefix=[VALGRIND, "--tool=drd", "--fair-sched=yes",
                            f"--suppressions={ROOT / 'tools/drd.supp'}"])
    report_fpcunit(subtests, r, f"{binary.name} ({name})")
    errors = valgrind_errors(err)
    assert errors == 0, f"{binary.name} ({name}): drd errors: {errors} (see {err})"


def drd_build(suite: str, out_dir: Path) -> Path:
    require_valgrind()
    return fpc_build(ROOT / "tests/unit" / f"{suite}.pas", out_dir, out_dir / "u",
                     [*TEST_FLAGS, "-dWD_DRD"])


@pytest.mark.drd
@pytest.mark.parametrize("run", range(1, DRD_RUNS + 1), ids=lambda n: f"run{n}")
def test_workers_drd(run, subtests):
    """S7 exit criterion: the worker tests under drd, DRD_RUNS times."""
    binary = drd_build("test_workers", DR)
    drd_run(binary, DR, f"run-{run}", subtests)


@pytest.mark.drd
@pytest.mark.parametrize("suite", ["TTestWsWorker", "TTestWsTopics"])
def test_ws_echo_drd(suite, subtests):
    """The WebSocket handler on the worker pool (real sockets) under drd: the
    event queue, the receive mark and the stop while a handler is busy are
    loop-to-worker hand-offs like the ones of S7; and the pub/sub topics:
    publishes posted to every loop, subscribes posted from a worker, a
    publish from a plain thread."""
    binary = drd_build("test_ws_echo", DR / "ws")
    drd_run(binary, DR / "ws", f"run-{suite}", subtests, suite=suite)


@pytest.mark.drd
def test_capi_drd(subtests):
    """The C interface (real sockets) under drd: its registry of WebSockets is
    used from threads that are not the server's (the host program's), while
    the connections end on the workers."""
    binary = drd_build("test_capi", DR / "capi")
    drd_run(binary, DR / "capi", "run", subtests)


@pytest.mark.stress
def test_s7_stress():
    """The end-to-end worker stress (tests/unit/stress_workers.pas through
    TServer), natively and under drd (tools/s7-stress.sh). STRESS_SEEDS
    (default 3) and STRESS_DRD_RUNS (default 1) set its size; the script's
    own defaults are 10 and 3."""
    require_valgrind()
    log = OUT / "s7-stress" / "s7-stress.log"
    proc = run_script("tools/s7-stress.sh", log=log,
                      env={"OUT_DIR": str(OUT / "s7-stress"),
                           "SEEDS": os.environ.get("STRESS_SEEDS", "3"),
                           "DRD_RUNS": os.environ.get("STRESS_DRD_RUNS", "1"),
                           "VALGRIND": VALGRIND})
    assert proc.returncode == 0, f"s7-stress failed (exit {proc.returncode}, see {log}):\n" \
        + "\n".join(proc.stdout.splitlines()[-15:])


@pytest.mark.valgrind
def test_rt_echo_memcheck():
    """The echo test: ECHO_BYTES (default 1 GiB) with random split sizes,
    the server under valgrind memcheck, 0 errors (tests/unit/test_rt_echo.sh)."""
    require_valgrind()
    log = OUT / "test_rt_echo.log"
    proc = run_script("tests/unit/test_rt_echo.sh", [os.environ.get("ECHO_BYTES", "1073741824")],
                      log=log, env={"OUT_DIR": str(OUT), "VALGRIND": VALGRIND})
    assert proc.returncode == 0, f"test_rt_echo failed (exit {proc.returncode}, see {log}):\n" \
        + "\n".join(proc.stdout.splitlines()[-15:])
