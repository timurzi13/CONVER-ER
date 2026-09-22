#!/bin/bash
# Builds CONVER+ER.app with the command-line Swift toolchain — no Xcode project.
# Produces a universal binary when the SDK can target both architectures.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CONVER+ER.app"
BIN="$APP/Contents/MacOS/ConverEr"
DEPLOY="15.0"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

compile() {  # $1 = arch
  swiftc -O -parse-as-library \
    -target "$1-apple-macosx$DEPLOY" \
    -framework AppKit -framework ImageIO -framework UniformTypeIdentifiers \
    -o "build/obj/ConverEr-$1" \
    Sources/*.swift
}

HOST="$(uname -m)"
OTHER=$([ "$HOST" = "arm64" ] && echo x86_64 || echo arm64)

echo "→ compiling $HOST"
compile "$HOST"

if compile "$OTHER" 2>/dev/null; then
  echo "→ compiling $OTHER"
  lipo -create "build/obj/ConverEr-$HOST" "build/obj/ConverEr-$OTHER" -output "$BIN"
  echo "→ universal: $(lipo -archs "$BIN")"
else
  echo "→ $OTHER unavailable, $HOST only"
  cp "build/obj/ConverEr-$HOST" "$BIN"
fi

echo "→ bundling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

rm -rf build/obj
echo "✓ $PWD/$APP"
