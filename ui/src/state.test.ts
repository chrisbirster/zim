import { describe, expect, it } from 'vitest';
import {
  contextSummary,
  dashboardVisible,
  nativePopupItemsPayload,
  nextContextIndex,
  payloadObject,
  pinsPayload,
} from './state';

describe('dashboardVisible', () => {
  const base = {
    path: '[No Name]',
    modified: false,
    mode: 'NORMAL',
    commandOpen: false,
    treeOpen: false,
    pinSwitcherOpen: false,
    nativePopupOpen: false,
  };

  it('shows only for an idle unnamed normal-mode buffer', () => {
    expect(dashboardVisible(base)).toBe(true);
  });

  it.each([
    ['named file', { path: 'src/main.zig' }],
    ['modified buffer', { modified: true }],
    ['insert mode', { mode: 'INSERT' }],
    ['command line', { commandOpen: true }],
    ['project tree', { treeOpen: true }],
    ['pin switcher', { pinSwitcherOpen: true }],
    ['native popup', { nativePopupOpen: true }],
  ])('hides for %s', (_label, patch) => {
    expect(dashboardVisible({ ...base, ...patch })).toBe(false);
  });
});

describe('native payload parsing', () => {
  it('accepts objects but rejects scalar and array payloads', () => {
    expect(payloadObject({ mode: 'NORMAL' })).toEqual({ mode: 'NORMAL' });
    expect(payloadObject(null)).toBeUndefined();
    expect(payloadObject('NORMAL')).toBeUndefined();
    expect(payloadObject([])).toBeUndefined();
  });

  it('filters malformed pins and preserves optional labels', () => {
    expect(pinsPayload([
      { id: 1, path: 'src/app.zig', line: 12, column: 4, label: 'app' },
      { id: 2, path: 'src/tui.zig', line: 7, column: 1 },
      { id: 'bad', path: 'bad', line: 1, column: 1 },
      { id: 3, path: 42, line: 1, column: 1 },
    ])).toEqual([
      { id: 1, path: 'src/app.zig', line: 12, column: 4, label: 'app' },
      { id: 2, path: 'src/tui.zig', line: 7, column: 1, label: undefined },
    ]);
    expect(pinsPayload('not-an-array')).toEqual([]);
  });

  it('filters malformed popup items', () => {
    expect(nativePopupItemsPayload([
      { label: 'one', detail: 'detail' },
      { label: 'two' },
      { detail: 'missing label' },
      'bad',
    ])).toEqual([
      { label: 'one', detail: 'detail' },
      { label: 'two', detail: undefined },
    ]);
  });
});

describe('context UI', () => {
  it('formats counts with correct singular and plural labels', () => {
    expect(contextSummary(0, 0, 0, 0)).toBe('No symbol result yet');
    expect(contextSummary(0, 1, 0, 0)).toBe('1 symbol');
    expect(contextSummary(0, 2, 0, 0)).toBe('2 symbols');
    expect(contextSummary(1, 0, 1, 0)).toBe('1 diagnostic');
    expect(contextSummary(1, 0, 2, 0)).toBe('2 diagnostics');
    expect(contextSummary(2, 0, 0, 1)).toBe('1 reference');
    expect(contextSummary(2, 0, 0, 2)).toBe('2 references');
  });

  it('covers the fixed context surfaces', () => {
    expect(contextSummary(3, 0, 0, 0)).toBe('Git context surface');
    expect(contextSummary(4, 0, 0, 0)).toBe('Quickfix context surface');
    expect(contextSummary(5, 0, 0, 0)).toBe('Tests context surface');
    expect(contextSummary(99, 0, 0, 0)).toBe('');
  });

  it('wraps context navigation in both directions', () => {
    expect(nextContextIndex(0, -1, 6)).toBe(5);
    expect(nextContextIndex(5, 1, 6)).toBe(0);
    expect(nextContextIndex(2, 1, 6)).toBe(3);
    expect(nextContextIndex(2, -1, 6)).toBe(1);
    expect(nextContextIndex(0, 1, 0)).toBe(0);
  });
});
