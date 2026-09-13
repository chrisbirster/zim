const std = @import("std");
const scene_module = @import("scene.zig");
const cell_grid = @import("render/cell_grid.zig");
const terminal_input = @import("terminal/input.zig");

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Constraints = struct {
    max_width: usize,
    max_height: usize,
};

pub const Bounds = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const InputResult = enum {
    ignored,
    handled,
};

pub const NativeViewError = error{
    DuplicateRegistration,
    UnknownNativeType,
    InvalidNativeType,
    MissingInstance,
};

pub const Context = struct {
    registry: *Registry,
    node_id: scene_module.NodeId,

    pub fn invalidate(self: Context) void {
        self.registry.invalidate(self.node_id);
    }

    pub fn notify(self: Context, payload_json: []const u8) !void {
        try self.registry.queueNotification(self.node_id, payload_json);
    }
};

pub const Component = struct {
    create: *const fn (
        allocator: std.mem.Allocator,
        context: Context,
        props_json: []const u8,
    ) anyerror!?*anyopaque,
    destroy: *const fn (
        allocator: std.mem.Allocator,
        state: ?*anyopaque,
    ) void,
    measure: *const fn (
        state: ?*anyopaque,
        context: Context,
        constraints: Constraints,
    ) anyerror!Size,
    paint: *const fn (
        state: ?*anyopaque,
        context: Context,
        grid: *cell_grid.CellGrid,
        bounds: Bounds,
    ) anyerror!void,
    update_props: ?*const fn (
        state: ?*anyopaque,
        context: Context,
        props_json: []const u8,
    ) anyerror!void = null,
    input: ?*const fn (
        state: ?*anyopaque,
        context: Context,
        event: terminal_input.Event,
    ) anyerror!InputResult = null,
};

const Registration = struct {
    name: []u8,
    component: Component,
};

const Instance = struct {
    node_id: scene_module.NodeId,
    native_type: []u8,
    props_json: []u8,
    component: Component,
    state: ?*anyopaque,
    invalidated: bool = true,
};

