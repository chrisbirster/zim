import {
  type HondoNode,
  type HondoNodeEventHandler,
} from '@hondo/core';
import {
  Box,
  type HondoEventProps,
  type HondoRef,
  type HondoStyle,
} from './components.js';
import { effect, setProp } from './renderer.js';

export interface NativeViewProps extends HondoEventProps {
  nativeType: string;
  nativeProps?: unknown;
  style?: HondoStyle;
  focusable?: boolean;
  autoFocus?: boolean;
  ref?: HondoRef;
  onNativeState?: HondoNodeEventHandler;
}

/**
 * Declares a Zig-owned region in the Hondo scene.
 *
 * Solid owns the component's coarse properties and surrounding application
 * chrome. The registered native implementation owns measurement, painting,
 * invalidation, and hot-path input once the node is mounted by Zig.
 */
export function NativeView(props: NativeViewProps): HondoNode {
  if (!props.nativeType) throw new TypeError('NativeView nativeType cannot be empty');

  const node = Box({
    get style() {
      return props.style;
    },
    get focusable() {
      return props.focusable ?? true;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: props.onKey,
    onKeyCapture: props.onKeyCapture,
    onMouse: props.onMouse,
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
  });

  effect(
    () => props.nativeType,
    nativeType => {
      if (!nativeType) throw new TypeError('NativeView nativeType cannot be empty');
      setProp(node, 'nativeType', nativeType);
    },
  );

  effect(
    () => props.nativeProps,
    nativeProps => {
      setProp(node, 'nativeProps', nativeProps ?? {});
    },
  );

  effect(
    () => props.onNativeState,
    handler => {
      setProp(node, 'onNativeState', handler ?? null);
    },
  );

  return node;
}
