# Zim Architecture

## Architectural thesis

Zim is a Neovim-class editor implemented in Zig.

The built-in terminal UI is the first client, but unlike an external client it lives in the same process and talks to the editor core through direct Zig APIs. External plugins, automation tools, embedding hosts, and future UIs use the public editor API over MessagePack-RPC.

```text
                     ┌──────────────────────┐
                     │       Zig TUI        │
                     └──────────┬───────────┘
                                │ direct Zig calls
                                ▼
┌──────────────────────────────────────────────────────────────┐
│                         Zim Core                             │
│                                                              │
│ buffers   windows   tabpages   modes   keymaps   commands    │
│ undo      marks     extmarks   events  options   registers   │
│ search    syntax    LSP        jobs    PTYs      diagnostics │
└─────────────────┬───────────────────────────────┬────────────┘
                  │                               │
          direct public API                 MessagePack-RPC
                  │                               │
             embedded Lua              ┌──────────┼───────────┐
                                       │          │           │
                                  remote      automation   future UI
                                  plugins       clients
```

A future SolidJS/WebView GUI is permitted, but it is an optional external UI and must not change the editor's core architecture.

## Process model

The default interactive editor is one native process:

```text
zim
├── editor core
├── Zig TUI
├── embedded Lua runtime
├── optional MessagePack-RPC endpoints
└── child processes
    ├── language servers
    ├── jobs/tasks
    └── PTYs
```

No HTTP server, browser runtime, WebSocket server, Node.js process, or GUI framework is required to run the editor.

Headless mode starts the same core without the TUI.

## Fundamental editor model

### Buffer

A buffer owns editable text and text-related state.

Conceptually:

```text
Buffer
├── id
├── name/path
├── text storage
├── changed tick / revision
├── modified state
├── undo history
├── marks/extmarks
├── options
└── attachments/listeners
```

The initial text representation should be intentionally simple—likely line-oriented storage or another straightforward representation. Rope/piece-table complexity should be added only after benchmarks demonstrate a real need.

### Window

A window is a view onto a buffer.

It owns view-specific state such as:

- cursor
- viewport/scroll position
- local options
- dimensions
- folds/view decorations later

Multiple windows may display the same buffer.

### Tab page

A tab page owns a layout of windows. A tab is not synonymous with a file.

Split layouts should be representable as a tree so horizontal/vertical splits remain independent of terminal coordinates.

### Editor

The top-level editor state owns:

```text
Editor
├── buffers
├── windows
├── tabpages
├── current window
├── current mode
├── command state
├── registers
├── global options
├── event/autocmd registry
├── Lua host
├── jobs/terminals
├── LSP clients
└── RPC channels
```

## Modal command architecture

Zim should model Vim-style editing as composable semantics rather than hard-coded key sequences.

Core concepts include:

```text
count
operator
motion
text object
mode
register
```

Examples:

```text
3dw
count=3 operator=delete motion=word

ci"
operator=change text-object=inside-quotes
```

Normal, Insert, Visual, Visual Line, Visual Block, Operator Pending, and Command Line modes should be explicit editor state.

The keymap layer maps input sequences to semantic actions/commands; it should not own buffer mutation rules.

## Commands

Commands are first-class editor objects.

Examples:

```text
:write
:quit
:edit
:buffer
:split
:vsplit
:tabnew
:terminal
```

The command registry should support built-in Zig commands and Lua-registered commands through the same public-facing API.

## TUI architecture

The built-in TUI is pure Zig.

Input path:

```text
terminal bytes
    ↓
input decoder
    ↓
key notation / mouse / resize event
    ↓
keymap + modal parser
    ↓
editor command
    ↓
core state mutation
```

Rendering path:

```text
editor/view state
    ↓
render into cell grid
    ↓
compare against previous grid
    ↓
emit only changed terminal cells
```

A cell should carry enough information for a terminal renderer without exposing terminal escape sequences to the editor core:

```text
Cell
├── grapheme/rune
├── foreground
├── background
└── attributes
```

The terminal must always be restored safely after normal exit, errors, interrupts, or panics where recovery is possible.

## Public editor API

Zim should have one conceptual public API shared across extension mechanisms.

Examples:

```text
buffers
windows
commands
keymaps
options
events/autocmds
marks/extmarks
diagnostics
jobs
LSP
UI attachment
```

Built-in implementation code may use lower-level Zig functions, but features intended for extensions should converge on stable editor concepts rather than separate Lua/RPC-specific models.

Neovim inspiration does not imply Neovim API compatibility. Compatibility can be evaluated later as an explicit project.

## Lua

Lua is Zim's primary configuration and embedded plugin language.

Expected user entrypoint:

```text
~/.config/zim/init.lua
```

Lua should be able to:

- read/set editor options
- define keymaps
- register commands
- subscribe to events/autocommands
- inspect and modify buffers through safe APIs
- create marks/extmarks/decorations
- publish diagnostics
- start jobs and interact with other exposed subsystems

Embedded Lua calls the public API directly in-process; it should not serialize each call through MessagePack-RPC.

The exact Lua runtime (for example PUC Lua versus LuaJIT) should be selected through a portability/performance spike. The public API must avoid unnecessary dependence on runtime-specific behavior.

## Events and autocommands

Core state transitions should emit typed events that can drive built-ins and plugins.

Examples:

```text
BufRead
BufWritePre
BufWritePost
BufEnter
BufLeave
TextChanged
InsertEnter
InsertLeave
WinEnter
WinLeave
VimEnter-like startup event
LspAttach
DiagnosticChanged
```

