const std = @import("std");
const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows)
    @import("size_windows.zig")
else
    @import("size_posix.zig");

pub const Size = platform.Size;
pub const SizeError = platform.SizeError;
pub const query = platform.query;

pub const Tracker = struct {
    current: Size,

    pub fn init(output_fd: i32) SizeError!Tracker {
        return .{ .current = try query(output_fd) };
    }

    pub fn initKnown(size: Size) Tracker {
        return .{ .current = size };
    }

    pub fn update(self: *Tracker, next: Size) ?Size {
        if (self.current.width == next.width and self.current.height == next.height) return null;
        self.current = next;
        return next;
    }

    pub fn poll(self: *Tracker, output_fd: i32) SizeError!?Size {
        return self.update(try query(output_fd));
    }
};

test "terminal size tracker emits only actual dimension changes" {
    var tracker = Tracker.initKnown(.{ .width = 80, .height = 24 });

    try std.testing.expect(tracker.update(.{ .width = 80, .height = 24 }) == null);
    const resized = tracker.update(.{ .width = 120, .height = 40 }).?;
    try std.testing.expectEqual(@as(usize, 120), resized.width);
    try std.testing.expectEqual(@as(usize, 40), resized.height);
    try std.testing.expect(tracker.update(.{ .width = 120, .height = 40 }) == null);
}
