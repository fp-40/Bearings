#!/bin/sh
# Checks that every place that names the version names the same one:
# BEARINGS_VERSION (src/rt/bearings.version.pas, the source), fpmake.pp,
# README.md and python/pyproject.toml (pybearings ships libbearings.so, so
# both parts share one version). tools/release.sh changes all of them.
# Usage: tools/check-version.sh      prints the version
# Exit status 0 only when they all match.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$(sed -n "s/^ *BEARINGS_VERSION = '\([^']*\)';.*/\1/p" "$ROOT/src/rt/bearings.version.pas")
[ -n "$V" ] || { echo "check-version: no BEARINGS_VERSION in src/rt/bearings.version.pas"; exit 1; }
FAIL=0
check() {   # file found
  if [ "$2" != "$V" ]; then
    echo "check-version: $1 has '${2:-nothing}', bearings.version.pas has '$V'"
    FAIL=1
  fi
}
check fpmake.pp "$(sed -n "s/^ *P\.Version := '\([^']*\)';.*/\1/p" "$ROOT/fpmake.pp")"
check README.md "$(sed -n 's/^Version: .*(\([0-9][^)]*\))\.$/\1/p' "$ROOT/README.md")"
check python/pyproject.toml "$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$ROOT/python/pyproject.toml")"
[ "$FAIL" -eq 0 ] && echo "$V"
exit $FAIL
