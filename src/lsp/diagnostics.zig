const std = @import("std");
const types = @import("types.zig");

const WireDiagnostic = struct {
    range: types.Range,
    severity: ?u8 = null,
    message: []const u8,
    source: ?[]const u8 = null,
};

const PublishParams = struct {
    uri: []const u8,
    version: ?i64 = null,
    diagnostics: []const WireDiagnostic,
};

pub const OwnedDiagnostic = struct {
    range: types.Range,
    severity: ?types.DiagnosticSeverity = null,
    message: []u8,
    source: ?[]u8 = null,

    fn deinit(self: *OwnedDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.source) |source| allocator.free(source);
        self.* = undefined;
    }
};

pub const Entry = struct {
    uri: []u8,
    version: ?i64,
    items: std.ArrayList(OwnedDiagnostic) = .empty,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn replaceFromParamsJson(self: *Store, params_json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(PublishParams, self.allocator, params_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var replacement = Entry{
            .uri = try self.allocator.dupe(u8, parsed.value.uri),
            .version = parsed.value.version,
        };
        errdefer replacement.deinit(self.allocator);
        for (parsed.value.diagnostics) |wire| {
            try replacement.items.append(self.allocator, .{
                .range = wire.range,
                .severity = severityFromWire(wire.severity),
                .message = try self.allocator.dupe(u8, wire.message),
                .source = if (wire.source) |source| try self.allocator.dupe(u8, source) else null,
            });
        }

        if (self.indexOf(parsed.value.uri)) |index| {
            self.entries.items[index].deinit(self.allocator);
            self.entries.items[index] = replacement;
        } else {
            try self.entries.append(self.allocator, replacement);
        }
    }

    pub fn itemsFor(self: *const Store, uri: []const u8) []const OwnedDiagnostic {
        const index = self.indexOf(uri) orelse return &[_]OwnedDiagnostic{};
        return self.entries.items[index].items.items;
    }

    pub fn nextOffset(
        self: *const Store,
        uri: []const u8,
        text: []const u8,
        current_offset: usize,
        forward: bool,
    ) ?usize {
        const items = self.itemsFor(uri);
        if (items.len == 0) return null;
        var best: ?usize = null;
        if (forward) {
            var wrapped: ?usize = null;
            for (items) |item| {
                const offset = types.byteOffsetFromPositionUtf16(text, item.range.start);
                if (offset > current_offset and (best == null or offset < best.?)) best = offset;
                if (wrapped == null or offset < wrapped.?) wrapped = offset;
            }
            return best orelse wrapped;
        }

        var wrapped: ?usize = null;
        for (items) |item| {
            const offset = types.byteOffsetFromPositionUtf16(text, item.range.start);
            if (offset < current_offset and (best == null or offset > best.?)) best = offset;
            if (wrapped == null or offset > wrapped.?) wrapped = offset;
        }
        return best orelse wrapped;
    }

    fn indexOf(self: *const Store, uri: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.uri, uri)) return index;
        }
        return null;
    }
};

fn severityFromWire(value: ?u8) ?types.DiagnosticSeverity {
    const raw = value orelse return null;
    return switch (raw) {
        1 => .error,
        2 => .warning,
        3 => .information,
        4 => .hint,
        else => null,
    };
}

test "diagnostics replace by URI and navigate with UTF-16 ranges" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.replaceFromParamsJson(
        \\{"uri":"file:///tmp/demo.zig","version":3,"diagnostics":[
        \\{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":4}},"severity":1,"message":"first","source":"zls"},
        \\{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"severity":2,"message":"second"}
        \\]}
    );
    const items = store.itemsFor("file:///tmp/demo.zig");
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("first", items[0].message);
    const text = "a🙂b\nnext";
    const next = store.nextOffset("file:///tmp/demo.zig", text, 0, true).?;
    try std.testing.expectEqual("a🙂".len, next);
    const wrapped = store.nextOffset("file:///tmp/demo.zig", text, text.len, true).?;
    try std.testing.expectEqual("a🙂".len, wrapped);
}
