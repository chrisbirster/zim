import { createSignal, flush } from 'solid-js';
import { describe, expect, it } from 'vitest';
import { HondoHost, RecordingMutationBridge, installHost, type HondoNode } from '@hondo/core';
import { Table, Tree, type TreeItem } from './data_controls.js';
import { render } from './renderer.js';

function textContent(node: HondoNode): string {
  if (node.isText) return node.textValue ?? '';
  return node.children.map(textContent).join('');
}

function deepest(node: HondoNode): HondoNode {
  let current = node;
  while (current.children[0]) current = current.children[0];
  return current;
}

function dispatchMouse(
  host: HondoHost,
  target: HondoNode,
  action: 'press' | 'release',
) {
  return host.dispatchNodeEvent(deepest(target).id, 'mouse', {
    x: 0,
    y: 0,
    button: 'left',
    action,
    shift: false,
    alt: false,
    ctrl: false,
  });
}

function mountHost(code: () => HondoNode) {
  const bridge = new RecordingMutationBridge();
  const host = new HondoHost(bridge);
  const restore = installHost(host);
  const dispose = render(code, host.root);
  flush();
  bridge.take();
  return { bridge, host, dispose, restore };
}

describe('Tree', () => {
  it('expands, navigates hierarchy, skips disabled rows, collapses, and activates', () => {
    const items: readonly TreeItem<string>[] = [
      {
        id: 'src',
        value: 'src',
        children: [
          { id: 'app', value: 'app.ts' },
          { id: 'generated', value: 'generated.ts', disabled: true },
        ],
      },
      { id: 'readme', value: 'README.md' },
    ];
    const [selectedId, setSelectedId] = createSignal('src');
    const [expandedIds, setExpandedIds] = createSignal<readonly string[]>([]);
    const activated: string[] = [];
    let tree!: HondoNode;

    const mounted = mountHost(() => {
      tree = Tree({
        items,
        get selectedId() {
          return selectedId();
        },
        get expandedIds() {
          return expandedIds();
        },
        onSelectionChange: id => setSelectedId(id),
        onExpandedChange: ids => setExpandedIds(ids),
        onActivate: id => activated.push(id),
      });
      return tree;
    });

    expect(tree.children.map(textContent)).toEqual(['▸ src', '  README.md']);

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'right' });
    flush();
    expect(expandedIds()).toEqual(['src']);
    expect(tree.children.map(textContent)).toEqual([
      '▾ src',
      '    app.ts',
      '    generated.ts',
      '  README.md',
    ]);

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'right' });
    flush();
    expect(selectedId()).toBe('app');

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'down' });
    flush();
    expect(selectedId()).toBe('readme');

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'enter' });
    expect(activated).toEqual(['readme']);

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'up' });
    flush();
    expect(selectedId()).toBe('app');

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'left' });
    flush();
    expect(selectedId()).toBe('src');

    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'left' });
    flush();
    expect(expandedIds()).toEqual([]);
    expect(tree.children.map(textContent)).toEqual(['▸ src', '  README.md']);

    mounted.dispose();
    mounted.restore();
  });

  it('keeps the selected row inside a controlled viewport', () => {
    const items: readonly TreeItem<string>[] = [
      { id: 'one', value: 'one' },
      { id: 'two', value: 'two' },
      { id: 'three', value: 'three' },
    ];
    const [selectedId, setSelectedId] = createSignal('one');
    let tree!: HondoNode;

    const mounted = mountHost(() => {
      tree = Tree({
        items,
        get selectedId() {
          return selectedId();
        },
        expandedIds: [],
        viewportSize: 2,
        onSelectionChange: id => setSelectedId(id),
      });
      return tree;
    });

    expect(tree.children.map(textContent)).toEqual(['  one', '  two']);
    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'down' });
    flush();
    mounted.host.dispatchNodeEvent(tree.id, 'key', { kind: 'down' });
    flush();
    expect(selectedId()).toBe('three');
    expect(tree.children.map(textContent)).toEqual(['  two', '  three']);

    mounted.dispose();
    mounted.restore();
  });

  it('selects with mouse press, toggles branches on release, and activates leaves', () => {
    const items: readonly TreeItem<string>[] = [
      {
        id: 'src',
        value: 'src',
        children: [{ id: 'app', value: 'app.ts' }],
      },
      { id: 'readme', value: 'README.md' },
    ];
    const [selectedId, setSelectedId] = createSignal('readme');
    const [expandedIds, setExpandedIds] = createSignal<readonly string[]>([]);
    const activated: string[] = [];
    let tree!: HondoNode;

    const mounted = mountHost(() => {
      tree = Tree({
        items,
        get selectedId() {
          return selectedId();
        },
        get expandedIds() {
          return expandedIds();
        },
        onSelectionChange: setSelectedId,
        onExpandedChange: setExpandedIds,
        onActivate: id => activated.push(id),
      });
      return tree;
    });

    dispatchMouse(mounted.host, tree.children[0]!, 'press');
    flush();
    expect(selectedId()).toBe('src');
    dispatchMouse(mounted.host, tree.children[0]!, 'release');
    flush();
    expect(expandedIds()).toEqual(['src']);
    expect(tree.children.map(textContent)).toEqual(['▾ src', '    app.ts', '  README.md']);

    dispatchMouse(mounted.host, tree.children[1]!, 'press');
    flush();
    expect(selectedId()).toBe('app');
    dispatchMouse(mounted.host, tree.children[1]!, 'release');
    expect(activated).toEqual(['app']);

    mounted.dispose();
    mounted.restore();
  });
});

