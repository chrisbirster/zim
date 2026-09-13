const std = @import("std");
const scene_module = @import("../scene.zig");
const cell_grid = @import("cell_grid.zig");
const scene_renderer = @import("scene_renderer.zig");

pub const HitTestError = error{
    NodeIdOutOfRange,
    InvalidStyleJson,
};

const StyleSnapshot = struct {
    node_id: scene_module.NodeId,
    original_style: ?[]u8,
};

pub fn hitTest(
    scene: *scene_module.Scene,
    width: usize,
    height: usize,
    x: usize,
    y: usize,
) !?scene_module.NodeId {
    if (width == 0 or height == 0 or x >= width or y >= height) return null;

    var snapshots: std.ArrayList(StyleSnapshot) = .empty;
    try snapshots.ensureTotalCapacity(scene.allocator, scene.nodes.items.len);
    errdefer restoreStyles(scene, &snapshots);

    try injectOwnershipStyles(scene, &snapshots);
    defer restoreStyles(scene, &snapshots);

    var grid = try cell_grid.CellGrid.init(scene.allocator, width, height);
    defer grid.deinit();
    try scene_renderer.render(scene, &grid);

    const cell = grid.get(x, y) orelse return null;
    const rgb = switch (cell.style.background) {
        .rgb => |value| value,
        else => return null,
    };
    const encoded = (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
    if (encoded == 0) return null;
    return @intCast(encoded);
}

fn injectOwnershipStyles(
    scene: *scene_module.Scene,
    snapshots: *std.ArrayList(StyleSnapshot),
) !void {
    for (scene.nodes.items) |*maybe_node| {
        const node = if (maybe_node.*) |*entry| entry else continue;
        if (node.id == 0) continue;
        if (node.id > 0x00ff_ffff) return HitTestError.NodeIdOutOfRange;

        const existing_index = stylePropertyIndex(node);
        const original = if (existing_index) |index| node.properties.items[index].value_json else null;
        const injected = try ownershipStyle(scene.allocator, original, node.id);
        errdefer scene.allocator.free(injected);

        if (existing_index) |index| {
            snapshots.appendAssumeCapacity(.{
                .node_id = node.id,
                .original_style = original,
            });
            node.properties.items[index].value_json = injected;
        } else {
            const name = try scene.allocator.dupe(u8, "style");
            errdefer scene.allocator.free(name);
            try node.properties.append(scene.allocator, .{
                .name = name,
                .value_json = injected,
            });
            snapshots.appendAssumeCapacity(.{
                .node_id = node.id,
                .original_style = null,
            });
        }
    }
}

fn ownershipStyle(
    allocator: std.mem.Allocator,
    original: ?[]const u8,
    node_id: scene_module.NodeId,
) ![]u8 {
    var color_buffer: [7]u8 = undefined;
    color_buffer[0] = '#';
    _ = try std.fmt.bufPrint(color_buffer[1..], "{x:0>6}", .{node_id});

    const existing = original orelse "{}";
    if (existing.len < 2 or existing[0] != '{' or existing[existing.len - 1] != '}') {
        return HitTestError.InvalidStyleJson;
    }

    var inner = existing[1 .. existing.len - 1];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[0])) inner = inner[1..];
    while (inner.len > 0 and std.ascii.isWhitespace(inner[inner.len - 1])) inner = inner[0 .. inner.len - 1];

    if (inner.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"background\":\"{s}\"}}",
            .{color_buffer[0..]},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"background\":\"{s}\",{s}}}",
        .{ color_buffer[0..], inner },
    );
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

test "hit testing uses the renderer's flow bounds and deepest visible node" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "box");
    try scene.createElement(2, "text");
    try scene.createText(3, "X");
    try scene.setPropertyJson(1, "style", "{\"width\":5,\"height\":3,\"padding\":1}");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(2, 3, null);

    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), try hitTest(&scene, 5, 3, 0, 0));
    try std.testing.expectEqual(@as(?scene_module.NodeId, 3), try hitTest(&scene, 5, 3, 1, 1));
    try std.testing.expectEqual(@as(?scene_module.NodeId, null), try hitTest(&scene, 5, 3, 5, 0));

    try std.testing.expectEqualStrings(
        "{\"width\":5,\"height\":3,\"padding\":1}",
        (try scene.getPropertyJson(1, "style")).?,
    );
    try std.testing.expect((try scene.getPropertyJson(2, "style")) == null);
}

test "hit testing follows native overlay z order" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "box");
    try scene.createText(2, "BASE");
    try scene.createElement(3, "box");
    try scene.createText(4, "LOW");
    try scene.createElement(5, "box");
    try scene.createText(6, "TOP");

    try scene.setPropertyJson(1, "style", "{\"width\":4,\"height\":1}");
    try scene.setPropertyJson(3, "style", "{\"position\":\"overlay\",\"zIndex\":1,\"width\":3,\"height\":1}");
    try scene.setPropertyJson(5, "style", "{\"position\":\"overlay\",\"zIndex\":9,\"width\":3,\"height\":1}");

    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(0, 5, null);
    try scene.insertNode(5, 6, null);
    try scene.insertNode(0, 3, null);
    try scene.insertNode(3, 4, null);

    try std.testing.expectEqual(@as(?scene_module.NodeId, 6), try hitTest(&scene, 4, 1, 0, 0));
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), try hitTest(&scene, 4, 1, 3, 0));
}
