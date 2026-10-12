#!/bin/sh
# Compiles every unit under src/ (and tests/support/) on its own, each in a
# fresh, empty unit output directory, so nothing compiled for another unit
# is reused. FPC fails with "Circular unit reference" when interface uses
# clauses form a cycle, so a clean run shows the interface uses graph is
# acyclic (the layer rules of README.md). Also prints the interface uses graph and
# checks it with a topological sort (tools/unit-graph.py).
# Usage: tools/compile-each-unit.sh [out_dir]   (or env OUT_DIR; the argument wins)
# Env: FPC names the compiler (default fpc; build/tools/bin/fpc-aarch64 for
#      the ARM64 cross build, tools/get-cross-aarch64.sh).
# Exit status 0 only when every unit compiles and the graph has no cycle.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-${OUT_DIR:-$ROOT/build/compile-each-unit}}
FPC=${FPC:-fpc}
rm -rf "$OUT"
mkdir -p "$OUT"
FU="-Fu$ROOT/src/rt -Fu$ROOT/src/http -Fu$ROOT/src/http1 -Fu$ROOT/src/server -Fu$ROOT/src/ws -Fu$ROOT/tests/support"
FAIL=0
N=0
for F in $(find "$ROOT/src" "$ROOT/tests/support" -name '*.pas' | sort); do
  U=$(basename "$F" .pas)
  D="$OUT/$U"
  mkdir -p "$D"
  N=$((N + 1))
  # shellcheck disable=SC2086
  if "$FPC" -Mobjfpc -Sh -O2 -vew $FU -FU"$D" "$F" > "$D/build.log" 2>&1; then
    echo "ok    $U"
  else
    echo "FAIL  $U"
    grep -E 'Error|Fatal' "$D/build.log" | head -5
    FAIL=$((FAIL + 1))
  fi
done
echo "compiled $N units on their own, $FAIL failed"
python3 -I "$ROOT/tools/unit-graph.py" "$ROOT/src" "$ROOT/tests/support"
[ "$FAIL" -eq 0 ]
