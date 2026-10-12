#!/bin/bash
# usage: bench2.sh <label> <port> <server_pid> [duration]
# One wrk pass over the 4 cells (c256/c1024 x depth 1/16) against a running
# server; prints rps, latency p50/p99, server CPU-seconds used during the run,
# rps per server CPU-second, RSS (moved from the M3 design-phase perf prototype,
# m3-perf-proto/bench2.sh). For the gate method of docs/design.md section 9 (alternating
# servers, 5 runs per cell, median) use bench/run_gate.sh (bench/compare.py).
# env: WRK (wrk binary; default: build/tools/bin/wrk) WRK_CPUS (default 8-15)
#      WRK_THREADS (default 8) CONNS ("256 1024") DEPTHS ("1 16")
W=${WRK:-$(cd "$(dirname "$0")/.." && pwd)/build/tools/bin/wrk}
D=$(cd "$(dirname "$0")" && pwd)
LABEL=$1; PORT=$2; SPID=$3; DUR=${4:-10}; WCPUS=${WRK_CPUS:-8-15}; WT=${WRK_THREADS:-8}
H=(-H 'Host: tfb-server' -H 'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7' -H 'Connection: keep-alive')
URL=http://127.0.0.1:$PORT/plaintext
TCK=$(getconf CLK_TCK)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cpu() { awk '{print $14+$15}' /proc/$SPID/stat; }
taskset -c $WCPUS $W -t$WT -c256 -d2s "${H[@]}" $URL >/dev/null
for C in ${CONNS:-256 1024}; do
  for P in ${DEPTHS:-1 16}; do
    T0=$(cpu)
    taskset -c $WCPUS $W -t$WT -c$C -d${DUR}s --latency "${H[@]}" -s $D/pipeline.lua $URL -- $P > "$TMP" &
    WP=$!; sleep $((DUR/2)); RSS=$(ps -o rss= -p $SPID); wait $WP
    T1=$(cpu)
    OUT=$(cat "$TMP")
    RPS=$(echo "$OUT" | awk '/Requests\/sec/{print $2}')
    P50=$(echo "$OUT" | awk '$1=="50%"{print $2}')
    P99=$(echo "$OUT" | awk '$1=="99%"{print $2}')
    ERR=$(echo "$OUT" | grep -E "Socket errors|Non-2xx" | tr '\n' ' ')
    CPUS=$(echo "scale=2; ($T1-$T0)/$TCK" | bc)
    EFF=$(echo "scale=0; $RPS*$DUR/(($T1-$T0)/$TCK)" | bc 2>/dev/null)
    echo "$LABEL c=$C depth=$P rps=$RPS p50=$P50 p99=$P99 srv_cpu_s=$CPUS req_per_cpu_s=$EFF rss_kb=$RSS $ERR"
  done
done
