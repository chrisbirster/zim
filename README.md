# Zim

**Your new code overlord.**

Zim is an experimental code editor and development environment built with Zig and SolidJS.

The long-term goal is to create a fast, local-first editor with:

* One native Zig executable
* One embedded SolidJS frontend
* A versioned RPC protocol
* Persistent editor sessions
* Language Server Protocol support
* Integrated terminals and build tasks
* CLI, browser, and plugin clients
* A small, understandable core

Zim takes architectural inspiration from editors such as Neovim and Micro while using a browser-native graphical interface instead of a traditional terminal UI.

> THE CODE... IT FILLS ME... IT IS NEAT!

## Status

Zim is currently in the earliest stage of development.

The application presently starts, identifies the selected workspace, and prints its initialization sequence:

```text
ZIM 0.1.0 — YOUR NEW CODE OVERLORD

THE CODE... IT FILLS ME... IT IS NEAT!

[INVADING]    /Users/nutz/projects/zim
[CATALOGING]  Human files
[AWAKENING]   Language intelligence
[STARTING]    Operation Impending Build
[READY]       Commence coding.
```

The editor, RPC server, frontend, terminal, and language features are still under development.

## Development

### Requirements

* Zig 0.16.0
* Nix, or another environment containing Zig
* Node.js and npm for frontend development

Check your Zig installation:

```bash
zig version
```

### Build

```bash
zig build
```

### Run

```bash
zig build run
```

Pass arguments after `--`:

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