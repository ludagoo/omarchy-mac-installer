#!/usr/bin/env python3
"""Recognize an aura first stage and an aura second stage.

m1n1-aurora also installs a file at usr/share/aura/stage1/aura-raw.bin, and
that file is a copy of m1n1. The config magic and the STACKBOT tail are not
enough. aura's trial marker string "aura-try" is in aura and not in that copy.

Stage 1 is the raw boot object the pinned Engine enrolls (STACKBOT, one
version-1 config block). Stage 2 is the ESP bundle (aura.bin plus device
trees and U-Boot). It is not a raw boot object; it only has to carry the
same marker string.
"""
import struct
import sys
from pathlib import Path

MAGIC = b"AURORA-S1-CFG01\0"
MARKER = b"aura-try"
BODY = struct.Struct("<II40s192s")
BLOCK = len(MAGIC) + BODY.size + 4


def stage1_ok(data: bytes) -> bool:
    if not data.endswith(b"STACKBOT") or data.count(MAGIC) != 1 or MARKER not in data:
        return False
    offset = data.index(MAGIC) + len(MAGIC)
    if offset + BODY.size + 4 > len(data) - 8:
        return False
    return struct.unpack_from("<I", data, offset)[0] == 1


def stream_contains(stream, needle: bytes) -> bool:
    if not needle:
        return True
    window = b""
    while chunk := stream.read(1 << 20):
        window += chunk
        if needle in window:
            return True
        if len(needle) > 1:
            window = window[-(len(needle) - 1):]
        else:
            window = b""
    return needle in window


def stage2_ok(data: bytes) -> bool:
    return bool(data) and MARKER in data


def fixture_stage1(*, marker: bool = True) -> bytes:
    body = BODY.pack(1, 0, b"", b";m1n1/boot.bin")
    prefix = b"preamble aura-try\n" if marker else b"preamble m1n1\n"
    return prefix + MAGIC + body + struct.pack("<I", 0) + b"STACKBOT"


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--write-fixture":
        Path(argv[2]).write_bytes(fixture_stage1())
        return 0
    if len(argv) == 3 and argv[1] == "--write-m1n1-fixture":
        Path(argv[2]).write_bytes(fixture_stage1(marker=False))
        return 0
    if len(argv) != 3 or argv[1] not in ("stage1", "stage2"):
        print("usage: aura_stage1.py stage1|stage2 FILE", file=sys.stderr)
        return 2
    path = Path(argv[2])
    if argv[1] == "stage1":
        ok = stage1_ok(path.read_bytes())
    else:
        with path.open("rb") as stream:
            ok = stream_contains(stream, MARKER)
    if not ok:
        print(f"{path} is not an aura {argv[1]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
