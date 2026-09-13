# Hondo architecture

## Product boundary

Hondo is a third-party, terminal-native SolidJS framework. It is independent from StingJS and Zim.

The fundamental ownership rule is:

> Solid owns reactivity. Hondo owns terminal UI. Zig owns terminal mechanics. Applications own their domain logic.

## Runtime stack

```text
Solid 2 / JSX
      |
@solidjs/universal
      |
 Hondo Solid adapter
      |
 Hondo host tree
      |
 QuickJS runtime
      |
 JS <-> Zig host bridge
      |
 Zig scene + layout engine
      |
 cell grid + diff renderer
      |
 terminal
```

QuickJS is an execution environment for Solid/Hondo application code. It must not become the owner of terminal raw mode, PTYs, filesystem access, language servers, editor buffers, or other application-domain subsystems.

## Solid boundary

Hondo implements the host operations expected by `@solidjs/universal`, including the equivalents of:

- create element
- create text node
- replace text
- set property
- insert child before an optional anchor
- remove child
- identify text nodes
- get parent
- get first child
- get next sibling

Solid fine-grained reactivity determines which host operations occur. Hondo does not introduce a DOM or virtual DOM.

## Host tree

The JavaScript side maintains lightweight logical node identity and relationships. Zig receives a compact stream of host mutations and owns the native scene representation.

Initial mutation vocabulary:

```text
CREATE_NODE
CREATE_TEXT
SET_PROPERTY
SET_TEXT
INSERT
REMOVE
```

The protocol should remain small, deterministic, testable, and versioned before a stable release.

## Zig terminal engine

Zig owns:

- terminal raw mode and restoration
- keyboard/mouse/resize decoding
- Unicode/grapheme handling
- terminal capability detection
- layout calculation
- clipping
- focus routing at the native boundary
- current/previous cell grids
- cell-grid diffing
- ANSI output
- high-performance native views

## Native views

Hondo must support heavyweight application-defined native views whose internal rendering does not expand into thousands of Solid host nodes.

Conceptually:

```tsx
<NativeView type="editor" />
```

A native view receives layout bounds, lifecycle callbacks, native invalidation, and direct input ownership when focused.

This is essential for consumers such as Zim: ordinary editor typing must be able to stay entirely in Zig.

```text
terminal input -> Zig -> native application view
```

It must not require this path:

```text
terminal input -> Zig -> QuickJS -> Solid -> Zig
```

for performance-critical interactions.

## Input routing

```text
terminal bytes
      |
 Zig decoder
      |
 key / mouse / resize event
      |
      +--> native view focused -> application native handler
      |
      +--> Hondo UI focused -> Hondo event -> Solid handler
```

## Components

Hondo components are layered.

### Primitives

- Text
- Box
- Stack
- Row
- Column
- Spacer

### Controls

- Input
- List
- Menu
- Popup
- Tree
- Table
- Tabs
- ScrollView

### Native extension point

- NativeView

Application-specific controls such as an editor viewport, terminal emulator, diagnostics view, or agent surface belong in the consuming application unless they are general enough to graduate into Hondo.

## Styling boundary

Styling is intentionally unresolved during the foundation phase.

Candidate approaches:

1. a StyleX authoring adapter that compiles to terminal-native values rather than CSS,
2. modifier composition,
3. a Hondo-native typed style object.

Hondo will not embed a CSS engine. The chosen model must terminate in a compact Zig-native style representation covering only terminal-relevant concepts such as color, attributes, spacing, sizing, direction, alignment, and growth.

## Non-goals

Hondo is not:

- a browser renderer
- a DOM implementation
- a WebView framework
- a CSS engine
- an editor core
- a StingJS target or package
- tied to Zim

## Flagship integration: Zim

Zim can use Hondo for application chrome and reactive composition while keeping editor semantics and editor viewport rendering native in Zig.

```text
Hondo/Solid:
  tab line
  sidebar
  menus
  command UI
  status line
  popups
  future agent UI

Zim/Zig:
  buffers
  windows
  modal grammar
  cursor/selections
  undo
  Tree-sitter
  LSP
  registers
  jobs/PTYS
  editor viewport
```
