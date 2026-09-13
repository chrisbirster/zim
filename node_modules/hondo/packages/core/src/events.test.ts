import { afterEach, describe, expect, it } from 'vitest';
import {
  clearNativeEventsForTests,
  registerNativeEvent,
} from './events.js';

type HondoEventGlobals = typeof globalThis & {
  __hondoDispatchNativeEvent?: (name: string, payloadJson: string) => void;
};

const globals = globalThis as HondoEventGlobals;

afterEach(() => clearNativeEventsForTests());

describe('native event registry', () => {
  it('dispatches parsed payloads to registered handlers', () => {
    const payloads: unknown[] = [];
    const dispose = registerNativeEvent('counter.increment', payload => {
      payloads.push(payload);
    });

    globals.__hondoDispatchNativeEvent?.(
      'counter.increment',
      '{"source":"keyboard"}',
    );

    expect(payloads).toEqual([{ source: 'keyboard' }]);
    dispose();
  });

  it('stops dispatching after disposal', () => {
    let calls = 0;
    const dispose = registerNativeEvent('counter.increment', () => {
      calls += 1;
    });

    dispose();
    globals.__hondoDispatchNativeEvent?.('counter.increment', 'null');

    expect(calls).toBe(0);
  });
});
