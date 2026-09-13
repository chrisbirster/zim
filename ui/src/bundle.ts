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
import {
  contextSummary as summarizeContext,
  dashboardVisible as shouldShowDashboard,
  nativePopupItemsPayload,
  nextContextIndex,
  payloadObject,
  pinsPayload,
  type NativePopupItem,
  type PinView,
} from './state';

const host = new HondoHost(new NativeMutationBridge());
const restoreHost = installHost(host);
const [mode, setMode] = createSignal('NORMAL');
const [line, setLine] = createSignal(1);
const [column, setColumn] = createSignal(1);
const [modified, setModified] = createSignal(false);
const [path, setPath] = createSignal('[No Name]');
const [project, setProject] = createSignal('.');
const [status, setStatus] = createSignal('');
const [commandOpen, setCommandOpen] = createSignal(false);
const [commandText, setCommandText] = createSignal('');
const [buffers, setBuffers] = createSignal(1);
const [windows, setWindows] = createSignal(1);
const [tabs, setTabs] = createSignal(1);
const [diagnostics, setDiagnostics] = createSignal(0);
const [symbols, setSymbols] = createSignal(0);
const [references, setReferences] = createSignal(0);
const [treeOpen, setTreeOpen] = createSignal(false);
const [treeRefreshNonce, setTreeRefreshNonce] = createSignal(0);
const [zenMode, setZenMode] = createSignal(true);

const [pins, setPins] = createSignal<PinView[]>([]);
const [pinSwitcherOpen, setPinSwitcherOpen] = createSignal(false);
const [pinSwitcherIndex, setPinSwitcherIndex] = createSignal(0);
const [nativePopupOpen, setNativePopupOpen] = createSignal(false);
const [nativePopupKind, setNativePopupKind] = createSignal('plugin');
const [nativePopupTitle, setNativePopupTitle] = createSignal('');
const [nativePopupItems, setNativePopupItems] = createSignal<NativePopupItem[]>([]);
const [nativePopupSelected, setNativePopupSelected] = createSignal(0);
const [terminalWidth, setTerminalWidth] = createSignal(120);
const [terminalHeight, setTerminalHeight] = createSignal(30);
const [contextIndex, setContextIndex] = createSignal(0);
const [focusZone, setFocusZone] = createSignal<'tree' | 'editor' | 'context'>('editor');

const contextNames = ['Symbols', 'Diagnostics', 'References', 'Git', 'Quickfix', 'Tests'] as const;
let treeRef: HondoRefHandle | undefined;
let editorRef: HondoRefHandle | undefined;
let contextRef: HondoRefHandle | undefined;

type ZimGlobals = typeof globalThis & {
  __zimUiDispose?: () => void;
  __zimJsKeyEvents?: number;
  __zimToggleTree?: () => void;
  __zimToggleZen?: () => void;
  __zimFocusEditor?: () => void;
  __zimFocusTree?: () => void;
  __zimCloseTree?: () => void;
};

const globals = globalThis as ZimGlobals;
globals.__zimJsKeyEvents = 0;

function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {
  const value = payloadObject(event.payload);
  if (!value) return undefined;
  return {
    kind: typeof value.kind === 'string' ? value.kind : undefined,
    codepoint: typeof value.codepoint === 'number' ? value.codepoint : undefined,
  };
}

function projectLabel(): string {
  return project() || '.';
}

function dashboardVisible(): boolean {
  return shouldShowDashboard({
    path: path(),
    modified: modified(),
    mode: mode(),
    commandOpen: commandOpen(),
    treeOpen: treeOpen(),
    pinSwitcherOpen: pinSwitcherOpen(),
    nativePopupOpen: nativePopupOpen(),
  });
}

function contextSummary(): string {
  return summarizeContext(contextIndex(), symbols(), diagnostics(), references());
}