describe('Table', () => {
  it('renders typed columns, scrolls controlled selection, and activates rows', () => {
    const rows = [
      { name: 'alpha', state: 'ready' },
      { name: 'beta', state: 'busy' },
      { name: 'gamma', state: 'done' },
    ];
    const [selected, setSelected] = createSignal(0);
    const activated: string[] = [];
    let table!: HondoNode;

    const mounted = mountHost(() => {
      table = Table({
        rows,
        columns: [
          { key: 'name', header: 'Name', width: 8, renderCell: row => row.name },
          { key: 'state', header: 'State', width: 6, renderCell: row => row.state },
        ],
        get selectedIndex() {
          return selected();
        },
        viewportSize: 2,
        onSelectionChange: index => setSelected(index),
        onActivate: (_index, row) => activated.push(row.name),
      });
      return table;
    });

    expect(table.children).toHaveLength(3);
    expect(table.children[0]?.children.map(textContent)).toEqual(['Name', 'State']);
    expect(table.children[1]?.children.map(textContent)).toEqual(['alpha', 'ready']);
    expect(table.children[2]?.children.map(textContent)).toEqual(['beta', 'busy']);

    mounted.host.dispatchNodeEvent(table.id, 'key', { kind: 'down' });
    flush();
    expect(selected()).toBe(1);

    mounted.host.dispatchNodeEvent(table.id, 'key', { kind: 'down' });
    flush();
    expect(selected()).toBe(2);
    expect(table.children[1]?.children.map(textContent)).toEqual(['beta', 'busy']);
    expect(table.children[2]?.children.map(textContent)).toEqual(['gamma', 'done']);

    mounted.host.dispatchNodeEvent(table.id, 'key', { kind: 'enter' });
    expect(activated).toEqual(['gamma']);

    mounted.dispose();
    mounted.restore();
  });

  it('can omit the header and clamp non-looping selection at the edge', () => {
    const rows = [{ value: 'one' }, { value: 'two' }];
    const [selected, setSelected] = createSignal(1);
    let table!: HondoNode;

    const mounted = mountHost(() => {
      table = Table({
        rows,
        columns: [
          { key: 'value', header: 'Value', width: 8, renderCell: row => row.value },
        ],
        get selectedIndex() {
          return selected();
        },
        showHeader: false,
        onSelectionChange: index => setSelected(index),
      });
      return table;
    });

    expect(table.children).toHaveLength(2);
    mounted.host.dispatchNodeEvent(table.id, 'key', { kind: 'down' });
    flush();
    expect(selected()).toBe(1);

    mounted.dispose();
    mounted.restore();
  });

  it('selects and activates data rows with the mouse while ignoring the header', () => {
    const rows = [{ value: 'one' }, { value: 'two' }];
    const [selected, setSelected] = createSignal(0);
    const activated: string[] = [];
    let table!: HondoNode;

    const mounted = mountHost(() => {
      table = Table({
        rows,
        columns: [
          { key: 'value', header: 'Value', width: 8, renderCell: row => row.value },
        ],
        get selectedIndex() {
          return selected();
        },
        onSelectionChange: setSelected,
        onActivate: (_index, row) => activated.push(row.value),
      });
      return table;
    });

    dispatchMouse(mounted.host, table.children[0]!, 'press');
    flush();
    expect(selected()).toBe(0);

    dispatchMouse(mounted.host, table.children[2]!, 'press');
    flush();
    expect(selected()).toBe(1);
    dispatchMouse(mounted.host, table.children[2]!, 'release');
    expect(activated).toEqual(['two']);

    mounted.dispose();
    mounted.restore();
  });
});
