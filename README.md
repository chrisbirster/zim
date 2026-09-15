# Zim

**Your new code overlord.**

Zim is a fast, local-first, terminal-only modal programmer's editor written in Zig. It follows the editor fundamentals that make Neovim powerful—buffers, windows, composable modal editing, commands, keymaps, events, a stable extension API, Lua configuration, plugins, jobs, and remote automation—without being a Neovim fork or promising Neovim plugin compatibility.

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
┌────────────────────────────────────────────┐
│                  Zim Core                  │
│                                            │
│ buffers   windows   modes    keymaps       │
│ commands  undo      marks    events        │
│ LSP       parsing   search   plugins       │
│ pins      extmarks  diagnostics  popup UI  │
│ jobs      PTY       terminal state         │
└──────────┬─────────────────────────────────┘
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

Lua is the primary configuration and in-process plugin language. External plugins and automation use the same public editor concepts through local MessagePack-RPC without moving native editor state out of Zig.

## Current status

The current development version is **`v1.0.0 — Daily Driver`**. v1 turns the editor architecture completed through v0.9 into a compatibility-managed, recoverable, installable primary-editor candidate.

Daily Driver adds:

- atomic crash-recovery snapshots for unsaved buffers and complete workspace state
- clean session persistence for project, buffers, windows, tabs, splits, cursors, and scroll positions
- isolated command, autocommand, Lua, plugin, RPC, LSP, and external-tool failure boundaries
- bounded user-visible error history through `:Errors` and runtime diagnostics through `:Checkhealth`
- built-in searchable help topics with `:Help`
- native `zim`, `mono`, and `ember` colorschemes plus user highlight overrides
- compatibility-managed public/plugin/RPC API metadata for the 1.x line
- reproducible macOS/Linux/Windows release archives and checksum-verifying installers
- bounded startup and 5 MiB large-file performance gates in three-platform CI
- terminal compatibility diagnostics for Kitty, WezTerm, Alacritty, Terminal.app, Windows Terminal, SSH, and tmux contexts

```text
ZIM 1.0.0 — YOUR NEW CODE OVERLORD
```

See [Daily Driver](docs/DAILY_DRIVER.md), [API Stability](docs/API_STABILITY.md), [Recovery and Sessions](docs/RECOVERY_AND_SESSIONS.md), [Install](docs/INSTALL.md), and [Terminal Compatibility](docs/TERMINAL_COMPATIBILITY.md) for the v1 contract and release gates.

## MessagePack-RPC + Remote Plugins

Run a headless stdio RPC server:

```bash
zim --rpc-stdio
```

Run a headless local IPC server:

```bash
zim --headless --rpc-listen /tmp/zim.sock
```

Or keep the normal TUI and let a remote plugin attach locally:

```bash
zim --rpc-listen /tmp/zim.sock .
```

On Windows, `--rpc-listen zim-main` serves `\\.\pipe\zim-main` instead of a Unix socket.

Clients first negotiate protocol/API metadata with `zim.handshake`, then can discover capabilities and call the supported public RPC methods. Remote commands and autocommands receive callback notifications; registrations are scoped to the connection and cleaned up when that connection is discarded.

RPC remains local-only in v1.0. There is no TCP listener, RPC authentication layer, or network plugin registry. Treat connected remote processes as trusted local extensions.

See [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md) for the complete RPC contract and [API Stability](docs/API_STABILITY.md) for the 1.x compatibility policy.

## Jobs + Terminal

Start a non-interactive asynchronous job without invoking a shell implicitly:

```text
:JobStart zig build test
:JobList
:JobStop 1
```

Lua uses the same native job service:

```lua
local id = zim.job.start({ 'zig', 'build', 'test' })
local state = zim.job.status(id)
local stdout = zim.job.stdout(id)
local stderr = zim.job.stderr(id)
```

Open an interactive shell:

```text
:terminal
```

Or run a command inside a PTY-backed terminal session:

```text
:terminal zig build test
```

