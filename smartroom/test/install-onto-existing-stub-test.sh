#!/bin/bash
# Exercises smartroom/mac/install-onto-existing-stub against a simulated
# macOS disk (fake diskutil/plutil/newfs_msdos, files for raw devices) on Linux:
# the Studio's layout, where diskutil numbers the new Root after Apple's
# recovery container, a rerun in --boot/--root mode, and the refusals.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mock=$t/bin state=$t/state dev=$t/dev
mkdir -p "$mock" "$state" "$dev"
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin|PATH=$mock:\$PATH|" -e "s|/dev/r|$dev/r|g" \
  -e "s|/var/root/|$t/root/|g" "$here/../mac/install-onto-existing-stub" >"$t/install"
chmod +x "$t/install"; mkdir -p "$t/root"
# partition records: state/<id> = "offset size content name"
part() { echo "$2 $3 $4 $5" >"$state/$1"; : >"$dev/r$1"; }
part disk0s1 0 524288000 Apple_APFS_ISC x
part disk0s2 524288000 494384795648 Apple_APFS macOS
part disk0s3 494909083648 2684354560 Apple_APFS SmartRoomOS
part disk0s4 497593438208 2147483648 EFI EFI-SMART
part disk0s5 499740921856 404000000000 0FC63DAF-8483-4772-8E79-3D69D8477DE4 linux
part disk0s6 903740921856 5368709120 Apple_APFS_Recovery recovery
mkdir -p "$t/vol/disk0s4/vendorfw" "$t/vol/disk0s4/asahi"
echo cpio >"$t/vol/disk0s4/vendorfw/firmware.cpio"; echo tar >"$t/vol/disk0s4/vendorfw/firmware.tar"
echo stub >"$t/vol/disk0s4/asahi/stub_info.json"
cat >"$mock/diskutil" <<SH
#!/bin/bash
state=$state vol=$t/vol
SH
cat >>"$mock/diskutil" <<'SH'
case $1 in
  info)
    id=${3:-$2}; [[ -f $state/$id ]] || exit 1
    read -r off size content name <"$state/$id"
    uuid=11111111-2222-3333-4444-555555555555
    [[ $id == disk0s4 ]] && uuid=A702D68C-B4BB-407E-845C-A60060A5D22B
    mp=""; [[ -d $vol/$id && -e $state/$id.mounted ]] && mp=$vol/$id
    printf 'ParentWholeDisk=disk0\nDiskUUID=%s\nContent=%s\nTotalSize=%s\nPartitionMapPartitionOffset=%s\nMountPoint=%s\n' "$uuid" "$content" "$size" "$off" "$mp" ;;
  list) for f in "$state"/disk0s*; do [[ $f == *.mounted ]] && continue; echo "   x: $(cut -d' ' -f3 "$f")   ${f##*/}"; done ;;
  mount) mkdir -p "$vol/$2"; : >"$state/$2.mounted" ;;
  unmount) rm -f "$state/$2.mounted" ;;
  eraseVolume) rm -f "$state/$4" ;;
  addPartition)
    read -r off size _ <"$state/$2"
    n=1; while [[ -e $state/disk0s$n ]]; do n=$((n + 1)); done
    want=${5%B}; start=$((off + size))
    for f in "$state"/disk0s*; do [[ $f == *.mounted ]] && continue; read -r o _ <"$f"
      if (( o > start )) && (( start + want > o )); then echo "diskutil: not enough space" >&2; exit 1; fi; done
    echo "$start $want 0FC63DAF-8483-4772-8E79-3D69D8477DE4 new" >"$state/disk0s$n"; : >"$(dirname "$state")/dev/rdisk0s$n" ;;
  *) echo "diskutil mock: $*" >&2; exit 1 ;;
