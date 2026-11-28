#!/bin/bash
# smartroom/hardware/studio-netsim: the cold-boot check B helper, against fake systemctl,
# systemd-run, nmcli, ip and logger. Nothing here touches a real machine.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
hw=$here/../hardware
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
mkdir -p "$t/bin" "$t/run" "$t/state"
for c in systemd-run nmcli logger systemctl; do
  printf '#!/bin/bash\necho "%s $*" >>"%s/calls"\n' "$c" "$t" >"$t/bin/$c"
done
printf '#!/bin/bash\nexit "${FAKE_ROUTE_RC:-0}"\n' >"$t/bin/ip"
printf '#!/bin/bash\n[[ ${FAKE_ROUTE_RC:-0} == 0 ]] && echo "default via 192.168.1.1 dev end0"; exit 0\n' >"$t/bin/ip"
chmod +x "$t"/bin/*
export PATH="$t/bin:$PATH"
env_netsim=(NETSIM_RUN_DIR="$t/run" NETSIM_STATE_DIR="$t/state" NETSIM_UNIT="$t/studio-netsim.service")
ns() { env "${env_netsim[@]}" bash "$hw/studio-netsim" "$@"; }

for f in "$hw"/studio-*; do bash -n "$f" && ok "syntax: ${f##*/}" || bad "syntax: ${f##*/}"; done

ns arm 120
[[ $(cat "$t/state/netsim-armed") == 120 ]] && ok "arm writes the duration for the next boot only" || bad "arm"
ns start
[[ ! -e $t/state/netsim-armed ]] && ok "start consumes the arm file (one boot only)" || bad "start must consume the arm file"
grep -qx 'unmanaged-devices=interface-name:end0' "$t/run/99-studio-netsim.conf" && ok "start keeps only end0 away from NetworkManager, in /run" || bad "start's drop-in"
grep -q -- '--on-active=120s .*studio-netsim-restore .* stop$' "$t/calls" && grep -q -- '--on-active=240s .*studio-netsim-restore2 .* stop-hard$' "$t/calls" &&
  ok "start schedules the hand-back after N s and the hard restore 120 s later" || bad "start's timers: $(cat "$t/calls")"
ns stop
[[ ! -e $t/run/99-studio-netsim.conf ]] && grep -q 'nmcli general reload conf' "$t/calls" && ok "stop removes the drop-in and reloads NetworkManager" || bad "stop"
: >"$t/calls"; printf 'x' >"$t/run/99-studio-netsim.conf"
FAKE_ROUTE_RC=0 ns stop-hard
! grep -q 'systemctl restart NetworkManager' "$t/calls" && ok "stop-hard does nothing when the default route is back" || bad "stop-hard restarted with a route"
FAKE_ROUTE_RC=1 ns stop-hard
grep -q 'systemctl restart NetworkManager' "$t/calls" && ok "stop-hard restarts NetworkManager when there is still no route" || bad "stop-hard without a route"
ns install
grep -q "ConditionPathExists=$t/state/netsim-armed" "$t/studio-netsim.service" && [[ -x $t/state/studio-netsim ]] && ok "install writes a unit that runs only when armed" || bad "install"
! grep -qE 'nmcli (con|connection) (modify|delete|add)|nmcli device set|/etc/NetworkManager' "$hw/studio-netsim" && ok "no NetworkManager profile or config on disk is touched" || bad "netsim touches NetworkManager's files"
ns remove
[[ ! -e $t/studio-netsim.service ]] && ok "remove deletes the unit" || bad "remove"

exit $fail
