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

Zim is a real modal editor under active pre-1.0 development. The current development version is **`v0.4.0 — Plugin System + Package Management`**.

`v0.4.0` builds on the programmable Zig API and v0.3 Lua layer with:

- deterministic in-process Lua plugin discovery and startup
- built-in Git-backed plugin install/update/remove
- an exact-commit `plugins.lock`
- plugin compatibility metadata through `zim-plugin.meta`
- API-generation, Zim-version, and capability checks
- failure isolation so one broken plugin does not block later plugins
- rollback of partial command/keymap/autocommand registrations when plugin startup fails
- Lua module search paths for plugin `require(...)`
- `:PackAdd`, `:PackUpdate`, `:PackRemove`, and `:PackList`
- `:Commands` and `:Keymaps` discovery
- a real Git-backed package lifecycle test that installs, restarts/loads, updates, verifies exact SHAs, and removes a plugin
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

```text
ZIM 0.4.0 — YOUR NEW CODE OVERLORD
```

See [Plugins](docs/PLUGINS.md) for package management and plugin authoring, and [Lua Configuration](docs/LUA_CONFIGURATION.md) for the public Lua editor API.

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

Plugins are trusted in-process Lua code. Zim v0.4 does not claim Neovim API/plugin compatibility.

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

CI additionally runs the pure Zig core gate, the real Git-backed plugin package lifecycle test, Hondo integration tests, the full suite, and the pinned real-ZLS smoke where configured.

## Read next

- [Plugins](docs/PLUGINS.md)
- [Lua Configuration](docs/LUA_CONFIGURATION.md)
- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Programmable Core](docs/PROGRAMMABLE_CORE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)
