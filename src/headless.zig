const std = @import("std");
const editor = @import("editor.zig");

pub fn run(allocator: std.mem.Allocator, target: ?[]const u8) u8 {
    var state = editor.Editor.init(allocator, target);
    defer state.deinit();
    return 0;
}

test "headless editor startup has no Hondo dependency" {
    try std.testing.expectEqual(@as(u8, 0), run(std.testing.allocator, "src/main.zig"));
}
