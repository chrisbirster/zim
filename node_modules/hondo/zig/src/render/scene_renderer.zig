const std = @import("std");
const scene_module = @import("../scene.zig");
const cell_grid = @import("cell_grid.zig");
const paint = @import("style.zig");

pub const Direction = enum {
    column,
    row,
};

pub const Align = enum {
    start,
    center,
    end,
    stretch,
};

pub const Justify = enum {
    start,
    center,
    end,
    space_between,
};

pub const Position = enum {
    flow,
    overlay,
};

pub const Edges = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,

    fn horizontal(self: Edges) usize {
        return self.left +| self.right;
    }

    fn vertical(self: Edges) usize {
        return self.top +| self.bottom;
    }
};

pub const LayoutStyle = struct {
    direction: Direction = .column,
    position: Position = .flow,
    x: usize = 0,
    y: usize = 0,
    z_index: usize = 0,
    width: ?usize = null,
    height: ?usize = null,
    min_width: ?usize = null,
    min_height: ?usize = null,
    max_width: ?usize = null,
    max_height: ?usize = null,
    basis: ?usize = null,
    grow: usize = 0,
    shrink: usize = 0,
    gap: usize = 0,
    padding: Edges = .{},
    alignment: Align = .stretch,
    justify: Justify = .start,
    clip: bool = true,
};

const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

const Size = struct {
    width: usize,
    height: usize,
};

const ChildLayout = struct {
    id: scene_module.NodeId,
    style: LayoutStyle,
    measured: Size,
    main: usize,
};

const OverlayLayout = struct {
    id: scene_module.NodeId,
    style: LayoutStyle,
    measured: Size,
};

pub fn render(scene: *scene_module.Scene, grid: *cell_grid.CellGrid) !void {
    grid.clear();
    const viewport = Rect{
        .x = 0,
        .y = 0,
        .width = grid.width,
        .height = grid.height,
    };
    try renderNode(scene, 0, grid, viewport);
    try renderOverlays(scene, grid, viewport);
}

fn renderOverlays(
    scene: *scene_module.Scene,
    grid: *cell_grid.CellGrid,
    viewport: Rect,
) !void {
    var overlays: std.ArrayList(OverlayLayout) = .empty;
    defer overlays.deinit(scene.allocator);

    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (node.id == 0) continue;
        const style = try styleForNode(scene, node.id, node.type_name);
        if (style.position != .overlay) continue;
        try overlays.append(scene.allocator, .{
            .id = node.id,
            .style = style,
            .measured = try measureNode(scene, node.id),
        });
    }

    var i: usize = 0;
    while (i < overlays.items.len) : (i += 1) {
        var j = i + 1;
        while (j < overlays.items.len) : (j += 1) {
            if (overlays.items[j].style.z_index < overlays.items[i].style.z_index) {
                const tmp = overlays.items[i];
                overlays.items[i] = overlays.items[j];
                overlays.items[j] = tmp;
            }
        }
    }

    for (overlays.items) |overlay| {
        const x = @min(overlay.style.x, viewport.width);
        const y = @min(overlay.style.y, viewport.height);
        const available_width = viewport.width - x;
        const available_height = viewport.height - y;
        const width = @min(overlay.measured.width, available_width);
        const height = @min(overlay.measured.height, available_height);
        if (width == 0 or height == 0) continue;

        try renderNode(scene, overlay.id, grid, .{
            .x = viewport.x +| x,
            .y = viewport.y +| y,
            .width = width,
            .height = height,
        });
    }
}