function onNativeState(event: HondoNodeEvent): void {
  const value = payloadObject(event.payload);
  if (!value) return;
  if (typeof value.mode === 'string') setMode(value.mode);
  if (typeof value.line === 'number') setLine(value.line);
  if (typeof value.column === 'number') setColumn(value.column);
  if (typeof value.modified === 'boolean') setModified(value.modified);
  if (typeof value.path === 'string') setPath(value.path);
  if (typeof value.project === 'string') setProject(value.project);
  if (typeof value.status === 'string') setStatus(value.status);
  if (typeof value.commandOpen === 'boolean') setCommandOpen(value.commandOpen);
  if (typeof value.commandText === 'string') setCommandText(value.commandText);
  if (typeof value.buffers === 'number') setBuffers(value.buffers);
  if (typeof value.windows === 'number') setWindows(value.windows);
  if (typeof value.tabs === 'number') setTabs(value.tabs);
  if (typeof value.diagnostics === 'number') setDiagnostics(value.diagnostics);
  if (typeof value.symbols === 'number') setSymbols(value.symbols);
  if (typeof value.references === 'number') setReferences(value.references);
  if (value.pins !== undefined) setPins(pinsPayload(value.pins));
  if (typeof value.pinSwitcherOpen === 'boolean') setPinSwitcherOpen(value.pinSwitcherOpen);
  if (typeof value.pinSwitcherIndex === 'number') setPinSwitcherIndex(value.pinSwitcherIndex);
  if (typeof value.popupOpen === 'boolean') setNativePopupOpen(value.popupOpen);
  if (typeof value.popupKind === 'string') setNativePopupKind(value.popupKind);
  if (typeof value.popupTitle === 'string') setNativePopupTitle(value.popupTitle);
  if (value.popupItems !== undefined) setNativePopupItems(nativePopupItemsPayload(value.popupItems));
  if (typeof value.popupSelected === 'number') setNativePopupSelected(value.popupSelected);
  if (typeof value.terminalWidth === 'number') setTerminalWidth(value.terminalWidth);
  if (typeof value.terminalHeight === 'number') setTerminalHeight(value.terminalHeight);
  if (value.treeOpenedFile === true || value.treeClose === true) {
    setTreeOpen(false);
    setFocusZone('editor');
    flush();
    editorRef?.focus();
    return;
  }
  flush();
}

function contextKey(event: HondoNodeEvent): void {
  const key = keyPayload(event);
  if (key?.kind === 'escape') {
    setZenMode(true);
    setFocusZone('editor');
    event.preventDefault();
    flush();
    editorRef?.focus();
    return;
  }
  if (key?.kind === 'left' || key?.kind === 'right') {
    const direction: 1 | -1 = key.kind === 'right' ? 1 : -1;
    setContextIndex(nextContextIndex(contextIndex(), direction, contextNames.length));
    event.preventDefault();
    flush();
  }
}

const contextTabs = contextNames.map((name, index) =>
  Text({
    get style() {
      return {
        dim: index !== contextIndex(),
        bold: index === contextIndex(),
        foreground: index === contextIndex() ? 'bright-cyan' : 'bright-black',
      } as const;
    },
    get children() {
      return index === contextIndex() ? `[${name}]` : name;
    },
  }),
);

const projectTreePanel = Column({
  get style() {
    return {
      width: terminalWidth() < 90 ? 28 : 34,
      minWidth: terminalWidth() < 90 ? 28 : 34,
      minHeight: 1,
      background: '#171722',
      paddingX: 1,
      clip: true,
    };
  },
  children: [
    Text({
      style: { bold: true, foreground: 'bright-cyan' },
      children: () => ` ${projectLabel()} `,
    }),
    NativeView({
      nativeType: 'zim.editor',
      get nativeProps() {
        return { role: 'project-tree', refreshNonce: treeRefreshNonce() };
      },
      autoFocus: true,
      ref: handle => {
        treeRef = handle;
      },
      onFocusIn: () => setFocusZone('tree'),
      onNativeState,
      style: { grow: 1, minHeight: 1, background: '#171722' },
    }),
    Text({
      style: { dim: true },
      children: '<leader>e close · j/k move · Enter open',
    }),
  ],
});

