import { createSignal, flush } from 'solid-js';
import { describe, expect, it } from 'vitest';
import {
  HondoHost,
  RecordingMutationBridge,
  installHost,
  type HondoNode,
} from '@hondo/core';
import { NativeView } from './native_view.js';
import { render } from './renderer.js';

describe('NativeView', () => {
  it('declares a focusable native type and reactively forwards coarse native props', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);
    const [title, setTitle] = createSignal('first');
    let node!: HondoNode;

    const dispose = render(() => NativeView({
      nativeType: 'editor',
      get nativeProps() {
        return { title: title(), lineCount: 3 };
      },
      ref: handle => {
        node = handle.node;
      },
      style: { grow: 1 },
    }), host.root);
    flush();

    const initial = bridge.take();
    expect(initial).toContainEqual({
      kind: 'setProperty',
      id: node.id,
      name: 'nativeType',
      value: 'editor',
    });
    expect(initial).toContainEqual({
      kind: 'setProperty',
      id: node.id,
      name: 'nativeProps',
      value: { title: 'first', lineCount: 3 },
    });
    expect(initial).toContainEqual({
      kind: 'setProperty',
      id: node.id,
      name: 'focusable',
      value: true,
    });

    setTitle('second');
    flush();
    expect(bridge.take()).toContainEqual({
      kind: 'setProperty',
      id: node.id,
      name: 'nativeProps',
      value: { title: 'second', lineCount: 3 },
    });

    dispose();
    restore();
  });

  it('receives coarse native state notifications through normal Hondo propagation', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);
    const states: unknown[] = [];
    let node!: HondoNode;

    const dispose = render(() => NativeView({
      nativeType: 'editor',
      ref: handle => {
        node = handle.node;
      },
      onNativeState: event => states.push(event.payload),
    }), host.root);
    flush();

    host.dispatchNodeEvent(node.id, 'nativeState', {
      cursorLine: 12,
      dirty: true,
    });
    expect(states).toEqual([{ cursorLine: 12, dirty: true }]);

    dispose();
    restore();
  });
});
