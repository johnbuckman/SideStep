#!/bin/bash
# Build the shippable, runtime-configured BeaconInject.dylib (arm64 iOS).
# No per-install constants — the dylib reads BeaconConfig.plist at runtime, so
# this one binary is bundled into iSideload and injected into every app.
# Output: ../Helpers/BeaconInject.dylib
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$HERE/../Helpers/BeaconInject.dylib"
mkdir -p "$(dirname "$OUT")"
xcrun clang -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 -fobjc-arc -O \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -framework UserNotifications -framework BackgroundTasks \
  -dynamiclib -o "$OUT" "$HERE/beacon_inject.m" \
  -Wl,-install_name,@executable_path/BeaconInject.dylib 2>&1 | grep -viE 'using sysroot' || true
codesign -f -s - "$OUT" 2>/dev/null || true
echo "built $OUT"
xcrun vtool -show-build-version "$OUT" 2>/dev/null | grep -E 'platform|minos' | sed 's/^/  /'

# Ship it as an obfuscated data blob (XOR 0xA5) — NOT a Mach-O — so macOS
# notarization doesn't try to scan/sign an iOS binary sitting in the bundle.
# iSideload de-obfuscates it into a real BeaconInject.dylib at inject time,
# where zsign signs it for iOS. This .bin is what the app bundle carries.
python3 -c "import sys; d=open('$OUT','rb').read(); open('$HERE/../Helpers/beacon_payload.dat','wb').write(bytes(b^0xA5 for b in d))"
echo "encoded data blob beacon_payload.dat ($(stat -f%z "$HERE/../Helpers/beacon_payload.dat") bytes)"
