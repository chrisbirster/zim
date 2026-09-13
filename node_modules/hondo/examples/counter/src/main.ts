import { createSignal } from '@hondo/solid';

export function createCounter() {
  const [count, setCount] = createSignal(0);

  return {
    count,
    increment() {
      setCount(value => value + 1);
    },
  };
}
