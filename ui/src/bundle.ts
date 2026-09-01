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
  Popup,
  Row,
  Spacer,
  Text,
  createSignal,
  render,
  type HondoRefHandle,
} from '@hondo/solid';
import { flush } from 'solid-js';

const host = new HondoHost(new NativeMutationBridge());
const restoreHost = installHost(host);
const [mode, setMode] = createSignal('NORMAL');
const [line, setLine] = createSignal(1);
const [column, setColumn] = createSignal(1);
const [modified, setModified] = createSignal(false);
const [commandOpen, setCommandOpen] = createSignal(false);
let editorRef: HondoRefHandle | undefined;

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
  if (value.commandOpen === true) setCommandOpen(true);
  flush();
}

function dismissCommand(): void {
  setCommandOpen(false);
  flush();
  editorRef?.focus();
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
            style: { dim: true, foreground: 'bright-cyan' },
            children: 'Hondo native editor',
          }),
          Spacer({ grow: 1 }),
          Text({ style: { dim: true }, children: 'Ctrl-C quit  : command' }),
        ],
      }),
      NativeView({
        nativeType: 'zim.editor',
        nativeProps: { shell: 'hondo', protocol: 1 },
        autoFocus: true,
        ref: handle => {
          editorRef = handle;
        },
        onNativeState,
        onKey: () => {
          globals.__zimJsKeyEvents = (globals.__zimJsKeyEvents ?? 0) + 1;
        },
        style: { grow: 1, minHeight: 1, background: '#080b10' },
      }),
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
          Spacer({ grow: 1 }),
          Text({
            children: () => `Ln ${line()}, Col ${column()} `,
          }),
        ],
      }),
      () =>
        commandOpen()
          ? Popup({
              x: 2,
              y: 2,
              zIndex: 100,
              focusable: true,
              autoFocus: true,
              onDismiss: dismissCommand,
              style: {
                width: 48,
                height: 4,
                padding: 1,
                background: '#20242c',
                foreground: 'bright-white',
              },
              children: Column({
                children: [
                  Text({
                    style: { bold: true, foreground: 'bright-magenta' },
                    children: 'COMMAND PALETTE',
                  }),
                  Text({ style: { dim: true }, children: 'Esc closes • editor remains Zig-native' }),
                ],
              }),
            })
          : null,
    ],
  }),
  host.root,
);
flush();

globals.__zimUiDispose = () => {
  disposeRender();
  restoreHost();
};
