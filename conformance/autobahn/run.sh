#!/bin/sh
# Runs the Autobahn TestSuite (fuzzingclient mode: the suite is the client)
# against examples/ws_echo.pas and prints a summary per result.
# Needs Docker and the image crossbario/autobahn-testsuite (pulled on first
# use). The echo server listens on 127.0.0.1:9001 with one loop; the
# container uses the host network. The HTML and JSON reports go to
# build/autobahn/reports/ (index.html for a browser).
# Usage: conformance/autobahn/run.sh [cases]   (default: every case; for
#        example '1.*,2.*' runs groups 1 and 2)
# Exit status 0 when no case has the result FAILED.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/build/autobahn
IMAGE=crossbario/autobahn-testsuite:latest
mkdir -p "$OUT/units" "$OUT/reports"
fpc -Mobjfpc -Sh -O2 -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http" -Fu"$ROOT/src/http1" \
  -Fu"$ROOT/src/server" -Fu"$ROOT/src/ws" -FU"$OUT/units" -FE"$OUT" \
  "$ROOT/examples/ws_echo.pas" > "$OUT/build.log" 2>&1 || { echo "build failed: $OUT/build.log"; exit 1; }
python3 -I - "$ROOT/conformance/autobahn/fuzzingclient.json" "$OUT/fuzzingclient.json" "${1:-*}" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["cases"] = [x.strip() for x in sys.argv[3].split(",")]
json.dump(c, open(sys.argv[2], "w"), indent=2)
PY
rm -f "$OUT"/reports/*
"$OUT/ws_echo" 9001 1 2> "$OUT/server.log" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep 0.5
docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$OUT:/work" "$IMAGE" \
  wstest -m fuzzingclient -s /work/fuzzingclient.json > "$OUT/wstest.log" 2>&1 || {
  echo "wstest failed: $OUT/wstest.log"; tail -20 "$OUT/wstest.log"; exit 1; }
kill $PID
wait $PID 2>/dev/null || true
trap - EXIT
python3 -I - "$OUT/reports/index.json" <<'PY'
import json, sys, collections
idx = json.load(open(sys.argv[1]))["bearings"]
by = collections.defaultdict(list)
for case, r in idx.items():
    by[r["behavior"]].append(case)
    if r.get("behaviorClose") not in ("OK", "INFORMATIONAL", None):
        by["close:" + r["behaviorClose"]].append(case)
def key(c):
    return [int(p) for p in c.split(".")]
for b in sorted(by):
    cases = sorted(by[b], key=key)
    print("%-22s %4d  %s" % (b, len(cases), " ".join(cases[:12]) + (" ..." if len(cases) > 12 else "")))
print("total cases: %d" % len(idx))
sys.exit(1 if by.get("FAILED") else 0)
PY
