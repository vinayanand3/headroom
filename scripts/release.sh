#!/bin/bash
# Builds, signs and packages Headroom for distribution.
#
#   ./scripts/release.sh            build + sign + dmg
#   ./scripts/release.sh notarize   the above, then notarise + staple
#
# Notarisation needs an App Store Connect credential stored in your keychain.
# Create it once, yourself (it takes your Apple ID and an app-specific password,
# which nothing else here ever sees):
#
#   xcrun notarytool store-credentials "Headroom" \
#       --apple-id "you@example.com" --team-id "$HEADROOM_TEAM_ID"
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Signing identity. Auto-detected when your keychain holds exactly one
# "Developer ID Application" certificate, which is the normal case — hardcoding
# one person's identity would stop anyone else building this at all. Override
# with HEADROOM_IDENTITY when you have several.
if [ -n "${HEADROOM_IDENTITY:-}" ]; then
    IDENTITY="$HEADROOM_IDENTITY"
else
    FOUND=$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
    COUNT=$(printf '%s' "$FOUND" | grep -c . || true)
    if [ "$COUNT" -eq 1 ]; then
        IDENTITY="$FOUND"
    elif [ "$COUNT" -eq 0 ]; then
        echo "No 'Developer ID Application' certificate in your keychain." >&2
        echo "You need one from the Apple Developer Program to sign for" >&2
        echo "distribution. Check with: security find-identity -v -p codesigning" >&2
        exit 1
    else
        echo "Several Developer ID certificates found. Pick one:" >&2
        printf '  export HEADROOM_IDENTITY="%s"\n' $FOUND >&2
        exit 1
    fi
fi

# Team ID falls out of the identity string: "... Name (TEAMID)".
TEAM_ID="${HEADROOM_TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"

# Anaconda ships its own `codesign` that shadows Apple's on PATH and fails with
# "arguments were not expected". Always call the system tools by absolute path.
CODESIGN=/usr/bin/codesign
HDIUTIL=/usr/bin/hdiutil
ICONUTIL=/usr/bin/iconutil
SPCTL=/usr/sbin/spctl

PROFILE="Headroom"
APP="build/Headroom.app"
DMG="build/Headroom.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

echo "==> building $VERSION"
echo "    signing as: $IDENTITY"
swift build -c release

echo "==> icon"
swiftc -O -o build/make-icon scripts/make-icon.swift 2>/dev/null
./build/make-icon build/Headroom.iconset >/dev/null
$ICONUTIL -c icns build/Headroom.iconset -o Resources/AppIcon.icns

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Headroom "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist      "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns    "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing"
# --options runtime  : hardened runtime, required for notarisation
# --timestamp        : secure timestamp, also required
$CODESIGN --force --options runtime --timestamp \
          --sign "$IDENTITY" "$APP"
$CODESIGN --verify --strict --verbose=2 "$APP"

# Notarise the .app BEFORE wrapping it, so the ticket is stapled to the app
# itself and travels with it into /Applications. Stapling only the DMG leaves the
# app relying on an online lookup at first launch — which fails on a plane or a
# locked-down network. Two round trips, but the app then works fully offline.
if [ "${1:-}" = "notarize" ]; then
    echo "==> notarising the app (a few minutes)"
    rm -f build/Headroom-app.zip
    /usr/bin/ditto -c -k --keepParent "$APP" build/Headroom-app.zip
    xcrun notarytool submit build/Headroom-app.zip --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

echo "==> dmg"
rm -rf build/dmgroot "$DMG"
mkdir -p build/dmgroot
cp -R "$APP" build/dmgroot/
ln -s /Applications build/dmgroot/Applications
$HDIUTIL create -volname "Headroom" -srcfolder build/dmgroot \
               -ov -format UDZO "$DMG" >/dev/null
$CODESIGN --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "${1:-}" = "notarize" ]; then
    echo "==> notarising the dmg"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    echo "==> verification"
    $SPCTL -a -vvv -t open --context context:primary-signature "$DMG"
    /usr/bin/hdiutil attach "$DMG" -nobrowse -quiet -mountpoint /tmp/hr-verify
    xcrun stapler validate /tmp/hr-verify/Headroom.app
    $SPCTL -a -vvv -t exec /tmp/hr-verify/Headroom.app
    /usr/bin/hdiutil detach /tmp/hr-verify -quiet
fi

echo
echo "done: $DMG"
