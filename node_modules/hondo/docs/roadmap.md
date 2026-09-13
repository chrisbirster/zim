# Hondo roadmap

Hondo follows a milestone train from foundation to the first usable `v0.1.0`.

## Status

| Milestone | Status | Evidence |
| --- | --- | --- |
| M0 — Foundation | ✅ complete | workspace/toolchain/CI established |
| M1 — Solid to Zig vertical slice | ✅ complete | Solid signal + native input round-trip |
| M2 — Native terminal engine | ✅ complete | Linux/macOS PTY + Windows ConPTY lifecycle coverage |
| M3 — Layout and primitives | ✅ complete | terminal-native layout/component API |
| M4 — Styling decision | ✅ complete | typed native style model selected |
| M5 — TUI component library | ✅ complete | controls, overlays, focus and mouse interactions |
| M6 — NativeView | ✅ complete | native lifecycle/layout/paint/direct-input path |
| M7 — Zim integration | ⬜ open | work primarily belongs in `chrisbirster/zim` |
| M8 — Hondo v0.1.0 | 🟨 release-ready except M7 proof | packaging/docs/release hardening complete |

## M0 — Foundation ✅

- [x] monorepo/workspace layout
- [x] Zig 0.16 build foundation
- [x] TypeScript/Solid workspace
- [x] pinned Node/npm versions
- [x] Solid 2 and `@solidjs/universal`
- [x] QuickJS dependency strategy
- [x] JS/Zig ownership contract
- [x] Linux/macOS/Windows CI
- [x] Zig and TypeScript gates
- [x] examples skeleton
- [x] MIT license

## M1 — Solid to Zig vertical slice ✅

- [x] embedded QuickJS
- [x] bundled Solid application execution
- [x] Hondo host-node identity/tree
- [x] universal renderer host operations
- [x] compact JS/Zig mutation protocol
- [x] Zig scene tree
- [x] Solid signal update reaches Zig
- [x] Zig input reaches a Solid callback
- [x] deterministic disposal/cleanup
- [x] lifecycle tests and counter example

## M2 — Native terminal engine ✅

- [x] raw mode and guaranteed restoration
- [x] alternate screen
- [x] keyboard, mouse, focus and resize input
- [x] Unicode/grapheme and terminal-width semantics
- [x] terminal capability model
- [x] color and text attributes
- [x] cell representation/current+previous grids/diff
- [x] ANSI writer, clipping and invalidation
- [x] focus model and traversal
- [x] Linux/macOS PTY and Windows ConPTY integration tests

## M3 — Layout and primitive components ✅

- [x] `Text`, `Box`, `Stack`, `Row`, `Column`, `Spacer`
- [x] width/height/min/max, grow/shrink
- [x] padding, gap, alignment and clipping
- [x] foreground/background and text attributes
- [x] refs and keyboard focus
- [x] capture/target/bubble event propagation
- [x] dashboard snapshots/example

## M4 — Styling decision ✅

- [x] StyleX-shaped authoring spike without CSS runtime
- [x] modifier-composition spike
- [x] Hondo-native typed style-object model
- [x] TypeScript ergonomics and reactive styles
- [x] serialization/Zig representation evaluation
- [x] themes/tokens, variants and composition evaluation
- [x] selected model documented in `docs/styling-decision.md`

Invariant: Hondo does not embed a CSS engine.

## M5 — TUI component library ✅

- [x] `Input`, `List`, `Menu`, `Popup`
- [x] `Tree`, `Table`, `Tabs`, `ScrollView`
- [x] keyboard navigation and selection
- [x] scrolling and focus traversal
- [x] overlays/z-order and popup positioning
- [x] controlled text editing for `Input`
- [x] spatial mouse interactions and click-to-focus

## M6 — NativeView ✅

- [x] native component registration and lifecycle
- [x] measurement and layout constraints
- [x] native paint and invalidation
- [x] focus handoff and direct input routing
- [x] native -> Solid state notifications
- [x] Solid -> native property changes
- [x] native-first hot-path benchmark/proof

Exit proved: a focused native view can process handled input and paint entirely in Zig while participating in Hondo layout.

## M7 — Zim integration ⬜

Target: integration milestone; most work occurs in the Zim repository.

- [ ] Zim consumes Hondo as an external dependency
- [ ] Hondo renders Zim application chrome
- [ ] Zim native `EditorView` embeds through NativeView
- [ ] editor input bypasses QuickJS/Solid
- [ ] status/command/popup UI reacts through Solid
- [ ] integration performance tests
- [ ] headless/editor tests remain independent of Hondo

Exit: Zim can be edited interactively with Hondo UI around a Zig-native editor viewport.

## M8 — Hondo v0.1.0 🟨

Release criteria:

- [x] Solid 2 integration
- [x] `@solidjs/universal` renderer
- [x] QuickJS runtime
- [x] Zig terminal renderer
- [x] terminal input/output lifecycle
- [x] cell-grid diffing
- [x] cross-platform CI
- [x] primitive/component library
- [x] documented styling model
- [x] NativeView API
- [x] independent examples
- [ ] Zim integration proof
- [x] documented public API
- [x] release notes and compatibility notes
- [x] buildable/packageable `@hondo/core` and `@hondo/solid`

Final release exit after M7 proof:

1. merge the release-ready `dev` tree to `main`;
2. verify exact `main` CI on Linux/macOS/Windows including PTY/ConPTY;
3. tag `v0.1.0` and create the GitHub Release;
4. attach npm-compatible package tarballs.

After `v0.1.0`, Hondo follows Semantic Versioning. During `0.x`, breaking API evolution is expected and must be called out explicitly in release notes.
