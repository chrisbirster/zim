const std = @import("std");
const builtin = @import("builtin");
const host_module = @import("host.zig");
const server = @import("server.zig");

const native = if (builtin.os.tag == .windows)
    @import("transport_windows.zig")
else
    @import("transport_posix.zig");

pub const local_kind = native.local_kind;
pub const LocalEndpoint = native.LocalEndpoint;
pub const sleepOneMs = native.sleepOneMs;

pub fn serveStdio(allocator: std.mem.Allocator, host: *host_module.Host) !void {
    var stream = tryStdio();
    try server.serve(allocator, host, &stream);
}

fn tryStdio() !native.StdioStream {
    return native.StdioStream.init();
}

test "RPC local transport selects a platform-local channel" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("windows-named-pipe", local_kind);
    } else {
        try std.testing.expectEqualStrings("unix-domain-socket", local_kind);
    }
}
