const std = @import("std");
const cell_grid = @import("../render/cell_grid.zig");
const style_module = @import("../render/style.zig");
const capabilities = @import("capabilities.zig");
const control = @import("control.zig");

pub const FrameError = error{
    DimensionMismatch,
};

pub fn encode(allocator: std.mem.Allocator, grid: *const cell_grid.CellGrid) ![]u8 {
    return encodeWithCapabilities(allocator, grid, capabilities.Capabilities.full());
}

pub fn encodeWithCapabilities(
    allocator: std.mem.Allocator,
    grid: *const cell_grid.CellGrid,
    caps: capabilities.Capabilities,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var active_style = style_module.Style{};

    try output.appendSlice(allocator, control.home);
    for (0..grid.height) |y| {
        try output.appendSlice(allocator, control.clear_line);
        for (0..grid.width) |x| {
            try appendCellStyled(allocator, &output, grid.get(x, y).?, caps, &active_style);
        }
        if (y + 1 < grid.height) try output.appendSlice(allocator, "\r\n");
    }
    try resetIfNeeded(allocator, &output, &active_style);

    return output.toOwnedSlice(allocator);
}

pub fn encodeDiff(
    allocator: std.mem.Allocator,
    previous: *const cell_grid.CellGrid,
    current: *const cell_grid.CellGrid,
) ![]u8 {
    return encodeDiffWithCapabilities(allocator, previous, current, capabilities.Capabilities.full());
}

pub fn encodeDiffWithCapabilities(
    allocator: std.mem.Allocator,
    previous: *const cell_grid.CellGrid,
    current: *const cell_grid.CellGrid,
    caps: capabilities.Capabilities,
) ![]u8 {
    if (!previous.sameDimensions(current)) return FrameError.DimensionMismatch;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var active_style = style_module.Style{};

    for (0..current.height) |y| {
        var x: usize = 0;
        while (x < current.width) {
            if (cellsEqual(previous, current, x, y)) {
                x += 1;
                continue;
            }

            var run_start = @min(glyphStart(previous, x, y), glyphStart(current, x, y));
            var run_end = @max(glyphEnd(previous, x, y), glyphEnd(current, x, y));
            x += 1;

            while (x < current.width) {
                if (x < run_end) {
                    if (!cellsEqual(previous, current, x, y)) {
                        run_start = @min(run_start, @min(glyphStart(previous, x, y), glyphStart(current, x, y)));
                        run_end = @max(run_end, @max(glyphEnd(previous, x, y), glyphEnd(current, x, y)));
                    }
                    x += 1;
                    continue;
                }

                if (cellsEqual(previous, current, x, y)) break;
                const next_start = @min(glyphStart(previous, x, y), glyphStart(current, x, y));
                if (next_start > run_end) break;
                run_start = @min(run_start, next_start);
                run_end = @max(run_end, @max(glyphEnd(previous, x, y), glyphEnd(current, x, y)));
                x += 1;
            }

            try appendCursorPosition(allocator, &output, y + 1, run_start + 1);
            for (run_start..run_end) |run_x| {
                try appendCellStyled(allocator, &output, current.get(run_x, y).?, caps, &active_style);
            }
        }
    }
    try resetIfNeeded(allocator, &output, &active_style);

    return output.toOwnedSlice(allocator);
}

fn cellsEqual(
    previous: *const cell_grid.CellGrid,
    current: *const cell_grid.CellGrid,
    x: usize,
    y: usize,
) bool {
    return previous.get(x, y).?.eql(current.get(x, y).?);
}

fn glyphStart(grid: *const cell_grid.CellGrid, x: usize, y: usize) usize {
    const cell = grid.get(x, y).?;
    if (cell.kind == .continuation and x > 0) return x - 1;
    return x;
}

fn glyphEnd(grid: *const cell_grid.CellGrid, x: usize, y: usize) usize {
    const start = glyphStart(grid, x, y);
    const lead = grid.get(start, y).?;
    if (lead.kind == .lead and lead.width == 2) return @min(start + 2, grid.width);
    return @min(start + 1, grid.width);
}

fn appendCursorPosition(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    row: usize,
    column: usize,
) !void {
    const sequence = try std.fmt.allocPrint(allocator, "\x1b[{d};{d}H", .{ row, column });
    defer allocator.free(sequence);
    try output.appendSlice(allocator, sequence);
}

