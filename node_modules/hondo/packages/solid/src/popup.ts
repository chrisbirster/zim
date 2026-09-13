import { type HondoNode } from '@hondo/core';
import {
  Box,
  type HondoStyle,
  type PrimitiveProps,
} from './components.js';
import { keyPayload } from './controls.js';

export interface PopupProps
  extends Omit<PrimitiveProps, 'style' | 'onKey'> {
  x?: number;
  y?: number;
  zIndex?: number;
  style?: HondoStyle;
  onDismiss?: () => void;
  onKey?: PrimitiveProps['onKey'];
}

export function Popup(props: PopupProps = {}): HondoNode {
  return Box({
    get style() {
      return {
        ...(props.style ?? {}),
        position: 'overlay' as const,
        x: Math.max(0, Math.trunc(props.x ?? 0)),
        y: Math.max(0, Math.trunc(props.y ?? 0)),
        zIndex: Math.max(0, Math.trunc(props.zIndex ?? 0)),
      };
    },
    get focusable() {
      return props.focusable;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || !props.onDismiss) return;
      if (keyPayload(event)?.kind !== 'escape') return;
      props.onDismiss();
      event.preventDefault();
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: props.onMouse,
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      return props.children;
    },
  });
}
