#!/bin/sh
# The echo test: 1 GB with random split sizes under valgrind without errors
# (docs/design.md section 9).
# Builds tests/unit/test_rt_echo.pas with the unit-test flags, runs the echo
# server under valgrind memcheck and the client natively, and checks: client
# verified every byte, server exited 0, valgrind reported 0 errors.
# Usage: tests/unit/test_rt_echo.sh [bytes] [seed]     (default 1073741824 1)
# Env: OUT_DIR build directory (default build/unit);
#      VALGRIND valgrind command (default: build/tools/bin/valgrind, from
#      tools/get-tools.sh);
#      NO_VALGRIND=1 runs the server natively (quick check, no valgrind).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/unit}
BYTES=${1:-1073741824}
SEED=${2:-1}
VG=${VALGRIND:-$ROOT/build/tools/bin/valgrind}
# own unit directory: this build uses -dWD_DEBUG, the unit tests do not
UO="$OUT/test_rt_echo.units"
mkdir -p "$OUT" "$UO"
FU="-Fu$ROOT/src/rt -Fu$ROOT/src/http -Fu$ROOT/src/http1"
# shellcheck disable=SC2086
if ! fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -dWD_DEBUG $FU -FU"$UO" -FE"$OUT" \
    "$ROOT/tests/unit/test_rt_echo.pas" > "$OUT/test_rt_echo.build.log" 2>&1; then
  echo "test_rt_echo: BUILD FAILED (see $OUT/test_rt_echo.build.log)"
  exit 1
fi
PORTF="$OUT/test_rt_echo.port"
VGLOG="$OUT/test_rt_echo.valgrind.log"
rm -f "$PORTF" "$VGLOG"
if [ "${NO_VALGRIND:-0}" = 1 ]; then
  "$OUT/test_rt_echo" --server > "$PORTF" &
else
  $VG --tool=memcheck --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
    --log-file="$VGLOG" \
    "$OUT/test_rt_echo" --server > "$PORTF" &
fi
SPID=$!
I=0
while ! grep -q '^port ' "$PORTF" 2>/dev/null; do
  I=$((I + 1))
  if [ $I -gt 300 ]; then echo "test_rt_echo: server did not start"; kill $SPID; exit 1; fi
  sleep 0.1
done
PORT=$(awk '/^port /{print $2}' "$PORTF")
if "$OUT/test_rt_echo" --client "$PORT" "$BYTES" "$SEED"; then CR=0; else CR=$?; fi
if wait $SPID; then SR=0; else SR=$?; fi
echo "test_rt_echo: bytes=$BYTES client exit $CR, server exit $SR"
if [ "${NO_VALGRIND:-0}" != 1 ]; then
  grep -E 'ERROR SUMMARY|definitely lost|indirectly lost|Invalid|uninitialised' "$VGLOG" | head -20
fi
if [ "$CR" -eq 0 ] && [ "$SR" -eq 0 ]; then
  echo "test_rt_echo: passed"
  exit 0
fi
echo "test_rt_echo: FAILED"
exit 1
