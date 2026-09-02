const std = @import("std");
const framing = @import("framing.zig");

pub fn request(
    allocator: std.mem.Allocator,
    id: u64,
    method_name: []const u8,
    params: anytype,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method_name,
        .params = params,
    }, .{});
    defer allocator.free(body);
    return framing.frame(allocator, body);
}

pub fn notification(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: anytype,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = method_name,
        .params = params,
    }, .{});
    defer allocator.free(body);
    return framing.frame(allocator, body);
}

pub fn responseId(value: std.json.Value) ?u64 {
    if (value != .object) return null;
    const raw = value.object.get("id") orelse return null;
    return switch (raw) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

pub fn method(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const raw = value.object.get("method") orelse return null;
    return switch (raw) {
        .string => |text| text,
        else => null,
    };
}

test "request emits framed JSON-RPC" {
    const bytes = try request(std.testing.allocator, 7, "textDocument/hover", .{
        .textDocument = .{ .uri = "file:///tmp/demo.zig" },
        .position = .{ .line = 2, .character = 4 },
    });
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Length:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "textDocument/hover") != null);
}
