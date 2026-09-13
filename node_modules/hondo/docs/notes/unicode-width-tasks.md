# Unicode width implementation

This slice covers M2 tasks 1–5 from the terminal correctness train:

- grapheme-cluster segmentation
- display-width semantics
- wide-cell continuation representation
- Unicode-safe diff rendering
- Unicode conformance tests

The implementation targets `dev` and must pass Linux, macOS, and Windows CI before merge.
