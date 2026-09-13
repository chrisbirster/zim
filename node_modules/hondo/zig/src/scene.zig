const std = @import("std");

pub const NodeId = u32;

pub const SceneError = error{
    DuplicateNode,
    MissingNode,
    InvalidAnchor,
    InvalidParent,
    NodeContainsItself,
};

pub const NodeKind = enum {
    root,
    element,
    text,
};

pub const Property = struct {
    name: []u8,
    value_json: []u8,

    fn deinit(self: *Property, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value_json);
    }
};

pub const Node = struct {
    id: NodeId,
    kind: NodeKind,
    type_name: []u8,
    text: ?[]u8 = null,
    parent: ?NodeId = null,
    children: std.ArrayList(NodeId) = .empty,
    properties: std.ArrayList(Property) = .empty,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        if (self.text) |text| allocator.free(text);
        self.children.deinit(allocator);
        for (self.properties.items) |*property| property.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(?Node) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        var scene = Scene{ .allocator = allocator };
        errdefer scene.deinit();

        try scene.nodes.append(allocator, Node{
            .id = 0,
            .kind = .root,
            .type_name = try allocator.dupe(u8, "root"),
        });
        return scene;
    }

    pub fn deinit(self: *Scene) void {
        for (self.nodes.items) |*maybe_node| {
            if (maybe_node.*) |*entry| entry.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createElement(self: *Scene, id: NodeId, type_name: []const u8) !void {
        try self.createNode(id, .element, type_name, null);
    }

    pub fn createText(self: *Scene, id: NodeId, value: []const u8) !void {
        try self.createNode(id, .text, "#text", value);
    }

    pub fn replaceText(self: *Scene, id: NodeId, value: []const u8) !void {
        const entry = try self.getNode(id);
        if (entry.kind != .text) return SceneError.MissingNode;
        if (entry.text) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
            self.allocator.free(existing);
        }
        entry.text = try self.allocator.dupe(u8, value);
    }

    pub fn setPropertyJson(
        self: *Scene,
        id: NodeId,
        name: []const u8,
        value_json: []const u8,
    ) !void {
        const entry = try self.getNode(id);
        for (entry.properties.items) |*property| {
            if (!std.mem.eql(u8, property.name, name)) continue;

            const replacement = try self.allocator.dupe(u8, value_json);
            self.allocator.free(property.value_json);
            property.value_json = replacement;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value_json);
        errdefer self.allocator.free(owned_value);

        try entry.properties.append(self.allocator, .{
            .name = owned_name,
            .value_json = owned_value,
        });
    }

    pub fn getPropertyJson(self: *Scene, id: NodeId, name: []const u8) !?[]const u8 {
        const entry = try self.getNode(id);
        for (entry.properties.items) |property| {
            if (std.mem.eql(u8, property.name, name)) return property.value_json;
        }
        return null;
    }

    pub fn insertNode(self: *Scene, parent_id: NodeId, node_id: NodeId, anchor_id: ?NodeId) !void {
        if (parent_id == node_id) return SceneError.NodeContainsItself;

        const parent = try self.getNode(parent_id);
        _ = try self.getNode(node_id);

        if (anchor_id) |anchor| {
            if (anchor == node_id) return SceneError.InvalidAnchor;
            const anchor_node = try self.getNode(anchor);
            if (anchor_node.parent != parent_id) return SceneError.InvalidAnchor;
        }

        const current_parent = (try self.getNode(node_id)).parent;
        if (current_parent) |old_parent_id| {
            const old_parent = try self.getNode(old_parent_id);
            const old_index = childIndex(old_parent, node_id) orelse return SceneError.InvalidParent;
            _ = old_parent.children.orderedRemove(old_index);
        }

        const insertion_index = if (anchor_id) |anchor|
            childIndex(parent, anchor) orelse return SceneError.InvalidAnchor
        else
            parent.children.items.len;

        try parent.children.insert(self.allocator, insertion_index, node_id);
        (try self.getNode(node_id)).parent = parent_id;
    }

    pub fn removeNode(self: *Scene, parent_id: NodeId, node_id: NodeId) !void {
        const parent = try self.getNode(parent_id);
        const entry = try self.getNode(node_id);
        if (entry.parent != parent_id) return SceneError.InvalidParent;

        const index = childIndex(parent, node_id) orelse return SceneError.InvalidParent;
        _ = parent.children.orderedRemove(index);
        entry.parent = null;
    }

    pub fn getNode(self: *Scene, id: NodeId) SceneError!*Node {
        if (id >= self.nodes.items.len) return SceneError.MissingNode;
        return &(self.nodes.items[id] orelse return SceneError.MissingNode);
    }

    fn createNode(
        self: *Scene,
        id: NodeId,
        kind: NodeKind,
        type_name: []const u8,
        text: ?[]const u8,
    ) !void {
        try self.ensureSlot(id);
        if (self.nodes.items[id] != null) return SceneError.DuplicateNode;

        const owned_type = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(owned_type);

        const owned_text = if (text) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_text) |value| self.allocator.free(value);

        self.nodes.items[id] = Node{
            .id = id,
            .kind = kind,
            .type_name = owned_type,
            .text = owned_text,
        };
    }

    fn ensureSlot(self: *Scene, id: NodeId) !void {
        while (self.nodes.items.len <= id) {
            try self.nodes.append(self.allocator, null);
        }
    }
};

fn childIndex(parent: *const Node, id: NodeId) ?usize {
    for (parent.children.items, 0..) |child_id, index| {
        if (child_id == id) return index;
    }
    return null;
}

test "scene applies create insert replace and remove without changing identities" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "box");
    try scene.createText(2, "Count: 0");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);

    try std.testing.expectEqual(@as(NodeId, 1), scene.nodes.items[0].?.children.items[0]);
    try std.testing.expectEqual(@as(?NodeId, 1), (try scene.getNode(2)).parent);

    try scene.replaceText(2, "Count: 1");
    try std.testing.expectEqualStrings("Count: 1", (try scene.getNode(2)).text.?);

    try scene.removeNode(1, 2);
    try std.testing.expectEqual(@as(usize, 0), (try scene.getNode(1)).children.items.len);
    try std.testing.expectEqual(@as(?NodeId, null), (try scene.getNode(2)).parent);
}

test "scene reorders an existing identity before an anchor" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "a");
    try scene.createElement(2, "b");
    try scene.createElement(3, "c");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(0, 2, null);
    try scene.insertNode(0, 3, null);

    try scene.insertNode(0, 3, 1);

    const root = try scene.getNode(0);
    try std.testing.expectEqualSlices(NodeId, &.{ 3, 1, 2 }, root.children.items);
}

test "scene stores property JSON without assigning presentation semantics" {
    var scene = try Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.createElement(1, "text");
    try scene.setPropertyJson(1, "style", "{\"bold\":true}");
    try std.testing.expectEqualStrings(
        "{\"bold\":true}",
        (try scene.getPropertyJson(1, "style")).?,
    );

    try scene.setPropertyJson(1, "style", "{\"bold\":false}");
    try std.testing.expectEqualStrings(
        "{\"bold\":false}",
        (try scene.getPropertyJson(1, "style")).?,
    );
}
