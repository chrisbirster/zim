# 0003: Terminal-only product architecture

* **Status:** Accepted
* **Date:** 2026-08-29
* **Supersedes:** the external-GUI portions of [0002: Neovim-class Zig architecture](0002-neovim-zig-architecture.md)

## Context

Zim's direction has converged on a specific product identity: a Zig-native, Neovim-class editor whose editing experience lives entirely in the terminal.

Earlier architecture work intentionally kept open the possibility of an external SolidJS/WebView GUI. That flexibility is no longer desirable. Keeping a future GUI in the architecture creates pressure to design UI attachment protocols, rendering abstractions, transport behavior, and duplicated presentation paths that do not serve Zim's actual product.

The terminal is not a bootstrap UI. It is the intended user experience.

## Decision

Zim will be a **terminal-only editor**.

### The Zig TUI is permanent

Interactive Zim runs through its built-in Zig terminal UI.

```text
terminal input
      │
      ▼
Zig TUI
      │ direct Zig calls
      ▼
Zim editor core
```

The TUI is first-party, in-process, and permanent. It should receive the same engineering attention as the editor core: input latency, rendering efficiency, terminal compatibility, resize behavior, Unicode correctness, and safe terminal restoration are product concerns.

### No graphical editor frontend

Zim will not ship or plan a graphical editor frontend.

This excludes:

- SolidJS editor UI
- WebView editor shell
- browser editor client
- Electron frontend
- native GUI frontend
- external GUI attachment protocol as a product milestone

If SolidJS is used by the Zim project, it is for the separate documentation website only and is not part of the editor runtime.

### Preserve core/UI separation where it helps correctness

Terminal-only does not mean the TUI should own editor semantics.

Buffers, windows, tab pages, modes, commands, edits, undo, registers, marks/extmarks, diagnostics, jobs, LSP state, and plugin state remain editor-core concepts. The TUI renders and manipulates them through direct Zig APIs.

This separation supports headless tests, Lua plugins, automation, and maintainability without implying multiple UI products.

### MessagePack-RPC remains

Zim will still use MessagePack-RPC for:

- remote plugins
- external automation
- embedding
- headless control

MessagePack-RPC is not a rendering protocol and normal interactive editing does not pass through it.

### Lua remains the primary extension language

Embedded Lua remains part of the Neovim-class direction. Normal configuration and plugins call the public editor API in-process.

### Headless mode remains first-class

`zim --headless` runs the same editor core without terminal rendering for tests, automation, CI, embedding, and remote-plugin workflows.

Headless mode is not a second user interface.

## Consequences

- There is one interactive UI to optimize and support: the terminal.
- No Node.js, browser runtime, WebView, DOM, or GUI toolkit enters the editor dependency graph.
- The roadmap no longer contains a GUI milestone.
- The public editor API does not need UI-attachment concepts for a hypothetical frontend.
- MessagePack-RPC design can focus on plugins and automation rather than high-frequency display traffic.
- TUI capability and portability become core product quality dimensions.
- SSH, tmux/screen, Unicode, terminal capability differences, and Windows terminal behavior deserve explicit testing.
- Core editing semantics remain headlessly testable.
- Documentation-site technology is independent of editor architecture.

## Non-goals

This decision does not mean Zim must visually clone Neovim or limit itself to the lowest common denominator of historical terminals.

Zim may use modern terminal capabilities where appropriate, including true color, mouse input, bracketed paste, richer keyboard protocols, hyperlinks, synchronized output, or image protocols when they can be introduced with sensible fallbacks.

The constraint is that the experience remains a terminal application.

## Product invariant

A useful test for future proposals is:

> **Can this feature belong naturally in a terminal-first modal editor?**

If a proposed editor feature fundamentally requires a graphical frontend, it is outside Zim's product scope.

## First validation milestone

The decision is validated when:

```bash
zim file.txt
```

opens a reliable Zig TUI in which a user can enter Normal/Insert mode, move, edit, undo, `:w`, and `:q`, with the terminal restored correctly afterward and the same editing semantics covered by headless tests.
