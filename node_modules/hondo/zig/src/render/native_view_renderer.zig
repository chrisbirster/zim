const std = @import("std");
const scene_module = @import("../scene.zig");
const native_view = @import("../native_view.zig");
const cell_grid = @import("cell_grid.zig");
const scene_renderer = @import("scene_renderer.zig");

const StyleSnapshot = struct {
    node_id: scene_module.NodeId,
    original_style: ?[]u8,
};

pub fn render(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
    grid: *cell_grid.CellGrid,
) !void {
    try registry.sync(scene);

    var measured: std.ArrayList(StyleSnapshot) = .empty;
    try injectMeasuredStyles(scene, registry, grid.width, grid.height, &measured);
    defer restoreStyles(scene, &measured);

    try scene_renderer.render(scene, grid);

    var bounds_scene = try cloneWithoutHondoOverlays(scene, registry);
    defer bounds_scene.deinit();
    var bounds_map = try ownershipMap(&bounds_scene, grid.width, grid.height);
    defer bounds_map.deinit();
    var visible_map = try ownershipMap(scene, grid.width, grid.height);
    defer visible_map.deinit();

    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (!registry.isNative(node.id)) continue;
        const bounds = boundsForOwner(&bounds_map, node.id) orelse continue;

        var native_grid = try cell_grid.CellGrid.init(scene.allocator, grid.width, grid.height);
        defer native_grid.deinit();
        try registry.paint(node.id, &native_grid, bounds);
        try compositeNative(scene, registry, node.id, grid, &native_grid, &visible_map, bounds);
    }
}

pub fn hitTest(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
    width: usize,
    height: usize,
    x: usize,
    y: usize,
) !?scene_module.NodeId {
    if (width == 0 or height == 0 or x >= width or y >= height) return null;
    try registry.sync(scene);
    var measured: std.ArrayList(StyleSnapshot) = .empty;
    try injectMeasuredStyles(scene, registry, width, height, &measured);
    defer restoreStyles(scene, &measured);

    var map = try ownershipMap(scene, width, height);
    defer map.deinit();
    return decodeOwner(map.get(x, y));
}

fn injectMeasuredStyles(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
    width: usize,
    height: usize,
    snapshots: *std.ArrayList(StyleSnapshot),
) !void {
    try snapshots.ensureTotalCapacity(scene.allocator, scene.nodes.items.len);
    errdefer restoreStyles(scene, snapshots);

    for (scene.nodes.items) |*maybe_node| {
        const node = if (maybe_node.*) |*entry| entry else continue;
        if (!registry.isNative(node.id)) continue;
        const measured = try registry.measure(node.id, .{
            .max_width = width,
            .max_height = height,
        });
        const index = stylePropertyIndex(node);
        const original = if (index) |style_index| node.properties.items[style_index].value_json else null;
        const replacement = try measuredStyle(scene.allocator, original, measured);
        if (replacement == null) continue;
        errdefer scene.allocator.free(replacement.?);

        if (index) |style_index| {
            snapshots.appendAssumeCapacity(.{ .node_id = node.id, .original_style = original });
            node.properties.items[style_index].value_json = replacement.?;
        } else {
            const name = try scene.allocator.dupe(u8, "style");
            errdefer scene.allocator.free(name);
            try node.properties.append(scene.allocator, .{ .name = name, .value_json = replacement.? });
            snapshots.appendAssumeCapacity(.{ .node_id = node.id, .original_style = null });
        }
    }
}

