#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/check-resources.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Info.plist")"
build_num="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$root/Info.plist")"
app="$root/build/Show Bar.app"
archive="/tmp/ShowBarDesktop.xcarchive"
export_dir="/tmp/ShowBarDesktopExport"
export_plist="$root/MacAppStore/ExportOptions-DeveloperID.plist"
api_key="/Users/naoryanko/.private_keys/AuthKey_Q2Q7AWQ232.p8"
team_req='designated => identifier "com.naoryanko.showbar" and anchor apple generic and certificate leaf[subject.OU] = "CM9QNMLQMQ"'

rm -rf "$app" "$archive" "$export_dir"
mkdir -p "$root/build"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$root/MacAppStore" && xcodegen generate --spec project.yml >/dev/null)
fi

xcodebuild \
  -project "$root/MacAppStore/ShowBarStore.xcodeproj" \
  -scheme ShowBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=CM9QNMLQMQ \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_num" \
  archive

if xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_plist" \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates >/dev/null 2>&1 && [[ -d "$export_dir/Show Bar.app" ]]; then
  ditto "$export_dir/Show Bar.app" "$app"
  if [[ -f "$api_key" ]]; then
    zip="/tmp/ShowBarDesktop.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" \
      --key "$api_key" \
      --key-id "Q2Q7AWQ232" \
      --issuer "70c9685e-8bd7-4050-9947-46e8d30e0a3f" \
      --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
  fi
else
  ditto "$archive/Products/Applications/Show Bar.app" "$app"
  signer="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
  if [[ -n "$signer" ]]; then
    codesign --force --deep --options runtime --timestamp=none \
      -r="$team_req" \
      --sign "$signer" "$app"
  fi
fi

codesign --verify --strict --deep "$app"
codesign -v -R='identifier "com.naoryanko.showbar" and anchor apple generic and certificate leaf[subject.OU] = "CM9QNMLQMQ"' "$app"

echo "Built and verified $app ($version build $build_num)"
