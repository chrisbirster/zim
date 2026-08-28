# Zim Architecture

## Architectural thesis

Zim is a Zig editor core with a versioned semantic protocol and one or more clients.

The first-party client is a SolidJS graphical application. It is intentionally not the source of truth for editor state.

```text
┌─────────────────────────────────────────────────────────────┐
│                         Clients                             │
│                                                             │
│  SolidJS GUI      CLI / automation      future plugins      │
└───────────────────────────┬─────────────────────────────────┘
                            │
                    versioned semantic RPC
                            │
┌───────────────────────────▼─────────────────────────────────┐
│                         Zim Core                            │
│                                                             │
│  sessions   workspaces   documents   commands              │
│  search     LSP          terminals   tasks      git         │
│                                                             │
│             events + authoritative state                    │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│                    Operating system                         │
│                                                             │
│  filesystem   processes   PTYs   sockets   watchers         │
└─────────────────────────────────────────────────────────────┘
```

## Ownership rules

### Zig core owns

- workspace identity and roots
- filesystem access
- open-document buffers
- document revisions and dirty state
- save operations
- command dispatch
- search operations
- language-server processes and protocol state
- terminals and pseudoterminals
- build/task processes and output
- session persistence
- Git subprocess/integration state
- plugin permissions and host capabilities when plugins arrive

### SolidJS client owns

- layout
- panels and tabs
- visual editor presentation
- menus, command palette, dialogs, and notifications
- keyboard/mouse interaction mapping
- client-local ephemeral UI state
- rendering RPC state/events to the screen

### Protocol owns the contract

The protocol is the boundary between product semantics and presentation. A feature is not fully designed until its command, result, state, and event model are clear.

## Core process model

The initial implementation should use one Zim process per active session/workspace.

That process hosts:

1. the editor core
2. the local RPC server
3. the embedded static frontend server
4. child processes such as language servers and task commands
5. session persistence

Later, Zim can add a lightweight session broker if multiple persistent sessions need to survive independently. The first MVP should not require a daemon.

## Recommended module boundaries

```text
src/
├── main.zig              # process entrypoint
├── cli/                  # argument parsing and top-level commands
├── app/                  # startup/shutdown orchestration
├── session/              # session identity and persistence
├── workspace/            # roots, tree, ignore rules, watching
├── document/             # buffers, revisions, edits, save/dirty state
├── command/              # semantic command registry/dispatch
├── rpc/                  # protocol framing, request routing, events
├── server/               # HTTP/WebSocket transport and asset serving
├── search/               # file/text search
├── language/             # LSP lifecycle and translation
├── terminal/             # PTY/process ownership
├── task/                 # project/build task execution
├── git/                  # repository status and operations
└── platform/             # OS-specific adapters

web/
├── src/
│   ├── app/
│   ├── rpc/
│   ├── workspace/
│   ├── editor/
│   ├── terminal/
│   └── components/
└── dist/                 # generated production assets

protocol/
├── schema/               # protocol source definitions
└── generated/            # generated Zig/TypeScript types later

tests/
├── unit/
├── integration/
└── protocol/
```

These directories should be introduced only as real features land; avoid creating empty architecture for its own sake.

## Application state model

The core should expose stable IDs rather than pointers or UI-derived identities.

Examples:

```text
SessionId
WorkspaceId
DocumentId
TerminalId
TaskId
LanguageServerId
```

A client should be able to disconnect and reconnect, request a snapshot, and reconstruct its presentation without depending on in-memory frontend object identity.

## Document model

Documents are the most important core abstraction after workspaces.

Each open document should eventually contain at least:

```text
Document
├── id
├── uri/path
├── text/buffer
├── revision
├── saved_revision
├── encoding
├── line ending
└── external modification state
```

Edits should be revisioned. A client submits an edit against a known revision; the core applies it, advances the revision, and emits the resulting change. This creates a sound base for multiple views, LSP synchronization, plugins, undo/redo, and eventually multiple clients.

For the MVP, use a simple understandable text representation first. Do not prematurely build a sophisticated rope/piece-table unless measurements show it is necessary.

## RPC

### Transport

Start with JSON-RPC 2.0 over a local WebSocket because it is easy to inspect, easy for the SolidJS client to consume, and good for development.

The protocol should remain transport-independent at the application layer so a Unix-domain socket or binary transport can be added later without redesigning editor semantics.

### Method shape

