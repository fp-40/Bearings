"""The S9 split fuzz (docs/design.md section 9; tests/unit/test_split_fuzz.pas):
the conformance case inputs and the M2 parser corpus (20 000 random entries,
seed 1) in random reads with random EAGAIN and partial writes, compared with
one-read runs; built with -Ci -Cr -Co -Ct -Sa -gh -gl -dWD_DEBUG, heaptrc
must report 0 unfreed blocks. 100 seeds in the fast tier, 2000 in the full
tier (FUZZ_SEEDS overrides both).
"""

import os
import subprocess
import sys

import pytest
from harness import (
    DRD_TIMEOUT,
    OUT,
    ROOT,
    TEST_FLAGS,
    fpc_build,
    heaptrc_unfreed,
    report_fpcunit,
    run_fpcunit,
)


FZ = OUT / "split-fuzz"


@pytest.mark.fuzz
@pytest.mark.hostonly
@pytest.mark.parametrize("seeds", [pytest.param(100, marks=pytest.mark.fast),
                                   pytest.param(2000, marks=pytest.mark.full)])
def test_split_fuzz(seeds, subtests):
    seeds = int(os.environ.get("FUZZ_SEEDS", seeds))
    FZ.mkdir(parents=True, exist_ok=True)
    py = [sys.executable, "-I"]
    subprocess.run([*py, str(ROOT / "tests/unit/test_split_fuzz_cases.py"), str(FZ / "cases.bin"),
                    str(ROOT / "conformance/cases/h1"),
                    str(ROOT / "conformance/pascal-server/extra/extra-cases.json")],
                   check=True, stdout=open(FZ / "cases.log", "w"), stderr=subprocess.STDOUT)
    subprocess.run([*py, str(ROOT / "tests/unit/test_parser_corpus.py"), str(FZ / "corpus.bin"),
                    "20000", "1"], check=True, stdout=open(FZ / "corpus.log", "w"),
                   stderr=subprocess.STDOUT)
    binary = fpc_build(ROOT / "tests/unit/test_split_fuzz.pas", FZ, FZ / "u",
                       [*TEST_FLAGS, "-Ci", "-gh", "-dWD_DEBUG"],
                       extra_units=["conformance/pascal-server"])
    heap = FZ / "heap.txt"
    heap.unlink(missing_ok=True)
    for f in FZ.glob("fail-*.txt"):
        f.unlink()
    r = run_fpcunit(binary, FZ / "out.txt", timeout=DRD_TIMEOUT,
                    env={"FUZZ_DATA": str(FZ), "FUZZ_SEEDS": str(seeds), "HEAPTRC": f"log={heap}"})
    for line in (FZ / "out.txt").read_text(errors="replace").splitlines():
        if line.startswith("split fuzz: ") and line[12:13].isdigit():
            print("  " + line)
    report_fpcunit(subtests, r, f"test_split_fuzz ({seeds} seeds)")
    unfreed = heaptrc_unfreed(heap)
    assert unfreed == 0, f"test_split_fuzz: unfreed blocks: {unfreed} (see {heap})"
