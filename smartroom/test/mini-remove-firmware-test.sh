#!/bin/bash
# Mocked Linux test for smartroom/mac/remove-firmware on Intel T2 Macmini8,1.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/../mac/remove-firmware
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; [[ ! -f $t/out ]] || sed 's/^/    /' "$t/out" >&2; exit 1; }

mock=$t/bin
mkdir -p "$mock" "$t/root" "$t/esp_mnt"
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" \
  -e "s|/var/root/|$t/root/|g" "$script" >"$t/rf"
chmod +x "$t/rf"

export FAKE_STATE=$t/state.json FAKE_LOG=$t/calls.log FAKE_MNT=$t/esp_mnt
cat >"$t/fakemac.py" <<'PY'
import json, os, plistlib, sys

STATE, LOG, MNT = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"], os.environ["FAKE_MNT"]

def load(): return json.load(open(STATE))
def save(s): json.dump(s, open(STATE, "w"), indent=1)
def log(m): open(LOG, "a").write(m + "\n")
def emit(o): sys.stdout.buffer.write(plistlib.dumps(o, fmt=plistlib.FMT_XML))
def parts(s):
    ps = sorted(s["parts"], key=lambda p: p["offset"])
    for i, p in enumerate(ps):
        p["id"] = f"{s['disk']}s{i + 1}"
    return ps

op = sys.argv[1]; a = sys.argv[2:]; s = load()
if op == "diskutil":
    if a == ["info", "-plist", "/"]:
        st = next(p for p in parts(s) if p["uuid"] == s["mac_store"])
        emit({"DeviceIdentifier": "disk1s1", "APFSContainerReference": s["mac_ref"],
              "APFSPhysicalStores": [{"APFSPhysicalStore": st["id"]}],
              "APFSVolumeGroupID": "MACGRP", "Internal": True})
    elif a[:2] == ["info", "-plist"]:
        ident = a[2]
        if ident == s["disk"]:
            emit({"DeviceIdentifier": s["disk"], "Internal": True, "WholeDisk": True,
                  "Content": "GUID_partition_scheme", "Size": s["disk_size"], "DeviceBlockSize": 4096})
        elif ident == "disk1s1":
            st = next(p for p in parts(s) if p["uuid"] == s["mac_store"])
            emit({"DeviceIdentifier": "disk1s1", "APFSPhysicalStores": [{"APFSPhysicalStore": st["id"]}]})
        else:
            p = next((x for x in parts(s) if x["id"] == ident), None)
            if not p: sys.exit(1)
            emit({"DeviceIdentifier": p["id"], "DiskUUID": p["uuid"], "Content": p["content"],
                  "PartitionMapPartitionOffset": p["offset"], "Size": p["size"], "TotalSize": p["size"],
                  "ParentWholeDisk": s["disk"], "MountPoint": s["mounts"].get(p["id"], ""),
                  "VolumeName": p.get("name", "")})
    elif a[:2] == ["list", "-plist"]:
        ps = parts(s)
        emit({"AllDisksAndPartitions": [{"DeviceIdentifier": s["disk"], "Content": "GUID_partition_scheme",
              "Partitions": [{"DeviceIdentifier": p["id"]} for p in ps]}]})
    elif a == ["apfs", "list", "-plist"]:
        st = next(p for p in parts(s) if p["uuid"] == s["mac_store"])
        emit({"Containers": [{"ContainerReference": s["mac_ref"], "APFSContainerUUID": "APFS-1",
              "PhysicalStores": [{"DeviceIdentifier": st["id"]}], "Volumes": []}]})
    elif a[:2] == ["apfs", "resizeContainer"] and a[3:] == ["limits", "-plist"]:
        p = next(x for x in parts(s) if x["id"] == a[2])
        emit({"MinimumSize": s["mac_min"], "CurrentSize": p["size"], "MaximumSize": s["disk_size"] - p["offset"] - 1048576})
    elif a[:2] == ["apfs", "resizeContainer"] and a[3] == "0":
        p = next(x for x in parts(s) if x["id"] == a[2])
        p["size"] = s["disk_size"] - p["offset"] - 1048576
        save(s); log(f"MUTATE resizeContainer {a[2]} 0")
    elif a[:3] == ["eraseVolume", "free", "none"]:
        p = next(x for x in parts(s) if x["id"] == a[3])
        assert p["uuid"] not in (s["apple_esp"], s["mac_store"]), f"refuse protected {p}"
        s["parts"] = [x for x in s["parts"] if x["uuid"] != p["uuid"]]
        save(s); log(f"MUTATE eraseVolume {a[3]} {p['uuid']}")
    elif a[0] == "mount":
        mp = a[a.index("-mountPoint") + 1] if "-mountPoint" in a else MNT
        os.makedirs(mp, exist_ok=True)
        for rel in s.get("esp_files", []):
            fp = os.path.join(mp, rel)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            open(fp, "wb").write(b"x")
        s["mounts"][a[-1]] = mp; save(s)
    elif a[0] == "unmount":
        s["mounts"].pop(a[-1], None); save(s)
elif op == "plutil":
    raw = sys.stdin.buffer.read() if a[5] == "-" else open(a[5], "rb").read()
    v = plistlib.loads(raw)
    for k in a[1].split("."):
        v = v[int(k)] if isinstance(v, list) else v[k]
    if a[2] == "xml1":
        if a[4] == "-": emit(v)
        else: open(a[4], "wb").write(plistlib.dumps(v, fmt=plistlib.FMT_XML))
    elif isinstance(v, bool): print("true" if v else "false")
    elif isinstance(v, (dict, list)): sys.exit(1)
    else: print(v)
