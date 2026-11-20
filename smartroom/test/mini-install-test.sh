#!/bin/bash
# Mocked Linux test for smartroom/mac/mini-install (2018 Intel T2 Macmini8,1).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/../mac/mini-install
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; [[ ! -f $t/out ]] || sed 's/^/    /' "$t/out" >&2; exit 1; }

mock=$t/bin
mkdir -p "$mock" "$t/root" "$t/dev" "$t/esp_mnt" "$t/fw/wifi" "$t/fw/bluetooth" "$t/pkg"
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" \
  -e "s|/dev/r|$t/dev/r|g" \
  -e "s|/var/root/|$t/root/|g" "$script" >"$t/mi"
chmod +x "$t/mi"

export FAKE_STATE=$t/state.json FAKE_LOG=$t/calls.log FAKE_MNT=$t/esp_mnt FAKE_DEV=$t/dev
printf 'wifi-blob' >"$t/fw/wifi/C-4364__s-B2.trx"
printf 'bt-blob' >"$t/fw/bluetooth/C-4364.ptb"

cat >"$t/fakemac.py" <<'PY'
import base64, json, os, plistlib, sys

STATE, LOG, MNT, DEV = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"], os.environ["FAKE_MNT"], os.environ["FAKE_DEV"]

def load():
    return json.load(open(STATE))

def save(s):
    json.dump(s, open(STATE, "w"), indent=1, sort_keys=True)

def log(line):
    open(LOG, "a").write(line + "\n")

def emit(obj):
    sys.stdout.buffer.write(plistlib.dumps(obj, fmt=plistlib.FMT_XML))

def parts(s):
    ps = sorted(s["parts"], key=lambda p: p["offset"])
    for i, p in enumerate(ps):
        p["id"] = f"{s['disk']}s{i + 1}"
    return ps

def diskutil(args):
    s = load()
    if args == ["info", "-plist", "/"]:
        c = s["containers"][0]
        st = next(p for p in parts(s) if p["uuid"] == c["store"])
        emit({"DeviceIdentifier": "disk1s1", "APFSContainerReference": c["ref"],
              "APFSPhysicalStores": [{"APFSPhysicalStore": st["id"]}],
              "APFSVolumeGroupID": s["mac_group"], "Internal": True})
    elif args[:2] == ["info", "-plist"]:
        ident = args[2]
        if ident == s["disk"]:
            emit({"DeviceIdentifier": s["disk"], "Internal": True, "WholeDisk": True,
                  "Content": "GUID_partition_scheme", "Size": s["disk_size"], "DeviceBlockSize": 4096})
            return
        p = next((x for x in parts(s) if x["id"] == ident), None)
        if not p:
            sys.exit(1)
        emit({"DeviceIdentifier": p["id"], "DiskUUID": p["uuid"], "Content": p["content"],
              "PartitionMapPartitionOffset": p["offset"], "Size": p["size"], "TotalSize": p["size"],
              "ParentWholeDisk": s["disk"], "MountPoint": s["mounts"].get(p["id"], ""),
              "VolumeName": p.get("name", "")})
    elif args[:2] == ["list", "-plist"]:
        ps = parts(s)
        emit({"AllDisksAndPartitions": [{"DeviceIdentifier": s["disk"], "Content": "GUID_partition_scheme",
              "Partitions": [{"DeviceIdentifier": p["id"]} for p in ps]}]})
    elif args[:2] == ["apfs", "resizeContainer"] and len(args) == 5 and args[3:] == ["limits", "-plist"]:
        p = next(x for x in parts(s) if x["id"] == args[2])
        emit({"MinimumSize": s["mac_min"], "CurrentSize": p["size"], "MaximumSize": s["disk_size"] - p["offset"]})
    elif args[:2] == ["apfs", "resizeContainer"] and len(args) == 4:
        p = next(x for x in parts(s) if x["id"] == args[2])
        sz_s = args[3]
        new_sz = int(sz_s[:-1]) if sz_s.endswith("B") else int(sz_s)
        assert new_sz >= s["mac_min"], f"{new_sz} < {s['mac_min']}"
        p["size"] = new_sz
        save(s)
        log(f"MUTATE resizeContainer {args[2]} {new_sz}")
    elif args[0] == "addPartition":
        prev_id, fmt, _name, sz_s = args[1], args[2], args[3], args[4]
        ps = parts(s)
        prev = next(x for x in ps if x["id"] == prev_id)
        off = prev["offset"] + prev["size"]
        if sz_s == "0":
            sz = s["disk_size"] - off - 1048576
        else:
            sz = int(sz_s[:-1]) if sz_s.endswith("B") else int(sz_s)
        content = "EFI" if fmt == "%EFI%" else "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        idx = len(s["parts"]) + 1
        uid = f"AAAA0000-0000-0000-0000-{idx:012d}"
        s["parts"].append({"uuid": uid, "content": content, "offset": off, "size": sz})
        new_id = f"{s['disk']}s{idx}"
        open(os.path.join(DEV, "r" + new_id), "wb").close()
        save(s)
        log(f"MUTATE addPartition {fmt} {new_id} {sz}")
    elif args[0] == "mount":
        ident = args[-1]
        mp = os.path.join(MNT, ident)
        os.makedirs(mp, exist_ok=True)
        s["mounts"][ident] = mp
        save(s)
    elif args[0] == "unmount":
        ident = args[-1]
        s["mounts"].pop(ident, None)
        save(s)
    else:
        sys.exit(1)

