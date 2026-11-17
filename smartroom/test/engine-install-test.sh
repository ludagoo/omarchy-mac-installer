#!/bin/bash
# Exercises smartroom/mac/engine-install on Linux against a simulated Mac:
#   - fake macOS tools (diskutil/plutil/bless/scutil/sysadminctl/codesign/...)
#     over one JSON disk state, emitting real-looking plists;
#   - a fake engine archive whose main.py runs the Engine's REAL journal
#     (omarchy_contract), planner (omarchy_planner.emit_plan), admission
#     (omarchy_execution.admit_execution) and stage-1 sequencing
#     (omarchy_stage1) from Engine/overlay/src, with an adapter that changes
#     the simulated disk the way the engine's stages do (stub, ESP, Boot, Root,
#     bless --setBoot).
# So the driver's request/identity files, digests and binding are checked by
# the engine's own code. What it cannot prove is listed in
# smartroom/docs/engine-headless.md ("What is unverified").
# Needs bash, python3, tar, sha256sum. No root, no network.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
src=$here/../..
t=$(mktemp -d); [[ -n ${KEEP-} ]] && echo "keeping $t" || trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
mock=$t/bin state=$t/disk.json
mkdir -p "$mock" "$t/repo/Engine" "$t/repo/Packaging" "$t/repo/smartroom/mac" "$t/vol" "$t/preboot" "$t/img"
PW='correct horse'

# ---- the simulated Mac: disk0 = ISC, macOS, free space, Recovery ----------
GROUP=6D7E1A22-1B3C-4D5E-8F90-0A1B2C3D4E5F
python3 - "$state" "$GROUP" <<'PY'
import json, sys
G = 1 << 30
state = {
  "disk": "disk0", "disk_size": 994662584320, "default_boot": "disk3s1", "bless_password": "correct horse",
  "engine_forgets_bless": False,
  "parts": [
    {"id": "disk0s1", "uuid": "11111111-0000-0000-0000-000000000001", "content": "Apple_APFS_ISC", "offset": 24576, "size": 524288000},
    {"id": "disk0s2", "uuid": "11111111-0000-0000-0000-000000000002", "content": "Apple_APFS", "offset": 524312576, "size": 500 * G},
    {"id": "disk0s3", "uuid": "11111111-0000-0000-0000-000000000003", "content": "Apple_APFS_Recovery", "offset": 989297614848, "size": 5368709120},
  ],
  "containers": [
    {"ref": "disk3", "uuid": "22222222-0000-0000-0000-000000000003", "store": "disk0s2", "volumes": [
      {"id": "disk3s1", "name": "Macintosh HD", "roles": ["System"], "group": sys.argv[2]},
      {"id": "disk3s5", "name": "Macintosh HD - Data", "roles": ["Data"], "group": sys.argv[2]},
      {"id": "disk3s2", "name": "Preboot", "roles": ["Preboot"], "group": None},
      {"id": "disk3s3", "name": "Recovery", "roles": ["Recovery"], "group": None}]},
  ],
  "mounted": {},
}
json.dump(state, open(sys.argv[1], "w"), indent=1)
PY
cp "$state" "$t/disk.initial.json"

# diskutil: info / list / apfs list / mount / unmount over the JSON state
cat >"$mock/diskutil" <<PY
#!/usr/bin/python3
import json, os, plistlib, sys
STATE, VOL = "$state", "$t/vol"
PY
cat >>"$mock/diskutil" <<'PY'
s = json.load(open(STATE)); a = sys.argv[1:]
out = lambda v: sys.stdout.buffer.write(plistlib.dumps(v))
def vol(i):
    for c in s["containers"]:
        for v in c["volumes"]:
            if v["id"] == i: return c, v
    return None, None
