#!/bin/bash
# smartroom/ac-power-check against fake image roots: the good root passes; each
# missing piece (tool, enablement, Studio-only condition, kernel switch) fails.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check=$here/../ac-power-check
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
kver=7.3.0-0sredge3-1-ARCH
mkroot() { # DIR [module-text] : a root that passes
  local r=$1 mod=${2-ac_power_mode}
  mkdir -p "$r/usr/lib/systemd/system" "$r/usr/local/sbin" "$r/etc/systemd/system/multi-user.target.wants" \
    "$r/usr/lib/modules/$kver/kernel/drivers/power/reset"
  printf '#!/bin/bash\n# pm-setting fallback\n' >"$r/usr/local/sbin/smartroom-ac-power"; chmod 755 "$r/usr/local/sbin/smartroom-ac-power"
  printf '[Unit]\nConditionFirmware=|device-tree-compatible(apple,j475c)\nConditionFirmware=|device-tree-compatible(apple,j475d)\n[Install]\nWantedBy=multi-user.target\n' \
    >"$r/usr/lib/systemd/system/smartroom-ac-power.service"
  ln -s /usr/lib/systemd/system/smartroom-ac-power.service "$r/etc/systemd/system/multi-user.target.wants/smartroom-ac-power.service"
  printf 'x\0%s\0y' "$mod" >"$r/usr/lib/modules/$kver/kernel/drivers/power/reset/macsmc-reboot.ko"
}
run() { bash "$check" "$1" "$kver"; }
mkroot "$t/good"
run "$t/good" >"$t/out" && ok "a root with the tool, the enabled Studio-only unit and the kernel switch passes" ||
  { bad "the good root failed: $(cat "$t/out")"; }
mkroot "$t/zst"; rm "$t/zst/usr/lib/modules/$kver/kernel/drivers/power/reset/macsmc-reboot.ko"
if command -v zstd >/dev/null; then
  printf 'x\0ac_power_mode\0' | zstd -q >"$t/zst/usr/lib/modules/$kver/kernel/drivers/power/reset/macsmc-reboot.ko.zst"
  run "$t/zst" >/dev/null && ok "a compressed module is read" || bad "a compressed module is read"
fi
mkroot "$t/a"; rm "$t/a/usr/local/sbin/smartroom-ac-power"
! run "$t/a" >/dev/null && ok "no tool fails" || bad "no tool fails"
mkroot "$t/b"; rm "$t/b/etc/systemd/system/multi-user.target.wants/smartroom-ac-power.service"
! run "$t/b" >/dev/null && ok "an unit that is not enabled fails" || bad "an unit that is not enabled fails"
mkroot "$t/c"; sed -i '/j475d/d' "$t/c/usr/lib/systemd/system/smartroom-ac-power.service"
! run "$t/c" >/dev/null && ok "a unit that skips the M2 Ultra Studio fails" || bad "a unit that skips the M2 Ultra Studio fails"
mkroot "$t/d" "other"; printf '#!/bin/bash\n' >"$t/d/usr/local/sbin/smartroom-ac-power"
! run "$t/d" >/dev/null && ok "a kernel without ac_power_mode and a tool without the fallback fails" || bad "no kernel switch and no fallback fails"
mkroot "$t/e" "other"
run "$t/e" >/dev/null && ok "a kernel without ac_power_mode passes on the tool's nvmem fallback" || bad "the nvmem fallback"
grep -q 'ac-power-check' "$here/../desk-check" && ok "desk-check runs it" || bad "desk-check does not run ac-power-check"
exit $fail
