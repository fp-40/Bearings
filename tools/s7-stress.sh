#!/bin/sh
# Step S7 evidence (design m3-transport.md 9 S7, 7.5; deviation S7-34): the
# end-to-end worker stress (tests/unit/stress_workers.pas: TServer +
# dispatcher + 16 workers, 24 client threads, 13 handler modes, a second
# Share holder, random disconnects and RSTs, pipelining). It must print
# "STRESS PASSED" for every seed: no wrong body byte, no clean end of a body
# that did not end, no hang, no assertion in a handler or on a loop, every
# exchange freed. Then the -dWD_DRD (cmem) build runs under
# valgrind --tool=drd with tools/drd.supp: 0 errors and "STRESS PASSED".
# Usage: tools/s7-stress.sh
# Env: OUT_DIR (default build/s7-stress); SEEDS (native seeds, default 10);
#      CLIENTS / CONNS (native, default 24 / 150); DRD_RUNS (default 3);
#      DRD_CLIENTS / DRD_CONNS (default 12 / 20); VALGRIND (default
#      build/tools/bin/valgrind); STOP_EARLY_MS (also run each native seed
#      once more with the server destroyed while traffic runs, default 300;
#      0 = no such run).
# Under drd every thread runs in turn (one lock, --fair-sched=yes), and a
# request of handler mode 8 (Read in 1-13 byte pieces with busy waits) took
# up to 74 s (max_request_ms, build/S7-fix5/m8), up to 123 s in a mixed
# run (drd run 3, seed 316187: max_request_ms=115635 for the fifth S7 race
# verifier, 122550 in build/S7-fix6/s7-stress; 104 s in build/S7-fix5),
# all on a loaded machine: the client's receive
# timeout under drd is 600 s, so a "hang" there is a request that never
# completes, not a slow one. The maximum depends on the load on the CPUs;
# it is reported per run (max_request_ms), not bounded by this comment.
# Exit status 0 only when every run passed.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/s7-stress}
mkdir -p "$OUT/u" "$OUT/drd/u"
OUT=$(cd "$OUT" && pwd)
FU="-Fu$ROOT/src/rt -Fu$ROOT/src/http -Fu$ROOT/src/http1 -Fu$ROOT/src/server -Fu$ROOT/tests/support -Fu$ROOT/tests/unit"
VG=${VALGRIND:-$ROOT/build/tools/bin/valgrind}
FAIL=0
# shellcheck disable=SC2086
if ! fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa $FU -FU"$OUT/u" -FE"$OUT" \
    "$ROOT/tests/unit/stress_workers.pas" > "$OUT/build.log" 2>&1; then
  echo "stress_workers: BUILD FAILED (see $OUT/build.log)"
  exit 1
fi
STOP=${STOP_EARLY_MS:-300}
I=1
while [ "$I" -le "${SEEDS:-10}" ]; do
  S=$((1000 + I * 7919))
  for MODE in normal stop; do
    if [ "$MODE" = stop ] && [ "$STOP" -eq 0 ]; then continue; fi
    SE=0
    if [ "$MODE" = stop ]; then SE=$STOP; fi
    if SEED=$S CLIENTS=${CLIENTS:-24} CONNS=${CONNS:-150} STOP_EARLY_MS=$SE \
        timeout 600 "$OUT/stress_workers" > "$OUT/s$I-$MODE.out" 2> "$OUT/s$I-$MODE.err"; then R=0; else R=$?; fi
    L=$(grep -E '^(requests|violations|head_write|streams)' "$OUT/s$I-$MODE.out" | tr '\n' ' ')
    echo "stress seed $S ($MODE): exit $R $L"
    if [ "$R" -ne 0 ] || ! grep -q 'STRESS PASSED' "$OUT/s$I-$MODE.out"; then FAIL=1; fi
  done
  I=$((I + 1))
done
# shellcheck disable=SC2086
if ! fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -dWD_DRD $FU -FU"$OUT/drd/u" -FE"$OUT/drd" \
    "$ROOT/tests/unit/stress_workers.pas" > "$OUT/drd/build.log" 2>&1; then
  echo "stress_workers (drd): BUILD FAILED (see $OUT/drd/build.log)"
  exit 1
fi
if ! { [ -x "$VG" ] || command -v "$VG" > /dev/null 2>&1; }; then
  echo "stress_workers (drd): FAILED: no valgrind at $VG (run tools/get-tools.sh, or set VALGRIND)"
  exit 1
fi
I=1
while [ "$I" -le "${DRD_RUNS:-3}" ]; do
  S=$((2000 + I * 104729))
  SE=0
  # every second run destroys the server while traffic runs
  if [ $((I % 2)) -eq 0 ]; then SE=1500; fi
  if (cd "$OUT/drd" && SEED=$S CLIENTS=${DRD_CLIENTS:-12} CONNS=${DRD_CONNS:-20} STOP_EARLY_MS=$SE \
      RCV_TIMEOUT_S=600 timeout 3600 "$VG" --tool=drd --fair-sched=yes \
      --suppressions="$ROOT/tools/drd.supp" ./stress_workers > "run-$I.out" 2> "run-$I.err"); then R=0; else R=$?; fi
  DE=$(sed -n 's/.*ERROR SUMMARY: \([0-9]*\) errors.*/\1/p' "$OUT/drd/run-$I.err" | tail -n 1)
  L=$(grep -E '^(requests|violations|head_write|streams)' "$OUT/drd/run-$I.out" | tr '\n' ' ')
  echo "stress drd run $I (seed $S, stop $SE): exit $R, drd errors: ${DE:-?} $L"
  if [ "$R" -ne 0 ] || [ "${DE:-x}" != "0" ] || ! grep -q 'STRESS PASSED' "$OUT/drd/run-$I.out"; then FAIL=1; fi
  I=$((I + 1))
done
[ "$FAIL" -eq 0 ] && echo "s7-stress: passed" || echo "s7-stress: FAILED"
exit $FAIL
