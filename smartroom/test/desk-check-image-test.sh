#!/bin/bash
# Desk-check of an image must not mount the host's ESP, and the room image's
# timezone is UTC unless a build sets SMARTROOM_TIMEZONE.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dc=$here/desk-check
fail() { echo "not ok - $*" >&2; exit 1; }
grep -q 'cover_host_device_tree' "$dc" || fail "desk-check must hide the host device tree"
awk '
  /cover_host_device_tree "\$bootchk\/m"/ { cover = NR }
  /omarchy-apple-silicon-boot-check \$mode/ { check = NR }
  END { exit !(cover && check && cover < check) }
' "$dc" || fail "the host device tree must be covered before the boot check"
grep -q 'zoneinfo/UTC' "$dc" || fail "desk-check must expect timezone UTC"
grep -q 'America/Chicago' "$dc" && fail "desk-check must not require America/Chicago"
grep -q 'chown -R -- "\$SUDO_USER:" "\$work"' "$dc" || fail "desk-check must return its work tree to the runner"
echo "ok - desk-check reads the image ESP, expects UTC, and returns its tree"
