#!/bin/bash
# Idle keep-alive memory (design m3-transport.md 7.6, step S10): VmRSS of a
# server before and with N idle keep-alive connections (bench/idle.py: one
# request each, then idle), per connection = (with - before) / N. Both
# servers as in bench/run_gate.sh (4 threads on CPUs 0-3); the client runs
# on CPUs 4-15. The RSS with the connections is read 2 s and 5 s after the
# last response (bearings' loops give pooled blocks back after 2 s idle, 1.8).
# RUNS runs per server, alternating; per-connection medians.
#
# Usage: bench/idle_rss.sh <run_gate out dir (bin/, hyper-target/)> [out dir]
# Env: N (10000), RUNS (3), SERVER_CPUS (0-3), SERVER_THREADS (4)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G=$1
OUT=${2:-$G/idle}
N=${N:-10000}
RUNS=${RUNS:-3}
SERVER_CPUS=${SERVER_CPUS:-0-3}
SERVER_THREADS=${SERVER_THREADS:-4}
HB=$G/hyper-target/release/hyper-tfb
PB=$G/bin/plaintext
mkdir -p "$OUT"
LOG=$OUT/idle.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
ulimit -n 65536
say "idle_rss $(date '+%Y-%m-%d %H:%M:%S'); N=$N RUNS=$RUNS; load average before: $(cut -d' ' -f1-3 /proc/loadavg)"
one() {   # name
  local NAME=$1 PORT=18805 S R0 R2 R5 line
  if [ "$NAME" = hyper ]; then
    THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$HB" $PORT 2>/dev/null & S=$!
  else
    SERVER=hyper THREADS=$SERVER_THREADS taskset -c "$SERVER_CPUS" "$PB" $PORT 2>/dev/null & S=$!
  fi
  sleep 1
  R0=$(awk '/VmRSS/{print $2}' /proc/$S/status)
  coproc IDLE { taskset -c 4-15 python3 -I "$ROOT/bench/idle.py" $PORT "$N"; }
  read -r line <&"${IDLE[0]}"
  sleep 2; R2=$(awk '/VmRSS/{print $2}' /proc/$S/status)
  sleep 3; R5=$(awk '/VmRSS/{print $2}' /proc/$S/status)
  echo >&"${IDLE[1]}"
  wait "$IDLE_PID" 2>/dev/null || true
  kill $S; wait $S 2>/dev/null || true
  say "$NAME: $line; RSS before $R0 KB; with $N idle connections: $R2 KB at 2 s, $R5 KB at 5 s; per connection $(( (R2 - R0) * 1024 / N )) B at 2 s, $(( (R5 - R0) * 1024 / N )) B at 5 s"
  echo "$NAME $(( (R2 - R0) * 1024 / N )) $(( (R5 - R0) * 1024 / N )) $R0 $R5" >> "$OUT/raw.txt"
}
: > "$OUT/raw.txt"
I=1
while [ $I -le "$RUNS" ]; do
  if [ $((I % 2)) = 1 ]; then one hyper; one bearings; else one bearings; one hyper; fi
  I=$((I + 1))
done
for NAME in hyper bearings; do
  say "$NAME median bytes per idle connection: at 2 s $(awk -v n=$NAME '$1==n{print $2}' "$OUT/raw.txt" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'), at 5 s $(awk -v n=$NAME '$1==n{print $3}' "$OUT/raw.txt" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
done
