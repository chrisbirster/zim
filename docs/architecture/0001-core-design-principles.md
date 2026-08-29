# 0001: Core Design Principles

* **Status:** Superseded by [0002: Neovim-class Zig architecture](0002-neovim-zig-architecture.md)
* **Date:** 2026-07-26
* **Superseded:** 2026-08-29

## Historical context

This decision captured Zim's earlier direction as a local-first editor with a Zig backend and a SolidJS graphical frontend connected through semantic RPC.

The project direction later changed: Zim is now being built as a Zig-first, terminal-native, Neovim-class editor. SolidJS is no longer a required first-party frontend and may return only as an optional external UI after the core editor is mature.

The durable principles from this ADR remain useful:

- local-first operation
- authoritative Zig editor state
- understandable architecture
- semantic extension APIs
- no required remote/cloud services

The frontend-specific and JSON-RPC-first decisions are superseded by ADR 0002.

See [0002-neovim-zig-architecture.md](0002-neovim-zig-architecture.md) for the active architecture decision.
