# Zim Roadmap

This roadmap tracks the path from the current bootstrap executable to a usable Neovim-class editor implemented in Zig.

The canonical repository is **https://github.com/chrisbirster/zim**.

## North star

The first important milestone is not RPC, a GUI, or a plugin system.

It is this:

```bash
zim src/main.zig
```

opens a real terminal editor where a developer can enter Normal/Insert mode, move, edit, undo, save, and quit reliably.

Everything else builds on that editor core.

## Current state

Today Zim has:

- [x] Zig project/bootstrap
- [x] native executable
- [x] startup identity/banner
- [x] current-working-directory resolution
- [x] canonical GitHub repository
- [x] documented Neovim-class architectural direction

It does **not** yet have terminal raw-mode handling, a screen renderer, a buffer model, cursor/editing semantics, modes, keymaps, commands, Lua, MessagePack-RPC, LSP, or a plugin system.

## Milestone 0 — Runtime and terminal foundation

**Goal:** make Zim a safe, testable terminal application.

- [ ] shrink `main.zig` into process/bootstrap code
- [ ] add app startup/shutdown orchestration
- [ ] parse `zim`, `zim <file>`, `zim <dir>`, `--help`, `--version`, and `--headless`
- [ ] add CI for format/build/tests on supported platforms
- [ ] initialize terminal raw mode
- [ ] always restore terminal state on clean exit/error paths
- [ ] decode keyboard input
- [ ] handle terminal resize
- [ ] build a cell-grid renderer
- [ ] diff frames and emit only changed cells
- [ ] add a tiny event loop
- [ ] add tests for input decoding and grid diffing

**Exit condition:** Zim can enter/leave the terminal safely, receive input, redraw efficiently, and survive resize/quit without corrupting the shell.

## Milestone 1 — Real editor vertical slice

**Goal:** become a small but genuine text editor.

- [ ] create `Editor` top-level state
- [ ] create `Buffer`
- [ ] use a simple line-oriented text representation first
- [ ] load a file into a buffer
- [ ] create `Window` as a view over a buffer
- [ ] add cursor state
- [ ] implement Normal mode
- [ ] implement Insert mode
- [ ] implement basic insertion/deletion
- [ ] implement `h`, `j`, `k`, `l`
- [ ] implement `i`, `a`, `o`, Escape
- [ ] implement `x`
- [ ] implement `:w`
- [ ] implement `:q`
- [ ] track modified state
- [ ] save atomically/safely where practical
- [ ] test editing semantics without a TUI
- [ ] add one PTY end-to-end open → edit → save → quit test

**Exit condition:** `zim file.txt` is a usable minimal modal editor.

## Milestone 2 — Vim editing grammar

**Goal:** make Zim feel like a modal editor rather than a conventional editor with Vim-like shortcuts.

- [ ] explicit mode state machine
- [ ] Operator Pending mode
- [ ] Visual mode
- [ ] Visual Line mode
- [ ] Visual Block mode
- [ ] counts
- [ ] motions
- [ ] operators
- [ ] operator + motion composition
- [ ] text objects
- [ ] registers
- [ ] yank/put
- [ ] change/delete/yank operators
- [ ] word motions
- [ ] line motions
- [ ] find/till character motions
- [ ] search motions
- [ ] repeat last change
- [ ] configurable keymaps
- [ ] comprehensive headless editing tests

**Exit condition:** common Vim editing sequences compose correctly instead of being individually hard-coded.

## Milestone 3 — Undo, buffers, windows, tabs, and command line

**Goal:** establish the core editor object model.

### Undo and revisions

- [ ] buffer changed tick/revision
- [ ] structured edit records
- [ ] undo
- [ ] redo
- [ ] change grouping
- [ ] evaluate undo-tree behavior after linear undo is reliable

### Buffers

- [ ] multiple loaded buffers
- [ ] buffer list
- [ ] hidden/unlisted concepts only if needed
- [ ] safe unsaved-buffer behavior

### Windows

- [ ] multiple windows displaying buffers
- [ ] horizontal split
- [ ] vertical split
- [ ] split layout tree
- [ ] per-window cursor/view state

### Tab pages

- [ ] tab page owns a window layout
- [ ] create/close/switch tab pages

### Command line

- [ ] command-line mode
- [ ] command parsing
- [ ] command registry
- [ ] command completion foundation
- [ ] core commands such as `edit`, `write`, `quit`, `buffer`, `split`, `vsplit`, and `tabnew`

**Exit condition:** Zim has the buffer/window/tab/command architecture expected of a serious Vim-family editor.

## Milestone 4 — Public API, events, Lua configuration, and plugins

**Goal:** make Zim programmable without turning extension hooks into internal coupling.

### Public API

- [ ] define stable handle/ID types for buffers/windows/tabpages
- [ ] expose options
- [ ] expose buffer operations
- [ ] expose window/tab operations
- [ ] expose commands
- [ ] expose keymaps
- [ ] expose marks/extmarks
- [ ] expose events/autocommands

### Events/autocommands

- [ ] typed event registry
- [ ] buffer lifecycle events
- [ ] mode transition events
- [ ] window/tab events
- [ ] deterministic callback ordering rules

### Lua

- [ ] select embedded Lua runtime through a portability/performance spike
- [ ] load `~/.config/zim/init.lua`
- [ ] expose `zim` Lua API namespace
- [ ] Lua option access
- [ ] Lua keymap registration
- [ ] Lua command registration
- [ ] Lua autocommands/events
- [ ] Lua buffer/window APIs
- [ ] Lua plugin loading
- [ ] plugin error isolation/reporting
- [ ] API conformance tests from Lua

