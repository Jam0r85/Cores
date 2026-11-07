#!/bin/zsh
# Builds Cores.app into ./build. Pass --install to copy it to /Applications and launch it.
# Signs with $CODESIGN_IDENTITY if set (release.sh passes your Developer ID), otherwise ad-hoc,
# which is all you need to run it on this Mac.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Cores"

# Draw the app icon once.
if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  "$BIN" --render-icon "$ICONSET/icon_1024.png"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  rm "$ICONSET/icon_1024.png"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

APP=build/Cores.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cores"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Hardened runtime always; a secure timestamp too when signing with a real certificate (notarization needs both).
codesign --force --options runtime ${CODESIGN_IDENTITY:+--timestamp} --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Cores 2>/dev/null || true
  rm -rf /Applications/Cores.app
  ditto "$APP" /Applications/Cores.app
  open /Applications/Cores.app
  echo "Installed and launched /Applications/Cores.app"
fi