Prefer semantic namespaces:

```text
system.*
session.*
workspace.*
document.*
command.*
search.*
language.*
terminal.*
task.*
git.*
plugin.*
```

Initial methods should stay very small:

```text
system.hello
workspace.get
workspace.listFiles
document.open
document.applyEdits
document.save
```

### Events

The core should publish semantic events such as:

```text
workspace.filesChanged
document.changed
document.saved
document.externalChange
task.output
task.finished
language.diagnostics
terminal.output
```

Clients should not poll when an event can represent the state transition cleanly.

### Versioning

`system.hello` should negotiate or at minimum report:

```text
applicationVersion
protocolVersion
sessionId
capabilities
```

Breaking protocol changes require a protocol-version increment.

## Frontend architecture

Use SolidJS + TypeScript + Vite for the first-party GUI.

The frontend should have a deliberately thin data layer:

```text
WebSocket
   │
RPC client
   │
normalized client state
   │
Solid signals/stores
   │
views/components
```

The UI may optimistically render safe interactions, but authoritative document/workspace state ultimately comes from the core.

For the text editor, CodeMirror is a pragmatic first choice because it provides mature editing behavior without requiring Zim to write a text-rendering engine before validating the overall architecture.

## Production packaging

Development:

```text
Zig core/server  <----WebSocket---->  Vite dev server
```

Production:

```text
SolidJS source
     │
     ▼
Vite build
     │
     ▼
web/dist
     │
     ▼
embedded/packaged into zim
     │
     ▼
single user-facing zim executable
```

The exact asset-embedding mechanism can evolve. The user-facing invariant is more important: installing Zim should not require separately installing or starting the frontend.

## Language Server Protocol

Zim should manage language servers from the Zig core.

The core should translate editor document lifecycle into LSP lifecycle:

```text
document.open        -> textDocument/didOpen
document.changed     -> textDocument/didChange
document.save        -> textDocument/didSave
```

Diagnostics, completion, hover, definition, references, and other results should be exposed to clients as Zim protocol concepts rather than leaking raw child-process ownership into the UI.

The first vertical slice should support exactly one configurable language server well before building a generalized installer/registry.

## Tasks and terminals

Tasks and terminals share process infrastructure but have different semantics.

- A **task** is a command Zim starts, observes, and can report as completed/failed.
- A **terminal** is an interactive PTY session with bidirectional input/output.

Keep these separate at the protocol level even if they share lower-level process code.

## Persistence

Persist only what creates clear user value in early releases:

- last workspace/session identity
- open document paths
- active document
- optional layout state

Do not persist arbitrary internal implementation structures. Use a small versioned session format that can be migrated or discarded safely.

## Security boundary

The frontend is a local client, but it should still communicate through explicit capabilities rather than gaining unrestricted filesystem/process access.

This becomes especially important if Zim later allows browser connections or third-party plugins.

Principle:

> A client can request a capability the core intentionally exposes; it cannot inherit the authority of the Zim process merely because it can connect to it.

The local server should bind to loopback by default and use an unguessable per-session token before browser-access features are considered stable.

## Testing strategy

### Unit tests

Test core data structures and state transitions without a browser:

- workspace resolution
- document edits/revisions
- dirty/saved state
- command dispatch
- protocol validation
- session serialization

### Integration tests

Start a real core/server and exercise it through RPC:

- handshake
- open/edit/save
- filesystem change propagation
- task execution/output
- LSP diagnostics

### UI tests

Keep UI tests focused on client behavior rather than duplicating editor-core correctness tests.

The architecture is healthy when most editor behavior can be tested headlessly through core APIs or RPC.

## Performance targets

Exact budgets should be measured once the corresponding features exist, but the project should work toward explicit targets such as:

- near-instant CLI startup
- local RPC operations below perceptible interaction latency
- incremental workspace updates rather than full-tree reloads
- no UI-wide rerender for a single document state change
- bounded memory growth for long-running sessions

Performance regressions should eventually be benchmarked in CI.

## Decision filter

When adding a feature, ask:

1. Who owns the authoritative state?
2. What is the semantic command or event?
3. Can the feature work without the GUI?
4. Can the GUI be replaced without rewriting the core feature?
5. Does this require a new abstraction now, or can a smaller explicit implementation solve it?
6. Can we test the behavior headlessly?

If those answers are unclear, the architecture probably needs to be designed before implementation starts.