Names do not need to match Neovim exactly, but the event model should be capable of the same style of extension.

Events must avoid re-entrancy surprises where practical; mutation rules and callback ordering should be documented as the system matures.

## Marks and extmarks

Ordinary marks support user/editor positions.

An extmark-like primitive should eventually provide revision-aware anchored positions/ranges for:

- diagnostics
- syntax/decorations
- virtual text
- plugin annotations
- LSP features
- future UI metadata

This should be a core abstraction rather than a TUI drawing trick.

## Undo and revisions

Editing operations should produce structured change records and a monotonically increasing changed tick/revision.

Undo/redo belongs to the buffer/editor core, not the UI.

Start with a correct linear undo stack. An undo tree can be added once the editing model is stable.

## Language intelligence and parsing

LSP clients are child processes managed by Zim.

Buffer lifecycle drives LSP synchronization:

```text
buffer open   -> didOpen
buffer edit   -> didChange
buffer save   -> didSave
buffer close  -> didClose
```

Diagnostics become editor-owned state and are rendered by whichever UI is attached.

Incremental syntax parsing/highlighting should also attach to buffer revisions. Tree-sitter is a natural candidate, but integration should be isolated behind a parsing/highlighting subsystem rather than spread through the TUI.

## Jobs and terminals

Jobs and interactive terminals share process infrastructure but have distinct semantics.

- **job/task:** process execution with captured/streamed output and completion status
- **terminal:** PTY-backed interactive session with terminal-grid state

The editor owns these processes. A UI renders them.

## Plugin model

Zim should support two extension classes.

### Embedded Lua plugins

```text
Zim process
└── Lua runtime
    └── plugin
        └── direct Zim API
```

Best for normal configuration and editor plugins.

### Remote plugins

```text
Zim
 │
MessagePack-RPC
 │
external process
```

Remote plugins gain language independence and process isolation. They should register capabilities through the Zim API instead of receiving unrestricted access to internal pointers or allocator-owned objects.

## MessagePack-RPC

MessagePack-RPC is the external API transport.

Use it for:

- remote plugins
- external automation clients
- embedding
- headless control
- optional external UIs

Initial transports should favor local operation:

- stdio for embedded/child-process use
- Unix-domain sockets on Unix-like systems
- an appropriate local IPC equivalent on Windows

TCP can be added when there is a clear use case and explicit security model.

The protocol should include API/version metadata and capability discovery so clients can fail clearly when versions differ.

## External UI protocol

When external graphical UIs arrive, Zim should expose an attachable UI protocol inspired by Neovim's separation of editor state from display.

The UI protocol can carry high-frequency display primitives such as:

- grid resize
- grid line updates
- cursor position
- mode changes
- highlights
- command-line state
- popup/completion state
- messages

The semantic editor API remains available alongside UI events.

This gives a future SolidJS client a fast display protocol without moving buffer ownership or editing semantics into JavaScript.

## Headless mode

Headless operation is a first-class startup mode:

```bash
zim --headless
```

It should initialize editor state, configuration/plugins as requested, API/RPC endpoints, buffers, jobs, and language tooling without initializing the terminal renderer.

This is important for:

- tests
- automation
- CI
- remote clients
- plugin development
- embedding

## Recommended module boundaries

Directories should appear as implementations land, not as empty scaffolding.

```text
src/
├── main.zig
├── app/
├── cli/
├── editor/
│   ├── buffer
│   ├── window
│   ├── tabpage
│   ├── mode
│   ├── edit
│   ├── undo
│   ├── marks
│   └── registers
├── input/
├── keymap/
├── command/
├── tui/
├── api/
├── lua/
├── rpc/
├── event/
├── syntax/
├── lsp/
├── job/
├── terminal/
├── search/
├── fs/
└── platform/

tests/
├── unit/
├── editor/
├── integration/
└── rpc/
```

## Testing strategy

### Editor tests

Most editing semantics should be testable without a terminal:

- insert/delete
- cursor motions
- operators
- text objects
- counts
- mode transitions
- undo/redo
- registers
- commands
- buffer/window behavior

### TUI tests

Test input decoding, grid generation, resize behavior, and terminal restoration independently of editor semantics where possible.

### Lua/API tests

Exercise the public API from Lua and ensure plugin operations produce the same editor state transitions as built-in calls.

### RPC tests

Run headless Zim and control it through MessagePack-RPC.

### End-to-end tests

Use PTY-based tests for a small set of real interactive flows such as open → insert → save → quit.

## Performance model

The critical interactive path should remain local and allocation-conscious:

```text
keypress → decode → keymap/modal parser → edit → invalidation → grid diff → terminal write
```

RPC and Lua must not sit in that path unless a configured plugin explicitly participates.

Performance targets should eventually cover startup, keystroke-to-render latency, large buffers, redraw volume, memory use, Lua callback overhead, and RPC throughput.

## Decision filter

When adding a feature, ask:

1. Is this editor state, UI state, or extension state?
2. Does it belong to the buffer, window, tabpage, or global editor?
3. Can core behavior be tested without a terminal?
4. Is the operation composable with the modal command model?
5. Should Lua and remote plugins be able to access it through the public API?
6. Is this on the keystroke/render hot path?
7. Are we adding complexity because measurement requires it, or because another editor happens to have it?

If those answers are unclear, design the editor primitive before adding UI behavior around it.
