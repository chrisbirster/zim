const std = @import("std");
const scene_module = @import("scene.zig");

pub const FocusError = error{
    NotFocusable,
};

pub const Direction = enum {
    forward,
    backward,
};

pub const Change = struct {
    previous: ?scene_module.NodeId,
    current: ?scene_module.NodeId,
};

pub const Manager = struct {
    focused: ?scene_module.NodeId = null,
    last_request: u64 = 0,

    pub fn set(self: *Manager, scene: *scene_module.Scene, node_id: scene_module.NodeId) !?Change {
        _ = try scene.getNode(node_id);
        if (!try isFocusable(scene, node_id)) return FocusError.NotFocusable;
        if (self.focused == node_id) return null;

        const change = Change{ .previous = self.focused, .current = node_id };
        self.focused = node_id;
        return change;
    }

    pub fn setNearest(
        self: *Manager,
        scene: *scene_module.Scene,
        node_id: scene_module.NodeId,
    ) !?Change {
        var current: ?scene_module.NodeId = node_id;
        while (current) |candidate| {
            const node = try scene.getNode(candidate);
            if (try isFocusable(scene, candidate)) return self.set(scene, candidate);
            current = node.parent;
        }
        return null;
    }

    pub fn syncRequested(self: *Manager, scene: *scene_module.Scene) !?Change {
        var requested_id: ?scene_module.NodeId = null;
        var requested_sequence = self.last_request;

        for (scene.nodes.items) |maybe_node| {
            const node = maybe_node orelse continue;
            if (!try isFocusable(scene, node.id)) continue;
            const raw = (try scene.getPropertyJson(node.id, "focusRequest")) orelse continue;
            const sequence = std.fmt.parseInt(u64, raw, 10) catch continue;
            if (sequence <= requested_sequence) continue;
            requested_sequence = sequence;
            requested_id = node.id;
        }

        const node_id = requested_id orelse return null;
        self.last_request = requested_sequence;
        return self.set(scene, node_id);
    }

    pub fn traverse(
        self: *Manager,
        scene: *scene_module.Scene,
        direction: Direction,
        wrap: bool,
    ) !?Change {
        var first: ?scene_module.NodeId = null;
        var last: ?scene_module.NodeId = null;
        var previous: ?scene_module.NodeId = null;
        var next: ?scene_module.NodeId = null;
        var found_current = false;

        for (scene.nodes.items) |maybe_node| {
            const node = maybe_node orelse continue;
            if (!try isFocusable(scene, node.id)) continue;

            if (first == null) first = node.id;

            if (self.focused) |focused| {
                if (node.id == focused) {
                    found_current = true;
                    previous = last;
                } else if (found_current and next == null) {
                    next = node.id;
                }
            }

            last = node.id;
        }

        const first_id = first orelse return null;
        const focus_target: ?scene_module.NodeId = if (self.focused == null or !found_current)
            switch (direction) {
                .forward => first_id,
                .backward => last,
            }
        else switch (direction) {
            .forward => next orelse if (wrap) first_id else null,
            .backward => previous orelse if (wrap) last else null,
        };

        const target_id = focus_target orelse return null;
        return self.set(scene, target_id);
    }

    pub fn clear(self: *Manager) ?Change {
        const previous = self.focused orelse return null;
        self.focused = null;
        return .{ .previous = previous, .current = null };
    }

    pub fn target(self: *const Manager) ?scene_module.NodeId {
        return self.focused;
    }
};

fn isFocusable(scene: *scene_module.Scene, node_id: scene_module.NodeId) !bool {
    const focusable = (try scene.getPropertyJson(node_id, "focusable")) orelse return false;
    return std.mem.eql(u8, focusable, "true");
}

test "focus manager only targets focusable scene nodes" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "box");
    try scene.createElement(2, "input");
    try scene.setPropertyJson(2, "focusable", "true");

    var manager = Manager{};
    try std.testing.expectError(FocusError.NotFocusable, manager.set(&scene, 1));

    const first = (try manager.set(&scene, 2)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, null), first.previous);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), first.current);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), manager.target());
    try std.testing.expect((try manager.set(&scene, 2)) == null);

    const cleared = manager.clear().?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), cleared.previous);
    try std.testing.expectEqual(@as(?scene_module.NodeId, null), cleared.current);
}

test "focus manager finds the nearest focusable mouse ancestor" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "column");
    try scene.createElement(2, "text");
    try scene.createText(3, "click");
    try scene.setPropertyJson(1, "focusable", "true");
    try scene.insertNode(0, 1, null);
    try scene.insertNode(1, 2, null);
    try scene.insertNode(2, 3, null);

    var manager = Manager{};
    const change = (try manager.setNearest(&scene, 3)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), change.current);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), manager.target());
}

test "focus manager consumes the newest declarative focus request once" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "input");
    try scene.createElement(2, "input");
    try scene.createElement(3, "box");
    try scene.setPropertyJson(1, "focusable", "true");
    try scene.setPropertyJson(2, "focusable", "true");
    try scene.setPropertyJson(1, "focusRequest", "1");
    try scene.setPropertyJson(2, "focusRequest", "2");
    try scene.setPropertyJson(3, "focusRequest", "99");

    var manager = Manager{};
    const first = (try manager.syncRequested(&scene)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), first.current);
    try std.testing.expectEqual(@as(u64, 2), manager.last_request);
    try std.testing.expect((try manager.syncRequested(&scene)) == null);

    try scene.setPropertyJson(1, "focusRequest", "3");
    const second = (try manager.syncRequested(&scene)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 2), second.previous);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), second.current);
}

test "focus manager traverses focusable scene order and wraps" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "input");
    try scene.createElement(2, "box");
    try scene.createElement(3, "input");
    try scene.setPropertyJson(1, "focusable", "true");
    try scene.setPropertyJson(3, "focusable", "true");

    var manager = Manager{};
    const initial = (try manager.traverse(&scene, .forward, true)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), initial.current);

    const forward = (try manager.traverse(&scene, .forward, true)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), forward.previous);
    try std.testing.expectEqual(@as(?scene_module.NodeId, 3), forward.current);

    const wrapped = (try manager.traverse(&scene, .forward, true)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 1), wrapped.current);

    const backward = (try manager.traverse(&scene, .backward, true)).?;
    try std.testing.expectEqual(@as(?scene_module.NodeId, 3), backward.current);
    try std.testing.expect((try manager.traverse(&scene, .forward, false)) == null);
}
