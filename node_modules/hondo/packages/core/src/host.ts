import {
  encodeHondoValue,
  type HondoMutationBridge,
  type HondoValue,
} from './bridge.js';

export interface HondoNode {
  readonly id: number;
  readonly type: string;
  readonly isText: boolean;
  parent: HondoNode | null;
  children: HondoNode[];
  textValue: string | null;
}

export type HondoNodeEventPhase = 'capture' | 'target' | 'bubble';

export interface HondoNodeEvent {
  readonly type: string;
  readonly target: HondoNode;
  readonly payload: HondoValue;
  currentTarget: HondoNode | null;
  phase: HondoNodeEventPhase;
  propagationStopped: boolean;
  defaultPrevented: boolean;
  stopPropagation(): void;
  preventDefault(): void;
}

export type HondoNodeEventHandler = (event: HondoNodeEvent) => void;

export interface HondoNodeEventResult {
  defaultPrevented: boolean;
  propagationStopped: boolean;
}

type EventRegistration = {
  type: string;
  capture: boolean;
};

export class HondoHost {
  readonly root: HondoNode = {
    id: 0,
    type: 'root',
    isText: false,
    parent: null,
    children: [],
    textValue: null,
  };

  private nextNodeId = 1;
  private readonly nodes = new Map<number, HondoNode>();
  private readonly eventHandlers = new Map<number, Map<string, HondoNodeEventHandler>>();

  constructor(readonly bridge: HondoMutationBridge) {
    this.nodes.set(this.root.id, this.root);
  }

  createElement(type: string): HondoNode {
    const node = this.createHostNode(type, false, null);
    this.bridge.createElement(node.id, type);
    return node;
  }

  createTextNode(value: string): HondoNode {
    const node = this.createHostNode('#text', true, value);
    this.bridge.createTextNode(node.id, value);
    return node;
  }

  replaceText(node: HondoNode, value: string): void {
    if (!node.isText) throw new TypeError('replaceText requires a Hondo text node');
    if (node.textValue === value) return;

    node.textValue = value;
    this.bridge.replaceText(node.id, value);
  }

  setProperty(node: HondoNode, name: string, value: unknown): void {
    const registration = parseEventProperty(name);
    if (registration) {
      this.setEventHandler(node, registration, value);
      return;
    }

    this.bridge.setProperty(node.id, name, encodeHondoValue(value));
  }

  insertNode(parent: HondoNode, node: HondoNode, anchor?: HondoNode | null): void {
    if (node === parent) throw new Error('A Hondo node cannot contain itself');
    if (anchor === node) throw new Error('A Hondo node cannot be its own insertion anchor');
    if (anchor && anchor.parent !== parent) {
      throw new Error('Hondo insertion anchor must be a child of the target parent');
    }

    if (node.parent) {
      const previousIndex = node.parent.children.indexOf(node);
      if (previousIndex >= 0) node.parent.children.splice(previousIndex, 1);
    }

    const anchorIndex = anchor ? parent.children.indexOf(anchor) : -1;
    const insertionIndex = anchorIndex >= 0 ? anchorIndex : parent.children.length;
    parent.children.splice(insertionIndex, 0, node);
    node.parent = parent;

    this.bridge.insertNode(parent.id, node.id, anchor?.id ?? null);
  }

  removeNode(parent: HondoNode, node: HondoNode): void {
    const index = parent.children.indexOf(node);
    if (index < 0 || node.parent !== parent) {
      throw new Error('Cannot remove a node that is not a child of the supplied parent');
    }

    parent.children.splice(index, 1);
    node.parent = null;
    this.bridge.removeNode(parent.id, node.id);
  }

  isTextNode(node: HondoNode): boolean {
    return node.isText;
  }

  getParentNode(node: HondoNode): HondoNode | undefined {
    return node.parent ?? undefined;
  }

  getFirstChild(node: HondoNode): HondoNode | undefined {
    return node.children[0];
  }

  getNextSibling(node: HondoNode): HondoNode | undefined {
    const parent = node.parent;
    if (!parent) return undefined;

    const index = parent.children.indexOf(node);
    return index >= 0 ? parent.children[index + 1] : undefined;
  }

  getNodeById(id: number): HondoNode | undefined {
    return this.nodes.get(id);
  }

