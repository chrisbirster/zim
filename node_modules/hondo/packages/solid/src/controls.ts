import {
  type HondoNode,
  type HondoNodeEvent,
  type HondoNodeEventHandler,
} from '@hondo/core';
import {
  Column,
  Row,
  Text,
  type HondoRef,
  type HondoStyle,
  type PrimitiveProps,
} from './components.js';

export type HondoKeyKind =
  | 'codepoint'
  | 'enter'
  | 'backspace'
  | 'tab'
  | 'shiftTab'
  | 'escape'
  | 'ctrlC'
  | 'up'
  | 'down'
  | 'left'
  | 'right';

export interface HondoKeyPayload {
  kind: HondoKeyKind;
  codepoint?: number;
}

export type HondoMouseButton =
  | 'none'
  | 'left'
  | 'middle'
  | 'right'
  | 'wheelUp'
  | 'wheelDown';

export type HondoMouseAction = 'press' | 'release' | 'move' | 'scroll';

export interface HondoMousePayload {
  x: number;
  y: number;
  button: HondoMouseButton;
  action: HondoMouseAction;
  shift: boolean;
  alt: boolean;
  ctrl: boolean;
}

export interface InputProps
  extends Omit<PrimitiveProps, 'children' | 'focusable' | 'onKey'> {
  value: string;
  placeholder?: string;
  disabled?: boolean;
  onInput?: (value: string) => void;
  onSubmit?: (value: string) => void;
  onKey?: HondoNodeEventHandler;
}

export function Input(props: InputProps): HondoNode {
  return Text({
    get style() {
      const style = props.style;
      if (props.value.length > 0 || !props.placeholder) return style;
      return { dim: true, ...(style ?? {}) };
    },
    get focusable() {
      return !props.disabled;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || props.disabled) return;

      const key = keyPayload(event);
      if (!key) return;

      if (key.kind === 'codepoint' && key.codepoint !== undefined) {
        props.onInput?.(`${props.value}${String.fromCodePoint(key.codepoint)}`);
        if (props.onInput) event.preventDefault();
        return;
      }

      if (key.kind === 'backspace') {
        props.onInput?.(removeLastCodePoint(props.value));
        if (props.onInput) event.preventDefault();
        return;
      }

      if (key.kind === 'enter' && props.onSubmit) {
        props.onSubmit(props.value);
        event.preventDefault();
      }
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: props.onMouse,
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      return props.value.length > 0 ? props.value : (props.placeholder ?? '');
    },
  });
}

export interface ListProps<T>
  extends Omit<PrimitiveProps, 'children' | 'focusable' | 'onKey'> {
  items: readonly T[];
  selectedIndex: number;
  disabled?: boolean;
  loop?: boolean;
  viewportSize?: number;
  itemStyle?: HondoStyle;
  selectedStyle?: HondoStyle;
  renderItem?: (item: T, index: number, selected: boolean) => string;
  onSelectionChange?: (index: number, item: T) => void;
  onActivate?: (index: number, item: T) => void;
  onKey?: HondoNodeEventHandler;
}

