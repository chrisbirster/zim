#!/usr/bin/env python3
from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"repair anchor not found in {path}: {old[:80]!r}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# Hondo's pinned overlay renderer considers overlay nodes even when Solid has
# detached them from the root tree. Keep Zim overlays attached and collapse
# inactive ones to zero size so dashboard/help/pin pixels cannot survive a
# state transition in a real terminal.
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

# A previous application can leave a terminal in CSI-u / Kitty keyboard mode.
# The Hondo version pinned by Zim intentionally uses legacy printable input and
# does not enable that protocol, but it also does not reset a protocol inherited
# from an earlier process. Explicitly reset it on entry/exit and accept CSI-u as
# a defensive fallback so shifted punctuation such as ':' always reaches Ex.
replace(
    "src/tui.zig",
    """const sequence_wait_ms = 10;\n""",
    """const sequence_wait_ms = 10;\nconst keyboard_protocol_reset = "\\x1b[<u";\n""",
)
replace(
    "src/tui.zig",
    """    const input_restore = try hondo.terminal.control.inputFeaturesRestoreSequence(init.gpa);\n""",
    """    const input_restore = try v1InputFeaturesRestoreSequence(init.gpa);\n""",
)
replace(
    "src/tui.zig",
    """    const input_begin = try hondo.terminal.control.inputFeaturesBeginSequence(init.gpa);\n""",
    """    const input_begin = try v1InputFeaturesBeginSequence(init.gpa);\n""",
)

# Opening a path can reuse the current [No Name] buffer. Buffer ID alone cannot
# tell the TUI that file-open succeeded, so compare the path as well before
# deciding whether the tree should close and keyboard ownership return to editor.
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
    """fn terminalContentHeight(height: usize) usize {\n    return @max(@as(usize, 1), height -| 1);\n}\n\nfn v1InputFeaturesBeginSequence(allocator: std.mem.Allocator) ![]u8 {\n    return std.mem.concat(allocator, u8, &.{\n        keyboard_protocol_reset,\n        hondo.terminal.control.enable_mouse_buttons,\n        hondo.terminal.control.enable_sgr_mouse,\n        hondo.terminal.control.enable_focus_events,\n    });\n}\n\nfn v1InputFeaturesRestoreSequence(allocator: std.mem.Allocator) ![]u8 {\n    return std.mem.concat(allocator, u8, &.{\n        keyboard_protocol_reset,\n        hondo.terminal.control.disable_focus_events,\n        hondo.terminal.control.disable_sgr_mouse,\n        hondo.terminal.control.disable_mouse_buttons,\n    });\n}\n\nfn optionalPathHash(path: ?[]const u8) u64 {\n    const value = path orelse return 0;\n    var hash: u64 = 0xcbf29ce484222325;\n    for (value) |byte| {\n        hash ^= byte;\n        hash *%= 0x100000001b3;\n    }\n    return hash;\n}\n\n""",
)

# Parse enough of the CSI-u keyboard protocol to make Zim robust even if a
# terminal ignores the reset above. This handles shifted printable codepoints
# and maps Ctrl+ASCII back to the legacy C0 values already understood by Zim.
replace(
    "src/tui.zig",
    """            if (len >= 3) {\n                if (hondo.terminal.input.decode(bytes[0..len])) |decoded| {\n                    if (decoded.consumed == len) return decoded.event;\n                }\n            }\n""",
    """            if (len >= 3) {\n                if (decodeCsiUEvent(bytes[0..len])) |event| return event;\n                if (hondo.terminal.input.decode(bytes[0..len])) |decoded| {\n                    if (decoded.consumed == len) return decoded.event;\n                }\n            }\n""",
)
replace(
    "src/tui.zig",
    """fn isExEntryEvent(event: hondo.terminal.input.Event) bool {\n""",
    r'''fn decodeCsiUEvent(bytes: []const u8) ?hondo.terminal.input.Event {
    if (bytes.len < 4 or bytes[0] != 0x1b or bytes[1] != '[' or bytes[bytes.len - 1] != 'u') return null;
    const body = bytes[2 .. bytes.len - 1];
    var fields = std.mem.splitScalar(u8, body, ';');
    const key_field = fields.next() orelse return null;
    const modifier_field = fields.next();
    if (fields.next() != null) return null;

    var key_parts = std.mem.splitScalar(u8, key_field, ':');
    const base_text = key_parts.next() orelse return null;
    const base_u32 = std.fmt.parseInt(u32, base_text, 10) catch return null;
    const shifted_u32 = if (key_parts.next()) |text|
        std.fmt.parseInt(u32, text, 10) catch null
    else
        null;

    var encoded_modifiers: u16 = 1;
    if (modifier_field) |raw| {
        var modifier_parts = std.mem.splitScalar(u8, raw, ':');
        encoded_modifiers = std.fmt.parseInt(u16, modifier_parts.next() orelse return null, 10) catch return null;
        if (encoded_modifiers == 0) return null;
    }
    const modifiers = encoded_modifiers - 1;
    const shift = modifiers & 1 != 0;
    const ctrl = modifiers & 4 != 0;
    const selected_u32 = if (shift) shifted_u32 orelse base_u32 else base_u32;
    const selected = std.math.cast(u21, selected_u32) orelse return null;

    if (ctrl and selected <= 0x7f) {
        const lower: u21 = if (selected >= 'A' and selected <= 'Z') selected + ('a' - 'A') else selected;
        if (lower >= 'a' and lower <= 'z') {
            const control: u21 = lower - 'a' + 1;
            if (control == 0x03) return .{ .key = .ctrl_c };
            return .{ .key = .{ .codepoint = control } };
        }
    }
    return .{ .key = .{ .codepoint = selected } };
}

fn isExEntryEvent(event: hondo.terminal.input.Event) bool {
''',
)

replace(
    "src/tui.zig",
    """test \"Hondo chrome reacts while editor grammar stays native\" {\n""",
    r'''test "v1 input protocol reset and CSI-u fallback preserve Ex punctuation" {
    const begin = try v1InputFeaturesBeginSequence(std.testing.allocator);
    defer std.testing.allocator.free(begin);
    const restore = try v1InputFeaturesRestoreSequence(std.testing.allocator);
    defer std.testing.allocator.free(restore);

    try std.testing.expect(std.mem.indexOf(u8, begin, keyboard_protocol_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, begin, "\x1b[>1u") == null);
    try std.testing.expect(std.mem.indexOf(u8, restore, keyboard_protocol_reset) != null);

    const shifted_colon = decodeCsiUEvent("\x1b[58;2u") orelse return error.TestUnexpectedResult;
    switch (shifted_colon) {
        .key => |key| switch (key) {
            .codepoint => |cp| try std.testing.expectEqual(@as(u21, ':'), cp),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const alternate_colon = decodeCsiUEvent("\x1b[59:58;2u") orelse return error.TestUnexpectedResult;
    switch (alternate_colon) {
        .key => |key| switch (key) {
            .codepoint => |cp| try std.testing.expectEqual(@as(u21, ':'), cp),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Hondo chrome reacts while editor grammar stays native" {
''',
)

print("v1 human dogfood repair applied")
