#!/bin/sh
# Builds the aarch64 wheel with the cross compiler, installs it in a
# free-threaded CPython for aarch64, run under qemu-user, and runs the
# package's tests against the installed wheel.
#
# Needs: tools/get-cross-aarch64.sh (the cross compiler, and the ARM64
# libgcc_s that glibc loads for pthread_exit); qemu-aarch64 registered in
# binfmt_misc (Debian/Ubuntu: qemu-user-binfmt) and the ARM64 glibc
# (libc6-arm64-cross); uv.
# qemu-user runs on this x86_64 host's memory model, stronger than ARM's:
# this checks that the wheel builds, loads and works, not ARM-only races.
#
# Usage: python/test-aarch64.sh [pytest arguments]
# Env: PYTHON_VERSION, the CPython to test with (default
#      cpython-3.14.4+freethreaded-linux-aarch64-gnu).
# Output under build/python-aarch64-test/; the wheel in its dist/.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=$ROOT/build/python-aarch64-test
PY=${PYTHON_VERSION:-cpython-3.14.4+freethreaded-linux-aarch64-gnu}
FPC=$ROOT/build/tools/bin/fpc-aarch64
[ -x "$FPC" ] || { echo "test-aarch64: no $FPC (run tools/get-cross-aarch64.sh)"; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
  echo "test-aarch64: qemu-aarch64 is not registered in binfmt_misc (qemu-user-binfmt)"; exit 1; }
# the ARM64 glibc, and the libgcc_s of get-cross-aarch64.sh
export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu
export QEMU_SET_ENV="LD_LIBRARY_PATH=$ROOT/build/tools/fpc-aarch64/lib"
mkdir -p "$OUT"
rm -rf "$OUT/dist"
(cd "$HERE" && PYBEARINGS_FPC="$FPC" uv build --wheel --out-dir "$OUT/dist" > "$OUT/build.log" 2>&1) \
  || { echo "test-aarch64: the build failed (see $OUT/build.log)"; exit 1; }
WHEEL=$(ls "$OUT"/dist/pybearings-*-manylinux_*_aarch64.whl)
UV_PYTHON_INSTALL_DIR=$OUT/pythons uv python install --no-bin "$PY" > "$OUT/python.log" 2>&1 \
  || { echo "test-aarch64: no $PY (see $OUT/python.log)"; exit 1; }
# uv python find skips an interpreter of another CPU: the installed one
PYTHON=$(ls -d "$OUT"/pythons/"$PY"/bin/python3 2>/dev/null) \
  || { echo "test-aarch64: no python3 under $OUT/pythons/$PY"; exit 1; }
rm -rf "$OUT/venv" "$OUT/tests"
uv venv -q --python "$PYTHON" "$OUT/venv"
uv pip install -q --python "$OUT/venv/bin/python" "$WHEEL" pytest
# a copy of the tests, away from src/: they import the installed wheel
cp -r "$HERE/tests" "$OUT/tests"
echo "test-aarch64: $(basename "$WHEEL") on $("$OUT/venv/bin/python" -c \
  'import platform, sys; print(platform.machine(), sys.version.split()[0], "GIL off" if not sys._is_gil_enabled() else "GIL on")')"
cd "$OUT"
exec "$OUT/venv/bin/python" -m pytest -q -p no:cacheprovider tests "$@"
