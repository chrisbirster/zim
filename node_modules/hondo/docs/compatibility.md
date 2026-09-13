# Compatibility

Hondo v0.1.0 intentionally supports a narrow, tested toolchain.

## Supported development/runtime matrix

| Layer | Supported version / platform |
| --- | --- |
| Zig | 0.16.0 |
| Node.js | >= 22.12.0; CI uses Node 24 |
| npm | 12.0.2 |
| TypeScript | 5.9.2 |
| Solid | `solid-js` 2.0.0-rc.4 |
| Universal renderer | `@solidjs/universal` 2.0.0-rc.4 |
| JavaScript runtime | QuickJS embedded by the Zig runtime |
| Linux | GitHub `ubuntu-latest`, real POSIX PTY lifecycle smoke |
| macOS | GitHub `macos-latest`, real POSIX PTY lifecycle smoke |
| Windows | GitHub `windows-latest`, real ConPTY lifecycle smoke |

## Terminal capabilities

Hondo has a centralized terminal capability model for Unicode, color depth, mouse, focus events, bracketed paste and synchronized output. Features degrade according to detected terminal support.

The renderer supports terminal-default colors, ANSI 16, indexed 256-color and truecolor output. Grapheme segmentation and display-width handling cover combining marks, CJK/fullwidth text, emoji variation selectors, flags, skin tones and ZWJ sequences.

## Package compatibility

`@hondo/solid` has a peer dependency on `solid-js@2.0.0-rc.4`. v0.1.0 does not claim compatibility with Solid 1.x or other Solid 2 RC/final versions until explicitly tested.

The published package artifacts are ESM and target ES2022. They include JavaScript, declarations and source maps under `dist/`.

## Architecture compatibility promises

Hondo v0.1.0 guarantees these architectural boundaries:

- no DOM, browser, WebView or CSS runtime is required;
- Solid uses `@solidjs/universal` fine-grained updates rather than React-style reconciliation;
- Zig owns terminal lifecycle, layout, input, focus and rendering;
- `NativeView` may process handled high-frequency input entirely in Zig;
- Hondo remains independent of Zim and other consumers.

## 0.x policy

After v0.1.0 Hondo follows Semantic Versioning. Because the project is still in 0.x, public APIs can evolve incompatibly; every breaking change must be called out in the corresponding release notes.
