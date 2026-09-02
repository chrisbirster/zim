const std = @import("std");

pub const Item = struct {
    label: []u8,
    detail: ?[]u8 = null,
    insert_text: []u8,
    sort_text: ?[]u8 = null,
    kind: ?u32 = null,

    fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.detail) |detail| allocator.free(detail);
        allocator.free(self.insert_text);
        if (self.sort_text) |sort_text| allocator.free(sort_text);
        self.* = undefined;
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    items: []Item,
    is_incomplete: bool = false,

    pub fn deinit(self: *List) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !List {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return empty(allocator, false);
    if (result == .null) return empty(allocator, false);

    var values: []const std.json.Value = undefined;
    var is_incomplete = false;
    switch (result) {
        .array => |array| values = array.items,
        .object => |object| {
            const items_value = object.get("items") orelse return error.InvalidCompletionResponse;
            if (items_value != .array) return error.InvalidCompletionResponse;
            values = items_value.array.items;
            if (object.get("isIncomplete")) |value| {
                if (value == .bool) is_incomplete = value.bool;
            }
        },
        else => return error.InvalidCompletionResponse,
    }

    var output: std.ArrayList(Item) = .empty;
    errdefer {
        for (output.items) |*item| item.deinit(allocator);
        output.deinit(allocator);
    }
    for (values) |value| {
        if (value != .object) continue;
        const label_value = value.object.get("label") orelse continue;
        if (label_value != .string) continue;

        var insert_text = label_value.string;
        if (value.object.get("insertText")) |candidate| {
            if (candidate == .string) insert_text = candidate.string;
        } else if (value.object.get("textEdit")) |text_edit| {
            if (text_edit == .object) {
                if (text_edit.object.get("newText")) |candidate| {
                    if (candidate == .string) insert_text = candidate.string;
                }
            }
        }

        var item = Item{
            .label = try allocator.dupe(u8, label_value.string),
            .insert_text = try allocator.dupe(u8, insert_text),
        };
        errdefer item.deinit(allocator);

        if (value.object.get("detail")) |detail| {
            if (detail == .string) item.detail = try allocator.dupe(u8, detail.string);
        }
        if (value.object.get("sortText")) |sort_text| {
            if (sort_text == .string) item.sort_text = try allocator.dupe(u8, sort_text.string);
        }
        if (value.object.get("kind")) |kind| {
            if (kind == .integer and kind.integer >= 0) item.kind = @intCast(kind.integer);
        }
        try output.append(allocator, item);
    }

    return .{
        .allocator = allocator,
        .items = try output.toOwnedSlice(allocator),
        .is_incomplete = is_incomplete,
    };
}

fn empty(allocator: std.mem.Allocator, is_incomplete: bool) !List {
    return .{
        .allocator = allocator,
        .items = try allocator.alloc(Item, 0),
        .is_incomplete = is_incomplete,
    };
}

test "completion parser supports CompletionList and textEdit insertion text" {
    var list = try parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":9,"result":{"isIncomplete":true,"items":[{"label":"append","detail":"method","kind":2,"sortText":"001","textEdit":{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"append()"}},{"label":"allocator","insertText":"allocator"}]}}
    );
    defer list.deinit();
    try std.testing.expect(list.is_incomplete);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("append()", list.items[0].insert_text);
    try std.testing.expectEqualStrings("method", list.items[0].detail.?);
    try std.testing.expectEqual(@as(?u32, 2), list.items[0].kind);
}

test "completion parser supports bare arrays" {
    var list = try parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":10,"result":[{"label":"value"}]}
    );
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("value", list.items[0].insert_text);
}
