import type { HondoValue } from './bridge.js';

export type HondoNativeEventHandler = (payload: HondoValue) => void;

const handlers = new Map<string, Set<HondoNativeEventHandler>>();

type HondoEventGlobals = typeof globalThis & {
  __hondoDispatchNativeEvent?: (name: string, payloadJson: string) => void;
};

function decodePayload(payloadJson: string): HondoValue {
  const value: unknown = JSON.parse(payloadJson);
  return value as HondoValue;
}

function dispatchNativeEvent(name: string, payloadJson: string): void {
  const listeners = handlers.get(name);
  if (!listeners || listeners.size === 0) return;

  const payload = decodePayload(payloadJson);
  for (const listener of [...listeners]) listener(payload);
}

const globals = globalThis as HondoEventGlobals;
if (typeof globals.__hondoDispatchNativeEvent !== 'function') {
  globals.__hondoDispatchNativeEvent = dispatchNativeEvent;
}

export function registerNativeEvent(
  name: string,
  handler: HondoNativeEventHandler,
): () => void {
  if (!name) throw new TypeError('Hondo native event name cannot be empty');
  if (typeof handler !== 'function') {
    throw new TypeError('Hondo native event handler must be a function');
  }

  let listeners = handlers.get(name);
  if (!listeners) {
    listeners = new Set();
    handlers.set(name, listeners);
  }
  listeners.add(handler);

  let disposed = false;
  return () => {
    if (disposed) return;
    disposed = true;

    const current = handlers.get(name);
    current?.delete(handler);
    if (current?.size === 0) handlers.delete(name);
  };
}

export function clearNativeEventsForTests(): void {
  handlers.clear();
}
