#!/bin/bash
# Exercises smartroom/mac/remove-firmware against a simulated Apple Silicon
# Mac on Linux: fake diskutil (XML plists from a JSON disk state; partitions
# are renumbered after every deletion to prove the script tracks them by UUID),
# plutil, bless, nvram, uname and id. Python is used only by these fakes; the
# script itself must never call it. No root, no Mac.
#   smartroom/test/remove-firmware-test.sh            (bash under test: bash)
#   TEST_BASH=/path/to/bash-3.2 smartroom/test/remove-firmware-test.sh
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/../mac/remove-firmware
tbash=${TEST_BASH:-bash}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "not ok - $*" >&2; [[ ! -f $t/out ]] || sed 's/^/    /' "$t/out" >&2; exit 1; }
mock=$t/bin
mkdir -p "$mock" "$t/root"
sed -e "s|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$mock:/usr/bin:/bin:/usr/sbin:/sbin|" \
  -e "s|/var/root/|$t/root/|g" "$script" >"$t/rf"
grep -q "^PATH=$mock:" "$t/rf" || fail "could not point the script at the fakes"
export FAKE_STATE=$t/state.json FAKE_LOG=$t/calls.log

# ---- the fakes ---------------------------------------------------------------
cat >"$t/fakemac.py" <<'PY'
import json, os, plistlib, sys

STATE, LOG = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"]

def load():
    with open(STATE) as f:
        return json.load(f)

def save(s):
    with open(STATE, "w") as f:
        json.dump(s, f, indent=1, sort_keys=True)

def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")

def parts(s):  # partitions with their BSD ids: numbered by GPT slot, compacted
    ps = sorted(s["partitions"], key=lambda p: p["slot"])
    for i, p in enumerate(ps):
        p["id"] = f"{s['disk']}s{i + 1}"
    return ps

def containers(s):
    out = []
    for c in s["containers"]:
        for i, v in enumerate(c["volumes"]):
            v["id"] = f"{c['ref']}s{i + 1}"
        out.append(c)
    return out

def by_id(s, ident):
    for p in parts(s):
        if p["id"] == ident:
            return "part", p
    for c in containers(s):
        for v in c["volumes"]:
            if v["id"] == ident:
                return "vol", (c, v)
    return None, None

def store_of(s, c):
    return next(p for p in parts(s) if p["uuid"] == c["store"])

def mac_container(s):
    return next(c for c in containers(s) if c["ref"] == s["mac_ref"])

def system_volume(c):
    return next(v for v in c["volumes"] if v["roles"] == ["System"])

def emit(obj):
    sys.stdout.buffer.write(plistlib.dumps(obj, fmt=plistlib.FMT_XML))

def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

def part_info(s, p):
    d = {"DeviceIdentifier": p["id"], "DiskUUID": p["uuid"], "Content": p["type"],
         "PartitionMapPartitionOffset": p["offset"], "Size": p["size"], "TotalSize": p["size"],
         "ParentWholeDisk": s["disk"], "WholeDisk": False, "Internal": True,
         "DeviceBlockSize": 4096, "MountPoint": s["mounts"].get(p["uuid"], "")}
    if p.get("name"):
        d["VolumeName"] = p["name"]
    return d

def vol_info(s, c, v):
    st = store_of(s, c)
    d = {"DeviceIdentifier": v["id"], "DiskUUID": v["uuid"], "VolumeName": v["name"],
         "APFSContainerReference": c["ref"], "APFSPhysicalStores": [{"APFSPhysicalStore": st["id"]}],
         "ParentWholeDisk": c["ref"], "WholeDisk": False, "Internal": True,
         "MountPoint": "/" if (c["ref"] == s["mac_ref"] and v["roles"] == ["System"]) else ""}
    if v.get("group"):
        d["APFSVolumeGroupID"] = v["group"]
    return d

def next_offset(s, p):
    later = [q["offset"] for q in s["partitions"] if q["offset"] > p["offset"]]
    return min(later) if later else s["disk_size"]

