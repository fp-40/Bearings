#!/bin/sh
# Builds the Pascal conformance server (design m3-transport.md 6.9).
# Usage: conformance/pascal-server/build.sh
# Env: OUT_DIR (default build/conformance; the binary is $OUT_DIR/beconf);
#      PROFILE=debug (default: -Ci -Cr -Co -Ct -Sa -gl -dWD_DEBUG, design 7.5
#      "debug builds for all tests") or PROFILE=release (-O2 -gl, the
#      production code path).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/conformance}
PROFILE=${PROFILE:-debug}
case "$PROFILE" in
  debug) FLAGS="-O2 -gl -Ci -Cr -Co -Ct -Sa -dWD_DEBUG" ;;
  release) FLAGS="-O2 -gl" ;;
  *) echo "build.sh: PROFILE must be debug or release" >&2; exit 2 ;;
esac
U="$OUT/units-$PROFILE"
mkdir -p "$OUT" "$U"
# shellcheck disable=SC2086
fpc -Mobjfpc -Sh $FLAGS \
  -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http" -Fu"$ROOT/src/http1" -Fu"$ROOT/src/server" \
  -Fu"$ROOT/conformance/pascal-server" -FU"$U" -FE"$OUT" -o"$OUT/beconf" \
  "$ROOT/conformance/pascal-server/beconf.lpr"