pub const Notification = struct {
    node_id: scene_module.NodeId,
    payload_json: []u8,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.payload_json);
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    registrations: std.ArrayList(Registration) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    notifications: std.ArrayList(Notification) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var index = self.instances.items.len;
        while (index > 0) {
            index -= 1;
            self.destroyInstanceAt(index);
        }
        self.instances.deinit(self.allocator);

        for (self.registrations.items) |registration| {
            self.allocator.free(registration.name);
        }
        self.registrations.deinit(self.allocator);

        for (self.notifications.items) |*notification| {
            notification.deinit(self.allocator);
        }
        self.notifications.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, name: []const u8, component: Component) !void {
        if (name.len == 0) return NativeViewError.InvalidNativeType;
        if (self.findRegistration(name) != null) return NativeViewError.DuplicateRegistration;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.registrations.append(self.allocator, .{
            .name = owned_name,
            .component = component,
        });
    }

    pub fn sync(self: *Registry, scene: *scene_module.Scene) !void {
        var existing_index = self.instances.items.len;
        while (existing_index > 0) {
            existing_index -= 1;
            const instance = &self.instances.items[existing_index];
            const attached = isAttached(scene, instance.node_id);
            const current_type = if (attached)
                try nativeType(scene, instance.node_id)
            else
                null;

            if (!attached or current_type == null or
                !std.mem.eql(u8, current_type.?, instance.native_type))
            {
                self.destroyInstanceAt(existing_index);
            }
        }

        for (scene.nodes.items) |maybe_node| {
            const node = maybe_node orelse continue;
            if (node.id == 0 or !isAttached(scene, node.id)) continue;
            const type_name = (try nativeType(scene, node.id)) orelse continue;
            const registration = self.findRegistration(type_name) orelse
                return NativeViewError.UnknownNativeType;
            const props_json = (try scene.getPropertyJson(node.id, "nativeProps")) orelse "{}";

            if (self.findInstanceIndex(node.id)) |index| {
                const instance = &self.instances.items[index];
                if (!std.mem.eql(u8, props_json, instance.props_json)) {
                    const context = Context{ .registry = self, .node_id = node.id };
                    if (instance.component.update_props) |update| {
                        try update(instance.state, context, props_json);
                    }
                    const replacement = try self.allocator.dupe(u8, props_json);
                    self.allocator.free(instance.props_json);
                    instance.props_json = replacement;
                    instance.invalidated = true;
                }
                continue;
            }

            const owned_type = try self.allocator.dupe(u8, type_name);
            errdefer self.allocator.free(owned_type);
            const owned_props = try self.allocator.dupe(u8, props_json);
            errdefer self.allocator.free(owned_props);
            const context = Context{ .registry = self, .node_id = node.id };
            const state = try registration.component.create(self.allocator, context, props_json);
            errdefer registration.component.destroy(self.allocator, state);

            try self.instances.append(self.allocator, .{
                .node_id = node.id,
                .native_type = owned_type,
                .props_json = owned_props,
                .component = registration.component,
                .state = state,
            });
        }
    }

    pub fn measure(
        self: *Registry,
        node_id: scene_module.NodeId,
        constraints: Constraints,
    ) !Size {
        const instance = self.findInstance(node_id) orelse return NativeViewError.MissingInstance;
        return instance.component.measure(
            instance.state,
            .{ .registry = self, .node_id = node_id },
            constraints,
        );
    }

    pub fn paint(
        self: *Registry,
        node_id: scene_module.NodeId,
        grid: *cell_grid.CellGrid,
        bounds: Bounds,
    ) !void {
        const instance = self.findInstance(node_id) orelse return NativeViewError.MissingInstance;
        instance.invalidated = false;
        try instance.component.paint(
            instance.state,
            .{ .registry = self, .node_id = node_id },
            grid,
            bounds,
        );
    }

    pub fn handleInput(
        self: *Registry,
        node_id: scene_module.NodeId,
        event: terminal_input.Event,
    ) !InputResult {
        const instance = self.findInstance(node_id) orelse return NativeViewError.MissingInstance;
        const handler = instance.component.input orelse return .ignored;
        return handler(
            instance.state,
            .{ .registry = self, .node_id = node_id },
            event,
        );
    }

    pub fn invalidate(self: *Registry, node_id: scene_module.NodeId) void {
        if (self.findInstance(node_id)) |entry| entry.invalidated = true;
    }

    pub fn needsRender(self: *const Registry) bool {
        for (self.instances.items) |instance| {
            if (instance.invalidated) return true;
        }
        return false;
    }

    pub fn queueNotification(
        self: *Registry,
        node_id: scene_module.NodeId,
        payload_json: []const u8,
    ) !void {
        const owned_payload = try self.allocator.dupe(u8, payload_json);
        errdefer self.allocator.free(owned_payload);
        try self.notifications.append(self.allocator, .{
            .node_id = node_id,
            .payload_json = owned_payload,
        });
    }

    pub fn takeNotification(self: *Registry) ?Notification {
        if (self.notifications.items.len == 0) return null;
        return self.notifications.orderedRemove(0);
    }

    pub fn instanceCount(self: *const Registry) usize {
        return self.instances.items.len;
    }

    pub fn isNative(self: *const Registry, node_id: scene_module.NodeId) bool {
        return self.findInstanceIndex(node_id) != null;
    }

    pub fn nearestNativeAncestor(
        self: *const Registry,
        scene: *scene_module.Scene,
        node_id: scene_module.NodeId,
    ) !?scene_module.NodeId {
        var current: ?scene_module.NodeId = node_id;
        var remaining = scene.nodes.items.len + 1;
        while (current) |id| {
            if (self.isNative(id)) return id;
            if (remaining == 0) return null;
            remaining -= 1;
            current = (try scene.getNode(id)).parent;
        }
        return null;
    }

    fn findRegistration(self: *const Registry, name: []const u8) ?Registration {
        for (self.registrations.items) |registration| {
            if (std.mem.eql(u8, registration.name, name)) return registration;
        }
        return null;
    }

    fn findInstanceIndex(self: *const Registry, node_id: scene_module.NodeId) ?usize {
        for (self.instances.items, 0..) |instance, index| {
            if (instance.node_id == node_id) return index;
        }
        return null;
    }

    fn findInstance(self: *Registry, node_id: scene_module.NodeId) ?*Instance {
        const index = self.findInstanceIndex(node_id) orelse return null;
        return &self.instances.items[index];
    }

    fn destroyInstanceAt(self: *Registry, index: usize) void {
        const instance = self.instances.orderedRemove(index);
        instance.component.destroy(self.allocator, instance.state);
        self.allocator.free(instance.native_type);
        self.allocator.free(instance.props_json);
    }
};