export function List<T>(props: ListProps<T>): HondoNode {
  const rows: HondoNode[] = [];

  const ensureRows = () => {
    while (rows.length < props.items.length) {
      const index = rows.length;
      rows.push(
        Text({
          get style() {
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            return selected
              ? { ...(props.itemStyle ?? {}), reverse: true, ...(props.selectedStyle ?? {}) }
              : props.itemStyle;
          },
          get children() {
            const item = props.items[index];
            if (item === undefined) return '';
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            return props.renderItem
              ? props.renderItem(item, index, selected)
              : String(item);
          },
        }),
      );
    }
  };

  return Column({
    get style() {
      return {
        clip: true,
        ...(props.viewportSize !== undefined ? { height: Math.max(0, props.viewportSize) } : {}),
        ...(props.style ?? {}),
      };
    },
    get focusable() {
      return !props.disabled;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;

      const key = keyPayload(event);
      if (!key) return;

      if (key.kind === 'up' || key.kind === 'down') {
        const direction = key.kind === 'down' ? 1 : -1;
        const next = nextIndex(
          clampIndex(props.selectedIndex, props.items.length),
          direction,
          props.items.length,
          props.loop ?? false,
        );
        if (next !== props.selectedIndex) {
          const item = props.items[next];
          if (item !== undefined) props.onSelectionChange?.(next, item);
        }
        if (props.onSelectionChange) event.preventDefault();
        return;
      }

      if (key.kind === 'enter' && props.onActivate) {
        const index = clampIndex(props.selectedIndex, props.items.length);
        const item = props.items[index];
        if (item !== undefined) {
          props.onActivate(index, item);
          event.preventDefault();
        }
      }
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: event => {
      props.onMouse?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;
      const mouse = mousePayload(event);
      if (!mouse || mouse.button !== 'left') return;
      ensureRows();
      const index = targetNodeIndex(event, rows, props.items.length);
      if (index < 0) return;
      const item = props.items[index];
      if (item === undefined) return;

      if (mouse.action === 'press') {
        if (index !== clampIndex(props.selectedIndex, props.items.length)) {
          props.onSelectionChange?.(index, item);
        }
      } else if (
        mouse.action === 'release'
        && index === clampIndex(props.selectedIndex, props.items.length)
      ) {
        props.onActivate?.(index, item);
      }
    },
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      ensureRows();
      const count = props.items.length;
      if (count === 0) return [];
      const viewport = normalizeViewport(props.viewportSize, count);
      const selected = clampIndex(props.selectedIndex, count);
      const start = viewportStart(selected, count, viewport);
      return rows.slice(start, Math.min(count, start + viewport));
    },
  });
}

export interface MenuProps<T>
  extends Omit<PrimitiveProps, 'children' | 'focusable' | 'onKey'> {
  items: readonly T[];
  selectedIndex: number;
  disabled?: boolean;
  loop?: boolean;
  viewportSize?: number;
  itemStyle?: HondoStyle;
  selectedStyle?: HondoStyle;
  disabledStyle?: HondoStyle;
  renderItem?: (item: T, index: number, selected: boolean) => string;
  isDisabled?: (item: T, index: number) => boolean;
  onSelectionChange?: (index: number, item: T) => void;
  onActivate?: (index: number, item: T) => void;
  onKey?: HondoNodeEventHandler;
}

