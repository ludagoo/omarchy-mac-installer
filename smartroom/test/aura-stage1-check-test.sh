#!/bin/bash
# The aura stage-1 recognizer, offline: a real aura raw image passes, and
# m1n1's copy of the same path (config magic, no aura-try) does not.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check=$here/../../image-builder/builder/aura_stage1.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$check" --write-fixture "$work/stage1.bin"
python3 "$check" stage1 "$work/stage1.bin"
printf 'second stage aura-try bundle\n' >"$work/boot.bin"
python3 "$check" stage2 "$work/boot.bin"
python3 "$check" --write-m1n1-fixture "$work/m1n1.bin"
if python3 "$check" stage1 "$work/m1n1.bin" >/dev/null 2>&1; then
  echo "m1n1 fixture was accepted as aura" >&2
  exit 1
fi
printf 'no marker\n' >"$work/empty-stage2"
if python3 "$check" stage2 "$work/empty-stage2" >/dev/null 2>&1; then
  echo "a stage 2 without aura-try was accepted" >&2
  exit 1
fi
echo "ok - aura stage 1 and stage 2 are recognized, and m1n1's copy is not"
