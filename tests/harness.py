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

Progress. An fpcunit run writes one line when each test method starts and
one when it ends to `<output>.progress` (`tail -f build/unit/drd/run-1.out.progress`),
and a script run writes its log as the lines come. With `pytest -v` (and
without pytest-xdist's -n) the same lines are shown on the terminal while
the test runs.
"""

import fcntl
import os
import re
import select
import shlex
import shutil
import subprocess
import time
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


# set by conftest.pytest_configure: the live progress lines need pytest's
# terminal writer
PYTEST_CONFIG = None


class Live:
    """Writes to the terminal while a test runs, past pytest's capture: only
    with -v, and not in a pytest-xdist worker (it has no terminal)."""

    def __init__(self):
        cfg = PYTEST_CONFIG
        self.tr = self.cap = None
        if cfg is not None and cfg.getoption("verbose", 0) >= 1:
            self.tr = cfg.pluginmanager.get_plugin("terminalreporter")
            self.cap = cfg.pluginmanager.get_plugin("capturemanager")
        self.started = False

    def write(self, text: str):
        if self.tr is None:
            return
        if self.cap is not None:
            with self.cap.global_and_fixture_disabled():
                self._write(text)
        else:
            self._write(text)

    def _write(self, text: str):
        if not self.started:
            self.tr.ensure_newline()
            self.started = True
        self.tr.write(text, flush=True)


def pump(proc: subprocess.Popen, on_bytes, timeout: float) -> int:
    """Hands the process's stdout to `on_bytes` as it comes; the exit code,
    or 124 when `timeout` seconds passed (the process is then killed)."""
    fd = proc.stdout.fileno()
    deadline = time.monotonic() + timeout
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            proc.kill()
            proc.wait()
            return 124
        ready, _, _ = select.select([fd], [], [], min(left, 1.0))
        if not ready:
            continue
        data = os.read(fd, 65536)
        if not data:
            break
        on_bytes(data)
    left = max(deadline - time.monotonic(), 0.1)
    try:
        return proc.wait(timeout=left)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return 124


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


def fpcunit_test_names(binary: Path, suite: str | None, env: dict) -> list[str]:
    """The Class.Method names `binary` runs for `suite` (None: all), in run
    order, from its --list (either of the runner's two list formats); empty
    when the list cannot be had. `env` is the run's environment (a program
    may need it to start), without HEAPTRC: the list must not write the
    run's heaptrc log."""
    try:
        proc = subprocess.run(
            [*RUN, str(binary), "--list"],
            env={k: v for k, v in env.items() if k != "HEAPTRC"},
            capture_output=True,
            text=True,
            errors="replace",
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    names, cls = [], ""
    for line in proc.stdout.splitlines():
        if m := re.search(r'<Suite Name="(\w+)"', line):
            cls = m.group(1)
        elif m := re.search(r'<Test name="(\w+)"', line):
            names.append(f"{cls}.{m.group(1)}")
        elif m := re.fullmatch(r"\s+(\w+\.\w+)", line):
            names.append(m.group(1))
    if suite:
        names = [n for n in names if n == suite or n.startswith(suite + ".")]
    return names


# the marks of the fpcunit runner's --progress
PROGRESS_WORDS = {".": "ok", "F": "FAILED", "E": "ERROR"}


class FpcProgress:
    """The progress of an fpcunit run, from the runner's --progress marks (one
    character when a test method ends: '.', 'F' or 'E'). The methods run in
    the order of --list, so mark N is the Nth name. Each start and each end
    is a line of `path`; with -v they are shown on the terminal too."""

    def __init__(self, path: Path, label: str, names: list[str]):
        self.file = open(path, "w", buffering=1)  # noqa: SIM115 (closed by close)
        self.live = Live()
        self.names = names
        self.done = 0
        self.t0 = self.t_test = time.monotonic()
        total = len(names) if names else "?"
        self.file.write(f"{label}: {total} tests\n")
        self.live.write(f"  {label}: {total} tests\n")
        self.start()

    def tag(self) -> str:
        total = str(len(self.names)) if self.names else "?"
        return f"[{self.done + 1:>{len(total)}}/{total}]"

    def name(self) -> str:
        return self.names[self.done] if self.done < len(self.names) else "?"

    def start(self):
        """The next test begins (known only when the names are)."""
        self.t_test = time.monotonic()
        self.running = self.done < len(self.names)
        if self.running:
            self.file.write(f"{self.tag()} run            {self.name()}\n")
            self.live.write(f"  {self.tag()} {self.name()} ")

    def mark(self, ch: str):
        secs = time.monotonic() - self.t_test
        word = PROGRESS_WORDS[ch]
        self.file.write(f"{self.tag()} {word:<6} {secs:6.1f}s {self.name()}\n")
        if not self.running:
            self.live.write(f"  {self.tag()} {self.name()} ")
        self.live.write(f"{word} ({secs:.1f} s)\n")
        self.done += 1
        self.start()

    def close(self, exit_code: int):
        secs = time.monotonic() - self.t0
        end = "TIMEOUT" if exit_code == 124 else f"exit {exit_code}"
        if self.running:
            # the test that was running when the program stopped
            self.live.write("...\n")
        self.file.write(f"{end}: {self.done} tests ended in {secs:.1f}s\n")
        self.live.write(f"  {end}: {self.done} tests ended in {secs:.1f} s\n")
        self.file.close()


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
    """Runs an fpcunit program (--all, or --suite=<suite>) and parses its XML
    report (`<output>.xml`). `output` gets what the program prints; `prefix`
    runs it under a command (valgrind); `stderr` gets the program's stderr
    (default: `output` too). The progress goes to `<output>.progress` and,
    with -v, to the terminal (FpcProgress)."""
    xml = output.with_name(output.name + ".xml")
    xml.unlink(missing_ok=True)
    args = [
        *(prefix if prefix is not None else RUN),
        str(binary),
        f"--suite={suite}" if suite else "--all",
        "--format=xml",
        f"--file={xml}",
        "--progress",
    ]
    full_env = dict(os.environ, **(env or {}))
    progress = FpcProgress(
        output.with_name(output.name + ".progress"),
        binary.name if output.stem == binary.name else f"{binary.name} ({output.stem})",
        fpcunit_test_names(binary, suite, full_env),
    )
    with open(output, "wb", buffering=0) as out:
        err = open(stderr, "wb") if stderr else out  # noqa: SIM115
        in_text = False

        def on_bytes(data: bytes):
            # a progress mark is a '.', 'F' or 'E' that does not continue a
            # line the program printed; everything else goes to `output`
            nonlocal in_text
            for b in data:
                ch = chr(b)
                if not in_text and ch in PROGRESS_WORDS:
                    progress.mark(ch)
                elif ch == "\n":
                    if in_text:
                        out.write(b"\n")
                    in_text = False
                else:
                    in_text = True
                    out.write(bytes([b]))

        try:
            proc = subprocess.Popen(
                args, stdout=subprocess.PIPE, stderr=err, env=full_env, cwd=cwd
            )
            code = pump(proc, on_bytes, timeout)
        finally:
            if stderr:
                err.close()
            progress.close(code if "code" in locals() else -1)
    r = parse_fpcunit_xml(xml, code)
    r.output = output
    return r


def parse_fpcunit_xml(output: Path, exit_code: int) -> FpcRun:
    """The <Test> elements of fpcunit's XML report (the program may print
    other lines before or after it)."""
    text = output.read_text(errors="replace") if output.exists() else ""
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
    goes to `log` as it comes (and, with -v, to the terminal) and is returned
    as `stdout`."""
    cmd = ["sh", str(ROOT / script), *map(str, args)]
    live = Live()
    chunks: list[bytes] = []
    logf = None
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        logf = open(log, "wb", buffering=0)  # noqa: SIM115
    pending = b""

    def on_bytes(data: bytes):
        nonlocal pending
        chunks.append(data)
        if logf:
            logf.write(data)
        *lines, pending = (pending + data).split(b"\n")
        for line in lines:
            live.write("  " + line.decode(errors="replace") + "\n")

    try:
        proc = subprocess.Popen(
            cmd,
            env=dict(os.environ, **(env or {})),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        code = pump(proc, on_bytes, timeout)
    finally:
        if logf:
            logf.close()
    if pending:
        live.write("  " + pending.decode(errors="replace") + "\n")
    text = b"".join(chunks).decode(errors="replace")
    if code == 124:
        raise subprocess.TimeoutExpired(cmd, timeout, output=text)
    return subprocess.CompletedProcess(cmd, code, stdout=text)
