# Zim Architecture

## Architectural thesis

Zim is a terminal-only Neovim-class editor implemented in Zig.

The terminal UI and editor core live in the same native process and communicate through direct Zig APIs. Embedded Lua extends the editor in-process. External plugins and automation tools use the public editor API over MessagePack-RPC.

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
             embedded Lua              ┌──────────┴───────────┐
                                       │                      │
                                  remote plugins        automation
                                                       / embedding
```

There is no graphical UI layer in Zim's product architecture.

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

No HTTP server, browser runtime, WebSocket server, Node.js process, WebView, or GUI framework is required or planned for the editor.

Headless mode starts the same core without initializing the TUI.

## Fundamental editor model

### Buffer

A buffer owns editable text and text-related state.

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

Start with an understandable text representation. Rope/piece-table complexity should be added only after benchmarks demonstrate a need.

### Window

A window is a terminal view onto a buffer. It owns cursor, viewport, local options, dimensions, folds, and other view-specific state. Multiple windows may display the same buffer.

### Tab page

A tab page owns a layout of windows. A tab is not synonymous with a file. Split layouts should be represented independently of terminal coordinates.

### Editor

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

Zim models Vim-style editing as composable semantics rather than hard-coded key sequences.

Core concepts:

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

Normal, Insert, Visual, Visual Line, Visual Block, Operator Pending, and Command Line modes are explicit editor state.

The keymap layer maps input sequences to semantic actions; it does not own buffer mutation rules.

## Commands

Commands are first-class editor objects. The command registry supports built-in Zig commands and Lua-registered commands through the same public-facing API.

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

## TUI architecture

The TUI is Zim's permanent user interface.

Input path:

```text
terminal bytes
    ↓
input decoder
    ↓
key / mouse / resize event
    ↓
keymap + modal parser
    ↓
editor command
    ↓
core state mutation
```

Rendering path:

```text
editor/window state
    ↓
render into cell grid
    ↓
compare against previous grid
    ↓
emit only changed terminal cells
```

A cell carries grapheme/rune, foreground, background, and attributes. Terminal escape sequences belong to the TUI/platform layer rather than the editor model.

The terminal must be restored safely after normal exit, errors, interrupts, or panics where recovery is possible.

Zim should behave well in local terminals, SSH sessions, tmux/screen, and supported Windows terminal environments.

## Public editor API

Zim has one conceptual public API shared across extension mechanisms:

```text
buffers
windows
tabpages
commands
keymaps
options
events/autocmds
marks/extmarks
diagnostics
jobs
LSP
```

There is no external UI attachment API in the product plan.

Neovim inspiration does not imply Neovim API compatibility. Compatibility can be evaluated separately if it creates enough value.

## Lua

Lua is Zim's primary configuration and embedded plugin language.

Expected user entrypoint:

```text
~/.config/zim/init.lua
```

Lua should be able to read/set options, define keymaps, register commands, subscribe to events/autocommands, inspect and modify buffers through safe APIs, create marks/extmarks/decorations, publish diagnostics, and start jobs.

Embedded Lua calls the public API directly in-process; it does not serialize each call through MessagePack-RPC.

The Lua runtime will be selected through a portability/performance spike. The public API should avoid unnecessary dependence on runtime-specific behavior.

## Events and autocommands

Core transitions emit typed events usable by built-ins and plugins, including buffer lifecycle, mode transitions, window/tab changes, LSP attachment, diagnostics, and text changes.

Mutation/re-entrancy rules and callback ordering should become explicit and documented as the system matures.

## Marks and extmarks

Ordinary marks support user/editor positions. An extmark-like primitive should provide revision-aware anchored positions/ranges for diagnostics, syntax/decorations, virtual text, plugin annotations, and language tooling.

These are editor primitives, not TUI drawing hacks.

## Undo and revisions

Editing operations produce structured change records and a monotonically increasing changed tick/revision. Undo/redo belongs to the buffer/editor core.

Start with a correct linear undo stack. Add an undo tree only when the editing model is stable.

## Language intelligence and parsing

LSP clients are child processes managed by Zim. Buffer lifecycle drives LSP synchronization, and diagnostics become editor-owned state rendered by the TUI.

Incremental parsing/highlighting also attaches to buffer revisions. Tree-sitter is a natural candidate but is not an architectural requirement.

## Jobs and terminals

Jobs and interactive terminals share process infrastructure but have distinct semantics:

- **job/task:** process execution with captured/streamed output and completion status
- **terminal:** PTY-backed interactive session with terminal-grid state

Both are owned by the editor core and rendered through terminal windows/buffers.

## Plugin model

### Embedded Lua plugins

```text
Zim process
└── Lua runtime
    └── plugin
        └── direct Zim API
```

This is the normal configuration/plugin path.

### Remote plugins

```text
Zim
 │
MessagePack-RPC
 │
external process
```

Remote plugins provide language independence and process isolation. They interact through documented handles/capabilities rather than internal pointers.

## MessagePack-RPC

MessagePack-RPC is the external extension and automation transport.

Use it for:

- remote plugins
- external automation clients
- embedding
- headless control

Initial transports favor local operation:

- stdio
- Unix-domain sockets on Unix-like systems
- an appropriate local IPC equivalent on Windows

TCP can be added only with a clear use case and security model.

The protocol includes API/version metadata and capability discovery.

## Headless mode

```bash
zim --headless
```

Headless mode initializes editor state, configuration/plugins as requested, buffers, jobs, language tooling, and optional RPC endpoints without terminal rendering.

It exists for tests, automation, CI, remote plugins, and embedding—not as a second UI product.

## Recommended module boundaries

Directories appear as implementations land, not as empty scaffolding.

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

Most editing semantics are tested without a terminal: insert/delete, motions, operators, text objects, counts, modes, undo/redo, registers, commands, and buffer/window behavior.

TUI tests focus on input decoding, grid generation, resize behavior, terminal capabilities, and terminal restoration.

Lua/API tests prove plugins drive the same core state transitions as built-ins. RPC tests run headless Zim and control it through MessagePack-RPC. A small PTY-based end-to-end suite verifies real interactive flows.

## Performance model

The critical interactive path stays local and allocation-conscious:

```text
keypress → decode → keymap/modal parser → edit → invalidation → grid diff → terminal write
```

RPC and Lua do not sit in that path unless a configured plugin explicitly participates.

Performance targets should eventually cover startup, keystroke-to-render latency, large buffers, redraw volume, memory use, Lua callback overhead, and RPC throughput.

## Decision filter

When adding a feature, ask:

1. Is this editor state, terminal-view state, or extension state?
2. Does it belong to the buffer, window, tabpage, or global editor?
3. Can core behavior be tested without a terminal?
4. Is the operation composable with the modal command model?
5. Should Lua and remote plugins access it through the public API?
6. Is this on the keystroke/render hot path?
7. Are we adding complexity because measurement requires it, or because another editor happens to have it?

If those answers are unclear, design the editor primitive before adding TUI behavior around it.
