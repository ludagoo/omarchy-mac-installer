#!/bin/bash
# overlay-exclude: the last matching line decides, and a line starting with !
# puts a path back. The Studio keeps Omarchy's boot chain but gets our safety
# files (panic/watchdog sysctls, watchdog drop-in, mkinitcpio safety hook).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
room=$(cd -- "$here/../room" && pwd)
fail() { echo "FAIL overlay-exclude: $*" >&2; exit 1; }

fn=$(sed -n '/^excluded() {/,/^}/p' "$room/setup-run")
[[ -n $fn ]] || fail "setup-run has no excluded()"
# excluded PATH, with HERE_DIR's overlay-exclude
check() { # check LISTFILE_DIR path -> prints excluded|kept
  ( here=$1; eval "$fn"; if excluded "$2"; then echo excluded; else echo kept; fi )
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '# comment' 'etc/mkinitcpio.conf.d/*' 'etc/a' '!etc/mkinitcpio.conf.d/zz-keep.conf' >"$tmp/overlay-exclude"
[[ $(check "$tmp" etc/mkinitcpio.conf.d/90-omarchy.conf) == excluded ]] || fail "glob excludes"
[[ $(check "$tmp" etc/mkinitcpio.conf.d/zz-keep.conf) == kept ]] || fail "! puts a path back"
[[ $(check "$tmp" etc/b) == kept ]] || fail "unlisted paths are kept"
printf '%s\n' '!etc/c' 'etc/c' >"$tmp/overlay-exclude"
[[ $(check "$tmp" etc/c) == excluded ]] || fail "a later exclude beats an earlier !"

# The real list.
for p in etc/sysctl.d/10-smartroomos-panic.conf etc/systemd/system.conf.d/smartroomos-watchdog.conf \
         etc/mkinitcpio.conf.d/zz-smartroomos-safety.conf usr/lib/initcpio/install/smartroomos-safety \
         usr/lib/initcpio/hooks/smartroomos-safety usr/local/sbin/smartroomos-integrity \
         usr/local/sbin/smartroom-rollback usr/lib/systemd/system/smartroomos-integrity.service \
         usr/lib/systemd/system/smartroomos-integrity-periodic.timer \
         usr/lib/systemd/system/smartroom-rollback-mark-good.service etc/smartroomos/integrity.conf; do
  [[ $(check "$room" "$p") == kept ]] || fail "the Studio must get $p"
done
for p in boot/limine.conf etc/default/limine etc/mkinitcpio.conf etc/mkinitcpio.conf.d/90-omarchy.conf \
         etc/limine-entry-tool.d/smartroomos.conf etc/limine-entry-tool.d/zz-smartroom-firmware.conf \
         etc/pacman.conf usr/local/sbin/smartroomos-efi-vars-save; do
  [[ $(check "$room" "$p") == excluded ]] || fail "Omarchy keeps $p"
done
echo "PASS overlay-exclude"
