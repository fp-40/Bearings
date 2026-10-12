#!/bin/sh
# Fixed-rate latency (docs/design.md section 9, the performance gate): p50 / p99 /
# p99.9 from wrk2 (build/tools/bin/wrk2, tools/get-tools.sh) at 50 % and 80 %
# of hyper's measured maximum requests/s, depth 1, hyper-tfb vs plaintext.
# Both servers as in bench/run_gate.sh (configuration B by default: 4
# threads on CPUs 0-3; wrk2 on CPUs 4-15 with 12 threads, TFB headers).
# The rates come from a run_gate.sh summary (hyper's median req/s per cell).
# Per cell and rate: RUNS runs of DUR s per server, alternating servers;
# the median of each percentile over the runs. wrk2 spends the first 10 s of
# a run calibrating and leaves them out of its histogram (DUR >= 20).
#
# Usage: bench/p99.sh <run_gate out dir (bin/, hyper-target/, summary.txt)> [out dir]
# Env: RUNS (3), DUR (40), CELLS ("256 1024"), RATES ("0.50 0.80"), WRK2,
#      SERVER_CPUS (0-3), SERVER_THREADS (4), WRK_CPUS (4-15), WRK_THREADS (12)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G=$1
OUT=${2:-$G/p99}
WRK2=${WRK2:-$ROOT/build/tools/bin/wrk2}
RUNS=${RUNS:-3}
DUR=${DUR:-40}
CELLS=${CELLS:-256 1024}
RATES=${RATES:-0.50 0.80}
SERVER_CPUS=${SERVER_CPUS:-0-3}
SERVER_THREADS=${SERVER_THREADS:-4}
WRK_CPUS=${WRK_CPUS:-4-15}
WRK_THREADS=${WRK_THREADS:-12}
HB=$G/hyper-target/release/hyper-tfb
PB=$G/bin/plaintext
[ -x "$WRK2" ] || { echo "p99: no wrk2 at $WRK2"; exit 2; }
[ -x "$HB" ] && [ -x "$PB" ] && [ -f "$G/summary.txt" ] || { echo "p99: $G lacks the gate binaries or summary.txt"; exit 2; }
mkdir -p "$OUT/raw"
LOG=$OUT/p99.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
say "p99 $(date '+%Y-%m-%d %H:%M:%S'); governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?'); RUNS=$RUNS DUR=$DUR"
say "load average before: $(cut -d' ' -f1-3 /proc/loadavg)"
HP=18803; PP=18804
THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$HB" $HP 2>/dev/null & H=$!
SERVER=hyper THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$PB" $PP 2>/dev/null & P=$!
trap 'kill $H $P 2>/dev/null || true; wait $H $P 2>/dev/null || true' EXIT
sleep 1
# ms value of a wrk2 percentile line ("  99.000%    1.23ms")
pct() {
  awk -v p="$2" '$1 == p { v=$2;
      if (v ~ /us$/) { sub(/us$/, "", v); v = v / 1000 }
      else if (v ~ /ms$/) { sub(/ms$/, "", v); v = v + 0 }
      else if (v ~ /m$/) { sub(/m$/, "", v); v = v * 60000 }
      else if (v ~ /s$/) { sub(/s$/, "", v); v = v * 1000 }
      print v; exit }' "$1"
}
rps() { awk '/^Requests\/sec:/{print $2; exit}' "$1"; }
med() { tr ' ' '\n' | grep -v '^$' | sort -g | awk '{a[NR]=$1} END{ if (NR==0) print "nan"; else if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'; }
SUM=$OUT/summary.txt
: > "$SUM"
for C in $CELLS; do
  MAX=$(awk -F'|' -v c="c$C d1" '{x=$2; gsub(/^ +| +$/, "", x); if (x == c) {print $3+0; exit}}' "$G/summary.txt")
  [ -n "$MAX" ] || { echo "p99: no hyper rate for c$C d1 in $G/summary.txt"; exit 2; }
  for F in $RATES; do
    R=$(awk -v m="$MAX" -v f="$F" 'BEGIN{printf "%d", m * f}')
    for N in hyper bearings; do eval "L_${N}_50=; L_${N}_99=; L_${N}_999=; L_${N}_rps=; L_${N}_err="; done
    I=1
    while [ $I -le "$RUNS" ]; do
      if [ $((I % 2)) = 1 ]; then ORDER="hyper bearings"; else ORDER="bearings hyper"; fi
      for N in $ORDER; do
        if [ $N = hyper ]; then PORT=$HP; else PORT=$PP; fi
        F1=$OUT/raw/c$C-r$F-$N-$I.txt
        taskset -c "$WRK_CPUS" "$WRK2" -t"$WRK_THREADS" -c"$C" -d"${DUR}s" -R"$R" --latency \
          -H 'Host: tfb-server' \
          -H 'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7' \
          -H 'Connection: keep-alive' "http://127.0.0.1:$PORT/plaintext" > "$F1" 2>&1 || true
        A50=$(pct "$F1" 50.000%); A99=$(pct "$F1" 99.000%); A999=$(pct "$F1" 99.900%); AR=$(rps "$F1")
        AE=$(grep -E 'Socket errors|Non-2xx' "$F1" | tr -s ' ' | tr '\n' ' ' || true)
        say "c$C rate $R ($F x hyper max $MAX) run $I $N: req/s $AR p50 ${A50}ms p99 ${A99}ms p99.9 ${A999}ms $AE"
        eval "L_${N}_50=\"\$L_${N}_50 $A50\"; L_${N}_99=\"\$L_${N}_99 $A99\"; L_${N}_999=\"\$L_${N}_999 $A999\"; L_${N}_rps=\"\$L_${N}_rps $AR\""
      done
      I=$((I + 1))
    done
    for N in hyper bearings; do
      eval "M50=\$(echo \$L_${N}_50 | med); M99=\$(echo \$L_${N}_99 | med); M999=\$(echo \$L_${N}_999 | med); MR=\$(echo \$L_${N}_rps | med)"
      echo "c$C $F $R $N $MR $M50 $M99 $M999" >> "$SUM"
    done
  done
done
say "load average after: $(cut -d' ' -f1-3 /proc/loadavg)"
say ""
say "| cell | rate (x hyper max) | server | achieved req/s | p50 ms | p99 ms | p99.9 ms |"
say "|---|---|---|---:|---:|---:|---:|"
while read -r C F R N MR M50 M99 M999; do
  say "| $C d1 | $R ($F) | $N | $MR | $M50 | $M99 | $M999 |"
done < "$SUM"
