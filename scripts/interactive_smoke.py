#!/usr/bin/env python3
"""Launch Zim in a real PTY, verify it stays alive, then quit with Ctrl-C."""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time


def fail(message: str, pid: int | None = None) -> int:
    print(f"interactive-smoke: {message}", file=sys.stderr)
    if pid is not None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    return 1


def wait_status(pid: int) -> int | None:
    finished, status = os.waitpid(pid, os.WNOHANG)
    return status if finished == pid else None


def describe_status(status: int) -> str:
    if os.WIFSIGNALED(status):
        return f"terminated by signal {os.WTERMSIG(status)}"
    if os.WIFEXITED(status):
        return f"exited with status {os.WEXITSTATUS(status)}"
    return f"ended with wait status {status}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: interactive_smoke.py /path/to/zim", file=sys.stderr)
        return 2

    executable = os.path.abspath(sys.argv[1])
    pid, master = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env.setdefault("TERM", "xterm-256color")
        os.execve(executable, [executable], env)

    try:
        # The original macOS regression traps during QuickJS/Hondo TUI startup.
        # Staying alive long enough to render a frame proves we crossed that path.
        startup_deadline = time.monotonic() + 3.0
        saw_output = False
        while time.monotonic() < startup_deadline:
            status = wait_status(pid)
            if status is not None:
                return fail(f"process died during startup: {describe_status(status)}")
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 8192)
                except OSError:
                    chunk = b""
                if chunk:
                    saw_output = True
            if saw_output and time.monotonic() + 0.5 >= startup_deadline:
                break

        status = wait_status(pid)
        if status is not None:
            return fail(f"process died before quit request: {describe_status(status)}")

        os.write(master, b"\x03")
        quit_deadline = time.monotonic() + 3.0
        while time.monotonic() < quit_deadline:
            status = wait_status(pid)
            if status is not None:
                if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
                    print("interactive-smoke: startup and Ctrl-C shutdown passed")
                    return 0
                return fail(f"unexpected shutdown: {describe_status(status)}")
            select.select([master], [], [], 0.1)

        return fail("timed out waiting for Ctrl-C shutdown", pid)
    finally:
        try:
            os.close(master)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
