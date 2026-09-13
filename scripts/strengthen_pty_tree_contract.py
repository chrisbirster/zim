#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

p = Path("scripts/interactive_smoke.py")
s = p.read_text()

s = replace_once(
    s,
    '''            if not startup:
                print("interactive-smoke: process stayed alive but produced no terminal frame", file=sys.stderr)
                return 1

            tree_frame = send(master, b" e")
''',
    '''            if not startup:
                print("interactive-smoke: process stayed alive but produced no terminal frame", file=sys.stderr)
                return 1
            if b"ZIM v1.0.0" not in startup or b":checkhealth" not in startup:
                print("interactive-smoke: v1 dashboard contract was not rendered", file=sys.stderr)
                return 1

            # The lowercase command advertised by the dashboard must execute from
            # the initial editor-facing experience, then Esc must close its popup.
            health_frame = send(master, b":checkhealth\\r", 0.5)
            if b"Checkhealth" not in health_frame and b"Zim 1.0.0" not in health_frame:
                print("interactive-smoke: lowercase :checkhealth did not execute", file=sys.stderr)
                return 1
            send(master, b"\\x1b")

            tree_frame = send(master, b" e")
''',
    "dashboard and lowercase checkhealth",
)

s = replace_once(
    s,
    '''            # Prove the leader binding is a true toggle from tree focus.
            send(master, b" e")
            reopened = send(master, b" e")
            if b"FILES" not in reopened:
                print("interactive-smoke: <leader>e did not close and reopen the tree", file=sys.stderr)
                return 1

            # The only root entry is src/. Enter expands it; j + Enter opens the
''',
    '''            # Prove the leader binding is a true toggle from tree focus. On a
            # no-file startup, closing the tree must reveal the dashboard again.
            closed = send(master, b" e")
            if b"ZIM v1.0.0" not in closed:
                print("interactive-smoke: <leader>e did not close from tree focus", file=sys.stderr)
                return 1
            reopened = send(master, b" e")
            if b"FILES" not in reopened:
                print("interactive-smoke: <leader>e did not reopen the tree", file=sys.stderr)
                return 1

            # Ex entry is global: ':' must steal command-line ownership even while
            # the project tree is the active keyboard surface. Esc returns to tree.
            tree_colon = send(master, b":")
            if b":" not in tree_colon:
                print("interactive-smoke: Ex mode was unreachable from tree focus", file=sys.stderr)
                return 1
            send(master, b"\\x1b")

            # The only root entry is src/. Enter expands it; h collapses the same
            # node and l expands it again. j + Enter then opens the nested file.
''',
    "tree toggle and Ex focus",
)

s = replace_once(
    s,
    '''            expanded = send(master, b"\\r")
            if b"sample.txt" not in expanded:
                print("interactive-smoke: Enter did not expand a project-tree directory", file=sys.stderr)
                return 1
            opened = send(master, b"j\\r", 0.5)
''',
    '''            expanded = send(master, b"\\r")
            if b"sample.txt" not in expanded:
                print("interactive-smoke: Enter did not expand a project-tree directory", file=sys.stderr)
                return 1
            send(master, b"h")
            reexpanded = send(master, b"l")
            if b"sample.txt" not in reexpanded:
                print("interactive-smoke: h/l did not collapse and re-expand the directory", file=sys.stderr)
                return 1
            opened = send(master, b"j\\r", 0.5)
''',
    "h l tree semantics",
)

p.write_text(s)
