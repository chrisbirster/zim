# Hondo

**Terminal-native SolidJS.**  
*A most profitable arrangement.*

Hondo is an independent framework for building native terminal interfaces with SolidJS 2. Solid owns reactive application composition; Zig owns terminal lifecycle, layout, cell rendering, input, focus, hit testing, and heavyweight native regions.

## What is included

- Solid 2 + `@solidjs/universal` renderer
- QuickJS application runtime with a compact Zig host bridge
- Unicode/grapheme-aware terminal cell engine and incremental ANSI diffing
- Linux/macOS PTY and Windows ConPTY lifecycle coverage
- layout primitives: `Text`, `Box`, `Stack`, `Row`, `Column`, `Spacer`
- controls: `Input`, `List`, `Menu`, `Popup`, `Tree`, `Table`, `Tabs`, `ScrollView`
- terminal-native typed styling with tokens and composition
- keyboard focus, capture/target/bubble events, mouse hit testing, overlays and z-order
- `NativeView` for Zig-owned regions whose hot path bypasses QuickJS/Solid

Hondo does not use a DOM, browser, WebView, React-style reconciliation, or a CSS runtime.

## Architecture

```text
Solid 2 application
       |
@solidjs/universal
       |
 Hondo host tree
       |
QuickJS <-> compact Zig bridge
       |
 scene/layout/focus/input
       |
 cell grid + ANSI diff
       |
    terminal

NativeView hot path:
terminal input -> Zig NativeView -> native paint
                     |
              coarse notifications
                     v
                   Solid
```

## Packages

```ts
import {
  Box,
  Input,
  NativeView,
  Popup,
  Table,
  Tabs,
  Text,
  Tree,
  defineStyles,
  render,
} from '@hondo/solid';
```

- `@hondo/core` — host tree, bridge types, node events and runtime-facing TypeScript APIs.
- `@hondo/solid` — Solid renderer, components, controls, styling and `NativeView` binding.

See [`docs/api.md`](docs/api.md) for the public API and [`docs/compatibility.md`](docs/compatibility.md) for the supported toolchain.

## Examples

- `examples/counter` — minimal signal/input vertical slice.
- `examples/dashboard` — layout and styling example.
- `examples/showcase` — non-Zim application surface combining controls, navigation, overlays and reactive state.

## Flagship consumer

Zim is Hondo's intended first demanding external consumer. Zim remains a separate repository: Hondo provides application chrome and the `NativeView` boundary while Zim keeps its editor buffer, cursor, selection and editing hot path in Zig.

## Development

```sh
npm install
npm run typecheck
npm test
npm run build
npm run pack:check
zig fmt --check zig build.zig
zig build test
zig build counter-smoke
```

CI runs the supported gates on Ubuntu, macOS and Windows, including real PTY/ConPTY lifecycle smoke tests.

## Status

The Hondo framework through M6 is complete and release-hardened for `v0.1.0`. The remaining project-level release criterion is the external Zim integration proof tracked in M7.

See [`docs/roadmap.md`](docs/roadmap.md), [`docs/architecture.md`](docs/architecture.md), and [`docs/development.md`](docs/development.md).
