# Public API

Hondo v0.1.0 exposes two TypeScript packages plus the Zig runtime.

## `@hondo/core`

Use `@hondo/core` when embedding or testing the host tree directly.

Primary exports:

- `HondoHost` — in-memory host tree used by the Solid universal renderer.
- `HondoNode` — host-node identity and parent/child relationships.
- `installHost()` / `getHost()` — install and resolve the current host for renderer operations.
- `NativeMutationBridge` — forwards host mutations to the native QuickJS/Zig bridge.
- `RecordingMutationBridge` — deterministic bridge for tests and snapshots.
- `HondoNodeEvent` / `HondoNodeEventHandler` — capture/target/bubble event surface.

Application code normally consumes `@hondo/solid` instead.

## `@hondo/solid`

### Renderer

- `render(() => node, root)` mounts a Solid/Hondo tree and returns a disposer.
- Solid renderer helpers are exported for advanced integrations.

### Primitives

- `Text`
- `Box`
- `Stack`
- `Row`
- `Column`
- `Spacer`

Primitives accept `style`, focus/event props, children and optional refs. Layout is terminal-native and evaluated by Zig.

### Styling

- `HondoStyle`
- `defineStyles()`
- `defineTokens()`
- `composeStyles()`

Hondo styles are typed terminal values, not CSS. Supported concepts include sizing, grow/shrink, gap, padding, alignment, clipping, overlay positioning/z-order, foreground/background color and terminal text attributes.

### Controls

- `Input` — controlled text editing with submit support.
- `List` — controlled selection, activation, viewporting and mouse interaction.
- `Menu` — list semantics with disabled entries.
- `Tabs` — controlled horizontal selection and activation.
- `ScrollView` — controlled vertical offset with keyboard and mouse-wheel input.
- `Popup` — overlay positioning, z-order and Escape dismissal.
- `Tree` — controlled hierarchy expansion/selection.
- `Table` — typed fixed-width columns, headers, viewporting and row activation.

All control state is owned by Solid. Zig owns terminal input decoding, spatial mouse targeting and focus dispatch.

### Focus and events

Hondo routes terminal events through:

```text
capture -> target -> bubble
```

Handlers can call `preventDefault()` and `stopPropagation()`. `Tab`/`Shift-Tab` use the native focus manager unless prevented. Mouse events are spatially hit-tested against the native layout/overlay result.

### `NativeView`

`NativeView` represents a Zig-owned heavyweight region in a Solid layout. Solid forwards coarse properties and receives coarse state notifications; measurement, painting, invalidation and handled input remain native.

Use `NativeView` when a component has a high-frequency hot path that should not traverse QuickJS/Solid—for example an editor viewport.

See [`native-view.md`](native-view.md) for registration and ownership details.

## Minimal mount

```ts
import { HondoHost, NativeMutationBridge, installHost } from '@hondo/core';
import { Column, Input, Text, createSignal, render } from '@hondo/solid';
import { flush } from 'solid-js';

const bridge = new NativeMutationBridge();
const host = new HondoHost(bridge);
const restoreHost = installHost(host);
const [query, setQuery] = createSignal('');

const dispose = render(() =>
  Column({
    children: [
      Text({ children: 'Search' }),
      Input({
        get value() { return query(); },
        onInput: setQuery,
        autoFocus: true,
      }),
    ],
  }),
  host.root,
);
flush();

// later
dispose();
restoreHost();
```

## Stability

Hondo follows Semantic Versioning after v0.1.0. During the 0.x line, breaking API changes may still occur and are called out explicitly in release notes.