export function Menu<T>(props: MenuProps<T>): HondoNode {
  const rows: HondoNode[] = [];

  const itemDisabled = (index: number) => {
    const item = props.items[index];
    return item === undefined || (props.isDisabled?.(item, index) ?? false);
  };

  const ensureRows = () => {
    while (rows.length < props.items.length) {
      const index = rows.length;
      rows.push(
        Text({
          get style() {
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            const disabled = itemDisabled(index);
            return {
              ...(props.itemStyle ?? {}),
              ...(selected ? { reverse: true, ...(props.selectedStyle ?? {}) } : {}),
              ...(disabled ? { dim: true, ...(props.disabledStyle ?? {}) } : {}),
            };
          },
          get children() {
            const item = props.items[index];
            if (item === undefined) return '';
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            return props.renderItem
              ? props.renderItem(item, index, selected)
              : String(item);
          },
        }),
      );
    }
  };

  return Column({
    get style() {
      return {
        clip: true,
        ...(props.viewportSize !== undefined ? { height: Math.max(0, props.viewportSize) } : {}),
        ...(props.style ?? {}),
      };
    },
    get focusable() {
      return !props.disabled && props.items.length > 0;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;
      const key = keyPayload(event);
      if (!key) return;

      if (key.kind === 'up' || key.kind === 'down') {
        const direction = key.kind === 'down' ? 1 : -1;
        const current = clampIndex(props.selectedIndex, props.items.length);
        const next = nextEnabledIndex(
          current,
          direction,
          props.items.length,
          props.loop ?? false,
          itemDisabled,
        );
        if (next !== current) {
          const item = props.items[next];
          if (item !== undefined) props.onSelectionChange?.(next, item);
        }
        if (props.onSelectionChange) event.preventDefault();
        return;
      }

      if (key.kind === 'enter' && props.onActivate) {
        const index = clampIndex(props.selectedIndex, props.items.length);
        const item = props.items[index];
        if (item !== undefined && !itemDisabled(index)) {
          props.onActivate(index, item);
          event.preventDefault();
        }
      }
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: event => {
      props.onMouse?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;
      const mouse = mousePayload(event);
      if (!mouse || mouse.button !== 'left') return;
      ensureRows();
      const index = targetNodeIndex(event, rows, props.items.length);
      if (index < 0 || itemDisabled(index)) return;
      const item = props.items[index];
      if (item === undefined) return;

      if (mouse.action === 'press') {
        if (index !== clampIndex(props.selectedIndex, props.items.length)) {
          props.onSelectionChange?.(index, item);
        }
      } else if (
        mouse.action === 'release'
        && index === clampIndex(props.selectedIndex, props.items.length)
      ) {
        props.onActivate?.(index, item);
      }
    },
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      ensureRows();
      const count = props.items.length;
      if (count === 0) return [];
      const viewport = normalizeViewport(props.viewportSize, count);
      const selected = clampIndex(props.selectedIndex, count);
      const start = viewportStart(selected, count, viewport);
      return rows.slice(start, Math.min(count, start + viewport));
    },
  });
}

export interface TabsProps<T>
  extends Omit<PrimitiveProps, 'children' | 'focusable' | 'onKey'> {
  items: readonly T[];
  selectedIndex: number;
  disabled?: boolean;
  loop?: boolean;
  tabStyle?: HondoStyle;
  selectedStyle?: HondoStyle;
  disabledStyle?: HondoStyle;
  renderTab?: (item: T, index: number, selected: boolean) => string;
  isDisabled?: (item: T, index: number) => boolean;
  onSelectionChange?: (index: number, item: T) => void;
  onActivate?: (index: number, item: T) => void;
  onKey?: HondoNodeEventHandler;
}

export function Tabs<T>(props: TabsProps<T>): HondoNode {
  const tabs: HondoNode[] = [];

  const itemDisabled = (index: number) => {
    const item = props.items[index];
    return item === undefined || (props.isDisabled?.(item, index) ?? false);
  };

  const ensureTabs = () => {
    while (tabs.length < props.items.length) {
      const index = tabs.length;
      tabs.push(
        Text({
          get style() {
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            const disabled = itemDisabled(index);
            return {
              ...(props.tabStyle ?? {}),
              ...(selected ? { reverse: true, ...(props.selectedStyle ?? {}) } : {}),
              ...(disabled ? { dim: true, ...(props.disabledStyle ?? {}) } : {}),
            };
          },
          get children() {
            const item = props.items[index];
            if (item === undefined) return '';
            const selected = index === clampIndex(props.selectedIndex, props.items.length);
            return props.renderTab ? props.renderTab(item, index, selected) : String(item);
          },
        }),
      );
    }
  };

  return Row({
    get style() {
      return { gap: 1, ...(props.style ?? {}) };
    },
    get focusable() {
      return !props.disabled && props.items.length > 0;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;
      const key = keyPayload(event);
      if (!key) return;

      if (key.kind === 'left' || key.kind === 'right') {
        const direction = key.kind === 'right' ? 1 : -1;
        const current = clampIndex(props.selectedIndex, props.items.length);
        const next = nextEnabledIndex(
          current,
          direction,
          props.items.length,
          props.loop ?? false,
          itemDisabled,
        );
        if (next !== current) {
          const item = props.items[next];
          if (item !== undefined) props.onSelectionChange?.(next, item);
        }
        if (props.onSelectionChange) event.preventDefault();
        return;
      }

      if (key.kind === 'enter' && props.onActivate) {
        const index = clampIndex(props.selectedIndex, props.items.length);
        const item = props.items[index];
        if (item !== undefined && !itemDisabled(index)) {
          props.onActivate(index, item);
          event.preventDefault();
        }
      }
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: event => {
      props.onMouse?.(event);
      if (event.defaultPrevented || props.disabled || props.items.length === 0) return;
      const mouse = mousePayload(event);
      if (!mouse || mouse.button !== 'left') return;
      ensureTabs();
      const index = targetNodeIndex(event, tabs, props.items.length);
      if (index < 0 || itemDisabled(index)) return;
      const item = props.items[index];
      if (item === undefined) return;

      if (mouse.action === 'press') {
        if (index !== clampIndex(props.selectedIndex, props.items.length)) {
          props.onSelectionChange?.(index, item);
        }
      } else if (
        mouse.action === 'release'
        && index === clampIndex(props.selectedIndex, props.items.length)
      ) {
        props.onActivate?.(index, item);
      }
    },
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      ensureTabs();
      return tabs.slice(0, props.items.length);
    },
  });
}