def info(i):
    if i == "/": i = "disk3s1"
    if i == s["disk"]:
        return {"DeviceIdentifier": i, "WholeDisk": True, "Content": "GUID_partition_scheme", "Size": s["disk_size"]}
    for p in s["parts"]:
        if p["id"] == i:
            d = {"DeviceIdentifier": i, "ParentWholeDisk": s["disk"], "DiskUUID": p["uuid"], "Content": p["content"],
                 "PartitionMapPartitionOffset": p["offset"], "Size": p["size"], "VolumeName": p.get("name", "")}
            mp = s["mounted"].get(i)
            if mp: d["MountPoint"] = mp
            return d
    c, v = vol(i)
    if v:
        d = {"DeviceIdentifier": i, "VolumeName": v["name"], "APFSContainerReference": c["ref"],
             "APFSPhysicalStores": [{"APFSPhysicalStore": c["store"]}]}
        if v["group"]: d["APFSVolumeGroupID"] = v["group"]
        return d
    sys.exit(1)
if a[:2] == ["info", "-plist"]: out(info(a[2]))
elif a[:2] == ["list", "-plist"]:
    out({"AllDisksAndPartitions": [{"DeviceIdentifier": s["disk"], "Content": "GUID_partition_scheme",
         "Partitions": [{"DeviceIdentifier": p["id"], "Content": p["content"]} for p in sorted(s["parts"], key=lambda p: p["offset"])]}]})
elif a[:3] == ["apfs", "list", "-plist"]:
    out({"Containers": [{"ContainerReference": c["ref"], "APFSContainerUUID": c["uuid"],
         "PhysicalStores": [{"DeviceIdentifier": c["store"]}],
         "Volumes": [{"DeviceIdentifier": v["id"], "Name": v["name"], "Roles": v["roles"]} for v in c["volumes"]]}
        for c in s["containers"]]})
elif a[0] == "mount":
    i = a[-1]; mp = a[a.index("-mountPoint") + 1] if "-mountPoint" in a else os.path.join(VOL, i)
    if os.path.isdir(os.path.join(VOL, i)) and mp != os.path.join(VOL, i):
        os.rmdir(mp); os.symlink(os.path.join(VOL, i), mp)
    s["mounted"][i] = mp; json.dump(s, open(STATE, "w"))
elif a[0] == "unmount":
    s["mounted"].pop(a[1], None); json.dump(s, open(STATE, "w"))
else:
    sys.stderr.write(f"diskutil mock: {a}\n"); sys.exit(1)
PY
# plutil -extract KEY raw -o - FILE|-  (JSON or XML input; strings and numbers)
cat >"$mock/plutil" <<'PY'
#!/usr/bin/python3
import json, plistlib, sys
a = sys.argv[1:]
assert a[0] == "-extract" and a[2] == "raw" and a[3:5] == ["-o", "-"], a
data = sys.stdin.buffer.read() if a[5] == "-" else open(a[5], "rb").read()
v = json.loads(data) if data.lstrip()[:1] in (b"{", b"[") else plistlib.loads(data)
for k in a[1].split("."):
    try: v = v[int(k)] if isinstance(v, list) else v[k]
    except (KeyError, IndexError, ValueError): sys.exit(1)
if isinstance(v, (dict, list)): sys.exit(1)
print(str(v).lower() if isinstance(v, bool) else v)
PY
# bless --getBoot | --setBoot --device /dev/X --user U --stdinpass
cat >"$mock/bless" <<PY
#!/usr/bin/python3
import json, sys
STATE, LOG = "$state", "$t/bless.log"
PY
cat >>"$mock/bless" <<'PY'
s = json.load(open(STATE)); a = sys.argv[1:]
open(LOG, "a").write(" ".join(a) + "\n")
if a == ["--getBoot"]: print("/dev/" + s["default_boot"]); sys.exit(0)
if "--setBoot" in a and "--stdinpass" in a:
    if sys.stdin.readline().rstrip("\n") != s["bless_password"]:
        sys.stderr.write("bless: authentication failed\n"); sys.exit(3)
    s["default_boot"] = a[a.index("--device") + 1].removeprefix("/dev/"); json.dump(s, open(STATE, "w")); sys.exit(0)
