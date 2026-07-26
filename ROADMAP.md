# Roadmap

Roadmap for the zim editor. 

## Vision

Zim will be distributed as a single executable:

```text
zim
```

The executable will contain:

```text
┌──────────────────────────────────────────────┐
│ Zim                                          │
│                                              │
│ Zig editor core                              │
│ RPC server                                   │
│ Workspace and document management            │
│ Language-server management                   │
│ Terminal and task management                 │
│ Embedded SolidJS frontend UI                 │
└──────────────────────────────────────────────┘
```

Starting Zim inside a project will launch the local editor server and open the embedded frontend:

```bash
zim .
```

Conceptually:

```text
SolidJS frontend
       │
       │ JSON-RPC over WebSocket
       ▼
Zig editor core
       │
       ├── Workspace
       ├── Documents
       ├── Commands
       ├── Language servers
       ├── Terminals
       ├── Build tasks
       └── Plugins
```

The Zig process will own the authoritative editor state. The SolidJS application will render that state and send semantic editor commands through Remote Proceedure Call (RPC).

## Why Zim?

Many editors combine the editor engine, rendering system, plugins, and user interface into one tightly coupled application.

Zim will separate these concerns:

* Zig owns editor state and system access.
* SolidJS owns the graphical interface.
* RPC connects the two.
* External clients can use the same RPC protocol.
* The complete application is shipped as one binary.

This architecture should eventually allow Zim to support:

```text
Browser interface  ─┐
Desktop wrapper     ├── Zim RPC ── Editor core
Command-line client ┤
External plugins   ─┘
```

## Planned commands

```bash
zim .
zim path/to/project
zim src/main.zig
zim open src/main.zig
zim status
zim sessions
zim doctor
zim stop
zim version
```

The initial command is:

```bash
zim .
```

This tells Zim to use the current directory as its workspace.

## Planned RPC API

Zim will begin with JSON-RPC 2.0 over WebSockets.

Example request:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "system.hello",
  "params": {}
}
```

Example response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "name": "Zim",
    "version": "0.1.0",
    "protocolVersion": 1
  }
}
```

Planned method groups include:

```text
system.*
session.*
workspace.*
document.*
command.*
language.*
terminal.*
task.*
git.*
plugin.*
```

## Planned frontend

The graphical interface will be built with:

* SolidJS
* TypeScript
* ViteJS
* CodeMirror
* WebSockets
* An embedded production build

During development, ViteJS will provide hot module replacement.

For production, the frontend will be compiled and embedded into the Zig executable.

```text
SolidJS source
      │
      ▼
Vite build
      │
      ▼
ui/dist/index.html
      │
      ▼
Zig @embedFile
      │
      ▼
Single Zim executable
```

## Current project structure

```text
zim/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    └── root.zig
```

The project will gradually expand toward:

```text
zim/
├── src/
│   ├── main.zig
│   ├── cli/
│   ├── editor/
│   ├── rpc/
│   ├── server/
│   ├── workspace/
│   ├── language/
│   ├── terminal/
│   ├── task/
│   ├── git/
│   └── plugin/
├── web/
│   └── src/
├── protocol/
└── tests/
```

## Roadmap

### Phase 0: Bootstrap

* [x] Initialize the Zig project
* [x] Add Zim startup output
* [x] Resolve the current workspace path
* [ ] Parse `zim .` and other CLI arguments
* [ ] Add version and help commands

### Phase 1: Local server

* [ ] Start a local HTTP server
* [ ] Add a health endpoint
* [ ] Serve an embedded HTML page
* [ ] Add a WebSocket endpoint
* [ ] Implement `system.hello`

### Phase 2: SolidJS interface

* [ ] Create the SolidJS application
* [ ] Connect to Zim over WebSocket
* [ ] Display connection and workspace state
* [ ] Embed the production frontend
* [ ] Ship the frontend inside the Zig binary

### Phase 3: Workspace

* [ ] List workspace files
* [ ] Read files
* [ ] Create files and directories
* [ ] Rename and delete files
* [ ] Watch for external filesystem changes
* [ ] Respect ignore files

### Phase 4: Editing

* [ ] Integrate CodeMirror
* [ ] Open documents
* [ ] Apply revisioned edits
* [ ] Save documents
* [ ] Add dirty-state tracking
* [ ] Add undo and redo
* [ ] Support multiple tabs

### Phase 5: Development tools

* [ ] Run build commands
* [ ] Stream task output
* [ ] Add an integrated terminal
* [ ] Start language servers
* [ ] Display diagnostics
* [ ] Add completion and go-to-definition

### Phase 6: Editor platform

* [ ] Add command registration
* [ ] Add Unix-domain socket support
* [ ] Support persistent sessions
* [ ] Add external RPC plugins
* [ ] Add plugin permissions
* [ ] Generate Zig and TypeScript protocol types
