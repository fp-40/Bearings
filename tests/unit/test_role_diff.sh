#!/bin/sh
# Differential test of request parsing: bearings.http1.role ServerParse + bearings.http.uri
# vs hyper v1.12.0's own src/proto/h1/role.rs Server::parse and http::Uri
# (copied unchanged into tests/unit/test_role_diff_rs, which is test tooling
# only). It checks which requests are accepted and with which framing
# (request smuggling); response encoding is covered by test_role_verify.
# Usage: tests/unit/test_role_diff.sh [parse cases] [seed] [uri cases]
# Runs the cases twice: plain, and with every request placed against a
# PROT_NONE guard page at its end.
# Exit status 0 only when every result matches hyper's in both runs.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/role-diff}
mkdir -p "$OUT"
NP=${1:-100000}
SEED=${2:-1}
NU=${3:-100000}
CARGO_TARGET_DIR="$OUT/cargo-target" cargo build --quiet --offline --release \
  --manifest-path "$ROOT/tests/unit/test_role_diff_rs/Cargo.toml"
fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http1" -Fu"$ROOT/tests/unit" \
  -FU"$OUT" -FE"$OUT" "$ROOT/tests/unit/test_role_diff.pas" > "$OUT/diff-build.log"
"$OUT/cargo-target/release/test_role_diff_rs" "$SEED" "$NP" "$OUT" "$NU"
"$OUT/test_role_diff" "$OUT"
"$OUT/test_role_diff" "$OUT" --guard
echo "differential: all runs match hyper"
