#!/bin/sh
# Differential test: bearings.http1.parser vs the real httparse 1.10.1.
# Usage: tests/unit/test_parser_diff.sh [random cases] [seed]
# Env: HTTPARSE_SRC=<httparse-1.10.1 source dir> adds httparse's own test
#      inputs to the corpus (optional).
# Exit status 0 only when both outputs are byte-identical.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/parser}
mkdir -p "$OUT"
N=${1:-200000}
SEED=${2:-1}
python3 -I "$ROOT/tests/unit/test_parser_corpus.py" "$OUT/corpus.bin" "$N" "$SEED"
CARGO_TARGET_DIR="$OUT/cargo-target" cargo build --quiet --offline --release \
  --manifest-path "$ROOT/tests/unit/test_parser_diff_rs/Cargo.toml"
fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http1" -Fu"$ROOT/tests/unit" \
  -FU"$OUT" -FE"$OUT" "$ROOT/tests/unit/test_parser_diff.pas" > "$OUT/diff-build.log"
"$OUT/cargo-target/release/test_parser_diff_rs" "$OUT/corpus.bin" > "$OUT/httparse.out"
"$OUT/test_parser_diff" "$OUT/corpus.bin" > "$OUT/pascal.out"
# Same run with the input placed against PROT_NONE guard pages: catches
# any read before Buf or at/after Buf+Len.
for MODE in --guard-end --guard-start; do
  "$OUT/test_parser_diff" "$OUT/corpus.bin" $MODE > "$OUT/pascal$MODE.out"
  cmp -s "$OUT/pascal.out" "$OUT/pascal$MODE.out" || {
    echo "differential: guard-page run $MODE differs or crashed"; exit 1; }
done
LINES=$(wc -l < "$OUT/httparse.out")
if cmp -s "$OUT/httparse.out" "$OUT/pascal.out"; then
  echo "differential: $LINES result lines identical"
else
  echo "differential: MISMATCH (first differences below)"
  diff "$OUT/httparse.out" "$OUT/pascal.out" | head -40
  exit 1
fi
