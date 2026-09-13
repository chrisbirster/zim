const std = @import("std");
const uucode = @import("uucode");
const style_module = @import("style.zig");

pub const GridError = error{
    DimensionMismatch,
};

pub const CellKind = enum {
    empty,
    lead,
    continuation,
};

pub const Cell = struct {
    kind: CellKind = .empty,
    grapheme: []const u8 = "",
    width: u2 = 1,
    style: style_module.Style = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.kind == other.kind and
            self.width == other.width and
            self.style.eql(other.style) and
            std.mem.eql(u8, self.grapheme, other.grapheme);
    }
};

pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    storage: std.heap.ArenaAllocator,
    width: usize,
    height: usize,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !CellGrid {
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, Cell{});
        return .{
            .allocator = allocator,
            .storage = std.heap.ArenaAllocator.init(allocator),
            .width = width,
            .height = height,
            .cells = cells,
        };
    }

    pub fn deinit(self: *CellGrid) void {
        self.storage.deinit();
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn clear(self: *CellGrid) void {
        self.storage.deinit();
        self.storage = std.heap.ArenaAllocator.init(self.allocator);
        @memset(self.cells, Cell{});
    }

    pub fn sameDimensions(self: *const CellGrid, other: *const CellGrid) bool {
        return self.width == other.width and self.height == other.height;
    }

    pub fn copyFrom(self: *CellGrid, other: *const CellGrid) !void {
        if (!self.sameDimensions(other)) return GridError.DimensionMismatch;
        self.clear();

        const storage = self.storage.allocator();
        for (other.cells, 0..) |source, index| {
            var copy = source;
            if (source.kind == .lead) {
                copy.grapheme = try storage.dupe(u8, source.grapheme);
            }
            self.cells[index] = copy;
        }
    }

    pub fn set(self: *CellGrid, x: usize, y: usize, codepoint: u21) !void {
        return self.setStyled(x, y, codepoint, .{});
    }

    pub fn setStyled(self: *CellGrid, x: usize, y: usize, codepoint: u21, style: style_module.Style) !void {
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buffer) catch {
            return self.setGraphemeStyled(x, y, "�", 1, style);
        };
        try self.setGraphemeStyled(x, y, buffer[0..len], 1, style);
    }

    pub fn setGrapheme(self: *CellGrid, x: usize, y: usize, grapheme: []const u8, display_width: usize) !void {
        return self.setGraphemeStyled(x, y, grapheme, display_width, .{});
    }

    pub fn setGraphemeStyled(
        self: *CellGrid,
        x: usize,
        y: usize,
        grapheme: []const u8,
        display_width: usize,
        style: style_module.Style,
    ) !void {
        if (x >= self.width or y >= self.height) return;
        if (display_width == 0) {
            try self.appendZeroWidth(x, y, grapheme);
            return;
        }

        const width = @min(display_width, 2);
        if (width == 2 and x + 1 >= self.width) return;

        self.clearGlyphAt(x, y);
        if (width == 2) self.clearGlyphAt(x + 1, y);

        const bytes = try self.storage.allocator().dupe(u8, grapheme);
        self.cells[y * self.width + x] = .{
            .kind = .lead,
            .grapheme = bytes,
            .width = @intCast(width),
            .style = style,
        };
        if (width == 2) {
            self.cells[y * self.width + x + 1] = .{
                .kind = .continuation,
                .width = 0,
                .style = style,
            };
        }
    }

    pub fn get(self: *const CellGrid, x: usize, y: usize) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[y * self.width + x];
    }

    pub fn paintUtf8(self: *CellGrid, start_x: usize, y: usize, text: []const u8, max_width: usize) !void {
        return self.paintUtf8Styled(start_x, y, text, max_width, .{});
    }

    pub fn paintUtf8Styled(
        self: *CellGrid,
        start_x: usize,
        y: usize,
        text: []const u8,
        max_width: usize,
        style: style_module.Style,
    ) !void {
        if (y >= self.height or start_x >= self.width or max_width == 0) return;

        if (!std.unicode.utf8ValidateSlice(text)) {
            var byte_index: usize = 0;
            var column: usize = 0;
            while (byte_index < text.len and column < max_width and start_x + column < self.width) : (byte_index += 1) {
                try self.setGraphemeStyled(start_x + column, y, "�", 1, style);
                column += 1;
            }
            return;
        }

        var iterator = uucode.grapheme.utf8Iterator(text);
        var column: usize = 0;
        while (iterator.nextGrapheme()) |range| {
            const grapheme = text[range.start..range.end];
            const glyph_width = graphemeDisplayWidth(grapheme);
            if (glyph_width == 0) {
                if (column > 0) try self.appendZeroWidth(start_x + column - 1, y, grapheme);
                continue;
            }
            if (column + glyph_width > max_width or start_x + column + glyph_width > self.width) break;
            try self.setGraphemeStyled(start_x + column, y, grapheme, glyph_width, style);
            column += glyph_width;
        }
    }

    pub fn rowUtf8(self: *const CellGrid, allocator: std.mem.Allocator, y: usize) ![]u8 {
        if (y >= self.height) return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        for (0..self.width) |x| {
            const cell = self.cells[y * self.width + x];
            switch (cell.kind) {
                .empty => try output.append(allocator, ' '),
                .lead => try output.appendSlice(allocator, cell.grapheme),
                .continuation => {},
            }
        }

        return output.toOwnedSlice(allocator);
    }

    fn appendZeroWidth(self: *CellGrid, x: usize, y: usize, grapheme: []const u8) !void {
        if (x >= self.width or y >= self.height) return;
        var lead_x = x;
        if (self.cells[y * self.width + lead_x].kind == .continuation) {
            if (lead_x == 0) return;
            lead_x -= 1;
        }
        const index = y * self.width + lead_x;
        if (self.cells[index].kind != .lead) return;

        const previous = self.cells[index].grapheme;
        const combined = try self.storage.allocator().alloc(u8, previous.len + grapheme.len);
        @memcpy(combined[0..previous.len], previous);
        @memcpy(combined[previous.len..], grapheme);
        self.cells[index].grapheme = combined;
    }

    fn clearGlyphAt(self: *CellGrid, x: usize, y: usize) void {
        if (x >= self.width or y >= self.height) return;
        const index = y * self.width + x;
        const cell = self.cells[index];
        switch (cell.kind) {
            .empty => {},
            .lead => {
                self.cells[index] = .{};
                if (cell.width == 2 and x + 1 < self.width) {
                    self.cells[index + 1] = .{};
                }
            },
            .continuation => {
                self.cells[index] = .{};
                if (x > 0) {
                    const lead_index = index - 1;
                    if (self.cells[lead_index].kind == .lead and self.cells[lead_index].width == 2) {
                        self.cells[lead_index] = .{};
                    }
                }
            },
        }
    }
};