sys.exit(2)
PY
console=${CONSOLE_USER-lucas}
cat >"$mock/scutil" <<'SH'
#!/bin/bash
cat >/dev/null
[[ -n $CONSOLE_USER ]] || { echo "<dictionary> {"; echo "}"; exit 0; }
printf '<dictionary> {\n  SessionInfo : <array> {\n    0 : <dictionary> {\n      kCGSSessionUserNameKey : %s\n    }\n  }\n}\n' "$CONSOLE_USER"
SH
cat >"$mock/sysadminctl" <<'SH'
#!/bin/bash
[[ ${NO_TOKEN-} == "$2" ]] && { echo "Secure token is DISABLED for user $2" >&2; exit 0; }
echo "$(date) sysadminctl[1:2] Secure token is ENABLED for user $2" >&2
SH
# the decoder's identifier, from identity.conf (the only place it is set)
rid=$(sed -n 's/^INSTALLER_RESTORE_IMAGE_IDENTIFIER="\(.*\)"$/\1/p' "$src/Packaging/identity.conf")
[[ -n $rid ]] || fail "no INSTALLER_RESTORE_IMAGE_IDENTIFIER in identity.conf"
cat >"$mock/codesign" <<SH
#!/bin/bash
rid=$rid
SH
cat >>"$mock/codesign" <<'SH'
case $1 in
  -d) printf 'Executable=%s\nIdentifier=%s\nFormat=Mach-O thin (arm64)\nCodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+0 location=embedded\nSignature=adhoc\nCDHash=0123456789abcdef0123456789abcdef01234567\nTeamIdentifier=not set\n' "${@: -1}" "$rid" >&2 ;;
  --verify) [[ $3 == "-R=identifier \"$rid\" and cdhash H\"0123456789abcdef0123456789abcdef01234567\"" ]] ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/bash\n[[ $1 == -s ]] && echo Darwin && exit 0; [[ $1 == -m ]] && echo arm64 && exit 0; exec /usr/bin/uname "$@"\n' >"$mock/uname"
