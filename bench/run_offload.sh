#!/bin/sh
# The S7 offload-cost gate (docs/design.md section 2): CPU per
# request of bench/plaintext answering every request on the loop (inline)
# against the same server answering every request from its worker pool
# (OFFLOAD=1: TOffloadCall + TBlockingHandler, the pool's default size,
# Min(32, DefaultLoopCount + 4) = 8 with 4 loops, as the prototype's T3
# "pool, 8 workers"), in configuration B: both servers with 4 loops pinned
# to CPUs 0-3 (the workers run on the same CPUs), wrk on CPUs 4-15 with 12
# threads, depth 1 (c256 and c1024). bench/compare.py runs the cells
# (10 s warm-up, RUNS alternating runs of DUR s, median of the runs that
# were not client-bound) and reports requests per server CPU-second; the
# offload cost per cell is 1e6 / (offload req/CPU-s) - 1e6 / (inline
# req/CPU-s) microseconds. Gate: every cell <= LIMIT (5.4 us, the
# prototype's measured offload cost at depth 1).
#
# Before the runs the response bytes of both servers are compared with cmp
# (bench/resp_bytes.py); a difference stops the script (exit 2).
# Recorded: governor, load average before and after.
#
# Usage: bench/run_offload.sh [out dir (default build/offload)]
# Env: RUNS (5), DUR (30), WARM (10), CELLS ("256:1 1024:1"), WRK, LIMIT
#      (5.4), BUILD=0 (reuse the binary in the out dir)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/offload}
WRK=${WRK:-$ROOT/build/tools/bin/wrk}
LIMIT=${LIMIT:-5.4}
mkdir -p "$OUT/bin" "$OUT/u"
[ -x "$WRK" ] || { echo "run_offload: no wrk at $WRK (run tools/get-tools.sh)"; exit 2; }
if [ "${BUILD:-1}" = 1 ]; then
  rm -rf "$OUT/u"; mkdir -p "$OUT/u"
  fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http" -Fu"$ROOT/src/http1" \
    -Fu"$ROOT/src/server" -FU"$OUT/u" -FE"$OUT/bin" "$ROOT/bench/plaintext.pas" > "$OUT/fpc-build.log" 2>&1 \
    || { echo "run_offload: plaintext build FAILED (see $OUT/fpc-build.log)"; exit 2; }
fi
PB=$OUT/bin/plaintext
LOG=$OUT/offload.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
say "run_offload $(date '+%Y-%m-%d %H:%M:%S'); governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
say "load average before: $(cut -d' ' -f1-3 /proc/loadavg)"
IP=18821; OP=18822
SERVER=hyper THREADS=4 taskset -c 0-3 "$PB" $IP 2>/dev/null & I=$!
SERVER=hyper OFFLOAD=1 THREADS=4 taskset -c 0-3 "$PB" $OP 2>/dev/null & O=$!
cleanup() {
  kill "$I" "$O" 2>/dev/null || true
  wait "$I" "$O" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
say "offload server threads: $(ls /proc/$O/task | wc -l) (4 loops + workers + main), inline: $(ls /proc/$I/task | wc -l)"
python3 -I "$ROOT/bench/resp_bytes.py" $IP "$OUT/resp.inline"
python3 -I "$ROOT/bench/resp_bytes.py" $OP "$OUT/resp.offload"
if cmp "$OUT/resp.inline" "$OUT/resp.offload" >> "$LOG" 2>&1; then
  say "response bytes: identical ($(wc -c < "$OUT/resp.inline") bytes over 5 cases, date normalized)"
else
  say "response bytes DIFFER: cmp $OUT/resp.inline $OUT/resp.offload"
  exit 2
fi
rm -f "$OUT/compare.txt"
if CELLS=${CELLS:-256:1 1024:1} WRK=$WRK OUT=$OUT/compare.txt python3 -I "$ROOT/bench/compare.py" \
    inline $IP "$I" offload $OP "$O" > "$OUT/compare.log" 2>&1; then CR=0; else CR=$?; fi
say "load average after: $(cut -d' ' -f1-3 /proc/loadavg)"
grep -E '^\| c[0-9]' "$OUT/compare.txt" | tee -a "$LOG" > "$OUT/summary.txt"
if [ "$CR" -ne 0 ]; then
  say "run_offload: compare.py exit $CR (see $OUT/compare.log)"
  exit 1
fi
# columns: | cell | inline rps | offload rps | ratio | inline req/CPU-s | offload req/CPU-s | ratio | cb |
if awk -F'|' -v lim="$LIMIT" '
    { ei=$6+0; eo=$7+0; ci=1e6/ei; co=1e6/eo; d=co-ci;
      printf "%s: inline %.2f us/request, offload %.2f us/request, offload cost %.2f us (limit %s)\n", $2, ci, co, d, lim;
      if (d > lim) bad=1 }
    END { exit bad?1:0 }' "$OUT/summary.txt" | tee -a "$LOG"; then
  :
fi
if awk -F'|' -v lim="$LIMIT" '{ d=1e6/($7+0)-1e6/($6+0); if (d > lim) bad=1 } END{exit bad?0:1}' "$OUT/summary.txt"; then
  say "run_offload: FAILED (a cell above $LIMIT us)"
  exit 1
fi
say "run_offload: passed (every cell <= $LIMIT us)"
