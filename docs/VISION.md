# Zim Vision

## Mission statement

**Zim exists to make modal, local software development feel immediate again.**

Zim is a Neovim-class programmer's editor rebuilt around Zig: fast to start, terminal-native, deeply programmable, usable headlessly, and architected so the editor engine is more important than any particular UI.

## Purpose

Zim is for developers who want:

- a fast native modal editor
- a terminal-first workflow
- a small core that can be understood and modified
- composable Vim-style editing semantics
- Lua configuration and plugins
- LSP, syntax parsing, jobs, terminals, search, and Git around one editor state
- a stable API for automation and external clients
- no required cloud account, browser runtime, Electron shell, or JavaScript toolchain

The goal is not to copy every Neovim implementation detail. The goal is to preserve the architectural fundamentals that make Neovim powerful while taking advantage of Zig to build a smaller, modern implementation.

## Product promise

Eventually:

```bash
zim src/main.zig
```

should immediately enter a capable modal editor.

And:

```bash
zim --headless
```

should expose the same editor engine for automation and testing without starting a UI.

The editor should remain useful offline and should not require any graphical client.

## Core beliefs

### 1. The editor core is the product

Buffers, windows, modes, commands, keymaps, undo history, marks, diagnostics, jobs, terminals, and extension state belong to the Zig core.

The TUI displays and manipulates that state; it does not define the editor model.

### 2. The first UI is pure Zig

The first useful Zim is a terminal editor implemented in Zig. The built-in TUI calls the core directly and does not pay an RPC or serialization cost for ordinary editing.

### 3. Modal editing is fundamental

Normal, Insert, Visual, operator-pending, command-line, motions, operators, counts, and text objects are core editor semantics.

They should compose rather than become a long list of special-case key handlers.

### 4. Buffers are not windows

A buffer owns text and editing state. A window is a view onto a buffer. A tab page owns a window layout.

This separation should remain true in the TUI and in any future external GUI.

### 5. One public editor API

Built-in features, Lua plugins, headless automation, external plugins, and future UIs should converge on the same stable editor concepts and API surface.

Internal Zig code may call implementation functions directly, but extension-facing behavior should not require a parallel editor model.

### 6. Lua is the primary extension language

Zim should support `init.lua` configuration and embedded Lua plugins.

Lua plugins should be able to register commands, keymaps, events/autocommands, diagnostics/decorations, and other capabilities through the public Zim API.

The exact Lua runtime implementation is an engineering choice; plugin APIs should avoid depending on runtime-specific quirks.

### 7. MessagePack-RPC is the external boundary

Remote plugins, automation tools, embedding hosts, and future external UIs should communicate with Zim using MessagePack-RPC.

The built-in TUI and embedded Lua do not need to serialize calls through RPC.

### 8. Headless is first-class

The editor should be able to run without a terminal UI. This enables integration testing, scripted editing, CI use, remote plugins, and future clients without creating a second core.

### 9. Small beats magical

Prefer explicit state, narrow modules, direct Zig calls, measurable behavior, and simple data structures until scale proves they are insufficient.

Do not re-create Neovim's historical complexity merely because Neovim has it.

### 10. Fast is a feature

Startup, keystroke handling, cursor movement, editing, redraws, search, command dispatch, and diagnostics should remain beneath perceptible latency whenever practical.

## What Zim is

Zim is:

- a modal programmer's editor
- a Zig application
- a terminal-first editor
- a buffer/window/mode/command engine
- a Lua-configurable and Lua-extensible environment
- a host for LSP, jobs, terminals, parsing, and development tools
- a headless automation engine
- a MessagePack-RPC server for remote plugins and clients
- eventually capable of supporting optional graphical UIs

## What Zim is not

Through the early releases, Zim is not trying to be:

- a Neovim fork
- byte-for-byte or API-compatible with Neovim
- a VS Code clone
- a GUI-first editor
- an Electron application
- a cloud IDE
- a browser-owned editor engine
- a plugin marketplace
- an AI product whose editor depends on a remote model

Compatibility layers can be considered later if they create enough value without compromising the core design.

## First useful Zim

The first useful Zim is intentionally small:

1. `zim file.txt` opens a real terminal editor.
2. The terminal is restored safely on exit or error.
3. Normal mode and Insert mode work.
4. Basic motions work.
5. Text can be inserted and deleted.
6. `:w` saves.
7. `:q` quits.
8. Undo and redo work.
9. Resize/redraw behavior is correct.
10. Core editing behavior is covered by headless tests.

If that loop is fast and trustworthy, Zim has the foundation of a real editor.

## Longer-term success

Zim succeeds when:

- developers can use it as a daily terminal editor
- its modal grammar feels coherent rather than approximated
- Lua is sufficient for normal configuration/plugin development
- external plugins can be written without linking into the Zim process
- headless tests exercise the same editor semantics used interactively
- the TUI can evolve without rewriting buffer/editing semantics
- an optional GUI could attach later without becoming a second editor implementation
- the codebase stays substantially easier to understand than the systems it replaces

## Personality

Zim should be technically serious without becoming sterile.

The project keeps its Invader Zim-inspired voice — **"Your new code overlord"** and **"THE CODE... IT FILLS ME... IT IS NEAT!"** — while the editor underneath remains disciplined, fast, and dependable.
