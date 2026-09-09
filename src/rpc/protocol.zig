const std = @import("std");
const msgpack = @import("msgpack.zig");

pub const protocol_version: u32 = 1;
pub const api_version: u32 = 1;

pub const Request = struct {
    msgid: u64,
    method: []const u8,
    params: []const msgpack.Value,
};

pub const Response = struct {
    msgid: u64,
    error_value: msgpack.Value,
    result: msgpack.Value,
};

pub const Notification = struct {
    method: []const u8,
    params: []const msgpack.Value,
};

pub const Frame = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

pub const DecodedFrame = struct {
    root: msgpack.Value,
    frame: Frame,
    consumed: usize,

    pub fn deinit(self: *DecodedFrame, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProtocolError = error{
    InvalidFrame,
    InvalidMessageId,
    InvalidMethod,
    InvalidParams,
};

pub fn decodeFrame(allocator: std.mem.Allocator, bytes: []const u8) !DecodedFrame {
    const decoded = try msgpack.decodeOne(allocator, bytes);
    var root = decoded.value;
    errdefer root.deinit(allocator);

    const parts = switch (root) {
        .array => |items| items,
        else => return error.InvalidFrame,
    };
    if (parts.len == 0) return error.InvalidFrame;
    const kind = try unsigned(parts[0]);

    const frame: Frame = switch (kind) {
        0 => blk: {
            if (parts.len != 4) return error.InvalidFrame;
            const params = switch (parts[3]) {
                .array => |items| items,
                else => return error.InvalidParams,
            };
            break :blk .{ .request = .{
                .msgid = try unsigned(parts[1]),
                .method = try string(parts[2]),
                .params = params,
            } };
        },
        1 => blk: {
            if (parts.len != 4) return error.InvalidFrame;
            break :blk .{ .response = .{
                .msgid = try unsigned(parts[1]),
                .error_value = parts[2],
                .result = parts[3],
            } };
        },
        2 => blk: {
            if (parts.len != 3) return error.InvalidFrame;
            const params = switch (parts[2]) {
                .array => |items| items,
                else => return error.InvalidParams,
            };
            break :blk .{ .notification = .{
                .method = try string(parts[1]),
                .params = params,
            } };
        },
        else => return error.InvalidFrame,
    };

    return .{ .root = root, .frame = frame, .consumed = decoded.consumed };
}

pub fn encodeRequest(allocator: std.mem.Allocator, out: *std.ArrayList(u8), msgid: u64, method: []const u8, params: []const msgpack.Value) !void {
    const frame = [_]msgpack.Value{
        .{ .unsigned = 0 },
        .{ .unsigned = msgid },
        .{ .string = method },
        .{ .array = params },
    };
    try msgpack.encode(allocator, out, .{ .array = &frame });
}

pub fn encodeResponse(allocator: std.mem.Allocator, out: *std.ArrayList(u8), msgid: u64, error_name: ?[]const u8, result: msgpack.Value) !void {
    const error_value: msgpack.Value = if (error_name) |name| .{ .string = name } else .nil;
    const frame = [_]msgpack.Value{
        .{ .unsigned = 1 },
        .{ .unsigned = msgid },
        error_value,
        result,
    };
    try msgpack.encode(allocator, out, .{ .array = &frame });
}

pub fn encodeNotification(allocator: std.mem.Allocator, out: *std.ArrayList(u8), method: []const u8, params: []const msgpack.Value) !void {
    const frame = [_]msgpack.Value{
        .{ .unsigned = 2 },
        .{ .string = method },
        .{ .array = params },
    };
    try msgpack.encode(allocator, out, .{ .array = &frame });
}

fn unsigned(value: msgpack.Value) ProtocolError!u64 {
    return switch (value) {
        .unsigned => |number| number,
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidMessageId,
        else => error.InvalidMessageId,
    };
}

fn string(value: msgpack.Value) ProtocolError![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidMethod,
    };
}

test "MessagePack-RPC request response and notification framing" {
    const params = [_]msgpack.Value{ .{ .string = "hello" }, .{ .unsigned = 7 } };
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(std.testing.allocator);

    try encodeRequest(std.testing.allocator, &wire, 42, "zim.ping", &params);
    var request = try decodeFrame(std.testing.allocator, wire.items);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, wire.items.len), request.consumed);
    try std.testing.expectEqual(@as(u64, 42), request.frame.request.msgid);
    try std.testing.expectEqualStrings("zim.ping", request.frame.request.method);
    try std.testing.expectEqualStrings("hello", request.frame.request.params[0].string);

    wire.clearRetainingCapacity();
    try encodeResponse(std.testing.allocator, &wire, 42, null, .{ .string = "pong" });
    var response = try decodeFrame(std.testing.allocator, wire.items);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pong", response.frame.response.result.string);

    wire.clearRetainingCapacity();
    try encodeNotification(std.testing.allocator, &wire, "zim.event", &params);
    var notification = try decodeFrame(std.testing.allocator, wire.items);
    defer notification.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zim.event", notification.frame.notification.method);
}
