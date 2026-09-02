# Lua Configuration

Zim v0.3.0 embeds Lua 5.4 and binds it to the public Zig editor API introduced in v0.2.0. Lua configuration runs in the same process as the editor, while normal keystroke handling and rendering remain on the native Zig/Hondo path.

Zim does **not** implement the Neovim Lua API and does not promise Neovim plugin compatibility. The `zim` namespace is Zim's own intentionally small extension surface.

## Config discovery

Zim looks for one startup file, in this order:

1. `$XDG_CONFIG_HOME/zim/init.lua`
2. `%APPDATA%/zim/init.lua`
3. `$HOME/.config/zim/init.lua`

A missing config is normal and does not prevent startup. The config file is currently limited to 4 MiB.

Lua is embedded through a pinned Ziglua/Lua 5.4 dependency, so users do not need a system Lua installation.

## Minimal example

```lua
zim.opt.number = true
zim.opt.tabstop = 4
zim.opt.expandtab = true

zim.keymap.set('normal', 'z', 'i')

zim.command.create('Hello', function(args)
  zim.buf.set_text(args)
end, {
  description = 'Replace the current buffer with command arguments',
})

zim.autocmd.create('ModeChanged', function(ev)
  -- ev.event is "ModeChanged"
  -- ev.sequence is a monotonically increasing event sequence
end)
```

A Lua-created command is available from the command line:

```text
:Hello configured by lua
```

The callback receives `"configured by lua"` as its `args` string.

## `zim.version`

```lua
assert(zim.version == '0.3.0')
```

## Options: `zim.opt`

Supported v0.3 options:

| Option | Type | Meaning |
| --- | --- | --- |
| `number` | boolean | editor line-number option |
| `tabstop` | integer | tab width; validated by the public Zig options API |
| `expandtab` | boolean | expand tabs option |

Example:

```lua
zim.opt.number = true
zim.opt.tabstop = 8
zim.opt.expandtab = true

print(zim.opt.tabstop)
```

Unknown option names and invalid values raise Lua errors.

## Keymaps: `zim.keymap`

```lua
local id = zim.keymap.set(mode, lhs, rhs, opts)
local removed = zim.keymap.del(mode, lhs, opts)
```

Supported mode names:

- `normal` or `n`
- `insert` or `i`
- `visual` or `v`
- `visual_line`
- `visual_block`
- `operator_pending`
- `command_line`

Global mapping:

```lua
zim.keymap.set('normal', 'z', 'i')
```

Buffer-local mapping:

```lua
zim.keymap.set('normal', 'z', 'i', {
  buffer = zim.buf.current(),
})
```

Delete it with the same scope:

```lua
zim.keymap.del('normal', 'z', {
  buffer = zim.buf.current(),
})
```

### v0.3 keymap limitation

`lhs` and `rhs` are currently **one Unicode codepoint each**. This is the first stable mapping bridge, not the final mapping grammar. Multi-key sequences, special-key notation, callback mappings, recursive/non-recursive flags, and richer mapping metadata are future work.

Buffer-local public mappings are resolved before the event reaches the native editor component, but the resulting input still travels through Hondo's native editor dispatch path rather than JavaScript.

## Commands: `zim.command`

Create a command:

```lua
local id = zim.command.create('Greeting', function(args)
  zim.buf.set_text('hello ' .. args)
end, {
  description = 'Write a greeting into the current buffer',
})
```

Run it from Lua:

```lua
zim.command.execute('Greeting', 'world')
```

Or from Zim's command line:

```text
:Greeting world
```

Delete it:

```lua
local removed = zim.command.del('Greeting')
```

Command callbacks receive one string containing the text after the command name.

## Autocommands: `zim.autocmd`

Create an autocmd:

```lua
local id = zim.autocmd.create('BufWritePost', function(ev)
  print(ev.event, ev.buffer)
end)
```

With options:

