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

**Status: complete.**

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
- [x] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [x] exact merged-main CI green

**Exit condition:** common editor customization no longer requires recompiling Zim, and the same public Zig API remains authoritative underneath Lua.

## v0.4.0 — Plugin System + Package Management

**Status: complete.**

**Goal:** make third-party in-process extensions first-class.

- [x] runtime/plugin search paths
- [x] Lua module/plugin discovery
- [x] deterministic plugin initialization lifecycle
- [x] plugin failure isolation/reporting with partial registration rollback
- [x] Git-backed install/update/remove
- [x] plugin lockfile with exact commit revisions
- [x] version/API/capability compatibility metadata
- [x] `:PackAdd`, `:PackUpdate`, `:PackRemove`, `:PackList`
- [x] command/keymap/plugin discovery
- [x] real Git-backed install/update/remove lifecycle test
- [x] plugin author/install documentation
- [x] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [x] exact merged-main CI green

**Exit condition:** a user can install, pin, load, update, remove, list, and diagnose useful Zim plugins without a third-party package manager.

## v0.5.0 — Zen Workspace

**Status: complete.**

**Goal:** deliver Zim's opinionated workspace UX on top of public primitives.

- [x] centered editor zone with breathing space
- [x] left Project zone
- [x] right Context zone
- [x] collapsible Project/Context rails
- [x] responsive collapse behavior for narrow terminals
- [x] Hondo-native focus traversal between Project, Editor, and Context
- [x] handled editor keystrokes remain on the native Zig/Hondo path
- [x] Symbols context surface with native result summary
- [x] Diagnostics context surface with native diagnostic summary
- [x] References context surface with reference-specific result summary
- [x] Git context surface
- [x] Quickfix context surface
- [x] Tests context surface
- [x] coarse project/LSP state bridge through NativeView notifications
- [x] coherent 0.5.0 executable/Lua/plugin/build versioning
- [x] Hondo integration coverage for focus/collapse/responsive/native-key behavior
- [x] user-facing Zen Workspace documentation
- [x] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [x] exact merged-main CI green

Validation evidence: squash-merged main commit `cbc41cf9fde6065ffe078080aabd63dbf49f9c05` passed CI #165 on Ubuntu, macOS, and Windows; Ubuntu also passed the pinned real-ZLS 0.16.0 smoke.

**Exit condition:** Zim has its recognizable workspace layout without making the UI framework own editor semantics.

## v0.6.0 — Pins

**Status: complete.**

**Goal:** make project navigation fast and persistent.

- [x] stable ordered native Pins model with persistent IDs
- [x] persist project-relative file path, line, column, and optional label
- [x] add/remove/reorder/list/jump operations
- [x] project/session persistence with restart restore and missing-target tolerance
- [x] linewise direct jumps with `'1` through `'9`
- [x] exact line/column direct jumps with backtick + `1` through `9`
- [x] `:PinAdd`, `:PinRemove`, `:PinMove`, `:PinJump`, and `:PinList`
- [x] centered Hondo pin switcher
- [x] Project-zone summary for the first nine Pins
- [x] public Zig Pins API
- [x] Lua `zim.pin` bindings and plugin `pins` capability
- [x] persistence/model/Lua API tests
- [x] Hondo integration coverage proving handled Pin navigation remains native
- [x] coherent 0.6.0 executable/Lua/plugin/build versioning
- [x] user-facing Pins documentation
- [x] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [x] exact merged-main CI green

Validation evidence: exact PR head `8491d95e913f18f33d4748d67ae9e0837b69df15` passed CI #167. Squash-merged main commit `3f46970a553fb5a37017eed039b782fe9af02152` passed CI #168 on Ubuntu, macOS, and Windows; Ubuntu also passed the pinned real-ZLS 0.16.0 smoke.

**Exit condition:** Pins survive restart, are reorderable and scriptable, support fast direct jumps 1–9, and are visible/selectable from the Zen Workspace without weakening the native editor hot path.

## v0.7.0 — Extmarks + Plugin UI Primitives

**Status: complete.**

**Goal:** give plugins and language tooling durable annotation/UI primitives without moving editor semantics out of Zig.

