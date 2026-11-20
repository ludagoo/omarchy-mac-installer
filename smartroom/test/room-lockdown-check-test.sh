#!/bin/bash
# smartroom/room-lockdown-check on a scratch image tree: the locked-down tree
# passes, and each way back to a local shell or root fails.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check=$here/room-lockdown-check
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
bad() { echo "FAIL: $*"; fail=1; }

good_tree() { # $1 = root
  local r=$1
  rm -rf "$r"
  mkdir -p "$r/usr/share/smartroomos/hypr" "$r/usr/local/bin" "$r/etc/sudoers.d" \
    "$r/etc/systemd/logind.conf.d" "$r/etc/systemd/system.conf.d" "$r/etc/systemd/system" \
    "$r/usr/lib/systemd/logind.conf.d" "$r/etc/ssh/sshd_config.d" \
    "$r/var/lib/pacman/local/greetd-0.10-1" "$r/home/smartroomcontroller/.config"
  cat >"$r/usr/share/smartroomos/hypr/hyprland.conf" <<'EOF'
# No key binds at all: a classroom keyboard must reach nothing.
input {
    kb_options = srvrkeys:none
}
cursor {
    invisible = true
}
EOF
  cat >"$r/usr/share/smartroomos/hypr/hyprland.lua" <<'EOF'
-- No key binds at all (no hl.bind here).
hl.config({
    input = { kb_options = "srvrkeys:none", },
    cursor = { invisible = true, },
})
EOF
  cat >"$r/usr/local/bin/smartroomos-session" <<'EOF'
kiosk_config() {
  local dir=/usr/share/smartroomos/hypr ver
}
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}" 2>/dev/null || true
EOF
  printf 'root:!*:20000::::::\nsmartroomcontroller:!:20000::::::\nalarm:!$6$x:20000::::::\n' >"$r/etc/shadow"
  printf 'root:x:0:0::/root:/bin/bash\nalarm:x:1000:1000::/home/alarm:/bin/bash\nsmartroomcontroller:x:1001:1001::/home/smartroomcontroller:/bin/bash\n' >"$r/etc/passwd"
  printf 'root:x:0:\nwheel:x:998:alarm\nuucp:x:986:smartroomcontroller\n' >"$r/etc/group"
  printf 'PasswordAuthentication no\n' >"$r/etc/ssh/sshd_config.d/99-smartroomos.conf"
  cat >"$r/etc/sudoers.d/smartroomcontroller" <<'EOF'
# Only the Room Controller's commands; never ALL.
Cmnd_Alias SR_SNAPSHOT = \
    /usr/local/bin/smartroomos-snapshot ^(status|list) --json$, \
    /usr/local/bin/smartroomos-snapshot ^(protect|unprotect|delete) [0-9]+ --json$
Cmnd_Alias SR_ROLLBACK = /usr/local/bin/smartroom-rollback ^status --json$
Cmnd_Alias SR_RELEASE = \
    /usr/bin/smartroom-release ^(status|list) --json$, \
    /usr/bin/smartroom-release ^restore [0-9]+ --no-reboot --json$
Cmnd_Alias SR_REBOOT = /usr/bin/systemctl reboot
smartroomcontroller ALL=(root) NOPASSWD: SR_SNAPSHOT, SR_ROLLBACK, SR_RELEASE, SR_REBOOT
EOF
  printf '[Login]\n#HandlePowerKey=poweroff\n' >"$r/usr/lib/systemd/logind.conf"
  printf '[Login]\nHandlePowerKey=poweroff\n' >"$r/usr/lib/systemd/logind.conf.d/10-vendor.conf"
  local k
  {
    printf '[Login]\n'
    for k in HandlePowerKey HandleRebootKey HandleSuspendKey HandleHibernateKey; do
      printf '%s=ignore\n%sLongPress=ignore\n' "$k" "$k"
    done
    printf 'NAutoVTs=0\nReserveVT=0\n'
  } >"$r/etc/systemd/logind.conf.d/smartroomos-keys.conf"
  printf '[Manager]\nCtrlAltDelBurstAction=none\n' >"$r/etc/systemd/system.conf.d/smartroomos-keys.conf"
  ln -s /dev/null "$r/etc/systemd/system/ctrl-alt-del.target"
  ln -s /dev/null "$r/etc/systemd/system/getty@tty1.service"
}

