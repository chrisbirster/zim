#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import os
import platform
import shutil
import sys
import tarfile
import tempfile
import zipfile


def normalized_platform() -> str:
    value = platform.system().lower()
    if value == "darwin":
        return "macos"
    if value == "windows":
        return "windows"
    if value == "linux":
        return "linux"
    raise SystemExit(f"unsupported platform: {value}")


def normalized_arch() -> str:
    value = platform.machine().lower()
    if value in {"amd64", "x86_64"}:
        return "x86_64"
    if value in {"arm64", "aarch64"}:
        return "aarch64"
    raise SystemExit(f"unsupported architecture: {value}")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    os_name = normalized_platform()
    arch = normalized_arch()
    binary_name = "zim.exe" if os_name == "windows" else "zim"
    binary = root / "zig-out" / "bin" / binary_name
    if not binary.exists():
        raise SystemExit(f"built binary not found: {binary}")

    dist = root / "dist"
    if dist.exists():
        shutil.rmtree(dist)
    dist.mkdir()

    stem = f"zim-{os_name}-{arch}"
    with tempfile.TemporaryDirectory(prefix="zim-package-") as temp:
        staging = Path(temp) / stem
        staging.mkdir()
        shutil.copy2(binary, staging / binary_name)
        for name in ("README.md", "LICENSE"):
            shutil.copy2(root / name, staging / name)
        install_doc = root / "docs" / "INSTALL.md"
        if install_doc.exists():
            shutil.copy2(install_doc, staging / "INSTALL.md")

        if os_name == "windows":
            archive = dist / f"{stem}.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
                for path in staging.rglob("*"):
                    if path.is_file():
                        output.write(path, Path(stem) / path.relative_to(staging))
        else:
            archive = dist / f"{stem}.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                output.add(staging, arcname=stem)

    print(archive)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
