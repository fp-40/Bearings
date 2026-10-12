#!/bin/sh
# Conformance gate, worker executor (design m3-transport.md 7.4, 9 S7, T1):
# builds wdconf and runs the wire cases against `wdconf --executor worker`
# in assertion mode.
#   1. the 105 cases, RUNS times: every run must print
#      "SUMMARY passed=104 failed=0 pending=1 total=105", except that a case
#      listed in worker-exceptions.txt may fail (only
#      chunk2::pipeline_enabled: S7 decision 14, deviation S7-1); the output
#      names the exception whenever it was used;
#   2. the extra cases (extra/extra-cases.json) once: every case must pass;
#   3. the evidence for the exception (extra/worker-probe.json):
#      reference-server must fail both probe cases in assertion mode (hyper
#      fails the same wire assertion when its second handler is Pending at
#      its first poll), and so must `wdconf --executor worker`.
# Step T1 (user decision 2026-10-08) removed the diff-mode checks (transcripts
# SAME, the event allowlist, worker_allowlist.py, classify_diff.py, the
# runner's --settle-ms). With DIFF=1 the script also runs diff mode against
# reference-server once, as a report (printed, never a failure).
# Logs: $OUT_DIR/gate-worker/. Exit status 0 when every check passes, 1
# otherwise.
# Usage: conformance/pascal-server/gate_worker.sh
# Env: OUT_DIR (default build/conformance), PROFILE (debug | release, see
#      build.sh), RUNS (default 5), DIFF (default 0).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CONF=$ROOT/conformance
PS=$CONF/pascal-server
OUT=${OUT_DIR:-$ROOT/build/conformance}
RUNS=${RUNS:-5}
LOG=$OUT/gate-worker
mkdir -p "$LOG"
OUT_DIR=$OUT sh "$PS/build.sh" > "$LOG/build.log" 2>&1 || {
  echo "gate_worker: wdconf build FAILED (see $LOG/build.log)"; exit 1; }
(cd "$CONF" && cargo build --release --offline --quiet) > "$LOG/cargo.log" 2>&1 || {
  echo "gate_worker: runner build FAILED (see $LOG/cargo.log)"; exit 1; }
W="$OUT/wdconf --executor worker"
RUNNER=$CONF/target/release/runner
REF=$CONF/target/release/reference-server
CASES=$CONF/cases/h1
EXC=$PS/worker-exceptions.txt
WANT_RUN='SUMMARY passed=104 failed=0 pending=1 total=105'
WANT_EXTRA='SUMMARY passed=25 failed=0 pending=0 total=25'
WANT_PROBE='SUMMARY passed=0 failed=2 pending=0 total=2'
FAIL=0
echo "gate_worker: load before: $(cat /proc/loadavg)"

# the case ids listed in worker-exceptions.txt
LISTED=$(sed -n 's/^\([^#|][^|]*\)|.*/\1/p' "$EXC" | sed 's/ *$//')

I=1
while [ "$I" -le "$RUNS" ]; do
  L=$LOG/run-$I.log
  "$RUNNER" run --server "$W" "$CASES" > "$L" 2>&1 || true
  S=$(tail -n 1 "$L")
  if [ "$S" = "$WANT_RUN" ]; then
    echo "assertion run $I: $S"
  else
    U=0
    for F in $(sed -n 's/^FAIL \([^ ]*\) .*/\1/p' "$L"); do
      if ! echo "$LISTED" | grep -qx "$F"; then U=1; echo "  unlisted failure: $F"; fi
    done
    if [ "$U" -eq 0 ] && grep -q '^SUMMARY .* pending=1 total=105$' "$L"; then
      echo "assertion run $I: $S (only listed exception cases fail: $(sed -n 's/^FAIL \([^ ]*\) .*/\1/p' "$L" | tr '\n' ' '))"
    else
      echo "assertion run $I: FAILED: $S (see $L)"
      FAIL=1
    fi
  fi
  I=$((I + 1))
done

"$RUNNER" run --server "$W" "$PS/extra/extra-cases.json" > "$LOG/extra.log" 2>&1 || true
S=$(tail -n 1 "$LOG/extra.log")
if [ "$S" = "$WANT_EXTRA" ]; then echo "extra cases, assertion mode: $S"
else echo "extra cases, assertion mode: FAILED: $S (see $LOG/extra.log)"; FAIL=1; fi

"$RUNNER" run --server "$REF" "$PS/extra/worker-probe.json" > "$LOG/probe-ref.log" 2>&1 || true
S=$(tail -n 1 "$LOG/probe-ref.log")
if [ "$S" = "$WANT_PROBE" ]; then
  echo "probe, reference-server assertion mode: $S (expected: both fail)"
else
  echo "probe, reference-server assertion mode: UNEXPECTED: $S (see $LOG/probe-ref.log)"; FAIL=1
fi
"$RUNNER" run --server "$W" "$PS/extra/worker-probe.json" > "$LOG/probe-wd.log" 2>&1 || true
S=$(tail -n 1 "$LOG/probe-wd.log")
if [ "$S" = "$WANT_PROBE" ]; then
  echo "probe, wdconf --executor worker assertion mode: $S (expected: both fail, as the reference)"
else
  echo "probe, wdconf --executor worker assertion mode: UNEXPECTED: $S (see $LOG/probe-wd.log)"; FAIL=1
fi
if [ "${DIFF:-0}" = 1 ]; then
  "$RUNNER" diff --a "$REF" --b "$W" "$CASES" > "$LOG/diff-report.log" 2>&1 || true
  echo "report only, diff mode vs reference-server: $(tail -n 1 "$LOG/diff-report.log")"
fi
echo "gate_worker: load after: $(cat /proc/loadavg)"
if [ "$FAIL" -eq 0 ]; then
  echo "gate_worker: passed"
  exit 0
fi
echo "gate_worker: FAILED"
exit 1
