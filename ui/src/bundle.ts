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
const [path, setPath] = createSignal('[No Name]');
const [project, setProject] = createSignal('');
const [status, setStatus] = createSignal('');
const [commandOpen, setCommandOpen] = createSignal(false);
const [commandText, setCommandText] = createSignal('');
const [buffers, setBuffers] = createSignal(1);
const [windows, setWindows] = createSignal(1);
const [tabs, setTabs] = createSignal(1);
const [diagnostics, setDiagnostics] = createSignal(0);
const [symbols, setSymbols] = createSignal(0);
type PinView = { id: number; path: string; line: number; column: number; label?: string };
const [references, setReferences] = createSignal(0);
const [pins, setPins] = createSignal<PinView[]>([]);
const [pinSwitcherOpen, setPinSwitcherOpen] = createSignal(false);
const [pinSwitcherIndex, setPinSwitcherIndex] = createSignal(0);
const [terminalWidth, setTerminalWidth] = createSignal(120);
const [terminalHeight, setTerminalHeight] = createSignal(30);
const [projectCollapsed, setProjectCollapsed] = createSignal(false);
const [contextCollapsed, setContextCollapsed] = createSignal(false);
const [contextIndex, setContextIndex] = createSignal(0);
const [focusZone, setFocusZone] = createSignal<'project' | 'editor' | 'context'>('editor');

const contextNames = ['Symbols', 'Diagnostics', 'References', 'Git', 'Quickfix', 'Tests'] as const;
let projectRef: HondoRefHandle | undefined;
let editorRef: HondoRefHandle | undefined;
let contextRef: HondoRefHandle | undefined;

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

function pinsPayload(value: HondoValue): PinView[] {
  if (!Array.isArray(value)) return [];
  const result: PinView[] = [];
  for (const candidate of value) {
    const item = payloadObject(candidate);
    if (!item) continue;
    if (typeof item.id !== 'number' || typeof item.path !== 'string' || typeof item.line !== 'number' || typeof item.column !== 'number') continue;
    result.push({
      id: item.id,
      path: item.path,
      line: item.line,
      column: item.column,
      label: typeof item.label === 'string' ? item.label : undefined,
    });
  }
  return result;
}

function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {
  const value = payloadObject(event.payload);
  if (!value) return undefined;
  return {
    kind: typeof value.kind === 'string' ? value.kind : undefined,
    codepoint: typeof value.codepoint === 'number' ? value.codepoint : undefined,
  };
}

function isCodepoint(event: HondoNodeEvent, expected: string): boolean {
  const key = keyPayload(event);
  return key?.kind === 'codepoint'
    && key.codepoint !== undefined
    && String.fromCodePoint(key.codepoint) === expected;
}

function dirname(value: string): string {
  if (!value || value === '[No Name]') return '';
  const slash = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
  return slash <= 0 ? '' : value.slice(0, slash);
}

function projectLabel(): string {
  return project() || dirname(path()) || '[No Project]';
}

function projectRail(): boolean {
  return projectCollapsed() || terminalWidth() < 72;
}

function contextRail(): boolean {
  return contextCollapsed() || terminalWidth() < 108;
}

function contextSummary(): string {
  switch (contextIndex()) {
    case 0:
      return symbols() === 0 ? 'No symbol result yet' : `${symbols()} symbol${symbols() === 1 ? '' : 's'}`;
    case 1:
      return diagnostics() === 0 ? 'No diagnostics' : `${diagnostics()} diagnostic${diagnostics() === 1 ? '' : 's'}`;
    case 2:
      return references() === 0 ? 'No reference result yet' : `${references()} reference${references() === 1 ? '' : 's'}`;
    case 3:
      return 'Git context surface';
    case 4:
      return 'Quickfix context surface';
    case 5:
      return 'Tests context surface';
    default:
      return '';
  }
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
  if (typeof value.terminalWidth === 'number') setTerminalWidth(value.terminalWidth);
  if (typeof value.terminalHeight === 'number') setTerminalHeight(value.terminalHeight);
  flush();
}

function projectKey(event: HondoNodeEvent): void {
  if (isCodepoint(event, 'c') || keyPayload(event)?.kind === 'enter') {
    setProjectCollapsed(value => !value);
    event.preventDefault();
    flush();
  }
}

