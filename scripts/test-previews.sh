#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
preview_test_dir="$(mktemp -d /tmp/showbar-preview-tests.XXXXXX)"
trap 'rm -rf "$preview_test_dir"' EXIT

xcrun swiftc \
  "$root/Sources/PreviewSupport/PreviewInteraction.swift" \
  "$root/Sources/PreviewPanel.swift" \
  "$root/Tests/PreviewPanelSmoke/Support.swift" \
  "$root/Tests/PreviewPanelSmoke/main.swift" \
  -o "$preview_test_dir/preview-tests"
"$preview_test_dir/preview-tests"
