const std = @import("std");
const ts = @import("tree-sitter");
const types = @import("types.zig");
const registry_mod = @import("registry.zig");
const query_sources = @import("queries.zig");
const document_mod = @import("document.zig");

const Document = document_mod.Document;

pub const Service = struct {
    allocator: std.mem.Allocator,
    registry: registry_mod.Registry,
    documents: std.ArrayList(Document) = .empty,

    pub fn init(allocator: std.mem.Allocator, registry: registry_mod.Registry) Service {
        return .{ .allocator = allocator, .registry = registry };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Service {
        return init(allocator, try registry_mod.Registry.initDefault(allocator));
    }

    pub fn deinit(self: *Service) void {
        for (self.documents.items) |*document| document.deinit();
        self.documents.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn open(
        self: *Service,
        buffer_id: types.BufferId,
        text: []const u8,
        initial_revision: types.Revision,
        language_id: []const u8,
    ) !types.ParseSummary {
        const language_index = self.registry.findIndex(language_id) orelse return error.UnknownLanguage;
        const spec = self.registry.languages.items[language_index];
        var replacement = try Document.init(
            self.allocator,
            buffer_id,
            initial_revision,
            language_index,
            spec,
            text,
        );
        errdefer replacement.deinit();

        if (self.documentIndex(buffer_id)) |index| {
            self.documents.items[index].deinit();
            self.documents.items[index] = replacement;
        } else {
            try self.documents.append(self.allocator, replacement);
        }
        return replacement.summary();
    }

    pub fn close(self: *Service, buffer_id: types.BufferId) bool {
        const index = self.documentIndex(buffer_id) orelse return false;
        var removed = self.documents.swapRemove(index);
        removed.deinit();
        return true;
    }

    pub fn revision(self: *const Service, buffer_id: types.BufferId) ?types.Revision {
        const index = self.documentIndex(buffer_id) orelse return null;
        return self.documents.items[index].revision;
    }

    pub fn summary(self: *const Service, buffer_id: types.BufferId) !types.ParseSummary {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        return document.summary();
    }

    pub fn applyEdit(
        self: *Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
        new_text: []const u8,
        new_revision: types.Revision,
        edit: types.Edit,
    ) !types.ChangedRangeList {
        const document = self.getDocument(buffer_id) orelse return error.UnknownBuffer;
        return document.applyEdit(result_allocator, new_text, new_revision, edit);
    }

    pub fn sync(
        self: *Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
        new_text: []const u8,
        new_revision: types.Revision,
    ) !types.ChangedRangeList {
        const document = self.getDocument(buffer_id) orelse return error.UnknownBuffer;
        if (new_revision <= document.revision) return error.StaleRevision;
        if (std.mem.eql(u8, document.text, new_text)) {
            document.revision = new_revision;
            return emptyChangedRangeList(result_allocator);
        }
        const edit = minimalEdit(document.text, new_text);
        return document.applyEdit(result_allocator, new_text, new_revision, edit);
    }

    pub fn highlights(
        self: *const Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
    ) !types.HighlightList {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        const spec = self.registry.languages.items[document.language_index];
        const query = try compileQuery(spec, .highlights);
        if (query == null) return try emptyHighlightList(result_allocator);
        defer query.?.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query.?, document.tree.rootNode());

        var items: std.ArrayList(types.HighlightSpan) = .empty;
        errdefer freeHighlights(&items, result_allocator);
        while (cursor.nextCapture()) |entry| {
            const capture_index: usize = @intCast(entry[0]);
            const match = entry[1];
            if (capture_index >= match.captures.len) continue;
            const capture = match.captures[capture_index];
            const name = query.?.captureNameForId(capture.index) orelse continue;
            const owned_name = try result_allocator.dupe(u8, name);
            items.append(result_allocator, .{
                .range = document_mod.rangeFromNode(capture.node),
                .capture = owned_name,
            }) catch |err| {
                result_allocator.free(owned_name);
                return err;
            };
        }
        return .{ .allocator = result_allocator, .items = try items.toOwnedSlice(result_allocator) };
    }

    pub fn folds(
        self: *const Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
    ) !types.FoldList {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        const spec = self.registry.languages.items[document.language_index];
        const query = try compileQuery(spec, .folds);
        if (query == null) return try emptyFoldList(result_allocator);
        defer query.?.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query.?, document.tree.rootNode());

        var items: std.ArrayList(types.FoldRange) = .empty;
        errdefer items.deinit(result_allocator);
        while (cursor.nextCapture()) |entry| {
            const capture_index: usize = @intCast(entry[0]);
            const match = entry[1];
            if (capture_index >= match.captures.len) continue;
            const capture = match.captures[capture_index];
            const name = query.?.captureNameForId(capture.index) orelse continue;
            if (!std.mem.eql(u8, name, "fold")) continue;
            try items.append(result_allocator, .{ .range = document_mod.rangeFromNode(capture.node) });
        }
        return .{ .allocator = result_allocator, .items = try items.toOwnedSlice(result_allocator) };
    }

    pub fn symbols(
        self: *const Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
    ) !types.SymbolList {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        const spec = self.registry.languages.items[document.language_index];
        const query = try compileQuery(spec, .symbols);
        if (query == null) return try emptySymbolList(result_allocator);
        defer query.?.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query.?, document.tree.rootNode());

        var items: std.ArrayList(types.Symbol) = .empty;
        errdefer freeSymbols(&items, result_allocator);
        while (cursor.nextMatch()) |match| {
            var symbol_node: ?ts.Node = null;
            var name_node: ?ts.Node = null;
            var kind: ?types.SymbolKind = null;

            for (match.captures) |capture| {
                const name = query.?.captureNameForId(capture.index) orelse continue;
                if (std.mem.eql(u8, name, "symbol.name")) {
                    name_node = capture.node;
                } else if (std.mem.eql(u8, name, "symbol.function")) {
                    symbol_node = capture.node;
                    kind = .function;
                } else if (std.mem.eql(u8, name, "symbol.class")) {
                    symbol_node = capture.node;
                    kind = .class;
                }
            }

            const node = symbol_node orelse continue;
            const selection = if (name_node) |value| document_mod.rangeFromNode(value) else null;
            const owned_name = if (selection) |name_range|
                try result_allocator.dupe(u8, sourceSlice(document.text, name_range))
            else
                null;

            items.append(result_allocator, .{
                .range = document_mod.rangeFromNode(node),
                .selection_range = selection,
                .name = owned_name,
                .kind = kind orelse .other,
            }) catch |err| {
                if (owned_name) |value| result_allocator.free(value);
                return err;
            };
        }
        return .{ .allocator = result_allocator, .items = try items.toOwnedSlice(result_allocator) };
    }

    pub fn textObjects(
        self: *const Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
        kind: types.StructuralObjectKind,
        scope: types.ObjectScope,
    ) !types.TextObjectList {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        const spec = self.registry.languages.items[document.language_index];
        const query = try compileQuery(spec, .text_objects);
        if (query == null) return try emptyTextObjectList(result_allocator);
        defer query.?.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query.?, document.tree.rootNode());

        var items: std.ArrayList(types.TextObject) = .empty;
        errdefer items.deinit(result_allocator);
        while (cursor.nextMatch()) |match| {
            var function_around: ?types.Range = null;
            var function_body: ?types.Range = null;
            var class_around: ?types.Range = null;
            var class_container: ?types.Range = null;
            var parameter_inner: ?types.Range = null;
            var block_around: ?types.Range = null;

            for (match.captures) |capture| {
                const name = query.?.captureNameForId(capture.index) orelse continue;
                const capture_range = document_mod.rangeFromNode(capture.node);
                if (std.mem.eql(u8, name, "object.function.around")) function_around = capture_range;
                if (std.mem.eql(u8, name, "object.function.body")) function_body = capture_range;
                if (std.mem.eql(u8, name, "object.class.around")) class_around = capture_range;
                if (std.mem.eql(u8, name, "object.class.container")) class_container = capture_range;
                if (std.mem.eql(u8, name, "object.parameter.inner")) parameter_inner = capture_range;
                if (std.mem.eql(u8, name, "object.block.around")) block_around = capture_range;
            }

            const resolved = resolveTextObject(document.text, kind, scope, .{
                .function_around = function_around,
                .function_body = function_body,
                .class_around = class_around,
                .class_container = class_container,
                .parameter_inner = parameter_inner,
                .block_around = block_around,
            }) orelse continue;
            try items.append(result_allocator, .{ .kind = kind, .scope = scope, .range = resolved });
        }
        return .{ .allocator = result_allocator, .items = try items.toOwnedSlice(result_allocator) };
    }

    pub fn structuralMotion(
        self: *const Service,
        scratch_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
        kind: types.StructuralObjectKind,
        direction: types.MotionDirection,
        from_byte: u32,
    ) !?types.Range {
        if (kind != .function and kind != .class) return error.UnsupportedMotionKind;
        var objects = try self.textObjects(scratch_allocator, buffer_id, kind, .around);
        defer objects.deinit();

        var best: ?types.Range = null;
        for (objects.items) |object| {
            switch (direction) {
                .next => {
                    if (object.range.start_byte <= from_byte) continue;
                    if (best == null or object.range.start_byte < best.?.start_byte) best = object.range;
                },
                .previous => {
                    if (object.range.start_byte >= from_byte) continue;
                    if (best == null or object.range.start_byte > best.?.start_byte) best = object.range;
                },
            }
        }
        return best;
    }

    pub fn injections(
        self: *const Service,
        result_allocator: std.mem.Allocator,
        buffer_id: types.BufferId,
    ) !types.InjectionList {
        const document = self.getDocumentConst(buffer_id) orelse return error.UnknownBuffer;
        const spec = self.registry.languages.items[document.language_index];
        const query = try compileQuery(spec, .injections);
        if (query == null) return try emptyInjectionList(result_allocator);
        defer query.?.destroy();

        const cursor = ts.QueryCursor.create();
        defer cursor.destroy();
        cursor.exec(query.?, document.tree.rootNode());

        var items: std.ArrayList(types.InjectionRegion) = .empty;
        errdefer freeInjections(&items, result_allocator);
        while (cursor.nextMatch()) |match| {
            var content: ?types.Range = null;
            var language_range: ?types.Range = null;
            for (match.captures) |capture| {
                const name = query.?.captureNameForId(capture.index) orelse continue;
                if (std.mem.eql(u8, name, "injection.content")) {
                    content = document_mod.rangeFromNode(capture.node);
                } else if (std.mem.eql(u8, name, "injection.language")) {
                    language_range = document_mod.rangeFromNode(capture.node);
                }
            }
            const content_range = content orelse continue;
            const language_id = if (language_range) |value|
                try duplicateLanguageId(result_allocator, sourceSlice(document.text, value))
            else
                null;
            items.append(result_allocator, .{ .range = content_range, .language_id = language_id }) catch |err| {
                if (language_id) |value| result_allocator.free(value);
                return err;
            };
        }
        return .{ .allocator = result_allocator, .items = try items.toOwnedSlice(result_allocator) };
    }

    fn documentIndex(self: *const Service, buffer_id: types.BufferId) ?usize {
        for (self.documents.items, 0..) |document, index| {
            if (document.id == buffer_id) return index;
        }
        return null;
    }

    fn getDocument(self: *Service, buffer_id: types.BufferId) ?*Document {
        const index = self.documentIndex(buffer_id) orelse return null;
        return &self.documents.items[index];
    }

    fn getDocumentConst(self: *const Service, buffer_id: types.BufferId) ?*const Document {
        const index = self.documentIndex(buffer_id) orelse return null;
        return &self.documents.items[index];
    }
};

