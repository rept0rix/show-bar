#!/bin/zsh
# Build the install disk with a drawn window, not a blank Finder folder.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Info.plist")"
app="$root/build/Show Bar.app"
bg="$root/build/dmg-background.png"
staging="$root/build/dmg-src"
rw="$root/build/Show-Bar-rw.dmg"
out="$root/Show-Bar-${version}.dmg"
vol="Install Show Bar"
mount="/Volumes/${vol}"

if [[ ! -d "$app" ]]; then
  "$root/scripts/build.sh"
fi

swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit \
  "$root/scripts/render-dmg-background.swift" \
  -o "$root/build/render-dmg-background"
"$root/build/render-dmg-background" "$bg"

if mount | grep -q " on ${mount} "; then
  hdiutil detach "$mount" -quiet || true
fi
rm -rf "$staging" "$rw" "$out"
mkdir -p "$staging/.background" "$staging"
cp "$bg" "$staging/.background/background.png"
ditto "$app" "$staging/Show Bar.app"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "$vol" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw" >/dev/null
hdiutil attach "$rw" -mountpoint "$mount" -nobrowse >/dev/null

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$vol"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 70, 1000, 558}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    delay 1
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Show Bar.app" of container window to {200, 248}
    set position of item "Applications" of container window to {600, 248}
    update without registering applications
    close
    open
    delay 1
    set position of item "Show Bar.app" of container window to {200, 248}
    set position of item "Applications" of container window to {600, 248}
  end tell
end tell
APPLESCRIPT

sleep 0.4
swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework CoreGraphics -o "$root/build/winid" - <<'SWIFT'
import CoreGraphics
let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in wins {
    let name = w[kCGWindowName as String] as? String ?? ""
    if name == "Install Show Bar" { print(w[kCGWindowNumber as String] ?? "") }
}
SWIFT
wid=$("$root/build/winid" | head -1)
if [[ -n "$wid" ]]; then
  screencapture -l "$wid" -o "$root/build/dmg-preview.png"
fi
# The .background folder must stay in the disk image. Finder hides it via the invisible flag.
chflags hidden "$mount/.background" || true
hdiutil detach "$mount" -quiet
hdiutil convert "$rw" -format UDZO -ov -o "$out" >/dev/null
rm -f "$rw"
echo "Built $out"
