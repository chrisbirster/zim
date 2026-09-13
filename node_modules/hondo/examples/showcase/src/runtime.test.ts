import { describe, expect, it } from 'vitest';
import { RecordingMutationBridge } from '@hondo/core';
import { mountShowcase } from './runtime.js';

describe('showcase', () => {
  it('mounts a composed non-Zim Hondo application surface', () => {
    const bridge = new RecordingMutationBridge();
    const mounted = mountShowcase(bridge);
    const mutations = bridge.take();

    const elementTypes = mutations.flatMap(mutation =>
      mutation.kind === 'createElement' ? [mutation.type] : [],
    );
    const propertyNames = mutations.flatMap(mutation =>
      mutation.kind === 'setProperty' ? [mutation.name] : [],
    );

    expect(elementTypes).toContain('column');
    expect(elementTypes).toContain('row');
    expect(elementTypes).toContain('text');
    expect(elementTypes).toContain('box');
    expect(propertyNames).toContain('style');
    expect(propertyNames).toContain('focusable');

    mounted.dispose();
  });
});
