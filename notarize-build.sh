#!/bin/bash
# Build a Developer-ID-signed, hardened-runtime SideStep.app and a signed DMG,
# ready to submit to Apple's notary service.
#
#   ./notarize-build.sh [output-dir]      default output dir: ./dist
#
# After this runs, notarize + staple with:
#   xcrun notarytool submit dist/SideStep-0.2-alpha.dmg --keychain-profile <profile> --wait
#   xcrun stapler staple dist/SideStep-0.2-alpha.dmg
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIDESTEP_IDENTITY:-Developer ID Application: Vid Tadel (XLS3XF57J8)}"
VERSION="0.5.0"
LABEL="Beta 0.1"
OUT="${1:-./dist}"
ENT="$PWD/SideStep.entitlements"

echo "==> Building InstallerApp"
swift build --product InstallerApp -c release >/dev/null 2>&1 || swift build --product InstallerApp
BINDIR=$(swift build --product InstallerApp -c release --show-bin-path 2>/dev/null || swift build --show-bin-path)

STAGE=$(mktemp -d)
APP="$STAGE/SideStep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BINDIR/InstallerApp" "$APP/Contents/MacOS/SideStep"
cp -R "$BINDIR/OpenSSL.framework" "$APP/Contents/MacOS/OpenSSL.framework"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f /Users/john/altstore-fork/AppIcon.icns ] && cp /Users/john/altstore-fork/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Helpers/idevice "$APP/Contents/Helpers/idevice"
# prebuilt iOS beacon dylib injected into every app we install
cp Helpers/beacon_payload.dat "$APP/Contents/Resources/beacon_payload.dat"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SideStep</string>
  <key>CFBundleDisplayName</key><string>SideStep</string>
  <key>CFBundleIdentifier</key><string>com.decent.sidestep</string>
  <key>CFBundleExecutable</key><string>SideStep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

SIGN() { codesign --force --options runtime --timestamp -s "$IDENTITY" "$@"; }

echo "==> Signing nested code (deepest first) with: $IDENTITY"
# bundled libimobiledevice/openssl dylibs used by the device helper
for dylib in "$APP"/Contents/Helpers/idevice/*.dylib; do SIGN "$dylib"; done
# the device helper executable
SIGN --entitlements "$ENT" "$APP/Contents/Helpers/idevice/idevicehelper"
# the direct-IP installer (heartbeat + sync); loads the bundled dylibs via @rpath
SIGN --entitlements "$ENT" "$APP/Contents/Helpers/idevice/idevice_ipinstall"
# Developer Mode detect/reveal helper
SIGN --entitlements "$ENT" "$APP/Contents/Helpers/idevice/idevicedevmodectl"
# OpenSSL framework linked by the app
SIGN "$APP/Contents/MacOS/OpenSSL.framework/Versions/A/OpenSSL"
SIGN "$APP/Contents/MacOS/OpenSSL.framework"
# finally the app bundle itself
SIGN --entitlements "$ENT" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$OUT"
DMG="$OUT/SideStep-${VERSION}-beta.dmg"
rm -f "$DMG"
DMGSTAGE=$(mktemp -d)
cp -R "$APP" "$DMGSTAGE/SideStep.app"
ln -s /Applications "$DMGSTAGE/Applications"
echo "==> Building DMG: $DMG"
hdiutil create -volname "SideStep $LABEL" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

rm -rf "$STAGE" "$DMGSTAGE"
echo "==> Done: $DMG"
echo "    Next: notarytool submit \"$DMG\" --keychain-profile <profile> --wait && stapler staple \"$DMG\""
