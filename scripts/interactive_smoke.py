#!/usr/bin/env python3
"""Launch Zim in a real PTY and prove interactive startup stays alive."""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import time


def reap(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        try:
            finished, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if finished == pid:
            return
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


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

    reaped = False
    try:
        # The v1 dogfood regression trapped during QuickJS/Hondo initialization,
        # before the first TUI frame. A real PTY process that produces terminal
        # output and remains alive through this observation window has crossed
        # the failing startup path. Shutdown semantics are covered separately.
        startup_deadline = time.monotonic() + 3.0
        saw_output = False
        while time.monotonic() < startup_deadline:
            status = wait_status(pid)
            if status is not None:
                reaped = True
                print(
                    f"interactive-smoke: process died during startup: {describe_status(status)}",
                    file=sys.stderr,
                )
                return 1
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 8192)
                except OSError:
                    chunk = b""
                if chunk:
                    saw_output = True

        status = wait_status(pid)
        if status is not None:
            reaped = True
            print(
                f"interactive-smoke: process died after startup: {describe_status(status)}",
                file=sys.stderr,
            )
            return 1
        if not saw_output:
            print("interactive-smoke: process stayed alive but produced no terminal frame", file=sys.stderr)
            return 1

        print("interactive-smoke: interactive startup remained alive and rendered output")
        return 0
    finally:
        if not reaped:
            reap(pid)
        try:
            os.close(master)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
