#!/bin/bash
# The room image ships smartroom-release and sheds the Mini's snapshot and update
# tools (F15), with the Room Controller pointed at smartroom-release.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "not ok - $*" >&2; exit 1; }

grep -qx 'smartroom-release[[:space:]].*' "$here/room/packages" || grep -qx 'smartroom-release' "$here/room/packages" \
  || fail "room/packages must install smartroom-release"
grep -q 'packages=(.*smartroom-release' "$here/build-packages" || fail "build-packages must build smartroom-release"
grep -q 'release-key.asc' "$here/build-image" || fail "build-image must hand the release key to the room setup"
grep -q 'release-keyring.gpg' "$here/room/setup-run" || fail "setup-run must install the release keyring"
grep -q 'SMARTROOM_SNAPSHOT_HELPER=/usr/bin/smartroom-release' "$here/room/setup-run" \
  || fail "setup-run must point the Room Controller at smartroom-release"
# The pin is written before the studio setup, whose product contract requires it.
pin=$(grep -n 'SMARTROOM_SNAPSHOT_HELPER=/usr/bin/smartroom-release' "$here/room/setup-run" | head -n1 | cut -d: -f1)
run=$(grep -n 'bin/smartroomos-studio-setup"$' "$here/room/setup-run" | tail -n1 | cut -d: -f1)
((pin < run)) || fail "the helper pin must be written before smartroomos-studio-setup runs"
for want in 'smartroom-release installed' 'Room Controller helper is smartroom-release' 'Mini snapshot/update tool absent' \
            'smartroom-release trusts the release key'; do
  grep -q "$want" "$here/desk-check" || fail "desk-check must assert: $want"
done

# overlay-exclude, applied the way setup-run applies it.
excluded() {
  local pattern verdict=1
  while read -r pattern; do
    [[ -n $pattern && $pattern != \#* ]] || continue
    if [[ $pattern == '!'* ]]; then
      # shellcheck disable=SC2053
      [[ $1 == ${pattern:1} ]] && verdict=1
    else
      # shellcheck disable=SC2053
      [[ $1 == $pattern ]] && verdict=0
    fi
  done <"$here/room/overlay-exclude"
  return $verdict
}
for dead in usr/local/sbin/smartroomos-snapshot usr/local/bin/smartroomos-snapshot usr/local/lib/smartroomos/snapshot-lib.sh \
            usr/local/sbin/smartroomos-boot-try usr/local/sbin/smartroomos-boot-commit usr/local/sbin/smartroomos-update \
            etc/systemd/system/smartroom-agent.service.d/snapshot-helper.conf; do
  excluded "$dead" || fail "overlay-exclude must drop $dead"
done
for keep in usr/local/sbin/smartroomos-first-connect usr/local/sbin/smartroomos-emergency usr/local/lib/smartroomos/install-lib.sh \
            etc/systemd/system/smartroom-agent.service.d/serial-uucp.conf etc/sudoers.d/smartroomcontroller; do
  ! excluded "$keep" || fail "overlay-exclude must keep $keep"
done
echo "ok - release wiring"
