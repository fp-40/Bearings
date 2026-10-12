#!/bin/sh
# CPU load generator for the "under stress-ng --cpu 16" runs (design
# m3-transport.md 9, S6 exit criterion; decision 12). When stress-ng is on
# PATH, "stress-ng --cpu N" runs; otherwise (stress-ng is not installed on
# this machine and has many dependencies) N busy processes run, a shell loop
# each with no syscalls in the loop. Either way they are killed when this
# script exits: on SIGINT/SIGTERM/SIGHUP (at once: the script itself only
# waits, so the trap runs as soon as the signal arrives), at the end of the
# optional duration, or when the command given after "--" finishes.
# SIGKILL cannot be trapped: kill the script with TERM, INT or HUP.
#
# Usage: tools/cpu-burn.sh N [seconds]           burn for seconds (default: until killed)
#        tools/cpu-burn.sh N -- command [args]   burn while command runs; exit with its status
#                                                (a signal to this script also stops the command)
# Env: CPU_BURN_STRESS_NG=0 uses the shell loops even when stress-ng is on PATH.
set -eu
N=${1:?usage: cpu-burn.sh N [seconds] | N -- command}
shift
PIDS=""
W=""
cleanup() {
  trap - EXIT INT TERM HUP
  for P in $W $PIDS; do kill "$P" 2>/dev/null || true; done
  for P in $W $PIDS; do wait "$P" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [ "${CPU_BURN_STRESS_NG:-1}" != 0 ] && command -v stress-ng > /dev/null 2>&1; then
  stress-ng --cpu "$N" --quiet &
  PIDS=$!
else
  I=0
  while [ "$I" -lt "$N" ]; do
    sh -c 'while :; do :; done' &
    PIDS="$PIDS $!"
    I=$((I + 1))
  done
fi
# Whatever the script waits for runs in the background and the script waits
# with the wait builtin, which a trapped signal interrupts (a foreground
# child would delay the trap until it exits).
if [ "${1:-}" = "--" ]; then
  shift
  # an asynchronous command gets /dev/null as stdin unless redirected:
  # hand it the script's stdin through fd 3
  exec 3<&0
  "$@" <&3 3<&- &
  W=$!
  if wait "$W"; then R=0; else R=$?; fi
  W=""
  exit $R
elif [ -n "${1:-}" ]; then
  sleep "$1" &
  W=$!
  wait "$W" || true
  W=""
else
  while :; do
    sleep 3600 &
    W=$!
    wait "$W" || true
    W=""
  done
fi