- [x] namespace-owned extmark IDs and registry
- [x] stable buffer-owned native Extmark model
- [x] ranged extmarks with independent start/end gravity
- [x] edit tracking through insertion/deletion/replacement
- [x] edit tracking through undo/redo
- [x] edit tracking through formatting and LSP WorkspaceEdits
- [x] anchored native decorations/highlights
- [x] signs/gutter metadata
- [x] end-of-line virtual text/annotations
- [x] editor-owned diagnostics publishing API
- [x] LSP diagnostics projected into the same extmark primitive
- [x] native floating/popup model with Zig-owned selection
- [x] passive Hondo popup rendering
- [x] completion popup model using parsed LSP completion items
- [x] native completion selection/cancel/accept behavior
- [x] completion acceptance inserts the selected LSP `insertText`
- [x] public Zig namespace/extmark/diagnostics/popup API
- [x] Lua `zim.extmark`, `zim.diagnostic`, and `zim.ui` bindings
- [x] plugin capabilities for `extmarks`, `diagnostics`, and `ui`
- [x] integration tests proving edit tracking and native UI ownership
- [x] coherent 0.7.0 executable/Lua/plugin/build versioning
- [x] user-facing Extmarks/Diagnostics/Plugin UI documentation
- [x] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [x] exact merged-main CI green

Validation evidence: implementation preflight head `6a414e981021ccea8dc7dd24a5ff341b4412d092` passed formatting, the Solid/Hondo bundle, the pure core suite, and Hondo integration. Exact release PR head `b4c346e458a95b3358dc0428721f785340c4cd12` passed CI #169 (run `33828310601`) on Ubuntu, macOS, and Windows; Ubuntu also passed the pinned real-ZLS 0.16.0 smoke. Squash-merged main commit `4bc4faac008d35480017e1b49f6535640f514720` passed CI #170 (run `33828961675`) on Ubuntu, macOS, and Windows; Ubuntu again passed the real-ZLS smoke.

**Exit condition:** a Lua plugin can create a namespace, place durable annotations that track edits, render highlights/signs/virtual text, publish diagnostics, and drive a native popup/completion surface through the public Zim API.

## v0.8.0 — Jobs + Terminal

**Status: implementation complete; final exact-head validation in progress.**

**Goal:** support build, test, tool, and interactive shell workflows without leaving Zim while preserving the Zig-native editor hot path.

- [x] native editor-owned asynchronous `JobManager`
- [x] stable `JobId`/status/snapshot model
- [x] argv-based process spawning with explicit cwd/environment/stdin options
- [x] independent stdout/stderr streaming with live visibility
- [x] bounded output buffering and truncation metadata
- [x] cancellation, wait, and completed-process cleanup
- [x] public Zig job start/stop/status/stdout/stderr API
- [x] built-in `:JobStart`, `:JobStop`, and `:JobList`
- [x] Lua `zim.job.start/stop/status/stdout/stderr`
- [x] plugin `jobs` capability metadata
- [x] PTY abstraction with POSIX `forkpty` backend
- [x] Windows ConPTY backend
- [x] native terminal session manager
- [x] Zig-owned terminal screen state/parser
- [x] `:terminal [command]` and terminal reattach behavior
- [x] native terminal input ownership and `Ctrl-C` forwarding
- [x] terminal resize/input/exit lifecycle
- [x] passive Hondo rendering of native terminal state
- [x] job lifecycle/streaming/cancellation tests
- [x] PTY, terminal session, terminal screen, controller, Lua job, and plugin capability tests
- [x] coherent 0.8.0 executable/Lua/plugin/build versioning
- [x] user-facing Jobs + Terminal and updated plugin documentation
- [ ] final doc-inclusive exact-head CI green on Ubuntu/macOS/Windows
- [ ] exact merged-main CI green

**Exit condition:** a Zig or Lua extension can start a tool asynchronously, receive separated stdout/stderr without blocking the editor, inspect or stop it safely, and a user can open an interactive terminal whose process, PTY, input, resize, and rendered state remain owned by native Zim.

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
