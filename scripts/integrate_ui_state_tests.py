#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)


path = Path("ui/src/bundle.ts")
source = path.read_text()

source = replace_once(
    source,
    "import { flush } from 'solid-js';\n",
    """import { flush } from 'solid-js';
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
""",
    "state helper import",
)

source = replace_once(
    source,
    """type PinView = { id: number; path: string; line: number; column: number; label?: string };
type NativePopupItem = { label: string; detail?: string };

""",
    "",
    "local state types",
)

start = source.find("function payloadObject(payload: HondoValue)")
end = source.find("function keyPayload(event: HondoNodeEvent)")
if start == -1 or end == -1 or end <= start:
    raise SystemExit("missing anchor: payload helper block")
source = source[:start] + source[end:]

source = replace_once(
    source,
    """function dashboardVisible(): boolean {
  return path() === '[No Name]'
    && !modified()
    && mode() === 'NORMAL'
    && !commandOpen()
    && !treeOpen()
    && !pinSwitcherOpen()
    && !nativePopupOpen();
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
""",
    """function dashboardVisible(): boolean {
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
""",
    "dashboard and context helpers",
)

source = replace_once(
    source,
    """  if (key?.kind === 'left' || key?.kind === 'right') {
    const direction = key.kind === 'right' ? 1 : -1;
    const next = (contextIndex() + direction + contextNames.length) % contextNames.length;
    setContextIndex(next);
""",
    """  if (key?.kind === 'left' || key?.kind === 'right') {
    const direction: 1 | -1 = key.kind === 'right' ? 1 : -1;
    setContextIndex(nextContextIndex(contextIndex(), direction, contextNames.length));
""",
    "context navigation",
)

path.write_text(source)
