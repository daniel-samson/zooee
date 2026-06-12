#!/usr/bin/env bash
# Binary size gate (#14): the sub-2MB promise, enforced per PR.
#
# Builds the app binaries in ReleaseSmall (the shipping-size promise,
# hard 2 MiB cap) and ReleaseSafe (what safety-conscious users ship;
# provisional cap until we have history). Dev tools (visual-diff,
# visual-test) are exempt — they aren't product binaries.
set -euo pipefail

SMALL_MAX=$((2 * 1024 * 1024))      # 2 MiB — the product promise
SAFE_MAX=$((4 * 1024 * 1024))       # provisional; tighten as data accrues

# Product binaries to gate (dev tools excluded).
GATED='zooee zooee-window-demo'

fail=0
echo "| binary | mode | bytes | limit | status |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "|---|---|---|---|---|" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

for mode in ReleaseSmall ReleaseSafe; do
  rm -rf zig-out
  zig build "-Doptimize=$mode"
  limit=$SMALL_MAX
  [ "$mode" = ReleaseSafe ] && limit=$SAFE_MAX
  for name in $GATED; do
    bin=""
    for candidate in "zig-out/bin/$name" "zig-out/bin/$name.exe"; do
      [ -f "$candidate" ] && bin="$candidate"
    done
    [ -z "$bin" ] && continue  # not built on this target (e.g. window demo off-Windows)
    size=$(wc -c < "$bin" | tr -d ' ')
    status=OK
    if [ "$size" -gt "$limit" ]; then
      status="OVER LIMIT"
      fail=1
    fi
    printf '%-20s %-13s %10d bytes (limit %d) %s\n' "$name" "$mode" "$size" "$limit" "$status"
    echo "| $name | $mode | $size | $limit | $status |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  done
done

exit "$fail"
