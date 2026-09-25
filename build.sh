#!/bin/bash
# Builds GooglyOriginal.app from source. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="GooglyOriginal.app"
BIN="$APP/Contents/MacOS/GooglyOriginal"
rm -rf "$APP" Googly.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Compiling…"
swiftc -O -swift-version 5 -enforce-exclusivity=unchecked \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/*.swift -o "$BIN" \
  -framework Cocoa -framework SceneKit -framework SpriteKit -framework AVFoundation -framework GameController \
  2>&1 | grep -v "warning:" | grep -v "^\s*|" | grep -v "^\s*$" || true
[ -f "$BIN" ] || { echo "Build failed"; exit 1; }
cp Info.plist "$APP/Contents/Info.plist"
echo "Making icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "Built $(pwd)/$APP"
