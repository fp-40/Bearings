"""Helpers of the test runner (tests/*.py): compiling with Free Pascal, running
an fpcunit suite and reporting each of its test methods as a subtest.

Env: OUT_DIR (build directory, default build/unit); FPC (compiler, default
fpc); RUN (a command prefix for running the built binaries, e.g. qemu);
TARGET=aarch64 selects the cross compiler and runner of
tools/get-cross-aarch64.sh and skips the host-only tests (docs/design/arm64.md);
SUITE_TIMEOUT (seconds per fpcunit run, default 600); DRD_TIMEOUT (default
3600); VALGRIND (default build/tools/bin/valgrind, from tools/get-tools.sh).

Option: --fpc-suite=TTestClass[.Method] runs only that suite class or
method of every fpcunit run selected (`-k h1_conn --fpc-suite=TTestConnState`).
"""

import fcntl
import os
import shlex
import shutil
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TARGET = os.environ.get("TARGET", "x86_64")
if TARGET == "aarch64":
    FPC = os.environ.get("FPC", str(ROOT / "build/tools/bin/fpc-aarch64"))
    RUN = shlex.split(os.environ.get("RUN", str(ROOT / "build/tools/bin/run-aarch64")))
    OUT = Path(os.environ.get("OUT_DIR", ROOT / "build/unit-aarch64")).resolve()
elif TARGET == "x86_64":
    FPC = os.environ.get("FPC", "fpc")
    RUN = shlex.split(os.environ.get("RUN", ""))
    OUT = Path(os.environ.get("OUT_DIR", ROOT / "build/unit")).resolve()
else:
    raise SystemExit(f"TARGET={TARGET}: x86_64 or aarch64")
HOST_FPC = "fpc"
SUITE_TIMEOUT = int(os.environ.get("SUITE_TIMEOUT", "600"))
DRD_TIMEOUT = int(os.environ.get("DRD_TIMEOUT", "3600"))
VALGRIND = os.environ.get("VALGRIND", str(ROOT / "build/tools/bin/valgrind"))

# the unit-test flags (docs/design/verification.md)
TEST_FLAGS = ["-Mobjfpc", "-Sh", "-O2", "-gl", "-Cr", "-Co", "-Ct", "-Sa"]
UNIT_DIRS = [
    "src/rt",
    "src/http",
    "src/http1",
    "src/server",
    "src/ws",
    "src/capi",
    "tests/support",
    "tests/unit",
]


def valgrind_available() -> bool:
    return os.access(VALGRIND, os.X_OK) or shutil.which(VALGRIND) is not None


def require_valgrind():
    """A missing valgrind fails the run (decision 12), it does not skip it."""
    if not valgrind_available():
        pytest.fail(
            f"no valgrind at {VALGRIND} (run tools/get-tools.sh, or set VALGRIND)"
        )