function contextKey(event: HondoNodeEvent): void {
  const key = keyPayload(event);
  if (isCodepoint(event, 'c') || key?.kind === 'enter') {
    setContextCollapsed(value => !value);
    event.preventDefault();
    flush();
    return;
  }
  if (!contextRail() && (key?.kind === 'left' || key?.kind === 'right')) {
    const direction = key.kind === 'right' ? 1 : -1;
    const next = (contextIndex() + direction + contextNames.length) % contextNames.length;
    setContextIndex(next);
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

const projectPanel = Column({
  focusable: true,
  ref: handle => {
    projectRef = handle;
  },
  onFocusIn: () => setFocusZone('project'),
  onKey: projectKey,
  get style() {
    return {
      width: projectRail() ? 3 : 24,
      minWidth: projectRail() ? 3 : 24,
      clip: true,
      background: focusZone() === 'project' ? '#151923' : '#0d1118',
      paddingX: projectRail() ? 0 : 1,
    };
  },
  get children() {
    if (projectRail()) {
      return [
        Text({ style: { bold: true, foreground: 'bright-magenta' }, children: ' P ' }),
      ];
    }
    return [
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: 'PROJECT' }),
      Text({ style: { dim: true }, children: () => projectLabel() }),
      Text({ children: () => `Current: ${path()}` }),
      Text({ children: () => `Open buffers: ${buffers()}` }),
      Text({ style: { bold: true, foreground: 'bright-yellow' }, children: () => `PINS (${pins().length})` }),
      ...pins().slice(0, 9).map((pin, index) =>
        Text({
          get children() {
            const name = pin.label || pin.path;
            return `${index + 1} ${name} :${pin.line}`;
          },
          style: { dim: true },
        }),
      ),
      Spacer({ grow: 1 }),
      Text({ style: { dim: true }, children: 'c collapse · Tab focus' }),
    ];
  },
});

const editorPanel = Column({
  style: { grow: 1, minWidth: 24, maxWidth: 110, minHeight: 1, background: '#080b10' },
  children: [
    NativeView({
      nativeType: 'zim.editor',
      nativeProps: { shell: 'hondo', protocol: 3, workspace: 'zen' },
      autoFocus: true,
      ref: handle => {
        editorRef = handle;
      },
      onFocusIn: () => setFocusZone('editor'),
      onNativeState,
      onKey: () => {
        globals.__zimJsKeyEvents = (globals.__zimJsKeyEvents ?? 0) + 1;
      },
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
  get style() {
    return {
      width: contextRail() ? 3 : 28,
      minWidth: contextRail() ? 3 : 28,
      clip: true,
      background: focusZone() === 'context' ? '#151923' : '#0d1118',
      paddingX: contextRail() ? 0 : 1,
    };
  },
  get children() {
    if (contextRail()) {
      return [
        Text({ style: { bold: true, foreground: 'bright-cyan' }, children: ' C ' }),
      ];
    }
    return [
      Text({ style: { bold: true, foreground: 'bright-cyan' }, children: 'CONTEXT' }),
      Row({ style: { gap: 1, clip: true }, children: contextTabs }),
      Text({ style: { foreground: 'bright-white' }, children: () => contextSummary() }),
      Text({ style: { dim: true }, children: () => `File: ${path()}` }),
      Spacer({ grow: 1 }),
      Text({ style: { dim: true }, children: '←/→ surface · c collapse' }),
    ];
  },
});

const pinSwitcher = Popup({
  get x() {
    return Math.max(0, Math.floor((terminalWidth() - 52) / 2));
  },
  get y() {
    return Math.max(1, Math.floor((terminalHeight() - Math.min(14, pins().length + 5)) / 2));
  },
  zIndex: 20,
  style: { width: 52, paddingX: 1, background: '#20242c' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: 'PIN SWITCHER' }),
      Text({ style: { dim: true }, children: '1-9 jump · j/k select · Enter jump · Esc close' }),
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
            return `${index + 1} ${label}${pin.path}:${pin.line}:${pin.column}`;
          },
        }),
      ),
    ],
  }),
});

const disposeRender = render(() =>
  Column({
    style: { minWidth: 1, minHeight: 1, background: '#080b10' },
    children: [
      () => (pinSwitcherOpen() ? pinSwitcher : null),
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
            children: () => `ZEN · ${focusZone().toUpperCase()} · B${buffers()} W${windows()} T${tabs()} `,
          }),
        ],
      }),
      Row({
        style: {
          grow: 1,
          minHeight: 1,
          gap: 1,
          paddingX: 1,
          justify: 'center',
          background: '#080b10',
        },
        children: [projectPanel, editorPanel, contextPanel],
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
          Text({
            style: { dim: true },
            children: () => `${terminalWidth()}×${terminalHeight()} · Tab workspace · `,
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
  projectRef = undefined;
  editorRef = undefined;
  contextRef = undefined;
  disposeRender();
  restoreHost();
};
