#!/bin/bash
# Mint a per-repo installer from the base "SideStep Installer.app" template.
#
# The installer reads its OWN filename at run time, so this just copies + renames +
# zips — NO recompile and NO re-sign, so a notarized template stays notarized. A dev
# can do the same by hand: drag "SideStep Installer" out of the DMG and rename it.
# The "/" in owner/repo becomes "--" (illegal in filenames).
#
#   ./make-installer.sh owner/repo [output-dir] [template.app]
#     owner/repo   e.g. johnbuckman/magnatune-app
#     output-dir   where to write the app + zip (default: ./dist)
#     template.app the base installer (default: ./dist/SideStep Installer.app)
set -e
cd "$(dirname "$0")"
REPO="$1"
OUTDIR="${2:-dist}"
BASE="${3:-dist/SideStepWizard.app}"

[ -n "$REPO" ] || { echo "usage: ./make-installer.sh owner/repo [output-dir] [template.app]" >&2; exit 1; }
case "$REPO" in
  */*/*) echo "error: expected exactly one '/', got: $REPO" >&2; exit 1 ;;
  */*)   : ;;
  *)     echo "error: need owner/repo (with a '/'), got: $REPO" >&2; exit 1 ;;
esac
[ -d "$BASE" ] || { echo "template not found: $BASE (run ./bundle-installer.sh first)" >&2; exit 1; }

# owner/repo -> "owner--repo installer.app" (app name first, survives truncation)
ENCODED="${REPO/\//--}"
DEST="$OUTDIR/${ENCODED} installer.app"
mkdir -p "$OUTDIR"
rm -rf "$DEST"
cp -R "$BASE" "$DEST"
# NB: do NOT re-sign. A signature seals contents + Info.plist, not the folder name, so
# renaming leaves it valid and a notarized template stays notarized. Verify only:
codesign --verify --deep --strict "$DEST" 2>/dev/null || echo "warning: template isn't validly signed"

# A .app is a directory → can't be served as one file. ditto-zip it for the web
# "Install with SideStep" fallback (host at github.io/SideStep/installers/).
ZIP="$DEST.zip"; rm -f "$ZIP"
ditto -c -k --keepParent "$DEST" "$ZIP"
echo "built: $DEST"
echo "zipped: $ZIP"
echo "downloads SideStep, readies the device, then opens sidestep://install?repo=$REPO"
