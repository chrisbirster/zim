const std = @import("std");

pub const Name = enum {
    number,
    tabstop,
    expandtab,
};

pub const Value = union(enum) {
    boolean: bool,
    integer: u16,
};

pub const Options = struct {
    number: bool = false,
    tabstop: u16 = 4,
    expandtab: bool = true,

    pub fn get(self: *const Options, name: Name) Value {
        return switch (name) {
            .number => .{ .boolean = self.number },
            .tabstop => .{ .integer = self.tabstop },
            .expandtab => .{ .boolean = self.expandtab },
        };
    }

    pub fn set(self: *Options, name: Name, value: Value) !void {
        switch (name) {
            .number => self.number = switch (value) {
                .boolean => |enabled| enabled,
                else => return error.OptionTypeMismatch,
            },
            .tabstop => self.tabstop = switch (value) {
                .integer => |width| blk: {
                    if (width == 0 or width > 32) return error.InvalidOptionValue;
                    break :blk width;
                },
                else => return error.OptionTypeMismatch,
            },
            .expandtab => self.expandtab = switch (value) {
                .boolean => |enabled| enabled,
                else => return error.OptionTypeMismatch,
            },
        }
    }
};

test "options are typed and validate values" {
    var options = Options{};
    try std.testing.expectEqual(@as(u16, 4), options.get(.tabstop).integer);
    try options.set(.tabstop, .{ .integer = 8 });
    try std.testing.expectEqual(@as(u16, 8), options.get(.tabstop).integer);
    try std.testing.expectError(error.OptionTypeMismatch, options.set(.number, .{ .integer = 1 }));
    try std.testing.expectError(error.InvalidOptionValue, options.set(.tabstop, .{ .integer = 0 }));
}
