# NativeView

`NativeView` is Hondo's escape hatch for terminal regions whose ordinary input and painting must remain native.

Solid owns the surrounding application UI and coarse control state. Zig owns the registered native component instance, measurement, final-bounds painting, invalidation, and handled input.

## Solid surface

```ts
NativeView({
  nativeType: 'editor',
  nativeProps: { file: 'README.md' },
  style: { grow: 1 },
  onNativeState: event => {
    // coarse state only: cursor position, dirty state, mode, etc.
  },
});
```

A NativeView is focusable by default. `nativeType` selects a Zig registration and `nativeProps` is serialized through the normal Hondo property bridge. Property changes are intentionally coarse and are not the editor input path.

## Zig registration

A native component supplies callbacks for:

- instance creation/destruction
- measurement under terminal constraints
- painting into the Hondo cell grid using final layout bounds
- optional coarse property updates
- optional direct terminal input

The registry owns instance lifetime. Detaching a NativeView from the Hondo scene destroys its Zig instance; changing `nativeType` destroys the old instance and creates the newly registered type.

## Layout and paint

Native measurement is temporarily supplied to the existing Hondo scene renderer as the node's natural width/height. Explicit Hondo width/height remain authoritative. The native renderer derives final bounds from the same Hondo layout output and calls the Zig paint callback with those bounds.

Native cells are composited only where the native node remains the topmost Hondo owner. This keeps ordinary Hondo overlays/popups above native content without creating a second layout or z-order implementation.

## Input ownership

When a focused event targets a registered NativeView, Hondo invokes the Zig input callback first. If Zig returns `handled`, the event does not call `__hondoDispatchNodeEvent` and therefore does not enter QuickJS/Solid. Ignored events fall back to the normal Hondo node event path.

Mouse targeting uses the same measured Hondo layout. Focus handoff remains compatible with Hondo's focus manager. Tab/Shift-Tab and normal JS default behavior continue to work when native code ignores the event.

Native code may queue a `nativeState` notification for coarse state changes. Those notifications intentionally cross into Solid; ordinary editor keystrokes do not.

## Hot-path benchmark

The Zig test `focused NativeView handles hot-path keys without a JavaScript node dispatcher` sends 10,000 key events through the native-first runtime. The QuickJS context intentionally does not install a Hondo scene bridge or `__hondoDispatchNodeEvent`. Every iteration must return the native dispatch path. If a handled key ever enters the JS node-event bridge, the test fails with a missing dispatcher.

The benchmark records elapsed time as a smoke measurement but does not enforce a machine-dependent wall-clock threshold in CI. The invariant being gated is stronger and stable across runners: handled native input requires zero JS event dispatches.
