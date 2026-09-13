import {
  HondoHost,
  NativeMutationBridge,
  installHost,
  type HondoMutationBridge,
  type HondoNodeEvent,
  type HondoValue,
} from '@hondo/core';
import {
  Text,
  createSignal,
  render,
} from '@hondo/solid';
import { flush } from 'solid-js';

export interface MountedCounter {
  increment(): void;
  dispose(): void;
}

export function mountCounter(
  bridge: HondoMutationBridge = new NativeMutationBridge(),
): MountedCounter {
  const host = new HondoHost(bridge);
  const restoreHost = installHost(host);
  const [count, setCount] = createSignal(0);

  const increment = () => {
    setCount(value => value + 1);
    flush();
  };

  const disposeRender = render(() =>
    Text({
      focusable: true,
      autoFocus: true,
      onKey: (event: HondoNodeEvent) => {
        if (!isActivationKey(event.payload)) return;
        event.preventDefault();
        increment();
      },
      onMouse: (event: HondoNodeEvent) => {
        if (!isActivationMouse(event.payload)) return;
        increment();
      },
      children: () => `Count: ${count()}`,
    }),
  host.root);
  flush();

  let disposed = false;

  return {
    increment() {
      if (disposed) throw new Error('Counter has been disposed');
      increment();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      disposeRender();
      restoreHost();
    },
  };
}

function isActivationKey(payload: HondoValue): boolean {
  if (!payload || Array.isArray(payload) || typeof payload !== 'object') return false;
  if (payload.kind === 'enter') return true;
  return payload.kind === 'codepoint' && payload.codepoint === 32;
}

function isActivationMouse(payload: HondoValue): boolean {
  if (!payload || Array.isArray(payload) || typeof payload !== 'object') return false;
  return payload.button === 'left' && payload.action === 'press';
}
