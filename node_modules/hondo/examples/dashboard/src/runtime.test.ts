import { describe, expect, it } from 'vitest';
import { RecordingMutationBridge } from '@hondo/core';
import { mountDashboard } from './runtime.js';

describe('dashboard example', () => {
  it('builds the dashboard entirely from public Hondo primitives', () => {
    const bridge = new RecordingMutationBridge();
    const dashboard = mountDashboard(bridge);

    try {
      const mutations = bridge.take();
      const elementTypes = mutations
        .filter(mutation => mutation.kind === 'createElement')
        .map(mutation => mutation.type);
      const text = mutations
        .filter(mutation => mutation.kind === 'createTextNode')
        .map(mutation => mutation.value);
      const focusRequest = mutations.find(
        mutation => mutation.kind === 'setProperty' && mutation.name === 'focusRequest',
      );

      expect({ elementTypes, text }).toMatchInlineSnapshot(`
        {
          "elementTypes": [
            "text",
            "spacer",
            "text",
            "row",
            "text",
            "box",
            "text",
            "box",
            "row",
            "text",
            "column",
          ],
          "text": [
            "HONDO",
            "native terminal online",
            "Render: incremental",
            "Focus: Solid → Zig",
            "Enter to activate • mouse/focus routing enabled",
          ],
        }
      `);
      expect(focusRequest).toMatchObject({
        kind: 'setProperty',
        name: 'focusRequest',
      });
    } finally {
      dashboard.dispose();
    }
  });
});