elif op == "bless":
    log("BLESS " + " ".join(a))
    if a == ["--getBoot"]:
        print(s["boot_dev"])
    elif "--setBoot" in a and "--mount" in a and a[a.index("--mount") + 1] == "/":
        s["boot_dev"] = "/dev/disk1s1"
        s["nvram"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = "<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>"
        save(s)
elif op == "nvram":
    if len(a) == 2 and a[0] == "-d":
        s["nvram"].pop(a[1], None); save(s)
    elif len(a) == 1:
        if a[0] not in s["nvram"]: sys.exit(1)
        print(f"{a[0]}\t{s['nvram'][a[0]]}")
PY

for tool in diskutil plutil bless nvram; do
  printf '#!/bin/bash\nexec python3 %q %s "$@"\n' "$t/fakemac.py" "$tool" >"$mock/$tool"
done
printf '#!/bin/bash\ncase $1 in -s) echo Darwin ;; -m) echo x86_64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$mock/uname"
printf '#!/bin/bash\necho 0\n' >"$mock/id"
printf '#!/bin/bash\necho "System Integrity Protection status: disabled."\n' >"$mock/csrutil"
chmod +x "$mock"/*

reset_state() {
  python3 - "$FAKE_STATE" "$1" <<'PY'
import json, sys
G = 1 << 30
mode = sys.argv[2]
parts = [
    {"uuid": "11111111-1111-1111-1111-111111111111", "content": "EFI", "offset": 20480, "size": 314572800},
    {"uuid": "22222222-2222-2222-2222-222222222222", "content": "Apple_APFS", "offset": 314593280, "size": 70 * G},
]
esp_files = ["EFI/BOOT/BOOTX64.EFI", "limine.conf", "smartroomos/firstboot.env"]
if mode in ("install", "no-evidence"):
    parts.append({"uuid": "33333333-3333-3333-3333-333333333333", "content": "EFI", "offset": 314593280 + 70 * G, "size": 2 * G})
    parts.append({"uuid": "44444444-4444-4444-4444-444444444444", "content": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "offset": 314593280 + 72 * G, "size": 170 * G})
if mode == "no-evidence":
    esp_files = ["EFI/Microsoft/Boot/bootmgfw.efi"]
elif mode == "foreign":
    parts.append({"uuid": "55555555-5555-5555-5555-555555555555", "content": "Microsoft Basic Data", "offset": 314593280 + 70 * G, "size": 20 * G})
s = {
    "disk": "disk0", "disk_size": 250 * G, "mac_min": 50 * G,
    "apple_esp": "11111111-1111-1111-1111-111111111111",
    "mac_store": "22222222-2222-2222-2222-222222222222", "mac_ref": "disk1",
    "boot_dev": "/dev/disk0s3", "mounts": {}, "parts": parts, "esp_files": esp_files,
    "nvram": {"7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device": "<array><dict><key>Path</key><string>\\EFI\\BOOT\\BOOTX64.EFI</string></dict></array>"},
}
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
  : >"$FAKE_LOG"
}

# 1. Refuses foreign partitions & missing SmartRoom ESP evidence
reset_state foreign
"$t/rf" --yes >"$t/out" 2>&1 && fail "foreign partition accepted"
! grep -q '^MUTATE' "$FAKE_LOG" || fail "foreign refusal mutated disk"

reset_state no-evidence
"$t/rf" --yes >"$t/out" 2>&1 && fail "non-SmartRoom ESP accepted"
grep -q "no SmartRoom/Limine bootloader evidence" "$t/out" || fail "wrong evidence error: $(cat "$t/out")"
! grep -q '^MUTATE' "$FAKE_LOG" || fail "evidence refusal mutated disk"
echo "ok - Intel Mini remove-firmware refuses foreign partitions and non-SmartRoom ESPs"

# 2. Dry run prints plan, changes nothing
reset_state install
"$t/rf" >"$t/out" 2>&1 || fail "dry run failed: $(cat "$t/out")"
grep -q "bless --mount / --setBoot" "$t/out" || fail "dry run missing bless plan"
grep -q "Dry run: nothing changed" "$t/out" || fail "dry run message missing"
! grep -q '^MUTATE' "$FAKE_LOG" || fail "dry run mutated disk"
echo "ok - Intel Mini remove-firmware dry-run prints plan without changing disk"

# 3. Full --yes removal (blesses macOS without --owner, erases Linux then ESP, grows macOS, keeps disk0s1)
"$t/rf" --yes >"$t/out" 2>&1 || fail "full remove failed: $(cat "$t/out")"
grep -q "BLESS --mount / --setBoot" "$FAKE_LOG" || fail "did not bless macOS"
grep -q "MUTATE eraseVolume disk0s4 44444444" "$FAKE_LOG" || fail "did not erase Linux"
grep -q "MUTATE eraseVolume disk0s3 33333333" "$FAKE_LOG" || fail "did not erase SmartRoom ESP"
grep -q "MUTATE resizeContainer disk0s2 0" "$FAKE_LOG" || fail "did not grow macOS"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert len(s["parts"])==2 and s["parts"][0]["uuid"].startswith("1111")' "$FAKE_STATE" \
  || fail "Apple ESP or partition count wrong after remove"
echo "ok - Intel Mini remove-firmware blesses /, deletes Linux then SmartRoom ESP, grows macOS, keeps Apple ESP"

# 4. Free-space-only grow back
reset_state free
"$t/rf" --yes >"$t/out" 2>&1 || fail "free grow failed: $(cat "$t/out")"
grep -q "MUTATE resizeContainer disk0s2 0" "$FAKE_LOG" || fail "free grow did not resizeContainer"
echo "ok - Intel Mini remove-firmware grows macOS into trailing free space"