def fpc_build(
    source: Path,
    out_dir: Path,
    unit_dir: Path,
    flags=None,
    extra_units=(),
    fpc: str = FPC,
    output: Path | None = None,
) -> Path:
    """Compiles `source` into `out_dir` (binary `out_dir/<stem>`, or `output`),
    with the unit files in `unit_dir`. One compiler at a time per unit
    directory (a file lock): pytest-xdist workers share the directories.
    Fails the test with the tail of the build log."""
    out_dir.mkdir(parents=True, exist_ok=True)
    unit_dir.mkdir(parents=True, exist_ok=True)
    binary = output or out_dir / source.stem
    log = out_dir / f"{source.stem}.build.log"
    cmd = [
        fpc,
        *(flags if flags is not None else TEST_FLAGS),
        *[f"-Fu{ROOT / d}" for d in (*UNIT_DIRS, *extra_units)],
        f"-FU{unit_dir}",
        f"-FE{out_dir}",
        f"-o{binary}",
        str(source),
    ]
    with open(unit_dir / ".fpc.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(log, "w") as logf:
            result = subprocess.run(cmd, stdout=logf, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        tail = "".join(log.read_text(errors="replace").splitlines(keepends=True)[-15:])
        pytest.fail(f"{source.name}: build failed (see {log}):\n{tail}", pytrace=False)
    return binary


@dataclass
class FpcTest:
    suite: str
    name: str
    result: str  # OK, Failed, Error, Ignored
    message: str


@dataclass
class FpcRun:
    tests: list[FpcTest]
    run: int
    errors: int
    failures: int
    exit_code: int  # 124 when the timeout stopped it
    output: Path


def run_fpcunit(
    binary: Path,
    output: Path,
    suite: str | None = None,
    env=None,
    timeout: int = SUITE_TIMEOUT,
    cwd: Path | None = None,
    prefix: list[str] | None = None,
    stderr: Path | None = None,
) -> FpcRun:
    """Runs an fpcunit program (--all, or --suite=<suite>) with XML output into
    `output` and parses the result. `prefix` runs it under a command (valgrind);
    `stderr` gets the program's stderr (default: appended to `output`)."""
    args = [
        *(prefix if prefix is not None else RUN),
        str(binary),
        f"--suite={suite}" if suite else "--all",
        "--format=xml",
    ]
    full_env = dict(os.environ, **(env or {}))
    err = open(stderr, "w") if stderr else subprocess.STDOUT
    try:
        with open(output, "w") as out:
            try:
                proc = subprocess.run(
                    args, stdout=out, stderr=err, env=full_env, timeout=timeout, cwd=cwd
                )
                code = proc.returncode
            except subprocess.TimeoutExpired:
                code = 124
    finally:
        if stderr:
            err.close()
    return parse_fpcunit_xml(output, code)


def parse_fpcunit_xml(output: Path, exit_code: int) -> FpcRun:
    """The <Test> elements of fpcunit's XML report (the program may print
    other lines before or after it)."""
    text = output.read_text(errors="replace")
    start, end = text.find("<?xml"), text.rfind("</TestResults>")
    tests: list[FpcTest] = []
    run = errors = failures = -1
    if start >= 0 and end >= 0:
        try:
            root = ET.fromstring(text[start : end + len("</TestResults>")])
        except ET.ParseError:
            root = None
        if root is not None:
            for ts in root.iter("TestSuite"):
                if not ts.get("Name"):
                    continue
                for t in ts.findall("Test"):
                    msg = t.findtext("Message") or ""
                    tests.append(
                        FpcTest(ts.get("Name"), t.get("Name"), t.get("Result"), msg)
                    )
            run = int(root.findtext("NumberOfRunTests") or -1)
            errors = int(root.findtext("NumberOfErrors") or -1)
            failures = int(root.findtext("NumberOfFailures") or -1)
    return FpcRun(tests, run, errors, failures, exit_code, output)


def report_fpcunit(subtests, r: FpcRun, label: str = ""):
    """Every test method as a subtest, then the run as a whole: it must have
    produced a report, exited 0 and counted no error or failure."""
    for t in r.tests:
        with subtests.test(msg=f"{t.suite}.{t.name}"):
            assert t.result in ("OK", "Ignored"), f"{t.result}: {t.message}"
    if r.exit_code == 124:
        pytest.fail(f"{label}: TIMEOUT (see {r.output})", pytrace=False)
    assert r.run >= 0, f"{label}: no fpcunit report in {r.output}"
    assert (r.exit_code, r.errors, r.failures) == (0, 0, 0), (
        f"{label}: exit {r.exit_code}, errors {r.errors}, failures {r.failures} (see {r.output})"
    )


def heaptrc_unfreed(heap_log: Path) -> int | None:
    """The unfreed block count of a heaptrc log, None when it has none."""
    if not heap_log.exists():
        return None
    for line in heap_log.read_text(errors="replace").splitlines():
        if line.endswith("unfreed memory blocks") or " unfreed memory blocks" in line:
            try:
                return int(line.split()[0])
            except ValueError:
                return None
    return None


def valgrind_errors(err_log: Path) -> int | None:
    """The count of valgrind's last ERROR SUMMARY line, None when absent."""
    count = None
    for line in err_log.read_text(errors="replace").splitlines():
        if "ERROR SUMMARY:" in line:
            try:
                count = int(line.split("ERROR SUMMARY:")[1].split()[0])
            except (IndexError, ValueError):
                pass
    return count


def run_script(
    script: str, args=(), env=None, timeout: int = DRD_TIMEOUT, log: Path | None = None
) -> subprocess.CompletedProcess:
    """Runs a repository shell script (tools/*.sh, tests/unit/*.sh); its output
    goes to `log` and is returned as `stdout`."""
    cmd = ["sh", str(ROOT / script), *map(str, args)]
    proc = subprocess.run(
        cmd,
        env=dict(os.environ, **(env or {})),
        timeout=timeout,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(proc.stdout)
    return proc
