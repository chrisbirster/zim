#!/usr/bin/env python3
from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"repair anchor not found in {path}: {old[:80]!r}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# Hondo's pinned overlay renderer currently considers detached overlay nodes.
# Keep Zim overlays attached and collapse them to zero size while hidden so
# dashboard/help/pin popup pixels cannot survive a state transition.
replace(
    "ui/src/bundle.ts",
    """const dashboard = Popup({\n  get x() {\n    return Math.max(2, Math.floor((terminalWidth() - 64) / 2));\n  },\n  get y() {\n    return Math.max(3, Math.floor((terminalHeight() - 20) / 2));\n  },\n  zIndex: 10,\n  style: { width: 64, paddingX: 2, background: '#080b10' },\n""",
    """const dashboard = Popup({\n  get x() {\n    return Math.max(2, Math.floor((terminalWidth() - 64) / 2));\n  },\n  get y() {\n    return Math.max(3, Math.floor((terminalHeight() - 20) / 2));\n  },\n  zIndex: 10,\n  get style() {\n    return dashboardVisible()\n      ? { width: 64, paddingX: 2, background: '#080b10' }\n      : { width: 0, height: 0, paddingX: 0, background: '#080b10' };\n  },\n""",
)
replace(
    "ui/src/bundle.ts",
    """  zIndex: 20,\n  style: { width: 62, paddingX: 1, background: '#20242c' },\n""",
    """  zIndex: 20,\n  get style() {\n    return pinSwitcherOpen()\n      ? { width: 62, paddingX: 1, background: '#20242c' }\n      : { width: 0, height: 0, paddingX: 0, background: '#20242c' };\n  },\n""",
)
replace(
    "ui/src/bundle.ts",
    """  zIndex: 30,\n  style: { width: 58, paddingX: 1, background: '#20242c' },\n""",
    """  zIndex: 30,\n  get style() {\n    return nativePopupOpen()\n      ? { width: 58, paddingX: 1, background: '#20242c' }\n      : { width: 0, height: 0, paddingX: 0, background: '#20242c' };\n  },\n""",
)
replace(
    "ui/src/bundle.ts",
    """    children: [\n      () => (dashboardVisible() ? dashboard : null),\n      () => (nativePopupOpen() ? nativePopup : null),\n      () => (pinSwitcherOpen() ? pinSwitcher : null),\n""",
    """    children: [\n      dashboard,\n      nativePopup,\n      pinSwitcher,\n""",
)

# Real terminals can honor keyboard-disambiguation and send shifted printable
# punctuation as CSI-u. The pinned Hondo decoder only accepts CSI-u Ctrl keys,
# so ':' can become Escape. For v1 keep printable keys in the legacy stream;
# Vim already treats legacy Tab/Ctrl-I equivalently and Zim translates the C0
# control bytes it needs. Mouse and focus reporting stay enabled.
replace(
    "src/tui.zig",
    """    const input_restore = try hondo.terminal.control.inputFeaturesRestoreSequence(init.gpa);\n""",
    """    const input_restore = try compatibleInputFeaturesRestoreSequence(init.gpa);\n""",
)
replace(
    "src/tui.zig",
    """    const input_begin = try hondo.terminal.control.inputFeaturesBeginSequence(init.gpa);\n""",
    """    const input_begin = try compatibleInputFeaturesBeginSequence(init.gpa);\n""",
)
replace(
    "src/tui.zig",
    """        const ex_entry = isExEntryEvent(incoming) and self.editor.mode == .normal;\n        const before_buffer_id = self.editor.currentBufferConst().id;\n        const before = api_observer.capture(self.editor);\n""",
    """        const ex_entry = isExEntryEvent(incoming) and self.editor.mode == .normal;\n        const before_buffer_id = self.editor.currentBufferConst().id;\n        const before_path_hash = optionalPathHash(self.editor.currentPath());\n        const before = api_observer.capture(self.editor);\n""",
)
replace(
    "src/tui.zig",
    """                if (before_buffer_id != self.editor.currentBufferConst().id) {\n""",
    """                if (before_buffer_id != self.editor.currentBufferConst().id or\n                    before_path_hash != optionalPathHash(self.editor.currentPath()))\n                {\n""",
)
replace(
    "src/tui.zig",
    """        if (before_buffer_id != self.editor.currentBufferConst().id) {\n""",
    """        if (before_buffer_id != self.editor.currentBufferConst().id or\n            before_path_hash != optionalPathHash(self.editor.currentPath()))\n        {\n""",
)
replace(
    "src/tui.zig",
    """fn terminalContentHeight(height: usize) usize {\n    return @max(@as(usize, 1), height -| 1);\n}\n\n""",
    """fn terminalContentHeight(height: usize) usize {\n    return @max(@as(usize, 1), height -| 1);\n}\n\nfn compatibleInputFeaturesBeginSequence(allocator: std.mem.Allocator) ![]u8 {\n    return std.mem.concat(allocator, u8, &.{\n        hondo.terminal.control.enable_mouse_buttons,\n        hondo.terminal.control.enable_sgr_mouse,\n        hondo.terminal.control.enable_focus_events,\n    });\n}\n\nfn compatibleInputFeaturesRestoreSequence(allocator: std.mem.Allocator) ![]u8 {\n    return std.mem.concat(allocator, u8, &.{\n        hondo.terminal.control.disable_focus_events,\n        hondo.terminal.control.disable_sgr_mouse,\n        hondo.terminal.control.disable_mouse_buttons,\n    });\n}\n\nfn optionalPathHash(path: ?[]const u8) u64 {\n    const value = path orelse return 0;\n    var hash: u64 = 0xcbf29ce484222325;\n    for (value) |byte| {\n        hash ^= byte;\n        hash *%= 0x100000001b3;\n    }\n    return hash;\n}\n\n""",
)
replace(
    "src/tui.zig",
    """test \"Hondo chrome reacts while editor grammar stays native\" {\n""",
    """test \"v1 input features keep printable punctuation on the legacy path\" {\n    const begin = try compatibleInputFeaturesBeginSequence(std.testing.allocator);\n    defer std.testing.allocator.free(begin);\n    const restore = try compatibleInputFeaturesRestoreSequence(std.testing.allocator);\n    defer std.testing.allocator.free(restore);\n\n    try std.testing.expect(std.mem.indexOf(u8, begin, hondo.terminal.control.enable_keyboard_disambiguation) == null);\n    try std.testing.expect(std.mem.indexOf(u8, begin, hondo.terminal.control.enable_focus_events) != null);\n    try std.testing.expect(std.mem.indexOf(u8, restore, hondo.terminal.control.disable_keyboard_disambiguation) == null);\n}\n\ntest \"Hondo chrome reacts while editor grammar stays native\" {\n""",
)

print("v1 human dogfood repair applied")
