import { describe, expect, it } from 'vitest';
import { flush } from 'solid-js';
import { HondoHost, RecordingMutationBridge, installHost } from '@hondo/core';
import { Box, Column, Row, Spacer, Text } from './components.js';
import { render } from './renderer.js';

describe('Hondo primitive components', () => {
  it('serializes typed layout and paint props through the existing scene bridge', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);

    const dispose = render(() =>
      Column({
        style: { width: 30, gap: 1, padding: 1, background: '#101820' },
        children: Row({
          style: { align: 'center', grow: 1 },
          children: [
            Text({ style: { bold: true, foreground: 'bright-cyan' }, children: 'Hondo' }),
            Spacer({ grow: 1 }),
            Text({ children: 'ready' }),
          ],
        }),
      }),
    host.root);
    flush();

    const mutations = bridge.take();
    const elementTypes = mutations
      .filter(mutation => mutation.kind === 'createElement')
      .map(mutation => mutation.type);
    const styleValues = mutations.flatMap(mutation =>
      mutation.kind === 'setProperty' && mutation.name === 'style'
        ? [mutation.value]
        : [],
    );

    expect({ elementTypes, styleValues }).toMatchInlineSnapshot(`
      {
        "elementTypes": [
          "text",
          "spacer",
          "text",
          "row",
          "column",
        ],
        "styleValues": [
          {
            "bold": true,
            "foreground": "bright-cyan",
          },
          {
            "basis": 0,
            "grow": 1,
            "shrink": 1,
          },
          {
            "align": "center",
            "grow": 1,
          },
          {
            "background": "#101820",
            "gap": 1,
            "padding": 1,
            "width": 30,
          },
        ],
      }
    `);

    dispose();
    restore();
  });

  it('exposes refs, focus requests, and existing capture/target/bubble handlers', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const restore = installHost(host);
    const calls: string[] = [];
    let focus: (() => void) | undefined;
    let targetId = -1;

    const dispose = render(() =>
      Box({
        onKeyCapture: event => calls.push(`box:${event.phase}`),
        children: Text({
          focusable: true,
          ref: handle => {
            targetId = handle.node.id;
            focus = () => handle.focus();
          },
          onKey: event => calls.push(`text:${event.phase}`),
          children: 'focus me',
        }),
      }),
    host.root);
    flush();
    bridge.take();

    focus?.();
    const focusMutations = bridge.take();
    expect(focusMutations).toHaveLength(1);
    expect(focusMutations[0]).toMatchObject({
      kind: 'setProperty',
      id: targetId,
      name: 'focusRequest',
    });
    expect((focusMutations[0] as { value: number }).value).toBeGreaterThan(0);

    host.dispatchNodeEvent(targetId, 'key', { kind: 'enter' });
    expect(calls).toEqual(['box:capture', 'text:target']);

    dispose();
    restore();
  });
});
