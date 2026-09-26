#!/bin/bash
# Builds the ffmpeg that ships inside CONVER+ER.
#
#   LGPL only    no --enable-gpl, no --enable-nonfree: every encoder is either
#                Apple's (VideoToolbox) or ffmpeg's own (ProRes, AAC, PCM)
#   static       links nothing but macOS system libraries, so it runs anywhere
#   universal    arm64 + x86_64, glued with lipo
#   all decoders the whole point is reading what macOS no longer can
#
# Output: vendor/ffmpeg/ffmpeg, plus the licence and a NOTICE describing the
# exact build. build.sh copies both into the app bundle when present.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="9.0.2"
SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
DEPLOY="15.0"

CACHE="$HOME/Library/Caches/converer-ffmpeg"
OUT="vendor/ffmpeg"
TARBALL="ffmpeg-$VERSION.tar.xz"
URL="https://ffmpeg.org/releases/$TARBALL"

mkdir -p "$CACHE" "$OUT"

if [ ! -f "$CACHE/$TARBALL" ]; then
  echo "→ downloading $URL"
  curl -L --fail -o "$CACHE/$TARBALL" "$URL"
fi
echo "→ verifying"
echo "$SHA256  $CACHE/$TARBALL" | shasum -a 256 -c - >/dev/null
echo "  sha256 ok"

CONFIG=(
  --disable-shared --enable-static
  --disable-programs --enable-ffmpeg
  --disable-doc --disable-debug
  --disable-network --disable-avdevice --disable-devices
  --disable-autodetect
  --enable-videotoolbox --enable-audiotoolbox
  --enable-zlib --enable-bzlib --disable-iconv
  --disable-encoders
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,prores_ks,aac,pcm_s16le,pcm_s24le
  --disable-muxers  --enable-muxer=mov,mp4,ipod,null
  --disable-filters --enable-filter=scale,format,aformat,aresample,null,anull,setsar
  --disable-protocols --enable-protocol=file,pipe
)

HOST="$(uname -m)"
JOBS="$(sysctl -n hw.ncpu)"

build_arch() {
  local arch="$1" ff_arch="$1"
  [ "$arch" = "arm64" ] && ff_arch="aarch64"
  local src="$CACHE/src-$arch"
  local extra=()
  [ "$arch" != "$HOST" ] && extra+=(--enable-cross-compile)
  # no nasm on a stock Mac; the heavy lifting is VideoToolbox's anyway
  [ "$arch" = "x86_64" ] && extra+=(--disable-x86asm)

  echo "→ $arch: configuring"
  rm -rf "$src" && mkdir -p "$src"
  tar xf "$CACHE/$TARBALL" -C "$src" --strip-components 1
  (
    cd "$src"
    ./configure "${CONFIG[@]}" ${extra[@]+"${extra[@]}"} \
      --arch="$ff_arch" --target-os=darwin \
      --cc="clang -arch $arch" \
      --extra-cflags="-mmacosx-version-min=$DEPLOY" \
      --extra-ldflags="-mmacosx-version-min=$DEPLOY" \
      > "$CACHE/configure-$arch.log" 2>&1 \
      || { tail -30 "$CACHE/configure-$arch.log"; exit 1; }
    echo "→ $arch: compiling ($JOBS jobs)"
    make -j"$JOBS" ffmpeg > "$CACHE/make-$arch.log" 2>&1 \
      || { tail -30 "$CACHE/make-$arch.log"; exit 1; }
  )
  cp "$src/ffmpeg" "$CACHE/ffmpeg-$arch"
}

build_arch arm64
build_arch x86_64

echo "→ universal binary"
lipo -create "$CACHE/ffmpeg-arm64" "$CACHE/ffmpeg-x86_64" -output "$OUT/ffmpeg"
chmod +x "$OUT/ffmpeg"

cp "$CACHE/src-$HOST/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
cat > "$OUT/NOTICE.txt" <<EOF
CONVER+ER bundles FFmpeg $VERSION (https://ffmpeg.org), licensed under the
GNU Lesser General Public License v2.1 or later — see COPYING.LGPLv2.1.

It runs as a separate program (Contents/Helpers/ffmpeg) and is only used for
video that macOS itself cannot decode or open. It can be replaced with any
other ffmpeg build by swapping that file.

Source:  $URL
SHA-256: $SHA256
Built for macOS $DEPLOY+, arm64 and x86_64, with:

$(printf '  %s\n' "${CONFIG[@]}")

The exact script is scripts/build-ffmpeg.sh in
https://github.com/timurzi13/CONVER-ER
EOF

echo "✓ $OUT/ffmpeg  ($(lipo -archs "$OUT/ffmpeg"), $(du -h "$OUT/ffmpeg" | cut -f1))"
