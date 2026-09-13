import { describe, expect, it } from 'vitest';
import { createSignal, flush } from 'solid-js';
import {
  HondoHost,
  RecordingMutationBridge,
  installHost,
} from '@hondo/core';
import {
  createElement,
  insert,
  render,
  solid2Baseline,
} from './index.js';

describe('Solid 2 baseline', () => {
  it('uses the coordinated Solid 2 RC packages', () => {
    expect(solid2Baseline).toEqual({
      core: '2.0.0-rc.4',
      universal: '2.0.0-rc.4',
    });
  });

  it('runs Solid fine-grained signals', () => {
    const [count, setCount] = createSignal(0);
    expect(count()).toBe(0);
    setCount(1);
    flush();
    expect(count()).toBe(1);
  });

  it('turns a reactive child change into one text mutation', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restoreHost = installHost(host);
    const [count, setCount] = createSignal(0);

    try {
      const dispose = render(() => {
        const textContainer = createElement('text');
        insert(textContainer, () => `Count: ${count()}`);
        return textContainer;
      }, host.root);
      flush();

      expect(host.root.children).toHaveLength(1);
      const textContainer = host.root.children[0];
      expect(textContainer?.type).toBe('text');
      expect(textContainer?.children).toHaveLength(1);

      const text = textContainer?.children[0];
      expect(text?.isText).toBe(true);
      expect(text?.textValue).toBe('Count: 0');

      bridge.take();
      setCount(1);
      flush();

      expect(text?.textValue).toBe('Count: 1');
      expect(bridge.take()).toEqual([
        { kind: 'replaceText', id: text?.id, value: 'Count: 1' },
      ]);

      dispose();
    } finally {
      restoreHost();
    }
  });
});