fn renderNode(
    scene: *scene_module.Scene,
    node_id: scene_module.NodeId,
    grid: *cell_grid.CellGrid,
    bounds: Rect,
) !void {
    if (bounds.width == 0 or bounds.height == 0) return;
    const node = try scene.getNode(node_id);

    if (node.kind == .text) {
        if (node.text) |text| {
            try grid.paintUtf8Styled(
                bounds.x,
                bounds.y,
                text,
                bounds.width,
                try terminalStyleForNode(scene, node_id),
            );
        }
        return;
    }

    const layout_style = try styleForNode(scene, node_id, node.type_name);
    const terminal_style = try terminalStyleForNode(scene, node_id);
    if (shouldFillBackground(terminal_style)) try fillRect(grid, bounds, terminal_style);

    const inner = innerRect(bounds, layout_style.padding);
    if (inner.width == 0 or inner.height == 0 or node.children.items.len == 0) return;

    var children: std.ArrayList(ChildLayout) = .empty;
    defer children.deinit(scene.allocator);

    for (node.children.items) |child_id| {
        const child = try scene.getNode(child_id);
        const child_style = try styleForNode(scene, child_id, child.type_name);
        if (child_style.position == .overlay) continue;
        const measured = try measureNode(scene, child_id);
        try children.append(scene.allocator, .{
            .id = child_id,
            .style = child_style,
            .measured = measured,
            .main = mainBase(child_style, measured, layout_style.direction),
        });
    }

    const available_main = mainSize(inner, layout_style.direction);
    if (layout_style.clip) {
        var occupied = totalMain(children.items, layout_style.gap);
        if (occupied < available_main) {
            distributeGrow(children.items, available_main - occupied, layout_style.direction);
        } else if (occupied > available_main) {
            distributeShrink(children.items, occupied - available_main, layout_style.direction);
        }
        occupied = totalMain(children.items, layout_style.gap);
        if (occupied > available_main and children.items.len > 0) {
            const overflow = occupied - available_main;
            const last = &children.items[children.items.len - 1];
            last.main -|= overflow;
        }
    } else {
        const occupied = totalMain(children.items, layout_style.gap);
        if (occupied < available_main) {
            distributeGrow(children.items, available_main - occupied, layout_style.direction);
        }
    }

    const occupied = totalMain(children.items, layout_style.gap);
    const free_main = available_main -| @min(occupied, available_main);
    const justify = justifySpacing(layout_style.justify, free_main, children.items.len);
    var cursor = mainStart(inner, layout_style.direction) +| justify.offset;

    for (children.items, 0..) |child_layout, index| {
        const cross_available = crossSize(inner, layout_style.direction);
        var cross = crossBase(child_layout.style, child_layout.measured, layout_style.direction);
        if (layout_style.alignment == .stretch and explicitCross(child_layout.style, layout_style.direction) == null) {
            cross = cross_available;
        }
        if (layout_style.clip) cross = @min(cross, cross_available);

        const cross_free = cross_available -| @min(cross, cross_available);
        const cross_offset = switch (layout_style.alignment) {
            .start, .stretch => 0,
            .center => cross_free / 2,
            .end => cross_free,
        };

        const child_bounds = switch (layout_style.direction) {
            .row => Rect{
                .x = cursor,
                .y = inner.y +| cross_offset,
                .width = child_layout.main,
                .height = cross,
            },
            .column => Rect{
                .x = inner.x +| cross_offset,
                .y = cursor,
                .width = cross,
                .height = child_layout.main,
            },
        };
        try renderNode(scene, child_layout.id, grid, child_bounds);

        cursor +|= child_layout.main;
        if (index + 1 < children.items.len) {
            cursor +|= layout_style.gap +| justify.between;
            if (index < justify.remainder) cursor +|= 1;
        }
    }
}

fn measureNode(scene: *scene_module.Scene, node_id: scene_module.NodeId) !Size {
    const node = try scene.getNode(node_id);
    const style = try styleForNode(scene, node_id, node.type_name);

    if (node.kind == .text) {
        const natural = Size{
            .width = if (node.text) |text| cell_grid.displayWidth(text) else 0,
            .height = 1,
        };
        return constrainSize(natural, style);
    }

    if (node.children.items.len == 0) {
        return constrainSize(.{
            .width = style.padding.horizontal(),
            .height = style.padding.vertical(),
        }, style);
    }

    var main_total: usize = 0;
    var cross_max: usize = 0;
    var flow_count: usize = 0;
    for (node.children.items) |child_id| {
        const child = try scene.getNode(child_id);
        const child_style = try styleForNode(scene, child_id, child.type_name);
        if (child_style.position == .overlay) continue;
        const measured = try measureNode(scene, child_id);
        if (flow_count > 0) main_total +|= style.gap;
        main_total +|= mainBase(child_style, measured, style.direction);
        cross_max = @max(cross_max, crossBase(child_style, measured, style.direction));
        flow_count += 1;
    }

    const content = switch (style.direction) {
        .row => Size{
            .width = main_total +| style.padding.horizontal(),
            .height = cross_max +| style.padding.vertical(),
        },
        .column => Size{
            .width = cross_max +| style.padding.horizontal(),
            .height = main_total +| style.padding.vertical(),
        },
    };
    return constrainSize(content, style);
}

