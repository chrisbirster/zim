# ADR 0004: Hondo owns terminal application chrome

## Status

Accepted.

## Decision

Zim remains a terminal-only editor with a Zig-owned editing core. The interactive application shell is rendered with Hondo, the terminal-native SolidJS framework.

This refines ADR 0003: the ban on browser/WebView/GUI rendering remains absolute, but the earlier blanket prohibition on SolidJS inside the editor no longer applies to terminal-native Hondo chrome.

Ownership is deliberately asymmetric:

- Zig owns buffers, cursor/selection state, editing commands, the `EditorView` paint loop, and handled editor input.
- Hondo/Solid owns application chrome such as status, command, popup, menu, tab, and sidebar UI.
- `NativeView` is the boundary between those worlds.
- Handled editor keystrokes do not cross QuickJS/Solid.
- Only coarse state notifications (mode, cursor position, modified state, command visibility, diagnostics-style summaries) cross from Zig to Solid.
- Solid may send coarse properties/configuration to the native view, never per-keystroke editor work.

## Dependency boundary

Zim consumes Hondo as an external pinned dependency. Hondo does not depend on Zim.

The editor/headless test graph remains pure Zig and can run without Node, QuickJS, Hondo, or a terminal session. Hondo integration tests are a separate build target.

## Consequences

This keeps the editor hot path native while allowing Solid fine-grained reactivity for complex terminal application UI. It also makes Zim the flagship pressure test for Hondo without turning Hondo into an editor-specific framework.
