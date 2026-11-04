#!/bin/sh
# Expected-value tests of the HTTP/1 parser, the request head rules and the
# body decoder: each driver prints one result line per case, and the lines
# must equal the expected values in tests/golden.
#
#   parser  bearings.http1.parser over the corpus of test_parser_corpus.py
#           (50 000 random cases, seed 1; the corpus is generated here and
#           its SHA-256 is checked, so a change in the generator or in
#           Python's random module is reported as such)
#   role    bearings.http1.role (request parsing) and bearings.http.uri over
#           tests/golden/role_cases.txt.xz
#   codec   bearings.http1.decode and bearings.http.headers over
#           tests/golden/decode_cases.txt.xz and headers_cases.txt.xz
#
# Every driver also runs with its input against PROT_NONE guard pages
# (a read outside the input crashes); those runs must print the same lines.
#
# The expected values were frozen on 2026-11-04 from httparse 1.10.1 and
# hyper v1.12.0, with the two rules of docs/design/deviations.md that
# differ from hyper (Host, bare LF in trailers) applied after each
# difference was checked. They are maintained here now: after an intended
# change of behaviour, run with UPDATE=1, which lists the lines that change
# (case, old, new) and rewrites the expected files; review the list before
# committing.
#
# Usage: tests/unit/test_golden.sh [parser|role|codec ...]   (default: all)
# Env: OUT_DIR (default build/golden), GOLDEN_DIR (default tests/golden), UPDATE=1.
# Exit status 0 only when every result matches.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/golden}
G=${GOLDEN_DIR:-$ROOT/tests/golden}
UPDATE=${UPDATE:-0}
CORPUS_SHA256=a09c35a657efb3f38c66d5f69dfb114cefc191b59a4925e322d439fc5aea4e41
mkdir -p "$OUT"
FAIL=0

build() {   # program
  fpc -Mobjfpc -Sh -O2 -gl -Cr -Co -Ct -Sa -Fu"$ROOT/src/rt" -Fu"$ROOT/src/http1" -Fu"$ROOT/tests/unit" \
    -FU"$OUT" -FE"$OUT" "$ROOT/tests/unit/$1.pas" > "$OUT/$1.build.log" 2>&1 || {
    echo "golden: $1 BUILD FAILED (see $OUT/$1.build.log)"; exit 1; }
}

# compare <name> <expected .xz> <got file> <cases file or ''>
# The case of line N is line N of the cases file; for the parser (no cases
# file) the first field of a result line is the case index.
compare() {
  xz -dc "$2" > "$OUT/$1.expected"
  N=$(wc -l < "$3")
  if cmp -s "$OUT/$1.expected" "$3"; then
    echo "golden $1: $N result lines as expected"
    return 0
  fi
  M=$(diff "$OUT/$1.expected" "$3" | grep -c '^>' || true)
  if [ "$UPDATE" = 1 ]; then
    echo "golden $1: UPDATE: $M lines change (first 20 below)"
  else
    echo "golden $1: MISMATCH: $M lines differ from the expected values (first 10 below)"
  fi
  python3 -I - "$OUT/$1.expected" "$3" "$4" "$([ "$UPDATE" = 1 ] && echo 20 || echo 10)" <<'EOF'
import sys
exp, got, cases, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
e = open(exp, encoding="latin-1").read().split("\n")
g = open(got, encoding="latin-1").read().split("\n")
c = open(cases, encoding="latin-1").read().split("\n") if cases else None
shown = 0
for i in range(max(len(e), len(g))):
    a = e[i] if i < len(e) else "<none>"
    b = g[i] if i < len(g) else "<none>"
    if a == b:
        continue
    print("  line %d" % (i + 1))
    if c is not None and i < len(c):
        print("    case:     " + c[i][:300])
    print("    expected: " + a[:300])
    print("    got:      " + b[:300])
    shown += 1
    if shown >= limit:
        break
EOF
  if [ "$UPDATE" = 1 ]; then
    xz -9e -T1 -c "$3" > "$2"
    echo "golden $1: $2 rewritten"
    return 0
  fi
  return 1
}

# guards_match <plain output> <guard output>...: the guard runs must print the same lines
guards_match() {
  P=$1; shift
  for F in "$@"; do
    cmp -s "$P" "$F" || { echo "golden: guard-page run $F differs from $P or crashed"; return 1; }
  done
}

do_parser() {
  build test_parser_golden
  python3 -I "$ROOT/tests/unit/test_parser_corpus.py" "$OUT/corpus.bin" 50000 1 > "$OUT/corpus.log"
  S=$(sha256sum "$OUT/corpus.bin" | cut -c1-64)
  if [ "$S" != "$CORPUS_SHA256" ]; then
    echo "golden parser: the corpus changed (sha256 $S, expected $CORPUS_SHA256):"
    echo "  test_parser_corpus.py or Python's random module produce other cases, so the"
    echo "  expected values no longer belong to them"
    return 1
  fi
  "$OUT/test_parser_golden" "$OUT/corpus.bin" > "$OUT/parser.got"
  "$OUT/test_parser_golden" "$OUT/corpus.bin" --guard-end > "$OUT/parser.guard-end"
  "$OUT/test_parser_golden" "$OUT/corpus.bin" --guard-start > "$OUT/parser.guard-start"
  guards_match "$OUT/parser.got" "$OUT/parser.guard-end" "$OUT/parser.guard-start" || return 1
  compare parser "$G/parser_expected.txt.xz" "$OUT/parser.got" ''
}

do_role() {
  build test_role_golden
  xz -dc "$G/role_cases.txt.xz" > "$OUT/role_cases.txt"
  "$OUT/test_role_golden" "$OUT/role_cases.txt" > "$OUT/role.got"
  "$OUT/test_role_golden" "$OUT/role_cases.txt" --guard > "$OUT/role.guard"
  guards_match "$OUT/role.got" "$OUT/role.guard" || return 1
  compare role "$G/role_expected.txt.xz" "$OUT/role.got" "$OUT/role_cases.txt"
}

do_codec() {
  build test_codec_golden
  R=0
  for K in decode headers; do
    xz -dc "$G/${K}_cases.txt.xz" > "$OUT/${K}_cases.txt"
    "$OUT/test_codec_golden" $K "$OUT/${K}_cases.txt" > "$OUT/$K.got"
    "$OUT/test_codec_golden" $K "$OUT/${K}_cases.txt" --guard-end > "$OUT/$K.guard-end"
    "$OUT/test_codec_golden" $K "$OUT/${K}_cases.txt" --guard-start > "$OUT/$K.guard-start"
    guards_match "$OUT/$K.got" "$OUT/$K.guard-end" "$OUT/$K.guard-start" || R=1
    compare $K "$G/${K}_expected.txt.xz" "$OUT/$K.got" "$OUT/${K}_cases.txt" || R=1
  done
  return $R
}

WHAT=${*:-parser role codec}
for W in $WHAT; do
  case $W in
    parser) do_parser || FAIL=1 ;;
    role) do_role || FAIL=1 ;;
    codec) do_codec || FAIL=1 ;;
    *) echo "golden: unknown test $W (parser, role or codec)"; exit 2 ;;
  esac
done
[ "$FAIL" -eq 0 ] && echo "golden: passed" || echo "golden: FAILED"
exit $FAIL
