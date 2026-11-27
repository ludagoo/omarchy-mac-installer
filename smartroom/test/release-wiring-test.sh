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
grep -q 'release-key-dev.asc' "$here/build-image" || fail "build-image must hand the optional dev release key to the room setup"
grep -q 'release-keyring.gpg' "$here/room/setup-run" || fail "setup-run must install the release keyring"
grep -q 'release-keyring-dev.gpg' "$here/room/setup-run" || fail "setup-run must install the dev release keyring"
grep -q 'smartroom_install_public_keyring' "$here/room/setup-run" || fail "setup-run must install keyrings through release-lib"
grep -q 'SMARTROOM_SNAPSHOT_HELPER=/usr/bin/smartroom-release' "$here/room/setup-run" \
  || fail "setup-run must point the Room Controller at smartroom-release"
# The pin is written before the studio setup, whose product contract requires it.
pin=$(grep -n 'SMARTROOM_SNAPSHOT_HELPER=/usr/bin/smartroom-release' "$here/room/setup-run" | head -n1 | cut -d: -f1)
run=$(grep -n 'bin/smartroom-studio-setup"$' "$here/room/setup-run" | tail -n1 | cut -d: -f1)
((pin < run)) || fail "the helper pin must be written before smartroom-studio-setup runs"
for want in 'smartroom-release installed' 'Room Controller helper is smartroom-release' 'Mini snapshot/update tool absent' \
            'smartroom-release trusts the release key' 'dev release keyring differs from production' \
            'dev release keyring is mode 0644'; do
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
for dead in usr/local/sbin/smartroom-snapshot usr/local/bin/smartroom-snapshot usr/local/lib/smartroom/snapshot-lib.sh \
            usr/local/sbin/smartroom-boot-try usr/local/sbin/smartroom-boot-commit usr/local/sbin/smartroom-update \
            etc/systemd/system/smartroom-agent.service.d/snapshot-helper.conf; do
  excluded "$dead" || fail "overlay-exclude must drop $dead"
done
for keep in usr/local/sbin/smartroom-first-connect usr/local/sbin/smartroom-emergency usr/local/lib/smartroom/install-lib.sh \
            etc/systemd/system/smartroom-agent.service.d/serial-uucp.conf etc/sudoers.d/smartroomcontroller; do
  ! excluded "$keep" || fail "overlay-exclude must keep $keep"
done
echo "ok - release wiring"
