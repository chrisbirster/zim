import { describe, expect, it } from 'vitest';
import {
  NativeMutationBridge,
  type HondoNativeArgument,
  type HondoNativeOperation,
} from './bridge.js';

type NativeCall = [HondoNativeOperation, ...HondoNativeArgument[]];

describe('NativeMutationBridge', () => {
  it('encodes Hondo mutations as primitive native host calls', () => {
    const calls: NativeCall[] = [];
    const bridge = new NativeMutationBridge((operation, ...args) => {
      calls.push([operation, ...args]);
    });

    bridge.createElement(1, 'text');
    bridge.createTextNode(2, 'Count: 0');
    bridge.replaceText(2, 'Count: 1');
    bridge.setProperty(1, 'style', { bold: true, padding: [1, 2] });
    bridge.insertNode(0, 1, null);
    bridge.insertNode(1, 2, null);
    bridge.removeNode(1, 2);

    expect(calls).toEqual([
      ['createElement', 1, 'text'],
      ['createTextNode', 2, 'Count: 0'],
      ['replaceText', 2, 'Count: 1'],
      ['setProperty', 1, 'style', '{"bold":true,"padding":[1,2]}'],
      ['insertNode', 0, 1, null],
      ['insertNode', 1, 2, null],
      ['removeNode', 1, 2],
    ]);
  });

  it('requires the native host function when none is injected', () => {
    expect(() => new NativeMutationBridge()).toThrow(
      'Hondo native host call is not installed',
    );
  });
});