def diskutil(args):
    s = load()
    if args[:2] == ["info", "-plist"]:
        ident = args[2]
        if ident == "/":
            c = mac_container(s)
            emit(vol_info(s, c, system_volume(c)))
        elif ident == s["disk"]:
            emit({"DeviceIdentifier": ident, "Content": "GUID_partition_scheme", "Size": s["disk_size"],
                  "WholeDisk": True, "Internal": True, "VirtualOrPhysical": "Unknown",
                  "DeviceTreePath": "IODeviceTree:/arm-io/ans"})
        else:
            kind, x = by_id(s, ident)
            if kind == "part":
                emit(part_info(s, x))
            elif kind == "vol":
                emit(vol_info(s, *x))
            else:
                die(f"Could not find disk: {ident}")
    elif args[:2] == ["list", "-plist"] and args[2] == s["disk"]:
        ps = parts(s)
        emit({"AllDisks": [s["disk"]] + [p["id"] for p in ps],
              "AllDisksAndPartitions": [{"DeviceIdentifier": s["disk"], "Content": "GUID_partition_scheme",
                                         "Size": s["disk_size"], "OSInternal": False,
                                         "Partitions": [{"DeviceIdentifier": p["id"], "Content": p["type"],
                                                         "DiskUUID": p["uuid"], "Size": p["size"]} for p in ps]}],
              "WholeDisks": [s["disk"]]})
    elif args[:3] == ["apfs", "list", "-plist"]:
        cs = containers(s)
        emit({"Containers": [{"ContainerReference": c["ref"], "APFSContainerUUID": c["uuid"],
                              "CapacityCeiling": store_of(s, c)["size"],
                              "PhysicalStores": [{"DeviceIdentifier": store_of(s, c)["id"],
                                                  "DiskUUID": c["store"], "Size": store_of(s, c)["size"]}],
                              "Volumes": [{"DeviceIdentifier": v["id"], "Name": v["name"], "Roles": v["roles"],
                                           "APFSVolumeUUID": v["uuid"]} for v in c["volumes"]]} for c in cs]})
    elif args[:3] == ["mount", "readOnly", "nobrowse"] and args[3] == "-mountPoint":
        mp, ident = args[4], args[5]
        kind, p = by_id(s, ident)
        if kind != "part" or p["type"] != "EFI":
            die(f"fake: mount of {ident} not simulated")
        if not os.path.isdir(mp):
            die(f"mount point {mp} does not exist")
        for rel, text in s["esp_files"].get(p["uuid"], {}).items():
            os.makedirs(os.path.dirname(os.path.join(mp, rel)), exist_ok=True)
            with open(os.path.join(mp, rel), "w") as f:
                f.write(text)
        s["mounts"][p["uuid"]] = mp
        save(s)
        log(f"mount {ident} {p['uuid']}")
    elif args[0] == "unmount":
        kind, p = by_id(s, args[1])
        mp = s["mounts"].pop(p["uuid"], None) if kind == "part" else None
        if not mp:
            die(f"{args[1]} not mounted")
        for root, dirs, files in os.walk(mp, topdown=False):
            for n in files:
                os.unlink(os.path.join(root, n))
            for n in dirs:
                os.rmdir(os.path.join(root, n))
        save(s)
        log(f"unmount {args[1]} {p['uuid']}")
    elif args[:2] == ["apfs", "deleteContainer"] and len(args) == 3:
        kind, p = by_id(s, args[2])
        cs = [c for c in s["containers"] if kind == "part" and c["store"] == p["uuid"]]
        if len(cs) != 1:
            die(f"{args[2]} is not an APFS physical store")
        log(f"MUTATE deleteContainer {args[2]} {p['uuid']}")
        s["containers"].remove(cs[0])
        s["partitions"] = [q for q in s["partitions"] if q["uuid"] != p["uuid"]]
        if s["boot"].get("volume") in [v["uuid"] for v in cs[0]["volumes"]]:
            s["boot"]["volume"] = None
        save(s)
        print(f"Started APFS operation\nDeleting APFS Container with all of its APFS Volumes\nFinished APFS operation")
    elif args[:3] == ["eraseVolume", "free", "none"] and len(args) == 4:
        kind, p = by_id(s, args[3])
        if kind != "part":
            die(f"Could not find disk: {args[3]}")
        if any(c["store"] == p["uuid"] for c in s["containers"]):
            die(f"{args[3]} is an APFS physical store; refusing")
        log(f"MUTATE eraseVolume {args[3]} {p['uuid']}")
        s["partitions"] = [q for q in s["partitions"] if q["uuid"] != p["uuid"]]
        s["mounts"].pop(p["uuid"], None)
        save(s)
        print(f"Started erase on {args[3]}\nFinished erase on {args[3]}")
    elif args[:2] == ["apfs", "resizeContainer"]:
        kind, p = by_id(s, args[2])
        if kind != "part" or not any(c["store"] == p["uuid"] for c in s["containers"]):
            die(f"{args[2]} is not an APFS physical store")
        maximum = next_offset(s, p) - p["offset"]
        if args[3:] == ["limits", "-plist"]:
            emit({"CurrentSize": p["size"], "MaximumSize": maximum, "MinimumSize": 100 << 30})
        elif args[3:] == ["0"]:
            log(f"MUTATE resizeContainer {args[2]} {p['uuid']} {maximum}")
            p["size"] = maximum
            save(s)
            print("Finished APFS operation")
        else:
            die("fake: resizeContainer form not simulated")
    else:
        die("fake diskutil: not simulated: " + " ".join(args), 2)

