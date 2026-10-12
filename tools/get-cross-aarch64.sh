#!/bin/sh
# Builds the Free Pascal 3.2.2 cross compiler for aarch64-linux (ARM64) with
# its RTL and packages into build/tools/, and installs two wrappers:
#
#   build/tools/bin/fpc-aarch64   compiles for aarch64-linux; takes the same
#                                 arguments as fpc (the scripts use it through FPC=)
#   build/tools/bin/run-aarch64   runs an aarch64 binary on this x86_64 host
#                                 under qemu-aarch64 (the scripts use it through RUN=)
#
# Needs, from the distribution (apt): binutils-aarch64-linux-gnu (assembler
# and linker), libc6-arm64-cross (the ARM64 glibc, which cthreads links
# dynamically, under /usr/aarch64-linux-gnu), qemu-user (qemu-aarch64),
# and the host fpc 3.2.2 to build the compiler with. The ARM64
# libgcc_s.so.1 (pthread_exit needs it at run time) comes from the
# libgcc-s1-arm64-cross package, fetched with apt-get download and
# unpacked with dpkg -x (no install), like get-tools.sh does for valgrind.
# Nothing outside build/tools/ is written.
#
# The wrapper passes the options the host's /etc/fpc.cfg passes (-Sgic
# -CX -XX -viwn) so that a cross build and a host build see the same
# language switches; the x86 tuning options of that file do not apply.
#
# The FPC source is the release_3_2_2 tag from GitHub, checked against
# FPC_SHA256. One patch: rtl/linux/aarch64/cprt0.as (the C start-up
# code) passes null init and fini to __libc_start_main instead of
# __libc_csu_init / __libc_csu_fini, which glibc 2.34 removed (FPC fixed
# this after 3.2.2). The ARM64 libc here is 2.43.
#
# A binary built this way runs on real ARM64 Linux hardware with glibc 2.34
# or later; qemu-aarch64 runs it here. qemu executes on the x86_64 host and
# does not reproduce ARM64's weak memory ordering (README.md, "ARM64").
#
# Idempotent: build/tools/fpc-aarch64.stamp holds the pin. Re-run after a
# pin change.
# Usage: tools/get-cross-aarch64.sh
# Env: TOOLS_DIR overrides build/tools.
# Exit status 0 only when the compiler, the wrappers and qemu-aarch64 work
# (a hello program is cross-compiled and run at the end).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS=${TOOLS_DIR:-$ROOT/build/tools}
FPC_URL=https://github.com/fpc/FPCSource/archive/refs/tags/release_3_2_2.tar.gz
FPC_SHA256=d0f6565d4a03eee82902cc9cf25e320e7694dc34f177f446601dcf2972732d31
PIN="fpc-3.2.2-aarch64-linux cprt0-glibc234 $FPC_SHA256"
PREFIX=$TOOLS/fpc-aarch64
LIBDIR=$PREFIX/lib/fpc/3.2.2
SYSROOT=/usr/aarch64-linux-gnu

mkdir -p "$TOOLS/bin" "$TOOLS/src"

for T in aarch64-linux-gnu-as aarch64-linux-gnu-ld qemu-aarch64 fpc; do
  command -v "$T" > /dev/null 2>&1 || { echo "get-cross-aarch64: $T not found (apt: binutils-aarch64-linux-gnu, qemu-user, fpc)"; exit 1; }
done
[ -f "$SYSROOT/lib/libc.so.6" ] || { echo "get-cross-aarch64: $SYSROOT/lib/libc.so.6 not found (apt: libc6-arm64-cross)"; exit 1; }
[ "$(fpc -iV)" = 3.2.2 ] || { echo "get-cross-aarch64: host fpc is $(fpc -iV), need 3.2.2"; exit 1; }

if [ -f "$TOOLS/fpc-aarch64.stamp" ] && [ "$(cat "$TOOLS/fpc-aarch64.stamp")" = "$PIN" ] \
    && [ -x "$LIBDIR/ppcrossa64" ]; then
  echo "get-cross-aarch64: present"
else
  SRC=$TOOLS/src/fpc-3.2.2
  TAR=$TOOLS/src/fpc-3.2.2.tar.gz
  if ! { [ -f "$TAR" ] && echo "$FPC_SHA256  $TAR" | sha256sum -c --quiet > /dev/null 2>&1; }; then
    echo "get-cross-aarch64: fetching the FPC 3.2.2 source"
    curl -sSL -o "$TAR" "$FPC_URL"
    echo "$FPC_SHA256  $TAR" | sha256sum -c --quiet || { echo "get-cross-aarch64: checksum mismatch for $TAR"; exit 1; }
  fi
  rm -rf "$SRC" "$PREFIX"
  mkdir -p "$SRC"
  tar xzf "$TAR" -C "$SRC" --strip-components=1
  # the glibc 2.34 patch of the C start-up code (see the header)
  python3 -I - "$SRC/rtl/linux/aarch64/cprt0.as" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ("\tadrp\tx3,:got:__libc_csu_init\n"
       "\tldr\tx3,[x3,#:got_lo12:__libc_csu_init]\n"
       "\tadrp\tx4,:got:__libc_csu_fini\n"
       "\tldr\tx4,[x4,#:got_lo12:__libc_csu_fini]\n")
