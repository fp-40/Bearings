#!/bin/sh
# Conformance tier (make test-full, make release): the differential tests
# against httparse and hyper (tests/unit/test_parser_diff.sh,
# test_role_diff.sh, test_codec_diff.sh) and the wire conformance gate
# (conformance/pascal-server/gate.sh), each at its default size.
# Needs cargo; the Rust crates must be in the cargo registry already
# (the scripts build with --offline: run `cargo fetch` in conformance/
# and in each tests/unit/*_rs directory once).
# Usage: tests/conformance.sh
# Env: TIMEOUT (seconds, default 3600) bounds each script.
# Exit status 0 only when every script passes; the others still run
# after one fails.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TO=${TIMEOUT:-3600}
FAIL=0
for S in tests/unit/test_parser_diff.sh tests/unit/test_role_diff.sh \
    tests/unit/test_codec_diff.sh conformance/pascal-server/gate.sh; do
  echo "conformance: $S"
  if timeout "$TO" sh "$ROOT/$S"; then R=0; else R=$?; fi
  if [ "$R" -ne 0 ]; then
    [ "$R" -eq 124 ] && echo "conformance: $S: TIMEOUT"
    echo "conformance: $S: FAILED (exit $R)"
    FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] && echo "conformance: passed" || echo "conformance: FAILED"
exit $FAIL