fn constrainSize(size: Size, style: LayoutStyle) Size {
    return .{
        .width = constrainDimension(size.width, style.width, style.min_width, style.max_width),
        .height = constrainDimension(size.height, style.height, style.min_height, style.max_height),
    };
}

fn constrainDimension(natural: usize, explicit: ?usize, minimum: ?usize, maximum: ?usize) usize {
    var value = explicit orelse natural;
    if (minimum) |limit| value = @max(value, limit);
    if (maximum) |limit| value = @min(value, limit);
    return value;
}

fn mainBase(style: LayoutStyle, measured: Size, direction: Direction) usize {
    var value = style.basis orelse (explicitMain(style, direction) orelse measuredMain(measured, direction));
    if (minMain(style, direction)) |limit| value = @max(value, limit);
    if (maxMain(style, direction)) |limit| value = @min(value, limit);
    return value;
}

fn crossBase(style: LayoutStyle, measured: Size, direction: Direction) usize {
    var value = explicitCross(style, direction) orelse measuredCross(measured, direction);
    if (minCross(style, direction)) |limit| value = @max(value, limit);
    if (maxCross(style, direction)) |limit| value = @min(value, limit);
    return value;
}

fn distributeGrow(children: []ChildLayout, extra: usize, direction: Direction) void {
    var remaining = extra;
    while (remaining > 0) {
        var progressed = false;
        for (children) |*child| {
            var weight = child.style.grow;
            while (weight > 0 and remaining > 0) : (weight -= 1) {
                if (maxMain(child.style, direction)) |limit| {
                    if (child.main >= limit) break;
                }
                child.main +|= 1;
                remaining -= 1;
                progressed = true;
            }
            if (remaining == 0) break;
        }
        if (!progressed) break;
    }
}

fn distributeShrink(children: []ChildLayout, overflow: usize, direction: Direction) void {
    var remaining = overflow;
    while (remaining > 0) {
        var progressed = false;
        for (children) |*child| {
            var weight = child.style.shrink;
            while (weight > 0 and remaining > 0) : (weight -= 1) {
                const minimum = minMain(child.style, direction) orelse 0;
                if (child.main <= minimum) break;
                child.main -= 1;
                remaining -= 1;
                progressed = true;
            }
            if (remaining == 0) break;
        }
        if (!progressed) break;
    }
}

const JustifySpacing = struct {
    offset: usize = 0,
    between: usize = 0,
    remainder: usize = 0,
};

fn justifySpacing(justify: Justify, free: usize, count: usize) JustifySpacing {
    return switch (justify) {
        .start => .{},
        .center => .{ .offset = free / 2 },
        .end => .{ .offset = free },
        .space_between => if (count > 1)
            .{ .between = free / (count - 1), .remainder = free % (count - 1) }
        else
            .{},
    };
}

fn totalMain(children: []const ChildLayout, gap: usize) usize {
    var total: usize = 0;
    for (children) |child| total +|= child.main;
    if (children.len > 1) total +|= gap *| (children.len - 1);
    return total;
}

fn innerRect(bounds: Rect, padding: Edges) Rect {
    const left = @min(padding.left, bounds.width);
    const top = @min(padding.top, bounds.height);
    const horizontal = @min(padding.horizontal(), bounds.width);
    const vertical = @min(padding.vertical(), bounds.height);
    return .{
        .x = bounds.x +| left,
        .y = bounds.y +| top,
        .width = bounds.width - horizontal,
        .height = bounds.height - vertical,
    };
}

fn fillRect(grid: *cell_grid.CellGrid, rect: Rect, style: paint.Style) !void {
    const max_y = @min(rect.y +| rect.height, grid.height);
    const max_x = @min(rect.x +| rect.width, grid.width);
    var y = rect.y;
    while (y < max_y) : (y += 1) {
        var x = rect.x;
        while (x < max_x) : (x += 1) {
            try grid.setStyled(x, y, ' ', style);
        }
    }
}

fn shouldFillBackground(style: paint.Style) bool {
    return switch (style.background) {
        .terminal_default => style.attributes.reverse,
        else => true,
    };
}

fn mainSize(rect: Rect, direction: Direction) usize {
    return if (direction == .row) rect.width else rect.height;
}

fn crossSize(rect: Rect, direction: Direction) usize {
    return if (direction == .row) rect.height else rect.width;
}

