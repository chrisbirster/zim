# 0002: Neovim-class Zig architecture

* **Status:** Superseded by [0003: Terminal-only product architecture](0003-terminal-only-product.md)
* **Date:** 2026-08-29
* **Supersedes:** [0001: Core Design Principles](0001-core-design-principles.md)

## Summary

This decision established the core Neovim-class direction that remains valid:

- pure Zig editor/TUI first
- Neovim-style buffers, windows, tab pages, modes, commands, keymaps, registers, undo, marks/extmarks, and events
- Lua as the primary embedded configuration/plugin language
- one conceptual public editor API
- MessagePack-RPC for remote plugins, automation, embedding, and headless clients
- headless mode as a first-class architecture
- simple implementations before premature optimization

It also allowed optional external graphical UIs later. That portion is superseded by ADR 0003.

Zim is now explicitly a **terminal-only editor**. The built-in Zig TUI is the permanent product interface. MessagePack-RPC remains an extension/automation boundary rather than a future GUI transport.

See [0003: Terminal-only product architecture](0003-terminal-only-product.md) for the current decision.
