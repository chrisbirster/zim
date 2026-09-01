const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const registry = @import("registry.zig");

pub const Document = struct {
    allocator: std.mem.Allocator,
    id: types.BufferId,
    revision: types.Revision,
    language_index: usize,
    text: []u8,
    parser: *ts.Parser,
    tree: *ts.Tree,

    pub fn init(
        allocator: std.mem.Allocator,
        id: types.BufferId,
        revision: types.Revision,
        language_index: usize,
        spec: registry.LanguageSpec,
        text: []const u8,
    ) !Document {
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);

        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(spec.factory());

        const tree = parser.parseString(text, null) orelse return error.ParseFailed;
        errdefer tree.destroy();

        return .{
            .allocator = allocator,
            .id = id,
            .revision = revision,
            .language_index = language_index,
            .text = owned_text,
            .parser = parser,
            .tree = tree,
        };
    }

    pub fn deinit(self: *Document) void {
        self.tree.destroy();
        self.parser.destroy();
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn summary(self: *const Document) types.ParseSummary {
        const root = self.tree.rootNode();
        return .{
            .revision = self.revision,
            .root = rangeFromNode(root),
            .has_error = root.hasError(),
        };
    }

    pub fn applyEdit(
        self: *Document,
        result_allocator: std.mem.Allocator,
        new_text: []const u8,
        new_revision: types.Revision,
        edit: types.Edit,
    ) !types.ChangedRangeList {
        if (new_revision <= self.revision) return error.StaleRevision;
        try validateEdit(self.text, new_text, edit);

        const edited_tree = self.tree.dupe();
        defer edited_tree.destroy();
        edited_tree.edit(.{
            .start_byte = edit.start_byte,
            .old_end_byte = edit.old_end_byte,
            .new_end_byte = edit.new_end_byte,
            .start_point = toTsPoint(edit.start_point),
            .old_end_point = toTsPoint(edit.old_end_point),
            .new_end_point = toTsPoint(edit.new_end_point),
        });

        const new_tree = self.parser.parseString(new_text, edited_tree) orelse return error.ParseFailed;
        errdefer new_tree.destroy();

        const ts_ranges = try edited_tree.getChangedRanges(result_allocator, new_tree);
        defer result_allocator.free(ts_ranges);
        const ranges = try result_allocator.alloc(types.Range, ts_ranges.len);
        errdefer result_allocator.free(ranges);
        for (ts_ranges, ranges) |source, *target| target.* = rangeFromTs(source);

        const replacement = try self.allocator.dupe(u8, new_text);
        errdefer self.allocator.free(replacement);

        self.tree.destroy();
        self.allocator.free(self.text);
        self.tree = new_tree;
        self.text = replacement;
        self.revision = new_revision;

        return .{ .allocator = result_allocator, .items = ranges };
    }
};

pub fn rangeFromNode(node: ts.Node) types.Range {
    return .{
        .start_byte = node.startByte(),
        .end_byte = node.endByte(),
        .start_point = fromTsPoint(node.startPoint()),
        .end_point = fromTsPoint(node.endPoint()),
    };
}

pub fn rangeFromTs(value: ts.Range) types.Range {
    return .{
        .start_byte = value.start_byte,
        .end_byte = value.end_byte,
        .start_point = fromTsPoint(value.start_point),
        .end_point = fromTsPoint(value.end_point),
    };
}

pub fn positionAt(text: []const u8, byte_index: usize) types.Position {
    const stop = @min(byte_index, text.len);
    var row: u32 = 0;
    var column: u32 = 0;
    for (text[0..stop]) |byte| {
        if (byte == '\n') {
            row += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .row = row, .column = column };
}

pub fn rangeFromBytes(text: []const u8, start_byte: usize, end_byte: usize) types.Range {
    return .{
        .start_byte = @intCast(start_byte),
        .end_byte = @intCast(end_byte),
        .start_point = positionAt(text, start_byte),
        .end_point = positionAt(text, end_byte),
    };
}

fn toTsPoint(point: types.Position) ts.Point {
    return .{ .row = point.row, .column = point.column };
}

fn fromTsPoint(point: ts.Point) types.Position {
    return .{ .row = point.row, .column = point.column };
}

fn validateEdit(old_text: []const u8, new_text: []const u8, edit: types.Edit) !void {
    const start: usize = @intCast(edit.start_byte);
    const old_end: usize = @intCast(edit.old_end_byte);
    const new_end: usize = @intCast(edit.new_end_byte);
    if (start > old_end or start > new_end) return error.InvalidEdit;
    if (old_end > old_text.len or new_end > new_text.len) return error.InvalidEdit;

    const removed = old_end - start;
    const inserted = new_end - start;
    if (old_text.len - removed + inserted != new_text.len) return error.InvalidEdit;
}
