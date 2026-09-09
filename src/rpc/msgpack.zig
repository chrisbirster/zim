const std = @import("std");

pub const max_depth: usize = 64;
pub const max_container_items: usize = 1 << 20;
pub const max_blob_bytes: usize = 16 * 1024 * 1024;

pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    string: []const u8,
    bytes: []const u8,
    array: []const Value,
    map: []const MapEntry,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |items_const| {
                const items = @constCast(items_const);
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .map => |entries_const| {
                const entries = @constCast(entries_const);
                for (entries) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub const MapEntry = struct {
    key: Value,
    value: Value,
};

pub const DecodeError = error{
    NeedMoreData,
    UnsupportedType,
    MessageTooLarge,
    NestingTooDeep,
    TrailingData,
};

pub fn scanOne(bytes: []const u8) DecodeError!usize {
    var index: usize = 0;
    try scanAt(bytes, &index, 0);
    return index;
}

pub fn decodeOne(allocator: std.mem.Allocator, bytes: []const u8) (DecodeError || std.mem.Allocator.Error)!struct { value: Value, consumed: usize } {
    const consumed = try scanOne(bytes);
    var index: usize = 0;
    const value = try decodeAt(allocator, bytes[0..consumed], &index, 0);
    return .{ .value = value, .consumed = consumed };
}

pub fn decodeExact(allocator: std.mem.Allocator, bytes: []const u8) (DecodeError || std.mem.Allocator.Error)!Value {
    const decoded = try decodeOne(allocator, bytes);
    if (decoded.consumed != bytes.len) {
        var value = decoded.value;
        value.deinit(allocator);
        return error.TrailingData;
    }
    return decoded.value;
}

pub fn encode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .nil => try out.append(allocator, 0xc0),
        .boolean => |flag| try out.append(allocator, if (flag) 0xc3 else 0xc2),
        .unsigned => |number| try encodeUnsigned(allocator, out, number),
        .integer => |number| try encodeInteger(allocator, out, number),
        .string => |string| {
            try encodeStringLength(allocator, out, string.len);
            try out.appendSlice(allocator, string);
        },
        .bytes => |payload| {
            try encodeBinLength(allocator, out, payload.len);
            try out.appendSlice(allocator, payload);
        },
        .array => |items| {
            try encodeArrayLength(allocator, out, items.len);
            for (items) |item| try encode(allocator, out, item);
        },
        .map => |entries| {
            try encodeMapLength(allocator, out, entries.len);
            for (entries) |entry| {
                try encode(allocator, out, entry.key);
                try encode(allocator, out, entry.value);
            }
        },
    }
}

fn scanAt(bytes: []const u8, index: *usize, depth: usize) DecodeError!void {
    if (depth > max_depth) return error.NestingTooDeep;
    try ensure(bytes, index.*, 1);
    const marker = bytes[index.*];
    index.* += 1;

    if (marker <= 0x7f or marker >= 0xe0) return;
    if ((marker & 0xe0) == 0xa0) {
        try skipPayload(bytes, index, marker & 0x1f);
        return;
    }
    if ((marker & 0xf0) == 0x90) {
        try scanItems(bytes, index, marker & 0x0f, depth);
        return;
    }
    if ((marker & 0xf0) == 0x80) {
        try scanMapItems(bytes, index, marker & 0x0f, depth);
        return;
    }

    switch (marker) {
        0xc0, 0xc2, 0xc3 => {},
        0xc4 => try skipPayload(bytes, index, try readU8(bytes, index)),
        0xc5 => try skipPayload(bytes, index, try readU16(bytes, index)),
        0xc6 => try skipPayload(bytes, index, try readU32(bytes, index)),
        0xcc, 0xd0 => try skipPayload(bytes, index, 1),
        0xcd, 0xd1 => try skipPayload(bytes, index, 2),
        0xce, 0xd2 => try skipPayload(bytes, index, 4),
        0xcf, 0xd3 => try skipPayload(bytes, index, 8),
        0xd9 => try skipPayload(bytes, index, try readU8(bytes, index)),
        0xda => try skipPayload(bytes, index, try readU16(bytes, index)),
        0xdb => try skipPayload(bytes, index, try readU32(bytes, index)),
        0xdc => try scanItems(bytes, index, try readU16(bytes, index), depth),
        0xdd => try scanItems(bytes, index, try readU32(bytes, index), depth),
        0xde => try scanMapItems(bytes, index, try readU16(bytes, index), depth),
        0xdf => try scanMapItems(bytes, index, try readU32(bytes, index), depth),
        else => return error.UnsupportedType,
    }
}

