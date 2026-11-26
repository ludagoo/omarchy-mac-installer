#!/bin/bash
# plan|install: run engine-install for the APFS physical store of / and a
# macOS short name. The owner is --owner or the console user. It is never
# a hard-coded account.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)

mode=
owner=
source_disk=
image_dir=
payload=
sha=
metadata=
firstboot=
restore=
no_firstboot=0
production=0
dry=0
engine=${SMARTROOM_ENGINE_INSTALL:-$here/mac/engine-install}

help() {
  cat <<'EOF'
Usage: smartroom/run-install.sh plan|install [options]

plan runs engine-install and stops before it writes (no --yes).
install passes --yes.

  --owner NAME            macOS short name. Default: the console user.
                          Names with spaces are refused.
  --source DISK           APFS physical store. Default: the store of /.
  --image-dir DIR         release directory (default: <repo>/image)
  --payload ZIP           os package zip (default: the one zip in the image dir)
  --sha256 HEX            payload sha256 (default: first field of image/SHA256)
  --installer-data JSON   default: <image-dir>/installer_data.json
  --firstboot-env FILE    default: <image-dir>/firstboot.env when that file exists
  --no-firstboot-env      do not pass a first-boot file
  --restore-image PATH    passed through to engine-install when set
  --production            passed through to engine-install
  --engine PATH           engine-install to run
  --dry-run               print the engine-install command and do not run it

The owner's password is read by engine-install from the terminal. This script
does not store it. Set SMARTROOM_RUN_INSTALL_NOSUDO=1 to run engine-install
without sudo (tests).
EOF
}

die() { echo "run-install: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    --dry-run) dry=1; shift ;;
    --no-firstboot-env) no_firstboot=1; shift ;;
    --production) production=1; shift ;;
    --owner) owner=${2:?}; shift 2 ;;
    --source) source_disk=${2:?}; shift 2 ;;
    --image-dir) image_dir=${2:?}; shift 2 ;;
    --payload) payload=${2:?}; shift 2 ;;
    --sha256) sha=${2:?}; shift 2 ;;
    --installer-data) metadata=${2:?}; shift 2 ;;
    --firstboot-env) firstboot=${2:?}; shift 2 ;;
    --restore-image) restore=${2:?}; shift 2 ;;
    --engine) engine=${2:?}; shift 2 ;;
    plan|install)
      [ -z "$mode" ] || die "pass plan or install once"
      mode=$1
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$mode" ] || die "pass plan or install (see --help)"
image_dir=${image_dir:-${SMARTROOM_IMAGE_DIR:-$repo/image}}

console_user() {
  local name=
  if command -v scutil >/dev/null 2>&1; then
    name=$(scutil <<<'show State:/Users/ConsoleUser' | sed -n 's/.*kCGSSessionUserNameKey : //p' | head -1)
  fi
  if [ -z "$name" ] || [ "$name" = "loginwindow" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
      name=$(stat -f '%Su' /dev/console 2>/dev/null || true)
    else
      name=$(stat -c '%U' /dev/console 2>/dev/null || true)
    fi
  fi
  printf '%s' "$name"
}

if [ -z "$owner" ]; then
  owner=$(console_user)
fi
[ -n "$owner" ] || die "could not detect the console user; pass --owner"
case "$owner" in
  *[!A-Za-z0-9._-]*)
    die "owner names with spaces are not supported; pass a macOS short name (--owner)"
    ;;
esac
[ "${#owner}" -le 255 ] || die "--owner is too long"

if [ -z "$source_disk" ]; then
  command -v diskutil >/dev/null 2>&1 || die "diskutil is required to find the APFS store of /; pass --source"
  source_disk=$(diskutil info / | sed -n 's/^[[:space:]]*APFS Physical Store:[[:space:]]*//p' | head -1)
fi
[ -n "$source_disk" ] || die "could not read the APFS physical store of /; pass --source"
case "$source_disk" in
  disk[0-9]*s[0-9]*) ;;
  *) die "--source must be an APFS physical store such as disk0s2" ;;
esac

if [ -z "$payload" ]; then
  shopt -s nullglob
  zips=("$image_dir"/smartroom-firmware-*-os-package.zip)
  shopt -u nullglob
  [ "${#zips[@]}" -eq 1 ] || die "pass --payload (found ${#zips[@]} firmware zips in $image_dir)"
  payload=${zips[0]}
fi
[ -f "$payload" ] || die "payload not found: $payload"

if [ -z "$sha" ]; then
  [ -f "$image_dir/SHA256" ] || die "pass --sha256 or provide $image_dir/SHA256"
  sha=$(awk 'NF { print $1; exit }' "$image_dir/SHA256")
fi
if [[ ! $sha =~ ^[0-9a-fA-F]{64}$ ]]; then
  die "--sha256 must be 64 hex digits"
fi

metadata=${metadata:-$image_dir/installer_data.json}
[ -f "$metadata" ] || die "installer data not found: $metadata"

if [ "$no_firstboot" = 0 ] && [ -z "$firstboot" ] && [ -f "$image_dir/firstboot.env" ]; then
  firstboot=$image_dir/firstboot.env
fi

[ -f "$engine" ] || die "engine-install not found: $engine"

args=(--payload "$payload" --sha256 "$sha" --installer-data "$metadata" --owner "$owner" --source "$source_disk")
if [ -n "$firstboot" ]; then
  args+=(--firstboot-env "$firstboot")
fi
if [ -n "$restore" ]; then
  args+=(--restore-image "$restore")
fi
if [ "$production" = 1 ]; then
  args+=(--production)
fi
if [ "$mode" = "install" ]; then
  args+=(--yes)
fi

if [ "$dry" = 1 ]; then
  printf 'dry-run: mode=%s\n' "$mode"
  printf 'dry-run: owner=%s\n' "$owner"
  printf 'dry-run: source=%s\n' "$source_disk"
  printf 'dry-run:'
  printf ' %q' "$engine" "${args[@]}"
  printf '\n'
  echo "dry-run: no changes"
  exit 0
fi

if [ "$(id -u)" -ne 0 ] && [ -z "${SMARTROOM_RUN_INSTALL_NOSUDO:-}" ]; then
  exec sudo -- "$engine" "${args[@]}"
fi
exec "$engine" "${args[@]}"
