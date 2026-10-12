#!/bin/sh
# The M3 performance gate (docs/design.md section 9, the performance gate):
# hyper-tfb (bench/hyper-tfb, hyper 1.12.0 rev 7f67699) vs bench/plaintext in
# configuration B: both servers with 4 loops/threads pinned to CPUs 0-3, wrk
# (build/tools/bin/wrk, tools/get-tools.sh) on CPUs 4-15 with 12 threads;
# bench/compare.py: per cell (c256/c1024 x depth 1/16) a 10 s warm-up, then
# RUNS runs of DUR s per server, alternating, median of the runs that were
# not client-bound. Gate: every cell >= 0.80 x hyper (exit status 1 if not).
#
# Before the gate run the response bytes of both servers are compared with
# cmp (bench/resp_bytes.py: single, 16 pipelined, 404, close, HTTP/1.0;
# plaintext runs with SERVER=hyper so the server header is the same); a
# difference stops the script (exit 2). Also recorded: governor, load
# average before and after, VmRSS of both servers every second, VmHWM.
#
# Usage: bench/run_gate.sh [out dir (default build/gate)]
# Env: RUNS (5), DUR (30), WARM (10), CELLS, WRK, BUILD=0 (reuse the binaries
#      in the out dir), GATE (0.80); the CPU split (default configuration B):
#      SERVER_CPUS (0-3), SERVER_THREADS (4), WRK_CPUS (4-15), WRK_THREADS (12);
#      configuration A of 7.6: SERVER_CPUS=0-7 SERVER_THREADS=8 WRK_CPUS=8-15
#      WRK_THREADS=8
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/gate}
WRK=${WRK:-$ROOT/build/tools/bin/wrk}
GATE=${GATE:-0.80}
SERVER_CPUS=${SERVER_CPUS:-0-3}
SERVER_THREADS=${SERVER_THREADS:-4}
WRK_CPUS=${WRK_CPUS:-4-15}
WRK_THREADS=${WRK_THREADS:-12}
export SERVER_CPUS WRK_CPUS WRK_THREADS
mkdir -p "$OUT/bin" "$OUT/u"
[ -x "$WRK" ] || { echo "run_gate: no wrk at $WRK (run tools/get-tools.sh)"; exit 2; }
if [ "${BUILD:-1}" = 1 ]; then
  CARGO_TARGET_DIR="$OUT/hyper-target" cargo build --quiet --offline --release \
    --manifest-path "$ROOT/bench/hyper-tfb/Cargo.toml" > "$OUT/hyper-build.log" 2>&1 \
    || { echo "run_gate: hyper-tfb build FAILED (see $OUT/hyper-build.log)"; exit 2; }
  rm -rf "$OUT/u"; mkdir -p "$OUT/u"
  fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http" -Fu"$ROOT/src/http1" \
    -Fu"$ROOT/src/server" -FU"$OUT/u" -FE"$OUT/bin" "$ROOT/bench/plaintext.pas" > "$OUT/fpc-build.log" 2>&1 \
    || { echo "run_gate: plaintext build FAILED (see $OUT/fpc-build.log)"; exit 2; }
fi
HB=$OUT/hyper-target/release/hyper-tfb
PB=$OUT/bin/plaintext
LOG=$OUT/gate.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
say "run_gate $(date '+%Y-%m-%d %H:%M:%S'); governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
say "load average before: $(cut -d' ' -f1-3 /proc/loadavg)"
say "servers: $SERVER_THREADS threads on CPUs $SERVER_CPUS; wrk: $WRK_THREADS threads on CPUs $WRK_CPUS"
HP=18801; PP=18802
THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$HB" $HP 2>/dev/null & H=$!
SERVER=hyper THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$PB" $PP 2>/dev/null & P=$!
S=
cleanup() {
  [ -n "$S" ] && kill "$S" 2>/dev/null || true
  kill "$H" "$P" 2>/dev/null || true
  wait "$H" "$P" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
python3 -I "$ROOT/bench/resp_bytes.py" $HP "$OUT/resp.hyper"
python3 -I "$ROOT/bench/resp_bytes.py" $PP "$OUT/resp.bearings"
if cmp "$OUT/resp.hyper" "$OUT/resp.bearings" >> "$LOG" 2>&1; then
  say "response bytes: identical ($(wc -c < "$OUT/resp.hyper") bytes over 5 cases, date normalized)"
else
  say "response bytes DIFFER: cmp $OUT/resp.hyper $OUT/resp.bearings"
  exit 2
fi
( while kill -0 "$H" 2>/dev/null && kill -0 "$P" 2>/dev/null; do
    echo "$(date +%s) $(awk '/VmRSS/{print $2}' /proc/$H/status) $(awk '/VmRSS/{print $2}' /proc/$P/status)"
    sleep 1
  done ) > "$OUT/rss.txt" &
S=$!
rm -f "$OUT/compare.txt"
if WRK=$WRK OUT=$OUT/compare.txt python3 -I "$ROOT/bench/compare.py" hyper $HP "$H" bearings $PP "$P" \
    > "$OUT/compare.log" 2>&1; then CR=0; else CR=$?; fi
say "VmHWM hyper $(awk '/VmHWM/{print $2}' /proc/$H/status) KB, bearings $(awk '/VmHWM/{print $2}' /proc/$P/status) KB"
say "max VmRSS (1 s samples): hyper $(awk 'BEGIN{m=0}{if($2>m)m=$2}END{print m}' "$OUT/rss.txt") KB, bearings $(awk 'BEGIN{m=0}{if($3>m)m=$3}END{print m}' "$OUT/rss.txt") KB"
say "load average after: $(cut -d' ' -f1-3 /proc/loadavg)"
grep -E '^\| c[0-9]' "$OUT/compare.txt" | tee -a "$LOG" > "$OUT/summary.txt"
if [ "$CR" -ne 0 ]; then
  say "run_gate: compare.py exit $CR (see $OUT/compare.log)"
  exit 1
fi
if awk -F'|' -v g="$GATE" '{r=$5+0; if (r < g) bad=1} END{exit bad?0:1}' "$OUT/summary.txt"; then
  say "run_gate: FAILED (a cell below $GATE x hyper)"
  exit 1
fi
say "run_gate: passed (every cell >= $GATE x hyper)"