if __name__ == "__main__":
    op = sys.argv[1]
    a = sys.argv[2:]
    if op == "diskutil":
        diskutil(a)
    elif op == "plutil":
        assert a[0] == "-extract" and a[3] == "-o"
        raw = sys.stdin.buffer.read() if a[5] == "-" else open(a[5], "rb").read()
        try:
            obj = plistlib.loads(raw)
        except Exception:
            obj = json.loads(raw.decode())
        for k in a[1].split("."):
            obj = obj[int(k)] if isinstance(obj, list) else obj[k]
        if a[2] == "xml1":
            emit(obj)
        elif isinstance(obj, bytes):
            print(base64.b64encode(obj).decode())
        elif isinstance(obj, bool):
            print("true" if obj else "false")
        elif isinstance(obj, (dict, list)):
            sys.exit(1)
        else:
            print(obj)
    elif op == "nvram":
        s = load()
        if a == ["-x", "-p"]:
            emit(s["nvram_bin"])
        elif len(a) == 2 and a[0] == "-d":
            s["nvram_str"].pop(a[1], None)
            s["nvram_bin"].pop(a[1], None)
            save(s)
            log(f"MUTATE nvram -d {a[1]}")
        elif len(a) == 1:
            if a[0] not in s["nvram_str"]:
                sys.exit(1)
            print(f"{a[0]}\t{s['nvram_str'][a[0]]}")
    elif op == "bless":
        s = load()
        log("BLESS " + " ".join(a))
        if a == ["--getBoot"]:
            print(s["boot_dev"])
        elif "--setBoot" in a:
            mp = a[a.index("--mount") + 1]
            esp_id = next((k for k, v in s["mounts"].items() if v == mp), None)
            assert esp_id, f"unknown mount {mp}"
            s["boot_dev"] = f"/dev/{esp_id}"
            xml = "<array><dict><key>Path</key><string>\\EFI\\BOOT\\BOOTX64.EFI</string></dict></array>\n".encode()
            s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = xml
            s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data"] = b"\x04\x01\x2a\x00\x02\x00\x00\x00\x7f\xff\x04\x00"
            save(s)
    elif op == "newfs_msdos":
        log("MUTATE newfs_msdos " + " ".join(a))
PY

for tool in diskutil plutil nvram bless newfs_msdos; do
  printf '#!/bin/bash\nexec python3 %q %s "$@"\n' "$t/fakemac.py" "$tool" >"$mock/$tool"
done
printf '#!/bin/bash\ncase $1 in -s) echo Darwin ;; -m) echo x86_64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$mock/uname"
printf '#!/bin/bash\necho 0\n' >"$mock/id"
printf '#!/bin/bash\necho "${FAKE_MODEL:-Macmini8,1}"\n' >"$mock/sysctl"
printf '#!/bin/bash\necho "${FAKE_SIP:-System Integrity Protection status: disabled.}"\n' >"$mock/csrutil"
printf '#!/bin/bash\necho "${FAKE_FWPASS:-Password Enabled: No}"\n' >"$mock/firmwarepasswd"
printf '#!/bin/bash\nexit 0\n' >"$mock/system_profiler"
# pmset: -a autorestart N is kept in $t/pmset.state (PMSET_FAIL=1 refuses, PMSET_STICK=0 accepts and keeps the old value);
# -g prints it. Every call goes to $t/pmset.log.
cat >"$mock/pmset" <<SH
#!/bin/bash
echo "\$*" >>"$t/pmset.log"
[ "\${PMSET_FAIL:-0}" = 1 ] && exit 1
if [ "\$1" = -a ] && [ "\$2" = autorestart ]; then
  [ "\${PMSET_STICK:-1}" = 0 ] || echo "\$3" >"$t/pmset.state"
  exit 0
