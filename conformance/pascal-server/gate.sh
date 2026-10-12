#!/bin/sh
# Conformance gate, inline executor (design m3-transport.md 7.4, 9 S6, T1):
# builds wdconf and runs the wire cases against it in assertion mode.
#   1. the 105 cases, RUNS times in a row: every run must print
#      "SUMMARY passed=104 failed=0 pending=1 total=105";
#   2. the extra cases (extra/extra-cases.json: SPEC behaviors the 105 cases
#      do not reach) once: every case must pass.
# Step T1 (user decision 2026-10-08) removed the diff-mode gate (same=104 in
# 5 runs, also under cpu-burn, classify_diff.py, the runner's --settle-ms):
# byte-identical transcripts and event timing are not goals. With DIFF=1 the
# script also runs diff mode against reference-server once, as a report
# (printed, never a failure). With LOOPS=N the server runs as
# `wdconf --loops N` (S8: N loops sharing one listener, amSharedExclusive;
# the 7.4 gate is LOOPS=4 RUNS=3) and the logs go to $OUT_DIR/gate-loopsN/.
# Logs: $OUT_DIR/gate/. Exit status 0 when every check passes, 1 otherwise.
# Usage: conformance/pascal-server/gate.sh
# Env: OUT_DIR (default build/conformance), PROFILE (debug | release, see
#      build.sh), RUNS (default 5), DIFF (default 0), LOOPS (default: none,
#      one loop).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONF=$ROOT/conformance
OUT=${OUT_DIR:-$ROOT/build/conformance}
RUNS=${RUNS:-5}
LOG=$OUT/gate${LOOPS:+-loops$LOOPS}
mkdir -p "$LOG"
OUT_DIR=$OUT sh "$CONF/pascal-server/build.sh" > "$LOG/build.log" 2>&1 || {
  echo "gate: wdconf build FAILED (see $LOG/build.log)"; exit 1; }
(cd "$CONF" && cargo build --release --offline --quiet) > "$LOG/cargo.log" 2>&1 || {
  echo "gate: runner build FAILED (see $LOG/cargo.log)"; exit 1; }
W="$OUT/wdconf${LOOPS:+ --loops $LOOPS}"
RUNNER=$CONF/target/release/runner
REF=$CONF/target/release/reference-server
CASES=$CONF/cases/h1
EXTRA=$CONF/pascal-server/extra/extra-cases.json
WANT_RUN='SUMMARY passed=104 failed=0 pending=1 total=105'
WANT_EXTRA='SUMMARY passed=25 failed=0 pending=0 total=25'
FAIL=0
echo "gate: load before: $(cat /proc/loadavg)"

check() {   # name, log file, expected summary
  S=$(tail -n 1 "$2")
  if [ "$S" = "$3" ]; then echo "$1: $S"; else echo "$1: FAILED: $S (see $2)"; FAIL=1; fi
}

I=1
while [ "$I" -le "$RUNS" ]; do
  "$RUNNER" run --server "$W" "$CASES" > "$LOG/run-$I.log" 2>&1 || true
  check "assertion run $I" "$LOG/run-$I.log" "$WANT_RUN"
  I=$((I + 1))
done
"$RUNNER" run --server "$W" "$EXTRA" > "$LOG/extra.log" 2>&1 || true
check "extra cases, assertion mode" "$LOG/extra.log" "$WANT_EXTRA"
if [ "${DIFF:-0}" = 1 ]; then
  "$RUNNER" diff --a "$REF" --b "$W" "$CASES" > "$LOG/diff-report.log" 2>&1 || true
  echo "report only, diff mode vs reference-server: $(tail -n 1 "$LOG/diff-report.log")"
fi
echo "gate: load after: $(cat /proc/loadavg)"
if [ "$FAIL" -eq 0 ]; then
  echo "gate: passed"
  exit 0
fi
echo "gate: FAILED"
exit 1
