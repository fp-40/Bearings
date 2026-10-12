#!/bin/sh
# Unit-test target: builds and runs every fpcunit suite with the M2 test
# flags (-Sa assertions on; test_h1_io is the M3 S3 suite; test_h1_conn,
# test_body_chan and test_exchange are the S4 suites; test_h1_dispatch is the
# S5 suite, built with -dWD_DEBUG so the wake-source check of docs/design.md 5.10
# runs in every test (and -dWD_STALL since step UB: TTestDispatchStall);
# test_server is the S8 suite (sendfile, upgrade
# detach, stop, shared listener, signals; real sockets); test_server_ops
# covers the operations features (Unix socket listener, systemd, the
# connection limit, the access log and the metrics; real sockets);
# test_ws_frame, test_ws_handshake, test_ws_conn and test_ws_echo cover
# WebSocket (src/ws; test_ws_echo uses real sockets; test_ws_conn and
# test_ws_echo also run with heaptrc);
# test_workers is the
# S7 suite, also run under
# valgrind --tool=drd; the S4, S5 and S7 suites also run once more
# built with heaptrc (-gh), which must report 0 unfreed blocks; so does the
# S8 and operations suites), the S7
# end-to-end stress (tools/s7-stress.sh, short form), the M3 S1 echo test
# (1 GiB with random splits, under valgrind memcheck: build/tools/bin/valgrind
# from tools/get-tools.sh; a missing valgrind fails the run, decision 12),
# then the M3 S9 split fuzz (test_split_fuzz, heaptrc), then the hot-path
# asm check of docs/design.md 7.4 (tools/check-hot-asm.sh).
# Step T1 removed the conn-level differential harness (conformance/conn-diff)
# and the BytesMut table generator (tests/unit/test_bytesmut_rs).
# The differentials kept (parser vs httparse, request parsing vs hyper's
# role.rs, body decoder vs decode.rs) run from their own scripts:
# tests/unit/test_parser_diff.sh, test_role_diff.sh, test_codec_diff.sh.
# Usage: tests/unit/run_all.sh
# Env: OUT_DIR overrides the build directory; HOT_ASM_ARGS overrides the
#      check-hot-asm.sh arguments (default --s7); VALGRIND names the
#      valgrind command (default: build/tools/bin/valgrind; run
#      tools/get-tools.sh first); ECHO_BYTES (default 1073741824);
#      FUZZ_SEEDS (split fuzz seeds, default 2000).
# Exit status 0 only when every suite passes and the asm check passes.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/unit}
mkdir -p "$OUT"
# absolute: the drd runs cd into $OUT/drd (a relative OUT_DIR broke their paths)
OUT=$(cd "$OUT" && pwd)
FU="-Fu$ROOT/src/rt -Fu$ROOT/src/http -Fu$ROOT/src/http1 -Fu$ROOT/src/server -Fu$ROOT/src/ws -Fu$ROOT/tests/support -Fu$ROOT/tests/unit"
FAIL=0
TOTAL=0
for T in test_parser test_codec test_role test_headers_validate \
    test_rt_sys test_rt_timer test_rt_loop test_rt_net test_rt_readbuf test_h1_io \
    test_h1_conn test_body_chan test_exchange test_h1_dispatch test_workers test_server \
    test_server_ops test_ws_frame test_ws_handshake test_ws_conn test_ws_echo; do
  # test_h1_dispatch: -dWD_DEBUG, in its own unit directory (the define
  # changes bearings.http1.dispatch's fields)
  D=$OUT
  XD=
  if [ "$T" = test_h1_dispatch ]; then D=$OUT/dispatch; XD="-dWD_DEBUG -dWD_STALL"; mkdir -p "$D"; fi
  # shellcheck disable=SC2086
  if ! fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa $XD $FU -FU"$D" -FE"$OUT" \
      "$ROOT/tests/unit/$T.pas" > "$OUT/$T.build.log" 2>&1; then
    echo "$T: BUILD FAILED (see $OUT/$T.build.log)"
    FAIL=1
    continue
  fi
  if "$OUT/$T" --all --format=plain > "$OUT/$T.out" 2>&1; then R=0; else R=$?; fi
  # the fpcunit summary line (a suite may log to stderr before it)
  LINE=$(grep -m 1 -E '^ Time:[0-9:.]+ N:[0-9]+ E:' "$OUT/$T.out" || head -n 1 "$OUT/$T.out")
  N=$(echo "$LINE" | sed -n 's/.* N:\([0-9]*\) .*/\1/p')
  TOTAL=$((TOTAL + ${N:-0}))
  echo "$T:$LINE (exit $R)"
  if [ "$R" -ne 0 ] || ! echo "$LINE" | grep -q ' E:0 F:0 '; then
    FAIL=1
  fi
