# Programmable Core

Zim `v0.2.0` establishes the Zig-side editor API that later Lua and MessagePack-RPC layers will bind to.

The important rule is simple: extensions do not get arbitrary internal pointers. They operate through stable handles and public registries owned by `src/api/root.zig`.

## Stable handles

The API exposes typed `BufferHandle`, `WindowHandle`, and `TabHandle` values. They wrap the editor's monotonic IDs so callers cannot accidentally pass a window ID where a buffer handle is required.

Handles can be validated before use:

```zig
const buffer = api.currentBuffer(&editor);
if (api.bufferIsValid(&editor, buffer)) {
    const text = api.bufferText(&editor, buffer).?;
    _ = text;
}
```

## Options

`v0.2.0` starts with typed core options:

- `number`
- `tabstop`
- `expandtab`

Type mismatches are rejected and `tabstop` is range validated. Lua's future `zim.opt` surface will bind to this API instead of introducing a parallel option store.

## Commands

Commands have stable numeric IDs, owned names/descriptions, callback functions, optional user data, discovery, deletion, and invocation.

Registration order does not affect lookup semantics, and command callbacks may mutate the registry because execution copies the callback target before invoking it.

## Keymaps

The public keymap registry supports:

- global mappings
- buffer-local mappings
- replacement of an existing mapping for the same scope/mode/key
- deletion/discovery

Global mappings update the editor's existing native keymap table. Buffer-local mappings are resolved by the public API's `handleKey` entrypoint before native global mappings are applied.

The current editor keymap primitive is a single codepoint mapping. Multi-key sequence/trie support can evolve behind the public API without changing the Lua-facing architecture.

## Events and autocommands

Typed event kinds include editor/buffer/window lifecycle, writes, text changes, mode changes, LSP lifecycle, and diagnostics changes.

Autocommands support optional buffer filtering and one-shot callbacks.

### Ordering

Callbacks execute in registration order.

### Mutation during dispatch

Dispatch uses snapshot semantics. The set of callbacks that will run for an event is captured before the first callback executes.

Therefore:

- a callback registered during an event does not run until a later event
- deleting a callback during dispatch does not remove it from the current snapshot
- `once` callbacks are removed after their invocation
- nested event emission is allowed and receives its own monotonically increasing sequence number

This makes callback behavior deterministic and avoids iterator invalidation when extensions modify registrations from inside callbacks.

## API-driven editor events

`Api.handleKey` observes the editor before and after native key handling and emits public events for:

- window changes
- buffer changes
- mode changes
- text revision changes

`Api.setCurrentText` emits `text_changed` and `Api.writeCurrent` wraps native writes with `buffer_write_pre`/`buffer_write_post`.

The TUI remains a direct Zig hot path. Lua integration in `v0.3.0` will bind to this public layer rather than routing normal editing through RPC.

## What v0.2.0 does not include

- embedded Lua
- `init.lua`
- plugin loading/package management
- MessagePack-RPC
- extmarks/plugin UI primitives

Those are separate milestones built on this contract.
