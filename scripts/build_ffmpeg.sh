#!/bin/zsh
# Builds the FFmpeg bundled with the app: LGPL v2.1 only (no --enable-gpl, no nonfree parts), shared libraries
# (so users can replace them, as the LGPL requires), macOS 14+, Apple Silicon.
#   - video encoding uses Apple's VideoToolbox, so the GPL x264/x265 are not needed
#   - https input via OpenSSL 3 (Apache 2.0), linked statically into libavformat
#   - no autodetected libraries: nothing from Homebrew ends up in the build
# Output: vendor/ffmpeg/{bin,lib,licenses}; build_app.sh copies it into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

FFMPEG_VERSION=8.1.1
FFMPEG_SHA256=b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3
OPENSSL_VERSION=3.5.9
MIN_MACOS=14.0
ARCH=arm64
JOBS=$(sysctl -n hw.ncpu)

SRC=$ROOT/vendor-src
WORK=$ROOT/.build/ffmpeg-work
OUT=$ROOT/vendor/ffmpeg
mkdir -p "$SRC" "$WORK"

fetch() {   # url file sha256
    [[ -f "$SRC/$2" ]] || curl -fsSL -o "$SRC/$2" "$1"
    echo "$3  $SRC/$2" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $2"; exit 1; }
}

# --- sources (checksums pinned; FFmpeg's was also checked against its GPG release signature) ---
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz
OPENSSL_SHA256=$(curl -fsSL "$OPENSSL_URL.sha256" | awk '{print $1}')
fetch "$OPENSSL_URL" "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"

FLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS"

# --- OpenSSL (static) ---
if [[ ! -f "$WORK/openssl/lib/libssl.a" ]]; then
    rm -rf "$WORK/openssl-$OPENSSL_VERSION"
    tar xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK"
    (cd "$WORK/openssl-$OPENSSL_VERSION" &&
        ./Configure darwin64-$ARCH-cc no-shared no-tests no-docs no-apps --prefix="$WORK/openssl" --libdir=lib -mmacosx-version-min=$MIN_MACOS &&
        make -j"$JOBS" >/dev/null && make install_sw >/dev/null)
fi

# --- FFmpeg ---
rm -rf "$WORK/ffmpeg-$FFMPEG_VERSION" "$OUT"
tar xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$WORK"
cd "$WORK/ffmpeg-$FFMPEG_VERSION"
PKG_CONFIG_PATH="$WORK/openssl/lib/pkgconfig" ./configure \
    --prefix="$OUT" \
    --arch=$ARCH --target-os=darwin \
    --extra-cflags="$FLAGS -I$WORK/openssl/include" --extra-ldflags="$FLAGS -L$WORK/openssl/lib" \
    --extra-ldexeflags="-Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path/../lib" \
    --install-name-dir=@rpath \
    --enable-shared --disable-static \
    --disable-autodetect \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv \
    --enable-openssl --pkg-config-flags=--static \
    --disable-ffplay --disable-doc --disable-debug \
    >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null

# --- licences and the source offer the LGPL asks for ---
mkdir -p "$OUT/licenses"
cp COPYING.LGPLv2.1 LICENSE.md "$OUT/licenses/"
cp "$WORK/openssl-$OPENSSL_VERSION/LICENSE.txt" "$OUT/licenses/OpenSSL-LICENSE.txt"
cat > "$OUT/licenses/README.txt" <<EOF
This application uses FFmpeg $FFMPEG_VERSION (https://ffmpeg.org), licensed under the GNU Lesser General Public
License version 2.1 or later, built as shared libraries (lib*.dylib in Contents/Frameworks) that can be replaced.
It was configured without GPL or nonfree components; https support uses OpenSSL $OPENSSL_VERSION (Apache License 2.0).
Source code: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
The exact build script is scripts/build_ffmpeg.sh in the application's source repository.
EOF
rm -rf "$OUT/include" "$OUT/lib/pkgconfig" "$OUT/share"

"$OUT/bin/ffmpeg" -hide_banner -version | head -1
"$OUT/bin/ffmpeg" -hide_banner -L 2>/dev/null | grep -m1 -i "lesser" || true
echo "Kész: $OUT"
