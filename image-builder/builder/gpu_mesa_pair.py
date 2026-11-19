#!/usr/bin/env python3
"""Check that the image's Mesa opens the GPU driver the image's kernel ships.

The Apple GPU driver registers with DRM under its module name: "asahi" up to
the 7.2 kernels, "aurora" from the 7.3 Aurora kernel on. Mesa's loader picks
the Gallium driver by that DRM name, so a libgallium that does not carry the
name as a driver string cannot open the GPU: EGL fails, and Hyprland aborts
at start, with or without a screen.

    gpu_mesa_pair.py MODULE LIBGALLIUM   exit 0 when LIBGALLIUM names MODULE's driver
    gpu_mesa_pair.py --write-fixtures DIR
"""
import gzip
import lzma
import re
import subprocess
import sys
from pathlib import Path


def module_bytes(path: Path) -> bytes:
    if path.suffix == ".zst":
        return subprocess.run(["zstd", "-dc", str(path)], check=True, capture_output=True).stdout
    if path.suffix == ".xz":
        return lzma.decompress(path.read_bytes())
    if path.suffix == ".gz":
        return gzip.decompress(path.read_bytes())
    return path.read_bytes()


def driver_name(module: bytes) -> str:
    names = set(re.findall(rb"(?<![^\0])name=([A-Za-z0-9_-]+)(?=\0)", module))
    if len(names) != 1:
        raise ValueError(f"expected one modinfo name, found {sorted(names)}")
    return names.pop().decode()


def mesa_opens(library: bytes, name: str) -> bool:
    return b"\0" + name.encode() + b"\0" in library


def write_fixtures(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    modinfo = b"\0license=GPL\0name=aurora\0vermagic=7.3.0-test SMP\0"
    (directory / "aurora.ko").write_bytes(b"\x7fELF" + modinfo)
    (directory / "aurora.ko.xz").write_bytes(lzma.compress(b"\x7fELF" + modinfo))
    (directory / "asahi.ko").write_bytes(b"\x7fELF\0name=asahi\0")
    (directory / "libgallium-asahi.so").write_bytes(b"\x7fELF\0kmsro\0asahi\0asahi-fence\0zink\0")
    (directory / "libgallium-aurora.so").write_bytes(b"\x7fELF\0kmsro\0asahi\0aurora\0zink\0")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--write-fixtures":
        write_fixtures(Path(argv[2]))
        return 0
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    name = driver_name(module_bytes(Path(argv[1])))
    print(f"kernel GPU driver: {name}")
    if not mesa_opens(Path(argv[2]).read_bytes(), name):
        print(f"{argv[2]} does not name the {name} driver", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