On POSIX, terminal sessions use `forkpty`; on Windows they use ConPTY. Zig owns process lifetime, PTY I/O, terminal parsing, resize, input, buffering, and cancellation. Hondo only paints the native screen model.

See [Jobs + Terminal](docs/JOBS_AND_TERMINAL.md) for the complete v0.8 behavior and deliberate scope.

## Extmarks, diagnostics, and plugin UI

Create a namespace and place a durable annotation:

```lua
local buffer = zim.buf.current()
local ns = zim.extmark.namespace('demo')

local id = zim.extmark.set(buffer, ns, 3, 5, {
  end_line = 3,
  end_column = 12,
  highlight = 'DiagnosticWarn',
  sign = '!',
  virtual_text = 'check this',
})
```

Extmarks belong to buffers and namespaces. Their anchors move through the native edit path instead of remaining fixed at raw line numbers.

Publish diagnostics through the same primitive:

```lua
zim.diagnostic.publish(buffer, ns, {
  {
    line = 4,
    severity = 'warning',
    message = 'suspicious value',
  },
})
```

Show a native plugin popup:

```lua
zim.ui.popup('Actions', {
  'Format document',
  'Run tests',
  'Open definition',
})
```

Plugins provide popup content, while Zig owns open/closed state and selection. Hondo renders coarse popup state; handled navigation keys remain on the native editor path.

LSP completion uses the same popup model. Zig owns the completion items and selected index, and accepting an item inserts its LSP `insertText` through the native buffer edit path.

See [Extmarks, Diagnostics, and Plugin UI](docs/EXTMARKS_AND_PLUGIN_UI.md) for gravity, decorations, diagnostics, popup behavior, and deliberate v0.7 limits.

## Pins

Add the current file/cursor location:

```text
:PinAdd
```

Add a label:

```text
:PinAdd parser entry
```

Open the centered switcher:

```text
:PinList
```

or in Normal mode:

```text
gp
```

Direct jumps reuse Zim's mark grammar without stealing numeric counts:

