const std = @import("std");

pub fn fileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "file://");
    const is_windows_drive = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    if (is_windows_drive) try output.append(allocator, '/');
    for (path) |byte| {
        const normalized = if (byte == '\\') '/' else byte;
        if (isUnreserved(normalized) or normalized == '/' or normalized == ':') {
            try output.append(allocator, normalized);
        } else {
            const hex = "0123456789ABCDEF";
            try output.appendSlice(allocator, &.{ '%', hex[normalized >> 4], hex[normalized & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn filePathAlloc(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedUriScheme;
    var input = uri[prefix.len..];
    if (input.len >= 3 and input[0] == '/' and std.ascii.isAlphabetic(input[1]) and input[2] == ':') {
        input = input[1..];
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '%' and index + 2 < input.len) {
            const high = try hexNibble(input[index + 1]);
            const low = try hexNibble(input[index + 2]);
            try output.append(allocator, (high << 4) | low);
            index += 3;
        } else {
            try output.append(allocator, input[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn hexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidPercentEncoding,
    };
}

test "file URI conversion preserves spaces and platform drives" {
    const posix = try fileUriAlloc(std.testing.allocator, "/tmp/hello world.zig");
    defer std.testing.allocator.free(posix);
    try std.testing.expectEqualStrings("file:///tmp/hello%20world.zig", posix);
    const decoded = try filePathAlloc(std.testing.allocator, posix);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("/tmp/hello world.zig", decoded);

    const windows = try fileUriAlloc(std.testing.allocator, "C:\\work\\demo.zig");
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("file:///C:/work/demo.zig", windows);
}
