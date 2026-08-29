const std = @import("std");

pub const Mode = enum {
    normal,
    insert,
};

pub const Buffer = struct {
    path: ?[]const u8 = null,
    modified: bool = false,
    revision: u64 = 0,
};

pub const Editor = struct {
    mode: Mode = .normal,
    buffer: Buffer,

    pub fn init(target: ?[]const u8) Editor {
        return .{
            .buffer = .{ .path = target },
        };
    }

    pub fn enterInsert(self: *Editor) void {
        self.mode = .insert;
    }

    pub fn enterNormal(self: *Editor) void {
        self.mode = .normal;
    }

    pub fn markChanged(self: *Editor) void {
        self.buffer.modified = true;
        self.buffer.revision += 1;
    }
};

test "editor starts in normal mode" {
    const editor = Editor.init(null);
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.buffer.path == null);
    try std.testing.expect(!editor.buffer.modified);
    try std.testing.expectEqual(@as(u64, 0), editor.buffer.revision);
}

test "editor keeps target and changes modes" {
    var editor = Editor.init("src/main.zig");

    try std.testing.expectEqualStrings("src/main.zig", editor.buffer.path.?);

    editor.enterInsert();
    try std.testing.expectEqual(Mode.insert, editor.mode);

    editor.enterNormal();
    try std.testing.expectEqual(Mode.normal, editor.mode);
}

test "buffer changes advance revision" {
    var editor = Editor.init(null);

    editor.markChanged();
    editor.markChanged();

    try std.testing.expect(editor.buffer.modified);
    try std.testing.expectEqual(@as(u64, 2), editor.buffer.revision);
}
