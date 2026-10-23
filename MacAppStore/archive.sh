#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
team="${DEVELOPMENT_TEAM:-CM9QNMLQMQ}"
version="${MARKETING_VERSION:-1.9.2}"
build="${CURRENT_PROJECT_VERSION:-12}"
archive="${ARCHIVE_PATH:-$root/build/ShowBarStore-$version-build$build.xcarchive}"

mkdir -p "$root/build"
cd "$root"
xcodegen generate --spec project.yml
xcodebuild \
  -project "$root/ShowBarStore.xcodeproj" \
  -scheme ShowBarStore \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  archive

echo "Archive created at $archive"
echo "Open it in Xcode Organizer to validate and upload to App Store Connect."
