# Unicode validation cases

The terminal Unicode slice must preserve grapheme boundaries and display width for:

- combining sequences such as `e` + U+0301
- CJK/fullwidth glyphs
- emoji variation-selector sequences
- regional-indicator flags
- skin-tone modifiers
- ZWJ emoji sequences
- replacing a two-column glyph with one-column text without leaving stale terminal content
