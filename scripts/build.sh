#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Show Bar.app"
binary="$app/Contents/MacOS/ShowBar"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"

iconset="$root/build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
src="$root/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  -framework ServiceManagement \
  "$root/Sources/"*.swift \
  -o "$binary"

identity="$(security find-identity -p codesigning -v | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier com.naoryanko.showbar "$app"
else
  codesign --force --sign - "$app"
fi
echo "Built $app"
