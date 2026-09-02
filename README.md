# Zim

**Your new code overlord.**

Zim is a fast, local-first, terminal-only modal programmer's editor written in Zig. It follows the editor fundamentals that make Neovim powerful—buffers, windows, composable modal editing, commands, keymaps, events, a stable extension API, Lua configuration, and remote automation—without being a Neovim fork or promising Neovim plugin compatibility.

> THE CODE... IT FILLS ME... IT IS NEAT!

## Canonical repository

Active development happens at **https://github.com/chrisbirster/zim**.

## Product direction

Zim is a **terminal editor, permanently**.

```text
keyboard / terminal
        │
        ▼
┌──────────────────────┐
│      Hondo TUI       │
└──────────┬───────────┘
           │ direct Zig calls
           ▼
┌──────────────────────────────────────┐
│              Zim Core                │
│                                      │
│ buffers   windows   modes   keymaps  │
│ commands  undo      marks   events   │
│ LSP       parsing   search  plugins  │
└──────────┬───────────────────────────┘
           │
           ├── embedded Lua API
           │
           └── MessagePack-RPC
                    │
                    ├── remote plugins
                    ├── automation
                    └── headless control
```

The TUI and editor core stay in the same Zig process. Normal editing never depends on RPC, HTTP, a browser, or a GUI shell.

Lua is the planned primary configuration and in-process plugin language. External plugins and automation will use the same editor concepts over MessagePack-RPC.

## Current status

Zim is a real modal editor under active pre-1.0 development.

The `v0.1.x` development baseline already includes:

- native Hondo terminal UI
- Normal/Insert/Visual/Operator-Pending/command-line modes
- composable operators, motions, counts, text objects, registers, macros, marks, jump/change history, folds, and undo/redo
- buffers, windows, splits, and tab pages
- Tree-sitter-backed language services
- native LSP lifecycle, diagnostics, navigation, hover, signature help, symbols, rename/workspace edits, code actions, formatting, and completion protocol foundation
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

The current target is **`v0.2.0 — Programmable Core`**: stable typed handles, public editor/options/commands/keymaps APIs, and deterministic typed events/autocommands. Lua configuration follows in `v0.3.0`.

```text
ZIM 0.2.0 — YOUR NEW CODE OVERLORD
```

## Extension architecture

Zim has one conceptual public editor API. The `v0.2.0` Zig-side contract lives under `src/api/` and is documented in [Programmable Core](docs/PROGRAMMABLE_CORE.md).

The long-term layering is:

```text
                 public Zim API
                       │
          ┌────────────┼────────────┐
          │            │            │
       built-ins      Lua       MessagePack-RPC
                       │            │
                    plugins     remote tools
```

Lua and RPC should bind to public editor concepts rather than arbitrary internal pointers.

## Neovim fundamentals we are keeping

- buffers are independent from windows/views
- modal editing is core behavior, not a UI skin
- operators, motions, counts, and text objects compose
- commands and keymaps are first-class
- tab pages own window layouts
- events/autocommands provide extension hooks
- marks/extmarks and decorations are editor primitives
- Lua is the primary embedded configuration/plugin language
- one stable editor API is shared by built-ins and extension layers
- MessagePack-RPC powers future external plugins and automation
- headless operation is an architectural feature

## Development

### Requirements

- Zig 0.16.0
- Node.js for the bundled Solid/Hondo UI build

### Build

```bash
zig build
```

### Run

```bash
zig build run -- .
```

### Headless

```bash
zig build run -- --headless
```

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```

CI additionally runs the pure Zig core gate, Hondo integration tests, the full suite, and the pinned real-ZLS smoke where configured.

## Read next

- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Programmable Core](docs/PROGRAMMABLE_CORE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)
