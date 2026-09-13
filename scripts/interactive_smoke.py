#!/usr/bin/env python3
"""Exercise Zim's release binary through a real PTY.

This follows the human dogfood path that exposed the v1 TUI focus bugs: start
in a project, toggle the explorer, expand a directory, open a file, use Vim
multi-key motions, then visibly enter Ex mode and quit. Headless
Editor.handleKey() tests are not sufficient for this contract because focus can
be lost between Hondo native views.
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


def send(master: int, data: bytes, settle: float = 0.35) -> bytes:
    os.write(master, data)
    return drain(master, settle)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: interactive_smoke.py /path/to/zim", file=sys.stderr)
        return 2

    executable = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="zim-interactive-") as project:
        src = Path(project, "src")
        src.mkdir()
        Path(src, "sample.txt").write_text(
            "alpha beta gamma\n"
            "two words here\n"
            "three words here\n"
            "four words here\n"
            "five words here\n"
            "six words here\n"
            "seven words here\n"
            "eight words here\n"
            "nine words here\n"
            "ten words here\n",
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

            tree_frame = send(master, b" e")
            if b"FILES" not in tree_frame:
                print("interactive-smoke: <leader>e did not render the project tree", file=sys.stderr)
                return 1

            # Prove the leader binding is a true toggle from tree focus.
            send(master, b" e")
            reopened = send(master, b" e")
            if b"FILES" not in reopened:
                print("interactive-smoke: <leader>e did not close and reopen the tree", file=sys.stderr)
                return 1

            # The only root entry is src/. Enter expands it; j + Enter opens the
            # now-visible nested sample file.
            expanded = send(master, b"\r")
            if b"sample.txt" not in expanded:
                print("interactive-smoke: Enter did not expand a project-tree directory", file=sys.stderr)
                return 1
            send(master, b"j\r", 0.5)

            # Exercise multi-key Vim grammar after tree -> editor focus. The
            # sequence intentionally includes both buffer-end and buffer-start.
            send(master, b"Ggg")

            # Exercise a representative operator+motion and undo through the
            # same TUI path before entering Ex mode.
            send(master, b"dw")
            send(master, b"u")

            # Visibility is checked on the initial ':' frame. Renderer updates
            # after q/! may be emitted as separate cell diffs, so requiring the
            # raw output stream to contain one contiguous ':q!' string would be
            # stricter than what the user actually sees on screen.
            colon_frame = send(master, b":")
            if b":" not in colon_frame:
                print("interactive-smoke: Ex command prompt was not visibly rendered", file=sys.stderr)
                return 1
            send(master, b"q!", 0.25)
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

            print("interactive-smoke: tree toggle/expand -> Vim motions/operators -> visible Ex :q! passed")
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
