#!/usr/bin/env bash
# Promote one or more icons from the vendored Lucide pool into the shipped,
# build-time-baked icons/ set. See assets/lucide/README.md.
#
#   tools/add-icon.sh chevron-down star
#   zig build gen-icons   # regenerate src/generated_icons.zig
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
pool="$repo/assets/lucide/icons"
dest="$repo/icons"

if [ "$#" -eq 0 ]; then
  echo "usage: tools/add-icon.sh <icon-name>..." >&2
  echo "  (name without .svg, e.g. chevron-down)" >&2
  exit 2
fi

# The pool is gitignored (see tools/fetch-lucide.sh); fetch it on demand.
if [ ! -d "$pool" ] || [ -z "$(ls -A "$pool" 2>/dev/null)" ]; then
  echo "Lucide pool missing — fetching it…" >&2
  "$repo/tools/fetch-lucide.sh" >&2
fi

missing=0
for name in "$@"; do
  src="$pool/${name%.svg}.svg"
  if [ ! -f "$src" ]; then
    echo "no such icon in pool: ${name%.svg}" >&2
    missing=1
    continue
  fi
  cp "$src" "$dest/"
  echo "added ${name%.svg}.svg"
done

if [ "$missing" -ne 0 ]; then
  echo "(browse assets/lucide/icons/ or https://lucide.dev/icons for names)" >&2
  exit 1
fi

echo "now run: zig build gen-icons"