fi
if [ "\$1" = -g ]; then
  printf 'System-wide power settings:\\nCurrently in use:\\n standby 1\\n autorestart          %s\\n' "\$(cat "$t/pmset.state" 2>/dev/null || echo 0)"
  exit 0
fi
exit 1
SH
printf '#!/bin/bash\necho "tmutil $*" >>%q\n' "$t/calls.log" >"$mock/tmutil"
printf '#!/bin/bash\necho "shutdown $*" >>%q\n' "$t/calls.log" >"$mock/shutdown"
cat >"$mock/shasum" <<'SH'
#!/bin/bash
[ "${1:-}" = "-a" ] && [ "${2:-}" = "256" ] && shift 2
exec sha256sum "$@"
SH
cat >"$mock/cp" <<'SH'
#!/bin/bash
args=()
for a in "$@"; do
  case $a in
    -RX) args+=("-R") ;;
    -X) ;;
    *) args+=("$a") ;;
  esac
done
exec /bin/cp "${args[@]}"
SH
chmod +x "$mock"/*

# Build test payload ZIP (2 MiB + 4 KiB = 2101248 bytes root.img to test non-1MiB-multiple 4K tail readback!)
python3 - "$t/pkg" <<'PY'
import hashlib, json, os, pathlib, zipfile
d = pathlib.Path(os.sys.argv[1])
stage = d / "stage"
(stage / "esp/EFI/BOOT").mkdir(parents=True)
(stage / "esp/EFI/Linux").mkdir(parents=True)
(stage / "esp/EFI/BOOT/BOOTX64.EFI").write_bytes(b"MZ-LIMINE-BOOTX64")
(stage / "esp/EFI/Linux/smartroomos_linux-t2.efi").write_bytes(b"MZ-UKI")
(stage / "esp/limine.conf").write_text("timeout: 1\n/linux-t2\nprotocol: efi\npath: boot():/EFI/Linux/smartroomos_linux-t2.efi\n")
(stage / "root.img").write_bytes(b"BTRFS_HDR" + os.urandom(2 * 1048576 + 4096 - 9))
manifest_lines = []
for p in sorted(stage.rglob("*")):
    if p.is_file():
        rel = p.relative_to(stage).as_posix()
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        manifest_lines.append(f"{h}  {rel}\n")
(stage / "MANIFEST").write_text("".join(manifest_lines))
zpath = d / "smartroomcontrollerfirmware-mini-x86_64.zip"
with zipfile.ZipFile(zpath, "w") as z:
    for p in sorted(stage.rglob("*")):
        if p.is_file():
            z.write(p, p.relative_to(stage).as_posix())
idata = {
    "os_list": [{
        "default_os_name": "SmartRoomOS",
        "omarchy_target": "intel-mini-full-os",
        "package": "smartroomcontrollerfirmware-mini-x86_64.zip",
        "boot_object": "EFI/BOOT/BOOTX64.EFI",
        "next_object": "EFI/Linux/smartroomos_linux-t2.efi",
        "partitions": [
            {"type": "EFI", "size": "2147483648B", "format": "fat", "volume_id": "0x2abf9f91"},
            {"type": "Linux", "image": "root.img", "expand": True, "size": "8589934592B"},
        ],
    }]
}
(d / "installer_data.json").write_text(json.dumps(idata))
PY
PAY="$t/pkg/smartroomcontrollerfirmware-mini-x86_64.zip"
IDATA="$t/pkg/installer_data.json"
PSHA=$(sha256sum "$PAY" | awk '{print $1}')
printf 'SMARTROOMOS_SERVER_URL=https://rooms.example.invalid\nSMARTROOMOS_AGENT_INSTALL_SHA256=%064d\n' 0 >"$t/fb.env"

reset_state() {
  python3 - "$FAKE_STATE" "${1:-normal}" <<'PY'
import json, sys
G = 1 << 30
mode = sys.argv[2]
mac_sz = 180 * G if mode == "free" else 249 * G
parts = [
    {"uuid": "00000000-0000-0000-0000-000000000001", "content": "EFI", "offset": 20480, "size": 314572800},
    {"uuid": "00000000-0000-0000-0000-000000000002", "content": "Apple_APFS", "offset": 314593280, "size": mac_sz},
]
if mode == "existing":
    parts.append({"uuid": "00000000-0000-0000-0000-000000000003", "content": "EFI", "offset": 314593280 + mac_sz, "size": 2 * G})
    parts.append({"uuid": "00000000-0000-0000-0000-000000000004", "content": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "offset": 314593280 + mac_sz + 2 * G, "size": 10 * G})
s = {
    "disk": "disk0", "disk_size": 250 * G, "mac_min": 50 * G, "mac_group": "MACGROUP-1111",
    "boot_dev": "/dev/disk1s1", "parts": parts,
    "containers": [{"ref": "disk1", "store": "00000000-0000-0000-0000-000000000002"}],
    "mounts": {},
    "nvram_str": {"94b73556-2197-4702-82a8-3e1337dafbfb:AppleSecureBootPolicy": "%00"},
    "nvram_bin": {
        "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device": "<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>\n",
        "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data": "__B64_MAC_DP__",
    },
}
import base64
s["nvram_bin"] = {
    "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device": base64.b64encode(b"<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>\n").decode(),
    "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data": base64.b64encode(b"\x04\x04\x0c\x00MAC_DP\x7f\xff\x04\x00").decode(),
}
# Wait: plistlib dumps bytes directly when given bytes
s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = base64.b64decode(s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"])
s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data"] = base64.b64decode(s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data"])
# json can't store raw bytes; serialize as list of ints? Wait: store utf8/b64 and convert in fakemac!
PY
}

# Fix nvram_bin JSON serialization cleanly in fakemac.py (decode base64 on emit)
python3 - "$t/fakemac.py" <<'PY'
p = open(sys.argv[1] if False else __import__("sys").argv[1]).read()
p = p.replace('emit(s["nvram_bin"])', 'emit({k: base64.b64decode(v) if isinstance(v, str) else v for k, v in s["nvram_bin"].items()})')
p = p.replace('s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = xml', 's["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = base64.b64encode(xml).decode()')
p = p.replace('s["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data"] = b"\\x04\\x01\\x2a\\x00\\x02\\x00\\x00\\x00\\x7f\\xff\\x04\\x00"', 's["nvram_bin"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data"] = base64.b64encode(b"\\x04\\x01\\x2a\\x00\\x02\\x00\\x00\\x00\\x7f\\xff\\x04\\x00").decode()')
open(__import__("sys").argv[1], "w").write(p)
PY

reset_state_clean() {
  python3 - "$FAKE_STATE" "${1:-normal}" <<'PY'
import base64, json, sys
G = 1 << 30
mode = sys.argv[2]
mac_sz = 180 * G if mode == "free" else 249 * G
parts = [
    {"uuid": "00000000-0000-0000-0000-000000000001", "content": "EFI", "offset": 20480, "size": 314572800},
    {"uuid": "00000000-0000-0000-0000-000000000002", "content": "Apple_APFS", "offset": 314593280, "size": mac_sz},
]
if mode == "existing":
    parts.append({"uuid": "00000000-0000-0000-0000-000000000003", "content": "EFI", "offset": 314593280 + mac_sz, "size": 2 * G})
    parts.append({"uuid": "00000000-0000-0000-0000-000000000004", "content": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "offset": 314593280 + mac_sz + 2 * G, "size": 10 * G})
s = {
    "disk": "disk0", "disk_size": 250 * G, "mac_min": 50 * G, "mac_group": "MACGROUP-1111",
    "boot_dev": "/dev/disk1s1", "parts": parts,
    "containers": [{"ref": "disk1", "store": "00000000-0000-0000-0000-000000000002"}],
    "mounts": {},
    "nvram_str": {"94b73556-2197-4702-82a8-3e1337dafbfb:AppleSecureBootPolicy": "%00"},
    "nvram_bin": {
        "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device": base64.b64encode(b"<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>\n").decode(),
        "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device-data": base64.b64encode(b"\x04\x04\x0c\x00MAC_DP\x7f\xff\x04\x00").decode(),
    },
}
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
  : >"$FAKE_LOG"
  rm -f "$t/pmset.state" "$t/pmset.log"
}

# 1. Pre-flight refusals (F7/F20): zero disk mutations
reset_state_clean normal
FAKE_MODEL=MacBookPro16,1 "$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 && fail "wrong model accepted"
grep -q "expected Macmini8,1" "$t/out" || fail "wrong model error: $(cat "$t/out")"

FAKE_SIP="System Integrity Protection status: enabled." "$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 && fail "SIP enabled accepted"
grep -q "csrutil disable" "$t/out" || fail "wrong SIP error: $(cat "$t/out")"

FAKE_FWPASS="Password Enabled: Yes" "$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 && fail "firmware password accepted"
grep -q "firmware password" "$t/out" || fail "wrong fwpass error: $(cat "$t/out")"

python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["nvram_str"]["94b73556-2197-4702-82a8-3e1337dafbfb:AppleSecureBootPolicy"]="%01"; json.dump(s,open(sys.argv[1],"w"))' "$FAKE_STATE"
"$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 && fail "Medium Security accepted"
grep -q "No Security" "$t/out" || fail "wrong T2 security error: $(cat "$t/out")"

reset_state_clean existing
"$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" --yes >"$t/out" 2>&1 && fail "existing install accepted (F20)"
grep -q "run remove-firmware first" "$t/out" || fail "wrong F20 error: $(cat "$t/out")"
! grep -q '^MUTATE' "$FAKE_LOG" || fail "refusal mutated disk: $(cat "$FAKE_LOG")"
echo "ok - preflight refuses wrong model, SIP on, firmware password, T2 Medium/Full Security, and existing install without touching disk"

# 2. Dry-run plan (Lucas's rule: MinimumSize 50 GiB + 20 GiB = 70 GiB kept for macOS -> 160 GiB for SmartRoom)
reset_state_clean normal
"$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" >"$t/out" 2>&1 || fail "dry run failed: $(cat "$t/out")"
grep -q "shrink disk0s2 from 249 GiB to 70 GiB" "$t/out" || fail "dry run split wrong: $(cat "$t/out")"
grep -q "Dry run: nothing changed" "$t/out" || fail "dry run notice missing"
! grep -q '^MUTATE' "$FAKE_LOG" || fail "dry run mutated disk"
echo "ok - dry-run computes MinimumSize + 20 GiB macOS keep (230 -> 70 GiB) and changes nothing"
grep -q "pmset -a autorestart 1 and read it back (now '0')" "$t/out" || fail "dry run plan lacks the power-cut step: $(cat "$t/out")"
[[ ! -e $t/pmset.state ]] || fail "dry run changed the power-failure setting"
! grep -qvx -- '-g' "$t/pmset.log" || fail "dry run called pmset with more than -g: $(cat "$t/pmset.log")"
echo "ok - dry-run plans 'pmset -a autorestart 1' (read back) and does not change it"

# 2b. The power-cut setting (WS7/F9): set from macOS before any disk change, read back, refuse if it does not stick
for mode in fail nostick; do
  reset_state_clean normal
  if [[ $mode == fail ]]; then export PMSET_FAIL=1; else export PMSET_STICK=0; fi
  "$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" --yes >"$t/out" 2>&1 \
    && fail "install went on although autorestart could not be set ($mode)"
  unset PMSET_FAIL PMSET_STICK
  grep -q "Nothing on disk was changed" "$t/out" || fail "pmset $mode: wrong refusal: $(cat "$t/out")"
  ! grep -q '^MUTATE' "$FAKE_LOG" || fail "pmset $mode: the install changed the disk before the power-cut setting: $(cat "$FAKE_LOG")"
done
reset_state_clean normal
"$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --firstboot-env "$t/fb.env" --yes >"$t/out" 2>&1 || fail "install with pmset ok failed: $(tail -8 "$t/out")"
[[ $(cat "$t/pmset.state") == 1 ]] || fail "autorestart was not set to 1: $(cat "$t/pmset.log")"
grep -qx -- '-a autorestart 1' "$t/pmset.log" || fail "pmset -a autorestart 1 was not called: $(cat "$t/pmset.log")"
grep -q "pmset autorestart 1, read back" "$t/out" || fail "no read-back line in the output"
grep -q '^MUTATE' "$FAKE_LOG" || fail "install did not mutate anything"
echo "ok - the install sets pmset autorestart 1 before any disk change, reads it back, and refuses to go on if it does not stick"

# 3. Full --yes install + SHA-256 readback + ESP staging + bless
reset_state_clean normal
rm -f "$t/dev/rdisk0s3" "$t/dev/rdisk0s4"
SMARTROOM_MAC_FIRMWARE_DIR="$t/fw" "$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" \
  --firstboot-env "$t/fb.env" --yes --reboot >"$t/out" 2>&1 || fail "full install failed: $(cat "$t/out")"
grep -q "MUTATE resizeContainer disk0s2 75161927680" "$FAKE_LOG" || fail "resizeContainer wrong: $(cat "$FAKE_LOG")"
grep -q "MUTATE addPartition %EFI% disk0s3 2147483648" "$FAKE_LOG" || fail "addPartition EFI wrong"
grep -q "MUTATE newfs_msdos -F 32 -v EFI - Smart -I 0x2abf9f91 $t/dev/rdisk0s3" "$FAKE_LOG" || fail "newfs_msdos wrong: $(cat "$FAKE_LOG")"
grep -q "MUTATE addPartition %Linux% disk0s4" "$FAKE_LOG" || fail "addPartition Linux wrong"
grep -q "BLESS --mount $FAKE_MNT/disk0s3 --setBoot --file $FAKE_MNT/disk0s3/EFI/BOOT/BOOTX64.EFI --shortform" "$FAKE_LOG" || fail "bless args wrong: $(cat "$FAKE_LOG")"
grep -q "shutdown -r now" "$FAKE_LOG" || fail "shutdown missing"

# Verify raw root.img byte-for-byte match and staged ESP contents
mkdir -p "$t/verify_zip"
unzip -q "$PAY" -d "$t/verify_zip"
cmp -s "$t/verify_zip/root.img" "$t/dev/rdisk0s4" || fail "raw root.img mismatch on $t/dev/rdisk0s4"
esp="$FAKE_MNT/disk0s3"
[[ -s $esp/EFI/BOOT/BOOTX64.EFI && -s $esp/limine.conf && -s $esp/smartroomos/firstboot.env ]] || fail "ESP files missing"
[[ -s $esp/smartroomos/macos-firmware/wifi/C-4364__s-B2.trx && -s $esp/smartroomos/macos-firmware/bluetooth/C-4364.ptb ]] || fail "Wi-Fi/BT firmware not staged"
[[ -s $esp/smartroomos/macos-boot-device.xml && -s $esp/smartroomos/macos-boot-device.bin ]] || fail "macOS NVRAM backup missing"
[[ -s $esp/smartroomos/firmware-boot-device.xml && -s $esp/smartroomos/firmware-boot-device.bin ]] || fail "Firmware NVRAM record missing"
echo "ok - full install: resize, 2 GiB ESP (0x2abf9f91), raw root.img 4K-tail readback, Wi-Fi/BT + NVRAM + firstboot.env + bless"

# 4. Already-shrunk disk (--source free)
reset_state_clean free
rm -f "$t/dev/rdisk0s3" "$t/dev/rdisk0s4"
"$t/mi" --payload "$PAY" --sha256 "$PSHA" --installer-data "$IDATA" --no-firstboot-env --source free --yes >"$t/out" 2>&1 || fail "free space install failed: $(cat "$t/out")"
! grep -q "MUTATE resizeContainer" "$FAKE_LOG" || fail "free space install resized macOS unnecessarily"
grep -q "MUTATE addPartition %EFI% disk0s3" "$FAKE_LOG" || fail "free space install did not add EFI"
echo "ok - --source free uses existing trailing space without resizing macOS"

# 5. POSIX syntax & no CLT tools
for w in python3 python git clang xcrun strings jq perl; do
  ! grep -v '^ *#' "$script" | grep -Eq "(^|[;&|( ])$w( |$)" || fail "script calls forbidden tool $w"
done
bash --posix -n "$script" || fail "not POSIX-mode parseable"
echo "ok - mini-install passes bash --posix -n and calls no CLT tools"
