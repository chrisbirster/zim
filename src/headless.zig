const std = @import("std");
const editor = @import("editor.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, target: ?[]const u8) !u8 {
    var state = try editor.Editor.init(allocator, io, target);
    defer state.deinit();
    try state.loadInitial();
    return 0;
}

test "headless editor startup has no Hondo dependency" {
    try std.testing.expectEqual(
        @as(u8, 0),
        try run(std.testing.allocator, std.testing.io, null),
    );
}
