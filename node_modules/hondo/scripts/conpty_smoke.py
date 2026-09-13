#!/usr/bin/env python3
"""CI-only native ConPTY harness for the interactive Hondo counter example."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import winpty

TIMEOUT_SECONDS = 30
POLL_SECONDS = 0.01
DRAIN_GRACE_SECONDS = 1.0
READY_MARKER = "Count: 0"
INCREMENTAL_UPDATE = "\x1b[1;8H1"
INITIAL_ROWS = 8
INITIAL_COLUMNS = 64
RESIZED_ROWS = 10
RESIZED_COLUMNS = 50
ORDERED_MARKERS = (
    "\x1b[?1049h",
    "\x1b[H",
    READY_MARKER,
    "\x1b[H",
    INCREMENTAL_UPDATE,
    "\x1b[?25h",
    "\x1b[?1049l",
)


def fail(message: str, output: str) -> None:
    diagnostic = f"ConPTY smoke failed: {message}\ncaptured text: {output!r}\n"
    Path("conpty-smoke-debug.txt").write_text(diagnostic, encoding="utf-8")
    sys.stderr.write(diagnostic)
    raise SystemExit(1)


def read_available(pty: winpty.PTY) -> str:
    try:
        return pty.read(blocking=False) or ""
    except winpty.WinptyError:
        # A non-blocking read can race an empty ConPTY output queue. EOF and
        # process liveness are checked separately below.
        return ""


def main() -> None:
    command = sys.argv[1:]
    if not command:
        raise SystemExit("usage: conpty_smoke.py COMMAND [ARG ...]")

    executable = os.path.abspath(command[0])
    cmdline = " " + subprocess.list2cmdline(command[1:]) if len(command) > 1 else None

    # Use the low-level PTY object so the test is unquestionably exercising
    # the native ConPTY backend and can poll output without the high-level
    # PtyProcess reader thread/EOF behavior.
    pty = winpty.PTY(
        INITIAL_COLUMNS,
        INITIAL_ROWS,
        backend=winpty.Backend.ConPTY,
    )
    if cmdline is None:
        pty.spawn(executable, cwd=os.getcwd())
    else:
        pty.spawn(executable, cwd=os.getcwd(), cmdline=cmdline)

    output = ""
    deadline = time.monotonic() + TIMEOUT_SECONDS
    resize_sent = False
    resize_observed = False
    resize_search_start = 0
    sent_enter = False

    while time.monotonic() < deadline:
        chunk = read_available(pty)
        if chunk:
            output += chunk

        if not resize_sent and READY_MARKER in output:
            resize_search_start = len(output)
            pty.set_size(RESIZED_COLUMNS, RESIZED_ROWS)
            resize_sent = True

        if resize_sent and not resize_observed:
            resize_index = output.find("\x1b[H", resize_search_start)
            if resize_index >= 0:
                resize_observed = True
                pty.write("\r")
                sent_enter = True

        if sent_enter and not pty.isalive():
            break

        time.sleep(POLL_SECONDS)
    else:
        fail("interactive counter timed out", output)

    # ConPTY can report the child exited before its final output reaches the
    # reader. Drain for a bounded grace period instead of requiring EOF.
    drain_deadline = time.monotonic() + DRAIN_GRACE_SECONDS
    while time.monotonic() < drain_deadline:
        chunk = read_available(pty)
        if chunk:
            output += chunk
            drain_deadline = time.monotonic() + DRAIN_GRACE_SECONDS
            continue
        time.sleep(POLL_SECONDS)

    if pty.isalive():
        fail("counter did not exit after activation input", output)

    exit_status = pty.get_exitstatus()
    if not resize_sent:
        fail("initial Count: 0 frame was never observed", output)
    if not resize_observed:
        fail("terminal resize did not trigger a fresh frame", output)
    if not sent_enter:
        fail("increment input was never sent", output)
    if exit_status not in (0, None):
        fail(f"counter exited with status {exit_status}", output)

    cursor = 0
    for marker in ORDERED_MARKERS:
        index = output.find(marker, cursor)
        if index < 0:
            fail(f"missing ordered marker {marker!r}", output)
        cursor = index + len(marker)

    sys.stdout.write("Hondo Windows ConPTY resize + incremental-render smoke passed\n")


if __name__ == "__main__":
    main()