done
echo "unit tests run: $TOTAL"
# S4 exit criterion: heaptrc clean. The summary goes to a log file
# (HEAPTRC=log=...): the console test runner leaves no stdout for it.
HT="$OUT/heaptrc"
mkdir -p "$HT"
for T in test_h1_conn test_body_chan test_exchange test_h1_dispatch test_workers test_server \
    test_server_ops test_ws_conn test_ws_echo; do
  XD=
  if [ "$T" = test_h1_dispatch ]; then XD="-dWD_DEBUG -dWD_STALL"; fi
  mkdir -p "$HT/u-$T"
  # shellcheck disable=SC2086
  if ! fpc -Mobjfpc -Sh -O2 -gl -gh -Cr -Co -Ct -Sa $XD $FU -FU"$HT/u-$T" -FE"$HT" \
      "$ROOT/tests/unit/$T.pas" > "$HT/$T.build.log" 2>&1; then
    echo "$T (heaptrc): BUILD FAILED (see $HT/$T.build.log)"
    FAIL=1
    continue
  fi
  rm -f "$HT/$T.heap"
  if HEAPTRC="log=$HT/$T.heap" "$HT/$T" --all --format=plain > "$HT/$T.out" 2>&1; then R=0; else R=$?; fi
  U=$(sed -n 's/^\([0-9]*\) unfreed memory blocks.*/\1/p' "$HT/$T.heap" 2>/dev/null | head -n 1)
  HL=$(grep -m 1 -E '^ Time:[0-9:.]+ N:[0-9]+ E:' "$HT/$T.out" || head -n 1 "$HT/$T.out")
  echo "$T (heaptrc): $HL (exit $R), unfreed blocks: ${U:-?}"
  if [ "$R" -ne 0 ] || [ "${U:-x}" != "0" ]; then
    FAIL=1
  fi
done
# S7 exit criterion: the worker stress tests under valgrind --tool=drd
# (docs/design.md section 9), built with -dWD_DRD (bearings.rt.sync's happens-before client
# requests), tools/drd.supp, WD_ITER=20 (loop counts at 20 %): drd must
# report 0 errors and every test must pass. DRD_RUNS (default 3) runs.
# --fair-sched=yes: valgrind runs one thread at a time; its default lock
# (--fair-sched=no) lets a thread that spins (the tests' CpuRelax loops)
# take the lock back again and again while the thread it waits for cannot
# run (valgrind's manual on --fair-sched; deviation S7-25)
VG=${VALGRIND:-$ROOT/build/tools/bin/valgrind}
DR="$OUT/drd"
mkdir -p "$DR/u"
# shellcheck disable=SC2086
if ! fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -dWD_DRD $FU -FU"$DR/u" -FE"$DR" \
    "$ROOT/tests/unit/test_workers.pas" > "$DR/test_workers.build.log" 2>&1; then
  echo "test_workers (drd): BUILD FAILED (see $DR/test_workers.build.log)"
  FAIL=1
elif ! { [ -x "$VG" ] || command -v "$VG" > /dev/null 2>&1; }; then
  echo "test_workers (drd): FAILED: no valgrind at $VG (run tools/get-tools.sh, or set VALGRIND)"
  FAIL=1
else
  I=1
  while [ "$I" -le "${DRD_RUNS:-3}" ]; do
    if (cd "$DR" && WD_ITER=20 "$VG" --tool=drd --fair-sched=yes --suppressions="$ROOT/tools/drd.supp" \
        ./test_workers --all --format=plain > "$DR/run-$I.out" 2> "$DR/run-$I.err"); then R=0; else R=$?; fi
    DE=$(sed -n 's/.*ERROR SUMMARY: \([0-9]*\) errors.*/\1/p' "$DR/run-$I.err" | tail -n 1)
    DL=$(grep -m 1 -E '^ Time:[0-9:.]+ N:[0-9]+ E:' "$DR/run-$I.out" || echo '?')
    echo "test_workers (drd run $I):$DL (exit $R), drd errors: ${DE:-?}"
    if [ "$R" -ne 0 ] || [ "${DE:-x}" != "0" ] || ! echo "$DL" | grep -q ' E:0 F:0 '; then
      FAIL=1
    fi
    I=$((I + 1))
  done
