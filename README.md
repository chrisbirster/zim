# Zim

**Your new code overlord.**

Zim is a fast, local-first, terminal-only modal programmer's editor written in Zig. It follows the editor fundamentals that make Neovim powerful—buffers, windows, composable modal editing, commands, keymaps, events, a stable extension API, Lua configuration, plugins, and remote automation—without being a Neovim fork or promising Neovim plugin compatibility.

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
           ├── embedded Lua 5.4 API
           │      │
           │      └── in-process plugins
           │
           └── MessagePack-RPC
                    │
                    ├── remote plugins
                    ├── automation
                    └── headless control
```

The TUI and editor core stay in the same Zig process. Normal editing never depends on RPC, HTTP, a browser, or a GUI shell.

Lua is the primary configuration and in-process plugin language. External plugins and automation will use the same editor concepts over MessagePack-RPC in a later milestone.

## Current status

Zim is a real modal editor under active pre-1.0 development. The current development version is **`v0.5.0 — Zen Workspace`**.

`v0.5.0` builds on the programmable core, Lua configuration, and built-in plugin system with:

- a centered editor zone with comfortable breathing space on wide terminals
- a first-class Project zone on the left
- a first-class Context zone on the right
- Hondo-native workspace focus traversal between Project, Editor, and Context
- collapsible Project and Context rails that remain keyboard-focusable
- responsive side-rail behavior for narrow terminals
- Context surfaces for Symbols, Diagnostics, References, Git, Quickfix, and Tests
- coarse native project/LSP summary state without sending buffer text or editing semantics through JavaScript
- live diagnostic, symbol, and reference result counts
- explicit tracking that distinguishes reference results from definition locations
- integration coverage proving Normal-mode workspace Tab traversal while Insert-mode Tab remains a native editor key
- the existing direct native EditorView keystroke/render path
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

```text
ZIM 0.5.0 — YOUR NEW CODE OVERLORD
```

See [Zen Workspace](docs/ZEN_WORKSPACE.md) for the workspace model, keyboard behavior, responsive layout, and native-state boundary.

## Zen Workspace

At normal terminal widths, Zim is organized as:

```text
┌──────────────┬──────────────────────────────┬──────────────────┐
│ PROJECT      │                              │ CONTEXT          │
│ project root │          EditorView          │ Symbols          │
│ current file │           Zig-native         │ Diagnostics      │
│ buffers      │                              │ References       │
│              │                              │ Git / QF / Tests │
└──────────────┴──────────────────────────────┴──────────────────┘
```

Project and Context are Hondo application chrome, not fake editor buffers. The center remains the single native `zim.editor` view.

In Normal mode, `Tab`/`Shift-Tab` traverse workspace focus. When a key belongs to editing, native editor ownership wins: for example, Insert-mode `Tab` inserts indentation instead of moving focus.

While a side zone is focused, `c` or `Enter` toggles its collapsed rail. Context uses Left/Right to select a surface. On narrow terminals Context and then Project collapse automatically to small focusable rails instead of disappearing.

The Git, Quickfix, and Tests entries are provider-neutral Context slots in v0.5. They establish the workspace contract without running subprocess-backed tooling on every paint/state update; later job/tooling work can feed them through the same coarse-state boundary.

## Plugin package management

Install a Git-backed plugin:

```text
:PackAdd https://github.com/example/zim-plugin.git
```

Install a specific tag, commit, or revision:

```text
:PackAdd https://github.com/example/zim-plugin.git v1.2.0
```

Update, list, or remove plugins:

```text
:PackUpdate zim-plugin
:PackUpdate
:PackList
:PackRemove zim-plugin
```

Package mutations are applied on disk immediately and the resulting exact Git commit is recorded in `plugins.lock`. Restart Zim to load newly installed/updated code or unload removed code.

Plugins are trusted in-process Lua code. Zim does not claim Neovim API/plugin compatibility.

See [Plugins](docs/PLUGINS.md) for package management and plugin authoring, and [Lua Configuration](docs/LUA_CONFIGURATION.md) for the public Lua editor API.

## Extension architecture

Zim has one conceptual public editor API. The stable Zig entrypoint is `src/api.zig`, with the contract documented in [Programmable Core](docs/PROGRAMMABLE_CORE.md).

```text
                 public Zim API
                       │
          ┌────────────┼────────────┐
          │            │            │
       built-ins      Lua       MessagePack-RPC
                       │            │
               config + plugins  remote tools
```

Lua binds to public editor concepts rather than arbitrary internal pointers. The same boundary is intended to back future RPC extensions.

## Quick Lua configuration

Create your config:

```bash
mkdir -p ~/.config/zim
$EDITOR ~/.config/zim/init.lua
```

Example:

```lua
zim.opt.number = true
zim.opt.tabstop = 4
zim.opt.expandtab = true

zim.keymap.set('normal', 'z', 'i')

zim.command.create('Hello', function(args)
  zim.buf.set_text(args)
end, { description = 'Replace the current buffer with command arguments' })

zim.autocmd.create('BufWritePost', function(ev)
  -- ev.event, ev.sequence, ev.buffer, ev.window, ev.tab
end)
```

The current keymap bridge intentionally starts small: `lhs` and `rhs` are single Unicode codepoints. Richer mapping notation belongs to later extension work.

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
- Git for `PackAdd`, `PackUpdate`, and managed plugin revisions

Lua is embedded; a system Lua installation is not required.

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

Headless startup still initializes the public API, plugin manager, installed plugins, and Lua configuration; it simply skips the Hondo TUI.

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```

CI additionally runs the pure Zig core gate, the real Git-backed plugin package lifecycle test, Hondo integration tests including the Zen workspace focus/native-key contract, the full suite, and the pinned real-ZLS smoke where configured.

## Read next

- [Zen Workspace](docs/ZEN_WORKSPACE.md)
- [Plugins](docs/PLUGINS.md)
- [Lua Configuration](docs/LUA_CONFIGURATION.md)
- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Programmable Core](docs/PROGRAMMABLE_CORE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)
- [ADR 0004: Hondo application shell](docs/architecture/0004-hondo-application-shell.md)
