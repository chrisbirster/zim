const std = @import("std");
const lsp = @import("root.zig");

fn pumpUntil(client: *lsp.Client, target: lsp.ClientState) !void {
    var scratch: [64 * 1024]u8 = undefined;
    var attempts: usize = 0;
    while (client.state != target) : (attempts += 1) {
        if (attempts >= 64) return error.LanguageServerDidNotReachExpectedState;
        const body = try client.receiveOnce(&scratch) orelse return error.LanguageServerExitedEarly;
        defer client.allocator.free(body);
        try client.handleBody(body);
    }
}

fn reportStderr(client: *lsp.Client) void {
    if (client.transport) |*transport| {
        var buffer: [4096]u8 = undefined;
        const count = transport.readError(&buffer) catch return;
        if (count > 0) std.debug.print("ZLS stderr: {s}\n", .{buffer[0..count]});
    }
}

test "real ZLS initializes and shuts down over native stdio transport" {
    var client = lsp.Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();

    try client.spawn(&.{"zls"}, "file:///tmp");
    pumpUntil(&client, .ready) catch |err| {
        reportStderr(&client);
        return err;
    };
    try std.testing.expectEqual(lsp.ClientState.ready, client.state);

    client.requestShutdown() catch |err| {
        reportStderr(&client);
        return err;
    };
    pumpUntil(&client, .exited) catch |err| {
        reportStderr(&client);
        return err;
    };
    try std.testing.expectEqual(lsp.ClientState.exited, client.state);

    if (client.transport) |*transport| {
        const term = try transport.wait();
        const exit_code = switch (term) {
            .exited => |code| code,
            else => return error.UnexpectedZlsTermination,
        };
        try std.testing.expectEqual(@as(u8, 0), exit_code);
    }
}
