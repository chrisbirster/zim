import {
  HondoHost,
  NativeMutationBridge,
  installHost,
  type HondoMutationBridge,
} from '@hondo/core';
import { Box, Column, Row, Spacer, Text, render } from '@hondo/solid';
import { flush } from 'solid-js';

export interface MountedDashboard {
  dispose(): void;
}

export function mountDashboard(
  bridge: HondoMutationBridge = new NativeMutationBridge(),
): MountedDashboard {
  const host = new HondoHost(bridge);
  const restoreHost = installHost(host);

  const disposeRender = render(() =>
    Column({
      style: {
        width: 56,
        minWidth: 32,
        maxWidth: 72,
        padding: 1,
        gap: 1,
        background: '#101820',
      },
      children: [
        Row({
          style: { width: 54, align: 'center' },
          children: [
            Text({
              style: { bold: true, foreground: 'bright-cyan' },
              children: 'HONDO',
            }),
            Spacer({ grow: 1 }),
            Text({
              style: { foreground: 'bright-green' },
              children: 'native terminal online',
            }),
          ],
        }),
        Row({
          style: { width: 54, gap: 2 },
          children: [
            Box({
              style: { width: 25, paddingX: 1, background: '#17212b' },
              children: Text({
                style: { bold: true, foreground: 'bright-yellow' },
                children: 'Render: incremental',
              }),
            }),
            Box({
              style: { grow: 1, minWidth: 20, paddingX: 1, background: '#17212b' },
              children: Text({ children: 'Focus: Solid → Zig' }),
            }),
          ],
        }),
        Text({
          focusable: true,
          autoFocus: true,
          style: { dim: true },
          children: 'Enter to activate • mouse/focus routing enabled',
        }),
      ],
    }),
  host.root);
  flush();

  let disposed = false;
  return {
    dispose() {
      if (disposed) return;
      disposed = true;
      disposeRender();
      restoreHost();
    },
  };
}
