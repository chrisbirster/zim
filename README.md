# Zim

**Your new code overlord.**

Zim is a fast, local-first, modal programmer's editor written in Zig and built around the fundamentals that make Neovim powerful: buffers, windows, modes, composable commands, Lua extensibility, a stable editor API, headless operation, and MessagePack-RPC for external clients and plugins.

> THE CODE... IT FILLS ME... IT IS NEAT!

## Canonical repository

Active development happens here:

**https://github.com/chrisbirster/zim**

This GitHub repository is the canonical source for Zim code, issues, pull requests, releases, architecture decisions, and roadmap work.

## Mission

Build a modern Neovim-class editor in Zig: immediate to start, pleasant in a terminal, deeply programmable, understandable enough to hack on, and useful without an account, browser, JavaScript runtime, or cloud service.

Zim is not a Neovim fork and does not promise Neovim API or plugin compatibility. It intentionally follows the same core architectural ideas while giving us room to design a smaller Zig-native implementation.

## Product direction

The first complete Zim is a **pure Zig terminal editor**.

```text
keyboard / terminal
        │
        ▼
┌──────────────────────┐
│       Zig TUI        │
└──────────┬───────────┘
           │ direct Zig calls
           ▼
┌──────────────────────────────────────┐
│              Zim Core                │
│                                      │
│ buffers   windows   modes   keymaps  │
│ commands  undo      marks   events   │
│ LSP       jobs      PTYs    search   │
└──────────┬───────────────────────────┘
           │
           ├── embedded Lua API
           │
           └── MessagePack-RPC
                    │
                    ├── remote plugins
                    ├── automation / embedding
                    └── optional external GUIs later
```

The built-in TUI does not need RPC to edit text. It lives in the same Zig process and calls the editor core directly.

Lua plugins run against the same public editor API in-process. External plugins, automation tools, and future graphical UIs use the API over MessagePack-RPC.

A future SolidJS GUI remains possible, but it is an optional external UI—not part of Zim's core architecture and not required for the first useful release.

## Neovim fundamentals we are keeping

- buffers are independent from windows/views
- modal editing is core behavior, not a UI skin
- operators, motions, counts, and text objects compose
- commands and keymaps are first-class
- tabs contain window layouts rather than being synonymous with files
- marks/extmarks and decorations are editor primitives
- an event/autocommand system supports extension without hard-coding hooks
- Lua is the primary configuration and embedded plugin language
- a stable editor API is shared by built-ins, Lua, automation, and remote clients
- MessagePack-RPC powers external plugins/clients
- headless operation is a supported architecture, not a testing hack
- language servers, jobs, terminals, and parsing attach to editor state rather than owning it
- external UIs can be added without creating a second editor engine

## Status

Zim is in very early development.

The current executable starts, resolves the current working directory, and prints its startup identity. It is not yet a usable text editor.

The next milestone is deliberately concrete: **open a file in a Zig TUI, enter Normal/Insert mode, edit text, save, and quit.**

```text
ZIM 0.1.0 — YOUR NEW CODE OVERLORD

THE CODE... IT FILLS ME... IT IS NEAT!
```

## Read next

- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0002: Neovim-class Zig architecture](docs/architecture/0002-neovim-zig-architecture.md)

## Development

### Requirements

- Zig 0.16.0

Additional native dependencies for Lua, terminal support, syntax parsing, or platform integration will be documented only when they actually land.

Check Zig:

```bash
zig version
```

### Build

```bash
zig build
```

### Run

```bash
zig build run -- .
```

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```