printf '#!/bin/bash\nshift 2; exec sha256sum "$@"\n' >"$mock/shasum"
printf '#!/bin/bash\n[[ $1 == -f && $2 == %%z ]] && exec /usr/bin/stat -c %%s "$3"; exec /usr/bin/stat "$@"\n' >"$mock/stat"
printf '#!/bin/bash\nexit 0\n' >"$mock/caffeinate"
printf '#!/bin/bash\nexec /usr/bin/uuidgen -r\n' >"$mock/uuidgen"
chmod +x "$mock"/*

# ---- the fake engine archive (real Engine modules + a main.py) ------------
eng=$t/engine-src
mkdir -p "$eng/Frameworks/Python.framework/Versions/3.13/bin" "$eng/bin"
ln -s 3.13 "$eng/Frameworks/Python.framework/Versions/Current"
printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' >"$eng/Frameworks/Python.framework/Versions/3.13/bin/python3.13"
chmod +x "$eng/Frameworks/Python.framework/Versions/3.13/bin/python3.13"
for m in omarchy_contract omarchy_execution omarchy_planner omarchy_stage1 omarchy_image; do
  cp "$src/Engine/overlay/src/$m.py" "$eng/"
done
{ printf 'STATE = "%s"\nVOL = "%s"\nRID = "%s"\n' "$state" "$t/vol" "$rid"; cat <<'PY'
import json, os, sys, types
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The planner imports Asahi's osinstall/util for inventory collection only;
# emit_plan (what plan mode runs) needs util.align_down alone.
sys.modules["osinstall"] = types.ModuleType("osinstall")
util = types.ModuleType("util"); util.align_down = lambda v, a: v - v % a; sys.modules["util"] = util
import omarchy_contract, omarchy_execution, omarchy_planner, omarchy_stage1

G, MIB, ALIGN = 1 << 30, 1 << 20, 4096
STUB, ESP, BOOT, ROOT_MIN = 2499805184, 524288000, 2147483648, 34359738368
FLOOR = STUB + ESP + BOOT + ROOT_MIN
env = os.environ
mode = env["OMARCHY_ENGINE_MODE"]
assert os.getcwd() == os.path.dirname(os.path.abspath(__file__)), "cwd is not the bundle"
assert env["PATH"].startswith(os.getcwd() + "/bin:"), env["PATH"]
assert env["LC_ALL"] == "C" and env["HOME"] == env["TMPDIR"]
s = json.load(open(STATE))
def save(): json.dump(s, open(STATE, "w"), indent=1)

def inventory():
    parts = sorted(s["parts"], key=lambda p: p["offset"])
    macos = next(p for p in parts if p["id"] == "disk0s2")
    cands = []
    for a, b in zip(parts, parts[1:]):
        gap = b["offset"] - (a["offset"] + a["size"])
        start = (a["offset"] + a["size"] + ALIGN - 1) // ALIGN * ALIGN
        length = (b["offset"] - start) // ALIGN * ALIGN
        if gap > 0 and length >= FLOOR:
            cands.append({"kind": "free", "source_identifier": "disk0", "offset_bytes": start, "length_bytes": length,
                          "minimum_install_bytes": FLOOR, "minimum_container_bytes": 0,
                          "recommended_install_bytes": 2 * FLOOR, "recommended_container_bytes": 0})
    cands.append({"kind": "resize", "source_identifier": macos["id"], "offset_bytes": macos["offset"],
                  "length_bytes": macos["size"], "minimum_install_bytes": FLOOR,
                  "minimum_container_bytes": 100 * G, "recommended_install_bytes": 2 * FLOOR,
                  "recommended_container_bytes": 120 * G})
    return cands

journal = omarchy_contract.Journal(env["OMARCHY_ENGINE_JOURNAL"])
journal.inspection(omarchy_contract.normalize_device_identifier("J475cAP"), "supported")
if journal.inventory_payload is None or mode in ("inspect", "plan"):
    journal.inventory("disk0", inventory())
if mode == "inspect":
    sys.exit(0)
if mode == "plan":
    omarchy_planner.emit_plan(journal, env["OMARCHY_ENGINE_REQUEST"], env["OMARCHY_ENGINE_IDENTITY"],
                              journal.inspection_payload["device_identifier"], ALIGN)
    sys.exit(0)

# install / retry-recovery-authorization: the app's environment, then admission
meta = json.load(open(env["OMARCHY_ENGINE_METADATA"]))["os_list"][0]
assert os.path.basename(env["OMARCHY_ENGINE_PAYLOAD"]) == meta["package"]
assert os.stat(env["OMARCHY_RESTORE_IMAGE"]).st_mode & 0o777 == 0o500
assert env["OMARCHY_RESTORE_IMAGE_REQUIREMENT"].startswith(f'identifier "{RID}"')
assert env["DISTRO"] == "Omarchy" and env["OMARCHY_INSTALLER_NAME"]
for leak in ("OMARCHY_RECOVERY_APP", "OMARCHY_RECOVERY_MANIFEST", "OMARCHY_RECOVERY_REQUIREMENT"):
    assert leak not in env, leak
owner = env["OMARCHY_MACHINE_OWNER"]
password = sys.stdin.readline().rstrip("\n")
assert sys.stdin.read() == "", "more than one line on stdin"
admitted = journal.inventory_payload if (journal.events or journal.checkpoints) else omarchy_contract.normalized_inventory("disk0", inventory())
plan = omarchy_execution.admit_execution(
    request_path=env["OMARCHY_ENGINE_REQUEST"], identity_path=env["OMARCHY_ENGINE_IDENTITY"],
    live_inventory=admitted, expected_binding_digest=env["OMARCHY_ENGINE_BINDING_DIGEST"],
    expected_plan_digest=env["OMARCHY_ENGINE_PLAN_DIGEST"])
digest = journal.plan(device_identifier=plan.device_identifier, layout_digest=plan.layout_digest,
    candidate_kind=plan.candidate_kind, source_identifier=plan.source_identifier,
    requested_length_bytes=plan.length_bytes, engine_version=plan.engine_version,
    engine_digest=plan.engine_digest, metadata_digest=plan.metadata_digest,
    payload_digest=plan.payload_digest, required_human_steps=list(plan.required_human_steps))
assert digest == plan.plan_digest

class Adapter:
    """What the Asahi stages do to the disk, on the simulated one."""
    def prepare_target(self, plan):
        if plan.candidate_kind == "resize":
            macos = next(p for p in s["parts"] if p["id"] == plan.source_identifier)
            macos["size"] = plan.offset_bytes - macos["offset"]
            save()
        return b"target"
    def install_stub_and_esp(self, plan):
        o = plan.offset_bytes
        n = max(int(p["id"].removeprefix("disk0s")) for p in s["parts"])
        name = meta["default_os_name"]
        def add(content, off, size, pname=""):
            nonlocal n
            n += 1
            s["parts"].append({"id": f"disk0s{n}", "uuid": f"33333333-0000-0000-0000-{n:012d}", "content": content,
                               "offset": off, "size": size, "name": pname})
            return f"disk0s{n}"
        stub = add("Apple_APFS", o, STUB)
        s["containers"].append({"ref": "disk5", "uuid": "22222222-0000-0000-0000-000000000005", "store": stub, "volumes": [
            {"id": "disk5s1", "name": name, "roles": ["System"], "group": "7A7A7A7A-0000-0000-0000-00000000005A"},
            {"id": "disk5s2", "name": name + " - Data", "roles": ["Data"], "group": "7A7A7A7A-0000-0000-0000-00000000005A"},
            {"id": "disk5s3", "name": "Preboot", "roles": ["Preboot"], "group": None},
            {"id": "disk5s4", "name": "Recovery", "roles": ["Recovery"], "group": None}]})
        label = ("EFI - " + name)[:11].upper()
        esp = add("EFI", o + STUB, ESP, label)
        add("Linux Filesystem", o + STUB + ESP, BOOT)
        add("Linux Filesystem", o + STUB + ESP + BOOT, plan.length_bytes - STUB - ESP - BOOT)
        d = os.path.join(VOL, esp)
        os.makedirs(os.path.join(d, "m1n1")); os.makedirs(os.path.join(d, "asahi"))
        open(os.path.join(d, "m1n1", "boot.bin"), "w").write("m1n1")
        open(os.path.join(d, "asahi", "stub_info.json"), "w").write('{"vgid": "7A7A7A7A-0000-0000-0000-00000000005A"}')
        save()
        return b"stub-and-esp"
    def validate_installed_checkpoint(self, plan, *evidence):
        assert any(p["content"] == "EFI" for p in s["parts"])
    def prepare_recovery_handoff(self, plan):
        # omarchy_asahi: bless --setBoot --device /dev/<stub System> --user OWNER --stdinpass
        if password != s["bless_password"]:
            raise RuntimeError("Recovery handoff authorization failed")
        if not s.get("engine_forgets_bless"):
            s["default_boot"] = "disk5s1"; save()
        return b"handoff"

if mode == "retry-recovery-authorization":
    print(omarchy_stage1.retry_recovery_authorization(plan, journal, Adapter()))
else:
    print(omarchy_stage1.run_stage1(plan, journal, Adapter()))
PY
} >"$eng/main.py"
version=v0.9.2-omarchy.20261106.0f73bea79639
archive=$t/installer-$version.tar.gz
tar -czf "$archive" -C "$eng" .
asize=$(stat -c %s "$archive") asha=$(sha256sum "$archive" | cut -d' ' -f1)
python3 - "$src/Engine/source-lock.json" "$t/repo/Engine/source-lock.json" "${archive##*/}" "$asize" "$asha" "$version" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
lock["validation_artifact"].update(filename=sys.argv[3], size_bytes=int(sys.argv[4]), sha256=sys.argv[5])
lock["downstream_overlay"]["version"] = sys.argv[6]
json.dump(lock, open(sys.argv[2], "w"))
PY
cp "$src/Packaging/identity.conf" "$t/repo/Packaging/"
# the driver, pointed at the mocks (PATH, Preboot, the absolute diskutil in its Python)
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" \
  -e "s|/System/Volumes/Preboot/|$t/preboot/|" -e "s|\"/usr/sbin/diskutil\"|\"$mock/diskutil\"|g" \
  -e 's#^(( EUID == 0 )) || die "run as root (sudo)"$#:#' \
  -e "s|env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C|env -i PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C|" \
  "$src/smartroom/mac/engine-install" >"$t/repo/smartroom/mac/engine-install"
