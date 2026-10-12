#!/bin/sh
# Differential stream fuzz (docs/design.md section 9): builds
# beconf (debug profile, conformance/pascal-server/build.sh) and the fuzz
# tool, writes its seed inputs (the conformance case inputs,
# tests/unit/test_split_fuzz_cases.py; the M2 parser corpus with httparse's
# test inputs, tests/unit/test_parser_corpus.py) and runs STREAMS streams
# against reference-server (hyper 1.12) and beconf, pinned to CPUs 8-15.
# Routine runs: the default 10 000 streams (about a minute); the S9 exit
# ran STREAMS=100000 once (user decision 2026-10-09: once, not nightly).
# Usage: conformance/fuzz-diff/run.sh
# Env: OUT_DIR (default build/m3/S9/fuzz-diff), STREAMS (10000), SEED (1),
#      JOBS (8), QUIET_MS (100)
# Exit status 0 when no difference and no server crash was found.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/m3/S9/fuzz-diff}
mkdir -p "$OUT"
ulimit -c 0
OUT_DIR="$OUT/beconf" sh "$ROOT/conformance/pascal-server/build.sh" > "$OUT/beconf-build.log" 2>&1 || {
  echo "fuzz-diff: beconf build FAILED (see $OUT/beconf-build.log)"; exit 2; }
(cd "$ROOT/conformance" && cargo build --release --offline --quiet) > "$OUT/cargo.log" 2>&1 || {
  echo "fuzz-diff: cargo build FAILED (see $OUT/cargo.log)"; exit 2; }
python3 -I "$ROOT/tests/unit/test_split_fuzz_cases.py" "$OUT/cases.bin" "$ROOT/conformance/cases/h1" \
  "$ROOT/conformance/pascal-server/extra/extra-cases.json" > "$OUT/inputs.log"
HP=${HTTPARSE_SRC:-$(ls -d "$HOME"/.cargo/registry/src/*/httparse-1.10.1 2>/dev/null | head -n 1)}
HTTPARSE_SRC=$HP python3 -I "$ROOT/tests/unit/test_parser_corpus.py" "$OUT/corpus.bin" 20000 1 >> "$OUT/inputs.log"
R="$OUT/run-seed${SEED:-1}-${STREAMS:-10000}"
rm -rf "$R"
taskset -c 8-15 "$ROOT/conformance/target/release/fuzz-diff" --b "$OUT/beconf/beconf" \
  --streams "${STREAMS:-10000}" --seed "${SEED:-1}" --jobs "${JOBS:-8}" --quiet-ms "${QUIET_MS:-100}" \
  --out "$R" --inputs "$OUT/cases.bin" --corpus "$OUT/corpus.bin"
