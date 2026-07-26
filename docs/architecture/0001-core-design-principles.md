# 0001: Core Design Principles

* **Status:** Accepted
* **Date:** 2026-07-26

## Context

Zim is a local-first code editor built with a Zig backend and a SolidJS frontend.

The project needs a small set of architectural principles to guide implementation decisions as the editor grows. These principles should help prevent the frontend, editor core, RPC protocol, and system services from becoming tightly coupled.

## Decision

Zim will follow these core design principles.

### One binary

A production release should not require users to separately install or run a frontend server.

The SolidJS frontend will be compiled into static assets and embedded into the Zig executable. Running `zim` should start everything required for the editor.

### Local first

Zim should work without an account, cloud service, or remote server.

Projects, editor sessions, configuration, and development tools should remain available on the user's machine. Remote and collaborative capabilities may be added later, but they must not become requirements for normal use.

### Semantic RPC

The protocol should describe editor concepts such as documents, edits, diagnostics, commands, workspaces, tasks, and terminals rather than screen coordinates or rendered interface elements.

Clients should receive meaningful application state and decide how to display it.

For example, Zim should send a diagnostic containing a file, message, severity, and location rather than instructions to draw highlighted characters at specific screen coordinates.

### Authoritative core

The Zig process owns workspace and document state.

Clients interact with that state through explicit RPC commands and events. The SolidJS frontend should not directly read or write project files.

This ensures that browser clients, command-line clients, plugins, and future interfaces all operate against the same editor state.

### Understandable architecture

Zim should remain small enough that a developer can trace a request from the frontend, through RPC, into the editor core.

Features should be divided into clear components with explicit responsibilities. Abstractions should be introduced to solve demonstrated problems rather than anticipated complexity.

## Consequences

These principles mean that:

* The SolidJS frontend must be embedded into production builds.
* The browser interface communicates with the Zig process through RPC.
* Filesystem access remains inside the Zig backend.
* Editor operations must be represented as semantic commands and events.
* The Zig process remains the source of truth for open documents and workspace state.
* Remote services cannot be required for core editor functionality.
* New abstractions must preserve the ability to follow an operation across the system.
* Features that violate these principles require a separate architecture decision explaining why.

## Notes

These principles describe the intended architecture of Zim. They do not require every subsystem to be implemented immediately.

Early versions may use simpler implementations as long as they preserve the direction established by this decision.
