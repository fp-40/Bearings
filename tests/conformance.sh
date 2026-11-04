#!/bin/sh
# Conformance tier (make test-full, make release): the wire conformance gate
# (conformance/pascal-server/gate.sh): the cases of conformance/cases and
# the extra cases against the Pascal conformance server, in assertion mode.
# The case runner is a Pascal program (conformance/runner/), built by the gate.
# The differential tests against httparse and hyper that ran here were
# replaced on 2026-11-04 by tests/unit/test_golden.sh (make test).
# Usage: tests/conformance.sh
# Env: TIMEOUT (seconds, default 3600) bounds each script.
# Exit status 0 only when every script passes; the others still run
# after one fails.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TO=${TIMEOUT:-3600}
FAIL=0
for S in conformance/pascal-server/gate.sh; do
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