fn measuredStyle(
    allocator: std.mem.Allocator,
    original: ?[]const u8,
    measured: native_view.Size,
) !?[]u8 {
    const source = original orelse "{}";
    if (source.len < 2 or source[0] != '{' or source[source.len - 1] != '}') return error.InvalidStyleJson;
    const has_width = hasJsonKey(source, "width");
    const has_height = hasJsonKey(source, "height");
    if (has_width and has_height) return null;

    var inner = source[1 .. source.len - 1];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[0])) inner = inner[1..];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[inner.len - 1])) inner = inner[0 .. inner.len - 1];

    if (inner.len == 0) {
        if (!has_width and !has_height) return try std.fmt.allocPrint(
            allocator,
            "{{\"width\":{d},\"height\":{d}}}",
            .{ measured.width, measured.height },
        );
        if (!has_width) return try std.fmt.allocPrint(allocator, "{{\"width\":{d}}}", .{measured.width});
        return try std.fmt.allocPrint(allocator, "{{\"height\":{d}}}", .{measured.height});
    }
    if (!has_width and !has_height) return try std.fmt.allocPrint(
        allocator,
        "{{{s},\"width\":{d},\"height\":{d}}}",
        .{ inner, measured.width, measured.height },
    );
    if (!has_width) return try std.fmt.allocPrint(allocator, "{{{s},\"width\":{d}}}", .{ inner, measured.width });
    return try std.fmt.allocPrint(allocator, "{{{s},\"height\":{d}}}", .{ inner, measured.height });
}

fn cloneWithoutHondoOverlays(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
) !scene_module.Scene {
    var clone = try scene_module.Scene.init(scene.allocator);
    errdefer clone.deinit();

    const source_root = try scene.getNode(0);
    for (source_root.properties.items) |property| {
        try clone.setPropertyJson(0, property.name, property.value_json);
    }

    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (node.id == 0 or !native_view.isAttached(scene, node.id)) continue;
        if (try insideHondoOverlay(scene, registry, node.id)) continue;
        switch (node.kind) {
            .text => try clone.createText(node.id, node.text orelse ""),
            else => try clone.createElement(node.id, node.type_name),
        }
        for (node.properties.items) |property| {
            try clone.setPropertyJson(node.id, property.name, property.value_json);
        }
    }

    for (scene.nodes.items) |maybe_parent| {
        const parent = maybe_parent orelse continue;
        if (parent.id != 0 and (!native_view.isAttached(scene, parent.id) or
            try insideHondoOverlay(scene, registry, parent.id))) continue;
        for (parent.children.items) |child_id| {
            if (!native_view.isAttached(scene, child_id)) continue;
            if (try insideHondoOverlay(scene, registry, child_id)) continue;
            _ = clone.getNode(child_id) catch continue;
            try clone.insertNode(parent.id, child_id, null);
        }
    }
    return clone;
}

fn insideHondoOverlay(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
    node_id: scene_module.NodeId,
) !bool {
    var current: ?scene_module.NodeId = node_id;
    var remaining = scene.nodes.items.len + 1;
    while (current) |id| {
        if (remaining == 0) return false;
        remaining -= 1;
        const node = try scene.getNode(id);
        if (!registry.isNative(id)) {
            if (stylePropertyIndex(node)) |index| {
                if (isOverlayStyle(node.properties.items[index].value_json)) return true;
            }
        }
        current = node.parent;
    }
    return false;
}

fn ownershipMap(
    scene: *scene_module.Scene,
    width: usize,
    height: usize,
) !cell_grid.CellGrid {
    var snapshots: std.ArrayList(StyleSnapshot) = .empty;
    try injectOwnershipStyles(scene, &snapshots);
    defer restoreStyles(scene, &snapshots);

    var grid = try cell_grid.CellGrid.init(scene.allocator, width, height);
    errdefer grid.deinit();
    try scene_renderer.render(scene, &grid);
    return grid;
}

fn injectOwnershipStyles(
    scene: *scene_module.Scene,
    snapshots: *std.ArrayList(StyleSnapshot),
) !void {
    try snapshots.ensureTotalCapacity(scene.allocator, scene.nodes.items.len);
    errdefer restoreStyles(scene, snapshots);
    for (scene.nodes.items) |*maybe_node| {
        const node = if (maybe_node.*) |*entry| entry else continue;
        if (node.id == 0 or node.id > 0x00ff_ffff) continue;
        const index = stylePropertyIndex(node);
        const original = if (index) |style_index| node.properties.items[style_index].value_json else null;
        const replacement = try ownershipStyle(scene.allocator, original, node.id);
        errdefer scene.allocator.free(replacement);
        if (index) |style_index| {
            snapshots.appendAssumeCapacity(.{ .node_id = node.id, .original_style = original });
            node.properties.items[style_index].value_json = replacement;
        } else {
            const name = try scene.allocator.dupe(u8, "style");
            errdefer scene.allocator.free(name);
            try node.properties.append(scene.allocator, .{ .name = name, .value_json = replacement });
            snapshots.appendAssumeCapacity(.{ .node_id = node.id, .original_style = null });
        }
    }
}

