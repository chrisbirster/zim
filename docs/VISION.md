# Zim Vision

## Mission statement

**Zim exists to make local software development feel immediate again.**

It should give developers a fast, native, understandable editor that starts from a project directory, keeps the user's machine and files at the center of the experience, and exposes powerful development capabilities through a small semantic core rather than a pile of tightly coupled UI machinery.

## Purpose

Zim is being built for developers who want:

- a native editor process with predictable resource usage
- a modern graphical interface without making the browser the source of truth
- local-first operation with no required account or cloud service
- language intelligence, terminals, tasks, Git, and automation around one shared editor state
- an editor architecture small enough to understand and extend
- a protocol that allows more than one client without duplicating the editor engine

The goal is not merely to render text. Zim should become the local control plane for working on a codebase.

## Product promise

Running:

```bash
zim .
```

should eventually be enough to enter a complete development environment for the current project.

Zim should discover the workspace, restore its session, open the native editor core, start only the development services it needs, expose the UI, and remain usable without an internet connection.

## Core beliefs

### 1. Local first is the default

The user's project, editor state, terminals, language servers, and tasks belong on the user's machine. Cloud features may exist later, but they must be additive rather than required for normal editing.

### 2. The editor is a system, not a view

The graphical interface must not become the editor engine. Workspace state, documents, revisions, filesystem operations, commands, terminals, tasks, language servers, and sessions belong in the Zig core.

### 3. UI should be easy to change

SolidJS owns presentation and interaction. It should be possible to redesign the interface without rewriting document semantics, terminal ownership, task execution, or language-server management.

### 4. Semantic commands beat UI coupling

Clients should ask Zim to perform editor operations such as `document.open`, `document.applyEdits`, or `task.run`. They should not reach through the protocol to manipulate internal objects or filesystem paths directly.

### 5. One core, many clients

The first-party SolidJS GUI is the primary client, but the same core should eventually support CLI automation, external plugins, browser access, testing tools, and other interfaces.

### 6. Small beats magical

Zim should favor explicit data flow, narrow modules, stable types, and code that can be followed end-to-end. New abstraction layers need to earn their place.

### 7. Fast is a feature

Startup, file opening, edits, command dispatch, search, diagnostics, and task feedback should feel immediate. Performance budgets should eventually become testable product requirements rather than vague aspirations.

## What Zim is

Zim is:

- a local-first code editor
- a native Zig application
- an editor core with a versioned protocol
- a modern SolidJS graphical client
- a workspace/document/session engine
- a host for development services such as LSP, terminals, tasks, and Git
- an eventual platform for automation and plugins

## What Zim is not

At least through the first stable releases, Zim is not trying to be:

- a cloud IDE
- a hosted source-control service
- a collaborative document platform
- an Electron application
- a browser application that directly owns project files
- a VS Code compatibility clone
- a plugin marketplace before the editor itself is solid
- an AI product whose basic editor experience depends on a model or remote service

Those constraints are intentional. They keep the first milestone focused on building an excellent editor foundation.

## The first useful Zim

The first useful Zim does not need every IDE feature. It needs one coherent vertical slice:

1. `zim .` starts the local editor core.
2. The bundled graphical client opens.
3. The workspace tree is visible.
4. A text file can be opened.
5. The file can be edited and saved.
6. External file changes are detected safely.
7. A project task can be run and its output viewed.
8. One language server can provide diagnostics.
9. Closing and reopening Zim restores the workspace/session.

If that loop is fast and reliable, Zim has a product. Everything after it expands the platform.

## Success criteria

Zim is succeeding when:

- developers can use it on a real repository for normal editing work
- the Zig core remains authoritative even as the UI grows
- frontend changes do not require editor-core rewrites
- headless tests can exercise editor behavior through the same semantic APIs used by the GUI
- features can be traced from RPC request to core state change to emitted event
- installation and startup remain simple
- the architecture supports additional clients without creating a second editor implementation

## Personality

Zim should be technically serious without becoming sterile.

The project can keep its Invader Zim-inspired voice — **"Your new code overlord"** and **"THE CODE... IT FILLS ME... IT IS NEAT!"** — while the underlying product remains disciplined, fast, and dependable.
