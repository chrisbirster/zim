import { describe, expect, it } from 'vitest';
import { HondoHost, type HondoNodeEvent } from './host.js';
import { RecordingMutationBridge } from './bridge.js';

describe('HondoHost', () => {
  it('tracks structure and emits ordered mutations', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const box = host.createElement('box');
    const text = host.createTextNode('hello');

    host.insertNode(host.root, box);
    host.insertNode(box, text);

    expect(host.root.children).toEqual([box]);
    expect(box.children).toEqual([text]);
    expect(text.parent).toBe(box);
    expect(bridge.take()).toEqual([
      { kind: 'createElement', id: box.id, type: 'box' },
      { kind: 'createTextNode', id: text.id, value: 'hello' },
      { kind: 'insertNode', parentId: 0, nodeId: box.id, anchorId: null },
      { kind: 'insertNode', parentId: box.id, nodeId: text.id, anchorId: null },
    ]);
  });

  it('deduplicates identical text updates', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const text = host.createTextNode('zero');
    bridge.take();

    host.replaceText(text, 'zero');
    expect(bridge.take()).toEqual([]);

    host.replaceText(text, 'one');
    expect(text.textValue).toBe('one');
    expect(bridge.take()).toEqual([
      { kind: 'replaceText', id: text.id, value: 'one' },
    ]);
  });

  it('moves an existing identity before an anchor', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const a = host.createElement('a');
    const b = host.createElement('b');
    const c = host.createElement('c');
    host.insertNode(host.root, a);
    host.insertNode(host.root, b);
    host.insertNode(host.root, c);
    bridge.take();

    host.insertNode(host.root, c, a);

    expect(host.root.children).toEqual([c, a, b]);
    expect(bridge.take()).toEqual([
      { kind: 'insertNode', parentId: 0, nodeId: c.id, anchorId: a.id },
    ]);
  });

  it('detaches removed nodes without destroying their identity', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const node = host.createElement('box');
    host.insertNode(host.root, node);
    bridge.take();

    host.removeNode(host.root, node);

    expect(node.parent).toBeNull();
    expect(host.root.children).toEqual([]);
    expect(bridge.take()).toEqual([
      { kind: 'removeNode', parentId: 0, nodeId: node.id },
    ]);
  });

  it('keeps event handlers local and dispatches capture target and bubble in order', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const parent = host.createElement('box');
    const child = host.createElement('input');
    host.insertNode(host.root, parent);
    host.insertNode(parent, child);
    bridge.take();

    const calls: string[] = [];
    host.setProperty(parent, 'onKeyCapture', (event: HondoNodeEvent) => {
      calls.push(`parent:${event.phase}`);
    });
    host.setProperty(child, 'onKeyCapture', (event: HondoNodeEvent) => {
      calls.push(`child-capture:${event.phase}`);
    });
    host.setProperty(child, 'onKey', (event: HondoNodeEvent) => {
      calls.push(`child:${event.phase}`);
      event.preventDefault();
    });
    host.setProperty(parent, 'onKey', (event: HondoNodeEvent) => {
      calls.push(`parent:${event.phase}`);
    });

    expect(bridge.take()).toEqual([]);
    expect(host.getNodeById(child.id)).toBe(child);

    const result = host.dispatchNodeEvent(child.id, 'key', { key: 'Enter' });
    expect(calls).toEqual([
      'parent:capture',
      'child-capture:target',
      'child:target',
      'parent:bubble',
    ]);
    expect(result.defaultPrevented).toBe(true);
    expect(result.propagationStopped).toBe(false);
  });

  it('stops propagation before the target when an ancestor capture handler requests it', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const parent = host.createElement('box');
    const child = host.createElement('input');
    host.insertNode(host.root, parent);
    host.insertNode(parent, child);

    const calls: string[] = [];
    host.setProperty(parent, 'onMouseCapture', (event: HondoNodeEvent) => {
      calls.push('parent');
      event.stopPropagation();
    });
    host.setProperty(child, 'onMouse', () => calls.push('child'));

    const result = host.dispatchNodeEvent(child.id, 'mouse', { x: 3, y: 4 });
    expect(calls).toEqual(['parent']);
    expect(result.propagationStopped).toBe(true);
  });

  it('replaces and removes event handlers without emitting native property mutations', () => {
    const bridge = new RecordingMutationBridge();
    const host = new HondoHost(bridge);
    const node = host.createElement('input');
    bridge.take();

    let count = 0;
    host.setProperty(node, 'onFocusIn', () => {
      count += 1;
    });
    host.dispatchNodeEvent(node.id, 'focusIn', null);
    host.setProperty(node, 'onFocusIn', null);
    host.dispatchNodeEvent(node.id, 'focusIn', null);

    expect(count).toBe(1);
    expect(bridge.take()).toEqual([]);
  });
});