chmod +x "$t/repo/smartroom/mac/engine-install"
grep -q "^PATH=$mock:" "$t/repo/smartroom/mac/engine-install" || fail "could not point the driver at the mocks"
grep -q '^(( EUID == 0 )) || die "run as root (sudo)"$' "$src/smartroom/mac/engine-install" || fail "the root check moved"
mkdir -p "$t/preboot/$GROUP/var/db"
python3 -c 'import plistlib,sys; open(sys.argv[1],"wb").write(plistlib.dumps({"lucas": {}, "admin2": {}}))' \
  "$t/preboot/$GROUP/var/db/AdminUserRecoveryInfo.plist"

# ---- the image (as the builder writes it) and a firstboot.env -------------
pkgname=smartroom-firmware-2026.11.17-aarch64-apple-silicon-mac-stable-os-package.zip
echo payload >"$t/img/$pkgname"
psha=$(sha256sum "$t/img/$pkgname" | cut -d' ' -f1)
sed "s|\"package\": \".*\"|\"package\": \"$pkgname\"|" "$HOME/smartroom-omarchy-fork/release/smartroom/installer_data.json" >"$t/img/installer_data.json" 2>/dev/null ||
  python3 - "$t/img/installer_data.json" "$pkgname" <<'PY'
import json, sys
json.dump({"os_list": [{"name": "SmartRoom Firmware", "default_os_name": "SmartRoom Firmware",
  "omarchy_target": "apple-silicon-full-os", "boot_object": "m1n1.bin", "next_object": "m1n1/boot.bin",
  "package": sys.argv[2], "recovery_gui": "omarchy-native-v1", "partitions": []}]}, open(sys.argv[1], "w"))
