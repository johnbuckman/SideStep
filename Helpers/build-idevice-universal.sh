#!/bin/bash
# Build a UNIVERSAL (arm64 + x86_64) libimobiledevice helper stack for SideStep,
# so the bundled device tools run on both Apple Silicon and Intel Macs.
#
# This is the universal successor to build-idevice.sh. It:
#   * builds a fat OpenSSL from the arm64 (/opt/homebrew) + x86_64 (/usr/local)
#     Homebrew openssl@3 kegs already on this Mac,
#   * builds the whole libimobiledevice stack fat in one pass against it,
#   * compiles the custom helpers fat (incl. idevice_new_network_local.c, which
#     build-idevice.sh omitted), and
#   * stages a relocatable, @rpath-only, ad-hoc-signed set into ./idevice/.
#
# Requires: autotools + pkg-config (MacPorts /opt/local), and BOTH openssl@3 kegs:
#   arm64:  brew install openssl@3                      (-> /opt/homebrew)
#   x86_64: arch -x86_64 /usr/local/bin/brew install openssl@3   (-> /usr/local)
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
WORK="$ROOT/.build-idevice-universal"
PREFIX="$WORK/prefix"
FATSSL="$WORK/openssl-fat"
STAGE="$ROOT/idevice"
ARCHS="-arch arm64 -arch x86_64"
A_SSL="${OPENSSL_ARM64:-/opt/homebrew/opt/openssl@3}"
X_SSL="${OPENSSL_X8664:-/usr/local/opt/openssl@3}"

export PATH="/opt/local/bin:/usr/bin:/bin"

# ── 1. fat OpenSSL (merge the two Homebrew kegs) ────────────────────────────
rm -rf "$WORK"; mkdir -p "$WORK/src" "$PREFIX" "$FATSSL/lib/pkgconfig" "$FATSSL/include"
for l in libssl.3.dylib libcrypto.3.dylib; do
  lipo -create "$A_SSL/lib/$l" "$X_SSL/lib/$l" -output "$FATSSL/lib/$l"
  install_name_tool -id "@rpath/$l" "$FATSSL/lib/$l" 2>/dev/null || true
done
ln -sf libssl.3.dylib "$FATSSL/lib/libssl.dylib"
ln -sf libcrypto.3.dylib "$FATSSL/lib/libcrypto.dylib"
cp -R "$A_SSL/include/." "$FATSSL/include/"
for pc in libssl libcrypto openssl; do
  sed -E "s#^prefix=.*#prefix=$FATSSL#; s#^exec_prefix=.*#exec_prefix=$FATSSL#; s#^libdir=.*#libdir=$FATSSL/lib#; s#^includedir=.*#includedir=$FATSSL/include#" \
    "$A_SSL/lib/pkgconfig/$pc.pc" > "$FATSSL/lib/pkgconfig/$pc.pc"
done

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$FATSSL/lib/pkgconfig"
export CFLAGS="$ARCHS -I$PREFIX/include -I$FATSSL/include -Wno-error"
export CXXFLAGS="$ARCHS -I$PREFIX/include -I$FATSSL/include -Wno-error"
export LDFLAGS="$ARCHS -L$PREFIX/lib -L$FATSSL/lib"
export cross_compiling=no   # fat build: AC_TRY_RUN executes the native arm64 slice

# ── 2. libimobiledevice stack, fat, from current master ─────────────────────
# Current master requires libtatsu (build it too; needs libplist + system libcurl).
# libtatsu must precede libimobiledevice. --without-readline avoids the arm64-only
# MacPorts readline on the x86_64 slice (only afcclient uses it).
REPOS=(libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice)
cd "$WORK/src"
for r in "${REPOS[@]}"; do
  [ -d "$r" ] || git clone --depth 1 "https://github.com/libimobiledevice/$r.git" >/dev/null 2>&1
