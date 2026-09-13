#!/usr/bin/env python3
"""CI-only PTY harness for the interactive Hondo counter example."""

import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

TIMEOUT_SECONDS = 30
READY_MARKER = b"Count: 0"
INCREMENTAL_UPDATE = b"\x1b[1;8H1"
INITIAL_ROWS = 8
INITIAL_COLUMNS = 64
RESIZED_ROWS = 10
RESIZED_COLUMNS = 50
ORDERED_MARKERS = (
    b"\x1b[?1049h",
    b"\x1b[H",
    READY_MARKER,
    b"\x1b[H",
    INCREMENTAL_UPDATE,
    b"\x1b[?25h",
    b"\x1b[?1049l",
)


def set_winsize(fd: int, rows: int, columns: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def fail(message: str, output: bytes) -> None:
    sys.stderr.write(f"PTY smoke failed: {message}\n")
    sys.stderr.write(f"captured bytes: {output!r}\n")
    raise SystemExit(1)


def main() -> None:
    command = sys.argv[1:]
    if not command:
        raise SystemExit("usage: pty_smoke.py COMMAND [ARG ...]")

    pid, master_fd = pty.fork()
    if pid == 0:
        set_winsize(0, INITIAL_ROWS, INITIAL_COLUMNS)
        os.execvp(command[0], command)

    output = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    resize_sent = False
    resize_observed = False
    resize_search_start = 0
    sent_enter = False

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                fail("interactive counter timed out", bytes(output))

            readable, _, _ = select.select([master_fd], [], [], min(remaining, 0.25))
            if not readable:
                continue

            try:
                chunk = os.read(master_fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise

            if not chunk:
                break

            output.extend(chunk)
            if not resize_sent and READY_MARKER in output:
                resize_search_start = len(output)
                set_winsize(master_fd, RESIZED_ROWS, RESIZED_COLUMNS)
                resize_sent = True

            if resize_sent and not resize_observed:
                resize_index = output.find(b"\x1b[H", resize_search_start)
                if resize_index >= 0:
                    resize_observed = True
                    os.write(master_fd, b"\r")
                    sent_enter = True
    finally:
        os.close(master_fd)

    _, status = os.waitpid(pid, 0)
    if not resize_sent:
        fail("initial Count: 0 frame was never observed", bytes(output))
    if not resize_observed:
        fail("terminal resize did not trigger a fresh frame", bytes(output))
    if not sent_enter:
        fail("increment input was never sent", bytes(output))
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        fail(f"counter exited with status {status}", bytes(output))

    cursor = 0
    for marker in ORDERED_MARKERS:
        index = output.find(marker, cursor)
        if index < 0:
            fail(f"missing ordered marker {marker!r}", bytes(output))
        cursor = index + len(marker)

    sys.stdout.write("Hondo PTY resize + incremental-render smoke passed\n")


if __name__ == "__main__":
    main()
