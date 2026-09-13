#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

p = Path("src/editor.zig")
s = p.read_text()

s = replace_once(
    s,
    """            .backspace => self.repeatMotion(.left, self.takeCount()),
            .left => self.repeatMotion(.left, self.takeCount()),
""",
    """            .backspace => self.repeatMotion(.left, self.takeCount()),
            .tab => blk: {
                _ = self.jumpListMove(1);
                break :blk true;
            },
            .left => self.repeatMotion(.left, self.takeCount()),
""",
    "normal Tab jump",
)

s = replace_once(
    s,
    """        const count = self.takeCount();
        return switch (cp) {
""",
    """        const had_count = self.count_prefix != 0;
        const count = self.takeCount();
        return switch (cp) {
""",
    "normal explicit count",
)

s = replace_once(
    s,
    """            'G' => blk: {
                if (count > 1) self.moveToLine(count - 1) else self.moveToLastLine();
                break :blk true;
            },
""",
    """            'G' => blk: {
                if (had_count) self.moveToLine(count - 1) else self.moveToLastLine();
                break :blk true;
            },
""",
    "counted G",
)

line_range = """    fn lineRange(self: *const Editor, at: usize, count: usize) Range {
        const bytes = self.text();
        const start = lineStartAt(bytes, at);
        var end = start;
        for (0..count) |_| {
            const line_end = lineEnd(bytes, end);
            end = if (line_end < bytes.len) line_end + 1 else line_end;
            if (end >= bytes.len) break;
        }
        return .{ .start = start, .end = end, .kind = .linewise };
    }

"""
line_helpers = line_range + """    fn lastLineIndex(self: *const Editor) usize {
        const bytes = self.text();
        if (bytes.len == 0) return 0;
        var probe = bytes.len;
        if (bytes[probe - 1] == '\\n') probe -= 1;
        return positionForOffset(bytes, lineStartAt(bytes, probe)).line - 1;
    }

    fn linewiseRangeToLine(self: *const Editor, target_line: usize) Range {
        const bytes = self.text();
        const current_line = positionForOffset(bytes, self.cursor()).line - 1;
        const first_line = @min(current_line, target_line);
        const last_line = @max(current_line, target_line);
        const start = offsetForLineColumn(bytes, first_line, 0);
        const last_start = offsetForLineColumn(bytes, last_line, 0);
        const last_end = lineEnd(bytes, last_start);
        return .{
            .start = start,
            .end = if (last_end < bytes.len) last_end + 1 else last_end,
            .kind = .linewise,
        };
    }

"""
s = replace_once(s, line_range, line_helpers, "linewise absolute motion helpers")

s = replace_once(
    s,
    """                if (self.pending_g) {
                    self.pending_g = false;
                    if (cp == 'e' or cp == 'E') {
                        const motion_count = self.operator_count * self.takeCount();
                        const range = self.previousEndMotionRange(cp == 'E', motion_count);
                        try self.applyOperator(op, range);
                        break :blk true;
                    }
                    self.resetOperator();
                    break :blk false;
                }
""",
    """                if (self.pending_g) {
                    self.pending_g = false;
                    if (cp == 'g') {
                        const had_motion_count = self.count_prefix != 0 or self.operator_count != 1;
                        const target_count = self.operator_count * self.takeCount();
                        const target_line = if (had_motion_count) target_count - 1 else 0;
                        try self.applyOperator(op, self.linewiseRangeToLine(target_line));
                        break :blk true;
                    }
                    if (cp == 'e' or cp == 'E') {
                        const motion_count = self.operator_count * self.takeCount();
                        const range = self.previousEndMotionRange(cp == 'E', motion_count);
                        try self.applyOperator(op, range);
                        break :blk true;
                    }
                    self.resetOperator();
                    break :blk false;
                }
""",
    "operator gg",
)

s = replace_once(
    s,
    """                const op_char: u21 = switch (op) {
                    .delete => 'd',
                    .change => 'c',
                    .yank => 'y',
                };
                if (cp == op_char) {
                    const range = self.lineRange(self.cursor(), self.operator_count);
                    try self.applyOperator(op, range);
                    break :blk true;
                }
""",
    """                if (cp == 'G') {
                    const had_motion_count = self.count_prefix != 0 or self.operator_count != 1;
                    const target_count = self.operator_count * self.takeCount();
                    const target_line = if (had_motion_count) target_count - 1 else self.lastLineIndex();
                    try self.applyOperator(op, self.linewiseRangeToLine(target_line));
                    break :blk true;
                }
                const op_char: u21 = switch (op) {
                    .delete => 'd',
                    .change => 'c',
                    .yank => 'y',
                };
                if (cp == op_char) {
                    const line_count = self.operator_count * self.takeCount();
                    const range = self.lineRange(self.cursor(), line_count);
                    try self.applyOperator(op, range);
                    break :blk true;
                }
""",
    "operator G and doubled count",
)

anchor = """test \"named numbered yank small-delete and black-hole registers are distinct\" {
"""
new_test = r'''test "v1 absolute G operators counts and Tab jump parity" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();

    try editor.setText("one\ntwo\nthree\nfour\n");
    _ = try editor.handleKey(.{ .codepoint = 'G' });
    try std.testing.expectEqual(@as(usize, 4), editor.cursorPosition().line);
    _ = try editor.handleKey(.{ .codepoint = '1' });
    _ = try editor.handleKey(.{ .codepoint = 'G' });
    try std.testing.expectEqual(@as(usize, 1), editor.cursorPosition().line);
    _ = try editor.handleKey(.{ .codepoint = '3' });
    _ = try editor.handleKey(.{ .codepoint = 'G' });
    try std.testing.expectEqual(@as(usize, 3), editor.cursorPosition().line);

    try editor.setText("one\ntwo\nthree\nfour\n");
    editor.setCursorFromLineColumn(1, 0);
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'G' });
    try std.testing.expectEqualStrings("one\n", editor.text());

    try editor.setText("one\ntwo\nthree\nfour\n");
    editor.setCursorFromLineColumn(2, 0);
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'g' });
    _ = try editor.handleKey(.{ .codepoint = 'g' });
    try std.testing.expectEqualStrings("four\n", editor.text());

    try editor.setText("one\ntwo\nthree\nfour\n");
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = '2' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("three\nfour\n", editor.text());

    try editor.setText("alpha beta alpha");
    _ = try editor.handleKey(.{ .codepoint = '/' });
    for ("beta") |byte| _ = try editor.handleKey(.{ .codepoint = byte });
    _ = try editor.handleKey(.enter);
    try std.testing.expectEqual(@as(usize, 6), editor.cursor());
    _ = try editor.handleKey(.ctrl_o);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor());
    _ = try editor.handleKey(.tab);
    try std.testing.expectEqual(@as(usize, 6), editor.cursor());
}

'''
s = replace_once(s, anchor, new_test + anchor, "absolute motion tests")

p.write_text(s)
