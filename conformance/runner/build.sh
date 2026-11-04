#!/bin/sh
# Builds the conformance case runner and the dumb server (conformance/SPEC.md,
# section 1) and runs the runner's self-test.
# Usage: conformance/runner/build.sh
# Env: OUT_DIR (default build/conformance; the binaries are $OUT_DIR/runner and
#      $OUT_DIR/dumb-server).
# The runner uses no Bearings unit: it shares no code with the server it checks.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/conformance}
U="$OUT/units-runner"
mkdir -p "$OUT" "$U"
fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -Fu"$ROOT/conformance/runner" -FU"$U" \
  -o"$OUT/runner" "$ROOT/conformance/runner/runner.pas"
fpc -Mobjfpc -Sh -O2 -gl -FU"$U" -o"$OUT/dumb-server" "$ROOT/conformance/dumb-server/dumbserver.pas"
"$OUT/runner" selftest
