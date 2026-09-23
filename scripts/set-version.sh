#!/bin/zsh
# Stamp one marketing version through Info.plist, the app fallback, the README, and the site.
# Usage: scripts/set-version.sh 1.3
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Usage: scripts/set-version.sh 1.3" >&2
  exit 1
fi

if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  tag="v${version}.0"
else
  tag="v${version}"
fi

plist="$root/Info.plist"
current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
build=$((current_build + 1))
url="https://github.com/rept0rix/show-bar/releases/download/${tag}/Show-Bar-${version}.dmg"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"

printf '%s\n%s\n' "$version" "$build" > "$root/VERSION"

python3 - "$root" "$version" "$url" <<'PY'
import pathlib, sys
root, version, url = sys.argv[1:]
root = pathlib.Path(root)

swift = root / "Sources/AppMain.swift"
text = swift.read_text()
needle = '// showbar-version'
if needle not in text:
    sys.exit("AppMain.swift is missing // showbar-version")
lines = []
for line in text.splitlines(keepends=True):
    if needle in line:
        line = line.split("??", 1)[0] + f'?? "{version}" {needle}\n'
    lines.append(line)
swift.write_text("".join(lines))

def between(path: pathlib.Path, start: str, end: str, body: str) -> None:
    text = path.read_text()
    if start not in text or end not in text:
        sys.exit(f"{path} is missing version markers")
    pre, rest = text.split(start, 1)
    _, post = rest.split(end, 1)
    path.write_text(pre + start + "\n" + body.rstrip() + "\n" + end + post)

between(
    root / "README.md",
    "<!-- showbar:download -->",
    "<!-- /showbar:download -->",
    f"Show Bar is for macOS 14 or later. The install disk is [Show Bar {version}]({url}). Open it and drag Show Bar into Applications.",
)
between(
    root / "site/index.html",
    "<!-- showbar:download -->",
    "<!-- /showbar:download -->",
    "\n".join([
        f'          <a class="download" href="{url}">Install for Mac</a>',
        '          <script type="text/javascript" src="https://cdnjs.buymeacoffee.com/1.0.0/button.prod.min.js" data-name="bmc-button" data-slug="na0ryank0r" data-color="#FFDD00" data-emoji="" data-font="Cookie" data-text="Buy me a coffee" data-outline-color="#000000" data-font-color="#000000" data-coffee-color="#ffffff"></script>',
        f'          <p class="note">Version {version}. Open the disk image and drag Show Bar into Applications. macOS 14 or later. Not on the Mac App Store. This build opens on the Mac it was signed on.</p>',
    ]),
)
PY

echo "version=$version"
echo "build=$build"
echo "tag=$tag"
echo "dmg=Show-Bar-${version}.dmg"
echo "url=$url"