pub fn displayWidth(text: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(text)) return text.len;
    var iterator = uucode.grapheme.utf8Iterator(text);
    var total: usize = 0;
    while (iterator.nextGrapheme()) |range| {
        total += graphemeDisplayWidth(text[range.start..range.end]);
    }
    return total;
}

pub fn graphemeDisplayWidth(grapheme: []const u8) usize {
    var iterator = uucode.utf8.Iterator.init(grapheme);
    var width: usize = 0;
    while (iterator.next()) |codepoint| {
        if (codepoint == 0xfe0f or codepoint == 0x20e3 or
            (codepoint >= 0x1f3fb and codepoint <= 0x1f3ff))
        {
            width = @max(width, 2);
            continue;
        }
        if (uucode.get(.wcwidth_zero_in_grapheme, codepoint)) continue;
        width = @max(width, @as(usize, uucode.get(.wcwidth_standalone, codepoint)));
    }
    return @min(width, 2);
}

test "cell grid paints UTF-8 graphemes and clips at the grid boundary" {
    var grid = try CellGrid.init(std.testing.allocator, 5, 2);
    defer grid.deinit();

    try grid.paintUtf8(1, 0, "AλBCDE", 4);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings(" AλBC", row);
}

test "cell equality includes terminal style" {
    var grid = try CellGrid.init(std.testing.allocator, 2, 1);
    defer grid.deinit();
    try grid.paintUtf8Styled(0, 0, "A", 1, .{ .attributes = .{ .bold = true } });

    const styled = grid.get(0, 0).?;
    const plain = Cell{ .kind = .lead, .grapheme = "A", .width = 1 };
    try std.testing.expect(!styled.eql(plain));
}

test "combining marks stay attached to their base grapheme" {
    var grid = try CellGrid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();

    try grid.paintUtf8(0, 0, "e\u{301}x", 4);
    try std.testing.expectEqual(@as(usize, 2), displayWidth("e\u{301}x"));
    try std.testing.expectEqual(CellKind.lead, grid.get(0, 0).?.kind);
    try std.testing.expectEqualStrings("e\u{301}", grid.get(0, 0).?.grapheme);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("e\u{301}x  ", row);
}

test "wide graphemes reserve a styled continuation cell" {
    var grid = try CellGrid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();

    const glyph_style = style_module.Style{ .foreground = .{ .ansi = 1 } };
    try grid.paintUtf8Styled(0, 0, "界A", 4, glyph_style);
    try std.testing.expectEqual(@as(usize, 3), displayWidth("界A"));
    try std.testing.expectEqual(@as(u2, 2), grid.get(0, 0).?.width);
    try std.testing.expectEqual(CellKind.continuation, grid.get(1, 0).?.kind);
    try std.testing.expect(grid.get(1, 0).?.style.eql(glyph_style));
    try std.testing.expectEqualStrings("A", grid.get(2, 0).?.grapheme);
}

test "emoji clusters and flags occupy one wide terminal glyph" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("❤️"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🇺🇸"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👩🏽‍🚀"));
}

test "overwriting a wide continuation clears the whole old glyph" {
    var grid = try CellGrid.init(std.testing.allocator, 3, 1);
    defer grid.deinit();

    try grid.paintUtf8(0, 0, "界", 3);
    try grid.set(1, 0, 'x');
    try std.testing.expectEqual(CellKind.empty, grid.get(0, 0).?.kind);
    try std.testing.expectEqualStrings("x", grid.get(1, 0).?.grapheme);
}

test "cell grid ignores writes outside its bounds" {
    var grid = try CellGrid.init(std.testing.allocator, 2, 1);
    defer grid.deinit();

    try grid.set(99, 99, 'x');
    try std.testing.expectEqual(CellKind.empty, grid.get(0, 0).?.kind);
}

test "cell grid copies matching frames and rejects mismatched dimensions" {
    var source = try CellGrid.init(std.testing.allocator, 3, 1);
    defer source.deinit();
    try source.paintUtf8(0, 0, "Aλ", 3);

    var destination = try CellGrid.init(std.testing.allocator, 3, 1);
    defer destination.deinit();
    try destination.copyFrom(&source);

    const row = try destination.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("Aλ ", row);

    var mismatched = try CellGrid.init(std.testing.allocator, 2, 1);
    defer mismatched.deinit();
    try std.testing.expectError(GridError.DimensionMismatch, mismatched.copyFrom(&source));
}