```text
'1   linewise jump to pin 1
`1   exact line + column jump to pin 1
```

Manage ordering:

```text
:PinMove 4 1
:PinRemove 2
:PinJump 3
```

Pins survive restart because they persist file identity and logical location rather than runtime buffer IDs. Files inside the project root are stored project-relative when possible.

Lua exposes the same model:

```lua
local id = zim.pin.add('parser')
local pins = zim.pin.list()
zim.pin.jump(1)
zim.pin.move(3, 1)
zim.pin.remove(2)
```

See [Pins](docs/PINS.md) for the full contract.

## Zen Workspace

At normal terminal widths, Zim is organized as:

```text
┌──────────────┬──────────────────────────────┬──────────────────┐
│ PROJECT      │                              │ CONTEXT          │
│ project root │          EditorView          │ Symbols          │
│ current file │           Zig-native         │ Diagnostics      │
│ buffers      │                              │ References       │
│ pins 1–9     │                              │ Git / QF / Tests │
└──────────────┴──────────────────────────────┴──────────────────┘
```

Project and Context are Hondo application chrome, not fake editor buffers. The center remains the single native `zim.editor` view.

In Normal mode, `Tab`/`Shift-Tab` traverse workspace focus. When a key belongs to editing, native editor ownership wins: for example, Insert-mode `Tab` inserts indentation instead of moving focus.

While a side zone is focused, `c` or `Enter` toggles its collapsed rail. Context uses Left/Right to select a surface. On narrow terminals Context and then Project collapse automatically to small focusable rails instead of disappearing.

Pins, diagnostics summaries, and plugin popup state are editor-owned data summarized through the coarse NativeView boundary. The Hondo shell renders them without owning editor semantics.

See [Zen Workspace](docs/ZEN_WORKSPACE.md) for the workspace model and native-state boundary.

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

Package-managed plugins are trusted in-process Lua code. Capabilities such as `extmarks`, `diagnostics`, `ui`, and `jobs` are compatibility metadata, not sandbox permissions. Remote plugins are separate trusted local processes connected through MessagePack-RPC. Zim does not claim Neovim API/plugin compatibility.

See [Plugins](docs/PLUGINS.md) for package management and in-process plugin authoring, [Lua Configuration](docs/LUA_CONFIGURATION.md) for the public Lua editor API, and [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md) for external extensions.

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

Lua binds to public editor concepts rather than arbitrary internal pointers. MessagePack-RPC adapts that same public boundary for local external processes; it does not expose native pointers or internal object layouts.

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

zim.colorscheme('ember')
zim.highlight.set('Keyword', { fg = 13, bold = true })

zim.keymap.set('normal', 'z', 'i')

zim.command.create('Hello', function(args)
  zim.buf.set_text(args)
end, { description = 'Replace the current buffer with command arguments' })

zim.autocmd.create('BufWritePost', function(ev)
  -- ev.event, ev.sequence, ev.buffer, ev.window, ev.tab
end)

local pin_id = zim.pin.add('working location')
local annotations = zim.extmark.namespace('annotations')
local build_job = zim.job.start({ 'zig', 'build', 'test' })
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
- jobs and terminal process state are native editor services
- Lua is the primary embedded configuration/plugin language
- one stable editor API is shared by built-ins and extension layers
- MessagePack-RPC powers local external plugins, automation, and headless control
- headless operation is an architectural feature

## Development

### Requirements

- Zig 0.16.0
- Node.js for the bundled Solid/Hondo UI build
- Git for `PackAdd`, `PackUpdate`, and managed plugin revisions
- Python 3 for RPC process-boundary smoke tests, release packaging, and Daily Driver performance gates

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

Headless startup still initializes the public API, job service, persisted Pins, plugin manager, installed plugins, Lua configuration, extmarks, diagnostics, and popup model; it simply skips the Hondo TUI and interactive terminal view.

### RPC stdio

```bash
zig build run -- --rpc-stdio
```

### RPC local IPC

```bash
zig build run -- --headless --rpc-listen /tmp/zim.sock
```

Use a Windows named-pipe name instead of a socket path on Windows.

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```

CI runs the pure Zig core gate, recovery/session and extension-failure isolation tests, job lifecycle/streaming/cancellation tests, PTY and terminal session/screen/controller tests, Pins persistence/Lua tests, extmark/edit-tracking/theme/plugin UI tests, the real Git-backed plugin package lifecycle test, MessagePack-RPC host/protocol tests, external-process stdio + local-IPC RPC smokes, bounded startup/large-file performance gates, Hondo integration tests including native Pin and popup/completion navigation, the full suite, and the pinned real-ZLS smoke where configured.

## Read next

- [Daily Driver](docs/DAILY_DRIVER.md)
- [API Stability](docs/API_STABILITY.md)
- [Recovery and Sessions](docs/RECOVERY_AND_SESSIONS.md)
- [Install / Update](docs/INSTALL.md)
- [Terminal Compatibility](docs/TERMINAL_COMPATIBILITY.md)
- [MessagePack-RPC + Remote Plugins](docs/RPC_AND_REMOTE_PLUGINS.md)
- [Jobs + Terminal](docs/JOBS_AND_TERMINAL.md)
- [Extmarks, Diagnostics, and Plugin UI](docs/EXTMARKS_AND_PLUGIN_UI.md)
- [Pins](docs/PINS.md)
- [Zen Workspace](docs/ZEN_WORKSPACE.md)
- [Plugins](docs/PLUGINS.md)
- [Lua Configuration](docs/LUA_CONFIGURATION.md)
- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Programmable Core](docs/PROGRAMMABLE_CORE.md)
- [Roadmap](ROADMAP.md)
- [ADR 0003: Terminal-only product architecture](docs/architecture/0003-terminal-only-product.md)
- [ADR 0004: Hondo application shell](docs/architecture/0004-hondo-application-shell.md)
