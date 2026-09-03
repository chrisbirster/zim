# Pins

Zim v0.6.0 adds **Pins**: persistent, ordered project locations that can be jumped to quickly from native editor commands, modal key sequences, Lua, or the Zen Workspace.

Pins deliberately store file identity rather than runtime buffer IDs. A persisted pin is conceptually:

```text
id
project-relative path
line
column
optional label
```

Line and column values are 1-based. The stable `id` identifies the logical pin; its position in the ordered list is the user-facing slot.

## Why Pins are not buffers

Buffers are runtime editor objects. Pins must survive editor restarts, so a pin stores a file path plus a logical location and resolves that target when you jump.

This also leaves room for v0.7 extmarks to make pin locations revision-aware without requiring callers to adopt a different Pins API.

## Add a pin

Place the cursor where you want the pin and run:

```text
:PinAdd
```

Add an optional human-readable label:

```text
:PinAdd parser entry
```

The current file path, cursor line, cursor column, and optional label are persisted immediately.

`PinAdd` requires a file-backed buffer. Unsaved `[No Name]` buffers cannot be persisted as project locations.

## List and switch Pins

Run:

```text
:PinList
```

or, in Normal mode:

```text
gp
```

Zim opens a centered Hondo pin switcher. The switcher is application chrome only; the native Zig editor still owns its input.

Inside the switcher:

- `j` / Down selects the next pin
- `k` / Up selects the previous pin
- `Enter` jumps to the selected pin
- `1` through `9` jumps directly to that slot
- `Esc` or `q` closes the switcher

The first nine pins are also summarized in the Zen Workspace Project zone.

## Direct native jumps

Zim extends its existing mark-jump grammar for numeric Pin slots:

```text
'1   jump to pin 1, linewise
'2   jump to pin 2, linewise
...
'9   jump to pin 9, linewise
```

Use backtick for the exact saved column:

```text
`1   jump to pin 1, exact line + column
`9   jump to pin 9, exact line + column
```

Plain `1` through `9` remain available for normal Vim-style counts. Pin jumps therefore do not steal the editor's numeric count grammar.

These handled key sequences remain on the native Zig/Hondo input path; they are not routed through Solid/QuickJS.

## Commands

### Jump

```text
:PinJump 3
```

Jumps to slot 3 using the saved line and column.

### Remove

```text
:PinRemove 2
```

Removes slot 2 and compacts the ordered list.

### Reorder

```text
:PinMove 4 1
```

Moves slot 4 to slot 1 while preserving the pin's stable ID.

### List

```text
:PinList
```

Opens the centered pin switcher.

## Persistence

Pins are stored under Zim's configuration root rather than written into the project repository.

The configuration root follows the same platform rules as `init.lua`:

- `$XDG_CONFIG_HOME/zim`
- `%APPDATA%/zim`
- otherwise `~/.config/zim`

Each project gets a session Pins file under:

```text
<config-root>/sessions/<project-hash>.pins.json
```

For files inside the project root, Zim stores a project-relative path. Files outside that root fall back to their supplied path.

The persisted format includes a version, the next stable Pin ID, and the ordered pin records.

## Missing targets

A persisted pin may outlive a file. Jumping to a target that no longer exists does not silently create a new file; Zim reports the missing target and leaves the current editor location intact.

The pin remains in the list so the user can remove or reorder it deliberately.

## Public Zig API

The public `Api` exposes Pins through the same editor boundary used by other extension surfaces:

```text
pinCount(editor)
pinEntries(editor)
pinAdd(editor, label)
pinRemove(editor, slot)
pinMove(editor, from_slot, to_slot)
pinJump(editor, slot, exact)
```

The authoritative storage and navigation semantics remain owned by `Editor` / `pins.Store`; UI code does not maintain a parallel Pins model.

## Lua API

The embedded Lua API exposes:

```lua
local id = zim.pin.add('parser')

local pins = zim.pin.list()
for index, pin in ipairs(pins) do
  print(index, pin.id, pin.path, pin.line, pin.column, pin.label)
end

zim.pin.jump(1)
zim.pin.move(3, 1)
zim.pin.remove(2)
```

`zim.pin.list()` returns ordered records containing:

```text
id
path
line
column
label (when present)
```

Plugins can declare the `pins` capability in `zim-plugin.meta` when they require this surface.

## Events

v0.6 intentionally does **not** add `PinAdded` / `PinRemoved` / `PinMoved` autocommand events yet. The native Pins revision already drives the built-in workspace state, and the public API covers scripting needs without prematurely widening the stable event contract.

If real plugin use cases require dedicated Pin events, they can be added later with a concrete payload contract.

## Architecture

```text
                 Editor / pins.Store
                       │
        ┌──────────────┼───────────────┐
        │              │               │
   native keys      public API       persistence
   commands         + Lua            session JSON
        │              │
        └────── coarse nativeState ──────► Hondo Project/Popup
```

The central rule is unchanged from the Zen Workspace: **Hondo presents Pins; Zig owns Pins.**

## Validation

v0.6 tests cover:

- stable IDs and ordered movement
- project-relative persistence and restart restore
- labels and logical line/column storage
- public API-backed Lua add/list/jump behavior
- centered switcher rendering in Hondo
- switcher keyboard handling on the native path
- exact numeric Pin jumps
- linewise numeric Pin jumps
- proof that handled Pin navigation does not cross into JavaScript