```lua
local id = zim.autocmd.create('TextChanged', {
  once = true,
  buffer = zim.buf.current(),
}, function(ev)
  print('changed', ev.sequence)
end)
```

Delete it:

```lua
zim.autocmd.del(id)
```

Supported events:

- `EditorEnter`
- `EditorLeave`
- `BufEnter`
- `BufLeave`
- `BufWritePre`
- `BufWritePost`
- `TextChanged`
- `ModeChanged`
- `WinEnter`
- `WinLeave`
- `LspAttach`
- `LspDetach`
- `DiagnosticsChanged`

The callback receives an event table with:

- `event` — event name
- `sequence` — deterministic event sequence number
- `buffer` — buffer handle when the event has one
- `window` — window handle when the event has one
- `tab` — tab handle when the event has one

Autocommands reuse the public Zig event registry, including its snapshot semantics when registrations change during dispatch.

## Buffers: `zim.buf`

Current buffer handle:

```lua
local buffer = zim.buf.current()
```

Read text from a buffer handle:

```lua
local text = zim.buf.get_text(buffer)
```

If the argument is omitted, `get_text` uses the current buffer:

```lua
local text = zim.buf.get_text()
```

Replace the current buffer text:

```lua
zim.buf.set_text('new contents')
```

`set_text` currently targets the current buffer; arbitrary-buffer mutation is not part of the v0.3 Lua surface yet.

## Windows: `zim.win`

```lua
local window = zim.win.current()
local buffer = zim.win.buffer(window)
```

If the argument to `zim.win.buffer` is omitted, the current window is used.

## Tabs: `zim.tab`

```lua
local tab = zim.tab.current()
```

Buffer, window, and tab values are stable numeric handles owned by the public Zig API. Lua does not receive internal Zig pointers.

## LSP: `zim.lsp`

Start the configured language server for the current buffer:

```lua
zim.lsp.start()
```

Request methods return the native request id:

```lua
local hover_id = zim.lsp.hover()
local signature_id = zim.lsp.signature_help()
local definition_id = zim.lsp.definition()
local references_id = zim.lsp.references()
local document_symbols_id = zim.lsp.document_symbols()
local workspace_symbols_id = zim.lsp.workspace_symbols('query')
local rename_id = zim.lsp.rename('new_name')
local code_action_id = zim.lsp.code_action()
local formatting_id = zim.lsp.format()
local completion_id = zim.lsp.complete()
```

Requests raise a Lua error when the language server is not ready or the native request cannot be started.

The Lua bridge does not implement a second LSP client. It calls the same native LSP machinery used by Zim commands and editor features.

## Error behavior

Startup config evaluation errors are reported to stderr with the config path and prevent that config from completing, but there is no separate system-Lua process to crash.

Lua command and autocmd callbacks run with protected calls. A callback error is caught and surfaced in the editor status as a `Lua command:` or `Lua autocmd:` message instead of unwinding through the editor loop.

Native argument validation—for example an unknown option, invalid mode/event, invalid handle, or unsupported multi-codepoint mapping—raises a Lua error at the call site.

## Architecture rule

The important v0.3 invariant is:

```text
init.lua
   │
   ▼
embedded Lua 5.4
   │
   ▼
public Zim Zig API
   │
   ▼
editor core / native Hondo input
```

Lua is an adapter over Zim's public API, not an alternate editor implementation. The integration suite proves that a Lua-created buffer-local keymap changes native Hondo input, a Lua autocmd observes the resulting mode change, and a Lua-defined `:Command` mutates the editor through the same public API.

## Deliberately deferred past v0.3

The first Lua milestone does not yet attempt to provide:

- Neovim API compatibility
- a plugin search path or package manager
- `require()`-based Zim plugin discovery conventions
- multi-key or callback keymaps
- arbitrary-buffer mutation APIs
- extmarks/decorations/plugin UI primitives
- asynchronous job/terminal APIs
- MessagePack-RPC remote plugins

Those capabilities are staged in later roadmap milestones so the v0.3 configuration layer stays small and testable.
