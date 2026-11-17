#!/bin/bash
# smartroom/mac/smartroom-boot-os on Linux against simulated macOS tools:
# diskutil (apfs list / info -plist), plutil (-extract raw|xml1), bless
# (--getBoot, --setBoot [--nextonly] --device|--mount, --user/--stdinpass,
# owner check), nvram alt-boot-volume, stat -f. Python only inside the fakes.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mock=$t/bin state=$t/state.json
mkdir -p "$mock"
MG=AAAAAAAA-0000-0000-0000-000000000001 FG=BBBBBBBB-0000-0000-0000-000000000002
cat >"$state" <<EOF
{"default": "disk3s1s1", "next": null, "owners": {"lucas": "pw one"},
 "volumes": [
  {"c": 0, "id": "disk3s1", "name": "Macintosh HD", "role": "System", "group": "$MG"},
  {"c": 0, "id": "disk3s5", "name": "Macintosh HD - Data", "role": "Data", "group": "$MG"},
  {"c": 0, "id": "disk3s2", "name": "Preboot", "role": "Preboot", "group": null},
  {"c": 1, "id": "disk5s1", "name": "SmartRoom Firmware", "role": "System", "group": "$FG"},
  {"c": 1, "id": "disk5s2", "name": "SmartRoom Firmware - Data", "role": "Data", "group": "$FG"}]}
EOF
cp "$state" "$t/initial.json"
cat >"$mock/diskutil" <<PY
#!/usr/bin/python3
import json, plistlib, sys
s = json.load(open("$state")); a = sys.argv[1:]
PY
cat >>"$mock/diskutil" <<'PY'
out = lambda v: sys.stdout.buffer.write(plistlib.dumps(v))
if a == ["apfs", "list", "-plist"]:
    cs = sorted({v["c"] for v in s["volumes"]})
    out({"Containers": [{"Volumes": [{"DeviceIdentifier": v["id"], "Name": v["name"], "Roles": [v["role"]]}
        for v in s["volumes"] if v["c"] == c]} for c in cs]})
elif a[:2] == ["info", "-plist"]:
    i = {"/": "disk3s1s1"}.get(a[2], a[2])
    v = next((v for v in s["volumes"] if v["id"] == i or i == v["id"] + "s1"), None)
    if not v: sys.exit(1)
    d = {"DeviceIdentifier": i, "VolumeName": v["name"]}
    if v["group"]: d["APFSVolumeGroupID"] = v["group"]
    out(d)
else: sys.exit(1)
PY
cat >"$mock/plutil" <<'PY'
#!/usr/bin/python3
import plistlib, sys
a = sys.argv[1:]
assert a[0] == "-extract" and a[3] == "-o", a
v = plistlib.loads(sys.stdin.buffer.read() if a[5] == "-" else open(a[5], "rb").read())
for k in a[1].split("."):
    try: v = v[int(k)] if isinstance(v, list) else v[k]
    except (KeyError, IndexError, ValueError): sys.exit(1)
if a[2] == "raw":
    if isinstance(v, (dict, list)): sys.exit(1)
    print(v)
PY
cat >"$mock/bless" <<PY
#!/usr/bin/python3
import json, sys
STATE, LOG = "$state", "$t/bless.log"
PY
cat >>"$mock/bless" <<'PY'
s = json.load(open(STATE)); a = sys.argv[1:]
open(LOG, "a").write(" ".join(a) + "\n")
if a == ["--getBoot"]: print("/dev/" + s["default"]); sys.exit(0)
assert "--setBoot" in a and "--stdinpass" in a, a
user = a[a.index("--user") + 1]; pw = sys.stdin.readline().rstrip("\n")
if s["owners"].get(user) != pw:
    print("Bootability failed Error Domain=BYErrorDomain Code=103 \"Owner authentication is required\""); sys.exit(3)
