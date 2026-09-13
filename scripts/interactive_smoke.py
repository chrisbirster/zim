#!/usr/bin/env python3
"""Exercise Zim's release binary through a real PTY.

This follows the human dogfood path that exposed the v1 TUI focus bugs: start
in a project, toggle the explorer, expand a directory, open a file, then prove
representative Vim motions/operators by writing their results to disk. Headless
Editor.handleKey() tests are not sufficient for this contract because focus and
terminal control-byte routing can diverge between Hondo native views.
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


def write_and_expect(master: int, path: Path, expected: str, label: str) -> bool:
    send(master, b":w\r", 0.5)
    actual = path.read_text(encoding="utf-8")
    if actual != expected:
        print(
            f"interactive-smoke: {label} wrote unexpected text\n"
            f"expected={expected!r}\nactual={actual!r}",
            file=sys.stderr,
        )
        return False
    return True


def undo_and_restore(master: int, path: Path, expected: str, label: str) -> bool:
    send(master, b"u")
    return write_and_expect(master, path, expected, f"undo after {label}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: interactive_smoke.py /path/to/zim", file=sys.stderr)
        return 2

    executable = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="zim-interactive-") as project:
        src = Path(project, "src")
        src.mkdir()
        initial_text = (
            "alpha beta gamma\n"
            "two words here\n"
            "three words here\n"
            "four words here\n"
            "five words here\n"
            "six words here\n"
            "seven words here\n"
            "eight words here\n"
            "nine words here\n"
            "ten words here\n"
        )
        sample = Path(src, "sample.txt")
        sample.write_text(initial_text, encoding="utf-8")
        lines = initial_text.splitlines(keepends=True)

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
            # now-visible nested sample file and must transfer ownership to editor.
            expanded = send(master, b"\r")
            if b"sample.txt" not in expanded:
                print("interactive-smoke: Enter did not expand a project-tree directory", file=sys.stderr)
                return 1
            opened = send(master, b"j\r", 0.5)
            if b"alpha beta gamma" not in opened:
                print("interactive-smoke: nested file did not open from project tree", file=sys.stderr)
                return 1

            # G with an explicit count must distinguish 1G from bare G. Pair it
            # with dd so the cursor destination is verified through disk contents.
            send(master, b"G1Gdd")
            no_first = "".join(lines[1:])
            if not write_and_expect(master, sample, no_first, "G1Gdd"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "G1Gdd"):
                return 1

            # Operator count before the motion and before the operator are Vim
            # equivalent: d2w and 2dw both remove two words plus following space.
            two_words_removed = "gamma\n" + "".join(lines[1:])
            send(master, b"ggd2w")
            if not write_and_expect(master, sample, two_words_removed, "d2w"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "d2w"):
                return 1

            send(master, b"gg2dw")
            if not write_and_expect(master, sample, two_words_removed, "2dw"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "2dw"):
                return 1

            send(master, b"ggdd")
            if not write_and_expect(master, sample, no_first, "dd"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "dd"):
                return 1

            # ciw must keep one undo group across operator -> insert mode.
            send(master, b"ggciwOMEGA\x1b")
            changed_word = "OMEGA beta gamma\n" + "".join(lines[1:])
            if not write_and_expect(master, sample, changed_word, "ciw"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "ciw"):
                return 1

            # Counted absolute G plus a doubled operator.
            send(master, b"gg3Gdd")
            no_third = "".join(lines[:2] + lines[3:])
            if not write_and_expect(master, sample, no_third, "3Gdd"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "3Gdd"):
                return 1

            # Absolute line motions must compose linewise with operators.
            send(master, b"2GdG")
            if not write_and_expect(master, sample, lines[0], "dG"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "dG"):
                return 1

            send(master, b"3Gdgg")
            after_dgg = "".join(lines[3:])
            if not write_and_expect(master, sample, after_dgg, "dgg"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "dgg"):
                return 1

            # Search creates a jump. Ctrl-O goes back and a literal terminal Tab
            # must behave as Vim Ctrl-I, returning to the search destination.
            send(master, b"gg/three\r")
            send(master, b"\x0f")
            send(master, b"\tdd")
            if not write_and_expect(master, sample, no_third, "Ctrl-O/Tab jump + dd"):
                return 1
            if not undo_and_restore(master, sample, initial_text, "Ctrl-O/Tab jump + dd"):
                return 1

            # Exercise command-line cancellation before the final quit. Visibility
            # is checked on the initial ':' frame; renderer updates after q/! may
            # be emitted as separate cell diffs rather than one contiguous string.
            colon_frame = send(master, b":")
            if b":" not in colon_frame:
                print("interactive-smoke: Ex command prompt was not visibly rendered", file=sys.stderr)
                return 1
            send(master, b"noop\x7f\x1b")

            colon_frame = send(master, b":")
            if b":" not in colon_frame:
                print("interactive-smoke: Ex command prompt did not recover after Esc", file=sys.stderr)
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

            print(
                "interactive-smoke: tree focus + counted motions + operator parity + visible Ex :q! passed"
            )
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
