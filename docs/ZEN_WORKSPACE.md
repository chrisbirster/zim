# Zen Workspace

Zim v0.5.0 introduces the **Zen Workspace**: a terminal-native application shell around the Zig editor core.

The workspace deliberately preserves the architecture established by ADR 0004:

- Zig owns buffers, windows, cursor/selection state, editing commands, language state, and the `EditorView` paint/input path.
- Hondo/Solid owns application chrome and focusable workspace regions.
- Handled editor keystrokes stay on the native Zig/Hondo path and do not cross QuickJS/Solid.
- Only coarse editor/project/language summaries cross the `NativeView` state boundary.

## Layout

At normal terminal widths the workspace is:

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ ZIM   current/file.zig                         ZEN · EDITOR · B1 W1 T1 │
├────────────────────────┬──────────────────────────────┬───────────────────┤
│ PROJECT                │                              │ CONTEXT           │
│ project root           │         EditorView           │ Symbols           │
│ current file           │        Zig-native            │ Diagnostics       │
│ open buffers           │                              │ References        │
│                        │                              │ Git               │
│                        │                              │ Quickfix          │
│                        │                              │ Tests             │
├────────────────────────┴──────────────────────────────┴───────────────────┤
│ NORMAL                                      Tab workspace · Ln 1, Col 1 │
└──────────────────────────────────────────────────────────────────────────┘
```

The center editor has a maximum comfortable width so large terminals gain breathing space instead of stretching source code across the entire screen.

## Workspace focus

Project, Editor, and Context are separate Hondo focus regions in this order:

```text
Project → Editor → Context → Project
```

In Normal mode:

- `Tab` moves forward through workspace focus.
- `Shift-Tab` moves backward.

The editor does **not** lose native key ownership when a key is meaningful to editing. In Insert mode, for example, `Tab` remains an editor key and inserts indentation rather than moving workspace focus.

The top bar displays the currently focused workspace zone.

## Project zone

The Project zone is Hondo chrome, not an editor buffer. It currently shows coarse project context:

- project root when Zim was opened on a directory
- current file
- open buffer count

Press `c` or `Enter` while the Project zone is focused to collapse or expand it.

The v0.5 Project zone establishes the workspace/focus contract. A richer interactive project tree can build on this chrome boundary without turning filesystem navigation into editor-buffer semantics.

## Context zone

The Context zone contains six workspace surfaces:

- Symbols
- Diagnostics
- References
- Git
- Quickfix
- Tests

While Context is focused, use Left/Right to change the selected surface. Press `c` or `Enter` to collapse or expand the panel.

### Language-backed summaries

The native editor state bridge supplies live coarse counts for:

- diagnostics held by the LSP diagnostic store
- the latest symbol result
- the latest **reference** result

Definition locations are tracked separately so a definition lookup is not mislabeled as a reference result.

### Git, Quickfix, and Tests

v0.5 establishes first-class Context surfaces for Git, Quickfix, and Tests. They are intentionally provider-neutral workspace slots in this milestone; Zim does not run Git or test subprocesses on every paint/state notification. Later job/tooling work can feed these surfaces through coarse state without changing the shell architecture.

## Responsive behavior

The shell receives real terminal dimensions from Zig. After the Hondo bundle is installed, Zig calls the shell's resize entrypoint directly on initial layout and whenever the terminal size changes.

- Below 108 columns, Context collapses to a focusable `C` rail.
- Below 72 columns, Project also collapses to a focusable `P` rail.
- Explicitly collapsed panels remain focusable rails rather than disappearing.

This keeps keyboard traversal predictable even on narrow terminals.

## Native state boundary

`EditorView` publishes coarse state such as:

```text
mode
cursor line/column
modified/revision
command/status
current path
project root
buffer/window/tab counts
diagnostic count
symbol count
reference count
```

The shell does not receive buffer text, cursor editing commands, or per-keystroke editing semantics.

## Validation contract

The v0.5 integration suite verifies that:

- Project → Editor → Context focus traversal works through Hondo.
- collapsing a side zone replaces it with a focusable rail.
- terminal resize drives responsive rail behavior.
- normal-mode workspace `Tab` does not mutate editor text.
- insert-mode `Tab` is still handled by the native editor path.
- existing handled editor-key tests continue to prove that ordinary editing does not cross JavaScript.

This is the key architectural promise of the Zen Workspace: **Hondo owns the workspace; Zig still owns the editor.**