fn appendCellStyled(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    cell: cell_grid.Cell,
    caps: capabilities.Capabilities,
    active_style: *style_module.Style,
) !void {
    if (cell.kind == .continuation) return;
    const desired_style = if (cell.kind == .empty) style_module.Style{} else cell.style;
    try appendStyleTransition(allocator, output, active_style, desired_style, caps);

    switch (cell.kind) {
        .empty => try output.append(allocator, ' '),
        .lead => try output.appendSlice(allocator, cell.grapheme),
        .continuation => unreachable,
    }
}

fn appendStyleTransition(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    active: *style_module.Style,
    desired: style_module.Style,
    caps: capabilities.Capabilities,
) !void {
    if (active.eql(desired)) return;
    if (!active.isDefault()) try output.appendSlice(allocator, control.reset_style);
    if (!desired.isDefault()) {
        try appendAttributes(allocator, output, desired.attributes);
        try appendColor(allocator, output, desired.foreground, true, caps.color_depth);
        try appendColor(allocator, output, desired.background, false, caps.color_depth);
    }
    active.* = desired;
}

fn resetIfNeeded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    active: *style_module.Style,
) !void {
    if (active.isDefault()) return;
    try output.appendSlice(allocator, control.reset_style);
    active.* = .{};
}

fn appendAttributes(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    attrs: style_module.Attributes,
) !void {
    if (attrs.bold) try output.appendSlice(allocator, "\x1b[1m");
    if (attrs.dim) try output.appendSlice(allocator, "\x1b[2m");
    if (attrs.italic) try output.appendSlice(allocator, "\x1b[3m");
    if (attrs.underline) try output.appendSlice(allocator, "\x1b[4m");
    if (attrs.reverse) try output.appendSlice(allocator, "\x1b[7m");
    if (attrs.strikethrough) try output.appendSlice(allocator, "\x1b[9m");
}

fn appendColor(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    color: style_module.Color,
    foreground: bool,
    depth: capabilities.ColorDepth,
) !void {
    if (depth == .mono) return;

    switch (color) {
        .terminal_default => return,
        .ansi => |index| try appendAnsi16(allocator, output, index, foreground),
        .indexed => |index| switch (depth) {
            .mono => {},
            .ansi16 => try appendAnsi16(allocator, output, @intCast(index % 16), foreground),
            .ansi256, .truecolor => try appendIndexed(allocator, output, index, foreground),
        },
        .rgb => |rgb| switch (depth) {
            .mono => {},
            .ansi16 => try appendAnsi16(allocator, output, ansiIndexForRgb(rgb), foreground),
            .ansi256 => try appendIndexed(allocator, output, indexedForRgb(rgb), foreground),
            .truecolor => try appendRgb(allocator, output, rgb, foreground),
        },
    }
}

fn appendAnsi16(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    index: u4,
    foreground: bool,
) !void {
    const normal_base: u8 = if (foreground) 30 else 40;
    const bright_base: u8 = if (foreground) 90 else 100;
    const numeric: u8 = if (index < 8)
        normal_base + @as(u8, index)
    else
        bright_base + @as(u8, index - 8);
    const sequence = try std.fmt.allocPrint(allocator, "\x1b[{d}m", .{numeric});
    defer allocator.free(sequence);
    try output.appendSlice(allocator, sequence);
}

fn appendIndexed(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    index: u8,
    foreground: bool,
) !void {
    const sequence = try std.fmt.allocPrint(
        allocator,
        "\x1b[{d};5;{d}m",
        .{ if (foreground) @as(u8, 38) else @as(u8, 48), index },
    );
    defer allocator.free(sequence);
    try output.appendSlice(allocator, sequence);
}

fn appendRgb(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    rgb: style_module.Rgb,
    foreground: bool,
) !void {
    const sequence = try std.fmt.allocPrint(
        allocator,
        "\x1b[{d};2;{d};{d};{d}m",
        .{ if (foreground) @as(u8, 38) else @as(u8, 48), rgb.r, rgb.g, rgb.b },
    );
    defer allocator.free(sequence);
    try output.appendSlice(allocator, sequence);
}

fn ansiIndexForRgb(rgb: style_module.Rgb) u4 {
    const peak = @max(rgb.r, @max(rgb.g, rgb.b));
    const bright: u4 = if (peak >= 192) 8 else 0;
    const red: u4 = if (rgb.r >= 128) 1 else 0;
    const green: u4 = if (rgb.g >= 128) 2 else 0;
    const blue: u4 = if (rgb.b >= 128) 4 else 0;
    return bright + red + green + blue;
}

fn indexedForRgb(rgb: style_module.Rgb) u8 {
    const red: u8 = @intCast((@as(u16, rgb.r) * 5 + 127) / 255);
    const green: u8 = @intCast((@as(u16, rgb.g) * 5 + 127) / 255);
    const blue: u8 = @intCast((@as(u16, rgb.b) * 5 + 127) / 255);
    return 16 + 36 * red + 6 * green + blue;
}

