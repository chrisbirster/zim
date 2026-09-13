#!/usr/bin/env python3
"""Exercise Zim's release binary through a real PTY.

This intentionally follows the human dogfood path that exposed the v1 TUI
focus bug: start in a project, open the explorer, open a file, then use Ex
command mode to quit. A headless Editor.handleKey() test is not sufficient
for this contract because focus can be lost between Hondo native views.
"""

from __future__ import annotations

import os
import pty
import select
import signal
import sys
import tempfile
import time
from pathlib import Path


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


def drain(master: int, duration: float) -> bytes:
    deadline = time.monotonic() + duration
    chunks: list[bytes] = []
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if not readable:
            continue
        try:
            chunk = os.read(master, 8192)
        except OSError:
            break
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def wait_for_exit(pid: int, timeout: float) -> int | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = wait_status(pid)
        if status is not None:
            return status
        time.sleep(0.05)
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: interactive_smoke.py /path/to/zim", file=sys.stderr)
        return 2

    executable = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="zim-interactive-") as project:
        Path(project, "sample.txt").write_text(
            "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n",
            encoding="utf-8",
        )

        pid, master = pty.fork()
        if pid == 0:
            env = os.environ.copy()
            env.setdefault("TERM", "xterm-256color")
            os.chdir(project)
            os.execve(executable, [executable], env)

        reaped = False
        try:
            startup = drain(master, 3.0)
            status = wait_status(pid)
            if status is not None:
                reaped = True
                print(
                    f"interactive-smoke: process died during startup: {describe_status(status)}",
                    file=sys.stderr,
                )
                return 1
            if not startup:
                print("interactive-smoke: process stayed alive but produced no terminal frame", file=sys.stderr)
                return 1

            os.write(master, b" e")
            tree_frame = drain(master, 0.5)
            if b"FILES" not in tree_frame:
                print("interactive-smoke: <leader>e did not render the project tree", file=sys.stderr)
                return 1

            # The temp project contains one file, so Enter opens it. This is the
            # transition that previously left Hondo focus attached to the tree.
            os.write(master, b"\r")
            drain(master, 0.5)

            # Exercise a multi-key Vim sequence after the focus transition.
            os.write(master, b"Ggg")
            drain(master, 0.25)

            # Ex mode must be visible and executable after tree -> editor focus.
            os.write(master, b":q!")
            command_frame = drain(master, 0.5)
            if b":q!" not in command_frame:
                print("interactive-smoke: Ex command line was not visibly rendered", file=sys.stderr)
                return 1

            os.write(master, b"\r")
            status = wait_for_exit(pid, 2.0)
            if status is None:
                print("interactive-smoke: :q! did not exit after project-tree handoff", file=sys.stderr)
                return 1
            reaped = True
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
                print(
                    f"interactive-smoke: :q! ended unexpectedly: {describe_status(status)}",
                    file=sys.stderr,
                )
                return 1

            print("interactive-smoke: tree -> editor -> Vim/Ex focus handoff passed")
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
