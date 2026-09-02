const std = @import("std");
const types = @import("types.zig");

pub const OwnedLocation = struct {
    uri: []u8,
    range: types.Range,

    pub fn deinit(self: *OwnedLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.* = undefined;
    }
};

pub const LocationList = struct {
    allocator: std.mem.Allocator,
    items: []OwnedLocation,

    pub fn deinit(self: *LocationList) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const OwnedSymbol = struct {
    name: []u8,
    kind: u32,
    uri: []u8,
    range: types.Range,

    pub fn deinit(self: *OwnedSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.uri);
        self.* = undefined;
    }
};

pub const SymbolList = struct {
    allocator: std.mem.Allocator,
    items: []OwnedSymbol,

    pub fn deinit(self: *SymbolList) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn parseLocations(allocator: std.mem.Allocator, body: []const u8) !LocationList {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return emptyLocations(allocator);
    var output: std.ArrayList(OwnedLocation) = .empty;
    errdefer {
        for (output.items) |*item| item.deinit(allocator);
        output.deinit(allocator);
    }
    switch (result) {
        .null => {},
        .object => try appendLocation(allocator, &output, result),
        .array => |array| for (array.items) |value| try appendLocation(allocator, &output, value),
        else => return error.InvalidLocationResponse,
    }
    return .{ .allocator = allocator, .items = try output.toOwnedSlice(allocator) };
}

pub fn parseHoverText(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return null;
    if (result == .null) return null;
    const contents = switch (result) {
        .object => |object| object.get("contents") orelse return null,
        else => return null,
    };
    return extractMarkupText(allocator, contents);
}

pub fn parseSignatureLabel(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const signatures = result.object.get("signatures") orelse return null;
    if (signatures != .array or signatures.array.items.len == 0) return null;
    const first = signatures.array.items[0];
    if (first != .object) return null;
    const label = first.object.get("label") orelse return null;
    if (label != .string) return null;
    return allocator.dupe(u8, label.string);
}

pub fn parseSymbols(allocator: std.mem.Allocator, body: []const u8, default_uri: []const u8) !SymbolList {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return emptySymbols(allocator);
    if (result == .null) return emptySymbols(allocator);
    if (result != .array) return error.InvalidSymbolResponse;

    var output: std.ArrayList(OwnedSymbol) = .empty;
    errdefer {
        for (output.items) |*item| item.deinit(allocator);
        output.deinit(allocator);
    }
    for (result.array.items) |value| try appendSymbolRecursive(allocator, &output, value, default_uri);
    return .{ .allocator = allocator, .items = try output.toOwnedSlice(allocator) };
}

fn appendLocation(allocator: std.mem.Allocator, output: *std.ArrayList(OwnedLocation), value: std.json.Value) !void {
    if (value != .object) return error.InvalidLocationResponse;
    const uri_value = value.object.get("uri") orelse return error.InvalidLocationResponse;
    const range_value = value.object.get("range") orelse return error.InvalidLocationResponse;
    if (uri_value != .string) return error.InvalidLocationResponse;
    try output.append(allocator, .{
        .uri = try allocator.dupe(u8, uri_value.string),
        .range = try parseRange(range_value),
    });
}

fn appendSymbolRecursive(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(OwnedSymbol),
    value: std.json.Value,
    default_uri: []const u8,
) !void {
    if (value != .object) return;
    const name_value = value.object.get("name") orelse return;
    const kind_value = value.object.get("kind") orelse return;
    if (name_value != .string or kind_value != .integer or kind_value.integer < 0) return;

    var uri = default_uri;
    var range_value: ?std.json.Value = value.object.get("range");
    if (value.object.get("location")) |location| {
        if (location == .object) {
            if (location.object.get("uri")) |uri_value| if (uri_value == .string) uri = uri_value.string;
            range_value = location.object.get("range");
        }
    }
    if (range_value) |range| {
        try output.append(allocator, .{
            .name = try allocator.dupe(u8, name_value.string),
            .kind = @intCast(kind_value.integer),
            .uri = try allocator.dupe(u8, uri),
            .range = try parseRange(range),
        });
    }

    if (value.object.get("children")) |children| {
        if (children == .array) for (children.array.items) |child| try appendSymbolRecursive(allocator, output, child, default_uri);
    }
}

fn parseRange(value: std.json.Value) !types.Range {
    if (value != .object) return error.InvalidRange;
    return .{
        .start = try parsePosition(value.object.get("start") orelse return error.InvalidRange),
        .end = try parsePosition(value.object.get("end") orelse return error.InvalidRange),
    };
}

fn parsePosition(value: std.json.Value) !types.Position {
    if (value != .object) return error.InvalidPosition;
    const line = value.object.get("line") orelse return error.InvalidPosition;
    const character = value.object.get("character") orelse return error.InvalidPosition;
    if (line != .integer or character != .integer or line.integer < 0 or character.integer < 0) return error.InvalidPosition;
    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

fn extractMarkupText(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        .object => |object| blk: {
            const raw = object.get("value") orelse break :blk null;
            if (raw != .string) break :blk null;
            break :blk try allocator.dupe(u8, raw.string);
        },
        .array => |array| blk: {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            errdefer writer.deinit();
            for (array.items) |item| {
                const part = try extractMarkupText(allocator, item) orelse continue;
                defer allocator.free(part);
                if (writer.written().len > 0) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(part);
            }
            break :blk try writer.toOwnedSlice();
        },
        else => null,
    };
}

fn emptyLocations(allocator: std.mem.Allocator) !LocationList {
    return .{ .allocator = allocator, .items = try allocator.alloc(OwnedLocation, 0) };
}

fn emptySymbols(allocator: std.mem.Allocator) !SymbolList {
    return .{ .allocator = allocator, .items = try allocator.alloc(OwnedSymbol, 0) };
}

test "response parsers handle hover locations signatures and nested symbols" {
    var locations = try parseLocations(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///a.zig","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":3}}}]}
    );
    defer locations.deinit();
    try std.testing.expectEqual(@as(usize, 1), locations.items.len);

    const hover = (try parseHoverText(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"result":{"contents":{"kind":"markdown","value":"**hello**"}}}
    )).?;
    defer std.testing.allocator.free(hover);
    try std.testing.expectEqualStrings("**hello**", hover);

    const signature = (try parseSignatureLabel(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"result":{"signatures":[{"label":"foo(a: i32)"}]}}
    )).?;
    defer std.testing.allocator.free(signature);
    try std.testing.expectEqualStrings("foo(a: i32)", signature);

    var symbols = try parseSymbols(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":4,"result":[{"name":"outer","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":3,"character":1}},"children":[{"name":"inner","kind":12,"range":{"start":{"line":1,"character":0},"end":{"line":2,"character":1}}}]}]}
    , "file:///demo.zig");
    defer symbols.deinit();
    try std.testing.expectEqual(@as(usize, 2), symbols.items.len);
}