fn ownershipStyle(
    allocator: std.mem.Allocator,
    original: ?[]const u8,
    node_id: scene_module.NodeId,
) ![]u8 {
    var color: [7]u8 = undefined;
    color[0] = '#';
    _ = try std.fmt.bufPrint(color[1..], "{x:0>6}", .{node_id});
    const source = original orelse "{}";
    if (source.len < 2 or source[0] != '{' or source[source.len - 1] != '}') return error.InvalidStyleJson;
    var inner = source[1 .. source.len - 1];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[0])) inner = inner[1..];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[inner.len - 1])) inner = inner[0 .. inner.len - 1];
    if (inner.len == 0) return std.fmt.allocPrint(
        allocator,
        "{{\"background\":\"{s}\"}}",
        .{color[0..]},
    );
    return std.fmt.allocPrint(
        allocator,
        "{{\"background\":\"{s}\",{s}}}",
        .{ color[0..], inner },
    );
}

fn boundsForOwner(map: *const cell_grid.CellGrid, node_id: scene_module.NodeId) ?native_view.Bounds {
    var min_x = map.width;
    var min_y = map.height;
    var max_x: usize = 0;
    var max_y: usize = 0;
    var found = false;
    for (0..map.height) |y| {
        for (0..map.width) |x| {
            if (decodeOwner(map.get(x, y)) != node_id) continue;
            found = true;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
    }
    if (!found) return null;
    return .{ .x = min_x, .y = min_y, .width = max_x - min_x + 1, .height = max_y - min_y + 1 };
}

fn compositeNative(
    scene: *scene_module.Scene,
    registry: *native_view.Registry,
    native_id: scene_module.NodeId,
    target: *cell_grid.CellGrid,
    native_grid: *const cell_grid.CellGrid,
    visible_map: *const cell_grid.CellGrid,
    bounds: native_view.Bounds,
) !void {
    const max_y = @min(bounds.y +| bounds.height, target.height);
    const max_x = @min(bounds.x +| bounds.width, target.width);

    for (bounds.y..max_y) |y| {
        for (bounds.x..max_x) |x| {
            const owner = decodeOwner(visible_map.get(x, y)) orelse continue;
            if ((try registry.nearestNativeAncestor(scene, owner)) != native_id) continue;
            try target.setStyled(x, y, ' ', .{});
        }
    }
    for (bounds.y..max_y) |y| {
        for (bounds.x..max_x) |x| {
            const owner = decodeOwner(visible_map.get(x, y)) orelse continue;
            if ((try registry.nearestNativeAncestor(scene, owner)) != native_id) continue;
            const source = native_grid.get(x, y) orelse continue;
            if (source.kind != .lead) continue;
            try target.setGraphemeStyled(x, y, source.grapheme, source.width, source.style);
        }
    }
}

fn decodeOwner(cell: ?cell_grid.Cell) ?scene_module.NodeId {
    const entry = cell orelse return null;
    const rgb = switch (entry.style.background) {
        .rgb => |value| value,
        else => return null,
    };
    const encoded = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | @as(u32, rgb.b);
    if (encoded == 0) return null;
    return @intCast(encoded);
}

fn restoreStyles(scene: *scene_module.Scene, snapshots: *std.ArrayList(StyleSnapshot)) void {
    var index = snapshots.items.len;
    while (index > 0) {
        index -= 1;
        const snapshot = snapshots.items[index];
        const node = scene.getNode(snapshot.node_id) catch continue;
        const property_index = stylePropertyIndex(node) orelse continue;
        const property = &node.properties.items[property_index];
        if (snapshot.original_style) |original| {
            scene.allocator.free(property.value_json);
            property.value_json = original;
        } else {
            scene.allocator.free(property.name);
            scene.allocator.free(property.value_json);
            _ = node.properties.orderedRemove(property_index);
        }
    }
    snapshots.deinit(scene.allocator);
    snapshots.* = .empty;
}

fn stylePropertyIndex(node: *const scene_module.Node) ?usize {
    for (node.properties.items, 0..) |property, index| {
        if (std.mem.eql(u8, property.name, "style")) return index;
    }
    return null;
}

fn hasJsonKey(json: []const u8, key: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "\"{s}\"", .{key}) catch return false;
    return std.mem.indexOf(u8, json, needle) != null;
}

