# Extmarks, Diagnostics, and Plugin UI

Zim v0.7.0 introduces durable, buffer-owned annotations and a small native popup model for plugins and language tooling.

The design rule is the same as the rest of Zim: **Zig owns editor semantics; Hondo renders coarse UI state.** Extmark identity, range tracking, diagnostic ownership, popup selection, and completion insertion all remain native.

## Namespaces

Extmarks are owned by a namespace. A namespace gives a plugin or built-in subsystem an isolated set of annotations that can be cleared or removed without touching another subsystem.

Lua:

```lua
local ns = zim.extmark.namespace('my-plugin')
```

Creating the same namespace name returns the existing namespace. Delete one with:

```lua
zim.extmark.namespace_del(ns)
```

Zim reserves its own LSP diagnostics namespace internally.

## Extmarks

An extmark is attached to a buffer and stores a stable ID, namespace, start position, optional end position, gravity, and optional decoration metadata.

Lua positions are one-based line/column coordinates:

```lua
local buffer = zim.buf.current()
local ns = zim.extmark.namespace('demo')

local id = zim.extmark.set(buffer, ns, 3, 5, {
  end_line = 3,
  end_column = 12,
  highlight = 'DiagnosticWarn',
  sign = '!',
  virtual_text = 'check this',
  right_gravity = 'right',
  end_right_gravity = 'left',
})
```

Remove one mark:

```lua
zim.extmark.del(buffer, ns, id)
```

Clear all marks in one namespace for one buffer:

```lua
zim.extmark.clear(buffer, ns)
```

## Edit tracking and gravity

Extmarks track the text they are anchored to rather than remaining at a raw line number. The buffer updates them through the same native edit primitive used by normal insert/delete operations, undo/redo, text replacement, formatting, and LSP WorkspaceEdits.

`right_gravity` controls what happens when text is inserted exactly at the start anchor:

- `right`: the start moves after newly inserted text.
- `left`: the start remains before newly inserted text.

`end_right_gravity` applies the same rule to the end anchor. The defaults are start=`right`, end=`left`.

v0.7 uses byte-offset anchors internally and converts line/column positions at the public API boundary. It does not claim Neovim extmark compatibility.

## Decorations

The native `EditorView` paints extmark decorations after syntax highlighting and before the cursor.

### Highlights

A ranged extmark can repaint the anchored text. v0.7 has built-in styles for:

- `DiagnosticError`
- `DiagnosticWarn`
- `DiagnosticInfo`
- `DiagnosticHint`

Unknown highlight names currently fall back to Zim's default extmark accent. v0.7 is not yet a general colorscheme/highlight-definition API.

### Signs

`sign` paints a one-cell marker in the editor gutter at the extmark start line.

```lua
zim.extmark.set(buffer, ns, 8, 1, { sign = '!' })
```

### Virtual text

`virtual_text` paints dim italic end-of-line annotation text when space is available.

```lua
zim.extmark.set(buffer, ns, 8, 1, { virtual_text = 'generated value' })
```

Virtual text is deliberately lightweight in v0.7: it is an annotation, not a second editable buffer or arbitrary layout surface.

## Diagnostics

Diagnostics use the same extmark primitive instead of a separate rendering system.

A plugin can replace its diagnostics for a buffer/namespace in one call:

```lua
local ns = zim.extmark.namespace('my-linter')
local buffer = zim.buf.current()

zim.diagnostic.publish(buffer, ns, {
  {
    line = 2,
    column = 4,
    end_line = 2,
    end_column = 9,
    severity = 'warning',
    message = 'suspicious value',
  },
  {
    line = 6,
    severity = 'error',
    message = 'missing result',
  },
})
```

Supported severities are:

- `error`
- `warning`
- `information`
- `hint`

Publishing first clears that namespace's existing diagnostics for the buffer, then creates diagnostic extmarks carrying highlight, sign, virtual text, message, and severity metadata.

Zim's LSP `publishDiagnostics` path now projects LSP diagnostics into the reserved diagnostics namespace using the same native mechanism.

## Plugin popup UI

v0.7 adds a small native popup model with an Hondo renderer. Plugins provide content, but Zig owns open/closed state and selection.

```lua
zim.ui.popup('Actions', {
  'Format document',
  'Run tests',
  'Open definition',
})
```

Close it explicitly with:

```lua
zim.ui.popup_close()
```

While a popup is open, navigation/accept/cancel are handled by the native editor path. Hondo receives the resulting coarse popup state and renders the centered floating surface.

v0.7 intentionally does not expose arbitrary Hondo nodes or JavaScript callbacks to plugins.

## Completion popup

LSP completion reuses the same native popup model with `kind = completion`.

When a completion response arrives:

1. Zig owns the parsed completion items.
2. Zig opens the completion popup and owns the selected index.
3. Hondo renders labels/details passively.
4. Native key handling moves or cancels the selection.
5. Accepting a completion inserts the selected LSP `insertText` into the buffer through the native edit path.

No handled completion keystroke needs to cross into JavaScript.

## Public Zig API

The stable facade remains `src/api.zig`. v0.7 re-exports namespace/extmark option and ID types and exposes operations for:

- namespace create/delete
- extmark set/delete/clear
- diagnostics publication
- popup open/close

Lua is a binding over those public concepts rather than a privileged internal API.

## Plugin capabilities

Plugin manifests can advertise the following v0.7 compatibility capabilities:

```text
extmarks
diagnostics
ui
```

Capabilities are compatibility metadata, not sandbox permissions. Installed plugins remain trusted in-process Lua code.

## Deliberate v0.7 limits

v0.7 does not include:

- Neovim API compatibility
- arbitrary plugin-defined Hondo components
- a general highlight/colorscheme-definition API
- extmark persistence across editor restart
- extmark serialization into Pins
- terminal/job UI
- MessagePack-RPC access to extmarks or popups

Jobs/terminal belong to v0.8 and remote API exposure belongs to v0.9.