target = "disk3s1s1" if "--mount" in a else a[a.index("--device") + 1].removeprefix("/dev/")
if "--nextonly" in a: s["next"] = target
else: s["default"] = target
json.dump(s, open(STATE, "w"))
PY
cat >"$mock/nvram" <<PY
#!/usr/bin/python3
import json, sys
s = json.load(open("$state"))
if sys.argv[1:] != ["alt-boot-volume"] or not s["next"]: sys.exit(1)
g = next(v["group"] for v in s["volumes"] if v["id"] == s["next"] or s["next"] == v["id"] + "s1")
print("alt-boot-volume\tEF57347C-0000-AA11-AA11-00306543ECAC:00000000-0000-0000-0000-000000000000:" + g)
PY
printf '#!/bin/bash\necho Darwin\n' >"$mock/uname"
printf '#!/bin/bash\necho 0\n' >"$mock/id"
printf '#!/bin/bash\n[[ $1 == -f ]] && exec /usr/bin/stat -c "%%u %%a" "$3"; exec /usr/bin/stat "$@"\n' >"$mock/stat"
printf '#!/bin/bash\necho "$*" >>%q\n' "$t/shutdown.log" >"$mock/shutdown"
chmod +x "$mock"/*
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" "$here/../mac/smartroom-boot-os" >"$t/sbo"
chmod +x "$t/sbo"; grep -q "^PATH=$mock" "$t/sbo" || fail "could not point the script at the mocks"
get() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["default"], s["next"])' "$state"; }

out=$("$t/sbo" status) && grep -qx 'default: macOS' <<<"$out" && grep -qx 'next:    none' <<<"$out" || fail "status: $out"
"$t/sbo" firmware --once >"$t/out" 2>&1 && fail "switched without a credential"
grep -q "needs an owner" "$t/out" || fail "wrong refusal: $(cat "$t/out")"
printf 'wrong\n' | "$t/sbo" firmware --once --owner lucas >"$t/out" 2>&1 && fail "a wrong password switched"
grep -q "bless refused (Bootability failed" "$t/out" || fail "wrong refusal: $(cat "$t/out")"
[[ $(get) == "disk3s1s1 None" ]] || fail "a refusal changed the startup disk: $(get)"
echo "ok - status; refuses without a credential and with a wrong password, changing nothing"

out=$(printf 'pw one\n' | "$t/sbo" firmware --once --owner lucas) || fail "firmware --once: $out"
[[ $out == "next start: SmartRoom Firmware" && $(get) == "disk3s1s1 disk5s1" ]] || fail "firmware --once: $out / $(get)"
grep -q -- '--setBoot --device /dev/disk5s1 --nextonly --user lucas --stdinpass' "$t/bless.log" || fail "bless args: $(tail -1 "$t/bless.log")"
! grep -q 'pw one' "$t/bless.log" || fail "the password reached bless's arguments"
echo "ok - firmware --once: bless --nextonly on the stub's System volume, password only on stdin"

printf 'lucas\npw one\n' >"$t/cred"; chmod 644 "$t/cred"
"$t/sbo" firmware --credential-file "$t/cred" >"$t/out" 2>&1 && fail "a world-readable credential file was used"
grep -q "must be root's and 0600" "$t/out" || fail "wrong refusal: $(cat "$t/out")"
chmod 600 "$t/cred"
if [[ $(stat -c %u "$t/cred") == 0 ]]; then
  out=$("$t/sbo" firmware --credential-file "$t/cred" --reboot) || fail "firmware via credential file: $out"
else
  # not root here: let the mock stat report root's ownership
  printf '#!/bin/bash\n[[ $1 == -f ]] && { echo "0 $(/usr/bin/stat -c %%a "$3")"; exit; }; exec /usr/bin/stat "$@"\n' >"$mock/stat"
  out=$("$t/sbo" firmware --credential-file "$t/cred" --reboot) || fail "firmware via credential file: $out"
fi
[[ $out == "default: SmartRoom Firmware" && $(get) == disk5s1\ * && $(cat "$t/shutdown.log") == "-r now" ]] || fail "firmware default: $out / $(get)"
echo "ok - firmware as default from a root-only credential file, then restart"

out=$(printf 'pw one\n' | "$t/sbo" macos --owner lucas) || fail "macos: $out"
[[ $out == "default: macOS" && $(get) == disk3s1s1\ * ]] || fail "macos: $out / $(get)"
grep -q -- '^--mount / --setBoot --user lucas --stdinpass$' "$t/bless.log" || fail "macOS bless: $(tail -1 "$t/bless.log")"
echo "ok - macos as default: bless --mount / --setBoot, as Omarchy's Remove does"

python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["volumes"]=[v for v in s["volumes"] if v["c"]==0]; json.dump(s,open(sys.argv[1],"w"))' "$state"
printf 'pw one\n' | "$t/sbo" firmware --owner lucas >"$t/out" 2>&1 && fail "switched to a missing firmware volume"
grep -q "no SmartRoom Firmware volume" "$t/out" || fail "wrong refusal: $(cat "$t/out")"
echo "ok - refuses when there is no firmware volume"
for w in python3 python git clang xcrun strings jq perl; do
  ! grep -v '^ *#' "$here/../mac/smartroom-boot-os" | grep -Eq "(^|[;&|( ])$w( |$)" || fail "the script calls $w"
done
bash --posix -n "$here/../mac/smartroom-boot-os" || fail "not POSIX-mode parseable"
echo "ok - uses no python3/git/clang/xcrun/strings/jq/perl"
