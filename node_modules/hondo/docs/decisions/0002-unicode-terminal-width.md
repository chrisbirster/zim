# ADR 0002 — Unicode terminal-width model

Status: accepted

Hondo renders terminal text as Unicode grapheme clusters, not individual code points.

## Decision

- Use `uucode` for UAX #29 grapheme segmentation and Unicode width properties.
- A rendered terminal glyph has display width 0, 1, or 2 columns.
- `CellGrid` stores a lead cell plus an explicit continuation cell for two-column glyphs.
- Grapheme bytes are owned by the grid rather than borrowed from scene text.
- Overwriting either half of a wide glyph clears the full previous glyph.
- Full-frame and incremental output never emit continuation cells as independent text.
- Incremental diff runs expand to grapheme boundaries when either the previous or current frame contains a wide glyph.

The first implementation favors correctness and simple ownership over allocation minimization. The grid uses arena-backed grapheme storage so frame copies remain self-contained. We can optimize storage after profiling without changing these semantics.

## Required coverage

Conformance tests include combining marks, CJK/wide glyphs, emoji variation selectors, regional-indicator flags, skin-tone/ZWJ emoji, and wide-to-narrow replacement.