  dispatchNodeEvent(targetId: number, type: string, payload: HondoValue): HondoNodeEventResult {
    const target = this.nodes.get(targetId);
    if (!target) throw new Error(`Unknown Hondo event target: ${targetId}`);
    if (!type) throw new TypeError('Hondo node event type cannot be empty');

    const path: HondoNode[] = [];
    for (let node: HondoNode | null = target; node; node = node.parent) path.push(node);

    const event: HondoNodeEvent = {
      type,
      target,
      payload,
      currentTarget: null,
      phase: 'capture',
      propagationStopped: false,
      defaultPrevented: false,
      stopPropagation() {
        this.propagationStopped = true;
      },
      preventDefault() {
        this.defaultPrevented = true;
      },
    };

    for (let index = path.length - 1; index >= 1; index -= 1) {
      this.invokeNodeHandler(path[index]!, type, true, event, 'capture');
      if (event.propagationStopped) {
        event.currentTarget = null;
        return eventResult(event);
      }
    }

    this.invokeNodeHandler(target, type, true, event, 'target');
    this.invokeNodeHandler(target, type, false, event, 'target');

    if (!event.propagationStopped) {
      for (let index = 1; index < path.length; index += 1) {
        this.invokeNodeHandler(path[index]!, type, false, event, 'bubble');
        if (event.propagationStopped) break;
      }
    }

    event.currentTarget = null;
    return eventResult(event);
  }

  private createHostNode(type: string, isText: boolean, textValue: string | null): HondoNode {
    const node: HondoNode = {
      id: this.nextNodeId++,
      type,
      isText,
      parent: null,
      children: [],
      textValue,
    };
    this.nodes.set(node.id, node);
    return node;
  }

  private setEventHandler(node: HondoNode, registration: EventRegistration, value: unknown): void {
    const key = eventHandlerKey(registration.type, registration.capture);
    if (value == null || value === false) {
      const handlers = this.eventHandlers.get(node.id);
      handlers?.delete(key);
      if (handlers?.size === 0) this.eventHandlers.delete(node.id);
      return;
    }
    if (typeof value !== 'function') {
      throw new TypeError(`${registration.capture ? 'capture ' : ''}${registration.type} handler must be a function`);
    }

    let handlers = this.eventHandlers.get(node.id);
    if (!handlers) {
      handlers = new Map();
      this.eventHandlers.set(node.id, handlers);
    }
    handlers.set(key, value as HondoNodeEventHandler);
  }

  private invokeNodeHandler(
    node: HondoNode,
    type: string,
    capture: boolean,
    event: HondoNodeEvent,
    phase: HondoNodeEventPhase,
  ): void {
    const handler = this.eventHandlers.get(node.id)?.get(eventHandlerKey(type, capture));
    if (!handler) return;
    event.currentTarget = node;
    event.phase = phase;
    handler(event);
  }
}

function parseEventProperty(name: string): EventRegistration | undefined {
  if (!/^on[A-Z]/.test(name)) return undefined;

  let eventName = name.slice(2);
  let capture = false;
  if (eventName.endsWith('Capture')) {
    capture = true;
    eventName = eventName.slice(0, -'Capture'.length);
  }
  if (!eventName) return undefined;

  return {
    type: eventName[0]!.toLowerCase() + eventName.slice(1),
    capture,
  };
}

function eventHandlerKey(type: string, capture: boolean): string {
  return `${type}:${capture ? 'capture' : 'bubble'}`;
}

function eventResult(event: HondoNodeEvent): HondoNodeEventResult {
  return {
    defaultPrevented: event.defaultPrevented,
    propagationStopped: event.propagationStopped,
  };
}

let activeHost: HondoHost | undefined;

export function installHost(host: HondoHost): () => void {
  const previous = activeHost;
  activeHost = host;
  let restored = false;

  return () => {
    if (restored) return;
    restored = true;
    if (activeHost === host) activeHost = previous;
  };
}

export function getHost(): HondoHost {
  if (!activeHost) throw new Error('No Hondo host is installed');
  return activeHost;
}

type HondoNodeEventGlobals = typeof globalThis & {
  __hondoDispatchNodeEvent?: (targetId: number, type: string, payloadJson: string) => boolean;
};

const globals = globalThis as HondoNodeEventGlobals;
if (typeof globals.__hondoDispatchNodeEvent !== 'function') {
  globals.__hondoDispatchNodeEvent = (targetId, type, payloadJson) => {
    const payload = JSON.parse(payloadJson) as HondoValue;
    return getHost().dispatchNodeEvent(targetId, type, payload).defaultPrevented;
  };
}
