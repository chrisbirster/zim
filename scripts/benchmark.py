#!/usr/bin/env python3
"""Small, deterministic Daily Driver performance smoke for release CI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

STARTUP_BUDGET_SECONDS = 3.0
LARGE_FILE_BUDGET_SECONDS = 15.0
LARGE_FILE_BYTES = 5 * 1024 * 1024


def resolve_binary(value: str) -> Path:
    candidate = Path(value)
    if candidate.exists():
        return candidate
    if os.name == "nt" and candidate.suffix.lower() != ".exe":
        exe = candidate.with_suffix(".exe")
        if exe.exists():
            return exe
    raise SystemExit(f"benchmark binary not found: {value}")


def run(binary: Path, args: list[str], env: dict[str, str]) -> float:
    start = time.perf_counter()
    completed = subprocess.run(
        [str(binary), *args],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    elapsed = time.perf_counter() - start
    if completed.returncode != 0:
        sys.stderr.buffer.write(completed.stderr)
        raise SystemExit(f"zim benchmark command failed with {completed.returncode}")
    return elapsed


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: benchmark.py <zim-binary>", file=sys.stderr)
        return 2
    binary = resolve_binary(sys.argv[1]).resolve()

    with tempfile.TemporaryDirectory(prefix="zim-bench-") as temp:
        root = Path(temp)
        config = root / "config"
        config.mkdir()
        env = os.environ.copy()
        env["XDG_CONFIG_HOME"] = str(config)
        env["APPDATA"] = str(config)
        env["HOME"] = str(root)

        startup_samples = [run(binary, ["--headless"], env) for _ in range(5)]
        startup_median = statistics.median(startup_samples)

        large = root / "large.zig"
        line = b"pub const value: usize = 123456789; // zim large-file smoke\n"
        with large.open("wb") as handle:
            remaining = LARGE_FILE_BYTES
            while remaining > 0:
                chunk = line[:remaining]
                handle.write(chunk)
                remaining -= len(chunk)
        large_elapsed = run(binary, ["--headless", str(large)], env)

        result = {
            "startup_seconds_median": round(startup_median, 6),
            "startup_budget_seconds": STARTUP_BUDGET_SECONDS,
            "large_file_bytes": large.stat().st_size,
            "large_file_seconds": round(large_elapsed, 6),
            "large_file_budget_seconds": LARGE_FILE_BUDGET_SECONDS,
        }
        print(json.dumps(result, sort_keys=True))

        if startup_median > STARTUP_BUDGET_SECONDS:
            print("startup performance budget exceeded", file=sys.stderr)
            return 1
        if large_elapsed > LARGE_FILE_BUDGET_SECONDS:
            print("large-file performance budget exceeded", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