def plutil_main(argv):
    # plutil -extract KEYPATH FMT -o OUT FILE|-
    if len(argv) != 6 or argv[0] != "-extract" or argv[3] != "-o":
        die("fake plutil: usage: -extract keypath fmt -o out file", 2)
    keypath, fmt, out, src = argv[1], argv[2], argv[4], argv[5]
    data = sys.stdin.buffer.read() if src == "-" else open(src, "rb").read()
    try:
        value = plistlib.loads(data)
    except Exception:
        die(f"{src}: Property List error: not a plist", 1)
    for key in keypath.split("."):
        if isinstance(value, list) and key.isdigit() and int(key) < len(value):
            value = value[int(key)]
        elif isinstance(value, dict) and key in value:
            value = value[key]
        else:
            die(f"{src}: Could not extract value, error: No value at that key path or invalid key path: {keypath}", 1)
    if fmt == "raw":
        if isinstance(value, bool):
            text = "true" if value else "false"
        elif isinstance(value, (int, str)):
            text = str(value)
        else:
            text = "<collection: the script must not read raw collections>"
        payload = (text + "\n").encode()
    elif fmt == "xml1":
        payload = plistlib.dumps(value, fmt=plistlib.FMT_XML)
    else:
        die("fake plutil: format not simulated", 2)
    if out == "-":
        sys.stdout.buffer.write(payload)
    else:
        with open(out, "wb") as f:
            f.write(payload)

def nvtarget(s, part_uuid, group):
    return f"EF57347C-0000-AA11-AA11-00306543ECAC:{part_uuid}:{group}"

def bless(args):
    s = load()
    if args == ["--getBoot"]:
        for c in containers(s):
            for v in c["volumes"]:
                if v["uuid"] == s["boot"].get("volume"):
                    print("/dev/" + v["id"])
                    return
        die("Could not determine boot device", 3)
    if args[:3] == ["--mount", "/", "--setBoot"]:
        rest = args[3:]
        nextonly = rest[:1] == ["--nextonly"]
        if nextonly:
            rest = rest[1:]
        if len(rest) != 3 or rest[0] != "--user" or rest[2] != "--stdinpass":
            die("fake bless: form not simulated", 2)
        line = sys.stdin.readline().rstrip("\n")
        log(f"bless{' --nextonly' if nextonly else ''} --user {rest[1]}")
        if rest[1] != s["owner"] or line != s["password"]:
            die("Could not authenticate user. Could not set boot device property: 0xe00002e2", 3)
        c = mac_container(s)
        target = nvtarget(s, c["store"], system_volume(c)["group"])
        if nextonly:
            s["nvram"]["alt-boot-volume"] = target
        else:
            s["nvram"]["boot-volume"] = target
            s["boot"]["volume"] = system_volume(c)["uuid"]
        save(s)
        return
    die("fake bless: not simulated: " + " ".join(args), 2)