pub fn nativeType(
    scene: *scene_module.Scene,
    node_id: scene_module.NodeId,
) !?[]const u8 {
    const raw = (try scene.getPropertyJson(node_id, "nativeType")) orelse return null;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
        return NativeViewError.InvalidNativeType;
    }
    const value = raw[1 .. raw.len - 1];
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\\') != null) {
        return NativeViewError.InvalidNativeType;
    }
    return value;
}

pub fn isAttached(scene: *scene_module.Scene, node_id: scene_module.NodeId) bool {
    var current: ?scene_module.NodeId = node_id;
    var remaining = scene.nodes.items.len + 1;
    while (current) |id| {
        if (id == 0) return true;
        if (remaining == 0) return false;
        remaining -= 1;
        const node = scene.getNode(id) catch return false;
        current = node.parent;
    }
    return false;
}

const TestState = struct {
    updates: usize = 0,
    inputs: usize = 0,
};

fn testCreate(
    allocator: std.mem.Allocator,
    context: Context,
    props_json: []const u8,
) !?*anyopaque {
    _ = context;
    _ = props_json;
    const state = try allocator.create(TestState);
    state.* = .{};
    return state;
}

fn testDestroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *TestState = @ptrCast(@alignCast(state_ptr orelse return));
    allocator.destroy(state);
}

fn testMeasure(
    state_ptr: ?*anyopaque,
    context: Context,
    constraints: Constraints,
) !Size {
    _ = state_ptr;
    _ = context;
    try std.testing.expectEqual(@as(usize, 20), constraints.max_width);
    try std.testing.expectEqual(@as(usize, 10), constraints.max_height);
    return .{ .width = 4, .height = 2 };
}

fn testPaint(
    state_ptr: ?*anyopaque,
    context: Context,
    grid: *cell_grid.CellGrid,
    bounds: Bounds,
) !void {
    _ = state_ptr;
    try grid.paintUtf8(bounds.x, bounds.y, "NATIVE", bounds.width);
    context.invalidate();
}

fn testUpdate(state_ptr: ?*anyopaque, context: Context, props_json: []const u8) !void {
    _ = context;
    _ = props_json;
    const state: *TestState = @ptrCast(@alignCast(state_ptr orelse return));
    state.updates += 1;
}

fn testInput(
    state_ptr: ?*anyopaque,
    context: Context,
    event: terminal_input.Event,
) !InputResult {
    const state: *TestState = @ptrCast(@alignCast(state_ptr orelse return .ignored));
    switch (event) {
        .key => |key| switch (key) {
            .enter => {
                state.inputs += 1;
                context.invalidate();
                try context.notify("{\"changed\":true}");
                return .handled;
            },
            else => {},
        },
        else => {},
    }
    return .ignored;
}

const test_component = Component{
    .create = testCreate,
    .destroy = testDestroy,
    .measure = testMeasure,
    .paint = testPaint,
    .update_props = testUpdate,
    .input = testInput,
};

test "NativeView registry owns lifecycle props measurement invalidation and notifications" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "box");
    try scene.setPropertyJson(1, "nativeType", "\"test\"");
    try scene.setPropertyJson(1, "nativeProps", "{\"value\":1}");
    try scene.insertNode(0, 1, null);

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("test", test_component);
    try registry.sync(&scene);
    try std.testing.expectEqual(@as(usize, 1), registry.instanceCount());
    try std.testing.expect(registry.needsRender());

    const measured = try registry.measure(1, .{ .max_width = 20, .max_height = 10 });
    try std.testing.expectEqual(@as(usize, 4), measured.width);
    try std.testing.expectEqual(@as(usize, 2), measured.height);

    const handled = try registry.handleInput(1, .{ .key = .enter });
    try std.testing.expectEqual(InputResult.handled, handled);
    var notification = registry.takeNotification().?;
    defer notification.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(scene_module.NodeId, 1), notification.node_id);
    try std.testing.expectEqualStrings("{\"changed\":true}", notification.payload_json);

    try scene.setPropertyJson(1, "nativeProps", "{\"value\":2}");
    try registry.sync(&scene);
    const state: *TestState = @ptrCast(@alignCast(registry.findInstance(1).?.state.?));
    try std.testing.expectEqual(@as(usize, 1), state.updates);

    var grid = try cell_grid.CellGrid.init(std.testing.allocator, 20, 10);
    defer grid.deinit();
    try registry.paint(1, &grid, .{ .x = 2, .y = 3, .width = 4, .height = 2 });
    try std.testing.expect(registry.needsRender());

    try scene.removeNode(0, 1);
    try registry.sync(&scene);
    try std.testing.expectEqual(@as(usize, 0), registry.instanceCount());
}
