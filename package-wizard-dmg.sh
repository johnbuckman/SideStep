#!/bin/bash
# Build the SideStepWizard distribution DMG. Opening it shows two items:
#   • SideStepWizard.app     — the developer tool (configure → make a per-app installer)
#   • How-this-works.rtf     — what it does, step by step, plus generic website HTML
#
#   ./package-wizard-dmg.sh [output-dir]     default: ./dist
#
# Notarize the DMG afterwards (Developer-ID signed app inside):
#   xcrun notarytool submit dist/SideStepWizard-<ver>.dmg --keychain-profile <profile> --wait
#   xcrun stapler staple dist/SideStepWizard-<ver>.dmg
set -e
cd "$(dirname "$0")"
SHORT_VERSION="$(tr -d ' \n' < VERSION.txt)"
OUTDIR="${1:-dist}"

# 1. Build the app (Developer-ID signed).
./bundle-installer.sh "$OUTDIR" >/dev/null
APP="$OUTDIR/SideStepWizard.app"
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }

# 2. Generate How-this-works.rtf (shared with notarize-wizard.sh).
STAGE="$(mktemp -d)"
RTF="$STAGE/How-this-works.rtf"
./make-howto-rtf.sh "$RTF"

# 3. Stage the DMG contents and build it.
DMGSTAGE="$(mktemp -d)"
cp -R "$APP" "$DMGSTAGE/SideStepWizard.app"
cp "$RTF" "$DMGSTAGE/How-this-works.rtf"
DMG="$OUTDIR/SideStepWizard-${SHORT_VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "SideStep Wizard" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE" "$DMGSTAGE"
echo "built: $DMG"
echo "contains: SideStepWizard.app + How-this-works.rtf"
echo "notarize:  xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait && xcrun stapler staple \"$DMG\""
