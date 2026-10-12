#!/bin/sh
# System calls per request (design m3-transport.md 7.6, step S10).
# The design names `perf stat -e 'syscalls:sys_enter_*'`; on this machine
# kernel.perf_event_paranoid is 4 and tracefs is root-only, so the count
# comes from `strace -c -f` instead. kernel.yama.ptrace_scope is 1 (only a
# process's descendants can be traced), so strace starts the server: each
# server runs twice under strace, once without load for 2 + DUR + 1 s (the
# baseline: start-up, idle loop timers, exit) and once with one wrk run of
# DUR s after 2 s; per request = (loaded - baseline) / wrk's requests.
# strace stops the thread at every system call, so the server is several
# times slower while traced: the counts per request are exact for that
# run, but how many requests one read or one epoll_wait covers depends on
# speed (a slower server finds more ready work per call), so the shares of
# epoll_wait and of reads at depth 1 are not those of an untraced run.
# Both servers as in bench/run_gate.sh (4 threads on CPUs 0-3); wrk on
# CPUs 4-15 with 12 threads and TFB's headers and pipeline.lua.
#
# Usage: bench/syscalls.sh <run_gate out dir (bin/, hyper-target/)> [out dir]
# Env: DUR (10), CELLS ("256:1 256:16"), WRK
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G=$1
OUT=${2:-$G/syscalls}
DUR=${DUR:-10}
CELLS=${CELLS:-256:1 256:16}
WRK=${WRK:-$ROOT/build/tools/bin/wrk}
HB=$G/hyper-target/release/hyper-tfb
PB=$G/bin/plaintext
mkdir -p "$OUT"
LOG=$OUT/syscalls.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
say "syscalls $(date '+%Y-%m-%d %H:%M:%S'); DUR=$DUR; load average before: $(cut -d' ' -f1-3 /proc/loadavg)"
# traced NAME FILE [wrk args]: run the server under strace; with wrk args,
# one wrk run after 2 s, else idle for the same time
traced() {
  NAME=$1; F=$2; shift 2
  PORT=18806
  if [ "$NAME" = hyper ]; then
    taskset -c 4-15 strace -c -f -o "$F" env THREADS=4 taskset -c 0-3 "$HB" $PORT 2>/dev/null & T=$!
  else
    taskset -c 4-15 strace -c -f -o "$F" env SERVER=hyper THREADS=4 taskset -c 0-3 "$PB" $PORT 2>/dev/null & T=$!
  fi
  sleep 2
  if [ "$#" -gt 0 ]; then
    taskset -c 4-15 "$WRK" "$@" "http://127.0.0.1:$PORT/plaintext" -- "$D" > "$W" 2>&1 || true
  else
    sleep "$DUR"
  fi
  sleep 1
  S=$(pgrep -f "^$( [ "$NAME" = hyper ] && echo "$HB" || echo "$PB" ) $PORT\$" || true)
  [ -n "$S" ] && kill $S
  wait $T 2>/dev/null || true
}
# calls per system call name from an strace -c table
table() {
  awk '/^------/ { sep++; next }
       sep == 1 && NF >= 5 { print $NF, $4 }' "$1"
}
for CELL in $CELLS; do
  C=${CELL%%:*}; D=${CELL##*:}
  for NAME in hyper bearings; do
    F0=$OUT/strace-idle-$NAME.txt
    [ -f "$F0" ] || traced $NAME "$F0"
    F=$OUT/strace-c$C-d$D-$NAME.txt
    W=$OUT/wrk-c$C-d$D-$NAME.txt
    traced $NAME "$F" -t12 -c"$C" -d"${DUR}s" \
      -H 'Host: tfb-server' \
      -H 'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7' \
      -H 'Connection: keep-alive' -s "$ROOT/bench/pipeline.lua"
    REQ=$(awk '/requests in/{print $1; exit}' "$W")
    say "c$C d$D $NAME: $REQ requests ($(awk '/^Requests\/sec:/{print $2}' "$W") req/s under strace)"
    table "$F0" > "$OUT/t0"; table "$F" > "$OUT/t1"
    awk -v r="$REQ" -v cell="c$C-d$D" -v n="$NAME" '
      FNR == NR { base[$1] = $2; next }
      { c = $2 - base[$1]; tot += c; if (c == 0) next;
        printf "  %-16s %10d calls (idle baseline %d)  %.4f per request\n", $1, c, base[$1] + 0, c / r }
      END { printf "  %-16s %10d calls  %.4f per request\n", "total", tot, tot / r;
        printf "ROW %s %s %d %d %.4f\n", cell, n, r, tot, tot / r }' "$OUT/t0" "$OUT/t1" | tee -a "$LOG"
  done
done
rm -f "$OUT/t0" "$OUT/t1"