def nvram(args):
    if args != ["-p"]:
        die("fake nvram: not simulated", 2)
    s = load()
    print("auto-boot\ttrue")
    for k in sorted(s["nvram"]):
        print(f"{k}\t{s['nvram'][k]}")
    print("SystemAudioVolume\t%80")

tool, args = os.path.basename(sys.argv[0]), sys.argv[1:]
{"diskutil": diskutil, "plutil": plutil_main, "bless": bless, "nvram": nvram}[tool](args)
PY
# argv[0] picks the tool: one copy of the fake per name
for tool in diskutil plutil bless nvram; do
  mkdir -p "$t/fk/$tool"; cp "$t/fakemac.py" "$t/fk/$tool/$tool"
  printf '#!/bin/sh\nexec python3 -I %s/fk/%s/%s "$@"\n' "$t" "$tool" "$tool" >"$mock/$tool"
done
printf '#!/bin/sh\ncase $1 in -s) echo Darwin ;; -m) echo arm64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$mock/uname"
printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' >"$mock/id"
chmod +x "$mock"/*

# ---- disk layouts ------------------------------------------------------------
cat >"$t/mkstate.py" <<'PY'
import json, sys
GiB, MiB = 1 << 30, 1 << 20
DISK = 994662584320
U = lambda n: "%08X-0000-4000-8000-%012X" % (n, n)
G_MAC, G_STUB, G_STUB2 = U(0x9001), U(0x9002), U(0x9003)

def layout(case):
    s = {"disk": "disk0", "disk_size": DISK, "mac_ref": "disk3", "mounts": {}, "esp_files": {},
         "nvram": {}, "boot": {}, "owner": "admin", "password": "c0rrect horse*?"}
    P = []
    def part(slot, uuid, typ, off, size, name=""):
        P.append({"slot": slot, "uuid": uuid, "type": typ, "offset": off, "size": size, "name": name})
    def stub_container(ref, store, name, group, vbase):
        return {"ref": ref, "uuid": U(vbase), "store": store, "volumes": [
            {"uuid": U(vbase + 1), "name": name, "roles": ["System"], "group": group},
            {"uuid": U(vbase + 2), "name": name + " - Data", "roles": ["Data"], "group": group},
            {"uuid": U(vbase + 3), "name": "Preboot", "roles": ["Preboot"]},
            {"uuid": U(vbase + 4), "name": "Recovery", "roles": ["Recovery"]}]}
    isc, mac, rec = U(1), U(2), U(3)
    part(1, isc, "Apple_APFS_ISC", 24576, 524288000)
    mac_off = 24576 + 524288000
    rec_size = 5368709120
    rec_off = DISK - rec_size
    mac_c = {"ref": "disk3", "uuid": U(0x30), "store": mac, "volumes": [
        {"uuid": U(0x31), "name": "Macintosh HD", "roles": ["System"], "group": G_MAC},
        {"uuid": U(0x32), "name": "Macintosh HD - Data", "roles": ["Data"], "group": G_MAC},
        {"uuid": U(0x33), "name": "Preboot", "roles": ["Preboot"]},
        {"uuid": U(0x34), "name": "Recovery", "roles": ["Recovery"]},
        {"uuid": U(0x35), "name": "VM", "roles": ["VM"]},
        {"uuid": U(0x36), "name": "Update", "roles": ["Update"]}]}
    isc_c = {"ref": "disk1", "uuid": U(0x10), "store": isc, "volumes": [
        {"uuid": U(0x11), "name": "iSCPreboot", "roles": ["Preboot"]},
        {"uuid": U(0x12), "name": "xART", "roles": ["xART"]},
        {"uuid": U(0x13), "name": "Hardware", "roles": ["Hardware"]}]}
    rec_c = {"ref": "disk2", "uuid": U(0x20), "store": rec, "volumes": [
        {"uuid": U(0x21), "name": "Recovery", "roles": ["Recovery"]}]}
    C = [isc_c, rec_c]
    stub, esp = U(4), U(5)
    mac_target = lambda: f"EF57347C-0000-AA11-AA11-00306543ECAC:{mac}:{G_MAC}"
    stub_target = lambda: f"EF57347C-0000-AA11-AA11-00306543ECAC:{stub}:{G_STUB}"
    s["nvram"]["boot-volume"] = mac_target()
    s["boot"]["volume"] = U(0x31)
    esp_files = {"m1n1/boot.bin": "m1n1 stage 2", "asahi/stub_info.json": '{"vgid": "%s", "name": "x"}' % G_STUB.lower()}
    if case == "free":
        part(2, mac, "Apple_APFS", mac_off, 500 * 10**9)
        part(3, rec, "Apple_APFS_Recovery", rec_off, rec_size)
        C += [mac_c]
    elif case in ("engine", "omarchy", "foreign", "twostubs", "noevidence", "vgid", "bigesp", "secondmac"):
        mac_size = 500 * 10**9
        part(2, mac, "Apple_APFS", mac_off, mac_size)
        off = mac_off + mac_size
        name = "Omarchy" if case == "omarchy" else "SmartRoom Firmware"
        stub_size = 2499805184
        part(4, stub, "Apple_APFS", off, stub_size); off += stub_size
        if case == "foreign":
            part(9, U(9), "Microsoft Basic Data", off, 8 * GiB, "STUFF"); off += 8 * GiB
        if case == "twostubs":
            part(9, U(9), "Apple_APFS", off, stub_size); off += stub_size
            C.append(stub_container("disk6", U(9), "Second", G_STUB2, 0x60))
        if case == "secondmac":
            part(9, U(9), "Apple_APFS", off, 100 * 10**9); off += 100 * 10**9
            other = stub_container("disk6", U(9), "Macintosh HD 2", G_STUB2, 0x60)
            other["volumes"].append({"uuid": U(0x6f), "name": "VM", "roles": ["VM"]})
            C.append(other)
        esp_size = 3 * GiB if case == "bigesp" else 500 * MiB
        part(5, esp, "EFI", off, esp_size, "EFI - SMART"); off += esp_size
        part(6, U(6), "Linux Filesystem", off, 2 * GiB); off += 2 * GiB
        part(7, rec, "Apple_APFS_Recovery", rec_off, rec_size)
        part(8, U(7), "0FC63DAF-8483-4772-8E79-3D69D8477DE4", off, rec_off - off)
        C += [mac_c, stub_container("disk4", stub, name, G_STUB, 0x40)]
        if case == "noevidence":
            esp_files = {"EFI/BOOT/BOOTAA64.EFI": "limine"}
        if case == "vgid":
            esp_files["asahi/stub_info.json"] = '{"vgid": "%s"}' % G_STUB2
        if case == "omarchy":
            s["nvram"]["alt-boot-volume"] = stub_target()
            s["mounts"][esp] = sys.argv[3]          # macOS already mounted the ESP
    elif case == "legacy":
        part(2, mac, "Apple_APFS", 524288000, 494384795648)
        part(3, stub, "Apple_APFS", 494909083648, 2684354560)
        part(4, esp, "EFI", 497593438208, 2147483648, "EFI - SMART")
        part(5, U(6), "0FC63DAF-8483-4772-8E79-3D69D8477DE4", 499740921856, 404000000000)
        P[0]["offset"], P[0]["size"] = 24576, 524263424
        s["disk_size"] = 903740921856 + 5368709120
        part(6, rec, "Apple_APFS_Recovery", 903740921856, 5368709120)
        C += [mac_c, stub_container("disk4", stub, "SmartRoomOS", G_STUB, 0x40)]
        s["nvram"]["boot-volume"] = stub_target()
        s["boot"]["volume"] = U(0x41)
    else:
        raise SystemExit("unknown case " + case)
    s["partitions"], s["containers"] = P, C
    s["esp_files"][esp] = esp_files
    s["protected"] = [isc, mac, rec]
    return s

json.dump(layout(sys.argv[1]), open(sys.argv[2], "w"), indent=1, sort_keys=True)
PY
setup() { : >"$FAKE_LOG"; mkdir -p "$t/espmount"; python3 -I "$t/mkstate.py" "$1" "$FAKE_STATE" "$t/espmount"
  if [[ $1 == omarchy ]]; then mkdir -p "$t/espmount/m1n1"; echo m1n1 >"$t/espmount/m1n1/boot.bin"; fi; }
run() { "$tbash" "$t/rf" "$@" >"$t/out" 2>&1; }
q() { python3 -I -c "import json,sys; s=json.load(open('$FAKE_STATE')); print(eval(sys.argv[1]))" "$1"; }
layout() { q "sorted((p['offset'], p['size'], p['uuid']) for p in s['partitions'])"; }
mutations() { grep -c '^MUTATE' "$FAKE_LOG" || true; }
never_protected() {
  local u
  for u in $(q "' '.join(s['protected'])"); do
    ! grep -E '^(MUTATE (deleteContainer|eraseVolume)|unmount|mount) ' "$FAKE_LOG" | grep -q "$u" ||
      fail "a protected partition ($u) was passed to a disk change: $(cat "$FAKE_LOG")"
  done
}
grown() { # macOS store size == Recovery offset - macOS offset, nothing in between
  [[ $(q "len(s['partitions'])") == 3 ]] || fail "partitions left: $(layout)"
  [[ $(q "[p['size'] for p in s['partitions'] if p['type']=='Apple_APFS'][0]") == \
     $(q "[p['offset'] for p in s['partitions'] if p['type']=='Apple_APFS_Recovery'][0] - [p['offset'] for p in s['partitions'] if p['type']=='Apple_APFS'][0]") ]] ||
    fail "macOS did not grow to the Recovery offset: $(layout)"
}

# ---- 0. the script calls none of the tools that open the CLT dialog ---------
bad=$(sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "$script" |
  grep -nE '(^|[;&|({`[:space:]]|\$\()(python3?|git|clang|cc|gcc|xcrun|strings|otool|make|jq|perl|ruby|swift)([[:space:]]|$|\))' || true)
[[ -z $bad ]] || fail "the script calls a developer tool: $bad"
grep -q '^#!/bin/bash$' "$script" || fail "not /bin/bash"
echo "ok - calls only macOS system tools (no python3/git/clang/xcrun/strings/jq/perl)"

# ---- 1. fresh Engine layout, startup is macOS --------------------------------
setup engine
before=$(layout)
run || fail "dry run failed"
[[ $(layout) == "$before" && $(mutations) == 0 ]] || fail "the dry run changed the disk"
grep -q 'found "SmartRoom Firmware"' "$t/out" && grep -q 'Dry run: nothing changed' "$t/out" || fail "dry run report"
grep -q 'startup disk: the running macOS' "$t/out" || fail "startup not recognized as macOS"
! grep -q bless "$FAKE_LOG" || fail "blessed during a dry run"
run --yes </dev/null || fail "removal failed"
grown; never_protected
[[ $(grep -c '^MUTATE' "$FAKE_LOG") == 5 ]] || fail "expected 4 deletions and one resize: $(cat "$FAKE_LOG")"
grep -q '^MUTATE deleteContainer disk0s3 ' "$FAKE_LOG" && grep -q '^MUTATE eraseVolume disk0s3 ' "$FAKE_LOG" ||
  fail "the ESP was not tracked to its new number after the stub went: $(cat "$FAKE_LOG")"
[[ $(sed -n 1p "$FAKE_LOG" | cut -d' ' -f1-2) == "mount disk0s4" ]] || fail "evidence not read first: $(cat "$FAKE_LOG")"
! grep -q bless "$FAKE_LOG" || fail "blessed although macOS was the startup disk"
grep -q 'done: "SmartRoom Firmware" removed' "$t/out" || fail "no success line"
ls "$t/root/smartroom-remove-firmware/"run-*.log >/dev/null || fail "no run log"
echo "ok - Engine layout: dry run changes nothing; --yes removes stub, ESP, Boot, Root by UUID and grows macOS to Recovery"

# ---- 2. Mac Studio legacy layout, the stub is the startup disk --------------
setup legacy
before=$(layout)
run --yes </dev/null && fail "removed without --owner while the stub is the startup disk"
grep -q 'needs a machine owner' "$t/out" || fail "wrong refusal"
[[ $(layout) == "$before" && $(mutations) == 0 ]] || fail "changed the disk without --owner"
printf 'wrong\n' | run --owner admin --yes && fail "went on after a wrong password"
grep -q 'Nothing was deleted' "$t/out" || fail "wrong-password report"
! grep -q 'wrong' "$t/out" || fail "the password appeared in the output"
[[ $(layout) == "$before" && $(mutations) == 0 ]] || fail "deleted after a failed bless"
run --owner admin </dev/null || fail "legacy dry run"
grep -q 'found "SmartRoomOS"' "$t/out" && grep -q '0. set the running macOS as the startup disk' "$t/out" || fail "legacy plan"
printf '%s\n' 'c0rrect horse*?' | run --owner admin --yes || fail "legacy removal with the right password"
grep -q '^bless --user admin$' "$FAKE_LOG" || fail "macOS not blessed"
[[ $(grep -n bless "$FAKE_LOG" | tail -n 1 | cut -d: -f1) -lt $(grep -n '^MUTATE' "$FAKE_LOG" | head -n 1 | cut -d: -f1) ]] ||
  fail "deleted before blessing macOS"
grown; never_protected
[[ $(q "s['boot']['volume']") == $(q "'%08X-0000-4000-8000-%012X' % (0x31, 0x31)") ]] || fail "macOS is not the startup disk"
echo "ok - legacy SmartRoomOS layout: refuses without --owner, stops on a wrong password, blesses macOS first, then removes"

# ---- 3. Omarchy stub, next start set to it, ESP already mounted --------------
setup omarchy
printf '%s\n' 'c0rrect horse*?' | run --owner admin --yes || fail "Omarchy removal"
grep -q '^bless --user admin$' "$FAKE_LOG" && grep -q '^bless --nextonly --user admin$' "$FAKE_LOG" || fail "next start not blessed: $(cat "$FAKE_LOG")"
! grep -q '^mount ' "$FAKE_LOG" || fail "mounted an ESP that macOS had mounted"
grep -q 'found "Omarchy"' "$t/out" || fail "Omarchy name"
grown; never_protected
echo "ok - Omarchy stub with alt-boot-volume: blesses --nextonly too; reads an already mounted ESP in place"

# ---- 4. refusals ---------------------------------------------------------------
for c in foreign twostubs secondmac noevidence vgid bigesp; do
  setup $c
  before=$(layout)
  printf '%s\n' 'c0rrect horse*?' | run --owner admin --yes && fail "$c accepted"
  [[ $(layout) == "$before" && $(mutations) == 0 ]] || fail "$c: the disk changed"
  ! grep -q bless "$FAKE_LOG" || fail "$c: blessed"
  never_protected
  case $c in
    foreign) want="not part of an installation" ;;
    twostubs) want="2 stubs" ;;
    secondmac) want="another macOS" ;;
    noevidence) want="neither m1n1/boot.bin nor asahi/stub_info.json" ;;
    vgid) want="names volume group" ;;
    bigesp) want="larger than 2.5 GiB" ;;
  esac
  grep -q "$want" "$t/out" || fail "$c: wrong refusal"
done
echo "ok - refuses a foreign partition, two stubs, a second macOS, an unproven ESP, a vgid mismatch and a 3 GiB ESP, changing nothing"

# ---- 5. free space only --------------------------------------------------------
setup free
run || fail "free-space dry run"
[[ $(mutations) == 0 ]] || fail "free-space dry run changed the disk"
run --yes </dev/null || fail "free-space grow"
grown; never_protected
[[ $(mutations) == 1 ]] || fail "free space: expected one resize"
echo "ok - free space only: grows macOS to Recovery"

# ---- usage ---------------------------------------------------------------------
run --bogus && fail "unknown argument accepted"
run --owner 'a b' && fail "a bad owner name accepted"
echo "ok - refuses bad arguments"
echo "all remove-firmware tests passed (bash under test: $("$tbash" -c 'echo $BASH_VERSION'))"
