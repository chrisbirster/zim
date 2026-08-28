# Zim Roadmap

This roadmap tracks the path from the current bootstrap executable to a genuinely usable local-first editor.

The canonical repository is **https://github.com/chrisbirster/zim**.

## North star

The first product milestone is simple to describe:

```bash
zim .
```

opens a fast graphical editor for the current repository where a developer can browse files, open a text file, edit it, save it, run a project task, see language diagnostics, close Zim, and return to the same session.

That is the first useful Zim.

## Current state

Today Zim has:

- [x] Zig project/bootstrap
- [x] native executable
- [x] startup identity/banner
- [x] current-working-directory resolution
- [x] accepted core architecture principles
- [x] mission/product architecture documentation

It does **not** yet have a real CLI parser, local server, RPC implementation, frontend, workspace model, document model, editor UI, terminal, task runner, or LSP integration.

## Milestone 0 — Foundation

**Goal:** turn the bootstrap into a testable application skeleton.

- [ ] Define `App` startup/shutdown orchestration
- [ ] Add CLI argument parsing
- [ ] Implement `zim .`
- [ ] Implement `zim <path>`
- [ ] Add `zim --help`
- [ ] Add `zim --version`
- [ ] Normalize and validate workspace paths
- [ ] Introduce stable application errors and exit codes
- [ ] Add unit tests for CLI/workspace resolution
- [ ] Add GitHub Actions for format, build, and tests on supported platforms

**Exit condition:** Zim has a reliable command-line entrypoint and CI can prove it builds/tests from a clean checkout.

## Milestone 1 — Core + RPC heartbeat

**Goal:** prove that Zim can host an authoritative editor core and communicate with a client.

- [ ] Create the core application state
- [ ] Add a local HTTP server bound to loopback
- [ ] Add `/health`
- [ ] Add a WebSocket endpoint
- [ ] Implement JSON-RPC 2.0 request/response framing
- [ ] Implement protocol error handling
- [ ] Add `system.hello`
- [ ] Report `applicationVersion`, `protocolVersion`, session ID, and capabilities
- [ ] Add server lifecycle/shutdown tests
- [ ] Add an integration test that connects and completes the handshake

**Exit condition:** a headless client can start Zim, connect, call `system.hello`, and shut the process down cleanly.

## Milestone 2 — First-party SolidJS client

**Goal:** establish the graphical shell without moving editor authority into the frontend.

- [ ] Create `web/` with SolidJS + TypeScript + Vite
- [ ] Build a typed RPC client
- [ ] Connect/reconnect to the local Zim server
- [ ] Display connection state
- [ ] Display current workspace identity
- [ ] Establish basic layout: activity/sidebar/editor/panel/status
- [ ] Add development mode with Vite HMR
- [ ] Add production frontend build
- [ ] Serve production assets from Zim
- [ ] Package/embed the built UI with the application

**Exit condition:** `zim .` can open the first-party GUI and the GUI is reading real state from the Zig process through RPC.

## Milestone 3 — Workspace browser

**Goal:** make a repository navigable.

- [ ] Add `WorkspaceId` and workspace state
- [ ] Implement workspace tree enumeration
- [ ] Add ignore handling
- [ ] Add `workspace.get`
- [ ] Add `workspace.listFiles`
- [ ] Add filesystem watching
- [ ] Emit `workspace.filesChanged`
- [ ] Render the file tree in SolidJS
- [ ] Add create/rename/delete operations after read-only browsing is stable
- [ ] Add integration tests against temporary workspaces

**Exit condition:** Zim can display and incrementally update the file tree of a real repository.

## Milestone 4 — Editing vertical slice

**Goal:** become a real text editor.

- [ ] Define `DocumentId`
- [ ] Define the document state/revision model
- [ ] Implement `document.open`
- [ ] Implement `document.applyEdits`
- [ ] Implement `document.save`
- [ ] Track dirty/saved revisions
- [ ] Detect external file modifications
- [ ] Emit document lifecycle events
- [ ] Integrate CodeMirror in the SolidJS client
- [ ] Add tabs/open-document UI
- [ ] Add keyboard save
- [ ] Add safe conflict behavior for external changes
- [ ] Add end-to-end open → edit → save tests

**Exit condition:** a developer can browse to a file, edit it, save it, and trust that Zim's Zig core owns the authoritative document state.