**Exit condition:** users can configure Zim substantially in Lua and write useful in-process plugins using documented APIs.

## Milestone 5 — Project and language tooling

**Goal:** make Zim useful for real programming work.

### Search/files

- [ ] file open/completion
- [ ] fuzzy file finder foundation
- [ ] project text search
- [ ] ignore-file handling
- [ ] filesystem watching where useful

### Syntax

- [ ] parsing/highlighting subsystem
- [ ] evaluate/integrate Tree-sitter
- [ ] incremental highlight updates
- [ ] highlight groups

### LSP

- [ ] spawn/manage one language server
- [ ] initialize/shutdown lifecycle
- [ ] buffer open/change/save synchronization
- [ ] diagnostics
- [ ] hover
- [ ] go-to-definition
- [ ] references
- [ ] completion
- [ ] formatting

### Jobs and terminal

- [ ] asynchronous jobs
- [ ] stdout/stderr streaming
- [ ] cancellation
- [ ] PTY abstraction
- [ ] `:terminal`
- [ ] terminal buffer/view

**Exit condition:** Zim can be used for normal edit/build/search/LSP workflows on a real codebase.

## Milestone 6 — Marks, extmarks, diagnostics, and richer editor primitives

**Goal:** provide the primitives required by serious plugins and language tooling.

- [ ] user marks
- [ ] revision-aware extmarks
- [ ] ranged extmarks
- [ ] decorations/highlights anchored to text
- [ ] virtual text/annotations if justified
- [ ] editor-owned diagnostic store
- [ ] signs/gutter metadata
- [ ] folds
- [ ] popup/floating-window primitives
- [ ] completion popup model

**Exit condition:** language tooling and plugins can annotate/edit buffers without relying on fragile raw positions or TUI-specific hacks.

## Milestone 7 — MessagePack-RPC and remote plugins

**Goal:** expose the editor as a programmable process in the Neovim tradition.

- [ ] MessagePack codec integration
- [ ] MessagePack-RPC request/response/notification framing
- [ ] API metadata and versioning
- [ ] capability discovery
- [ ] stdio channel
- [ ] Unix-domain socket channel
- [ ] Windows local IPC equivalent
- [ ] `--listen`/attach workflow as appropriate
- [ ] headless RPC integration tests
- [ ] remote-plugin registration
- [ ] remote-plugin lifecycle
- [ ] remote event subscriptions
- [ ] clear errors for API/protocol mismatches

**Exit condition:** an external process can attach to Zim, inspect/edit state, register extension behavior, and receive events through MessagePack-RPC.

## Milestone 8 — Daily-driver hardening

**Goal:** make Zim trustworthy enough to replace Neovim for real work.

- [ ] robust crash/error recovery
- [ ] session support
- [ ] swap/recovery strategy if needed
- [ ] configurable options model
- [ ] colorschemes/highlight configuration
- [ ] runtime/plugin search paths
- [ ] command/keymap discovery
- [ ] help/documentation system
- [ ] Git integration basics
- [ ] performance benchmarks
- [ ] large-file testing
- [ ] startup profiling
- [ ] packaging/installers
- [ ] macOS/Linux/Windows hardening

**Exit condition:** Zim can serve as a primary terminal editor for sustained project work.

## Milestone 9 — External UI protocol and optional GUI

**Goal:** prove that Zim is an editor engine independent of its built-in terminal UI.

Do this only after the TUI/editor/plugin foundation is healthy.

- [ ] external UI attach/detach API
- [ ] grid resize events
- [ ] grid line events
- [ ] cursor events
- [ ] mode/highlight events
- [ ] command-line events
- [ ] popup/completion events
- [ ] multi-client behavior rules
- [ ] optional SolidJS/system-WebView GUI experiment
- [ ] benchmark GUI transport/input/render latency against TUI

**Exit condition:** an external GUI can drive the same editor core without owning buffers, modal semantics, LSP state, or terminal processes.

## Immediate next 10 engineering steps

These are the next tasks to implement, in order:

1. **Split bootstrap from app state** — make `main.zig` a tiny entrypoint.
2. **Implement CLI parsing** — `zim`, `zim <file>`, `<dir>`, `--help`, `--version`, `--headless`.
3. **Add CI** — formatting, build, and tests on supported platforms.
4. **Implement terminal lifecycle** — raw mode, alternate screen if chosen, cursor visibility, guaranteed restoration.
5. **Build the cell-grid renderer** — current/previous frame and minimal terminal diff output.
6. **Decode terminal input** — keys, escape sequences, resize, and clean quit handling.
7. **Create `Editor`, `Buffer`, and `Window`** — simple text storage and one window onto one buffer.
8. **Implement Normal + Insert mode** — cursor motion, insertion, deletion, Escape.
9. **Implement the first command line** — enough for `:w` and `:q`.
10. **Add headless editor tests and one PTY smoke test** — prove the same core semantics work with and without rendering.

After step 10, Zim should be a crude but real editor. Only then should we broaden the Vim grammar.

## Engineering rules

- The keystroke-to-render hot path stays inside Zig.
- The built-in TUI calls the core directly; do not route normal editing through RPC.
- Keep buffers separate from windows and tab pages.
- Model Vim editing through composable operators/motions/text objects.
- Keep editor behavior testable without a terminal.
- Lua uses the public editor API, not arbitrary internal pointers.
- Remote plugins use MessagePack-RPC.
- Do not build a GUI before the terminal editor is genuinely useful.
- Do not promise Neovim plugin/API compatibility without an explicit compatibility project.
- Prefer simple buffer/rendering structures until benchmarks justify more complex ones.
- Keep `main` buildable; substantial work lands through focused branches/PRs.