fn scanItems(bytes: []const u8, index: *usize, raw_count: anytype, depth: usize) DecodeError!void {
    const count: usize = @intCast(raw_count);
    if (count > max_container_items) return error.MessageTooLarge;
    for (0..count) |_| try scanAt(bytes, index, depth + 1);
}

fn scanMapItems(bytes: []const u8, index: *usize, raw_count: anytype, depth: usize) DecodeError!void {
    const count: usize = @intCast(raw_count);
    if (count > max_container_items) return error.MessageTooLarge;
    for (0..count) |_| {
        try scanAt(bytes, index, depth + 1);
        try scanAt(bytes, index, depth + 1);
    }
}

fn skipPayload(bytes: []const u8, index: *usize, raw_len: anytype) DecodeError!void {
    const len: usize = @intCast(raw_len);
    if (len > max_blob_bytes) return error.MessageTooLarge;
    try ensure(bytes, index.*, len);
    index.* += len;
}

fn decodeAt(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, depth: usize) (DecodeError || std.mem.Allocator.Error)!Value {
    if (depth > max_depth) return error.NestingTooDeep;
    try ensure(bytes, index.*, 1);
    const marker = bytes[index.*];
    index.* += 1;

    if (marker <= 0x7f) return .{ .unsigned = marker };
    if (marker >= 0xe0) return .{ .integer = @as(i8, @bitCast(marker)) };
    if ((marker & 0xe0) == 0xa0) return .{ .string = try readPayload(bytes, index, marker & 0x1f) };
    if ((marker & 0xf0) == 0x90) return decodeArray(allocator, bytes, index, marker & 0x0f, depth);
    if ((marker & 0xf0) == 0x80) return decodeMap(allocator, bytes, index, marker & 0x0f, depth);

    return switch (marker) {
        0xc0 => .nil,
        0xc2 => .{ .boolean = false },
        0xc3 => .{ .boolean = true },
        0xc4 => .{ .bytes = try readPayload(bytes, index, try readU8(bytes, index)) },
        0xc5 => .{ .bytes = try readPayload(bytes, index, try readU16(bytes, index)) },
        0xc6 => .{ .bytes = try readPayload(bytes, index, try readU32(bytes, index)) },
        0xcc => .{ .unsigned = try readU8(bytes, index) },
        0xcd => .{ .unsigned = try readU16(bytes, index) },
        0xce => .{ .unsigned = try readU32(bytes, index) },
        0xcf => .{ .unsigned = try readU64(bytes, index) },
        0xd0 => .{ .integer = @as(i8, @bitCast(try readU8(bytes, index))) },
        0xd1 => .{ .integer = @as(i16, @bitCast(try readU16(bytes, index))) },
        0xd2 => .{ .integer = @as(i32, @bitCast(try readU32(bytes, index))) },
        0xd3 => .{ .integer = @as(i64, @bitCast(try readU64(bytes, index))) },
        0xd9 => .{ .string = try readPayload(bytes, index, try readU8(bytes, index)) },
        0xda => .{ .string = try readPayload(bytes, index, try readU16(bytes, index)) },
        0xdb => .{ .string = try readPayload(bytes, index, try readU32(bytes, index)) },
        0xdc => decodeArray(allocator, bytes, index, try readU16(bytes, index), depth),
        0xdd => decodeArray(allocator, bytes, index, try readU32(bytes, index), depth),
        0xde => decodeMap(allocator, bytes, index, try readU16(bytes, index), depth),
        0xdf => decodeMap(allocator, bytes, index, try readU32(bytes, index), depth),
        else => error.UnsupportedType,
    };
}

