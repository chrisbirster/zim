# 0002: Neovim-class Zig architecture

* **Status:** Accepted
* **Date:** 2026-08-29
* **Supersedes:** [0001: Core Design Principles](0001-core-design-principles.md)

## Context

Zim was initially described as a Zig editor core paired with a SolidJS graphical frontend and JSON-RPC/WebSocket transport.

The project direction has been clarified: Zim should be much closer in spirit to Neovim—a terminal-native, modal, extensible editor whose core is independent of any external GUI.

The architecture needs to prioritize becoming a real editor quickly while preserving the ability to support plugins, headless automation, remote clients, and optional graphical UIs later.

## Decision

Zim will be built as a **Neovim-class editor implemented in Zig**.

### Pure Zig editor and TUI first

The first useful Zim will require only Zig/native dependencies. The built-in terminal UI lives in the same process as the editor core and calls it directly.

Normal editing must not depend on HTTP, WebSockets, JSON, JavaScript, a browser runtime, or a graphical shell.

### Neovim-style editor fundamentals

The core architecture will preserve the important editor concepts that make Vim/Neovim powerful:

- buffers independent from windows
- tab pages containing window layouts
- explicit modes
- composable counts, operators, motions, and text objects
- registers
- first-class commands and keymaps
- undo/redo and buffer revisions
- marks and extmark-like revision-aware annotations
- events/autocommands
- headless operation
- editor-owned LSP, jobs, terminals, diagnostics, and parsing state

These ideas guide Zim's architecture, but Zim is not automatically API-compatible with Neovim.

### Lua as the primary embedded extension language

Zim will support Lua configuration and plugins.

The intended configuration entrypoint is `~/.config/zim/init.lua`.

Lua plugins will interact with Zim through the public editor API. They should be able to register commands, keymaps, event handlers/autocommands, and use buffer/window/editor capabilities exposed intentionally by the core.

The specific Lua runtime (such as PUC Lua or LuaJIT) will be chosen after a portability/performance spike. The API should not be unnecessarily coupled to one runtime's implementation details.

### One conceptual public editor API

Zim will expose stable editor concepts for extensions and clients: buffers, windows, tab pages, options, commands, keymaps, events, marks/extmarks, diagnostics, jobs, LSP, and UI attachment.

Embedded Lua calls this API directly in-process.

### MessagePack-RPC for external clients and plugins

External processes will communicate with Zim using MessagePack-RPC.

This includes:

- remote plugins
- automation tools
- embedding hosts
- headless clients
- optional external graphical UIs

Initial transports should favor local IPC and stdio. Network exposure is not a core requirement.

### Headless mode is first-class

Zim will support running the editor core without initializing the TUI.

Headless mode must use the same buffer, command, mode, Lua, event, and API implementations used by the interactive editor.

### External UIs are optional and later

An external GUI, including a possible SolidJS/system-WebView frontend, may be built later.

It must attach to the existing editor engine rather than duplicating buffer, modal editing, LSP, job, or terminal semantics.

A high-frequency UI attach protocol can expose grid/cursor/mode/highlight/command-line events over the same RPC transport.

### Prefer simple implementations first

Zim will not copy complexity merely because Neovim contains it.

Examples:

- begin with a simple understandable text-buffer representation
- begin with linear undo before an undo tree
- begin with one TUI process before designing a daemon/session broker
- add abstractions and optimized data structures when benchmarks or features require them

## Consequences

This decision means:

- SolidJS is removed from the initial implementation requirements.
- Node.js/Vite are not dependencies of the first usable Zim.
- JSON-RPC/WebSocket is no longer the planned plugin/client protocol.
- The first engineering milestone must produce a terminal editor, not an RPC server.
- TUI/editor behavior should be testable without plugins or external clients.
- Lua becomes a core extension requirement after editing fundamentals are stable.
- MessagePack-RPC becomes a core external-extension requirement after the public API exists.
- The codebase must maintain a clean buffer/window/editor separation.
- UI rendering must not become the owner of editing semantics.
- Future graphical clients remain possible without changing Zim's identity.

## Non-goals

This ADR does not commit Zim to:

- full Neovim API compatibility
- running existing Neovim plugins unchanged
- reproducing every Vim edge case immediately
- LuaJIT specifically
- Tree-sitter specifically
- a GUI implementation timeline
- remote/network editing

Those are separate decisions to make when the core editor provides enough evidence to evaluate them well.

## First validation milestone

This architecture is validated when:

```bash
zim file.txt
```

opens a Zig TUI in which a user can:

- enter Normal and Insert modes
- move the cursor
- insert/delete text
- undo/redo
- `:w`
- `:q`

and the same editing semantics can be exercised without a terminal in headless tests.

That milestone proves the core/TUI boundary before extensibility layers are added.