done
for r in "${REPOS[@]}"; do
  echo "=== building $r fat ==="
  CFG_ENV=()
  # pkg-config would pick MacPorts' arm64-only curl and break x86_64; force system curl.
  [ "$r" = "libtatsu" ] && CFG_ENV=(libcurl_CFLAGS="-I$FATSSL/include" libcurl_LIBS="-lcurl")
  ( cd "$r"
    env "${CFG_ENV[@]}" ./autogen.sh --prefix="$PREFIX" --disable-static --without-cython --without-readline \
      >/dev/null 2>"$WORK/$r.cfg.err" || { echo "CONFIGURE FAILED for $r"; tail -20 "$WORK/$r.cfg.err"; exit 1; }
    make -j4 >/dev/null 2>"$WORK/$r.make.err" || { echo "MAKE FAILED for $r"; tail -30 "$WORK/$r.make.err"; exit 1; }
    make install >/dev/null 2>&1 )
done

# ── 3. custom helpers, fat ──────────────────────────────────────────────────
echo "=== compiling custom helpers fat ==="
clang $ARCHS -I"$PREFIX/include" "$ROOT/idevicehelper.c" \
  -L"$PREFIX/lib" -limobiledevice-1.0 -lplist-2.0 -o "$WORK/idevicehelper"
# idevice_ipinstall needs the local idevice_new_network() (hand-builds a network
# idevice_t against stock libimobiledevice — build-idevice.sh omitted this file).
clang $ARCHS -I"$PREFIX/include" "$ROOT/idevice_ipinstall.c" "$ROOT/idevice_new_network_local.c" \
  -L"$PREFIX/lib" -limobiledevice-1.0 -lplist-2.0 -lusbmuxd-2.0 -o "$WORK/idevice_ipinstall"
clang $ARCHS -I"$PREFIX/include" "$ROOT/idevice_wifienable.c" \
  -L"$PREFIX/lib" -limobiledevice-1.0 -lplist-2.0 -o "$WORK/idevice_wifienable"

# ── 4. stage relocatable set into ./idevice/ ────────────────────────────────
echo "=== staging universal set ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$WORK/idevicehelper" "$WORK/idevice_ipinstall" "$WORK/idevice_wifienable" "$STAGE/"
cp "$PREFIX/bin/idevicedevmodectl" "$STAGE/"   # stock tool from the libimobiledevice build
# concrete (versioned) dylibs only + the fat openssl pair
cp "$PREFIX"/lib/libimobiledevice-1.0.[0-9]*.dylib "$PREFIX"/lib/libusbmuxd-2.0.[0-9]*.dylib \
   "$PREFIX"/lib/libimobiledevice-glue-1.0.[0-9]*.dylib "$PREFIX"/lib/libplist-2.0.[0-9]*.dylib "$STAGE/"
cp "$FATSSL"/lib/libssl.3.dylib "$FATSSL"/lib/libcrypto.3.dylib "$STAGE/"
find "$STAGE" -type l -delete   # drop any short-version symlinks

echo "=== relocating install names + rpath + adhoc sign ==="
cd "$STAGE"
for f in *.dylib; do install_name_tool -id "@rpath/$f" "$f" 2>/dev/null || true; done
for f in idevicehelper idevice_ipinstall idevice_wifienable idevicedevmodectl *.dylib; do
  [ -f "$f" ] || continue
  otool -L "$f" | awk 'NR>1{print $1}' | while read dep; do
    case "$dep" in
      # our build prefixes, plus any absolute OpenSSL path (fat libssl carries per-slice
      # Homebrew Cellar refs to libcrypto that must be rewritten to @rpath).
      "$PREFIX"/lib/*|"$FATSSL"/lib/*|*/openssl@3/lib/*|*/opt/openssl*/*|*/Cellar/openssl*/*|/opt/homebrew/*|/usr/local/*)
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null || true;;
    esac
  done
  install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
  codesign -f -s - "$f" 2>/dev/null || true
done
echo "=== DONE. universal set staged -> $STAGE ==="
for f in "$STAGE"/*; do [ -f "$f" ] && printf "%-38s %s\n" "$(basename "$f")" "$(lipo -archs "$f")"; done
