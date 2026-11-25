#!/bin/bash
# room/packages is the firmware's builder/packages-target.aarch64 minus what the
# Omarchy bottom layer installs (its header). A package the firmware adds for both
# lines (cloudflared for the room tunnel, WS15) must reach the Studio image too:
# 2026.11.21-studio-edge had no cloudflared, and the tunnel only ran from a hand install.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
room=$here/../room/packages
fail=0
grep -qE '^cloudflared([[:space:]]|$)' "$room" && echo "ok - the image ships cloudflared" || { echo "not ok - room/packages lacks cloudflared"; fail=1; }
fw=${SMARTROOM_FIRMWARE:-$(cd -- "$here/../../../smartroomcontrollerfirmware" 2>/dev/null && pwd || true)}
if [[ -z $fw || ! -f $fw/builder/packages-target.aarch64 ]]; then
  echo "skip - no firmware checkout (SMARTROOM_FIRMWARE) to compare with"
  exit $fail
fi
# The bottom layer (Omarchy Mac's base image) and snap-pac (a room never runs pacman).
bottom='asahi-fwextract asahi-scripts btrfs-progs cpio curl iwd jq limine networkmanager sudo wf-recorder snap-pac'
missing=$(comm -23 <(awk '/^[^#[:space:]]/{print $1}' "$fw/builder/packages-target.aarch64" | grep -v '^omarchy/' | sort -u) \
                  <(awk '/^[^#[:space:]]/{print $1}' "$room" | sort -u) | grep -vxF -f <(tr ' ' '\n' <<<"$bottom") || true)
if [[ -z $missing ]]; then
  echo "ok - every firmware package is in room/packages or the bottom layer"
else
  echo "not ok - firmware packages missing from room/packages: $(paste -sd' ' <<<"$missing")"; fail=1
fi
exit $fail