fn mainStart(rect: Rect, direction: Direction) usize {
    return if (direction == .row) rect.x else rect.y;
}

fn measuredMain(size: Size, direction: Direction) usize {
    return if (direction == .row) size.width else size.height;
}

fn measuredCross(size: Size, direction: Direction) usize {
    return if (direction == .row) size.height else size.width;
}

fn explicitMain(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.width else style.height;
}

fn explicitCross(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.height else style.width;
}

fn minMain(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.min_width else style.min_height;
}

fn maxMain(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.max_width else style.max_height;
}

fn minCross(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.min_height else style.min_width;
}

fn maxCross(style: LayoutStyle, direction: Direction) ?usize {
    return if (direction == .row) style.max_height else style.max_width;
}

fn styleForNode(
    scene: *scene_module.Scene,
    node_id: scene_module.NodeId,
    type_name: []const u8,
) !LayoutStyle {
    var style = LayoutStyle{};
    if (std.mem.eql(u8, type_name, "row")) style.direction = .row;
    if (std.mem.eql(u8, type_name, "column") or std.mem.eql(u8, type_name, "stack")) style.direction = .column;

    const json = (try scene.getPropertyJson(node_id, "style")) orelse return style;
    if (jsonStringValue(json, "direction")) |direction| {
        if (std.mem.eql(u8, direction, "row")) style.direction = .row;
        if (std.mem.eql(u8, direction, "column")) style.direction = .column;
    }
    if (jsonStringValue(json, "position")) |position| {
        if (std.mem.eql(u8, position, "overlay")) style.position = .overlay;
        if (std.mem.eql(u8, position, "flow")) style.position = .flow;
    }
    style.x = jsonUnsignedValue(json, "x") orelse 0;
    style.y = jsonUnsignedValue(json, "y") orelse 0;
    style.z_index = jsonUnsignedValue(json, "zIndex") orelse 0;
    style.width = jsonUnsignedValue(json, "width");
    style.height = jsonUnsignedValue(json, "height");
    style.min_width = jsonUnsignedValue(json, "minWidth");
    style.min_height = jsonUnsignedValue(json, "minHeight");
    style.max_width = jsonUnsignedValue(json, "maxWidth");
    style.max_height = jsonUnsignedValue(json, "maxHeight");
    style.basis = jsonUnsignedValue(json, "basis");
    style.grow = jsonUnsignedValue(json, "grow") orelse 0;
    style.shrink = jsonUnsignedValue(json, "shrink") orelse 0;
    style.gap = jsonUnsignedValue(json, "gap") orelse 0;
    style.padding = paddingValue(json);
    style.alignment = jsonAlignValue(json, "align") orelse .stretch;
    style.justify = jsonJustifyValue(json, "justify") orelse .start;
    style.clip = jsonBoolValue(json, "clip") orelse true;
    return style;
}

fn paddingValue(json: []const u8) Edges {
    const all = jsonUnsignedValue(json, "padding") orelse 0;
    const horizontal = jsonUnsignedValue(json, "paddingX") orelse all;
    const vertical = jsonUnsignedValue(json, "paddingY") orelse all;
    return .{
        .top = jsonUnsignedValue(json, "paddingTop") orelse vertical,
        .right = jsonUnsignedValue(json, "paddingRight") orelse horizontal,
        .bottom = jsonUnsignedValue(json, "paddingBottom") orelse vertical,
        .left = jsonUnsignedValue(json, "paddingLeft") orelse horizontal,
    };
}

fn terminalStyleForNode(scene: *scene_module.Scene, node_id: scene_module.NodeId) !paint.Style {
    var result = paint.Style{};
    try applyInheritedTerminalStyle(scene, node_id, &result);
    return result;
}

fn applyInheritedTerminalStyle(
    scene: *scene_module.Scene,
    node_id: scene_module.NodeId,
    result: *paint.Style,
) !void {
    const node = try scene.getNode(node_id);
    if (node.parent) |parent| try applyInheritedTerminalStyle(scene, parent, result);
    const json = (try scene.getPropertyJson(node_id, "style")) orelse return;

    if (jsonColorValue(json, "foreground")) |value| result.foreground = value;
    if (jsonColorValue(json, "background")) |value| result.background = value;
    if (jsonBoolValue(json, "bold")) |value| result.attributes.bold = value;
    if (jsonBoolValue(json, "dim")) |value| result.attributes.dim = value;
    if (jsonBoolValue(json, "italic")) |value| result.attributes.italic = value;
    if (jsonBoolValue(json, "underline")) |value| result.attributes.underline = value;
    if (jsonBoolValue(json, "reverse")) |value| result.attributes.reverse = value;
    if (jsonBoolValue(json, "inverse")) |value| result.attributes.reverse = value;
    if (jsonBoolValue(json, "strikethrough")) |value| result.attributes.strikethrough = value;
}

