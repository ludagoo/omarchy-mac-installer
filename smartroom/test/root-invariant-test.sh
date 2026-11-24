#!/bin/bash
# The root invariant is smartroom-release check-root (omarchy-mac-pkgs), one rule for
# every root: desk-check runs the image's own copy on the image root, no other owner
# rule or allow-list is left here, and release-pack makes the Studio release only
# through the image's build-release (which refuses a root that fails check-root).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
sr=$here/..
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
grep -q 'chroot "$m" .*python3 -I /usr/bin/smartroom-release check-root /' "$sr/desk-check" &&
  ok "desk-check runs the image's smartroom-release check-root" || bad "desk-check does not run check-root"
if grep -v '^[[:space:]]*#' "$sr/desk-check" | grep -nE 'find etc usr opt|owner-allow|visudo -c'; then
  bad "desk-check keeps its own owner rule (above)"
else
  ok "desk-check has no second owner rule"
fi
grep -q 'ldd "$f"' "$sr/desk-check" && grep -q '/usr/lib/chromium/*' "$sr/desk-check" &&
  ok "desk-check fails a program whose shared libraries are missing (the room browser included)" || bad "desk-check does not check shared libraries"
[[ ! -e $sr/room/owner-allow ]] && ok "no owner allow-list (exceptions live in check-root, with reasons)" || bad "room/owner-allow is back"
grep -qE '^smartroom-release([[:space:]]|$)' "$sr/room/packages" && ok "the image ships smartroom-release" || bad "room/packages lacks smartroom-release"
grep -q 'build-release --id "$id" --out "$out" --source-path "$top/@" --line studio' "$sr/release-pack" &&
  ok "release-pack uses the image's build-release" || bad "release-pack does not use build-release"
grep -q 'check-root "$out/root.btrfs.zst"' "$sr/release-pack" && ok "release-pack checks the stream it made" || bad "release-pack does not check the stream"
if grep -v '^[[:space:]]*#' "$sr/release-pack" | grep -nE 'btrfs send|rsync|btrfs subvolume snapshot'; then bad "release-pack sends or copies a root itself"; else ok "release-pack never sends a root itself"; fi
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
code() { set +e; bash "$sr/release-pack" "$@" >"$t/out" 2>&1; echo $?; set -e; }
[[ $(code z "$t/o" --work "$t/w") == 64 ]] && ok "release-pack wants --id" || bad "release-pack ran without --id"
[[ $(code z "$t/o" --id x --work "$t/w" --sign-key ABC) == 64 ]] && ok "a signature needs the public key to check it" || bad "--sign-key without --key-asc"
[[ $(code z "$t/o" --id x --work /tmp/w) == 64 ]] && ok "the work directory is not /tmp" || bad "release-pack accepted /tmp"
if (( EUID != 0 )); then
  [[ $(code z "$t/o" --id x --work /nonexistent-release-pack-test/w) == 1 ]] && grep -q 'run as root' "$t/out" && ok "release-pack needs root" || bad "release-pack ran without root"
fi
exit $fail
