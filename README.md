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
┌────────────────────────────────────────────┐
│                  Zim Core                  │
│                                            │
│ buffers   windows   modes    keymaps       │
│ commands  undo      marks    events        │
│ LSP       parsing   search   plugins       │
│ pins      extmarks  diagnostics  popup UI  │
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

Lua is the primary configuration and in-process plugin language. External plugins and automation will use the same editor concepts over MessagePack-RPC in a later milestone.

## Current status

Zim is a real modal editor under active pre-1.0 development. The current development version is **`v0.7.0 — Extmarks + Plugin UI Primitives`**.

`v0.7.0` builds durable editor annotations and plugin-facing UI on top of the public Zig API:

- namespace-owned, buffer-attached extmarks with stable IDs
- ranged extmarks with start/end gravity
- tracking through native insert/delete, undo/redo, text replacement, formatting, and LSP WorkspaceEdits
- native anchored highlights, gutter signs, and end-of-line virtual text
- LSP and plugin diagnostics represented by the same extmark primitive
- a reserved native LSP diagnostics namespace
- public Zig namespace/extmark/diagnostics/popup APIs
- Lua `zim.extmark`, `zim.diagnostic`, and `zim.ui` bindings
- plugin compatibility capabilities for `extmarks`, `diagnostics`, and `ui`
- a native popup model whose selection semantics stay in Zig
- centered Hondo rendering for plugin popups and LSP completion
- completion acceptance using the LSP item's native `insertText`
- tests proving popup/completion interaction stays on the native editor input path
- real pinned ZLS 0.16.0 subprocess smoke testing
- Ubuntu, macOS, and Windows CI

```text
ZIM 0.7.0 — YOUR NEW CODE OVERLORD
```

See [Extmarks, Diagnostics, and Plugin UI](docs/EXTMARKS_AND_PLUGIN_UI.md) for the public v0.7 model and Lua examples.

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

LSP completion now uses the same popup model. Zig owns the completion items and selected index, and accepting an item inserts its LSP `insertText` through the native buffer edit path.

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

Plugins are trusted in-process Lua code. Capabilities such as `extmarks`, `diagnostics`, and `ui` are compatibility metadata, not sandbox permissions. Zim does not claim Neovim API/plugin compatibility.

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

local pin_id = zim.pin.add('working location')
local annotations = zim.extmark.namespace('annotations')
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

Headless startup still initializes the public API, persisted Pins, plugin manager, installed plugins, Lua configuration, extmarks, diagnostics, and popup model; it simply skips the Hondo TUI.

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```

CI additionally runs the pure Zig core gate, Pins persistence/Lua tests, extmark/edit-tracking and plugin UI tests, the real Git-backed plugin package lifecycle test, Hondo integration tests including native Pin and popup/completion navigation, the full suite, and the pinned real-ZLS smoke where configured.

## Read next

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
