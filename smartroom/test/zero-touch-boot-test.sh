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

# The image's menu says timeout: 0; first boot's leaf and its menu defaults keep that.
sed -i 's/^timeout:.*/timeout: 0/' "$esp/limine.conf"
OMARCHY_IMAGE_BOOT_REBUILD="$request" leaf >/dev/null || fail "limine-boot.sh failed on a timeout: 0 menu"
grep -qx 'timeout: 0' "$esp/limine.conf" && [[ $(grep -c '^timeout:' "$esp/limine.conf") == 1 ]] ||
  fail "first boot changed timeout: 0 ($(grep timeout "$esp/limine.conf"))"
echo "ok - first boot keeps timeout: 0"

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

# --- Never wait at boot (zero-touch boot): the builder's own functions, run on a scratch root.
fns=$(sed -n '/^SMARTROOM_SAFETY_CMDLINE=/p; /^grub_default_has_word() {/,/^}/p; /^add_safety_words() {/,/^}/p; /^force_zero_wait() {/,/^}/p' "$builder")
[[ $fns == *force_zero_wait* && $fns == *add_safety_words* ]] || fail "the builder lost add_safety_words or force_zero_wait"
sandbox() { # sandbox 'commands': the functions, profile=smartroom, a scratch target
  ( profile=smartroom; target=$test_tmp/target; fail() { echo "builder fail: $*" >&2; exit 1; }
    eval "$fns"; eval "$1" )
}
mkdir -p "$test_tmp/target/boot/efi" "$test_tmp/target/etc/default"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash panic=10"\n' >"$test_tmp/target/etc/default/grub"
sandbox 'add_safety_words "$target/etc/default/grub"; add_safety_words "$target/etc/default/grub"' || fail "add_safety_words"
line=$(cat "$test_tmp/target/etc/default/grub")
[[ $line == 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash panic=10 oops=panic softlockup_panic=1 systemd.watchdog_sec=30 fsck.repair=preen"' ]] ||
  fail "safety words appended once and panic=10 kept: $line"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet systemd.watchdog_sec=300"\n' >"$test_tmp/target/etc/default/grub"
sandbox 'add_safety_words "$target/etc/default/grub"' || fail "add_safety_words on a different value"
grep -Eq ' systemd.watchdog_sec=30 fsck.repair=preen"$' "$test_tmp/target/etc/default/grub" || fail "word match is exact, not a prefix"
# Menu timeouts: Omarchy's 1, the leaf's 3, none at all -> 0, with one timeout line.
for start in 'timeout: 1' 'timeout: 3' 'timeout: 10' ''; do
  printf '%s\nquiet: yes\n/+SmartRoom Firmware\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi\n' "$start" >"$test_tmp/target/boot/efi/limine.conf"
  sandbox force_zero_wait || fail "force_zero_wait on '$start'"
  [[ $(grep -c '^timeout:' "$test_tmp/target/boot/efi/limine.conf") == 1 ]] &&
    grep -qx 'timeout: 0' "$test_tmp/target/boot/efi/limine.conf" || fail "timeout: 0 from '$start'"
done
printf 'timeout: 0\n/+X\n  path: boot():/EFI/Linux/a.efi#%s\n' "$(printf 'a%.0s' $(seq 128))" >"$test_tmp/target/boot/efi/limine.conf"
! sandbox force_zero_wait 2>/dev/null || fail "a file checksum on a path must stop the build"
# It runs after the Limine activation, before the UKI command line is verified.
act_at=$(grep -n '^  force_zero_wait$' "$builder" | head -n 1 | cut -d: -f1)
unset_at=$(grep -n '^  verify_uki_cmdline$' "$builder" | head -n 1 | cut -d: -f1)
[[ -n $act_at && -n $unset_at ]] && (( act_at < unset_at )) || fail "force_zero_wait is not called right after the activation"
# The word list is the firmware's (docs/boot-integrity-rollback.md), when its checkout is here.
fw=${SMARTROOM_FIRMWARE:-$(cd -- "$installer/../smartroomcontrollerfirmware" 2>/dev/null && pwd || true)}
if [[ -n $fw && -f $fw/overlay/usr/local/lib/smartroom/install-lib.sh ]]; then
  want=$(bash -c 'source "$1"; smartroom_boot_safety_cmdline' _ "$fw/overlay/usr/local/lib/smartroom/install-lib.sh")
  have=$(sed -n "s/^SMARTROOM_SAFETY_CMDLINE='\(.*\)'\$/\1/p" "$builder")
  [[ $want == "$have" ]] || fail "the builder's safety words differ from the firmware's: '$have' vs '$want'"
  echo "ok - the builder's safety words equal the firmware's"
fi
echo "ok - the builder forces timeout: 0, refuses checksums, and adds the boot safety words once"
echo "PASS zero-touch-boot"
