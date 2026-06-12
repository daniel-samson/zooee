#!/usr/bin/env bash
# Binary size check (#14): keep zooee lean.
#
# Gates ReleaseSmall only — the shipping-size story. The 2 MiB limit is
# a tripwire, not an absolute: apps like File Pilot prove a serious app
# fits in a couple of MB, and the point is to force a conversation the
# moment we trend toward JS-app bloat, not to block a justified byte.
# Raising the limit is allowed; doing it accidentally is not.
# Dev tools (visual-diff, visual-test) are exempt — not product binaries.
set -euo pipefail

SMALL_MAX=$((2 * 1024 * 1024)) # 2 MiB tripwire

# Product binaries to gate (dev tools excluded).
GATED='zooee zooee-window-demo'

fail=0
echo "| binary | bytes | limit | status |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "|---|---|---|---|" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

rm -rf zig-out
zig build -Doptimize=ReleaseSmall

for name in $GATED; do
  bin=""
  for candidate in "zig-out/bin/$name" "zig-out/bin/$name.exe"; do
    [ -f "$candidate" ] && bin="$candidate"
  done
  [ -z "$bin" ] && continue # not built on this target (e.g. window demo off-Windows)
  size=$(wc -c < "$bin" | tr -d ' ')
  status=OK
  if [ "$size" -gt "$SMALL_MAX" ]; then
    status="OVER LIMIT"
    fail=1
  fi
  printf '%-20s %10d bytes (limit %d) %s\n' "$name" "$size" "$SMALL_MAX" "$status"
  echo "| $name | $size | $SMALL_MAX | $status |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
done

exit "$fail"