fn decodeArray(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, raw_count: anytype, depth: usize) (DecodeError || std.mem.Allocator.Error)!Value {
    const count: usize = @intCast(raw_count);
    if (count > max_container_items) return error.MessageTooLarge;
    const items = try allocator.alloc(Value, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    while (initialized < count) : (initialized += 1) {
        items[initialized] = try decodeAt(allocator, bytes, index, depth + 1);
    }
    return .{ .array = items };
}

fn decodeMap(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, raw_count: anytype, depth: usize) (DecodeError || std.mem.Allocator.Error)!Value {
    const count: usize = @intCast(raw_count);
    if (count > max_container_items) return error.MessageTooLarge;
    const entries = try allocator.alloc(MapEntry, count);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(entries);
    }
    while (initialized < count) : (initialized += 1) {
        entries[initialized].key = try decodeAt(allocator, bytes, index, depth + 1);
        errdefer entries[initialized].key.deinit(allocator);
        entries[initialized].value = try decodeAt(allocator, bytes, index, depth + 1);
    }
    return .{ .map = entries };
}

fn readPayload(bytes: []const u8, index: *usize, raw_len: anytype) DecodeError![]const u8 {
    const len: usize = @intCast(raw_len);
    if (len > max_blob_bytes) return error.MessageTooLarge;
    try ensure(bytes, index.*, len);
    const result = bytes[index.* .. index.* + len];
    index.* += len;
    return result;
}

fn ensure(bytes: []const u8, index: usize, count: usize) DecodeError!void {
    if (index > bytes.len or count > bytes.len - index) return error.NeedMoreData;
}

fn readU8(bytes: []const u8, index: *usize) DecodeError!u8 {
    try ensure(bytes, index.*, 1);
    const value = bytes[index.*];
    index.* += 1;
    return value;
}

fn readU16(bytes: []const u8, index: *usize) DecodeError!u16 {
    try ensure(bytes, index.*, 2);
    const value = (@as(u16, bytes[index.*]) << 8) | bytes[index.* + 1];
    index.* += 2;
    return value;
}

fn readU32(bytes: []const u8, index: *usize) DecodeError!u32 {
    try ensure(bytes, index.*, 4);
    const value = (@as(u32, bytes[index.*]) << 24) |
        (@as(u32, bytes[index.* + 1]) << 16) |
        (@as(u32, bytes[index.* + 2]) << 8) |
        bytes[index.* + 3];
    index.* += 4;
    return value;
}

fn readU64(bytes: []const u8, index: *usize) DecodeError!u64 {
    try ensure(bytes, index.*, 8);
    var value: u64 = 0;
    for (bytes[index.* .. index.* + 8]) |byte| value = (value << 8) | byte;
    index.* += 8;
    return value;
}

fn encodeUnsigned(allocator: std.mem.Allocator, out: *std.ArrayList(u8), number: u64) !void {
    if (number <= 0x7f) return out.append(allocator, @intCast(number));
    if (number <= std.math.maxInt(u8)) {
        try out.append(allocator, 0xcc);
        return out.append(allocator, @intCast(number));
    }
    if (number <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xcd);
        return appendU16(allocator, out, @intCast(number));
    }
    if (number <= std.math.maxInt(u32)) {
        try out.append(allocator, 0xce);
        return appendU32(allocator, out, @intCast(number));
    }
    try out.append(allocator, 0xcf);
    try appendU64(allocator, out, number);
}

fn encodeInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), number: i64) !void {
    if (number >= 0) return encodeUnsigned(allocator, out, @intCast(number));
    if (number >= -32) return out.append(allocator, @bitCast(@as(i8, @intCast(number))));
    if (number >= std.math.minInt(i8)) {
        try out.append(allocator, 0xd0);
        return out.append(allocator, @bitCast(@as(i8, @intCast(number))));
    }
    if (number >= std.math.minInt(i16)) {
        try out.append(allocator, 0xd1);
        return appendU16(allocator, out, @bitCast(@as(i16, @intCast(number))));
    }
    if (number >= std.math.minInt(i32)) {
        try out.append(allocator, 0xd2);
        return appendU32(allocator, out, @bitCast(@as(i32, @intCast(number))));
    }
    try out.append(allocator, 0xd3);
    try appendU64(allocator, out, @bitCast(number));
}

