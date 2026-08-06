#!/bin/bash
# Build the minimal standalone installer into a base "SideStep Installer.app".
# It bundles NO copy of SideStep and no device tools — at run time it downloads the
# latest SideStep from GitHub Releases and uses SideStep's own tools. Its bundle id
# (com.johnbuckman.sidestep.installer) is deliberately DIFFERENT from SideStep's, so
# macOS never confuses the two.
#
# Notarize this ONCE (own bundle id). make-installer.sh then renames it per repo with
# no re-sign, so every "Install owner--repo.app" inherits this notarization.
#
#   ./bundle-installer.sh [output-dir]      default output-dir: ./dist
set -e
cd "$(dirname "$0")"
SHORT_VERSION="$(tr -d ' \n' < VERSION.txt)"
OUTDIR="${1:-dist}"

rm -f "$(swift build --show-bin-path)/SideStepInstaller"
swift build --product SideStepInstaller
BINDIR=$(swift build --show-bin-path)

APP="$OUTDIR/SideStepWizard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/SideStepInstaller" "$APP/Contents/MacOS/SideStepInstaller"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SideStepWizard</string>
  <key>CFBundleDisplayName</key><string>SideStep Wizard</string>
  <key>CFBundleIdentifier</key><string>com.johnbuckman.sidestep.installer</string>
  <key>CFBundleExecutable</key><string>SideStepInstaller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$SHORT_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Prefer the release Developer ID (stable identity, notarizable); fall back to ad-hoc.
IDENTITY="${SIDESTEP_IDENTITY:-Developer ID Application: John Buckman (CDZD6VH5KL)}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP" >/dev/null 2>&1
  echo "built + signed ($IDENTITY): $APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "built + ad-hoc signed (Developer ID not found): $APP"
fi
echo "next: ./package-wizard-dmg.sh   # notarize + build the SideStepWizard DMG"
