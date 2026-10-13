#!/bin/sh
# Builds Referee.app (the menu bar app) and installs it in /Applications.
# Needs the Xcode command line tools. Run from anywhere: sh macapp/build.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/build.noindex"  # .noindex: kept out of Spotlight and Launchpad, so only the installed app shows
APP="$BUILD/Referee.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  -o "$APP/Contents/MacOS/Referee" "$HERE"/Sources/*.swift

cp "$HERE"/Resources/whistle*.png "$APP/Contents/Resources/"

# App icon: Resources/AppIcon.png (1024px, on Apple's icon grid) at every size macOS asks for.
ICONSET="$BUILD/Referee.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$HERE/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$HERE/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Referee.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Referee</string>
  <key>CFBundleDisplayName</key><string>Referee</string>
  <key>CFBundleIdentifier</key><string>com.reeceama.referee</string>
  <key>CFBundleExecutable</key><string>Referee</string>
  <key>CFBundleIconFile</key><string>Referee</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.reeceama.referee.link</string>
    <key>CFBundleURLSchemes</key><array><string>referee</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Referee's Word helper checks and cites the document you're writing in Word.</string>
  <key>RefereeRepository</key><string>$REPO</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
[ "$1" = "--no-install" ] && exit 0  # package.sh builds the app without installing it
rm -rf /Applications/Referee.app "$HOME/Applications/Referee.app"  # older builds went in ~/Applications
cp -R "$APP" /Applications/
# Tell Launch Services and Spotlight about it, so it shows in Applications and search straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Referee.app
mdimport /Applications/Referee.app 2>/dev/null || true
echo "Installed /Applications/Referee.app"
