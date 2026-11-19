#!/bin/bash
# The GPU driver / Mesa pairing desk-check, offline: a Mesa that names the
# kernel's "aurora" driver passes, the published edge Mesa (only "asahi") does
# not, and the 7.2 kernel's "asahi" driver still passes with either.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check=$here/../../image-builder/builder/gpu_mesa_pair.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$check" --write-fixtures "$work"
fail=0
ok() { echo "ok - $*"; }
bad() { echo "not ok - $*"; fail=1; }
out=$(python3 "$check" "$work/aurora.ko" "$work/libgallium-aurora.so") && [[ $out == "kernel GPU driver: aurora" ]] &&
  ok "an aurora kernel with a Mesa that names aurora passes" ||
  bad "an aurora kernel with a Mesa that names aurora passes"
python3 "$check" "$work/aurora.ko.xz" "$work/libgallium-aurora.so" >/dev/null &&
  ok "a compressed module is read" || bad "a compressed module is read"
! python3 "$check" "$work/aurora.ko" "$work/libgallium-asahi.so" >/dev/null 2>&1 &&
  ok "an aurora kernel with an asahi-only Mesa fails" ||
  bad "an aurora kernel with an asahi-only Mesa fails"
python3 "$check" "$work/asahi.ko" "$work/libgallium-asahi.so" >/dev/null &&
  python3 "$check" "$work/asahi.ko" "$work/libgallium-aurora.so" >/dev/null &&
  ok "an asahi kernel passes with either Mesa" || bad "an asahi kernel passes with either Mesa"
printf '\0name=asahi\0name=aurora\0' >"$work/two.ko"
! python3 "$check" "$work/two.ko" "$work/libgallium-aurora.so" >/dev/null 2>&1 &&
  ok "a module with two names is refused" || bad "a module with two names is refused"
exit $fail
