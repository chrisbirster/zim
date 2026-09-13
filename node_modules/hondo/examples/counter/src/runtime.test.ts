import { describe, expect, it } from 'vitest';
import { RecordingMutationBridge } from '@hondo/core';
import { mountCounter } from './runtime.js';

describe('native counter runtime', () => {
  it('mounts Count: 0 and increments with one replaceText mutation', () => {
    const bridge = new RecordingMutationBridge();
    const counter = mountCounter(bridge);

    try {
      const mount = bridge.take();
      const textCreate = mount.find(operation => operation.kind === 'createTextNode');

      expect(textCreate).toMatchObject({
        kind: 'createTextNode',
        value: 'Count: 0',
      });

      counter.increment();

      expect(bridge.take()).toEqual([
        {
          kind: 'replaceText',
          id: textCreate?.id,
          value: 'Count: 1',
        },
      ]);
    } finally {
      counter.dispose();
    }
  });
});
