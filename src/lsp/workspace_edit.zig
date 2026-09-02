const std = @import("std");
const types = @import("types.zig");

pub const OwnedTextEdit = struct {
    range: types.Range,
    new_text: []u8,

    fn deinit(self: *OwnedTextEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.new_text);
        self.* = undefined;
    }
};

pub const FileEdit = struct {
    uri: []u8,
    edits: std.ArrayList(OwnedTextEdit) = .empty,

    fn deinit(self: *FileEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        for (self.edits.items) |*edit| edit.deinit(allocator);
        self.edits.deinit(allocator);
        self.* = undefined;
    }
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileEdit) = .empty,

    pub fn init(allocator: std.mem.Allocator) Plan {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Plan) void {
        for (self.files.items) |*file| file.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !Plan {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return Plan.init(allocator);
        if (result == .null) return Plan.init(allocator);
        return parseValue(allocator, result);
    }

    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) !Plan {
        if (value != .object) return error.InvalidWorkspaceEdit;
        var plan = Plan.init(allocator);
        errdefer plan.deinit();

        if (value.object.get("changes")) |changes| {
            if (changes != .object) return error.InvalidWorkspaceEdit;
            var iterator = changes.object.iterator();
            while (iterator.next()) |entry| {
                try appendFileEdits(&plan, entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        if (value.object.get("documentChanges")) |document_changes| {
            if (document_changes != .array) return error.InvalidWorkspaceEdit;
            for (document_changes.array.items) |document_change| {
                if (document_change != .object) continue;
                const text_document = document_change.object.get("textDocument") orelse continue;
                const edits = document_change.object.get("edits") orelse continue;
                if (text_document != .object) continue;
                const uri_value = text_document.object.get("uri") orelse continue;
                if (uri_value != .string) continue;
                try appendFileEdits(&plan, uri_value.string, edits);
            }
        }

        return plan;
    }
};

pub fn parseTextEditResponse(allocator: std.mem.Allocator, body: []const u8, uri: []const u8) !Plan {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return Plan.init(allocator);
    if (result == .null) return Plan.init(allocator);
    if (result != .array) return error.InvalidTextEditResponse;
    var plan = Plan.init(allocator);
    errdefer plan.deinit();
    try appendFileEdits(&plan, uri, result);
    return plan;
}

pub fn applyTextEdits(
    allocator: std.mem.Allocator,
    original: []const u8,
    edits: []const OwnedTextEdit,
) ![]u8 {
    const Span = struct {
        start: usize,
        end: usize,
        new_text: []const u8,
    };
    const spans = try allocator.alloc(Span, edits.len);
    defer allocator.free(spans);
    for (edits, spans) |edit, *span| {
        span.* = .{
            .start = types.byteOffsetFromPositionUtf16(original, edit.range.start),
            .end = types.byteOffsetFromPositionUtf16(original, edit.range.end),
            .new_text = edit.new_text,
        };
        if (span.end < span.start) return error.InvalidEditRange;
    }

    var i: usize = 0;
    while (i < spans.len) : (i += 1) {
        var min_index = i;
        var j = i + 1;
        while (j < spans.len) : (j += 1) {
            if (spans[j].start < spans[min_index].start) min_index = j;
        }
        if (min_index != i) std.mem.swap(Span, &spans[i], &spans[min_index]);
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var cursor: usize = 0;
    for (spans) |span| {
        if (span.start < cursor) return error.OverlappingEdits;
        try output.appendSlice(allocator, original[cursor..span.start]);
        try output.appendSlice(allocator, span.new_text);
        cursor = span.end;
    }
    try output.appendSlice(allocator, original[cursor..]);
    return output.toOwnedSlice(allocator);
}

fn appendFileEdits(plan: *Plan, uri: []const u8, edits_value: std.json.Value) !void {
    if (edits_value != .array) return error.InvalidWorkspaceEdit;
    const index = try getOrAppendFile(plan, uri);
    for (edits_value.array.items) |edit_value| {
        if (edit_value != .object) return error.InvalidWorkspaceEdit;
        const range_value = edit_value.object.get("range") orelse return error.InvalidWorkspaceEdit;
        const text_value = edit_value.object.get("newText") orelse return error.InvalidWorkspaceEdit;
        if (text_value != .string) return error.InvalidWorkspaceEdit;
        try plan.files.items[index].edits.append(plan.allocator, .{
            .range = try parseRange(range_value),
            .new_text = try plan.allocator.dupe(u8, text_value.string),
        });
    }
}

fn getOrAppendFile(plan: *Plan, uri: []const u8) !usize {
    for (plan.files.items, 0..) |file, index| {
        if (std.mem.eql(u8, file.uri, uri)) return index;
    }
    try plan.files.append(plan.allocator, .{ .uri = try plan.allocator.dupe(u8, uri) });
    return plan.files.items.len - 1;
}

fn parseRange(value: std.json.Value) !types.Range {
    if (value != .object) return error.InvalidWorkspaceEdit;
    return .{
        .start = try parsePosition(value.object.get("start") orelse return error.InvalidWorkspaceEdit),
        .end = try parsePosition(value.object.get("end") orelse return error.InvalidWorkspaceEdit),
    };
}

fn parsePosition(value: std.json.Value) !types.Position {
    if (value != .object) return error.InvalidWorkspaceEdit;
    const line = value.object.get("line") orelse return error.InvalidWorkspaceEdit;
    const character = value.object.get("character") orelse return error.InvalidWorkspaceEdit;
    if (line != .integer or character != .integer or line.integer < 0 or character.integer < 0) return error.InvalidWorkspaceEdit;
    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

test "WorkspaceEdit parses changes and documentChanges across files" {
    var plan = try Plan.parseResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":8,"result":{"changes":{"file:///a.zig":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"alpha"}]},"documentChanges":[{"textDocument":{"uri":"file:///b.zig","version":2},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"beta"}]}]}}
    );
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.files.items.len);

    const updated = try applyTextEdits(std.testing.allocator, "x🙂z", plan.files.items[0].edits.items);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("alpha🙂z", updated);
}

test "formatting TextEdit response becomes a single-file plan" {
    var plan = try parseTextEditResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":9,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"formatted"}]}
    , "file:///demo.zig");
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.files.items.len);
    try std.testing.expectEqualStrings("file:///demo.zig", plan.files.items[0].uri);
    try std.testing.expectEqualStrings("formatted", plan.files.items[0].edits.items[0].new_text);
}

pub fn parseCodeActionResponse(allocator: std.mem.Allocator, body: []const u8) !Plan {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return Plan.init(allocator);
    if (result == .null) return Plan.init(allocator);
    if (result != .array) return error.InvalidCodeActionResponse;
    for (result.array.items) |action| {
        if (action != .object) continue;
        if (action.object.get("edit")) |edit| return Plan.parseValue(allocator, edit);
    }
    return Plan.init(allocator);
}
