#!/bin/bash
# Build InstallerApp and bundle it into SideStep.app (repo-relative).
#   ./bundle-app.sh [output-dir]     default output: /Applications/SideStep.app
set -e
cd "$(dirname "$0")"
# Version comes from VERSION.txt (same source as notarize-build.sh), so a local
# test build shows the same number the in-app updater compares against.
SHORT_VERSION="$(tr -d ' \n' < VERSION.txt)"
# Force a relink: swift build sometimes recompiles a changed module but skips
# relinking the executable, which silently bundles a stale binary.
rm -f "$(swift build --show-bin-path)/InstallerApp"
swift build --product InstallerApp
BINDIR=$(swift build --show-bin-path)
APP="${1:-/Applications}/SideStep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/InstallerApp" "$APP/Contents/MacOS/SideStep"
cp -R "$BINDIR/OpenSSL.framework" "$APP/Contents/MacOS/OpenSSL.framework"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Helpers"
cp -R Helpers/idevice "$APP/Contents/Helpers/idevice"   # libimobiledevice device tools (no Python)
cp Helpers/beacon_payload.dat "$APP/Contents/Resources/beacon_payload.dat"  # iOS beacon dylib injected into installs
[ -f blocklist.json ] && cp blocklist.json "$APP/Contents/Resources/blocklist.json"  # anti-piracy offline fallback

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
  <key>CFBundleVersion</key><string>$SHORT_VERSION</string>
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
</dict></plist>
PLIST

# ad-hoc sign WITHOUT hardened runtime so it can dlopen AOSKit/AuthKit for Anisette
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "built + signed: $APP"
