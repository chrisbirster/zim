const std = @import("std");

pub const Mode = enum {
    normal,
    insert,
};

pub const Position = struct {
    line: usize,
    column: usize,
};

pub const Buffer = struct {
    path: ?[]const u8 = null,
    text: std.ArrayList(u8) = .empty,
    modified: bool = false,
    revision: u64 = 0,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .normal,
    buffer: Buffer,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, target: ?[]const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = .{ .path = target },
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.text.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buffer.text.items;
    }

    pub fn setText(self: *Editor, value: []const u8) !void {
        self.buffer.text.items.len = 0;
        try self.buffer.text.appendSlice(self.allocator, value);
        self.cursor = 0;
        self.buffer.modified = false;
        self.buffer.revision = 0;
    }

    pub fn enterInsert(self: *Editor) void {
        self.mode = .insert;
    }

    pub fn enterNormal(self: *Editor) void {
        self.mode = .normal;
    }

    pub fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch
            std.unicode.utf8Encode(0xfffd, &bytes) catch unreachable;
        try self.insertBytes(bytes[0..len]);
    }

    pub fn insertNewline(self: *Editor) !void {
        try self.insertBytes("\n");
    }

    pub fn backspace(self: *Editor) bool {
        if (self.cursor == 0) return false;
        const previous = previousCodepointStart(self.buffer.text.items, self.cursor);
        const removed = self.cursor - previous;
        const old_len = self.buffer.text.items.len;
        std.mem.copyForwards(
            u8,
            self.buffer.text.items[previous .. old_len - removed],
            self.buffer.text.items[self.cursor..old_len],
        );
        self.buffer.text.items.len = old_len - removed;
        self.cursor = previous;
        self.markChanged();
        return true;
    }

    pub fn moveLeft(self: *Editor) bool {
        if (self.cursor == 0) return false;
        self.cursor = previousCodepointStart(self.buffer.text.items, self.cursor);
        return true;
    }

    pub fn moveRight(self: *Editor) bool {
        if (self.cursor >= self.buffer.text.items.len) return false;
        const first = self.buffer.text.items[self.cursor];
        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
        self.cursor = @min(self.buffer.text.items.len, self.cursor + sequence_len);
        return true;
    }

    pub fn moveUp(self: *Editor) bool {
        return self.moveVertical(-1);
    }

    pub fn moveDown(self: *Editor) bool {
        return self.moveVertical(1);
    }

    pub fn setCursorFromLineColumn(self: *Editor, line_index: usize, byte_column: usize) void {
        const bytes = self.buffer.text.items;
        var start: usize = 0;
        var line: usize = 0;
        while (line < line_index and start < bytes.len) : (line += 1) {
            const end = lineEnd(bytes, start);
            if (end >= bytes.len) {
                start = bytes.len;
                break;
            }
            start = end + 1;
        }
        const end = lineEnd(bytes, start);
        self.cursor = start + @min(byte_column, end - start);
        while (self.cursor > start and self.cursor < bytes.len and isContinuation(bytes[self.cursor])) {
            self.cursor -= 1;
        }
    }

    pub fn cursorPosition(self: *const Editor) Position {
        var line: usize = 1;
        var column: usize = 1;
        for (self.buffer.text.items[0..self.cursor]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else if (!isContinuation(byte)) {
                column += 1;
            }
        }
        return .{ .line = line, .column = column };
    }

    pub fn lineStart(self: *const Editor) usize {
        return lineStartAt(self.buffer.text.items, self.cursor);
    }

    fn insertBytes(self: *Editor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const old_len = self.buffer.text.items.len;
        try self.buffer.text.ensureTotalCapacity(self.allocator, old_len + bytes.len);
        self.buffer.text.items.len = old_len + bytes.len;
        std.mem.copyBackwards(
            u8,
            self.buffer.text.items[self.cursor + bytes.len ..],
            self.buffer.text.items[self.cursor..old_len],
        );
        @memcpy(self.buffer.text.items[self.cursor .. self.cursor + bytes.len], bytes);
        self.cursor += bytes.len;
        self.markChanged();
    }

    fn moveVertical(self: *Editor, direction: i8) bool {
        const bytes = self.buffer.text.items;
        const current_start = lineStartAt(bytes, self.cursor);
        const byte_column = self.cursor - current_start;

        if (direction < 0) {
            if (current_start == 0) return false;
            const previous_end = current_start - 1;
            const previous_start = lineStartAt(bytes, previous_end);
            self.cursor = previous_start + @min(byte_column, previous_end - previous_start);
            return true;
        }

        const current_end = lineEnd(bytes, self.cursor);
        if (current_end >= bytes.len) return false;
        const next_start = current_end + 1;
        const next_end = lineEnd(bytes, next_start);
        self.cursor = next_start + @min(byte_column, next_end - next_start);
        return true;
    }

    fn markChanged(self: *Editor) void {
        self.buffer.modified = true;
        self.buffer.revision += 1;
    }
};

fn previousCodepointStart(bytes: []const u8, cursor: usize) usize {
    var index = cursor - 1;
    while (index > 0 and isContinuation(bytes[index])) index -= 1;
    return index;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn lineStartAt(bytes: []const u8, index: usize) usize {
    var start = @min(index, bytes.len);
    while (start > 0 and bytes[start - 1] != '\n') start -= 1;
    return start;
}

fn lineEnd(bytes: []const u8, index: usize) usize {
    var end = @min(index, bytes.len);
    while (end < bytes.len and bytes[end] != '\n') end += 1;
    return end;
}

test "editor starts in normal mode with an empty buffer" {
    var editor = Editor.init(std.testing.allocator, null);
    defer editor.deinit();
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.buffer.path == null);
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(Position{ .line = 1, .column = 1 }, editor.cursorPosition());
}

test "insert mode edits UTF-8 and backspace removes one codepoint" {
    var editor = Editor.init(std.testing.allocator, "src/main.zig");
    defer editor.deinit();
    editor.enterInsert();
    try editor.insertCodepoint('λ');
    try editor.insertCodepoint('x');
    try std.testing.expectEqualStrings("λx", editor.text());
    try std.testing.expectEqual(Position{ .line = 1, .column = 3 }, editor.cursorPosition());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("λ", editor.text());
    try std.testing.expectEqual(@as(u64, 3), editor.buffer.revision);
}

test "vertical movement preserves the byte column and clamps short lines" {
    var editor = Editor.init(std.testing.allocator, null);
    defer editor.deinit();
    try editor.setText("abcd\nx\n1234");
    editor.setCursorFromLineColumn(0, 3);
    try std.testing.expect(editor.moveDown());
    try std.testing.expectEqual(Position{ .line = 2, .column = 2 }, editor.cursorPosition());
    try std.testing.expect(editor.moveDown());
    try std.testing.expectEqual(Position{ .line = 3, .column = 2 }, editor.cursorPosition());
    try std.testing.expect(editor.moveUp());
    try std.testing.expectEqual(Position{ .line = 2, .column = 2 }, editor.cursorPosition());
}
