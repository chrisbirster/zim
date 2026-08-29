# Zim

**Your new code overlord.**

Zim is a fast, local-first, terminal-only modal programmer's editor written in Zig and built around the fundamentals that make Neovim powerful: buffers, windows, modes, composable commands, Lua extensibility, a stable editor API, headless operation, and MessagePack-RPC for external plugins and automation.

> THE CODE... IT FILLS ME... IT IS NEAT!

## Canonical repository

Active development happens here:

**https://github.com/chrisbirster/zim**

This GitHub repository is the canonical source for Zim code, issues, pull requests, releases, architecture decisions, and roadmap work.

## Mission

Build a modern Neovim-class editor in Zig: immediate to start, excellent in a terminal, deeply programmable, understandable enough to hack on, and useful without an account, browser, JavaScript runtime, graphical shell, or cloud service.

Zim is not a Neovim fork and does not promise Neovim API or plugin compatibility. It intentionally follows the same core editor fundamentals while giving us room to design a smaller Zig-native implementation.

## Product direction

Zim is a **terminal editor, permanently**.

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
                    ├── automation
                    └── embedding/headless control
```

The TUI lives in the same Zig process and calls the editor core directly. Normal editing never depends on RPC, HTTP, WebSockets, JavaScript, a browser, or a GUI framework.

Lua plugins run against the public editor API in-process. External plugins and automation tools use the same editor concepts over MessagePack-RPC.

SolidJS has **no role in the Zim editor runtime**. If the project uses SolidJS, it is for the separate documentation website only.

## Neovim fundamentals we are keeping

- buffers are independent from windows/views
- modal editing is core behavior, not a UI skin
- operators, motions, counts, and text objects compose
- commands and keymaps are first-class
- tabs contain window layouts rather than being synonymous with files
- marks/extmarks and decorations are editor primitives
- an event/autocommand system supports extension without hard-coded hooks
- Lua is the primary configuration and embedded plugin language
- a stable editor API is shared by built-ins, Lua, automation, and remote plugins
- MessagePack-RPC powers external plugins and automation clients
- headless operation is a supported architecture, not a testing hack
- language servers, jobs, terminals, and parsing attach to editor state rather than owning it

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
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)

## Development

### Requirements

- Zig 0.16.0

Additional native dependencies for Lua, terminal support, syntax parsing, or platform integration will be documented only when they actually land.

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
