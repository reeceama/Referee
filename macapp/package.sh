#!/bin/sh
# Builds the downloadable Referee for Mac: one app with its own Python, Referee's code and
# libraries, and the browser extension folder inside, so nothing else needs installing.
# Output: macapp/dist.noindex/Referee.app, Referee-mac.zip (Apple silicon), its .sha256 and Referee-extension.zip.
#
# Usage: sh macapp/package.sh RELEASE   e.g. v1.0.0 (the tag of the GitHub release).
# Publish them as a GitHub release with that name: copies of Referee check for newer releases
# and update themselves.
#
# Python comes from python-build-standalone (Astral), pinned below and checked against its
# published SHA-256. The app is signed ad hoc, not notarised: the first time it's opened,
# macOS asks for it to be allowed in System Settings > Privacy & Security.
set -e
RELEASE="$1"
case "$RELEASE" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Usage: sh macapp/package.sh RELEASE  (a version tag like v1.0.0)"; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PYTHON_RELEASE=20260924
PYTHON_FILE="cpython-3.13.15+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA256=a18e1d1b6067d39cf7b2b605fdb78ad6b8a3aed221c44ef934d399dccf355453
CACHE="$HERE/build-cache/python-$PYTHON_RELEASE"
DIST="$HERE/dist.noindex"  # .noindex: kept out of Spotlight and Launchpad
APP="$DIST/Referee.app"

# 1. The app itself, built as usual.
sh "$HERE/build.sh" --no-install
rm -rf "$DIST"
mkdir -p "$DIST" "$CACHE"
cp -R "$HERE/build.noindex/Referee.app" "$APP"
/usr/libexec/PlistBuddy -c "Delete :RefereeRepository" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RefereeRelease string $RELEASE" "$APP/Contents/Info.plist"

# 2. Python, downloaded once and checked.
if [ ! -f "$CACHE/$PYTHON_FILE" ]; then
  curl -sSL -o "$CACHE/$PYTHON_FILE" \
    "https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/$(printf '%s' "$PYTHON_FILE" | sed 's/+/%2B/')"
fi
echo "$PYTHON_SHA256  $CACHE/$PYTHON_FILE" | shasum -a 256 -c - >/dev/null || { echo "Python download failed its checksum"; exit 1; }
tar -xzf "$CACHE/$PYTHON_FILE" -C "$APP/Contents/Resources"   # unpacks to Resources/python
PY="$APP/Contents/Resources/python/bin/python3"
"$PY" -m pip install --quiet --no-cache-dir --disable-pip-version-check -r "$REPO/server/requirements.txt"

# 3. Referee's code: the launcher, the server and the Word helper (not evaluation scripts or data).
CODE="$APP/Contents/Resources/referee"
mkdir -p "$CODE/server" "$CODE/word-helper"
cp "$REPO/referee.py" "$CODE/"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE"
for f in "$REPO"/server/*.py; do case "$(basename "$f")" in eval_*|load_demo.py) ;; *) cp "$f" "$CODE/server/" ;; esac; done
cp "$REPO"/word-helper/*.py "$CODE/word-helper/"
cp -R "$REPO/extension" "$APP/Contents/Resources/extension"
rm -rf "$APP/Contents/Resources/extension/dev"
cp -R "$REPO/gdocs-addon" "$APP/Contents/Resources/gdocs-addon"   # the Google Docs add-on and its setup guide
find "$APP" -name "__pycache__" -type d -prune -exec rm -rf {} +

# 4. Sign everything ad hoc (Apple silicon won't run unsigned code) and zip it.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent Referee.app Referee-mac.zip)
(cd "$DIST" && shasum -a 256 Referee-mac.zip > Referee-mac.zip.sha256)
# The extension on its own too, for anyone who'd rather load it directly.
(cd "$APP/Contents/Resources" && ditto -c -k --sequesterRsrc --keepParent extension "$DIST/Referee-extension.zip")
echo "Built $APP ($(du -sh "$APP" | cut -f1)) and $DIST/Referee-mac.zip ($(du -sh "$DIST/Referee-mac.zip" | cut -f1))"