PY
grep -q "\"$pkgname\"" "$t/img/installer_data.json" || fail "test installer_data.json"
printf 'SMARTROOMOS_SERVER_URL=https://rooms.example.invalid\nSMARTROOMOS_AGENT_INSTALL_SHA256=%064d\n' 0 >"$t/fb.env"
touch "$t/restore-image"; chmod 755 "$t/restore-image"

ei=$t/repo/smartroom/mac/engine-install
st=$t/state
common=(--payload "$t/img/$pkgname" --sha256 "$psha" --installer-data "$t/img/installer_data.json"
  --owner lucas --restore-image "$t/restore-image" --engine "$archive" --state "$st")
run() { CONSOLE_USER=$console "$ei" "$@" >"$t/out" 2>&1; }
pw() { printf '%s\n' "$1"; }
disk() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(*[p["id"]+":"+p["content"]+":"+str(p["offset"])+":"+str(p["size"]) for p in s["parts"]], s["default_boot"])' "$state"; }
initial=$(disk)

# refusals before anything runs
pw "$PW" | run "${common[@]}" && fail "a SmartRoom image without firstboot.env was accepted"
grep -q "needs --firstboot-env" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
printf 'SMARTROOMOS_SERVER_URL=https://x.invalid\n' >"$t/bad.env"
pw "$PW" | run "${common[@]}" --firstboot-env "$t/bad.env" && fail "a firstboot.env without the install.sh sha256 was accepted"
grep -q "SMARTROOMOS_AGENT_INSTALL_SHA256" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
pw "$PW" | CONSOLE_USER="" "$ei" "${common[@]}" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 && fail "ran with no console user"
grep -q "no user is logged in at this Mac's console" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
pw "$PW" | run "${common[@]/lucas/nobody}" --firstboot-env "$t/fb.env" && fail "a non-owner was accepted"
grep -q "nobody is not a macOS machine owner" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
pw "$PW" | NO_TOKEN=lucas run "${common[@]}" --firstboot-env "$t/fb.env" && fail "an owner without a secure token was accepted"
[[ $(disk) == "$initial" ]] || fail "a refusal changed the disk"
echo "ok - refuses: no firstboot.env, a bad one, no console user, a non-owner, no secure token"

