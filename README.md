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
           ├── embedded Lua 5.4 API
           │
           └── MessagePack-RPC
                    │
                    ├── remote plugins
                    ├── automation
                    └── headless control
```

The TUI and editor core stay in the same Zig process. Normal editing never depends on RPC, HTTP, a browser, or a GUI shell.

Lua is the primary configuration and future in-process plugin language. External plugins and automation will use the same editor concepts over MessagePack-RPC.

## Current status

Zim is a real modal editor under active pre-1.0 development. The current development version is **`v0.3.0 — Lua Configuration`**.

`v0.3.0` builds on the `v0.2.0` programmable Zig API and adds:

- embedded, pinned Lua 5.4 through Ziglua with no system Lua dependency
- startup configuration from `XDG_CONFIG_HOME/zim/init.lua`, `%APPDATA%/zim/init.lua`, or `~/.config/zim/init.lua`
- the global `zim` Lua namespace
- `zim.opt` for typed editor options
- global and buffer-local `zim.keymap` mappings
- Lua-defined commands through `zim.command`, callable as `:Command args`
- typed `zim.autocmd` callbacks with once and buffer-local filters
- buffer/window/tab handles through `zim.buf`, `zim.win`, and `zim.tab`
- LSP request bindings through `zim.lsp`
- protected Lua callback execution so callback failures do not crash the editor
- Lua-to-Hondo integration coverage proving Lua-created keymaps, commands, and autocommands drive the native editor path
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

```text
ZIM 0.3.0 — YOUR NEW CODE OVERLORD
```

See [Lua Configuration](docs/LUA_CONFIGURATION.md) for the supported API and an `init.lua` example.

## Extension architecture

Zim has one conceptual public editor API. The stable Zig entrypoint is `src/api.zig`, with the contract documented in [Programmable Core](docs/PROGRAMMABLE_CORE.md).

```text
                 public Zim API
                       │
          ┌────────────┼────────────┐
          │            │            │
       built-ins      Lua       MessagePack-RPC
                       │            │
                    plugins     remote tools
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

The v0.3 keymap API intentionally starts small: `lhs` and `rhs` are single Unicode codepoints. Multi-key mappings and richer command/key notation belong to later extension work.

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

Headless startup still initializes the public API and loads Lua configuration; it simply skips the Hondo TUI.

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

- [Lua Configuration](docs/LUA_CONFIGURATION.md)
- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Programmable Core](docs/PROGRAMMABLE_CORE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)
