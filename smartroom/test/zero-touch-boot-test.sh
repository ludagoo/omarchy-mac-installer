#!/bin/bash
# The image builder's zero-touch files, then the real first-boot leaf.
# limine-boot.sh rewrites /etc/default/limine and keeps only TARGET_OS_NAME.
# ENABLE_VERIFICATION=no has to be the drop-in (limine-entry-tool loads it
# after the packaged yes and before that file). panic=10 has to be a word of
# GRUB_CMDLINE_LINUX_DEFAULT: grub-console.sh does not rewrite that line, and
# omarchy-mac-limine-cmdline copies it onto the UKI command line.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
installer=$(cd -- "$here/../.." && pwd)
boot=${SMARTROOM_MAC_BOOT:-}
if [[ -z $boot ]]; then
  boot=$(cd -- "$installer/../omarchy-mac-pkgs/omarchy-mac-boot" 2>/dev/null && pwd || true)
fi
[[ -n $boot && -f $boot/setup/limine-boot.sh && -f $boot/bin/omarchy-mac-limine-cmdline ]] ||
  { echo "SMARTROOM_MAC_BOOT names no omarchy-mac-boot checkout" >&2; exit 1; }
builder=$installer/image-builder/bin/build-mac-image
fail() { echo "FAIL zero-touch-boot: $*" >&2; exit 1; }

run_at=$(grep -n '/var/tmp/smartroom-setup/run' "$builder" | head -n 1 | cut -d: -f1)
drop_at=$(grep -n 'zz-smartroom-firmware.conf' "$builder" | head -n 1 | cut -d: -f1)
panic_at=$(grep -n 'panic=10' "$builder" | head -n 1 | cut -d: -f1)
[[ -n $run_at && -n $drop_at && -n $panic_at ]] || fail "the builder does not write the drop-in and panic=10"
(( drop_at > run_at && panic_at > run_at )) ||
  fail "the drop-in and panic=10 are written before the room layer (it must not be able to replace them)"
# The name limine-boot.sh keeps is still written. The checksum switch is not
# left in the file that leaf rewrites.
name_line=$(grep -n 'TARGET_OS_NAME=' "$builder" | head -n 1)
[[ $name_line == *'printf '"'"'TARGET_OS_NAME="%s"\n'"'"''* ]] ||
  fail "TARGET_OS_NAME is no longer the only key written into /etc/default/limine ($name_line)"
! grep -q 'ENABLE_VERIFICATION=no' <(sed -n '1,'"$run_at"'p' "$builder") ||
  fail "ENABLE_VERIFICATION=no is still written into the file first boot rewrites"
echo "ok - the builder writes the checksum drop-in and panic=10 after the room layer"

# The built configuration: what the image holds when the Mac's first boot runs
# the leaf. Packaged limine-entry-tool.conf says yes. The drop-in says no.
# /etc/default/limine is already the leaf's own rewrite from image build.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub=$test_tmp/bin
esp=$test_tmp/esp
etc=$test_tmp/etc
mkdir -p "$stub" "$esp/EFI/BOOT" "$esp/EFI/Linux" "$etc/limine-entry-tool.d" \
  "$test_tmp/share/limine" "$test_tmp/boot/grub" "$test_tmp/runtime/default/limine"
printf '#!/bin/bash\nexec "$@"\n' >"$stub/sudo"
printf '#!/bin/bash\nexit 0\n' >"$stub/omarchy-hw-apple-silicon"
printf '#!/bin/bash\necho linux-aurora\n' >"$stub/omarchy-mac-kernel"
printf '#!/bin/bash\necho "systemctl $*" >>"$TEST_CALLS"\n' >"$stub/systemctl"
printf '#!/bin/bash\necho "limine-snapper-sync $*" >>"$TEST_CALLS"\n' >"$stub/limine-snapper-sync"
printf '#!/bin/bash\nprintf "systemd\\n"\n' >"$stub/omarchy-mac-initramfs-hooks"
printf '#!/bin/bash\necho "omarchy-mac-boot-update" >>"$TEST_CALLS"\n' >"$stub/omarchy-mac-boot-update"
cat >"$stub/findmnt" <<'SH'
#!/bin/bash
case "$*" in
  "-no TARGET $TEST_ESP") echo "$TEST_ESP" ;;
  "-no UUID /") echo root-uuid ;;
  *) exit 1 ;;