fn isOverlayStyle(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"position\":\"overlay\"") != null or
        std.mem.indexOf(u8, json, "\"position\": \"overlay\"") != null;
}

const TestState = struct { bounds: native_view.Bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };

fn testCreate(allocator: std.mem.Allocator, context: native_view.Context, props: []const u8) !?*anyopaque {
    _ = context;
    _ = props;
    const state = try allocator.create(TestState);
    state.* = .{};
    return state;
}
fn testDestroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *TestState = @ptrCast(@alignCast(state_ptr orelse return));
    allocator.destroy(state);
}
fn testMeasure(state_ptr: ?*anyopaque, context: native_view.Context, constraints: native_view.Constraints) !native_view.Size {
    _ = state_ptr;
    _ = context;
    try std.testing.expectEqual(@as(usize, 12), constraints.max_width);
    try std.testing.expectEqual(@as(usize, 4), constraints.max_height);
    return .{ .width = 6, .height = 2 };
}
fn testPaint(state_ptr: ?*anyopaque, context: native_view.Context, grid: *cell_grid.CellGrid, bounds: native_view.Bounds) !void {
    _ = context;
    const state: *TestState = @ptrCast(@alignCast(state_ptr orelse return));
    state.bounds = bounds;
    try grid.paintUtf8(bounds.x, bounds.y, "NATIVE", bounds.width);
    if (bounds.height > 1) try grid.paintUtf8(bounds.x, bounds.y + 1, "view", bounds.width);
}
const test_component = native_view.Component{
    .create = testCreate,
    .destroy = testDestroy,
    .measure = testMeasure,
    .paint = testPaint,
};

test "NativeView measurement participates in Hondo flow and native paint uses final bounds" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "column");
    try scene.createElement(2, "box");
    try scene.createText(3, "after");
    try scene.setPropertyJson(2, "nativeType", "\"editor\"");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(1, 3, null);

    var registry = native_view.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("editor", test_component);
    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 12, 4);
    defer grid.deinit();
    try render(&scene, &registry, &grid);

    const row0 = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row0);
    const row1 = try grid.rowUtf8(std.testing.allocator, 1);
    defer std.testing.allocator.free(row1);
    const row2 = try grid.rowUtf8(std.testing.allocator, 2);
    defer std.testing.allocator.free(row2);
    try std.testing.expect(std.mem.startsWith(u8, row0, "NATIVE"));
    try std.testing.expect(std.mem.startsWith(u8, row1, "view"));
    try std.testing.expect(std.mem.startsWith(u8, row2, "after"));
}

test "Hondo overlay remains above NativeView paint" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "box");
    try scene.createElement(2, "box");
    try scene.createText(3, "POP");
    try scene.setPropertyJson(1, "nativeType", "\"editor\"");
    try scene.setPropertyJson(2, "style", "{\"position\":\"overlay\",\"x\":1,\"y\":0,\"zIndex\":9}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(0, 2, null);
    try scene.insertNode(2, 3, null);

    var registry = native_view.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("editor", test_component);
    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 12, 4);
    defer grid.deinit();
    try render(&scene, &registry, &grid);

    const row = try grid.rowUtf8(std.testing.allocator, 0);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.startsWith(u8, row, "NPOPVE"));
}
