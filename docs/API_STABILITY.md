# Zim 1.x Compatibility Policy

Zim 1.0 makes the extension boundary a compatibility-managed product surface rather than an implementation detail.

## Versioned surfaces

Zim exposes four related versions:

- **Zim version** — semantic product version (`1.0.0`).
- **Public API version** — native Zig/Lua editor concepts exposed to built-ins and extensions. v1 starts at `1`.
- **Plugin API version** — manifest compatibility gate for embedded Lua plugins. v1 starts at `1`.
- **RPC protocol/API versions** — MessagePack framing/handshake and remotely callable API. Both remain `1` for Zim 1.0.

`zim --version` and `zim --check` report these values. Remote clients can retrieve protocol/API metadata through `zim.api_info` and must handshake before editor methods are available.

## Stability rules

Throughout the Zim 1.x line:

- Existing documented command, keymap, autocommand, buffer/window/tab, job, Pins, extmark, diagnostic and plugin-UI behaviors will not be intentionally broken without a deprecation path.
- New optional fields, capabilities, commands, events and RPC methods may be added in a minor release.
- A plugin that declares plugin API version `1` remains loadable unless it depends on behavior explicitly documented as experimental.
- RPC protocol/API version `1` remains wire compatible. New methods may be advertised through capability discovery.
- Configuration errors, plugin errors and remote-client errors are not permitted to corrupt editor-owned state.

A deliberately incompatible public change requires either a new API/protocol version with negotiation or a new Zim major version.

## Modal grammar

The v1 modal editing grammar is part of the user-facing compatibility contract. Existing documented operators, motions, text objects, counts, registers, macros, marks and command-line entry behavior are stable for 1.x. New grammar may be added; existing grammar is not silently reassigned.

## Experimental surface

A feature is experimental only when its documentation says so. Experimental APIs may change in a minor release, but they must not bypass native ownership of buffers, windows, tabs, commands, keymaps, events, jobs, terminal state or extmarks.