esac
SH
cat >"$stub/limine-update" <<'SH'
#!/bin/bash
echo "limine-update" >>"$TEST_CALLS"
mkdir -p "$TEST_ESP/EFI/Linux"
printf 'UKI\n' >"$TEST_ESP/EFI/Linux/omarchy_linux-aurora.efi"
[[ -f $TEST_ESP/limine.conf ]] || exit 0
grep -q '^/+SmartRoom Firmware' "$TEST_ESP/limine.conf" && exit 0
root=$(dirname "$TEST_LIMINE_DEFAULT")
verify=
take() {
  [[ -f $1 ]] || return 0
  local line
  line=$(sed -n 's/^ENABLE_VERIFICATION=//p' "$1" | tail -n 1)
  line=${line#\"}; line=${line%\"}
  [[ -n $line ]] && verify=$line
}
take "$root/limine-entry-tool.conf"
if [[ -d $root/limine-entry-tool.d ]]; then
  for drop in "$root"/limine-entry-tool.d/*.conf; do
    take "$drop"
  done
fi
take "$TEST_LIMINE_DEFAULT"
cmdline=$(sed -n 's/^KERNEL_CMDLINE\[default\]="\(.*\)"$/\1/p' "$TEST_LIMINE_DEFAULT")
path='boot():/EFI/Linux/omarchy_linux-aurora.efi'
if [[ $verify == yes ]]; then
  hash=$(printf '%128s' '')
  path="$path#${hash// /a}"
fi
printf '/+SmartRoom Firmware\n  //linux-aurora\n  protocol: efi\n  path: %s\n  cmdline: %s\n' "$path" "$cmdline" >>"$TEST_ESP/limine.conf"
SH
chmod +x "$stub"/*
for name in omarchy-mac-limine-cmdline omarchy-mac-limine-deploy omarchy-mac-limine-active; do
  ln -s "$boot/bin/$name" "$stub/$name"
done
printf 'LIMINE\n' >"$test_tmp/share/limine/BOOTAA64.EFI"
printf 'LIMINE\n' >"$esp/EFI/BOOT/BOOTAA64.EFI"
printf 'UKI\n' >"$esp/EFI/Linux/omarchy_linux-aurora.efi"
printf 'timeout: 1\nquiet: yes\ninterface_branding: Omarchy Bootloader\n' >"$test_tmp/runtime/default/limine/limine.conf"
printf 'ENABLE_VERIFICATION=yes\n' >"$etc/limine-entry-tool.conf"
printf '%s\n' '# First boot rewrites /etc/default/limine and keeps only TARGET_OS_NAME.' \
  'ENABLE_VERIFICATION=no' >"$etc/limine-entry-tool.d/zz-smartroom-firmware.conf"
cp "$etc/limine-entry-tool.d/zz-smartroom-firmware.conf" "$test_tmp/drop-in"
printf '%s\n' \
  'GRUB_VIDEO_BACKEND="efi_gop"' \
  'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs rootflags=x-systemd.device-timeout=0"' \
  'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0 plymouth.ignore-serial-consoles panic=10"' \
  >"$etc/grub"
printf 'UUID=root-uuid / btrfs subvol=@ 0 0\n' >"$etc/fstab"
printf 'aaaabbbbccccddddeeeeffff00001111\n' >"$etc/machine-id"
printf 'TARGET_OS_NAME="SmartRoom Firmware"\nENABLE_UKI=yes\nCUSTOM_UKI_NAME="omarchy"\nFIND_BOOTLOADERS=no\nKERNEL_CMDLINE[default]=""\nESP_PATH="%s"\nBOOT_ORDER="linux-aurora, *, *fallback, Snapshots"\n' "$esp" >"$etc/limine"
cat >"$esp/limine.conf" <<'MENU'
timeout: 1
quiet: yes
interface_branding: Omarchy Bootloader
/+SmartRoom Firmware
  //linux-aurora
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-aurora.efi
  cmdline: root=UUID=root-uuid rw quiet splash panic=10
MENU
calls=$test_tmp/calls
: >"$calls"
leaf() {
  TEST_CALLS="$calls" TEST_ESP="$esp" TEST_LIMINE_DEFAULT="$etc/limine" \
    OMARCHY_PATH="$test_tmp/runtime" OMARCHY_ESP="$esp" \
    OMARCHY_LIMINE_EFI="$test_tmp/share/limine/BOOTAA64.EFI" \
    OMARCHY_GRUB_DEFAULT="$etc/grub" OMARCHY_UPDATE_GRUB_DEFAULT="$etc/update-grub" \
    OMARCHY_LIMINE_DEFAULT="$etc/limine" OMARCHY_FSTAB="$etc/fstab" \
    OMARCHY_GRUB_TARGET="$test_tmp/boot/grub/grub-aa64.efi" \
    OMARCHY_GRUB_DIR="$test_tmp/boot/grub" \
    OMARCHY_LIMINE_BOOT_HOOKS_DIR="$etc/boot/hooks/pre.d" \
    OMARCHY_PACMAN_HOOKS_DIR="$etc/pacman.d/hooks" \
    OMARCHY_SYSTEMD_DIR="$etc/systemd/system" \
    OMARCHY_LIMINE_GATE="$test_tmp/limine.enabled" \
    OMARCHY_MACHINE_ID="$etc/machine-id" \
    OMARCHY_LIMINE_MENU_DEFAULTS="$boot/files/usr/lib/omarchy/mac-boot/limine-menu-defaults" \
    OMARCHY_GRUB_PROBE=omarchy-test-absent-grub-probe \
    PATH="$stub:$PATH" bash -c 'source "$1"' _ "$boot/setup/limine-boot.sh"
}
PATH="$stub:$PATH" TEST_CALLS="$calls" OMARCHY_GRUB_DEFAULT="$etc/grub" \
  OMARCHY_GRUB_CONSOLE_PENDING="$test_tmp/no-such-pending" \
  bash -c 'source "$1"' _ "$boot/setup/grub-console.sh" || fail "grub-console.sh failed"
grep -Eq '^GRUB_CMDLINE_LINUX_DEFAULT="(.*[[:space:]])?panic=10([[:space:]].*)?"$' "$etc/grub" ||
  fail "grub-console.sh rewrote away panic=10 ($(cat "$etc/grub"))"
: >"$test_tmp/limine.enabled"
request=$test_tmp/boot-rebuild
OMARCHY_IMAGE_BOOT_REBUILD="$request" leaf || fail "limine-boot.sh failed on the built configuration ($(cat "$calls"))"
[[ -f $request ]] || fail "first boot did not defer the UKI rebuild"
! grep -qx limine-update "$calls" || fail "first boot rebuilt the UKI itself"
cmp -s "$etc/limine-entry-tool.d/zz-smartroom-firmware.conf" "$test_tmp/drop-in" ||
  fail "first boot rewrote the checksum drop-in"
! grep -q '^ENABLE_VERIFICATION=' "$etc/limine" ||
  fail "first boot put ENABLE_VERIFICATION back into /etc/default/limine"
grep -qx 'TARGET_OS_NAME="SmartRoom Firmware"' "$etc/limine" || fail "the OS name was lost"
grep -Eq 'KERNEL_CMDLINE\[default\]="[^"]*panic=10"' "$etc/limine" ||
  fail "the derived UKI command line lost panic=10 ($(grep KERNEL_CMDLINE "$etc/limine"))"
! grep -qE '^ *[a-z_]*path: .*#[0-9a-f]{128}' "$esp/limine.conf" ||
  fail "first boot added a checksum to limine.conf"
echo "ok - first boot keeps ENABLE_VERIFICATION=no and panic=10"

# What the deferred rebuild writes: no checksum, panic=10 on the UKI line.
rm -f "$request" "$esp/EFI/Linux/omarchy_linux-aurora.efi"
cp "$test_tmp/runtime/default/limine/limine.conf" "$esp/limine.conf"
: >"$calls"
leaf || fail "the rebuild failed"
grep -qx limine-update "$calls" || fail "the rebuild did not run limine-update"
! grep -qE '^ *[a-z_]*path: .*#[0-9a-f]{128}' "$esp/limine.conf" ||
  fail "the rebuilt limine.conf carries a checksum ($(grep path "$esp/limine.conf"))"
grep -Eq '^ *cmdline:.*panic=10([[:space:]]|$)' "$esp/limine.conf" ||
  fail "the rebuilt UKI command line has no panic=10 ($(grep cmdline "$esp/limine.conf"))"
echo "ok - the rebuilt limine.conf has no checksum and the UKI line has panic=10"
echo "PASS zero-touch-boot"
