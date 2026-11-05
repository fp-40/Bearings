"""The conformance case runner (conformance/SPEC.md): plays the client of
the case files against a server command, checks the assertions and the
server's events. Test tooling only: nothing here ships with Bearings, and
it shares no code with the server it checks.

Library use (pytest):

    cases = load_cases(["conformance/cases/h1"])
    results = run_cases(cases, "build/conformance/beconf", jobs=4)
    print(summary_line(results))
"""

import json
import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

from .bytestr import CaseError, get_str, json_str
from .cases import pending_reason, run_case, validate_case


class CaseFileError(Exception):
    """A case file cannot be read or is not a case file (CLI exit status 2)."""


@dataclass
class LoadedCase:
    id: str                 # "<file stem>::<name>"
    file: str
    case: dict
    invalid: str | None     # why the case is invalid, or None
    pending: str | None     # the pending reason, or None


@dataclass
class CaseResult:
    id: str
    status: str             # PASS | FAIL | PEND
    ms: int
    text: str               # the lines the CLI prints for this case, joined with "\n"
    reason: str | None = None


def collect_files(path: str, out: list) -> None:
    """Directories are searched recursively for *.json, in sorted order."""
    if os.path.isdir(path):
        for name in sorted(os.listdir(path), key=lambda n: n.encode("utf-8", "surrogateescape")):
            full = os.path.join(path, name)
            if os.path.isdir(full) or full.endswith(".json"):
                collect_files(full, out)
    else:
        out.append(path)


def load_cases(paths, filters=()) -> list:
    """Every case of the case files, in order; raises CaseFileError."""
    files = []
    for p in paths:
        collect_files(str(p), files)
    cases = []
    for f in files:
        try:
            with open(f, "rb") as fh:
                doc = json.loads(fh.read().decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise CaseFileError(f"{f}: invalid JSON: {e}") from None
        except OSError as e:
            raise CaseFileError(f"cannot read {f}: {e.strerror}") from None
        arr = doc.get("cases") if isinstance(doc, dict) else None
        if not isinstance(arr, list):
            raise CaseFileError(f'{f}: expected an object with a "cases" array')
        stem = os.path.splitext(os.path.basename(f))[0]
        seen = set()
        for i, c in enumerate(arr):
            name = get_str(c, "name", f"#{i}")
            full = f + "::" + name
            if filters and not any(s in full for s in filters):
                continue
            invalid = None
            try:
                validate_case(c)
            except CaseError as e:
                invalid = str(e)
            if name in seen:
                invalid = f"duplicate case name {json_str(name)} in {f}"
            seen.add(name)
            pend = pending_reason(c) if isinstance(c, dict) else None
            cases.append(LoadedCase(stem + "::" + name, f, c, invalid, pend))
    return cases


def run_one(lc: LoadedCase, server: str, verbose: bool) -> CaseResult:
    if lc.invalid is not None:
        return CaseResult(lc.id, "FAIL", 0, f"FAIL {lc.id} (invalid case)\n    {lc.invalid}")
    if lc.pending is not None:
        return CaseResult(lc.id, "PEND", 0, f"PEND {lc.id}: {lc.pending}", lc.pending)
    try:
        r = run_case(lc.case, server, verbose)
    except Exception as e:   # noqa: BLE001 - a runner defect is reported as a failed case
        return CaseResult(lc.id, "FAIL", 0,
                          f"FAIL {lc.id} (runner error)\n    {type(e).__name__}: {e}")
    if not r.failures:
        lines = [f"PASS {lc.id} ({r.elapsed_ms} ms)"]
        if verbose:
            lines += ["      " + ev for ev in r.events]
        return CaseResult(lc.id, "PASS", r.elapsed_ms, "\n".join(lines))
    lines = [f"FAIL {lc.id} ({r.elapsed_ms} ms)"]
    lines += ["    " + f for f in r.failures]
    lines.append("    server events:")
    lines += ["      " + ev for ev in r.events]
    err = r.stderr.strip(bytes(range(33)))
    if err:
        lines.append("    server stderr (last 2000 bytes):")
        lines += ["      " + line for line in err[-2000:].decode("utf-8", "replace").splitlines()]
    return CaseResult(lc.id, "FAIL", r.elapsed_ms, "\n".join(lines))


def run_cases(cases, server: str, jobs: int = 1, verbose: bool = False, report=None) -> list:
    """Runs the cases, jobs at a time; report (if given) gets each result in
    case order as soon as it and every case before it are done."""
    results = []
    with ThreadPoolExecutor(max_workers=max(1, min(jobs, len(cases) or 1))) as pool:
        futures = [pool.submit(run_one, lc, server, verbose) for lc in cases]
        for fut in futures:
            r = fut.result()
            results.append(r)
            if report is not None:
                report(r)
    return results


def summary_line(results) -> str:
    n = {"PASS": 0, "FAIL": 0, "PEND": 0}
    for r in results:
        n[r.status] += 1
    return f"SUMMARY passed={n['PASS']} failed={n['FAIL']} pending={n['PEND']} total={len(results)}"


__all__ = ["CaseError", "CaseFileError", "CaseResult", "LoadedCase", "load_cases", "run_cases",
           "summary_line"]
