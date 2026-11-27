#!/bin/bash
# smartroom/network-camera-check against fake repositories and image roots: the
# good ones pass; a missing package, a module for another kernel, a missing or
# changed drop-in, an overriding drop-in or a user outside video fails. The
# image's package list and build-packages carry the module.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check=$here/../network-camera-check
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
expect() { # pass|fail WHAT ARGS...
  local want=$1 what=$2
  shift 2
  if bash "$check" "$@" >"$t/out" 2>&1; then
    [[ $want == pass ]] && ok "$what" || bad "$what (passed): $(grep FAIL "$t/out" || cat "$t/out")"
  else
    [[ $want == fail ]] && ok "$what" || bad "$what: $(grep FAIL "$t/out" || cat "$t/out")"
  fi
}
kver=7.3.0-0sredge4-1-ARCH
kpkg=7.3.0.aurora0sredge4-1

mkpkg() { # DIR NAME VERSION [DEPEND]
  local d=$1/build-$2 out=$1/$2-$3-aarch64.pkg.tar.zst
  mkdir -p "$d"
  { printf 'pkgname = %s\npkgver = %s\n' "$2" "$3"; [[ -z ${4-} ]] || printf 'depend = %s\n' "$4"; } >"$d/.PKGINFO"
  bsdtar -C "$d" --zstd -cf "$out" .PKGINFO
  rm -rf "$d"
}
mkdir -p "$t/repo"
mkpkg "$t/repo" linux-aurora "$kpkg"
mkpkg "$t/repo" v4l2loopback-aurora "0.15.4_7.3.0.aurora0sredge4.1-1" "linux-aurora=$kpkg"
expect pass "a repository with the module for its kernel passes" repo "$t/repo"
mkdir -p "$t/old"
mkpkg "$t/old" linux-aurora "7.3.0.aurora0sredge5-1"
mkpkg "$t/old" v4l2loopback-aurora "0.15.4_7.3.0.aurora0sredge4.1-1" "linux-aurora=$kpkg"
expect fail "a module built for the previous kernel fails" repo "$t/old"
mkdir -p "$t/none"
mkpkg "$t/none" linux-aurora "$kpkg"
expect fail "a repository without the module fails" repo "$t/none"

mkroot() { # DIR : a root that passes
  local r=$1
  mkdir -p "$r/var/lib/pacman/local/v4l2loopback-aurora-0.15.4_7.3.0.aurora0sredge4.1-1" \
    "$r/usr/lib/modules/$kver/extra" "$r/etc/modprobe.d" "$r/etc/modules-load.d" "$r/usr/lib/modprobe.d"
  printf 'x\0vermagic=%s SMP preempt mod_unload aarch64\0name=v4l2loopback\0' "$kver" >"$r/usr/lib/modules/$kver/extra/v4l2loopback.ko"
  printf 'extra/v4l2loopback.ko: kernel/drivers/media/common/videobuf2/videobuf2-common.ko\n' >"$r/usr/lib/modules/$kver/modules.dep"
  printf '# network camera\noptions v4l2loopback devices=1 video_nr=30 card_label="Network camera" exclusive_caps=1\n' \
    >"$r/etc/modprobe.d/smartroom-network-camera.conf"
  printf '# network camera\nv4l2loopback\n' >"$r/etc/modules-load.d/smartroom-network-camera.conf"
  printf 'options brcmfmac roamoff=1\n' >"$r/etc/modprobe.d/brcmfmac.conf"
  chmod 0644 "$r/etc/modprobe.d/"*.conf "$r/etc/modules-load.d/"*.conf
  printf 'root:x:0:\nvideo:x:985:smartroomcontroller\nuucp:x:986:smartroomcontroller\n' >"$r/etc/group"
}
if (( EUID == 0 )); then owned=1; else owned=0; fi
mkroot "$t/good"
if (( owned )); then
  expect pass "a root with the package, module, drop-ins and video group passes" root "$t/good" "$kver"
