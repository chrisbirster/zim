export type HondoValue =
  | null
  | boolean
  | number
  | string
  | HondoValue[]
  | { [key: string]: HondoValue };

export type HondoMutation =
  | { kind: 'createElement'; id: number; type: string }
  | { kind: 'createTextNode'; id: number; value: string }
  | { kind: 'replaceText'; id: number; value: string }
  | { kind: 'setProperty'; id: number; name: string; value: HondoValue }
  | { kind: 'insertNode'; parentId: number; nodeId: number; anchorId: number | null }
  | { kind: 'removeNode'; parentId: number; nodeId: number };

export interface HondoMutationBridge {
  createElement(id: number, type: string): void;
  createTextNode(id: number, value: string): void;
  replaceText(id: number, value: string): void;
  setProperty(id: number, name: string, value: HondoValue): void;
  insertNode(parentId: number, nodeId: number, anchorId: number | null): void;
  removeNode(parentId: number, nodeId: number): void;
}

export type HondoNativeOperation =
  | 'createElement'
  | 'createTextNode'
  | 'replaceText'
  | 'setProperty'
  | 'insertNode'
  | 'removeNode';

export type HondoNativeArgument = string | number | null;

export type HondoNativeHostCall = (
  operation: HondoNativeOperation,
  ...args: HondoNativeArgument[]
) => void;

export function encodeHondoValue(value: unknown): HondoValue {
  if (value == null) return null;

  switch (typeof value) {
    case 'boolean':
    case 'number':
    case 'string':
      return value;
    case 'undefined':
      return null;
    case 'object': {
      if (Array.isArray(value)) return value.map(encodeHondoValue);

      const encoded: { [key: string]: HondoValue } = {};
      for (const [key, item] of Object.entries(value)) {
        encoded[key] = encodeHondoValue(item);
      }
      return encoded;
    }
    default:
      throw new TypeError(`Unsupported Hondo bridge value: ${typeof value}`);
  }
}

function resolveNativeHostCall(): HondoNativeHostCall {
  const hostCall = (globalThis as { __hondoHostCall?: unknown }).__hondoHostCall;
  if (typeof hostCall !== 'function') {
    throw new Error('Hondo native host call is not installed');
  }
  return hostCall as HondoNativeHostCall;
}

export class NativeMutationBridge implements HondoMutationBridge {
  constructor(private readonly hostCall: HondoNativeHostCall = resolveNativeHostCall()) {}

  createElement(id: number, type: string): void {
    this.hostCall('createElement', id, type);
  }

  createTextNode(id: number, value: string): void {
    this.hostCall('createTextNode', id, value);
  }

  replaceText(id: number, value: string): void {
    this.hostCall('replaceText', id, value);
  }

  setProperty(id: number, name: string, value: HondoValue): void {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new TypeError('Hondo property value is not serializable');
    this.hostCall('setProperty', id, name, encoded);
  }

  insertNode(parentId: number, nodeId: number, anchorId: number | null): void {
    this.hostCall('insertNode', parentId, nodeId, anchorId);
  }

  removeNode(parentId: number, nodeId: number): void {
    this.hostCall('removeNode', parentId, nodeId);
  }
}

export class RecordingMutationBridge implements HondoMutationBridge {
  private operations: HondoMutation[] = [];

  take(): HondoMutation[] {
    const operations = this.operations;
    this.operations = [];
    return operations;
  }

  createElement(id: number, type: string): void {
    this.operations.push({ kind: 'createElement', id, type });
  }

  createTextNode(id: number, value: string): void {
    this.operations.push({ kind: 'createTextNode', id, value });
  }

  replaceText(id: number, value: string): void {
    this.operations.push({ kind: 'replaceText', id, value });
  }

  setProperty(id: number, name: string, value: HondoValue): void {
    this.operations.push({ kind: 'setProperty', id, name, value });
  }

  insertNode(parentId: number, nodeId: number, anchorId: number | null): void {
    this.operations.push({ kind: 'insertNode', parentId, nodeId, anchorId });
  }

  removeNode(parentId: number, nodeId: number): void {
    this.operations.push({ kind: 'removeNode', parentId, nodeId });
  }
}
