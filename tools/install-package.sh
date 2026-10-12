#!/bin/sh
# Builds bearings as an FPC package (fpmake.pp) and installs its units into
# the user's fppkg directory, ~/.fppkg/lib/fpc/<version>/units/<cpu>-linux/bearings,
# which /etc/fpc.cfg (and build/tools/bin/fpc-aarch64) search: afterwards
# a program compiles with `fpc -Mobjfpc -Sh prog.pas`, without -Fu options
# (README.md, "Installing as a package").
#
# Usage: tools/install-package.sh [x86_64|aarch64]   (default x86_64)
#   aarch64 uses the cross compiler of tools/get-cross-aarch64.sh.
# Env: PREFIX overrides ~/.fppkg (the units go to
#      $PREFIX/lib/fpc/<version>/units/<cpu>-linux/bearings).
#
# fpmake needs the directory that holds the compiler's own units (to check
# the implicit dependency on the RTL): for the host compiler it is found by
# asking fpc where it loads system.ppu from; for the cross compiler it is
# build/tools/fpc-aarch64/lib/fpc/<version>.
# Exit status 0 only when the install succeeded.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CPU=${1:-x86_64}
PREFIX=${PREFIX:-$HOME/.fppkg}
case $CPU in
  x86_64)
    FPC=fpc
    T=$(mktemp -d)
    printf 'program p;\nbegin\nend.\n' > "$T/p.pas"
    SYS=$(cd "$T" && fpc -vt p.pas 2>&1 | grep -m1 -o '/[^ ]*/units/[^ /]*/rtl/system.ppu' || true)
    rm -rf "$T"
    [ -n "$SYS" ] || { echo "install-package: cannot find where fpc loads system.ppu from"; exit 1; }
    GU=${SYS%/units/*}
    EXTRA= ;;
  aarch64)
    FPC=$ROOT/build/tools/bin/fpc-aarch64
    [ -x "$FPC" ] || { echo "install-package: no $FPC (run tools/get-cross-aarch64.sh)"; exit 1; }
    GU=$ROOT/build/tools/fpc-aarch64/lib/fpc/3.2.2
    EXTRA="--os=linux --cpu=aarch64 --compiler=$FPC" ;;
  *) echo "install-package: unknown CPU $CPU (x86_64 or aarch64)"; exit 1 ;;
esac
OUT=$ROOT/build/fpmake
mkdir -p "$OUT"
fpc -Mobjfpc -Sh -FE"$OUT" -FU"$OUT" "$ROOT/fpmake.pp" > "$OUT/fpmake.build.log" 2>&1 \
  || { echo "install-package: fpmake.pp did not compile (see $OUT/fpmake.build.log)"; exit 1; }
cd "$ROOT"
# shellcheck disable=SC2086
"$OUT/fpmake" install $EXTRA --prefix="$PREFIX" --globalunitdir="$GU" > "$OUT/install-$CPU.log" 2>&1 \
  || { tail -n 3 "$OUT/install-$CPU.log"; echo "install-package: FAILED (see $OUT/install-$CPU.log)"; exit 1; }
echo "install-package: bearings ($CPU-linux) installed under $PREFIX/lib/fpc/$(fpc -iV)/units/$CPU-linux/bearings"