r=$t/root
good_tree "$r"
out=$(bash "$check" "$r" 2>&1) || { echo "$out"; bad "the locked-down tree must pass"; }
grep -q 'ROOM LOCKDOWN PASS' <<<"$out" || bad "a pass must say ROOM LOCKDOWN PASS"

# Each mutation must fail the check and name what it broke.
must_fail() { # $1 = what, $2 = expected FAIL text, then a command run with $r set
  local what=$1 want=$2
  shift 2
  good_tree "$r"
  "$@"
  out=$(bash "$check" "$r" 2>&1)
  local rc=$?
  (( rc != 0 )) || { bad "$what: the check passed"; return; }
  grep -q "^FAIL .*$want" <<<"$out" || { echo "$out" | grep '^FAIL'; bad "$what: no FAIL line about '$want'"; }
}
must_fail "empty password" "smartroomcontroller password locked" \
  sed -i 's/^smartroomcontroller:!:/smartroomcontroller::/' "$r/etc/shadow"
must_fail "root with a password" "root password locked" \
  sed -i 's/^root:!\*:/root:$6$salt$hash:/' "$r/etc/shadow"
must_fail "alarm unlocked" "alarm password locked" \
  sed -i 's/^alarm:!\$6/alarm:$6/' "$r/etc/shadow"
must_fail "in wheel" "not in wheel" \
  sed -i 's/^wheel:x:998:alarm$/wheel:x:998:alarm,smartroomcontroller/' "$r/etc/group"
must_fail "NOPASSWD: ALL" "grants no ALL command" \
  sed -i 's/NOPASSWD: SR_SNAPSHOT, SR_ROLLBACK, SR_RELEASE, SR_REBOOT/NOPASSWD: ALL/' "$r/etc/sudoers.d/smartroomcontroller"
must_fail "ALL after a list" "grants no ALL command" \
  sed -i 's/NOPASSWD: SR_SNAPSHOT, SR_ROLLBACK, SR_RELEASE, SR_REBOOT/NOPASSWD: SR_SNAPSHOT, ALL/' "$r/etc/sudoers.d/smartroomcontroller"
must_fail "(ALL) ALL on a continued line" "grants no ALL command" \
  bash -c 'printf "smartroomcontroller ALL=\\\\\n  (ALL) ALL\n" >>"$1"' _ "$r/etc/sudoers.d/smartroomcontroller"
must_fail "a shell in sudoers" "no shell" \
  sed -i 's|^Cmnd_Alias SR_REBOOT = .*|Cmnd_Alias SR_REBOOT = /usr/bin/systemctl reboot, /bin/bash|' "$r/etc/sudoers.d/smartroomcontroller"
must_fail "pacman in sudoers" "no shell" \
  sed -i 's|^Cmnd_Alias SR_REBOOT = .*|Cmnd_Alias SR_REBOOT = /usr/bin/systemctl reboot, /usr/bin/pacman|' "$r/etc/sudoers.d/smartroomcontroller"
must_fail "no reboot rule" "systemctl reboot" \
  sed -i 's|^Cmnd_Alias SR_REBOOT = .*|Cmnd_Alias SR_REBOOT = /usr/bin/true|' "$r/etc/sudoers.d/smartroomcontroller"
must_fail "foot installed" "foot not installed" mkdir -p "$r/var/lib/pacman/local/foot-1.20-1"
must_fail "kitty installed" "kitty not installed" mkdir -p "$r/var/lib/pacman/local/kitty-0.40-1"
must_fail "a terminal bind (conf)" "no key binds or exec in hyprland.conf" \
  bash -c 'printf "bind = SUPER, Return, exec, foot\n" >>"$1"' _ "$r/usr/share/smartroomos/hypr/hyprland.conf"
must_fail "exec-once (conf)" "no key binds or exec in hyprland.conf" \
  bash -c 'printf "exec-once = foot\n" >>"$1"' _ "$r/usr/share/smartroomos/hypr/hyprland.conf"
must_fail "a terminal bind (lua)" "no key binds or exec in hyprland.lua" \
  bash -c 'printf "hl.bind(\"SUPER + Return\", hl.dsp.exec_cmd(\"foot\"))\n" >>"$1"' _ "$r/usr/share/smartroomos/hypr/hyprland.lua"
