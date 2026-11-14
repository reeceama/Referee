#!/bin/sh
# Checks a release before it's tagged and published. Stops at the first problem.
#
# Usage: sh scripts/release_check.sh v1.2.0
#
#   1. the version is the same in the app, the extension and the changelog, and the changelog
#      entry has a date (not "unreleased");
#   2. everything is committed;
#   3. nothing that shouldn't ship is tracked: a link to somewhere outside the repository (as
#      .venv was in 1.1.0), a Python environment, a .env file, or a file over 5 MB;
#   4. the smoke test passes.
set -e
RELEASE="$1"
case "$RELEASE" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Usage: sh scripts/release_check.sh RELEASE  (a version tag like v1.2.0)"; exit 1 ;;
esac
VERSION="${RELEASE#v}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
fail() { echo "✗ $1"; exit 1; }
ok() { echo "✓ $1"; }

# 1. Version
grep -q "<key>CFBundleShortVersionString</key><string>$VERSION</string>" macapp/build.sh || fail "macapp/build.sh doesn't say $VERSION"
grep -q "\"version\": \"$VERSION\"" extension/manifest.json || fail "extension/manifest.json doesn't say $VERSION"
TOP="$(grep -m1 '^## ' CHANGELOG.md)"
case "$TOP" in
  "## $VERSION ("*"unreleased"*) fail "CHANGELOG.md: $VERSION is still marked unreleased" ;;
  "## $VERSION ("*) ;;
  *) fail "CHANGELOG.md: the newest entry is \"$TOP\", not $VERSION" ;;
esac
ok "version $VERSION in the app, extension and changelog"

# 2. Committed
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes (git status)"
ok "everything committed"

# 3. Nothing stray
STRAY=""
for path in $(git ls-files -s | awk '$1 == "120000" {print $4}'); do
  target="$(git cat-file -p ":$path" 2>/dev/null || readlink "$path")"
  case "$target" in /*|../*) STRAY="$STRAY\n  $path -> $target (a link outside the repository)" ;; esac
done
for path in $(git ls-files | grep -E '(^|/)(\.venv|venv|env)/|(^|/)\.venv$|(^|/)\.env$|pyvenv\.cfg$'); do
  STRAY="$STRAY\n  $path"
done
for path in $(git ls-files); do
  [ -f "$path" ] && [ ! -L "$path" ] && [ "$(wc -c < "$path")" -gt 5000000 ] && STRAY="$STRAY\n  $path (over 5 MB)"
done
[ -z "$STRAY" ] || fail "tracked files that shouldn't ship:$(printf "$STRAY")"
ok "nothing stray tracked"

# 4. Smoke test
PY="$REPO/.venv/bin/python"
[ -x "$PY" ] || PY=python3
"$PY" tests/smoke_test.py > /dev/null 2>&1 || fail "smoke test failed: run $PY tests/smoke_test.py"
ok "smoke test passes"

echo "Ready to tag $RELEASE."