fn encodeStringLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), len: usize) !void {
    if (len > max_blob_bytes) return error.MessageTooLarge;
    if (len <= 31) return out.append(allocator, 0xa0 | @as(u8, @intCast(len)));
    if (len <= std.math.maxInt(u8)) {
        try out.append(allocator, 0xd9);
        return out.append(allocator, @intCast(len));
    }
    if (len <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xda);
        return appendU16(allocator, out, @intCast(len));
    }
    try out.append(allocator, 0xdb);
    try appendU32(allocator, out, @intCast(len));
}

fn encodeBinLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), len: usize) !void {
    if (len > max_blob_bytes) return error.MessageTooLarge;
    if (len <= std.math.maxInt(u8)) {
        try out.append(allocator, 0xc4);
        return out.append(allocator, @intCast(len));
    }
    if (len <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xc5);
        return appendU16(allocator, out, @intCast(len));
    }
    try out.append(allocator, 0xc6);
    try appendU32(allocator, out, @intCast(len));
}

fn encodeArrayLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), len: usize) !void {
    if (len > max_container_items) return error.MessageTooLarge;
    if (len <= 15) return out.append(allocator, 0x90 | @as(u8, @intCast(len)));
    if (len <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xdc);
        return appendU16(allocator, out, @intCast(len));
    }
    try out.append(allocator, 0xdd);
    try appendU32(allocator, out, @intCast(len));
}

fn encodeMapLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), len: usize) !void {
    if (len > max_container_items) return error.MessageTooLarge;
    if (len <= 15) return out.append(allocator, 0x80 | @as(u8, @intCast(len)));
    if (len <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xde);
        return appendU16(allocator, out, @intCast(len));
    }
    try out.append(allocator, 0xdf);
    try appendU32(allocator, out, @intCast(len));
}

fn appendU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @truncate(value >> 8));
    try out.append(allocator, @truncate(value));
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @truncate(value >> 24));
    try out.append(allocator, @truncate(value >> 16));
    try out.append(allocator, @truncate(value >> 8));
    try out.append(allocator, @truncate(value));
}

fn appendU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    try out.append(allocator, @truncate(value >> 56));
    try out.append(allocator, @truncate(value >> 48));
    try out.append(allocator, @truncate(value >> 40));
    try out.append(allocator, @truncate(value >> 32));
    try out.append(allocator, @truncate(value >> 24));
    try out.append(allocator, @truncate(value >> 16));
    try out.append(allocator, @truncate(value >> 8));
    try out.append(allocator, @truncate(value));
}

test "MessagePack round trips the RPC subset" {
    const nested = [_]Value{
        .{ .string = "zim" },
        .{ .unsigned = 9001 },
        .{ .integer = -42 },
        .{ .boolean = true },
        .nil,
    };
    const entries = [_]MapEntry{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "zim" } },
        .{ .key = .{ .string = "values" }, .value = .{ .array = &nested } },
    };
    const original = Value{ .map = &entries };

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try encode(std.testing.allocator, &encoded, original);
    try std.testing.expectEqual(encoded.items.len, try scanOne(encoded.items));

    var decoded = try decodeExact(std.testing.allocator, encoded.items);
    defer decoded.deinit(std.testing.allocator);
    const map = decoded.map;
    try std.testing.expectEqual(@as(usize, 2), map.len);
    try std.testing.expectEqualStrings("name", map[0].key.string);
    try std.testing.expectEqualStrings("zim", map[0].value.string);
    try std.testing.expectEqual(@as(u64, 9001), map[1].value.array[1].unsigned);
    try std.testing.expectEqual(@as(i64, -42), map[1].value.array[2].integer);
}

test "MessagePack scanner distinguishes incomplete frames" {
    try std.testing.expectError(error.NeedMoreData, scanOne(&.{ 0x92, 0xa3, 'z', 'i' }));
    try std.testing.expectEqual(@as(usize, 6), try scanOne(&.{ 0x92, 0xa3, 'z', 'i', 'm', 0xc0 }));
}