const editorPanel = Column({
  get style() {
    return {
      grow: 1,
      minWidth: 24,
      maxWidth: treeOpen() ? 120 : (zenMode() ? 104 : 116),
      minHeight: 1,
      background: '#080b10',
    };
  },
  children: [
    NativeView({
      nativeType: 'zim.editor',
      nativeProps: { shell: 'hondo', protocol: 4, workspace: 'zen', role: 'editor' },
      autoFocus: true,
      ref: handle => {
        editorRef = handle;
      },
      onFocusIn: () => setFocusZone('editor'),
      onNativeState,
      style: { grow: 1, minHeight: 1, background: '#080b10' },
    }),
  ],
});

const contextPanel = Column({
  focusable: true,
  ref: handle => {
    contextRef = handle;
  },
  onFocusIn: () => setFocusZone('context'),
  onKey: contextKey,
  style: {
    width: 28,
    minWidth: 28,
    clip: true,
    background: '#11151d',
    paddingX: 1,
  },
  children: [
    Text({ style: { bold: true, foreground: 'bright-cyan' }, children: 'CONTEXT' }),
    Row({ style: { gap: 1, clip: true }, children: contextTabs }),
    Text({ style: { foreground: 'bright-white' }, children: () => contextSummary() }),
    Text({ style: { dim: true }, children: () => `File: ${path()}` }),
    Spacer({ grow: 1 }),
    Text({ style: { dim: true }, children: '←/→ surface · Esc zen' }),
  ],
});

const dashboard = Popup({
  get x() {
    return Math.max(2, Math.floor((terminalWidth() - 64) / 2));
  },
  get y() {
    return Math.max(3, Math.floor((terminalHeight() - 20) / 2));
  },
  zIndex: 10,
  style: { width: 64, paddingX: 2, background: '#080b10' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '        ███████╗██╗███╗   ███╗' }),
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '        ╚══███╔╝██║████╗ ████║' }),
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '          ███╔╝ ██║██╔████╔██║' }),
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '         ███╔╝  ██║██║╚██╔╝██║' }),
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '        ███████╗██║██║ ╚═╝ ██║' }),
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: '        ╚══════╝╚═╝╚═╝     ╚═╝' }),
      Text({ children: '' }),
      Text({ style: { bold: true, foreground: 'bright-yellow' }, children: '                 ZIM v1.0.0' }),
      Text({ style: { dim: true }, children: '             your new code overlord.' }),
      Text({ children: '' }),
      Text({ children: '      <leader>e     project explorer' }),
      Text({ children: '      <leader>a     pin current file/location' }),
      Text({ children: '      <leader>h     open pins (Harpoon)' }),
      Text({ children: '      <leader>z     toggle Zen workspace' }),
      Text({ children: '      :help         built-in documentation' }),
      Text({ children: '      :checkhealth  runtime diagnostics' }),
      Text({ children: '      :q            quit' }),
      Text({ children: '' }),
      Text({ style: { dim: true }, children: '             leader is <Space>' }),
    ],
  }),
});

const pinSwitcher = Popup({
  get x() {
    return Math.max(0, Math.floor((terminalWidth() - 62) / 2));
  },
  get y() {
    return Math.max(1, Math.floor((terminalHeight() - Math.min(16, pins().length + 5)) / 2));
  },
  zIndex: 20,
  style: { width: 62, paddingX: 1, background: '#20242c' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: 'HARPOON' }),
      Text({ style: { dim: true }, children: 'j/k select · Enter jump · 1-9 jump · Esc close' }),
      () => pins().map((pin, index) =>
        Text({
          get style() {
            return {
              bold: index === pinSwitcherIndex(),
              reverse: index === pinSwitcherIndex(),
              foreground: index === pinSwitcherIndex() ? 'bright-cyan' : 'bright-white',
            } as const;
          },
          get children() {
            const label = pin.label ? `${pin.label} · ` : '';
            return `${index + 1}  ${label}${pin.path}:${pin.line}:${pin.column}`;
          },
        }),
      ),
    ],
  }),
});