new = ("\t/* glibc 2.34+ has no __libc_csu_init / __libc_csu_fini: null init\n"
       "\t   and fini make __libc_start_main run the ELF constructors itself */\n"
       "\tmov\tx3,#0\n"
       "\tmov\tx4,#0\n")
assert old in s, "cprt0.as: the __libc_csu_init sequence was not found"
open(p, "w").write(s.replace(old, new))
PY
  echo "get-cross-aarch64: building the cross compiler, RTL and packages (a few minutes)"
  if ! make -C "$SRC" crossall crossinstall OS_TARGET=linux CPU_TARGET=aarch64 \
      BINUTILSPREFIX=aarch64-linux-gnu- FPC="$(command -v fpc)" INSTALL_PREFIX="$PREFIX" \
      > "$TOOLS/fpc-aarch64.build.log" 2>&1; then
    echo "get-cross-aarch64: build FAILED (see $TOOLS/fpc-aarch64.build.log)"
    exit 1
  fi
  echo "$PIN" > "$TOOLS/fpc-aarch64.stamp"
fi

# The linker wants libc.so, libpthread.so and libdl.so; libc6-arm64-cross
# ships only the versioned files (libc6-dev-arm64-cross has the rest, but
# it is not needed: these links are enough).
mkdir -p "$PREFIX/lib"
ln -sf "$SYSROOT/lib/libc.so.6" "$PREFIX/lib/libc.so"
ln -sf "$SYSROOT/lib/libpthread.so.0" "$PREFIX/lib/libpthread.so"
ln -sf "$SYSROOT/lib/libdl.so.2" "$PREFIX/lib/libdl.so"

# libgcc_s.so.1 for ARM64 (see the header)
if [ ! -f "$PREFIX/lib/libgcc_s.so.1" ]; then
  echo "get-cross-aarch64: fetching libgcc-s1-arm64-cross"
  rm -rf "$TOOLS/src/libgcc-s1-arm64-cross"
  mkdir -p "$TOOLS/src/libgcc-s1-arm64-cross"
  (cd "$TOOLS/src/libgcc-s1-arm64-cross" && apt-get download libgcc-s1-arm64-cross > download.log 2>&1 \
    && dpkg -x libgcc-s1-arm64-cross_*.deb unpacked) \
    || { echo "get-cross-aarch64: apt-get download libgcc-s1-arm64-cross FAILED (see $TOOLS/src/libgcc-s1-arm64-cross/download.log)"; exit 1; }
  cp "$TOOLS/src/libgcc-s1-arm64-cross/unpacked/usr/aarch64-linux-gnu/lib/libgcc_s.so.1" "$PREFIX/lib/libgcc_s.so.1"
fi

cat > "$TOOLS/bin/fpc-aarch64" <<WRAP
#!/bin/sh
# fpc for aarch64-linux (tools/get-cross-aarch64.sh). No fpc.cfg (-n): the
# unit and library paths (the compiler's and ~/.fppkg's, as /etc/fpc.cfg
# has them), and the language switches of /etc/fpc.cfg, are given here.
exec "$LIBDIR/ppcrossa64" -n -Tlinux -Sgic -CX -XX -viwn -XPaarch64-linux-gnu- -Xr$SYSROOT -Fl"$PREFIX/lib" -Fl$SYSROOT/lib \\
  -Fu"$LIBDIR/units/aarch64-linux/rtl" -Fu"$LIBDIR/units/aarch64-linux/*" \\
  -Fu"\$HOME/.fppkg/lib/fpc/3.2.2/units/aarch64-linux/*" "\$@"
WRAP
cat > "$TOOLS/bin/run-aarch64" <<WRAP
#!/bin/sh
# Runs an aarch64-linux binary under qemu-aarch64 with the ARM64 glibc of
# libc6-arm64-cross and the libgcc_s.so.1 fetched by tools/get-cross-aarch64.sh.
exec qemu-aarch64 -L $SYSROOT -E LD_LIBRARY_PATH=$PREFIX/lib "\$@"
WRAP
chmod +x "$TOOLS/bin/fpc-aarch64" "$TOOLS/bin/run-aarch64"

# smoke test: a threaded hello, cross-compiled and run under qemu
H=$TOOLS/src/hello-aarch64
mkdir -p "$H"
cat > "$H/hello.pas" <<'PAS'
program hello;
{$mode objfpc}{$H+}
uses cthreads, SysUtils;
var N: LongInt = 41;
begin
  WriteLn('hello from ', {$I %FPCTARGETCPU%}, ' ', InterlockedIncrement(N));
end.
PAS
if ! "$TOOLS/bin/fpc-aarch64" -Mobjfpc -Sh -O2 -FE"$H" -FU"$H" "$H/hello.pas" > "$H/build.log" 2>&1; then
  echo "get-cross-aarch64: the hello program did not compile (see $H/build.log)"; exit 1
fi
OUTV=$("$TOOLS/bin/run-aarch64" "$H/hello") || { echo "get-cross-aarch64: the hello program did not run under qemu"; exit 1; }
[ "$OUTV" = "hello from aarch64 42" ] || { echo "get-cross-aarch64: unexpected hello output: $OUTV"; exit 1; }
echo "get-cross-aarch64: ok ($TOOLS/bin/fpc-aarch64, $TOOLS/bin/run-aarch64)"
