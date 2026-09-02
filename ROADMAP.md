# Zim Roadmap

Zim is a terminal-only, Zig-native modal programmer's editor. This roadmap is version-oriented and reflects the editor that exists now rather than the original bootstrap plan.

The canonical repository is **https://github.com/chrisbirster/zim**.

## Product rules

- The keystroke-to-render hot path stays in Zig.
- Buffers remain separate from windows and tab pages.
- Modal grammar is composable rather than a pile of shortcuts.
- Built-ins and extensions converge on one public editor API.
- Lua is the primary embedded configuration/plugin language.
- Remote plugins and automation use MessagePack-RPC.
- The TUI is the permanent product interface; there is no GUI milestone.

## v0.1.0 — Editor + language foundation

**Status: complete development baseline.**

Zim already has a real modal editor core, Hondo terminal UI, composable editing grammar, registers/macros/marks/jump history, undo, buffers/windows/tabs/splits, Tree-sitter-backed language services, and a native LSP client.

Phase 2 language tooling completed with:

- hover, signature help, definition, references, document/workspace symbols
- rename and workspace edits
- diagnostics and navigation
- code actions
- `textDocument/formatting`
- `textDocument/completion` protocol foundation
- pinned real-ZLS 0.16.0 subprocess lifecycle smoke testing
- Ubuntu/macOS/Windows CI

## v0.2.0 — Programmable Core

**Status: complete.**

**Goal:** establish the stable Zig-side extension contract before embedding Lua.

- [x] typed stable buffer/window/tab handles
- [x] public buffer/window/tab state API
- [x] typed options API
- [x] command registry and invocation API
- [x] global and buffer-local keymap API
- [x] typed event model
- [x] autocommand registry
- [x] deterministic callback ordering
- [x] safe snapshot semantics when callbacks mutate registrations
- [x] API-driven key handling emits editor events
- [x] headless API conformance tests
- [x] exact-head CI green on Ubuntu/macOS/Windows

**Exit condition:** core features have a documented Zig API boundary that Lua and future RPC bindings can call without arbitrary internal pointers.

## v0.3.0 — Lua Configuration

**Status: implementation complete; final merge/main validation pending.**

**Goal:** make Zim substantially configurable through `init.lua` without moving the native editing hot path out of Zig.

- [x] embed pinned Lua 5.4 through Ziglua with no system Lua dependency
- [x] load `XDG_CONFIG_HOME/zim/init.lua`, `%APPDATA%/zim/init.lua`, or `~/.config/zim/init.lua`
- [x] expose the `zim` namespace
- [x] `zim.opt`
- [x] global and buffer-local `zim.keymap`
- [x] `zim.command` registration/deletion/execution
- [x] typed `zim.autocmd` registration/deletion with once and buffer filters
- [x] buffer/window/tab handle APIs
- [x] LSP-facing API bindings
- [x] protected Lua callback errors without crashing the editor
- [x] Lua conformance tests against the public Zig API
- [x] Lua-created keymap/command/autocmd integration through native Hondo input
- [x] documentation for the v0.3 Lua surface
- [ ] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [ ] exact merged-main CI green

**Exit condition:** common editor customization no longer requires recompiling Zim, and the same public Zig API remains authoritative underneath Lua.

## v0.4.0 — Plugin System + Package Management

**Goal:** make third-party in-process extensions first-class.

- [ ] runtime/plugin search paths
- [ ] Lua module/plugin discovery
- [ ] deterministic plugin initialization lifecycle
- [ ] plugin failure isolation/reporting
- [ ] Git-backed install/update/remove
- [ ] plugin lockfile and pinned revisions
- [ ] version/capability compatibility metadata
- [ ] `:PackAdd`, `:PackUpdate`, `:PackRemove`, `:PackList`
- [ ] command/keymap/plugin discovery

**Exit condition:** a user can install, pin, load, update, and diagnose useful Zim plugins without a third-party package manager.

## v0.5.0 — Zen Workspace

**Goal:** deliver Zim's opinionated workspace UX on top of public primitives.

- [ ] centered editor zone
- [ ] left Project zone
- [ ] right Context zone
- [ ] collapsible breathing-space panels
- [ ] Hondo-native focus/input semantics
- [ ] Symbols view
- [ ] Diagnostics view
- [ ] References view
- [ ] Git/quickfix/test context surfaces
- [ ] preserve the Zig-native editor hot path

**Exit condition:** Zim has its recognizable workspace layout without making the UI framework own editor semantics.

## v0.6.0 — Pins

**Goal:** make project navigation fast and persistent.

- [ ] add/remove/reorder pins
- [ ] direct jumps 1–9
- [ ] centered pin switcher
- [ ] project/session persistence
- [ ] public Pins API and Lua bindings

## v0.7.0 — Extmarks + Plugin UI Primitives

**Goal:** give plugins and language tooling durable annotation/UI primitives.

- [ ] namespaces
- [ ] revision-aware/ranged extmarks
- [ ] anchored decorations/highlights
- [ ] signs/gutter metadata
- [ ] virtual text/annotations where justified
- [ ] editor-owned diagnostics publishing API
- [ ] floating/popup primitives
- [ ] completion popup model

## v0.8.0 — Jobs + Terminal

**Goal:** support build/test/tool workflows without leaving Zim.

- [ ] asynchronous jobs
- [ ] stdout/stderr streaming
- [ ] cancellation
- [ ] PTY abstraction
- [ ] `:terminal`
- [ ] terminal buffer/view
- [ ] Lua job API

## v0.9.0 — MessagePack-RPC + Remote Plugins

**Goal:** expose the same editor concepts to external processes.

- [ ] MessagePack codec
- [ ] RPC request/response/notification framing
- [ ] API metadata/versioning
- [ ] capability discovery
- [ ] stdio channel
- [ ] Unix-domain socket channel
- [ ] Windows local IPC equivalent
- [ ] remote command/keymap/autocmd registration
- [ ] headless RPC integration tests
- [ ] clear protocol/API mismatch diagnostics

## v1.0.0 — Daily Driver

**Goal:** make Zim trustworthy as a primary Neovim-class terminal editor.

- [ ] stable modal grammar and public API policy
- [ ] robust crash/error recovery
- [ ] sessions/recovery strategy
- [ ] colorschemes/highlight configuration
- [ ] built-in help/documentation
- [ ] packaging/installers
- [ ] startup and large-file benchmarks
- [ ] macOS/Linux/Windows terminal hardening
- [ ] SSH/tmux behavior testing
- [ ] sustained real-project dogfooding

**Exit condition:** Zim can realistically be used as a primary terminal programmer's editor with documented compatibility and extension guarantees.
