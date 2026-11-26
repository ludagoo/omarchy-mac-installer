#!/usr/bin/env bash
# Linux checks for this fork: image-builder/test/all, smartroom/test/all,
# and the Engine python tests. No Mac, no root, no image build.
#
# smartroom/test/zero-touch-boot-test.sh reads the boot leaves from
# ludagoo/omarchy-mac-pkgs (branch smartroom/edge) unless SMARTROOM_MAC_BOOT
# is already set, or a sibling checkout ../omarchy-mac-pkgs is present.
#
# Skipped here, and said so below: Swift package tests (macOS), and anything
# that builds or boots a real image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

install_apt() {
  command -v apt-get >/dev/null || return 0
  local pkgs=()
  command -v python3 >/dev/null || pkgs+=(python3)
  command -v jq >/dev/null || pkgs+=(jq)
  command -v git >/dev/null || pkgs+=(git)
  command -v gpg >/dev/null || pkgs+=(gnupg)
  command -v bsdtar >/dev/null || pkgs+=(libarchive-tools)
  command -v xz >/dev/null || pkgs+=(xz-utils)
  command -v zstd >/dev/null || pkgs+=(zstd)
  command -v openssl >/dev/null || pkgs+=(openssl)
  command -v curl >/dev/null || pkgs+=(curl)
  command -v unzip >/dev/null || pkgs+=(unzip)
  command -v dtc >/dev/null || pkgs+=(device-tree-compiler)
  if [[ $EUID -eq 0 ]] && ! command -v runuser >/dev/null; then
    pkgs+=(util-linux passwd)
  fi
  ((${#pkgs[@]})) || return 0
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update
  as_root apt-get install -y "${pkgs[@]}"
}

install_apt

if [[ $EUID -eq 0 && -z ${SMARTROOM_CI_AS_USER:-} ]]; then
  if ! id -u 1000 >/dev/null 2>&1; then
    useradd --uid 1000 --create-home --shell /bin/bash ci
  fi
  user=$(id -nu 1000)
  home=$(getent passwd "$user" | cut -d: -f6)
  echo "test-ci: running as $user (uid 1000), not root"
  exec runuser -u "$user" -- env \
    SMARTROOM_CI_AS_USER=1 \
    HOME="$home" \
    PATH="$PATH" \
    SMARTROOM_MAC_BOOT="${SMARTROOM_MAC_BOOT:-}" \
    bash "$ROOT/bin/test-ci.sh"
fi

if [[ -z ${SMARTROOM_MAC_BOOT:-} ]]; then
  sibling="$ROOT/../omarchy-mac-pkgs/omarchy-mac-boot"
  if [[ -f $sibling/setup/limine-boot.sh ]]; then
    SMARTROOM_MAC_BOOT=$(cd "$sibling" && pwd)
  else
    dest=${TMPDIR:-/tmp}/omarchy-mac-pkgs-smartroom-edge
    if [[ ! -f $dest/omarchy-mac-boot/setup/limine-boot.sh ]]; then
      echo "test-ci: cloning ludagoo/omarchy-mac-pkgs smartroom/edge (boot leaves)"
      rm -rf "$dest"
      git clone --depth 1 --branch smartroom/edge \
        https://github.com/ludagoo/omarchy-mac-pkgs.git "$dest"
    fi
    SMARTROOM_MAC_BOOT=$dest/omarchy-mac-boot
  fi
  export SMARTROOM_MAC_BOOT
fi
[[ -f $SMARTROOM_MAC_BOOT/setup/limine-boot.sh ]] || {
  echo "test-ci: SMARTROOM_MAC_BOOT is not an omarchy-mac-boot checkout" >&2
  exit 1
}

echo "test-ci: image-builder/test/all"
bash "$ROOT/image-builder/test/all"
echo "test-ci: smartroom/test/all"
bash "$ROOT/smartroom/test/all"
echo "test-ci: Engine python tests"
# Run each file. Ubuntu's Python 3.12 will not discover a directory that
# has no __init__.py. Each file already ends in unittest.main().
engine_fail=0
for f in "$ROOT"/Engine/tests/test_*.py; do
  python3 "$f" || engine_fail=1
done
[[ $engine_fail -eq 0 ]]

echo "test-ci: skipping Swift package tests (Tests/, Recovery/Tests/). They need macOS. Not this runner."
echo "test-ci: skipping image build and boot. Those need an aarch64 Linux host with Docker."
echo "test-ci: passed"
