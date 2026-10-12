#!/bin/sh
# The hot-path build check of docs/design.md 7.4: no implicit exception frame (fpc_pushexceptaddr /
# fpc_setjmp) in any hot routine.
#
# Compiles every unit under src/ with -al (assembler listing kept) in two
# configurations, the production/benchmark one (-O3) and the unit-test one
# (-O2 -Cr -Co -Ct -Sa), and checks the listed routines in both
# (tools/hot-asm.py; patterns: Name, Name*, TType.Method, TType.*).
#
# Usage: tools/check-hot-asm.sh [pattern ...]
#   no patterns: the full list of docs/design.md 7.4. Routines of units that are
#   still interface skeletons pass trivially (empty bodies); each step's
#   exit criterion names the routines it has implemented (S0:
#   tools/check-hot-asm.sh --s0; S1: --s1; S2: --s2; S3: --s3; S4: --s4;
#   S5: --s5; H: --h; S7: --s7).
# Env: OUT_DIR overrides the build directory.
# Exit status 0 only when every pattern matches at least one routine and no
# matched routine has a frame, in both configurations.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/check-hot-asm}

if [ "$#" -eq 1 ] && [ "$1" = "--s0" ]; then
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*'
elif [ "$#" -eq 1 ] && [ "$1" = "--s1" ]; then
  # S0's list plus the 4.4 routines implemented in S1
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*'
elif [ "$#" -eq 1 ] && [ "$1" = "--s2" ]; then
  # S1's list plus the read buffer of S2 (TBytesView.Release is per view)
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*'
elif [ "$#" -eq 1 ] && [ "$1" = "--s3" ]; then
  # S2's list plus bearings.http1.io (S3): TH1Io.* (docs/design.md 7.4) and the io.rs
  # types its methods call on every request
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*' \
    'TH1Io.*' 'TReadStrategy.*' 'TCursor.*' 'TWriteBuf.*' 'TBufList.*' 'TQueuedBuf.*' \
    'TEncodedBuf.*' IncrPowerOfTwo PrevPowerOfTwo QueuedEncoded QueuedTrailers QueuedFile \
    ReleaseBody
elif [ "$#" -eq 1 ] && [ "$1" = "--s4" ]; then
  # S3's list plus the S4 routines of docs/design.md 7.4 (TH1Conn.*, TBodyChan.*,
  # TExchange.{Respond,TryRead,ReleaseRequest}) and TConnState.*, which
  # TH1Conn calls on every request
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*' \
    'TH1Io.*' 'TReadStrategy.*' 'TCursor.*' 'TWriteBuf.*' 'TBufList.*' 'TQueuedBuf.*' \
    'TEncodedBuf.*' IncrPowerOfTwo PrevPowerOfTwo QueuedEncoded QueuedTrailers QueuedFile \
    ReleaseBody \
    'TH1Conn.*' 'TConnState.*' 'TBodyChan.*' TExchange.Respond TExchange.TryRead \
    TExchange.ReleaseRequest
elif [ "$#" -eq 1 ] && [ "$1" = "--s5" ]; then
  # S4's list plus the TH1Dispatcher routines of docs/design.md 7.4 (S5)
  set -- 'ServerParse*' ServerEncode EncodeHead MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*' \
    'TH1Io.*' 'TReadStrategy.*' 'TCursor.*' 'TWriteBuf.*' 'TBufList.*' 'TQueuedBuf.*' \
    'TEncodedBuf.*' IncrPowerOfTwo PrevPowerOfTwo QueuedEncoded QueuedTrailers QueuedFile \
    ReleaseBody \
    'TH1Conn.*' 'TConnState.*' 'TBodyChan.*' TExchange.Respond TExchange.TryRead \
    TExchange.ReleaseRequest \
    TH1Dispatcher.Run TH1Dispatcher.PollLoop TH1Dispatcher.PollRead \
    TH1Dispatcher.PollReadHead TH1Dispatcher.PollWrite TH1Dispatcher.PollFlush \
    TH1Dispatcher.PollInner TH1Dispatcher.PollCatch TH1Dispatcher.PollMsg \
    TH1Dispatcher.RecvMsg
elif [ "$#" -eq 1 ] && [ "$1" = "--h" ]; then
  # S5's list plus the routines step H changed or added: EncodeHeadHeapFlags
  # (its dynamic-array frame removed, decision 13), the decision 7 entries
  # (QueuedBytes, ContinueAfterQueue)
  set -- 'ServerParse*' ServerEncode EncodeHead EncodeHeadHeapFlags MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*' \
    'TH1Io.*' 'TReadStrategy.*' 'TCursor.*' 'TWriteBuf.*' 'TBufList.*' 'TQueuedBuf.*' \
    'TEncodedBuf.*' IncrPowerOfTwo PrevPowerOfTwo QueuedEncoded QueuedTrailers QueuedFile \
    QueuedBytes ContinueAfterQueue ReleaseBody \
    'TH1Conn.*' 'TConnState.*' 'TBodyChan.*' TExchange.Respond TExchange.TryRead \
    TExchange.ReleaseRequest \
    TH1Dispatcher.Run TH1Dispatcher.PollLoop TH1Dispatcher.PollRead \
    TH1Dispatcher.PollReadHead TH1Dispatcher.PollWrite TH1Dispatcher.PollFlush \
    TH1Dispatcher.PollInner TH1Dispatcher.PollCatch TH1Dispatcher.PollMsg \
    TH1Dispatcher.RecvMsg