fn minimalEdit(old_text: []const u8, new_text: []const u8) types.Edit {
    var start: usize = 0;
    const shared = @min(old_text.len, new_text.len);
    while (start < shared and old_text[start] == new_text[start]) : (start += 1) {}
    while (start > 0 and
        ((start < old_text.len and isUtf8Continuation(old_text[start])) or
            (start < new_text.len and isUtf8Continuation(new_text[start]))))
    {
        start -= 1;
    }

    var old_end = old_text.len;
    var new_end = new_text.len;
    while (old_end > start and new_end > start and old_text[old_end - 1] == new_text[new_end - 1]) {
        old_end -= 1;
        new_end -= 1;
    }
    while (old_end < old_text.len and new_end < new_text.len and
        (isUtf8Continuation(old_text[old_end]) or isUtf8Continuation(new_text[new_end])))
    {
        old_end += 1;
        new_end += 1;
    }

    return .{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(old_end),
        .new_end_byte = @intCast(new_end),
        .start_point = document_mod.positionAt(old_text, start),
        .old_end_point = document_mod.positionAt(old_text, old_end),
        .new_end_point = document_mod.positionAt(new_text, new_end),
    };
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

const CapturedObjects = struct {
    function_around: ?types.Range,
    function_body: ?types.Range,
    class_around: ?types.Range,
    class_container: ?types.Range,
    parameter_inner: ?types.Range,
    block_around: ?types.Range,
};

fn compileQuery(spec: registry_mod.LanguageSpec, kind: query_sources.Kind) !?*ts.Query {
    const source = spec.queries.get(kind);
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return null;
    var error_offset: u32 = 0;
    return try ts.Query.create(spec.factory(), source, &error_offset);
}

fn resolveTextObject(
    source: []const u8,
    kind: types.StructuralObjectKind,
    scope: types.ObjectScope,
    captures: CapturedObjects,
) ?types.Range {
    return switch (kind) {
        .function => switch (scope) {
            .around => captures.function_around,
            .inner => if (captures.function_body) |range| innerDelimitedRange(source, range, '{', '}') else null,
        },
        .class => switch (scope) {
            .around => captures.class_around,
            .inner => if (captures.class_container) |range| innerDelimitedRange(source, range, '{', '}') else null,
        },
        .parameter => if (captures.parameter_inner) |range| switch (scope) {
            .inner => range,
            .around => expandCommaSeparated(source, range),
        } else null,
        .block => if (captures.block_around) |range| switch (scope) {
            .around => range,
            .inner => innerDelimitedRange(source, range, '{', '}'),
        } else null,
    };
}

fn innerDelimitedRange(source: []const u8, range: types.Range, open: u8, close: u8) types.Range {
    const start: usize = @intCast(range.start_byte);
    const end: usize = @intCast(range.end_byte);
    if (start >= end or end > source.len) return range;
    const slice = source[start..end];
    const open_rel = std.mem.indexOfScalar(u8, slice, open) orelse return range;
    const close_rel = std.mem.lastIndexOfScalar(u8, slice, close) orelse return range;
    if (close_rel <= open_rel) return range;

    var inner_start = start + open_rel + 1;
    var inner_end = start + close_rel;
    while (inner_start < inner_end and std.ascii.isWhitespace(source[inner_start])) : (inner_start += 1) {}
    while (inner_end > inner_start and std.ascii.isWhitespace(source[inner_end - 1])) : (inner_end -= 1) {}
    return document_mod.rangeFromBytes(source, inner_start, inner_end);
}

fn expandCommaSeparated(source: []const u8, range: types.Range) types.Range {
    var start: usize = @intCast(range.start_byte);
    var end: usize = @intCast(range.end_byte);
    if (end > source.len) return range;

    var right = end;
    while (right < source.len and std.ascii.isWhitespace(source[right])) : (right += 1) {}
    if (right < source.len and source[right] == ',') {
        right += 1;
        while (right < source.len and std.ascii.isWhitespace(source[right])) : (right += 1) {}
        end = right;
        return document_mod.rangeFromBytes(source, start, end);
    }

    var left = start;
    while (left > 0 and std.ascii.isWhitespace(source[left - 1])) : (left -= 1) {}
    if (left > 0 and source[left - 1] == ',') start = left - 1;
    return document_mod.rangeFromBytes(source, start, end);
}

fn sourceSlice(source: []const u8, range: types.Range) []const u8 {
    const start: usize = @intCast(range.start_byte);
    const end: usize = @intCast(range.end_byte);
    if (start > end or end > source.len) return "";
    return source[start..end];
}

fn duplicateLanguageId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return allocator.dupe(u8, value);
}

