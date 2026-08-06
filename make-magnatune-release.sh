#!/bin/bash
# Build the notarized "magnatune-app installer" from the notarized SideStepWizard.app,
# zip it, and upload it as a Release asset on johnbuckman/magnatune-app so the docs-site
# button's fallback download works.
#
# Prereq: ./notarize-wizard.sh has produced a notarized + stapled dist/SideStepWizard.app.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/SideStepWizard.app"
REPO="johnbuckman/magnatune-app"
APPNAME="magnatune-app"
ZIP="dist/magnatune-app-installer.zip"        # stable release-asset name (docs link)

[ -d "$APP" ] || { echo "missing $APP — run ./notarize-wizard.sh first" >&2; exit 1; }

# The installer finds the repo by its immutable GitHub id (base62) in its filename.
ID=$(gh api "repos/$REPO" -q .id)
[ -n "$ID" ] || { echo "couldn't fetch GitHub id for $REPO" >&2; exit 1; }
CODE=$(python3 -c "
n=$ID
a='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
s=''
while n>0:
    s=a[n%62]+s; n//=62
print(s or '0')")
INST="dist/$APPNAME installer ($CODE).app"
echo "==> GitHub id $ID → base62 ($CODE); installer = $(basename "$INST")"

echo "==> Verifying SideStepWizard.app is notarized"
# spctl exits 0 when Gatekeeper accepts it; it prints nothing without -v, so check the
# exit code, not the output.
if ! spctl --assess --type exec "$APP" >/dev/null 2>&1; then
  echo "ERROR: $APP is not notarized/accepted yet — cannot build a clean installer." >&2
  spctl --assess --type exec -vv "$APP" 2>&1 | head -3 >&2
  exit 1
fi

echo "==> Building the renamed installer (rename preserves notarization)"
rm -rf "$INST"
cp -R "$APP" "$INST"
# Confirm the renamed copy is still accepted (the staple travels with the .app).
spctl --assess --type exec "$INST" >/dev/null 2>&1 \
  || { echo "ERROR: renamed installer lost notarization" >&2; exit 1; }

echo "==> Zipping (ditto preserves the bundle + staple)"
rm -f "$ZIP"
ditto -c -k --keepParent "$INST" "$ZIP"

echo "==> Finding the latest Release on $REPO"
TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
if [ -z "$TAG" ]; then
  echo "no existing release found — creating one" >&2
  TAG="installer"
  gh release create "$TAG" --repo "$REPO" \
     --title "SideStep installer" \
     --notes "One-click installer for Magnatune via SideStep. See https://johnbuckman.github.io/SideStep/"
fi
echo "==> Uploading $ZIP to release $TAG"
gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber

URL="https://github.com/$REPO/releases/latest/download/magnatune-app-installer.zip"
echo "==> Uploaded. Verifying the docs-site download URL resolves:"
code=$(curl -s -o /dev/null -w "%{http_code}" -L "$URL")
echo "    $URL  → HTTP $code"
echo "==> Done."
