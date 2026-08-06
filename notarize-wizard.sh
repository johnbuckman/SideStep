#!/bin/bash
# Build, sign, notarize + staple the SideStepWizard DMG in one shot.
# The DMG contains SideStepWizard.app + How-this-works.rtf.
#
#   ./notarize-wizard.sh [output-dir]           default: ./dist
#   NOTARY_PROFILE=<name> ./notarize-wizard.sh   override the notarytool keychain profile
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIDESTEP_IDENTITY:-Developer ID Application: John Buckman (CDZD6VH5KL)}"
# Use bping-notary — sidestep-notary is NOT working with Apple right now (do not use it
# until John says otherwise).
PROFILE="${NOTARY_PROFILE:-bping-notary}"
SHORT_VERSION="$(tr -d ' \n' < VERSION.txt)"
OUT="${1:-./dist}"
mkdir -p "$OUT"

echo "==> Building SideStepInstaller (release)"
swift build --product SideStepInstaller -c release >/dev/null 2>&1 || swift build --product SideStepInstaller
BINDIR=$(swift build --product SideStepInstaller -c release --show-bin-path 2>/dev/null || swift build --show-bin-path)

STAGE=$(mktemp -d)
APP="$STAGE/SideStepWizard.app"
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

echo "==> Signing with: $IDENTITY (hardened runtime + timestamp)"
codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Generating How-this-works.rtf"
RTF="$STAGE/How-this-works.rtf"
./make-howto-rtf.sh "$RTF"

DMG="$OUT/SideStepWizard-${SHORT_VERSION}.dmg"
rm -f "$DMG"
DMGSTAGE=$(mktemp -d)
cp -R "$APP" "$DMGSTAGE/SideStepWizard.app"
cp "$RTF" "$DMGSTAGE/How-this-works.rtf"
echo "==> Building DMG: $DMG"
hdiutil create -volname "SideStep Wizard" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> Submitting to Apple notary (profile: $PROFILE) — this can take a few minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Also staple the standalone .app and leave it in the output dir. Submitting the DMG
# notarized the nested app's cdhash, so the app's ticket is now available. Stapling the
# app itself means a rename-inherited installer ("magnatune-app installer.app") verifies
# OFFLINE — essential, since renaming can't re-fetch a ticket.
echo "==> Stapling the standalone app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -rf "$OUT/SideStepWizard.app"
cp -R "$APP" "$OUT/SideStepWizard.app"
spctl --assess --type exec -vv "$OUT/SideStepWizard.app" 2>&1 | head -2 || true

rm -rf "$STAGE" "$DMGSTAGE"
echo "==> Done."
echo "    Notarized app: $OUT/SideStepWizard.app   (rename → installer inherits notarization)"
echo "    Notarized DMG: $DMG"
