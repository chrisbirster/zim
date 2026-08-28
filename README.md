# Zim

**Your new code overlord.**

Zim is a fast, local-first code editor and development environment with a Zig core and a SolidJS graphical interface.

> THE CODE... IT FILLS ME... IT IS NEAT!

## Canonical repository

Active development happens here:

**https://github.com/chrisbirster/zim**

This GitHub repository is the canonical source for Zim code, issues, pull requests, releases, architecture decisions, and roadmap work.

## Mission

Build a code editor that feels immediate, stays understandable, works without a cloud account, and gives developers one small native process that owns the hard parts of editing and development tooling.

Zim should combine the responsiveness and scriptable architecture of a native editor with a modern graphical interface, without turning the browser UI into the editor engine.

## Product direction

Zim is an **editor platform with a first-party GUI**, not a web application wrapped around filesystem APIs.

The Zig process owns authoritative editor state and system capabilities:

- workspaces and files
- open documents and revisions
- commands
- language servers
- terminals
- build tasks
- sessions
- Git integration
- plugin capabilities

The SolidJS application renders that state and sends semantic commands through a versioned RPC protocol.

The long-term shape is:

```text
                ┌────────────────────────────┐
                │        Zim clients         │
                │                            │
                │  SolidJS GUI               │
                │  CLI / automation          │
                │  browser client            │
                │  external plugins          │
                └─────────────┬──────────────┘
                              │
                       semantic RPC
                              │
                ┌─────────────▼──────────────┐
                │       Zig editor core      │
                │                            │
                │ workspace   documents      │
                │ commands    LSP            │
                │ terminals   tasks          │
                │ sessions    git/plugins    │
                └────────────────────────────┘
```

Production releases should ultimately ship as one `zim` executable with the compiled SolidJS frontend embedded inside it.

## Status

Zim is in early development.

The current executable starts, resolves the selected workspace, and prints its initialization sequence. The editor server, RPC protocol, frontend, document model, terminal integration, and language features are the next major pieces.

```text
ZIM 0.1.0 — YOUR NEW CODE OVERLORD

THE CODE... IT FILLS ME... IT IS NEAT!

[INVADING]    /Users/nutz/projects/zim
[CATALOGING]  Human files
[AWAKENING]   Language intelligence
[STARTING]    Operation Impending Build
[READY]       Commence coding.
```

## Read next

- [Vision and product principles](docs/VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](ROADMAP.md)
- [Core design decision](docs/architecture/0001-core-design-principles.md)

## Development

### Requirements

- Zig 0.16.0
- Nix, or another environment containing Zig
- Node.js and npm for frontend development once the UI workspace lands

Check Zig:

```bash
zig version
```

### Build

```bash
zig build
```

### Run

```bash
zig build run -- .
```

### Format

```bash
zig fmt src build.zig
```

### Test

```bash
zig build test
```
