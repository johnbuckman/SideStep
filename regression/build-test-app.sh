#!/bin/bash
# Build a tiny, version-stamped iOS test app for the regression suite.
#   ./build-test-app.sh [version] [--name NAME] [--ext]
#     version   default 1.0.0
#     --name     app name (default SelfTest) → id com.sidestep.<lowername>.<team> after signing
#     --ext      also bundle a PlugIns/<NAME>Ext.appex app extension (exercises the
#                extension-bundle-id-nesting path SideStep has to rewrite)
# Produces regression/artifacts/<NAME>.app (unsigned; SideStep signs it at install).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="1.0.0"; NAME="SelfTest"; EXT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --ext)  EXT=1; shift ;;
    *)      VER="$1"; shift ;;
  esac
done
LOWER="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$HERE/artifacts/$NAME.app"
rm -rf "$OUT"; mkdir -p "$OUT"

xcrun clang -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 -fobjc-arc -O \
  -framework UIKit -framework Foundation \
  -o "$OUT/$NAME" "$HERE/testapp/selftest_app.m" 2>&1 | grep -viE 'using sysroot' || true

cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.sidestep.$LOWER.src</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST

if [ "$EXT" = "1" ]; then
  APPEX="$OUT/PlugIns/${NAME}Widget.appex"
  mkdir -p "$APPEX"
  xcrun clang -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 -fobjc-arc -O -fapplication-extension \
    -e _NSExtensionMain -framework UIKit -framework Foundation \
    -o "$APPEX/${NAME}Widget" "$HERE/testapp/selftest_ext.m" 2>&1 | grep -viE 'using sysroot' || true
  cat > "$APPEX/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${NAME}Widget</string>
  <key>CFBundleDisplayName</key><string>${NAME}Widget</string>
  <key>CFBundleIdentifier</key><string>com.sidestep.$LOWER.src.widget</string>
  <key>CFBundleExecutable</key><string>${NAME}Widget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>SelfTestExtVC</string>
    <key>NSExtensionAttributes</key><dict>
      <key>NSExtensionActivationRule</key><string>TRUEPREDICATE</string>
    </dict>
  </dict>
</dict></plist>
PLIST
  echo "built $OUT  (v$VER, +appex ${NAME}Widget)"
else
  echo "built $OUT  (v$VER, $(stat -f%z "$OUT/$NAME") bytes)"
fi
