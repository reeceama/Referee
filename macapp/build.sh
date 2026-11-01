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

# SwiftMath (MIT, github.com/mgriebling/SwiftMath) draws LaTeX in notes and reports. It's compiled
# in with Referee's own sources, at a fixed version, with a shim for its font bundle.
MATH="$HERE/Packages/SwiftMath"
[ -d "$MATH" ] || git clone --quiet --depth 1 --branch 1.7.3 https://github.com/mgriebling/SwiftMath.git "$MATH"
# Compiled once into a library and reused (it doesn't change), so a build only compiles Referee.
MATHLIB="$HERE/Packages/build"
if [ ! -f "$MATHLIB/libSwiftMath.a" ]; then
  mkdir -p "$MATHLIB"
  find "$MATH/Sources/SwiftMath" -name "*.swift" -print0 | (cd "$MATHLIB" && xargs -0 \
    swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 -module-name SwiftMath \
    -emit-library -static -emit-module -emit-module-path "$MATHLIB/SwiftMath.swiftmodule" \
    -o "$MATHLIB/libSwiftMath.a" "$HERE"/SwiftMathShim/*.swift)
fi
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 -I "$MATHLIB" -L "$MATHLIB" -lSwiftMath \
  -o "$APP/Contents/MacOS/Referee" "$HERE"/Sources/*.swift
cp -R "$MATH/Sources/SwiftMath/mathFonts.bundle" "$APP/Contents/Resources/"

# Reading scanned pages and screenshots with Apple's Vision, for the server.
swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/referee-ocr" "$HERE"/OCR/main.swift
swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/referee-pagecrop" "$HERE"/PageCrop/main.swift
cp "$MATH/LICENSE" "$APP/Contents/Resources/SwiftMath-LICENSE"

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
  <key>CFBundleShortVersionString</key><string>1.0.2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.reeceama.referee.link</string>
    <key>CFBundleURLSchemes</key><array><string>referee</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Referee checks and cites the document you're writing in Word, reads Apple Notes when you import them, and sends meeting action points to Things or Reminders if you choose.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Referee lists your upcoming events, so a meeting's notes can start with its title, date and attendees.</string>
  <key>RefereeRepository</key><string>$REPO</string>
</dict>
</plist>
PLIST

# Signed with the "Referee Local Signing" certificate when this Mac has it, so every build is the same
# app to macOS and permissions (calendars, Automation) are asked for once, not after every build.
# Without it: an ad-hoc signature, as before.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Referee Local Signing"/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
[ "$1" = "--no-install" ] && exit 0  # package.sh builds the app without installing it
rm -rf /Applications/Referee.app "$HOME/Applications/Referee.app"  # older builds went in ~/Applications
cp -R "$APP" /Applications/
# Tell Launch Services and Spotlight about it, so it shows in Applications and search straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Referee.app
mdimport /Applications/Referee.app 2>/dev/null || true
echo "Installed /Applications/Referee.app"
