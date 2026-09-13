import {
  HondoHost,
  NativeMutationBridge,
  installHost,
  type HondoMutationBridge,
} from '@hondo/core';
import {
  Box,
  Column,
  Input,
  Popup,
  Row,
  ScrollView,
  Table,
  Tabs,
  Text,
  Tree,
  createSignal,
  defineStyles,
  render,
  type TableColumn,
  type TreeItem,
} from '@hondo/solid';
import { flush } from 'solid-js';

interface ProcessRow {
  name: string;
  state: string;
  cpu: string;
}

const files: readonly TreeItem<string>[] = [
  {
    id: 'src',
    value: 'src',
    children: [
      { id: 'app', value: 'app.ts' },
      { id: 'runtime', value: 'runtime.zig' },
    ],
  },
  { id: 'readme', value: 'README.md' },
];

const processes: readonly ProcessRow[] = [
  { name: 'renderer', state: 'running', cpu: '2.1%' },
  { name: 'input', state: 'idle', cpu: '0.2%' },
  { name: 'native-view', state: 'running', cpu: '1.4%' },
  { name: 'diff', state: 'idle', cpu: '0.1%' },
];

const columns: readonly TableColumn<ProcessRow>[] = [
  { key: 'name', header: 'SERVICE', width: 16, renderCell: row => row.name },
  { key: 'state', header: 'STATE', width: 10, renderCell: row => row.state },
  { key: 'cpu', header: 'CPU', width: 6, renderCell: row => row.cpu },
];

const styles = defineStyles({
  shell: { width: 76, height: 24, padding: 1, gap: 1, background: '#0d1117' },
  title: { bold: true, foreground: 'bright-cyan' },
  panel: { paddingX: 1, background: '#161b22' },
  accent: { foreground: 'bright-green' },
  muted: { dim: true },
  popup: { width: 30, padding: 1, background: '#202733', foreground: 'bright-white' },
});

export interface MountedShowcase {
  dispose(): void;
}

export function mountShowcase(
  bridge: HondoMutationBridge = new NativeMutationBridge(),
): MountedShowcase {
  const host = new HondoHost(bridge);
  const restoreHost = installHost(host);

  const [query, setQuery] = createSignal('');
  const [tab, setTab] = createSignal(0);
  const [selectedFile, setSelectedFile] = createSignal('src');
  const [expanded, setExpanded] = createSignal<readonly string[]>(['src']);
  const [selectedProcess, setSelectedProcess] = createSignal(0);
  const [scrollOffset, setScrollOffset] = createSignal(0);

  const logRows = Array.from({ length: 8 }, (_, index) =>
    Text({ children: `event ${index + 1}: terminal pipeline healthy` }),
  );

  const disposeRender = render(() =>
    Column({
      style: styles.shell,
      children: [
        Row({
          style: { width: 74, align: 'center' },
          children: [
            Text({ style: styles.title, children: 'HONDO SHOWCASE' }),
            Text({ style: { ...styles.muted, grow: 1 }, children: '' }),
            Text({ style: styles.accent, children: 'Solid → Zig' }),
          ],
        }),
        Tabs({
          items: ['Overview', 'Runtime', 'NativeView'],
          get selectedIndex() { return tab(); },
          onSelectionChange: index => setTab(index),
          selectedStyle: { bold: true, foreground: 'bright-yellow' },
        }),
        Row({
          style: { width: 74, gap: 2, grow: 1 },
          children: [
            Column({
              style: { ...styles.panel, width: 22, gap: 1 },
              children: [
                Text({ style: { bold: true }, children: 'Workspace' }),
                Input({
                  get value() { return query(); },
                  placeholder: 'filter…',
                  onInput: setQuery,
                  autoFocus: true,
                }),
                Tree({
                  items: files,
                  get selectedId() { return selectedFile(); },
                  get expandedIds() { return expanded(); },
                  onSelectionChange: id => setSelectedFile(id),
                  onExpandedChange: setExpanded,
                  viewportSize: 6,
                }),
              ],
            }),
            Column({
              style: { ...styles.panel, grow: 1, minWidth: 46, gap: 1 },
              children: [
                Text({
                  style: styles.title,
                  get children() { return `Runtime / ${['Overview', 'Runtime', 'NativeView'][tab()]}`; },
                }),
                Table({
                  rows: processes,
                  columns,
                  get selectedIndex() { return selectedProcess(); },
                  onSelectionChange: index => setSelectedProcess(index),
                  viewportSize: 4,
                }),
                Text({ style: { bold: true }, children: 'Events' }),
                ScrollView({
                  children: logRows,
                  get offset() { return scrollOffset(); },
                  viewportSize: 4,
                  onOffsetChange: setScrollOffset,
                  style: { width: 44 },
                }),
              ],
            }),
          ],
        }),
        Text({
          style: styles.muted,
          get children() {
            return `query=${query() || '∅'} • file=${selectedFile()} • arrows/tab/mouse supported`;
          },
        }),
        Popup({
          x: 44,
          y: 2,
          zIndex: 10,
          style: styles.popup,
          children: Text({ children: 'Popup layer • Esc dismissal supported' }),
        }),
      ],
    }),
    host.root,
  );
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
