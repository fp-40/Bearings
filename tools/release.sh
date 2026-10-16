#!/bin/sh
# Releases Bearings and pybearings with one version (make release).
#
#   1. checks: on main, no local changes, main equal to origin/main, gh
#      logged in, the tag X.Y.Z new locally and on origin;
#   2. writes the new version where tools/check-version.sh looks for it,
#      and in python/uv.lock (its pybearings entry, by sed: uv lock would
#      also rewrite the file for the uv at hand);
#   3. runs every tier on that tree: make test (fast, Python included)
#      and make test-full (full and conformance);
#   4. shows the change and asks; on "y": commits "Bearings X.Y.Z", tags
#      X.Y.Z (as the tags so far: 0.1.0, 0.2.0), pushes both and creates
#      the GitHub release, which runs .github/workflows/upload-to-pypi.yml
#      (wheels and sdist to PyPI).
#
# A failed check or test, or any answer but "y", puts the version files
# back as they were; nothing is committed or pushed.
#
# Usage: tools/release.sh patch|minor|major|X.Y.Z
#   patch|minor|major bump the current version (both parts must match:
#   tools/check-version.sh); X.Y.Z sets it, also when they do not.
# Env: DRY_RUN=1 stops before the commit (and puts the files back).
#      SKIP_TESTS=1 skips step 3 (for a re-run right after a passing one).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
die() { echo "release: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: tools/release.sh patch|minor|major|X.Y.Z"

# 1. checks
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "the working tree has changes (git status)"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main differs from origin/main"
gh auth status > /dev/null 2>&1 || die "gh is not logged in (gh auth login)"

CUR=$(sed -n "s/^ *BEARINGS_VERSION = '\([^']*\)';.*/\1/p" src/rt/bearings.version.pas)
case $1 in
  patch|minor|major)
    tools/check-version.sh > /dev/null || die "the versions differ: give the new one as X.Y.Z"
    NEW=$(echo "$CUR" | awk -F. -v b="$1" '{
      if (b == "major") print $1 + 1 ".0.0";
      else if (b == "minor") print $1 "." $2 + 1 ".0";
      else print $1 "." $2 "." $3 + 1 }') ;;
  *)
    echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a version: $1 (X.Y.Z)"
    NEW=$1 ;;
esac
TAG=$NEW
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "the tag $TAG exists"
[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || die "the tag $TAG exists on origin"
echo "release: $CUR -> $NEW"

# from here on, a failure or a "no" restores the version files
FILES="src/rt/bearings.version.pas fpmake.pp README.md python/pyproject.toml python/uv.lock"
COMMITTED=0
restore() {
  if [ "$COMMITTED" -eq 0 ]; then
    # shellcheck disable=SC2086
    git checkout -- $FILES
  fi
}
trap restore EXIT
trap 'exit 130' INT TERM

# 2. the version, everywhere
sed -i "s/^\( *BEARINGS_VERSION = '\)[^']*';/\1$NEW';/" src/rt/bearings.version.pas
sed -i "s/^\( *P\.Version := '\)[^']*';/\1$NEW';/" fpmake.pp
sed -i "s/^\(Version: .*(\)[0-9][^)]*\()\.\)$/\1$NEW\2/" README.md
sed -i "s/^version = \"[^\"]*\"$/version = \"$NEW\"/" python/pyproject.toml
sed -i '/^name = "pybearings"$/{n;s/^version = "[^"]*"$/version = "'"$NEW"'"/}' python/uv.lock
grep -A1 '^name = "pybearings"$' python/uv.lock | grep -qx "version = \"$NEW\"" \
  || die "python/uv.lock: no pybearings entry to change"
[ "$(tools/check-version.sh)" = "$NEW" ] || die "the version files do not say $NEW"

# 3. the tests, on the new tree
if [ "${SKIP_TESTS:-0}" != 1 ]; then
  make test || die "make test failed"
  make test-full || die "make test-full failed"
fi

# 4. commit, tag, push, release
git --no-pager diff --stat
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "release: DRY_RUN: $NEW passed; nothing committed"
  exit 0
fi
printf 'release: commit, tag %s, push and publish to PyPI? [y/N] ' "$TAG"
read -r ANSWER
[ "$ANSWER" = y ] || die "stopped; nothing committed"
# shellcheck disable=SC2086
git commit --quiet -m "Bearings $NEW" -- $FILES
COMMITTED=1
git tag -a "$TAG" -m "Bearings $NEW"
git push --quiet origin main "$TAG"
gh release create "$TAG" --verify-tag --title "$NEW" --generate-notes
echo "release: $TAG published; the wheels go to PyPI from .github/workflows/upload-to-pypi.yml"
