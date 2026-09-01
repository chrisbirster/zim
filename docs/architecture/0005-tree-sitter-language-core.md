# ADR 0005 — Tree-sitter as Zim's headless language core

Status: Accepted for Language Core A (#11)

## Context

Zim's editor and workspace are deliberately split by ownership and runtime responsibility. Zig owns editing and language-sensitive hot paths. Hondo owns terminal application chrome. Tree-sitter therefore cannot be modeled as a Hondo component or as a syntax-highlighting plugin; it must be a reusable Zig service that can run with no terminal UI at all.

The active editor core already has its own buffer identity, UTF-8 contents, revision counter, operator grammar, and lifecycle. Language Core A must consume those concepts through an editor-neutral contract without importing or owning the editor implementation.

## Decision

Tree-sitter is a first-class headless language service under `src/language/`.

The service consumes:

- a neutral buffer/document id;
- UTF-8 source text;
- a monotonically increasing revision;
- a language id;
- incremental edits expressed as byte offsets plus zero-based row/byte-column points.

The service owns only parser-side state: a source snapshot, Tree-sitter parser, syntax tree, grammar selection and query execution. It does not own Zim buffers, cursors, undo history, Vim modes, windows, tabs, Hondo nodes or TUI state.

The service returns editor-neutral values:

- source ranges with byte and point coordinates;
- highlight capture names;
- fold ranges;
- structural symbols with name/kind/range where available;
- structural text-object ranges;
- structural navigation targets;
- injection regions and language ids.

## Parser lifecycle

A parse session is keyed by buffer id and revision. Full `open` parsing establishes the first syntax tree. Incremental updates require a newer revision and a single edit descriptor matching the supplied new UTF-8 text.

For reliability, an incremental update edits a shallow copy of the last valid tree and reparses against that copy. The service replaces its last valid tree/text only after the new parse and changed-range calculation succeed. A failed reparse therefore cannot destroy the previous valid parse snapshot.

## Language and query registry

The registry is independent of the editor and maps a language id to:

- display metadata;
- file extensions;
- a Tree-sitter language factory;
- highlight, fold, symbol, text-object and injection query sources.

Zig is the first real grammar and dogfood fixture. The architecture is intentionally multi-language: adding another compiled grammar is a registry/build-wiring change, not a parser-service redesign.

Queries are embedded with the binary so the headless service has deterministic behavior and no runtime filesystem requirement. The registry still exposes query sources by language/kind, allowing future configuration or query composition above this layer.

## Classic Vim objects vs structural objects

Tree-sitter augments Vim grammar; it does not replace it.

Classic Vim semantics remain owned by the editor core:

- paragraphs/sentences (`ap`, `ip`, ...);
- words (`aw`, `iw`);
- quotes/brackets;
- motions, counts and operator-pending behavior.

Tree-sitter contributes a separate structural provider. Its initial neutral object kinds are:

- function inner/around;
- class/container inner/around;
- parameter inner/around;
- block inner/around.

The editor integration train may later map these to commands such as `daf`, `cif`, `daa` or `dic`. The language module does not interpret those key sequences and does not call the operator engine.

## Structural motions

The service can resolve next/previous function or class/container boundaries from a byte position. The result is only a structural range. Cursor movement, jumplist behavior, counts and Vim command semantics remain editor responsibilities.

## Injection architecture

Injection queries follow two neutral capture conventions:

- `@injection.content` — the source region to parse with another language;
- `@injection.language` — optional source text naming the embedded language.

Zig currently has no enabled embedded-language query in Zim. The result type and query contract exist now so HTML/template/Markdown-style embedded parsing can be layered later without changing the service API.

Nested parser ownership and recursive injection scheduling are intentionally deferred until a second real embedded-language grammar is added; the public contract already represents the regions needed to do that.

## Build and portability

Language Core A uses the official `tree-sitter/zig-tree-sitter` bindings pinned to a Zig 0.16-compatible revision and the maintained `tree-sitter-grammars/tree-sitter-zig` grammar. The Zig grammar is linked statically into the headless language test executable.

`zig build test-language` runs the language train directly. `zig build -Dheadless-only=true` also includes the language tests, while Hondo remains lazy and unnecessary for this graph.

## Ownership boundary

Language Core A owns `src/language/**`, its fixtures/tests, this ADR, and only the Tree-sitter dependency wiring required in `build.zig` / `build.zig.zon`.

It intentionally does not modify or import:

- `src/editor.zig`;
- `src/buffer.zig`;
- `src/workspace.zig`;
- `src/editor_view.zig`;
- `src/tui.zig`;
- `ui/**`.

The primary editor train will own the adapter from Zim's concrete Buffer/editor types into this neutral API after the service contract is stable.