export interface ScrollViewProps
  extends Omit<PrimitiveProps, 'children' | 'focusable' | 'onKey'> {
  children: readonly unknown[];
  offset?: number;
  viewportSize?: number;
  disabled?: boolean;
  onOffsetChange?: (offset: number) => void;
  onKey?: HondoNodeEventHandler;
}

export function ScrollView(props: ScrollViewProps): HondoNode {
  const scroll = (direction: -1 | 1) => {
    if (props.disabled || !props.onOffsetChange) return false;
    const viewport = normalizeViewport(props.viewportSize, props.children.length);
    const maximum = Math.max(0, props.children.length - viewport);
    const current = clamp(props.offset ?? 0, 0, maximum);
    const next = clamp(current + direction, 0, maximum);
    if (next !== current) props.onOffsetChange(next);
    return true;
  };

  return Column({
    get style() {
      return {
        clip: true,
        ...(props.viewportSize !== undefined ? { height: Math.max(0, props.viewportSize) } : {}),
        ...(props.style ?? {}),
      };
    },
    get focusable() {
      return !props.disabled && props.onOffsetChange !== undefined;
    },
    get autoFocus() {
      return props.autoFocus;
    },
    get ref() {
      return props.ref;
    },
    onKey: event => {
      props.onKey?.(event);
      if (event.defaultPrevented || props.disabled || !props.onOffsetChange) return;

      const key = keyPayload(event);
      if (!key || (key.kind !== 'up' && key.kind !== 'down')) return;
      scroll(key.kind === 'down' ? 1 : -1);
      event.preventDefault();
    },
    onKeyCapture: props.onKeyCapture,
    onMouse: event => {
      props.onMouse?.(event);
      if (event.defaultPrevented || props.disabled || !props.onOffsetChange) return;
      const mouse = mousePayload(event);
      if (!mouse || mouse.action !== 'scroll') return;
      if (mouse.button !== 'wheelUp' && mouse.button !== 'wheelDown') return;
      scroll(mouse.button === 'wheelDown' ? 1 : -1);
      event.preventDefault();
    },
    onMouseCapture: props.onMouseCapture,
    onFocusIn: props.onFocusIn,
    onFocusInCapture: props.onFocusInCapture,
    onFocusOut: props.onFocusOut,
    onFocusOutCapture: props.onFocusOutCapture,
    get children() {
      const viewport = normalizeViewport(props.viewportSize, props.children.length);
      const maximum = Math.max(0, props.children.length - viewport);
      const start = clamp(props.offset ?? 0, 0, maximum);
      return props.children.slice(start, start + viewport);
    },
  });
}