const nativePopup = Popup({
  get x() {
    return Math.max(0, Math.floor((terminalWidth() - 58) / 2));
  },
  get y() {
    return Math.max(1, Math.floor((terminalHeight() - Math.min(16, nativePopupItems().length + 5)) / 2));
  },
  zIndex: 30,
  style: { width: 58, paddingX: 1, background: '#20242c' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-cyan' }, children: () => nativePopupTitle() || nativePopupKind().toUpperCase() }),
      Text({ style: { dim: true }, children: () => nativePopupKind() === 'completion' ? 'j/k select · Enter accept · Esc close' : 'j/k select · Enter choose · Esc close' }),
      () => nativePopupItems().map((item, index) =>
        Text({
          get style() {
            return {
              bold: index === nativePopupSelected(),
              reverse: index === nativePopupSelected(),
              foreground: index === nativePopupSelected() ? 'bright-cyan' : 'bright-white',
            } as const;
          },
          get children() {
            return item.detail ? `${item.label}  ${item.detail}` : item.label;
          },
        }),
      ),
    ],
  }),
});

globals.__zimToggleTree = () => {
  const next = !treeOpen();
  setTreeOpen(next);
  if (next) {
    setTreeRefreshNonce(value => value + 1);
    setFocusZone('tree');
  } else {
    setFocusZone('editor');
  }
  flush();
  if (next) treeRef?.focus();
  else editorRef?.focus();
};

globals.__zimFocusEditor = () => {
  setFocusZone('editor');
  flush();
  editorRef?.focus();
};

globals.__zimFocusTree = () => {
  if (!treeOpen()) return;
  setFocusZone('tree');
  flush();
  treeRef?.focus();
};

globals.__zimCloseTree = () => {
  if (treeOpen()) setTreeOpen(false);
  setFocusZone('editor');
  flush();
  editorRef?.focus();
};

globals.__zimToggleZen = () => {
  const next = !zenMode();
  setZenMode(next);
  setFocusZone(next ? 'editor' : 'context');
  flush();
  if (next) editorRef?.focus();
  else contextRef?.focus();
};

const disposeRender = render(() =>
  Column({
    style: { minWidth: 1, minHeight: 1, background: '#080b10' },
    children: [
      () => (dashboardVisible() ? dashboard : null),
      () => (nativePopupOpen() ? nativePopup : null),
      () => (pinSwitcherOpen() ? pinSwitcher : null),
      Row({
        style: { height: 1, background: '#17172b' },
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
            children: () => `${zenMode() ? 'ZEN' : 'WORKSPACE'} · ${focusZone().toUpperCase()} `,
          }),
        ],
      }),
      Row({
        style: {
          grow: 1,
          minHeight: 1,
          gap: 1,
          justify: 'center',
          background: '#080b10',
        },
        children: [
          () => (treeOpen() ? projectTreePanel : null),
          editorPanel,
          () => (!zenMode() && terminalWidth() >= 105 ? contextPanel : null),
        ],
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
        style: { height: 1, background: '#17172b' },
        children: [
          Text({
            style: { bold: true, reverse: true },
            children: () => ` ${mode()} `,
          }),
          Text({
            style: { foreground: 'bright-cyan' },
            children: () => ` ${projectLabel()} `,
          }),
          Text({
            style: { foreground: 'bright-yellow' },
            children: () => (modified() ? '[+] ' : ''),
          }),
          Text({
            style: { dim: true },
            children: () => (status() ? `${status()} ` : ''),
          }),
          Spacer({ grow: 1 }),
          Text({
            style: { dim: true },
            children: () => `B${buffers()} W${windows()} T${tabs()} `,
          }),
          Text({ children: () => `Ln ${line()}, Col ${column()} ` }),
        ],
      }),
    ],
  }),
  host.root,
);
flush();

globals.__zimUiDispose = () => {
  treeRef = undefined;
  editorRef = undefined;
  contextRef = undefined;
  globals.__zimToggleTree = undefined;
  globals.__zimToggleZen = undefined;
  globals.__zimFocusEditor = undefined;
  globals.__zimFocusTree = undefined;
  globals.__zimCloseTree = undefined;
  disposeRender();
  restoreHost();
};
