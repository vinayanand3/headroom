#!/bin/bash
# Assembles an unsigned Headroom.app for local development.
# For anything you intend to hand to someone else, use ./scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

# Generate the icon if it isn't there yet, so a fresh clone builds a bundle that
# actually looks like the app. Leaving it out produced a bundle with an empty
# Resources/ and the generic placeholder icon in every dialog.
if [ ! -f Resources/AppIcon.icns ]; then
    swiftc -O -o build/make-icon scripts/make-icon.swift 2>/dev/null
    ./build/make-icon build/Headroom.iconset >/dev/null
    /usr/bin/iconutil -c icns build/Headroom.iconset -o Resources/AppIcon.icns
fi

APP="build/Headroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Headroom" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist      "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns    "$APP/Contents/Resources/AppIcon.icns"

echo "built $APP (unsigned)"
