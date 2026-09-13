import { registerNativeEvent } from '@hondo/core';
import { mountCounter } from './runtime.js';

const counter = mountCounter();
const unregisterIncrement = registerNativeEvent(
  'counter.increment',
  () => counter.increment(),
);

type HondoCounterGlobals = typeof globalThis & {
  __hondoCounterIncrement?: () => void;
  __hondoCounterDispose?: () => void;
};

const globals = globalThis as HondoCounterGlobals;
globals.__hondoCounterIncrement = () => counter.increment();
globals.__hondoCounterDispose = () => {
  unregisterIncrement();
  counter.dispose();
};
