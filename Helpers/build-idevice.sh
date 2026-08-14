#!/bin/bash
# Build the bundled device helper from source (arm64) and stage it into ./idevice/.
# Produces a self-contained set (helper + relocatable dylibs) that the .app bundles,
# so SideStep needs no Python / pymobiledevice3 / external tools at runtime.
#
# Requires: autotools + pkg-config (e.g. MacPorts), and an arm64 OpenSSL
# (e.g. Homebrew `brew install openssl@3` at /opt/homebrew).
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
WORK="$ROOT/.build-idevice"
PREFIX="$WORK/prefix"
OPENSSL="${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}"
mkdir -p "$WORK/src" "$PREFIX"

export PATH="/opt/local/bin:/usr/bin:/bin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$OPENSSL/lib/pkgconfig"
export CFLAGS="-arch arm64 -I$PREFIX/include -I$OPENSSL/include -Wno-error"
export LDFLAGS="-arch arm64 -L$PREFIX/lib"

cd "$WORK/src"
for r in libplist libimobiledevice-glue libusbmuxd libimobiledevice; do
  [ -d "$r" ] || git clone --depth 1 "https://github.com/libimobiledevice/$r.git"
done
for r in libplist libimobiledevice-glue libusbmuxd libimobiledevice; do
  ( cd "$r" && ./autogen.sh --prefix="$PREFIX" --disable-static --without-cython && make -j4 && make install )
done

# the helpers: idevicehelper (USB) and idevice_ipinstall (direct-IP + heartbeat).
# Both link the same libimobiledevice/libplist; idevice_ipinstall hand-declares the
# symbols it uses (it builds its own network idevice_t), so it needs no extra headers.
clang -arch arm64 -I"$PREFIX/include" "$ROOT/idevicehelper.c" \
  -L"$PREFIX/lib" -limobiledevice-1.0 -lplist-2.0 -o "$WORK/idevicehelper"
clang -arch arm64 -I"$PREFIX/include" "$ROOT/idevice_ipinstall.c" \
  -L"$PREFIX/lib" -limobiledevice-1.0 -lplist-2.0 -o "$WORK/idevice_ipinstall"

# stage a relocatable set into ./idevice/
S="$ROOT/idevice"; rm -rf "$S"; mkdir -p "$S"
cp "$WORK/idevicehelper" "$WORK/idevice_ipinstall" "$S/"
cp "$PREFIX"/lib/libimobiledevice-1.0.*.dylib "$PREFIX"/lib/libusbmuxd-*.dylib \
   "$PREFIX"/lib/libimobiledevice-glue-*.dylib "$PREFIX"/lib/libplist-2.0.*.dylib \
   "$OPENSSL"/lib/libssl.*.dylib "$OPENSSL"/lib/libcrypto.*.dylib "$S/" 2>/dev/null || true
# keep only the concrete (non-symlink) dylibs
find "$S" -type l -delete
cd "$S"
for f in *.dylib; do install_name_tool -id "@rpath/$f" "$f" 2>/dev/null; done
for f in idevicehelper idevice_ipinstall *.dylib; do
  otool -L "$f" | awk 'NR>1{print $1}' | while read dep; do
    case "$dep" in */prefix/lib/*|*/openssl@3/lib/*|*/opt/openssl*/*)
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null;; esac
  done
  install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
  codesign -f -s - "$f" 2>/dev/null || true
done
echo "staged self-contained helper -> $S"