fn freeHighlights(items: *std.ArrayList(types.HighlightSpan), allocator: std.mem.Allocator) void {
    for (items.items) |item| allocator.free(item.capture);
    items.deinit(allocator);
}

fn freeSymbols(items: *std.ArrayList(types.Symbol), allocator: std.mem.Allocator) void {
    for (items.items) |item| {
        if (item.name) |name| allocator.free(name);
    }
    items.deinit(allocator);
}

fn freeInjections(items: *std.ArrayList(types.InjectionRegion), allocator: std.mem.Allocator) void {
    for (items.items) |item| {
        if (item.language_id) |language_id| allocator.free(language_id);
    }
    items.deinit(allocator);
}

fn emptyChangedRangeList(allocator: std.mem.Allocator) !types.ChangedRangeList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.Range, 0) };
}

fn emptyHighlightList(allocator: std.mem.Allocator) !types.HighlightList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.HighlightSpan, 0) };
}

fn emptyFoldList(allocator: std.mem.Allocator) !types.FoldList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.FoldRange, 0) };
}

fn emptySymbolList(allocator: std.mem.Allocator) !types.SymbolList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.Symbol, 0) };
}

fn emptyTextObjectList(allocator: std.mem.Allocator) !types.TextObjectList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.TextObject, 0) };
}

fn emptyInjectionList(allocator: std.mem.Allocator) !types.InjectionList {
    return .{ .allocator = allocator, .items = try allocator.alloc(types.InjectionRegion, 0) };
}
