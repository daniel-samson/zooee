#!/usr/bin/env bash
# Download the vendored Lucide SVG pool into assets/lucide/icons/ (gitignored).
# The pool isn't committed — src/lucide.zig is the baked artifact — so fetch it
# here whenever you need to regenerate (`zig build gen-lucide`). Pin matches
# the baked set.
#
#   tools/fetch-lucide.sh        # fetch the pinned version
#   zig build gen-lucide         # rebake src/lucide.zig from it
set -euo pipefail

version="1.21.0" # keep in sync with assets/lucide/LICENSE + src/lucide.zig
repo="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo/assets/lucide/icons"
url="https://github.com/lucide-icons/lucide/releases/download/${version}/lucide-icons-${version}.zip"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading Lucide ${version}…"
curl -fsSL -o "$tmp/lucide.zip" "$url"
unzip -q "$tmp/lucide.zip" -d "$tmp/x"

mkdir -p "$dest"
cp "$tmp/x/icons/"*.svg "$dest/"
echo "fetched $(ls "$dest" | wc -l | tr -d ' ') icons → assets/lucide/icons/"
echo "now run: zig build gen-lucide   # rebake src/lucide.zig"
