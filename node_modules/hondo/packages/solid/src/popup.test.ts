import { flush } from 'solid-js';
import { describe, expect, it } from 'vitest';
import {
  HondoHost,
  RecordingMutationBridge,
  installHost,
  type HondoNode,
} from '@hondo/core';
import { Text } from './components.js';
import { Popup } from './popup.js';
import { render } from './renderer.js';

describe('Popup', () => {
  it('serializes viewport overlay positioning and z-order through the scene bridge', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);

    const dispose = render(() => Popup({
      x: 4,
      y: 2,
      zIndex: 9,
      style: { width: 20, padding: 1, background: 'blue' },
      children: Text({ children: 'Actions' }),
    }), host.root);
    flush();

    const styles = bridge.take().flatMap(mutation =>
      mutation.kind === 'setProperty' && mutation.name === 'style'
        ? [mutation.value]
        : [],
    );
    expect(styles.at(-1)).toEqual({
      width: 20,
      padding: 1,
      background: 'blue',
      position: 'overlay',
      x: 4,
      y: 2,
      zIndex: 9,
    });

    dispose();
    restore();
  });

  it('dismisses on bubbling Escape unless a user key handler prevents default', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);
    let child!: HondoNode;
    let dismissals = 0;

    const dispose = render(() => Popup({
      onDismiss: () => {
        dismissals += 1;
      },
      children: Text({
        children: 'focused child',
        ref: handle => {
          child = handle.node;
        },
      }),
    }), host.root);
    flush();

    host.dispatchNodeEvent(child.id, 'key', { kind: 'escape' });
    expect(dismissals).toBe(1);

    dispose();
    restore();

    const blockingBridge = new RecordingMutationBridge();
    const blockingHost = new HondoHost(blockingBridge);
    const blockingRestore = installHost(blockingHost);
    let blockedChild!: HondoNode;

    const blockingDispose = render(() => Popup({
      onKey: event => event.preventDefault(),
      onDismiss: () => {
        dismissals += 1;
      },
      children: Text({
        children: 'blocked child',
        ref: handle => {
          blockedChild = handle.node;
        },
      }),
    }), blockingHost.root);
    flush();

    blockingHost.dispatchNodeEvent(blockedChild.id, 'key', { kind: 'escape' });
    expect(dismissals).toBe(1);

    blockingDispose();
    blockingRestore();
  });
});