export function keyPayload(event: HondoNodeEvent): HondoKeyPayload | undefined {
  if (event.type !== 'key') return undefined;
  const payload = event.payload;
  if (payload === null || Array.isArray(payload) || typeof payload !== 'object') return undefined;

  const kind = payload.kind;
  if (typeof kind !== 'string' || !isKeyKind(kind)) return undefined;

  if (kind === 'codepoint') {
    return typeof payload.codepoint === 'number'
      ? { kind, codepoint: payload.codepoint }
      : undefined;
  }
  return { kind };
}

export function mousePayload(event: HondoNodeEvent): HondoMousePayload | undefined {
  if (event.type !== 'mouse') return undefined;
  const payload = event.payload;
  if (payload === null || Array.isArray(payload) || typeof payload !== 'object') return undefined;

  const { x, y, button, action, shift, alt, ctrl } = payload;
  if (typeof x !== 'number' || typeof y !== 'number') return undefined;
  if (typeof button !== 'string' || !isMouseButton(button)) return undefined;
  if (typeof action !== 'string' || !isMouseAction(action)) return undefined;
  if (typeof shift !== 'boolean' || typeof alt !== 'boolean' || typeof ctrl !== 'boolean') {
    return undefined;
  }

  return { x, y, button, action, shift, alt, ctrl };
}

function targetNodeIndex(event: HondoNodeEvent, nodes: readonly HondoNode[], count: number): number {
  const limit = Math.min(nodes.length, count);
  for (let index = 0; index < limit; index += 1) {
    const node = nodes[index];
    if (node && nodeContainsTarget(node, event.target)) return index;
  }
  return -1;
}

function nodeContainsTarget(node: HondoNode, target: HondoNode): boolean {
  for (let current: HondoNode | null = target; current; current = current.parent) {
    if (current === node) return true;
  }
  return false;
}

function removeLastCodePoint(value: string): string {
  const codepoints = Array.from(value);
  codepoints.pop();
  return codepoints.join('');
}

function isKeyKind(value: string): value is HondoKeyKind {
  return value === 'codepoint'
    || value === 'enter'
    || value === 'backspace'
    || value === 'tab'
    || value === 'shiftTab'
    || value === 'escape'
    || value === 'ctrlC'
    || value === 'up'
    || value === 'down'
    || value === 'left'
    || value === 'right';
}

function isMouseButton(value: string): value is HondoMouseButton {
  return value === 'none'
    || value === 'left'
    || value === 'middle'
    || value === 'right'
    || value === 'wheelUp'
    || value === 'wheelDown';
}

function isMouseAction(value: string): value is HondoMouseAction {
  return value === 'press'
    || value === 'release'
    || value === 'move'
    || value === 'scroll';
}

function nextIndex(current: number, direction: -1 | 1, count: number, loop: boolean): number {
  if (count <= 0) return 0;
  const next = current + direction;
  if (loop) return (next + count) % count;
  return clamp(next, 0, count - 1);
}

function nextEnabledIndex(
  current: number,
  direction: -1 | 1,
  count: number,
  loop: boolean,
  isDisabled: (index: number) => boolean,
): number {
  if (count <= 0) return 0;
  let candidate = current;

  for (let attempts = 0; attempts < count; attempts += 1) {
    candidate += direction;
    if (loop) {
      candidate = (candidate + count) % count;
    } else if (candidate < 0 || candidate >= count) {
      return current;
    }

    if (!isDisabled(candidate)) return candidate;
  }

  return current;
}

function clampIndex(index: number, count: number): number {
  if (count <= 0) return 0;
  return clamp(Math.trunc(index), 0, count - 1);
}

function normalizeViewport(viewportSize: number | undefined, count: number): number {
  if (viewportSize === undefined) return count;
  return clamp(Math.trunc(viewportSize), 0, count);
}

function viewportStart(selected: number, count: number, viewport: number): number {
  if (viewport <= 0 || count <= viewport) return 0;
  return clamp(selected - viewport + 1, 0, count - viewport);
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

export type { HondoRef, HondoStyle };