elif [ "$#" -eq 1 ] && [ "$1" = "--s7" ]; then
  # also: the debug checks of docs/design.md 6.1 and 6.4 are not in
  # the production build (no TExchange.Dbg* routine, no fpc_assert call in
  # bearings.http.exchange), and they are in the test build (the check can fail)
  DBGCHECK=1
  # H's list plus the S7 routines run per streamed frame or per offloaded
  # request (the S7 verifier's TChannelBody.Enqueue finding); not checked:
  # TChannelBody.Create (a constructor) and TChannelBody.Grow (the cold
  # growth of the frame ring, split out so Enqueue has no frame)
  set -- 'ServerParse*' ServerEncode EncodeHead EncodeHeadHeapFlags MakeEncoder SetLengthEncoder \
    SetChunkedEncoder 'TEncoder.*' TDecoder.Decode 'TByteVec.*' \
    'TTimerWheel.*' TLoop.RunIteration 'TTcpTransport.*' \
    'TReadBuf.*' 'TBytesView.*' \
    'TH1Io.*' 'TReadStrategy.*' 'TCursor.*' 'TWriteBuf.*' 'TBufList.*' 'TQueuedBuf.*' \
    'TEncodedBuf.*' IncrPowerOfTwo PrevPowerOfTwo QueuedEncoded QueuedTrailers QueuedFile \
    QueuedBytes ContinueAfterQueue ReleaseBody \
    'TH1Conn.*' 'TConnState.*' 'TBodyChan.*' TExchange.Respond TExchange.TryRead \
    TExchange.ReleaseRequest \
    TH1Dispatcher.Run TH1Dispatcher.PollLoop TH1Dispatcher.PollRead \
    TH1Dispatcher.PollReadHead TH1Dispatcher.PollWrite TH1Dispatcher.PollFlush \
    TH1Dispatcher.PollInner TH1Dispatcher.PollCatch TH1Dispatcher.PollMsg \
    TH1Dispatcher.RecvMsg \
    TChannelBody.Push TChannelBody.Enqueue TChannelBody.Ended TChannelBody.PollFrame \
    TChannelBody.FinishStream TChannelBody.AbortWith TChannelBody.AutoFinish \
    TChannelBody.WakeProducer TChannelBody.Reset TChannelBody.Deactivate TChannelBody.Done \
    TChannelBody.DropQueued TExchange.Release TExchange.ReleaseTransport TExchange.Share \
    TExchange.Offload TExchange.Wake TExchange.TryReadShared TExchange.Write TExchange.TryWrite \
    TExchange.WriteString TExchange.RespondShared TExchange.ClaimAnswer TExchange.SyncShared TExchange.CompleteShared \
    'TEventCount.*' 'TParker.*' 'TSpinLock.*' 'TMpscStack.*'
elif [ "$#" -eq 0 ]; then
  set -- TH1Dispatcher.Run TH1Dispatcher.PollLoop TH1Dispatcher.PollRead \
    TH1Dispatcher.PollReadHead TH1Dispatcher.PollWrite TH1Dispatcher.PollFlush \
    TH1Dispatcher.PollInner TH1Dispatcher.PollCatch TH1Dispatcher.PollMsg \
    TH1Dispatcher.RecvMsg 'TH1Conn.*' 'TH1Io.*' 'TReadBuf.*' 'TByteVec.*' \
    'TTcpTransport.*' 'ServerParse*' ServerEncode EncodeHead MakeEncoder \
    SetLengthEncoder SetChunkedEncoder TEncoder.Encode TEncoder.EncodeAndEnd \
    TEncoder.Finish TDecoder.Decode TExchange.Respond TExchange.TryRead \
    TExchange.ReleaseRequest 'TBodyChan.*' 'TTimerWheel.*' TLoop.RunIteration
fi

FU="-Fu$ROOT/src/rt -Fu$ROOT/src/http -Fu$ROOT/src/http1 -Fu$ROOT/src/server"
STATUS=0
DBGCHECK=${DBGCHECK:-0}
for CFG in prod test; do
  D="$OUT/$CFG"
  rm -rf "$D"
  mkdir -p "$D"
  case $CFG in
    prod) FLAGS="-O3" ;;
    test) FLAGS="-O2 -gl -Cr -Co -Ct -Sa" ;;
  esac
  # bearings.server uses every other unit of src/ (directly or not)
  # shellcheck disable=SC2086
  if ! fpc -Mobjfpc -Sh $FLAGS -al $FU -FU"$D" "$ROOT/src/server/bearings.server.pas" > "$D/build.log" 2>&1; then
    echo "check-hot-asm: compile failed ($CFG), see $D/build.log"
    exit 2
  fi
  echo "== $CFG ($FLAGS)"
  python3 -I "$ROOT/tools/hot-asm.py" "$D" "$@" || STATUS=1
  if [ "$DBGCHECK" -eq 1 ]; then
    NR=$(grep -c '\.type.*TEXCHANGE_\$__\$\$_DBG[A-Z]*,@function' "$D/bearings.http.exchange.s" || true)
    NA=$(grep -ci 'call[[:space:]]*fpc_assert' "$D/bearings.http.exchange.s" || true)
    echo "debug checks in bearings.http.exchange ($CFG): $NR TExchange.Dbg* routines, $NA fpc_assert calls"
    if [ "$CFG" = prod ] && [ "$NR" -ne 0 -o "$NA" -ne 0 ]; then
      echo "FAIL: the production build contains debug checks"; STATUS=1
    fi
    if [ "$CFG" = test ] && [ "$NR" -eq 0 -o "$NA" -eq 0 ]; then
      echo "FAIL: the test build has no debug checks (the check cannot fail)"; STATUS=1
    fi
  fi
done
if [ "$STATUS" -eq 0 ]; then
  echo "check-hot-asm: passed"
else
  echo "check-hot-asm: FAILED"
fi
exit $STATUS