## Milestone 5 — Development loop

**Goal:** make Zim useful for actual project work rather than only text editing.

### Tasks

- [ ] Define `TaskId`
- [ ] Run a command in the workspace
- [ ] Stream stdout/stderr
- [ ] Emit task status/output events
- [ ] Display task output in the UI
- [ ] Add cancellation

### Language intelligence

- [ ] Spawn one configured language server
- [ ] Implement LSP initialization
- [ ] Synchronize document open/change/save
- [ ] Surface diagnostics through Zim RPC
- [ ] Render diagnostics in the editor
- [ ] Add hover
- [ ] Add go-to-definition
- [ ] Add completion after lifecycle/diagnostics are reliable

**Exit condition:** a developer can edit code, run the project's build/test command, and see real language diagnostics without leaving Zim.

## Milestone 6 — Sessions and terminal

**Goal:** make Zim feel persistent and complete enough for daily use.

### Sessions

- [ ] Define `SessionId`
- [ ] Persist workspace/session metadata
- [ ] Restore open documents
- [ ] Restore active document
- [ ] Persist minimal layout state where useful
- [ ] Version the session format

### Terminal

- [ ] Add PTY abstraction
- [ ] Start interactive shells
- [ ] Stream terminal output
- [ ] Send terminal input/resize
- [ ] Render an integrated terminal client
- [ ] Clean up child processes reliably

**Exit condition:** closing and reopening Zim restores useful context, and normal command-line work can happen inside the editor.

## Milestone 7 — Daily-driver editor

**Goal:** close the obvious gaps that keep a developer from using Zim on a real repository every day.

- [ ] command palette
- [ ] quick file search
- [ ] project text search
- [ ] multi-cursor/editor ergonomics through CodeMirror
- [ ] Git status/diff basics
- [ ] configurable keybindings
- [ ] user/workspace settings
- [ ] themes
- [ ] crash-safe document/session recovery
- [ ] performance benchmarks
- [ ] packaging/installers for supported platforms

**Exit condition:** Zim can be used as the primary editor for a small-to-medium real project without constantly falling back to another editor.

## Milestone 8 — Platform

**Goal:** make the editor core useful beyond the built-in GUI.

Do this only after the daily-driver loop is healthy.

- [ ] semantic command registry
- [ ] capability discovery
- [ ] generated Zig/TypeScript protocol types
- [ ] Unix-domain socket transport
- [ ] CLI client for an existing session
- [ ] plugin protocol
- [ ] plugin capability/permission model
- [ ] external plugins
- [ ] multi-client session behavior
- [ ] optional remote/browser access with explicit authentication

## Immediate next 10 engineering steps

These are intentionally ordered. Each should leave the repository in a working state.

1. **Create `src/app/` orchestration** — move startup responsibility out of `main.zig` so the process entrypoint stays tiny.
2. **Implement CLI parsing** — support `zim .`, `zim <path>`, `--help`, and `--version` without designing a giant command framework.
3. **Create the workspace value type** — canonical path, identity, validation, and tests.
4. **Add CI** — `zig fmt --check` equivalent, build, and tests on Linux/macOS/Windows where Zig support permits.
5. **Introduce protocol version types** — establish `applicationVersion` and `protocolVersion = 1` before RPC expands.
6. **Start the loopback HTTP server** — health endpoint only.
7. **Add WebSocket + JSON-RPC framing** — transport and parsing, without editor methods yet.
8. **Implement `system.hello`** — first end-to-end semantic RPC method.
9. **Create the SolidJS/Vite client shell** — connection state and workspace name only.
10. **Wire `zim .` to launch the GUI path** — the first complete executable → server → RPC → client vertical slice.

After step 10, stop and evaluate architecture/performance before beginning the workspace browser.

## Engineering rules for roadmap work

- Every milestone should have a headless integration test where practical.
- Keep the Zig core usable without the SolidJS client.
- Do not expose arbitrary filesystem/process access through RPC.
- Prefer semantic state/events over frontend-specific APIs.
- Add module directories as code lands, not as empty scaffolding.
- Avoid premature editor-buffer optimization; measure first.
- Do not build a plugin system before the editing/development loop works.
- Do not make AI or cloud services dependencies of the core editor.
- Keep `main` releasable/buildable; substantial work should land through focused branches/PRs.
