const std = @import("std");
const language = @import("root.zig");

const zig_source = @embedFile("fixtures/sample.zig");

test "Tree-sitter language service parses and answers editor-neutral Zig queries" {
    const allocator = std.testing.allocator;
    var service = try language.Service.initDefault(allocator);
    defer service.deinit();

    const summary = try service.open(7, zig_source, 1, "zig");
    try std.testing.expectEqual(@as(u64, 1), summary.revision);
    try std.testing.expect(!summary.has_error);
    try std.testing.expect(summary.root.end_byte > 0);
    try std.testing.expectEqual(@as(?u64, 1), service.revision(7));

    var highlights = try service.highlights(allocator, 7);
    defer highlights.deinit();
    try std.testing.expect(hasHighlight(highlights.items, "function"));
    try std.testing.expect(hasHighlight(highlights.items, "type.builtin"));

    var folds = try service.folds(allocator, 7);
    defer folds.deinit();
    try std.testing.expect(folds.items.len >= 2);

    var symbols = try service.symbols(allocator, 7);
    defer symbols.deinit();
    try std.testing.expect(hasSymbol(symbols.items, "Point", .class));
    try std.testing.expect(hasSymbol(symbols.items, "add", .function));

    var function_around = try service.textObjects(allocator, 7, .function, .around);
    defer function_around.deinit();
    var function_inner = try service.textObjects(allocator, 7, .function, .inner);
    defer function_inner.deinit();
    try std.testing.expectEqual(@as(usize, 1), function_around.items.len);
    try std.testing.expectEqual(@as(usize, 1), function_inner.items.len);
    try std.testing.expect(function_inner.items[0].range.len() < function_around.items[0].range.len());

    var class_around = try service.textObjects(allocator, 7, .class, .around);
    defer class_around.deinit();
    var class_inner = try service.textObjects(allocator, 7, .class, .inner);
    defer class_inner.deinit();
    try std.testing.expectEqual(@as(usize, 1), class_around.items.len);
    try std.testing.expectEqual(@as(usize, 1), class_inner.items.len);
    try std.testing.expect(class_inner.items[0].range.len() < class_around.items[0].range.len());

    var parameter_inner = try service.textObjects(allocator, 7, .parameter, .inner);
    defer parameter_inner.deinit();
    var parameter_around = try service.textObjects(allocator, 7, .parameter, .around);
    defer parameter_around.deinit();
    try std.testing.expect(parameter_inner.items.len >= 2);
    try std.testing.expectEqual(parameter_inner.items.len, parameter_around.items.len);
    try std.testing.expect(parameter_around.items[0].range.len() >= parameter_inner.items[0].range.len());

    const next_function = (try service.structuralMotion(allocator, 7, .function, .next, 0)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(next_function.start_byte > 0);

    var injections = try service.injections(allocator, 7);
    defer injections.deinit();
    try std.testing.expectEqual(@as(usize, 0), injections.items.len);
}

test "Tree-sitter language service incrementally reparses by buffer revision" {
    const allocator = std.testing.allocator;
    var service = try language.Service.initDefault(allocator);
    defer service.deinit();
    _ = try service.open(11, zig_source, 40, "zig");

    const marker = "    return a + b;";
    const insert_at = std.mem.indexOf(u8, zig_source, marker) orelse return error.TestUnexpectedResult;
    const insertion = "    const tmp = a;\n";

    var updated: std.ArrayList(u8) = .empty;
    defer updated.deinit(allocator);
    try updated.appendSlice(allocator, zig_source[0..insert_at]);
    try updated.appendSlice(allocator, insertion);
    try updated.appendSlice(allocator, zig_source[insert_at..]);

    const start_point = pointAt(zig_source, insert_at);
    const edit = language.Edit{
        .start_byte = @intCast(insert_at),
        .old_end_byte = @intCast(insert_at),
        .new_end_byte = @intCast(insert_at + insertion.len),
        .start_point = start_point,
        .old_end_point = start_point,
        .new_end_point = pointAt(updated.items, insert_at + insertion.len),
    };

    var changed = try service.applyEdit(allocator, 11, updated.items, 41, edit);
    defer changed.deinit();
    try std.testing.expect(changed.items.len > 0);
    try std.testing.expectEqual(@as(?u64, 41), service.revision(11));
    try std.testing.expect(!(try service.summary(11)).has_error);

    var highlights = try service.highlights(allocator, 11);
    defer highlights.deinit();
    try std.testing.expect(hasHighlight(highlights.items, "function"));
}

test "language registry is extensible without editor dependencies" {
    const allocator = std.testing.allocator;
    var registry = try language.Registry.initDefault(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.find("zig") != null);
    try std.testing.expect(registry.findByExtension("zig") != null);
    try std.testing.expect(registry.findByExtension(".zig") != null);
    try std.testing.expect(registry.find("not-a-language") == null);
}

fn hasHighlight(items: []const language.HighlightSpan, capture: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.capture, capture)) return true;
    }
    return false;
}

fn hasSymbol(items: []const language.Symbol, name: []const u8, kind: language.SymbolKind) bool {
    for (items) |item| {
        if (item.kind != kind) continue;
        const actual = item.name orelse continue;
        if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}

fn pointAt(text: []const u8, byte_index: usize) language.Position {
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
