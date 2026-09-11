#!/usr/bin/env python3
"""Temporary assertion-driven documentation transform for the v1 candidate."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    target = ROOT / path
    text = target.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrences, found {count}: {old!r}")
    target.write_text(text.replace(old, new))


replace_exact(
    "README.md",
    '''## Current status\n\nZim is a real modal editor under active pre-1.0 development. The current development version is **`v0.9.0 — MessagePack-RPC + Remote Plugins`**.\n\n`v0.9.0` exposes the public editor API to trusted local external processes while preserving native ownership of editor semantics:\n\n- bounded MessagePack codec with incremental stream framing\n- MessagePack-RPC request/response/notification protocol\n- explicit RPC protocol and public API version negotiation\n- capability discovery\n- headless stdio RPC\n- Unix-domain socket transport on Linux/macOS\n- Windows named-pipe transport\n- remote commands, keymaps, and autocommands backed by the existing native registries\n- stable remote registration IDs with disconnect cleanup\n- remote command/autocommand callback notifications\n- buffer access and public command execution over RPC\n- nonblocking interactive RPC polling on Zim's editor thread\n- process-boundary CI smokes on Ubuntu, macOS, and Windows\n\n```text\nZIM 0.9.0 — YOUR NEW CODE OVERLORD\n```\n\nSee [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md) for the v0.9 wire protocol, transports, callbacks, lifecycle, and security model.\n''',
    '''## Current status\n\nThe current development version is **`v1.0.0 — Daily Driver`**. v1 turns the editor architecture completed through v0.9 into a compatibility-managed, recoverable, installable primary-editor candidate.\n\nDaily Driver adds:\n\n- atomic crash-recovery snapshots for unsaved buffers and complete workspace state\n- clean session persistence for project, buffers, windows, tabs, splits, cursors, and scroll positions\n- isolated command, autocommand, Lua, plugin, RPC, LSP, and external-tool failure boundaries\n- bounded user-visible error history through `:Errors` and runtime diagnostics through `:Checkhealth`\n- built-in searchable help topics with `:Help`\n- native `zim`, `mono`, and `ember` colorschemes plus user highlight overrides\n- compatibility-managed public/plugin/RPC API metadata for the 1.x line\n- reproducible macOS/Linux/Windows release archives and checksum-verifying installers\n- bounded startup and 5 MiB large-file performance gates in three-platform CI\n- terminal compatibility diagnostics for Kitty, WezTerm, Alacritty, Terminal.app, Windows Terminal, SSH, and tmux contexts\n\n```text\nZIM 1.0.0 — YOUR NEW CODE OVERLORD\n```\n\nSee [Daily Driver](docs/DAILY_DRIVER.md), [API Stability](docs/API_STABILITY.md), [Recovery and Sessions](docs/RECOVERY_AND_SESSIONS.md), [Install](docs/INSTALL.md), and [Terminal Compatibility](docs/TERMINAL_COMPATIBILITY.md) for the v1 contract and release gates.\n''',
)

replace_exact(
    "README.md",
    "RPC is local-only in v0.9. There is no TCP listener, RPC authentication layer, or network plugin registry. Treat connected remote processes as trusted local extensions.",
    "RPC remains local-only in v1.0. There is no TCP listener, RPC authentication layer, or network plugin registry. Treat connected remote processes as trusted local extensions.",
)
replace_exact(
    "README.md",
    "See [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md) for the complete v0.9 contract.",
    "See [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md) for the complete RPC contract and [API Stability](docs/API_STABILITY.md) for the 1.x compatibility policy.",
)
replace_exact(
    "README.md",
    "zim.opt.expandtab = true\n\nzim.keymap.set('normal', 'z', 'i')",
    "zim.opt.expandtab = true\n\nzim.colorscheme('ember')\nzim.highlight.set('Keyword', { fg = 13, bold = true })\n\nzim.keymap.set('normal', 'z', 'i')",
)
replace_exact(
    "README.md",
    "- Python 3 for the CI RPC process-boundary smoke harness",
    "- Python 3 for RPC process-boundary smoke tests, release packaging, and Daily Driver performance gates",
)
replace_exact(
    "README.md",
    "CI runs the pure Zig core gate, job lifecycle/streaming/cancellation tests, PTY and terminal session/screen/controller tests, Pins persistence/Lua tests, extmark/edit-tracking and plugin UI tests, the real Git-backed plugin package lifecycle test, MessagePack-RPC host/protocol tests, external-process stdio + local-IPC RPC smokes, Hondo integration tests including native Pin and popup/completion navigation, the full suite, and the pinned real-ZLS smoke where configured.",
    "CI runs the pure Zig core gate, recovery/session and extension-failure isolation tests, job lifecycle/streaming/cancellation tests, PTY and terminal session/screen/controller tests, Pins persistence/Lua tests, extmark/edit-tracking/theme/plugin UI tests, the real Git-backed plugin package lifecycle test, MessagePack-RPC host/protocol tests, external-process stdio + local-IPC RPC smokes, bounded startup/large-file performance gates, Hondo integration tests including native Pin and popup/completion navigation, the full suite, and the pinned real-ZLS smoke where configured.",
)
replace_exact(
    "README.md",
    '''## Read next\n\n- [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md)''',
    '''## Read next\n\n- [Daily Driver](docs/DAILY_DRIVER.md)\n- [API Stability](docs/API_STABILITY.md)\n- [Recovery and Sessions](docs/RECOVERY_AND_SESSIONS.md)\n- [Install / Update](docs/INSTALL.md)\n- [Terminal Compatibility](docs/TERMINAL_COMPATIBILITY.md)\n- [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md)''',
)

replace_exact(
    "ROADMAP.md",
    '''## v1.0.0 — Daily Driver\n\n**Goal:** make Zim trustworthy as a primary Neovim-class terminal editor.\n\n- [ ] stable modal grammar and public API policy\n- [ ] robust crash/error recovery\n- [ ] sessions/recovery strategy\n- [ ] colorschemes/highlight configuration\n- [ ] built-in help/documentation\n- [ ] packaging/installers\n- [ ] startup and large-file benchmarks\n- [ ] macOS/Linux/Windows terminal hardening\n- [ ] SSH/tmux behavior testing\n- [ ] sustained real-project dogfooding\n\n**Exit condition:** Zim can realistically be used as a primary terminal programmer's editor with documented compatibility and extension guarantees.''',
    '''## v1.0.0 — Daily Driver\n\n**Status: release-candidate implementation complete; sustained dogfood and final release validation remain.**\n\n**Goal:** make Zim trustworthy as a primary Neovim-class terminal editor.\n\n- [x] stable modal grammar and public API policy\n- [x] robust crash/error recovery and extension callback isolation\n- [x] atomic sessions/recovery strategy for complete workspace state and unsaved buffers\n- [x] colorschemes/highlight configuration wired into native rendering\n- [x] built-in searchable help/documentation and health/error diagnostics\n- [x] macOS/Linux/Windows release packaging plus checksum-verifying installers\n- [x] startup and large-file benchmark budgets enforced in CI\n- [x] macOS/Linux/Windows terminal hardening\n- [x] SSH/tmux compatibility modeling and diagnostics\n- [ ] sustained real-project dogfooding\n\nThe v1 release gate requires the exact candidate head to pass Ubuntu/macOS/Windows CI, followed by the same gate on the exact squash-merged `main` commit. The tag is cut only from that validated `main` commit.\n\n**Exit condition:** Zim can realistically be used as a primary terminal programmer's editor with documented compatibility and extension guarantees.''',
)

print("v1 documentation patch applied")
