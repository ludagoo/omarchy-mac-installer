#!/bin/bash
# Mocked Linux test for smartroom/mac/smartroom-boot-os on Intel T2 Macmini8,1.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/../mac/smartroom-boot-os
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; [[ ! -f $t/out ]] || sed 's/^/    /' "$t/out" >&2; exit 1; }

mock=$t/bin
mkdir -p "$mock" "$t/esp_mnt"
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" \
  "$script" >"$t/sbo"
chmod +x "$t/sbo"

export FAKE_STATE=$t/state.json FAKE_LOG=$t/calls.log FAKE_MNT=$t/esp_mnt
cat >"$t/fakemac.py" <<'PY'
import json, os, plistlib, sys

STATE, LOG, MNT = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"], os.environ["FAKE_MNT"]
def load(): return json.load(open(STATE))
def save(s): json.dump(s, open(STATE, "w"), indent=1)
def log(m): open(LOG, "a").write(m + "\n")
def emit(o): sys.stdout.buffer.write(plistlib.dumps(o, fmt=plistlib.FMT_XML))

op = sys.argv[1]; a = sys.argv[2:]; s = load()
if op == "diskutil":
    if a == ["info", "-plist", "/"]:
        emit({"DeviceIdentifier": "disk1s1", "APFSContainerReference": "disk1",
              "APFSPhysicalStores": [{"APFSPhysicalStore": "disk0s2"}], "Internal": True})
    elif a[:2] == ["info", "-plist"]:
        ident = a[2]
        if ident == "disk1s1":
            emit({"DeviceIdentifier": "disk1s1", "APFSPhysicalStores": [{"APFSPhysicalStore": "disk0s2"}]})
        else:
            p = next((x for x in s["parts"] if x["id"] == ident), None)
            if not p: sys.exit(1)
            emit({"DeviceIdentifier": p["id"], "DiskUUID": p["uuid"], "Content": p["content"],
                  "PartitionMapPartitionOffset": p["offset"], "ParentWholeDisk": "disk0",
                  "MountPoint": s["mounts"].get(p["id"], "")})
    elif a[:2] == ["list", "-plist"]:
        emit({"AllDisksAndPartitions": [{"DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme",
              "Partitions": [{"DeviceIdentifier": p["id"]} for p in s["parts"]]}]})
    elif a[0] == "mount":
        mp = a[a.index("-mountPoint") + 1] if "-mountPoint" in a else os.path.join(MNT, a[-1])
        os.makedirs(mp, exist_ok=True)
        if a[-1] == "disk0s3" and s.get("has_fw", True):
            for rel in ("EFI/BOOT/BOOTX64.EFI", "limine.conf"):
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
    elif "--setBoot" in a:
        mp = a[a.index("--mount") + 1]
        is_mac = (mp == "/")
        val = "/dev/disk1s1" if is_mac else "/dev/disk0s3"
        nv = ("<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>"
              if is_mac else "<array><dict><key>Path</key><string>\\EFI\\BOOT\\BOOTX64.EFI</string></dict></array>")
        if "--nextonly" in a:
            s["nvram"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-next"] = nv
        else:
            s["boot_dev"] = val
            s["nvram"]["7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device"] = nv
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
printf '#!/bin/bash\necho "${FAKE_SIP:-System Integrity Protection status: disabled.}"\n' >"$mock/csrutil"
printf '#!/bin/bash\necho "$*" >>%q\n' "$t/shutdown.log" >"$mock/shutdown"
chmod +x "$mock"/*

cat >"$FAKE_STATE" <<'JSON'
{
  "boot_dev": "/dev/disk1s1",
  "has_fw": true,
  "mounts": {},
  "nvram": {
    "7c436110-ab2a-4bbb-a880-fe41995c9f82:efi-boot-device": "<array><dict><key>Path</key><string>\\System\\Library\\CoreServices\\boot.efi</string></dict></array>"
  },
  "parts": [
    {"id": "disk0s1", "uuid": "11111111-1111-1111-1111-111111111111", "content": "EFI", "offset": 20480},
    {"id": "disk0s2", "uuid": "22222222-2222-2222-2222-222222222222", "content": "Apple_APFS", "offset": 314593280},
    {"id": "disk0s3", "uuid": "33333333-3333-3333-3333-333333333333", "content": "EFI", "offset": 80000000000},
    {"id": "disk0s4", "uuid": "44444444-4444-4444-4444-444444444444", "content": "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "offset": 82147483648}
  ]
}
JSON

st=$("$t/sbo" status)
grep -qx 'default: macOS' <<<"$st" && grep -qx 'next:    none' <<<"$st" && grep -qx 'firmware partition: disk0s3' <<<"$st" || fail "status wrong: $st"
echo "ok - Intel Mini status identifies macOS default and disk0s3 SmartRoom ESP (ignoring disk0s1)"

out=$("$t/sbo" firmware --once --reboot) || fail "firmware --once failed: $out"
[[ $out == "next start: SmartRoom Firmware" && $(cat "$t/shutdown.log") == "-r now" ]] || fail "firmware --once output: $out"
grep -q -- '--setBoot --nextonly --file .*/EFI/BOOT/BOOTX64.EFI --shortform' "$FAKE_LOG" || fail "bless args wrong: $(cat "$FAKE_LOG")"
echo "ok - Intel Mini firmware --once --reboot uses bless --nextonly --shortform with no password"

out=$("$t/sbo" firmware) || fail "firmware default failed: $out"
[[ $out == "default: SmartRoom Firmware" ]] || fail "firmware default output: $out"
st=$("$t/sbo" status)
grep -qx 'default: SmartRoom Firmware' <<<"$st" && grep -qx 'next:    none' <<<"$st" || fail "status after persistent firmware: $st"
echo "ok - Intel Mini firmware persistent clears efi-boot-next"

out=$("$t/sbo" macos) || fail "macos default failed: $out"
[[ $out == "default: macOS" ]] || fail "macos output: $out"
grep -q -- 'BLESS --mount / --setBoot$' "$FAKE_LOG" || fail "macos bless wrong"
echo "ok - Intel Mini macos sets / as default without password"

FAKE_SIP="System Integrity Protection status: enabled." "$t/sbo" firmware >"$t/out" 2>&1 && fail "SIP enabled accepted"
grep -q "csrutil disable" "$t/out" || fail "wrong SIP refusal: $(cat "$t/out")"
echo "ok - refuses when SIP NVRAM protection is enabled"
