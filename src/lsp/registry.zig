const std = @import("std");

pub const ServerSpec = struct {
    id: []const u8,
    language_id: []const u8,
    extensions: []const []const u8,
    argv: []const []const u8,
};

const zig_extensions = [_][]const u8{"zig"};
const zls_argv = [_][]const u8{"zls"};

pub const defaults = [_]ServerSpec{
    .{
        .id = "zls",
        .language_id = "zig",
        .extensions = &zig_extensions,
        .argv = &zls_argv,
    },
};

pub fn findByLanguage(language_id: []const u8) ?*const ServerSpec {
    for (&defaults) |*spec| {
        if (std.mem.eql(u8, spec.language_id, language_id)) return spec;
    }
    return null;
}

pub fn findByPath(path: []const u8) ?*const ServerSpec {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    if (dot + 1 >= path.len) return null;
    const extension = path[dot + 1 ..];
    for (&defaults) |*spec| {
        for (spec.extensions) |candidate| {
            if (std.mem.eql(u8, candidate, extension)) return spec;
        }
    }
    return null;
}

test "default registry resolves ZLS for Zig" {
    const spec = findByPath("src/main.zig").?;
    try std.testing.expectEqualStrings("zls", spec.id);
    try std.testing.expectEqualStrings("zig", spec.language_id);
}