esac
SH
printf '#!/bin/bash\nkey=$2; grep "^$key=" | cut -d= -f2-\n' >"$mock/plutil"
printf '#!/bin/bash\necho Darwin\n' >"$mock/uname"
printf '#!/bin/bash\necho 0\n' >"$mock/id"
printf '#!/bin/bash\nshift 2; sha256sum "$@"\n' >"$mock/shasum"
printf '#!/bin/bash\nexec bsdtar "$@"\n' >"$mock/tar"
printf '#!/bin/bash\nexec cp -a "$@"\n' >"$mock/ditto"
printf '#!/bin/bash\nexec /usr/bin/dd "${@/bs=4m/bs=4M}" status=none\n' >"$mock/dd"   # BSD dd takes 4m
cat >"$mock/newfs_msdos" <<SH
#!/bin/bash
echo "\$*" >>$t/newfs.log; rm -rf $t/vol/disk0s4; mkdir -p $t/vol/disk0s4
SH
cat >"$mock/cp" <<'SH'
#!/bin/bash
args=(); for a in "$@"; do case $a in -RX) args+=(-R) ;; -X) ;; *) args+=("$a") ;; esac; done
exec /usr/bin/cp "${args[@]}"
SH
chmod +x "$mock"/*
# a payload: boot.img/root.img (4 MiB multiples) and an esp/ tree
p=$t/payload; mkdir -p "$p/esp/m1n1" "$p/esp/EFI/BOOT" "$p/esp/EFI/Linux" "$p/esp/omarchy"
echo uki >"$p/esp/EFI/Linux/omarchy_linux-aurora.efi"
head -c 4194304 /dev/urandom >"$p/boot.img"; head -c 8388608 /dev/urandom >"$p/root.img"
echo m1n1 >"$p/esp/m1n1/boot.bin"; echo j700 >"$p/esp/m1n1/boot-j700.bin"; echo limine >"$p/esp/EFI/BOOT/BOOTAA64.EFI"
printf '/+SmartRoom Firmware\n  cmdline: root=UUID=x\ntimeout: 1\n' >"$p/esp/limine.conf"
zip=$t/smartroom-firmware-2026.11.17-aarch64-apple-silicon-mac-stable-os-package.zip
(cd "$p" && bsdtar --format zip -cf "$zip" esp boot.img root.img)
sha=$(sha256sum "$zip" | cut -d' ' -f1)
echo "SMARTROOMOS_SERVER_URL=https://example.invalid" >"$t/fb.env"
args=(--zip "$zip" --sha256 "$sha" --esp disk0s4 --esp-partuuid a702d68c-b4bb-407e-845c-a60060a5d22b)

# refusals
"$t/install" "${args[@]}" --linux disk0s6 >"$t/out" 2>&1 && fail "recovery container accepted as --linux"
grep -q "not a Linux partition" "$t/out" || fail "wrong refusal: $(cat "$t/out")"
"$t/install" --zip "$zip" --sha256 "$sha" --esp disk0s4 --esp-partuuid 00000000-0000-0000-0000-000000000000 --linux disk0s5 >"$t/out" 2>&1 &&
  fail "a foreign ESP was accepted"
"$t/install" "${args[@]/$sha/0000}" --linux disk0s5 >"$t/out" 2>&1 && fail "a wrong payload digest was accepted"
echo "ok - refuses the recovery container, a foreign ESP and a wrong digest"

# dry run changes nothing
before=$(cat "$state"/disk0s*)
"$t/install" "${args[@]}" --linux disk0s5 >"$t/out" 2>&1 || fail "dry run failed: $(cat "$t/out")"
[[ $(cat "$state"/disk0s*) == "$before" && ! -e $t/newfs.log ]] || fail "the dry run changed the disk"
echo "ok - the dry run only checks"

# install: Boot takes slot 5, Root slot 7 (after the recovery container's 6)
"$t/install" "${args[@]}" --linux disk0s5 --firstboot-env "$t/fb.env" --full-readback --yes >"$t/out" 2>&1 || fail "install failed: $(cat "$t/out")"
grep -q "Boot disk0s5, Root disk0s7" "$t/out" || fail "wrong partitions: $(grep Boot "$t/out")"
cmp -s "$dev/rdisk0s5" "$p/boot.img" && cmp -s <(head -c 8388608 "$dev/rdisk0s7") "$p/root.img" || fail "images not written"
[[ ! -s $dev/rdisk0s6 ]] || fail "the recovery container was written"
read -r _ size _ <"$state/disk0s5"; [[ $size == 2147483648 ]] || fail "Boot is not 2 GiB"
grep -q -- "-I 0x4f4d5801" "$t/newfs.log" && grep -q "EFI - Smart" "$t/newfs.log" || fail "ESP not formatted like the Engine: $(cat "$t/newfs.log")"
v=$t/vol/disk0s4
[[ -f $v/m1n1/boot.bin && ! -e $v/m1n1/boot-j700.bin && -f $v/vendorfw/firmware.cpio && -f $v/asahi/stub_info.json ]] || fail "ESP content: $(find "$v")"
grep -qx encrypt=0 "$v/omarchy/install.conf" && cmp -s "$v/asahi/extras/firstboot.env" "$t/fb.env" || fail "install.conf/firstboot.env"
echo "ok - splits the Linux partition into Boot and Root by offset, writes and reads back both images, rebuilds the ESP"

# rerun on the installed layout
"$t/install" "${args[@]}" --boot disk0s5 --root disk0s7 --encrypt 1 --yes >"$t/out" 2>&1 || fail "rewrite failed: $(cat "$t/out")"
grep -qx encrypt=1 "$t/vol/disk0s4/omarchy/install.conf" || fail "encrypt=1 not written"
"$t/install" "${args[@]}" --boot disk0s5 --root disk0s6 >"$t/out" 2>&1 && fail "the recovery container accepted as --root"
echo "ok - rewrites an installed Boot and Root, never the recovery container"