fn jsonAlignValue(json: []const u8, key: []const u8) ?Align {
    const value = jsonStringValue(json, key) orelse return null;
    if (std.mem.eql(u8, value, "start")) return .start;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "end")) return .end;
    if (std.mem.eql(u8, value, "stretch")) return .stretch;
    return null;
}

fn jsonJustifyValue(json: []const u8, key: []const u8) ?Justify {
    const value = jsonStringValue(json, key) orelse return null;
    if (std.mem.eql(u8, value, "start")) return .start;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "end")) return .end;
    if (std.mem.eql(u8, value, "space-between")) return .space_between;
    return null;
}

fn jsonColorValue(json: []const u8, key: []const u8) ?paint.Color {
    if (jsonStringValue(json, key)) |value| return parseColor(value);
    if (jsonUnsignedValue(json, key)) |value| {
        if (value <= 255) return .{ .indexed = @intCast(value) };
    }
    return null;
}

fn parseColor(value: []const u8) ?paint.Color {
    if (std.ascii.eqlIgnoreCase(value, "default")) return .terminal_default;
    const names = [_][]const u8{
        "black",
        "red",
        "green",
        "yellow",
        "blue",
        "magenta",
        "cyan",
        "white",
        "bright-black",
        "bright-red",
        "bright-green",
        "bright-yellow",
        "bright-blue",
        "bright-magenta",
        "bright-cyan",
        "bright-white",
    };
    for (names, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(value, name)) return .{ .ansi = @intCast(index) };
    }

    if (value.len == 7 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }
    return null;
}

fn jsonUnsignedValue(json: []const u8, key: []const u8) ?usize {
    const value_start = jsonValueStart(json, key) orelse return null;
    var end = value_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == value_start) return null;
    return std.fmt.parseInt(usize, json[value_start..end], 10) catch null;
}

fn jsonBoolValue(json: []const u8, key: []const u8) ?bool {
    const value_start = jsonValueStart(json, key) orelse return null;
    if (std.mem.startsWith(u8, json[value_start..], "true")) return true;
    if (std.mem.startsWith(u8, json[value_start..], "false")) return false;
    return null;
}

fn jsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const value_start = jsonValueStart(json, key) orelse return null;
    if (value_start >= json.len or json[value_start] != '"') return null;
    const start = value_start + 1;
    const relative_end = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    return json[start .. start + relative_end];
}

fn jsonValueStart(json: []const u8, key: []const u8) ?usize {
    var pattern_buffer: [128]u8 = undefined;
    if (key.len + 2 > pattern_buffer.len) return null;
    pattern_buffer[0] = '"';
    @memcpy(pattern_buffer[1 .. 1 + key.len], key);
    pattern_buffer[key.len + 1] = '"';
    const pattern = pattern_buffer[0 .. key.len + 2];

    const key_index = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after_key = key_index + pattern.len;
    const colon_relative = std.mem.indexOfScalar(u8, json[after_key..], ':') orelse return null;
    var value_start = after_key + colon_relative + 1;
    while (value_start < json.len and std.ascii.isWhitespace(json[value_start])) : (value_start += 1) {}
    return value_start;
}

test "scene renderer lays out a row with gap and clips text" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "row");
    try scene.createText(2, "ABC");
    try scene.createText(3, "XYZ");
    try scene.setPropertyJson(1, "style", "{\"gap\":1,\"width\":6}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 6, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("ABC XY", row);
}

test "scene renderer composes columns and honors explicit child width" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "column");
    try scene.createText(2, "first");
    try scene.createText(3, "second");
    try scene.setPropertyJson(2, "style", "{\"width\":3}");
    try scene.setPropertyJson(1, "style", "{\"gap\":1}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 6, 3);
    defer grid.deinit();
    try render(&scene, &grid);

    const first = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const spacer = try grid.rowUtf8(std.testing.allocator, 1);
    defer std.testing.allocator.free(spacer);
    const second = try grid.rowUtf8(std.testing.allocator, 2);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("fir   ", first);
    try std.testing.expectEqualStrings("      ", spacer);
    try std.testing.expectEqualStrings("second", second);
}

