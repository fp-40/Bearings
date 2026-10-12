#!/bin/sh
# Differential test: bearings.http1.decode and bearings.http.headers vs hyper v1.12.0's
# own src/proto/h1/decode.rs and src/headers.rs (copied unchanged into
# tests/unit/test_codec_diff_rs, which is test tooling only).
# Usage: tests/unit/test_codec_diff.sh [decode cases] [header cases] [seed]
# Runs the cases three times: plain, and with every decoder input placed
# against a PROT_NONE guard page at its end and at its start.
# Exit status 0 only when every result matches hyper's in all three runs.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/codec-diff}
mkdir -p "$OUT"
ND=${1:-100000}
NH=${2:-20000}
SEED=${3:-1}
CARGO_TARGET_DIR="$OUT/cargo-target" cargo build --quiet --offline --release \
  --manifest-path "$ROOT/tests/unit/test_codec_diff_rs/Cargo.toml"
fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http1" -Fu"$ROOT/tests/unit" \
  -FU"$OUT" -FE"$OUT" "$ROOT/tests/unit/test_codec_diff.pas" > "$OUT/diff-build.log"
"$OUT/cargo-target/release/test_codec_diff_rs" "$SEED" "$ND" "$NH" "$OUT"
"$OUT/test_codec_diff" "$OUT"
"$OUT/test_codec_diff" "$OUT" --guard-end
"$OUT/test_codec_diff" "$OUT" --guard-start
echo "differential: all runs match hyper"
