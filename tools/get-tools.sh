#!/bin/sh
# Fetches and builds the external tools the tests and benchmarks use, at
# pinned versions, into build/tools/ (docs/design.md section 9). No root needed; nothing outside build/tools/ is written.
#
#   build/tools/bin/wrk        wg/wrk at WRK_COMMIT (system OpenSSL, bundled LuaJIT)
#   build/tools/bin/wrk2       giltene/wrk2 at WRK2_COMMIT (fixed-rate load, p99; docs/design.md section 9)
#   build/tools/bin/valgrind   wrapper: the Ubuntu valgrind package VALGRIND_DEB,
#                              fetched with apt-get download, checked against
#                              VALGRIND_SHA256 and unpacked with dpkg -x (no install);
#                              the wrapper sets VALGRIND_LIB
#
# Idempotent: a tool whose pinned version is already built is left alone
# (build/tools/<tool>.stamp holds the pin). Re-run after a pin change.
# Usage: tools/get-tools.sh [wrk|wrk2|valgrind ...]   (default: all three)
# Env: TOOLS_DIR overrides build/tools.
# Exit status 0 only when every requested tool is present afterwards.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS=${TOOLS_DIR:-$ROOT/build/tools}

WRK_REPO=https://github.com/wg/wrk.git
WRK_COMMIT=a211dd5a7050b1f9e8a9870b95513060e72ac4a0        # wrk 4.2.0 + 2021-02-07 master
WRK2_REPO=https://github.com/giltene/wrk2.git
WRK2_COMMIT=44a94c17d8e6a0bac8559b53da76848e430cb7a7       # wrk2 master
VALGRIND_PKG=valgrind=1:3.26.0-0ubuntu1
VALGRIND_DEB='valgrind_1%3a3.26.0-0ubuntu1_amd64.deb'        # apt-get download's file name
# sha256 of that file (its SHA512 2a121f76... matches the Ubuntu 26.04 archive index)
VALGRIND_SHA256=70b10c31307700a388262baa9cff7a3b27814a9716b6f19e8f748a56bcbfa442

mkdir -p "$TOOLS/bin" "$TOOLS/src"

stamp_ok() {   # tool pin
  [ -f "$TOOLS/$1.stamp" ] && [ "$(cat "$TOOLS/$1.stamp")" = "$2" ]
}

git_at() {     # dir repo commit
  if [ ! -d "$1/.git" ]; then
    rm -rf "$1"
    git clone --quiet "$2" "$1"
  fi
  if [ "$(git -C "$1" rev-parse HEAD)" != "$3" ]; then
    git -C "$1" fetch --quiet origin
    git -C "$1" checkout --quiet --force "$3"
  fi
  [ "$(git -C "$1" rev-parse HEAD)" = "$3" ]
}

get_wrk() {
  if stamp_ok wrk "$WRK_COMMIT" && [ -x "$TOOLS/bin/wrk" ]; then
    echo "get-tools: wrk $WRK_COMMIT present"; return 0
  fi
  echo "get-tools: building wrk $WRK_COMMIT"
  git_at "$TOOLS/src/wrk" "$WRK_REPO" "$WRK_COMMIT"
  make -C "$TOOLS/src/wrk" clean > /dev/null 2>&1 || true
  make -C "$TOOLS/src/wrk" WITH_OPENSSL=/usr -j"$(nproc)" > "$TOOLS/wrk.build.log" 2>&1 \
    || { echo "get-tools: wrk build FAILED (see $TOOLS/wrk.build.log)"; return 1; }
  cp "$TOOLS/src/wrk/wrk" "$TOOLS/bin/wrk"
  echo "$WRK_COMMIT" > "$TOOLS/wrk.stamp"
  echo "get-tools: wrk built"
}

