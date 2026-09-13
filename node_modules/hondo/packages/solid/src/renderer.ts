import { createRenderer } from '@solidjs/universal';
import { getHost, type HondoNode } from '@hondo/core';

const renderer = createRenderer<HondoNode>({
  createElement(type: string, staticProperties?: Record<string, unknown>) {
    const node = getHost().createElement(type);

    if (staticProperties) {
      for (const [name, value] of Object.entries(staticProperties)) {
        getHost().setProperty(node, name, value);
      }
    }

    return node;
  },
  createTextNode(value: string) {
    return getHost().createTextNode(value);
  },
  replaceText(node: HondoNode, value: string) {
    getHost().replaceText(node, value);
  },
  setProperty(node: HondoNode, name: string, value: unknown) {
    getHost().setProperty(node, name, value);
  },
  insertNode(parent: HondoNode, node: HondoNode, anchor?: HondoNode | null) {
    getHost().insertNode(parent, node, anchor);
  },
  isTextNode(node: HondoNode) {
    return getHost().isTextNode(node);
  },
  removeNode(parent: HondoNode, node: HondoNode) {
    getHost().removeNode(parent, node);
  },
  getParentNode(node: HondoNode) {
    return getHost().getParentNode(node);
  },
  getFirstChild(node: HondoNode) {
    return getHost().getFirstChild(node);
  },
  getNextSibling(node: HondoNode) {
    return getHost().getNextSibling(node);
  },
});

const { render: universalRender } = renderer;

export const {
  effect,
  memo,
  createComponent,
  createElement,
  createTextNode,
  insertNode,
  insert,
  spread,
  setProp,
  mergeProps,
  applyRef,
  ref,
} = renderer;

export function render(code: () => unknown, root: HondoNode): () => void {
  return universalRender(code as () => HondoNode, root);
}

export { createSignal } from 'solid-js';

export const solid2Baseline = {
  core: '2.0.0-rc.4',
  universal: '2.0.0-rc.4',
} as const;
