export type PinView = {
  id: number;
  path: string;
  line: number;
  column: number;
  label?: string;
};

export type NativePopupItem = {
  label: string;
  detail?: string;
};

export type DashboardState = {
  path: string;
  modified: boolean;
  mode: string;
  commandOpen: boolean;
  treeOpen: boolean;
  pinSwitcherOpen: boolean;
  nativePopupOpen: boolean;
};

export function payloadObject(payload: unknown): Record<string, unknown> | undefined {
  if (!payload || Array.isArray(payload) || typeof payload !== 'object') return undefined;
  return payload as Record<string, unknown>;
}

export function pinsPayload(value: unknown): PinView[] {
  if (!Array.isArray(value)) return [];
  const result: PinView[] = [];
  for (const candidate of value) {
    const item = payloadObject(candidate);
    if (!item) continue;
    if (
      typeof item.id !== 'number'
      || typeof item.path !== 'string'
      || typeof item.line !== 'number'
      || typeof item.column !== 'number'
    ) continue;
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

export function nativePopupItemsPayload(value: unknown): NativePopupItem[] {
  if (!Array.isArray(value)) return [];
  const result: NativePopupItem[] = [];
  for (const candidate of value) {
    const item = payloadObject(candidate);
    if (!item || typeof item.label !== 'string') continue;
    result.push({
      label: item.label,
      detail: typeof item.detail === 'string' ? item.detail : undefined,
    });
  }
  return result;
}

export function dashboardVisible(state: DashboardState): boolean {
  return state.path === '[No Name]'
    && !state.modified
    && state.mode === 'NORMAL'
    && !state.commandOpen
    && !state.treeOpen
    && !state.pinSwitcherOpen
    && !state.nativePopupOpen;
}

export function contextSummary(
  index: number,
  symbols: number,
  diagnostics: number,
  references: number,
): string {
  switch (index) {
    case 0:
      return symbols === 0 ? 'No symbol result yet' : `${symbols} symbol${symbols === 1 ? '' : 's'}`;
    case 1:
      return diagnostics === 0 ? 'No diagnostics' : `${diagnostics} diagnostic${diagnostics === 1 ? '' : 's'}`;
    case 2:
      return references === 0 ? 'No reference result yet' : `${references} reference${references === 1 ? '' : 's'}`;
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

export function nextContextIndex(current: number, direction: 1 | -1, count: number): number {
  if (count <= 0) return 0;
  return (current + direction + count) % count;
}
