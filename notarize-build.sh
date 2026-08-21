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

IDENTITY="${SIDESTEP_IDENTITY:-Developer ID Application: John Buckman (CDZD6VH5KL)}"
# Version comes from VERSION.txt and auto-increments its patch number every build
# (0.2.1 → 0.2.2 → …). CFBundleShortVersionString == the release tag, so the in-app
# updater's tag-vs-version comparison works.
SHORT_VERSION="$(tr -d ' \n' < VERSION.txt)"
VERSION="$SHORT_VERSION"
LABEL="Beta $SHORT_VERSION"
OUT="${1:-./dist}"
ENT="$PWD/SideStep.entitlements"

echo "==> Building InstallerApp"
# Universal by default so the release runs on both Apple Silicon and Intel Macs.
# The bundled Helpers/idevice stack + OpenSSL.framework are also universal (see
# Helpers/build-idevice-universal.sh). Override with SIDESTEP_ARCHS="--arch arm64".
ARCHS="${SIDESTEP_ARCHS:---arch arm64 --arch x86_64}"
swift build --product InstallerApp -c release $ARCHS >/dev/null 2>&1 || swift build --product InstallerApp $ARCHS
BINDIR=$(swift build --product InstallerApp -c release $ARCHS --show-bin-path 2>/dev/null || swift build $ARCHS --show-bin-path)

STAGE=$(mktemp -d)
APP="$STAGE/SideStep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BINDIR/InstallerApp" "$APP/Contents/MacOS/SideStep"
cp -R "$BINDIR/OpenSSL.framework" "$APP/Contents/MacOS/OpenSSL.framework"
# Universal SwiftPM builds emit rpath @executable_path/../lib, but the framework is
# bundled next to the executable in MacOS/. Add @executable_path so @rpath/OpenSSL...
# resolves. (Single-arch builds emitted @loader_path and didn't need this — the
# universal switch is exactly what made the app fail to launch.)
install_name_tool -add_rpath @executable_path "$APP/Contents/MacOS/SideStep" 2>/dev/null || true
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f /Users/john/altstore-fork/AppIcon.icns ] && cp /Users/john/altstore-fork/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Helpers/idevice "$APP/Contents/Helpers/idevice"
# prebuilt iOS beacon dylib injected into every app we install
cp Helpers/beacon_payload.dat "$APP/Contents/Resources/beacon_payload.dat"
# anti-piracy blocklist (offline fallback; refreshed from the repo at launch)
cp blocklist.json "$APP/Contents/Resources/blocklist.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SideStep</string>
  <key>CFBundleDisplayName</key><string>SideStep</string>
  <key>CFBundleIdentifier</key><string>com.johnbuckman.sidestep</string>
  <key>CFBundleExecutable</key><string>SideStep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>iOS App Archive</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>CFBundleTypeExtensions</key><array><string>ipa</string></array>
  </dict></array>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.johnbuckman.sidestep</string>
    <key>CFBundleURLSchemes</key><array><string>sidestep</string></array>
  </dict></array>
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
# Wi-Fi-sync enabler (lockdown EnableWifiConnections over the USB trusted session)
SIGN --entitlements "$ENT" "$APP/Contents/Helpers/idevice/idevice_wifienable"
# OpenSSL framework linked by the app
SIGN "$APP/Contents/MacOS/OpenSSL.framework/Versions/A/OpenSSL"
SIGN "$APP/Contents/MacOS/OpenSSL.framework"
# finally the app bundle itself
SIGN --entitlements "$ENT" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$OUT"
DMG="$OUT/SideStep-${SHORT_VERSION}.dmg"
rm -f "$DMG"
DMGSTAGE=$(mktemp -d)
cp -R "$APP" "$DMGSTAGE/SideStep.app"
ln -s /Applications "$DMGSTAGE/Applications"
echo "==> Building DMG: $DMG"
hdiutil create -volname "SideStep $LABEL" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

rm -rf "$STAGE" "$DMGSTAGE"

# Auto-increment the patch number for the NEXT build (0.2.1 → 0.2.2 → …).
NEXT="$(python3 -c "v='$SHORT_VERSION'.split('.'); v[-1]=str(int(v[-1])+1); print('.'.join(v))")"
echo "$NEXT" > VERSION.txt
echo "==> Done: $DMG   (next build will be $NEXT)"
echo "    Next: notarytool submit \"$DMG\" --keychain-profile <profile> --wait && stapler staple \"$DMG\""
