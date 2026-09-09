const std = @import("std");
const host_module = @import("host.zig");
const msgpack = @import("msgpack.zig");
const protocol = @import("protocol.zig");

pub const max_pending_bytes: usize = 32 * 1024 * 1024;

pub fn processOne(allocator: std.mem.Allocator, host: *host_module.Host, input: []const u8, output: *std.ArrayList(u8)) !usize {
    var decoded = try protocol.decodeFrame(allocator, input);
    defer decoded.deinit(allocator);
    try host.handleFrame(decoded.frame, output);
    if (host.queuedBytes().len != 0) {
        try output.appendSlice(allocator, host.queuedBytes());
        host.clearQueued();
    }
    return decoded.consumed;
}

pub fn processAvailable(allocator: std.mem.Allocator, host: *host_module.Host, input: []const u8, output: *std.ArrayList(u8)) !usize {
    var consumed: usize = 0;
    while (consumed < input.len) {
        const used = processOne(allocator, host, input[consumed..], output) catch |err| switch (err) {
            error.NeedMoreData => break,
            else => return err,
        };
        consumed += used;
    }
    return consumed;
}

pub fn serve(allocator: std.mem.Allocator, host: *host_module.Host, stream: anytype) !void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var scratch: [8192]u8 = undefined;

    while (true) {
        const count = try stream.read(&scratch);
        if (count == 0) {
            if (pending.items.len != 0) return error.TruncatedRpcFrame;
            return;
        }
        if (pending.items.len + count > max_pending_bytes) return error.RpcFrameTooLarge;
        try pending.appendSlice(allocator, scratch[0..count]);

        output.clearRetainingCapacity();
        const consumed = try processAvailable(allocator, host, pending.items, &output);
        if (output.items.len != 0) try stream.writeAll(output.items);
        if (consumed != 0) {
            const remaining = pending.items.len - consumed;
            if (remaining != 0) std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[consumed..]);
            pending.items.len = remaining;
        }
    }
}

const MemoryStream = struct {
    input: []const u8,
    cursor: usize = 0,
    output: std.ArrayList(u8) = .empty,

    fn read(self: *MemoryStream, buffer: []u8) !usize {
        if (self.cursor == self.input.len) return 0;
        const count = @min(buffer.len, self.input.len - self.cursor);
        @memcpy(buffer[0..count], self.input[self.cursor .. self.cursor + count]);
        self.cursor += count;
        return count;
    }

    fn writeAll(self: *MemoryStream, bytes: []const u8) !void {
        try self.output.appendSlice(std.testing.allocator, bytes);
    }

    fn deinit(self: *MemoryStream) void {
        self.output.deinit(std.testing.allocator);
    }
};

test "headless RPC stream processes concatenated request frames" {
    const api_module = @import("../api.zig");
    const editor_module = @import("../editor.zig");
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var host = host_module.Host.init(std.testing.allocator, &api, &editor);
    defer host.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    const handshake = [_]msgpack.Value{ .{ .unsigned = protocol.protocol_version }, .{ .unsigned = protocol.api_version } };
    try protocol.encodeRequest(std.testing.allocator, &input, 1, "zim.handshake", &handshake);
    try protocol.encodeRequest(std.testing.allocator, &input, 2, "zim.buffer.current", &.{});

    var stream = MemoryStream{ .input = input.items };
    defer stream.deinit();
    try serve(std.testing.allocator, &host, &stream);

    var first = try protocol.decodeFrame(std.testing.allocator, stream.output.items);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), first.frame.response.msgid);
    var second = try protocol.decodeFrame(std.testing.allocator, stream.output.items[first.consumed..]);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), second.frame.response.msgid);
    try std.testing.expect(second.frame.response.result == .unsigned);
}