test "terminal frame redraws every cell-grid row from home" {
    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    try grid.paintUtf8(0, 0, "Hi", 4);
    try grid.paintUtf8(1, 1, "λ", 3);

    const bytes = try encode(std.testing.allocator, &grid);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "\x1b[H\x1b[2KHi  \r\n\x1b[2K λ  ",
        bytes,
    );
}

test "terminal frame emits colors and attributes without repeating SGR for adjacent styled cells" {
    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 3, 1);
    defer grid.deinit();
    const styled = style_module.Style{
        .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .attributes = .{ .bold = true },
    };
    try grid.paintUtf8Styled(0, 0, "AB", 2, styled);

    const bytes = try encodeWithCapabilities(std.testing.allocator, &grid, capabilities.Capabilities.full());
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "\x1b[H\x1b[2K\x1b[1m\x1b[38;2;1;2;3mAB\x1b[0m ",
        bytes,
    );
}

test "terminal colors degrade to configured capability depth" {
    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 1, 1);
    defer grid.deinit();
    try grid.paintUtf8Styled(0, 0, "X", 1, .{ .foreground = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } });

    const mono = try encodeWithCapabilities(std.testing.allocator, &grid, .{ .color_depth = .mono });
    defer std.testing.allocator.free(mono);
    try std.testing.expectEqualStrings("\x1b[H\x1b[2KX\x1b[0m", mono);

    const ansi = try encodeWithCapabilities(std.testing.allocator, &grid, .{ .color_depth = .ansi16 });
    defer std.testing.allocator.free(ansi);
    try std.testing.expect(std.mem.indexOf(u8, ansi, "\x1b[91m") != null);

    const indexed = try encodeWithCapabilities(std.testing.allocator, &grid, .{ .color_depth = .ansi256 });
    defer std.testing.allocator.free(indexed);
    try std.testing.expect(std.mem.indexOf(u8, indexed, "\x1b[38;5;196m") != null);
}

test "terminal diff emits only contiguous changed cell runs" {
    var previous = try cell_grid.CellGrid.init(std.testing.allocator, 5, 2);
    defer previous.deinit();
    var current = try cell_grid.CellGrid.init(std.testing.allocator, 5, 2);
    defer current.deinit();

    try current.paintUtf8(1, 0, "AB", 2);
    try current.set(4, 0, 'Z');
    try current.set(0, 1, 'λ');

    const bytes = try encodeDiff(std.testing.allocator, &previous, &current);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "\x1b[1;2HAB\x1b[1;5HZ\x1b[2;1Hλ",
        bytes,
    );

    try previous.copyFrom(&current);
    const unchanged = try encodeDiff(std.testing.allocator, &previous, &current);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("", unchanged);
}

test "style-only changes participate in terminal diffs" {
    var previous = try cell_grid.CellGrid.init(std.testing.allocator, 1, 1);
    defer previous.deinit();
    var current = try cell_grid.CellGrid.init(std.testing.allocator, 1, 1);
    defer current.deinit();
    try previous.paintUtf8(0, 0, "A", 1);
    try current.paintUtf8Styled(0, 0, "A", 1, .{ .attributes = .{ .underline = true } });

    const bytes = try encodeDiff(std.testing.allocator, &previous, &current);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1b[1;1H\x1b[4mA\x1b[0m", bytes);
}

test "terminal diff replaces a wide glyph with narrow text without stale continuation" {
    var previous = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer previous.deinit();
    var current = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer current.deinit();

    try previous.paintUtf8(0, 0, "界", 4);
    try current.paintUtf8(0, 0, "A", 4);

    const bytes = try encodeDiff(std.testing.allocator, &previous, &current);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1b[1;1HA ", bytes);
}

test "terminal diff never starts inside a wide grapheme" {
    var previous = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer previous.deinit();
    var current = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer current.deinit();

    try previous.paintUtf8(0, 0, "界", 4);
    try current.paintUtf8(0, 0, "語", 4);

    const bytes = try encodeDiff(std.testing.allocator, &previous, &current);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1b[1;1H語", bytes);
}

test "terminal diff rejects grids with different dimensions" {
    var previous = try cell_grid.CellGrid.init(std.testing.allocator, 2, 1);
    defer previous.deinit();
    var current = try cell_grid.CellGrid.init(std.testing.allocator, 3, 1);
    defer current.deinit();

    try std.testing.expectError(
        FrameError.DimensionMismatch,
        encodeDiff(std.testing.allocator, &previous, &current),
    );
}