get_wrk2() {
  if stamp_ok wrk2 "$WRK2_COMMIT+bytecode.c" && [ -x "$TOOLS/bin/wrk2" ]; then
    echo "get-tools: wrk2 $WRK2_COMMIT present"; return 0
  fi
  echo "get-tools: building wrk2 $WRK2_COMMIT"
  git_at "$TOOLS/src/wrk2" "$WRK2_REPO" "$WRK2_COMMIT"
  make -C "$TOOLS/src/wrk2" clean > /dev/null 2>&1 || true
  make -C "$TOOLS/src/wrk2" -j"$(nproc)" > "$TOOLS/wrk2.build.log" 2>&1 \
    || { echo "get-tools: wrk2 build FAILED (see $TOOLS/wrk2.build.log)"; return 1; }
  # wrk2's bundled LuaJIT 2.0 writes src/wrk.lua as an ELF object
  # (obj/bytecode.o) that the current linker reads as corrupt ("string table
  # [3] is corrupt"): the embedded wrk module is missing and every run stops
  # at start with "PANIC: unprotected error in call to Lua API (attempt to
  # index a nil value)" (M3 S10). Emit the bytecode as C source instead,
  # compile it with cc and link again.
  W2=$TOOLS/src/wrk2
  (cd "$W2/deps/luajit/src" && ./luajit -b "$W2/src/wrk.lua" "$W2/obj/bytecode.c") \
    && cc -c "$W2/obj/bytecode.c" -o "$W2/obj/bytecode.o" \
    && rm -f "$W2/wrk" && make -C "$W2" >> "$TOOLS/wrk2.build.log" 2>&1 \
    || { echo "get-tools: wrk2 bytecode relink FAILED (see $TOOLS/wrk2.build.log)"; return 1; }
  "$W2/wrk" -t1 -c1 -d1s -R1 http://127.0.0.1:1/ 2>&1 | grep -q PANIC \
    && { echo "get-tools: wrk2 still stops with a Lua PANIC"; return 1; }
  cp "$TOOLS/src/wrk2/wrk" "$TOOLS/bin/wrk2"
  echo "$WRK2_COMMIT+bytecode.c" > "$TOOLS/wrk2.stamp"
  echo "get-tools: wrk2 built"
}

get_valgrind() {
  if stamp_ok valgrind "$VALGRIND_DEB" && [ -x "$TOOLS/bin/valgrind" ]; then
    echo "get-tools: valgrind $VALGRIND_DEB present"; return 0
  fi
  echo "get-tools: fetching $VALGRIND_DEB"
  D="$TOOLS/deb"
  mkdir -p "$D"
  if [ ! -f "$D/$VALGRIND_DEB" ]; then
    (cd "$D" && apt-get download "$VALGRIND_PKG" > "$TOOLS/valgrind.fetch.log" 2>&1) \
      || { echo "get-tools: apt-get download FAILED (see $TOOLS/valgrind.fetch.log)"; return 1; }
  fi
  SUM=$(sha256sum "$D/$VALGRIND_DEB" | cut -d' ' -f1)
  if [ "$SUM" != "$VALGRIND_SHA256" ]; then
    echo "get-tools: $VALGRIND_DEB sha256 $SUM, expected $VALGRIND_SHA256"; return 1
  fi
  rm -rf "$TOOLS/valgrind"
  mkdir -p "$TOOLS/valgrind"
  dpkg -x "$D/$VALGRIND_DEB" "$TOOLS/valgrind"
  cat > "$TOOLS/bin/valgrind" <<EOF
#!/bin/sh
# wrapper written by tools/get-tools.sh: the unpacked $VALGRIND_DEB
VALGRIND_LIB="$TOOLS/valgrind/usr/libexec/valgrind"
export VALGRIND_LIB
exec "$TOOLS/valgrind/usr/bin/valgrind" "\$@"
EOF
  chmod +x "$TOOLS/bin/valgrind"
  "$TOOLS/bin/valgrind" --version > /dev/null \
    || { echo "get-tools: the unpacked valgrind does not run"; return 1; }
  echo "$VALGRIND_DEB" > "$TOOLS/valgrind.stamp"
  echo "get-tools: valgrind $("$TOOLS/bin/valgrind" --version) unpacked"
}

[ "$#" -eq 0 ] && set -- wrk wrk2 valgrind
STATUS=0
for T in "$@"; do
  case $T in
    wrk) get_wrk || STATUS=1 ;;
    wrk2) get_wrk2 || STATUS=1 ;;
    valgrind) get_valgrind || STATUS=1 ;;
    *) echo "get-tools: unknown tool $T"; STATUS=2 ;;
  esac
done
exit $STATUS