test "row layout uses terminal display width for wide text" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "row");
    try scene.createText(2, "界");
    try scene.createText(3, "A");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("界A ", row);
    try std.testing.expectEqual(cell_grid.CellKind.continuation, grid.get(1, 0).?.kind);
}

test "scene renderer maps inherited terminal colors and attributes from element style" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "text");
    try scene.createText(2, "Hi");
    try scene.setPropertyJson(
        1,
        "style",
        "{\"foreground\":\"#12abef\",\"background\":4,\"bold\":true,\"underline\":true}",
    );
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 2, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const cell = grid.get(0, 0).?;
    try std.testing.expect(cell.style.foreground.eql(.{
        .rgb = .{ .r = 0x12, .g = 0xab, .b = 0xef },
    }));
    try std.testing.expect(cell.style.background.eql(.{ .indexed = 4 }));
    try std.testing.expect(cell.style.attributes.bold);
    try std.testing.expect(cell.style.attributes.underline);
}

test "row grow distributes remaining terminal columns to spacer" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "row");
    try scene.createText(2, "A");
    try scene.createElement(3, "spacer");
    try scene.createText(4, "B");
    try scene.setPropertyJson(1, "style", "{\"width\":10}");
    try scene.setPropertyJson(3, "style", "{\"basis\":0,\"grow\":1}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);
    try scene.insertNode(1, 4, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 10, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("A        B", row);
}

test "padding and center alignment position content inside explicit bounds" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "column");
    try scene.createText(2, "X");
    try scene.setPropertyJson(1, "style", "{\"width\":10,\"height\":3,\"padding\":1,\"align\":\"center\"}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 10, 3);
    defer grid.deinit();
    try render(&scene, &grid);

    const middle = try grid.rowUtf8(std.testing.allocator, 1);
    defer std.testing.allocator.free(middle);
    try std.testing.expectEqualStrings("    X     ", middle);
}

test "min max shrink and clip semantics bound overflowing row children" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "row");
    try scene.createText(2, "abcdef");
    try scene.createText(3, "Z");
    try scene.setPropertyJson(1, "style", "{\"width\":5}");
    try scene.setPropertyJson(2, "style", "{\"minWidth\":3,\"maxWidth\":6,\"shrink\":1}");
    try scene.setPropertyJson(3, "style", "{\"shrink\":0}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 5, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("abcdZ", row);
}

test "clip false permits child content to paint beyond parent main size" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "row");
    try scene.createText(2, "ABC");
    try scene.setPropertyJson(1, "style", "{\"width\":2,\"clip\":false}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("ABC ", row);
}

test "overlay nodes do not consume flow space and paint at viewport coordinates" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "text");
    try scene.createText(2, "BASE");
    try scene.createElement(3, "box");
    try scene.createElement(4, "text");
    try scene.createText(5, "POP");
    try scene.setPropertyJson(3, "style", "{\"position\":\"overlay\",\"x\":1,\"y\":0,\"width\":3,\"height\":1}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(0, 3, null);
    try scene.insertNode(3, 4, null);
    try scene.insertNode(4, 5, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 4, 2);
    defer grid.deinit();
    try render(&scene, &grid);

    const first = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(first);
    const second = try grid.rowUtf8(std.testing.allocator, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("BPOP", first);
    try std.testing.expectEqualStrings("    ", second);
}

test "overlay zIndex paints higher layers last regardless of scene insertion order" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "box");
    try scene.createElement(2, "text");
    try scene.createText(3, "TOP");
    try scene.createElement(4, "box");
    try scene.createElement(5, "text");
    try scene.createText(6, "LOW");
    try scene.setPropertyJson(1, "style", "{\"position\":\"overlay\",\"zIndex\":9,\"width\":3,\"height\":1}");
    try scene.setPropertyJson(4, "style", "{\"position\":\"overlay\",\"zIndex\":1,\"width\":3,\"height\":1}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(2, 3, null);
    try scene.insertNode(0, 4, null);
    try scene.insertNode(4, 5, null);
    try scene.insertNode(5, 6, null);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 3, 1);
    defer grid.deinit();
    try render(&scene, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expectEqualStrings("TOP", row);
}