else
  # Unprivileged: the fixture files are the tester's, so only the owner lines fail.
  bash "$check" root "$t/good" "$kver" >"$t/out" 2>&1 || true
  if [[ $(grep -c '^FAIL' "$t/out") == 2 && $(grep '^FAIL' "$t/out" | grep -vc "is root's, 0644") == 0 ]]; then
    ok "a root with the package, module, drop-ins and video group passes (but for the owner, not root here)"
  else
    bad "the good root: $(grep FAIL "$t/out")"
  fi
fi
case_root() { # NAME WHAT EDIT
  mkroot "$t/$1"
  (cd "$t/$1" && eval "$3")
  bash "$check" root "$t/$1" "$kver" >"$t/out" 2>&1 || true
  if grep '^FAIL' "$t/out" | grep -v "is root's, 0644" | grep -q .; then ok "$2"; else bad "$2: $(cat "$t/out")"; fi
}
case_root nopkg "the package missing fails" 'rm -r var/lib/pacman/local/v4l2loopback-aurora-*'
case_root noko "the module missing fails" "rm usr/lib/modules/$kver/extra/v4l2loopback.ko"
case_root otherk "a module for another kernel fails" \
  "printf 'x\0vermagic=7.3.0-0sredge3-1-ARCH SMP preempt mod_unload aarch64\0' >usr/lib/modules/$kver/extra/v4l2loopback.ko"
case_root nodep "a module depmod did not list fails" ": >usr/lib/modules/$kver/modules.dep"
case_root noconf "the modprobe drop-in missing fails" 'rm etc/modprobe.d/smartroom-network-camera.conf'
case_root nr "another video_nr fails" "sed -i 's/video_nr=30/video_nr=20/' etc/modprobe.d/smartroom-network-camera.conf"
case_root label "another label fails" "sed -i 's/Network camera/Camera/' etc/modprobe.d/smartroom-network-camera.conf"
case_root caps "exclusive_caps off fails" "sed -i 's/exclusive_caps=1/exclusive_caps=0/' etc/modprobe.d/smartroom-network-camera.conf"
case_root noload "the modules-load drop-in missing fails" 'rm etc/modules-load.d/smartroom-network-camera.conf'
case_root override "a later drop-in that sets v4l2loopback options fails" \
  "printf 'options v4l2loopback devices=4 video_nr=20,21,22,23\n' >etc/modprobe.d/smartroom-qa-v4l2loopback.conf"
case_root vendor "a vendor drop-in that sets v4l2loopback options fails" \
  "printf 'options v4l2loopback devices=2\n' >usr/lib/modprobe.d/v4l2loopback.conf"
case_root group "the Room Controller user outside video fails" "sed -i 's/^video:x:985:.*/video:x:985:/' etc/group"
if command -v zstd >/dev/null; then
  mkroot "$t/zst"
  zstd -q --rm "$t/zst/usr/lib/modules/$kver/extra/v4l2loopback.ko"
  bash "$check" root "$t/zst" "$kver" >"$t/out" 2>&1 || true
  grep -q "^PASS network camera: v4l2loopback module for $kver" "$t/out" && ok "a compressed module is read" || bad "a compressed module: $(cat "$t/out")"
fi

# The image installs it, build-packages builds or requires it, desk-check runs the check.
grep -qE '^v4l2loopback-aurora([[:space:]]|$)' "$here/../room/packages" && ok "room/packages installs v4l2loopback-aurora" ||
  bad "room/packages lacks v4l2loopback-aurora"
grep -q 'network-camera-check" repo' "$here/../build-packages" && grep -q 'AURORA_KERNEL_BUILD_DIR' "$here/../build-packages" &&
  ok "build-packages builds the module against the kernel it built and checks the pair" || bad "build-packages does not build or check v4l2loopback-aurora"
grep -q 'network-camera-check" root' "$here/../desk-check" && ok "desk-check checks the network camera" ||
  bad "desk-check does not run network-camera-check"
exit $fail
