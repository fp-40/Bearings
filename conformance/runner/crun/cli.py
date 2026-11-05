"""The command line of the runner:

    crun run --server CMD [--filter S]... [--jobs N] [-v] PATH...
    crun list [--filter S]... PATH...
    crun selftest

run: every case of the case files (a PATH is a file or a directory searched
recursively for *.json, in sorted order) against a server started as
`CMD --config <file>` for each case; prints PASS, FAIL or PEND per case, in
case order, then "SUMMARY passed=.. failed=.. pending=.. total=..". Exit
status 1 when a case failed, 2 on a usage error or an unreadable case file.
list: the cases, with INVALID, PEND or CASE.
selftest: the runner's own checks; exit status 1 on a failure."""

import sys

from . import CaseFileError, load_cases, run_cases, summary_line
from .bytestr import get_str

USAGE = """usage:
  crun run  --server CMD [--filter S]... [--jobs N] [-v] PATH...
  crun list [--filter S]... PATH...
  crun selftest
PATH is a case file or a directory searched recursively for *.json.
CMD is a shell command line; the runner appends `--config <file>`.
--jobs N runs N cases at a time (default 1); the output keeps the case order.
run needs --server."""


def usage() -> int:
    print(USAGE, file=sys.stderr)
    return 2


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if not argv:
        return usage()
    cmd = argv[0]
    server = None
    filters = []
    jobs = 1
    verbose = False
    paths = []
    k = 1
    while k < len(argv):
        a = argv[k]
        if a in ("--server", "--filter", "--jobs"):
            k += 1
            if k >= len(argv):
                return usage()
            if a == "--server":
                server = argv[k]
            elif a == "--filter":
                filters.append(argv[k])
            else:
                try:
                    jobs = int(argv[k])
                except ValueError:
                    jobs = 0
                if jobs < 1:
                    print("--jobs needs a number >= 1", file=sys.stderr)
                    return usage()
        elif a in ("-v", "--verbose"):
            verbose = True
        elif a in ("-h", "--help"):
            return usage()
        elif a.startswith("-"):
            print(f"unknown option {a}", file=sys.stderr)
            return usage()
        else:
            paths.append(a)
        k += 1
    if cmd == "selftest":
        from .selftest import selftest

        return selftest()
    if cmd not in ("run", "list") or not paths:
        return usage()
    if cmd == "run" and server is None:
        print("run needs --server CMD", file=sys.stderr)
        return usage()
    try:
        cases = load_cases(paths, filters)
    except CaseFileError as e:
        print(e, file=sys.stderr)
        return 2
    if cmd == "list":
        for lc in cases:
            tag = (
                "INVALID"
                if lc.invalid is not None
                else "PEND"
                if lc.pending is not None
                else "CASE"
            )
            print(f"{tag} {lc.id} {get_str(lc.case, 'source')}")
            if lc.invalid is not None:
                print(f"    {lc.invalid}")
        return 0

    def report(r):
        print(r.text, flush=True)

    results = run_cases(cases, server, jobs, verbose, report)
    print(summary_line(results), flush=True)
    return 1 if any(r.status == "FAIL" for r in results) else 0
