import {
  HondoHost,
  NativeMutationBridge,
  installHost,
  type HondoNodeEvent,
  type HondoValue,
} from '@hondo/core';
import {
  Column,
  NativeView,
  Row,
  Spacer,
  Text,
  createSignal,
  render,
} from '@hondo/solid';
import { flush } from 'solid-js';

const host = new HondoHost(new NativeMutationBridge());
const restoreHost = installHost(host);
const [mode, setMode] = createSignal('NORMAL');
const [line, setLine] = createSignal(1);
const [column, setColumn] = createSignal(1);
const [modified, setModified] = createSignal(false);
const [path, setPath] = createSignal('[No Name]');
const [status, setStatus] = createSignal('');
const [commandOpen, setCommandOpen] = createSignal(false);
const [commandText, setCommandText] = createSignal('');
const [buffers, setBuffers] = createSignal(1);
const [windows, setWindows] = createSignal(1);
const [tabs, setTabs] = createSignal(1);

type ZimGlobals = typeof globalThis & {
  __zimUiDispose?: () => void;
  __zimJsKeyEvents?: number;
};

const globals = globalThis as ZimGlobals;
globals.__zimJsKeyEvents = 0;

function payloadObject(payload: HondoValue): Record<string, HondoValue> | undefined {
  if (!payload || Array.isArray(payload) || typeof payload !== 'object') return undefined;
  return payload as Record<string, HondoValue>;
}

function onNativeState(event: HondoNodeEvent): void {
  const value = payloadObject(event.payload);
  if (!value) return;
  if (typeof value.mode === 'string') setMode(value.mode);
  if (typeof value.line === 'number') setLine(value.line);
  if (typeof value.column === 'number') setColumn(value.column);
  if (typeof value.modified === 'boolean') setModified(value.modified);
  if (typeof value.path === 'string') setPath(value.path);
  if (typeof value.status === 'string') setStatus(value.status);
  if (typeof value.commandOpen === 'boolean') setCommandOpen(value.commandOpen);
  if (typeof value.commandText === 'string') setCommandText(value.commandText);
  if (typeof value.buffers === 'number') setBuffers(value.buffers);
  if (typeof value.windows === 'number') setWindows(value.windows);
  if (typeof value.tabs === 'number') setTabs(value.tabs);
  flush();
}

const disposeRender = render(() =>
  Column({
    style: { minWidth: 1, minHeight: 1, background: '#080b10' },
    children: [
      Row({
        style: { height: 1, background: '#161b22' },
        children: [
          Text({
            style: { bold: true, foreground: 'bright-magenta' },
            children: ' ZIM ',
          }),
          Text({
            style: { foreground: 'bright-cyan' },
            children: () => path(),
          }),
          Spacer({ grow: 1 }),
          Text({
            style: { dim: true },
            children: () => `B${buffers()} W${windows()} T${tabs()} `,
          }),
        ],
      }),
      NativeView({
        nativeType: 'zim.editor',
        nativeProps: { shell: 'hondo', protocol: 2 },
        autoFocus: true,
        onNativeState,
        onKey: () => {
          globals.__zimJsKeyEvents = (globals.__zimJsKeyEvents ?? 0) + 1;
        },
        style: { grow: 1, minHeight: 1, background: '#080b10' },
      }),
      () =>
        commandOpen()
          ? Row({
              style: { height: 1, background: '#20242c' },
              children: [
                Text({
                  style: { foreground: 'bright-yellow', bold: true },
                  children: () => ` ${commandText()}`,
                }),
              ],
            })
          : null,
      Row({
        style: { height: 1, background: '#161b22' },
        children: [
          Text({
            style: { bold: true, reverse: true },
            children: () => ` ${mode()} `,
          }),
          Text({
            style: { foreground: 'bright-yellow' },
            children: () => (modified() ? ' [+]' : ''),
          }),
          Text({
            style: { dim: true },
            children: () => (status() ? ` ${status()}` : ''),
          }),
          Spacer({ grow: 1 }),
          Text({ children: () => `Ln ${line()}, Col ${column()} ` }),
        ],
      }),
    ],
  }),
  host.root,
);
flush();

globals.__zimUiDispose = () => {
  disposeRender();
  restoreHost();
};