fi
# S7 fix round 5 (deviation S7-34): the end-to-end worker stress
# (tests/unit/stress_workers.pas through TServer), natively and under drd;
# STRESS_SEEDS (default 3) and STRESS_DRD_RUNS (default 1) set its size
# (tools/s7-stress.sh runs 10 and 3)
OUT_DIR="$OUT/s7-stress" SEEDS="${STRESS_SEEDS:-3}" DRD_RUNS="${STRESS_DRD_RUNS:-1}" \
  sh "$ROOT/tools/s7-stress.sh" || FAIL=1
VG=${VALGRIND:-$ROOT/build/tools/bin/valgrind}
if [ -x "$VG" ] || command -v "$VG" > /dev/null 2>&1; then
  OUT_DIR="$OUT" VALGRIND="$VG" sh "$ROOT/tests/unit/test_rt_echo.sh" "${ECHO_BYTES:-1073741824}" || FAIL=1
else
  echo "test_rt_echo: FAILED: no valgrind at $VG (run tools/get-tools.sh, or set VALGRIND)"
  FAIL=1
fi
# S9 split fuzz (docs/design.md section 9; tests/unit/test_split_fuzz.pas): the
# conformance case inputs and the M2 parser corpus (20 000 random entries,
# seed 1, with httparse's test inputs when found) in random reads with random EAGAIN and partial writes, compared
# with one-read runs; built with -Ci -Cr -Co -Ct -Sa -gh -gl -dWD_DEBUG,
# heaptrc must report 0 unfreed blocks. FUZZ_SEEDS (default 2000) seeds.
FZ="$OUT/split-fuzz"
mkdir -p "$FZ/u"
python3 -I "$ROOT/tests/unit/test_split_fuzz_cases.py" "$FZ/cases.bin" "$ROOT/conformance/cases/h1" \
  "$ROOT/conformance/pascal-server/extra/extra-cases.json" > "$FZ/cases.log" 2>&1 || FAIL=1
# httparse's own test inputs too when its source is in the cargo registry
# (test_parser_diff.sh's HTTPARSE_SRC)
HP=${HTTPARSE_SRC:-$(ls -d "$HOME"/.cargo/registry/src/*/httparse-1.10.1 2>/dev/null | head -n 1)}
HTTPARSE_SRC=$HP python3 -I "$ROOT/tests/unit/test_parser_corpus.py" "$FZ/corpus.bin" 20000 1 > "$FZ/corpus.log" 2>&1 || FAIL=1
# shellcheck disable=SC2086
if ! fpc -Mobjfpc -Sh -O2 -Ci -Cr -Co -Ct -Sa -gh -gl -dWD_DEBUG $FU -Fu"$ROOT/conformance/pascal-server" \
    -FU"$FZ/u" -FE"$FZ" "$ROOT/tests/unit/test_split_fuzz.pas" > "$FZ/build.log" 2>&1; then
  echo "test_split_fuzz: BUILD FAILED (see $FZ/build.log)"
  FAIL=1
else
  rm -f "$FZ/heap.txt" "$FZ"/fail-*.txt
  if FUZZ_DATA="$FZ" HEAPTRC="log=$FZ/heap.txt" "$FZ/test_split_fuzz" --all --format=plain \
      > "$FZ/out.txt" 2>&1; then R=0; else R=$?; fi
  U=$(sed -n 's/^\([0-9]*\) unfreed memory blocks.*/\1/p' "$FZ/heap.txt" 2>/dev/null | head -n 1)
  HL=$(grep -m 1 -E '^ Time:[0-9:.]+ N:[0-9]+ E:' "$FZ/out.txt" || echo '?')
  echo "test_split_fuzz:$HL (exit $R), unfreed blocks: ${U:-?}"
  grep '^split fuzz: [0-9e]' "$FZ/out.txt" | sed 's/^/  /'
  if [ "$R" -ne 0 ] || [ "${U:-x}" != "0" ] || ! echo "$HL" | grep -q ' E:0 F:0 '; then
    FAIL=1
  fi
fi
# shellcheck disable=SC2086
OUT_DIR="$OUT/check-hot-asm" sh "$ROOT/tools/check-hot-asm.sh" ${HOT_ASM_ARGS:---s7} || FAIL=1
[ "$FAIL" -eq 0 ] && echo "run_all: passed" || echo "run_all: FAILED"
exit $FAIL
