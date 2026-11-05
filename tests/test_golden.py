"""Expected-value tests of the HTTP/1 parser, the request head rules and the
body decoder: each driver prints one result line per case, and the lines
must equal the expected values in tests/golden.

    parser  bearings.http1.parser over the corpus of test_parser_corpus.py
            (50 000 random cases, seed 1; the corpus is generated here and
            its SHA-256 is checked, so a change in the generator or in
            Python's random module is reported as such)
    role    bearings.http1.role (request parsing) and bearings.http.uri over
            tests/golden/role_cases.txt.xz
    codec   bearings.http1.decode and bearings.http.headers over
            tests/golden/decode_cases.txt.xz and headers_cases.txt.xz

Every driver also runs with its input against PROT_NONE guard pages (a read
outside the input crashes); those runs must print the same lines.

The expected values were frozen on 2026-11-04 (docs/design/verification.md).
After an intended change of behaviour, run with UPDATE=1, which lists the
lines that change (case, old, new) and rewrites the expected files; review
the list before committing.

    pytest -m golden
    UPDATE=1 pytest -m golden -k codec
"""

import hashlib
import lzma
import os
import subprocess
import sys
from pathlib import Path

import pytest
from harness import OUT, ROOT, fpc_build


G = ROOT / "tests/golden"
GOLDEN_OUT = OUT / "golden"
UPDATE = os.environ.get("UPDATE") == "1"
CORPUS_SHA256 = "a09c35a657efb3f38c66d5f69dfb114cefc191b59a4925e322d439fc5aea4e41"

pytestmark = [pytest.mark.fast, pytest.mark.golden, pytest.mark.hostonly]


def build(driver: str) -> Path:
    return fpc_build(ROOT / "tests/unit" / f"{driver}.pas", GOLDEN_OUT, GOLDEN_OUT)


def run(binary: Path, args: list[str], output: Path):
    with open(output, "w") as out:
        proc = subprocess.run([str(binary), *args], stdout=out, stderr=subprocess.PIPE,
                              timeout=600)
    assert proc.returncode == 0, f"{binary.name} {' '.join(args)}: exit {proc.returncode}: " \
        f"{proc.stderr.decode(errors='replace')[-500:]}"


def guards_match(plain: Path, *guards: Path):
    for g in guards:
        assert g.read_bytes() == plain.read_bytes(), \
            f"guard-page run {g} differs from {plain} or crashed"


def compare(name: str, expected_xz: Path, got: Path, cases: Path | None):
    """The result lines against the expected file; with UPDATE=1 the file is
    rewritten and the changes are printed. The case of line N is line N of the
    cases file (the parser's lines carry their case index instead)."""
    expected = lzma.open(expected_xz).read().decode("latin-1").split("\n")
    actual = got.read_text(encoding="latin-1").split("\n")
    if expected == actual:
        print(f"golden {name}: {len(actual) - 1} result lines as expected")
        return
    case_lines = cases.read_text(encoding="latin-1").split("\n") if cases else None
    changed = 0
    limit = 20 if UPDATE else 10
    lines = []
    for i in range(max(len(expected), len(actual))):
        a = expected[i] if i < len(expected) else "<none>"
        b = actual[i] if i < len(actual) else "<none>"
        if a == b:
            continue
        changed += 1
        if changed <= limit:
            lines.append(f"  line {i + 1}")
            if case_lines is not None and i < len(case_lines):
                lines.append("    case:     " + case_lines[i][:300])
            lines.append("    expected: " + a[:300])
            lines.append("    got:      " + b[:300])
    detail = "\n".join(lines)
    if UPDATE:
        with lzma.open(expected_xz, "wb", preset=9 | lzma.PRESET_EXTREME) as f:
            f.write(got.read_bytes())
        print(f"golden {name}: UPDATE: {changed} lines change (first {limit} below)\n{detail}\n"
              f"golden {name}: {expected_xz} rewritten")
        return
    pytest.fail(f"golden {name}: MISMATCH: {changed} lines differ from the expected values "
                f"(first {limit} below)\n{detail}", pytrace=False)


def test_parser():
    binary = build("test_parser_golden")
    corpus = GOLDEN_OUT / "corpus.bin"
    subprocess.run([sys.executable, "-I", str(ROOT / "tests/unit/test_parser_corpus.py"),
                    str(corpus), "50000", "1"], check=True, stdout=subprocess.DEVNULL)
    sha = hashlib.sha256(corpus.read_bytes()).hexdigest()
    assert sha == CORPUS_SHA256, (
        f"golden parser: the corpus changed (sha256 {sha}, expected {CORPUS_SHA256}): "
        "test_parser_corpus.py or Python's random module produce other cases, so the "
        "expected values no longer belong to them")
    got, end, start = (GOLDEN_OUT / n for n in ("parser.got", "parser.guard-end", "parser.guard-start"))
    run(binary, [str(corpus)], got)
    run(binary, [str(corpus), "--guard-end"], end)
    run(binary, [str(corpus), "--guard-start"], start)
    guards_match(got, end, start)
    compare("parser", G / "parser_expected.txt.xz", got, None)


def test_role():
    binary = build("test_role_golden")
    cases = GOLDEN_OUT / "role_cases.txt"
    cases.write_bytes(lzma.open(G / "role_cases.txt.xz").read())
    got, guard = GOLDEN_OUT / "role.got", GOLDEN_OUT / "role.guard"
    run(binary, [str(cases)], got)
    run(binary, [str(cases), "--guard"], guard)
    guards_match(got, guard)
    compare("role", G / "role_expected.txt.xz", got, cases)


@pytest.mark.parametrize("kind", ["decode", "headers"])
def test_codec(kind):
    binary = build("test_codec_golden")
    cases = GOLDEN_OUT / f"{kind}_cases.txt"
    cases.write_bytes(lzma.open(G / f"{kind}_cases.txt.xz").read())
    got, end, start = (GOLDEN_OUT / n for n in (f"{kind}.got", f"{kind}.guard-end", f"{kind}.guard-start"))
    run(binary, [kind, str(cases)], got)
    run(binary, [kind, str(cases), "--guard-end"], end)
    run(binary, [kind, str(cases), "--guard-start"], start)
    guards_match(got, end, start)
    compare(kind, G / f"{kind}_expected.txt.xz", got, cases)