must_fail "VT switch on (conf)" "srvrkeys:none" \
  sed -i '/kb_options/d' "$r/usr/share/smartroomos/hypr/hyprland.conf"
must_fail "VT switch on (lua)" "srvrkeys:none" \
  sed -i '/kb_options/d' "$r/usr/share/smartroomos/hypr/hyprland.lua"
must_fail "kiosk config in skel" "no kiosk config in /etc/skel" mkdir -p "$r/etc/skel/.config/hypr"
must_fail "kiosk config copied to the home" "no kiosk hyprland.lua in /home" \
  bash -c 'mkdir -p "$1/.config/hypr" && : >"$1/.config/hypr/hyprland.lua"' _ "$r/home/smartroomcontroller"
must_fail "image kiosk config missing" "owned by the image: /usr/share/smartroomos/hypr/hyprland.conf" \
  rm "$r/usr/share/smartroomos/hypr/hyprland.conf"
must_fail "session reads the home" "starts Hyprland with /usr/share/smartroomos/hypr" \
  sed -i 's|local dir=/usr/share/smartroomos/hypr ver|local dir=$HOME/.config/hypr ver|' "$r/usr/local/bin/smartroomos-session"
must_fail "no ~/.cache" "creates ~/.cache" sed -i '/XDG_CACHE_HOME/d' "$r/usr/local/bin/smartroomos-session"
must_fail "a later drop-in turns the power key back on" "HandlePowerKey=ignore" \
  bash -c 'printf "[Login]\nHandlePowerKey=poweroff\n" >"$1/etc/systemd/logind.conf.d/zz-omarchy.conf"' _ "$r"
must_fail "the room's drop-in missing" "HandleRebootKey=ignore" rm "$r/etc/systemd/logind.conf.d/smartroomos-keys.conf"
must_fail "a later /run drop-in" "NAutoVTs=0" \
  bash -c 'mkdir -p "$1/run/systemd/logind.conf.d" && printf "[Login]\nNAutoVTs=6\n" >"$1/run/systemd/logind.conf.d/zz-run.conf"' _ "$r"
must_fail "Ctrl+Alt+Del burst reboots" "CtrlAltDelBurstAction=none" \
  rm "$r/etc/systemd/system.conf.d/smartroomos-keys.conf"
grep -q 'unbound variable\|bad array subscript' <<<"$out" && bad "no drop-ins at all must not break the check"
must_fail "ctrl-alt-del.target not masked" "ctrl-alt-del.target masked" rm "$r/etc/systemd/system/ctrl-alt-del.target"
must_fail "sshd passwords on" "sshd key-only" rm "$r/etc/ssh/sshd_config.d/99-smartroomos.conf"

# A same-name drop-in in /etc wins over /usr/lib; a key outside [Login] is not read.
good_tree "$r"
printf '[Login]\nHandlePowerKey=poweroff\n' >"$r/usr/lib/systemd/logind.conf.d/smartroomos-keys.conf"
bash "$check" "$r" >/dev/null 2>&1 || bad "an /etc drop-in must win a name over /usr/lib"
mkdir -p "$r/run/systemd/logind.conf.d"
printf '[Login]\nNAutoVTs=6\n' >"$r/run/systemd/logind.conf.d/smartroomos-keys.conf"
bash "$check" "$r" >/dev/null 2>&1 || bad "an /etc drop-in must win a name over /run"
rm -r "$r/run"
printf '[Other]\nHandlePowerKey=poweroff\n' >"$r/etc/systemd/logind.conf.d/zz-other.conf"
bash "$check" "$r" >/dev/null 2>&1 || bad "a key outside [Login] must not count"

# desk-check runs it on SmartRoom images and no longer looks in /etc/skel.
dc=$here/desk-check
grep -q 'room-lockdown-check' "$dc" || bad "desk-check must run room-lockdown-check"
grep -q 'etc/skel' "$dc" && bad "desk-check must not read the kiosk config from /etc/skel"
grep -Eq '^foot([[:space:]]|$)' "$here/room/packages" && bad "room/packages must not install foot"

(( fail == 0 )) && echo ok
exit $fail