# dry run: inspect + plan by the real planner, nothing on disk
pw "$PW" | run "${common[@]}" --firstboot-env "$t/fb.env" || fail "dry run: $(tail -5 "$t/out")"
grep -q "checked; nothing on disk changed" "$t/out" && grep -q "chosen: free disk0" "$t/out" || fail "dry run output: $(tail -5 "$t/out")"
[[ $(disk) == "$initial" ]] || fail "the dry run changed the disk"
! ls "$st"/run-*/package/*.zip >/dev/null 2>&1 || fail "the dry run left its payload copy"
echo "ok - dry run: the engine's own planner accepts the plan, nothing changes"

# wrong password: stops at the Recovery handoff; a fresh install is then refused; --retry finishes
sleep 1
pw "wrong" | run "${common[@]}" --firstboot-env "$t/fb.env" --yes && fail "a wrong password passed"
grep -q -- "--retry" "$t/out" || fail "no retry hint: $(tail -5 "$t/out")"
run1=$(ls -d "$st"/run-* | tail -n 1)
sleep 1
pw "$PW" | run "${common[@]}" --firstboot-env "$t/fb.env" --yes && fail "a second install ran beside an unfinished one"
grep -q "an earlier install is unfinished" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
pw "$PW" | run --retry "$run1" --state "$st" --yes || fail "retry: $(tail -8 "$t/out")"
grep -q "journal .*: completion awaiting_recovery" "$t/out" || fail "retry journal: $(tail -5 "$t/out")"
echo "ok - a wrong password stops at Recovery authorization; --retry completes it; no second install meanwhile"

esp=$(python3 -c 'import json,sys; print(next(p["id"] for p in json.load(open(sys.argv[1]))["parts"] if p["content"]=="EFI"))' "$state")
v=$t/vol/$esp
[[ $(cat "$v/omarchy/install.conf") == $'format=1\nencrypt=0\nlane=stable' ]] || fail "install.conf: $(cat "$v/omarchy/install.conf")"
cmp -s "$v/asahi/extras/firstboot.env" "$t/fb.env" || fail "firstboot.env not on the ESP"
grep -q 'startup disk: SmartRoom Firmware (disk5s1' "$t/out" || fail "default boot not confirmed: $(tail -20 "$t/out")"
grep -q 'Cmd+F5' "$t/out" && grep -q 'Control+Option+Space' "$t/out" || fail "no VoiceOver steps"
! grep -rqF "$PW" "$st" || fail "the password is in the state directory"
echo "ok - ESP has install.conf encrypt=0 and firstboot.env; the stub is the default startup disk; 1TR steps printed"

# a fresh Mac where the engine's bless did not stick: the driver re-blesses
cp "$t/disk.initial.json" "$state"; rm -rf "$t/vol"/* "$st"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["engine_forgets_bless"]=True; json.dump(s,open(sys.argv[1],"w"))' "$state"
pw "$PW" | run "${common[@]}" --firstboot-env "$t/fb.env" --full-readback --yes || fail "install: $(tail -8 "$t/out")"
grep -q "the startup disk is not SmartRoom Firmware" "$t/out" || fail "no re-bless: $(tail -8 "$t/out")"
[[ $(disk) == *" disk5s1" ]] || fail "not the default after re-bless: $(disk)"
grep -q -- "--setBoot --device /dev/disk5s1 --user lucas --stdinpass" "$t/bless.log" || fail "bless log: $(cat "$t/bless.log")"
echo "ok - re-blesses the stub when the engine's bless did not take"

# no free space: shrink macOS (resize candidate) by --source/--size
python3 - "$state" "$t/disk.initial.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[2])); m = next(p for p in s["parts"] if p["id"] == "disk0s2")
r = next(p for p in s["parts"] if p["id"] == "disk0s3"); m["size"] = r["offset"] - m["offset"]
json.dump(s, open(sys.argv[1], "w"))
PY
rm -rf "$t/vol"/* "$st"
pw "$PW" | run "${common[@]}" --firstboot-env "$t/fb.env" --yes && fail "installed with no free space and no --source"
grep -q "no free extent can hold the image" "$t/out" || fail "wrong refusal: $(tail -3 "$t/out")"
rm -rf "$st"
pw "$PW" | run "${common[@]}" --firstboot-env "$t/fb.env" --source disk0s2 --size 80G --yes || fail "resize install: $(tail -8 "$t/out")"
grep -q "chosen: resize disk0s2, 85899345920 bytes" "$t/out" || fail "resize choice: $(grep chosen "$t/out")"
python3 - "$state" <<'PY' || fail "resize layout"
import json, sys
s = json.load(open(sys.argv[1])); p = {x["id"]: x for x in s["parts"]}
rec = p["disk0s3"]; mac = p["disk0s2"]
assert mac["offset"] + mac["size"] + 80 * (1 << 30) == rec["offset"], (mac, rec)
assert s["default_boot"] == "disk5s1"
PY
echo "ok - shrinks macOS by exactly --size for the install (resize candidate)"
