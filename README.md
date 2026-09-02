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

`v0.2.0 — Programmable Core` adds the stable Zig-side extension contract on top of the existing editor/language foundation:

- native Hondo terminal UI
- composable modal grammar, registers, macros, marks, jump/change history, folds, and undo/redo
- buffers, windows, splits, and tab pages
- Tree-sitter-backed language services
- native LSP lifecycle, diagnostics, navigation, hover, signature help, symbols, rename/workspace edits, code actions, formatting, and completion protocol foundation
- stable typed buffer/window/tab handles
- public editor state and typed options APIs
- command and keymap registries, including buffer-local keymaps through the public input entrypoint
- typed events/autocommands with deterministic snapshot dispatch semantics
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

The next milestone is **`v0.3.0 — Lua Configuration`**: embed Lua, load `~/.config/zim/init.lua`, and bind `zim.opt`, `zim.keymap`, `zim.command`, `zim.autocmd`, buffer/window/tab, and LSP surfaces to the `v0.2.0` API.

```text
ZIM 0.2.0 — YOUR NEW CODE OVERLORD
```

## Extension architecture

Zim has one conceptual public editor API. The stable Zig entrypoint is `src/api.zig`, with the contract documented in [Programmable Core](docs/PROGRAMMABLE_CORE.md).

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

Lua and RPC bind to public editor concepts rather than arbitrary internal pointers.

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
