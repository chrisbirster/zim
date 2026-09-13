const std = @import("std");
const quickjs_runtime = @import("quickjs.zig");
const node_events = @import("node_events.zig");
const input_events = @import("input_events.zig");
const scene_module = @import("../scene.zig");
const terminal_input = @import("../terminal/input.zig");
const focus = @import("../focus.zig");
const native_view = @import("../native_view.zig");
const native_view_renderer = @import("../render/native_view_renderer.zig");

pub const DispatchPath = enum {
    native,
    javascript,
    none,
};

pub const DispatchResult = struct {
    result: node_events.Result,
    path: DispatchPath,
};

pub fn dispatchInteractive(
    allocator: std.mem.Allocator,
    runtime: *quickjs_runtime.Runtime,
    scene: *scene_module.Scene,
    manager: *focus.Manager,
    registry: *native_view.Registry,
    event: terminal_input.Event,
    width: usize,
    height: usize,
) !DispatchResult {
    try registry.sync(scene);
    if (try manager.syncRequested(scene)) |change| {
        try input_events.dispatchFocusChange(runtime, change);
    }

    const target = switch (event) {
        .mouse => |mouse| try native_view_renderer.hitTest(
            scene,
            registry,
            width,
            height,
            mouse.x,
            mouse.y,
        ),
        else => manager.target(),
    };

    if (target) |target_id| {
        if (try registry.nearestNativeAncestor(scene, target_id)) |native_id| {
            if (try registry.handleInput(native_id, event) == .handled) {
                if (isPrimaryMousePress(event)) {
                    if (try manager.setNearest(scene, target_id)) |change| {
                        try input_events.dispatchFocusChange(runtime, change);
                    }
                }
                try flushNotifications(runtime, registry);
                if (try manager.syncRequested(scene)) |change| {
                    try input_events.dispatchFocusChange(runtime, change);
                }
                return .{
                    .result = .{ .default_prevented = true },
                    .path = .native,
                };
            }
        }
    }

    const result = if (target) |target_id|
        try input_events.dispatch(allocator, runtime, target_id, event)
    else
        node_events.Result{ .default_prevented = false };

    try applyJavascriptDefaults(runtime, scene, manager, event, result, target);
    try flushNotifications(runtime, registry);
    if (try manager.syncRequested(scene)) |change| {
        try input_events.dispatchFocusChange(runtime, change);
    }

    return .{
        .result = result,
        .path = if (target != null) .javascript else .none,
    };
}

pub fn flushNotifications(
    runtime: *quickjs_runtime.Runtime,
    registry: *native_view.Registry,
) !void {
    while (registry.takeNotification()) |value| {
        var notification = value;
        defer notification.deinit(registry.allocator);
        _ = try node_events.dispatch(
            runtime,
            notification.node_id,
            "nativeState",
            notification.payload_json,
        );
    }
}

fn applyJavascriptDefaults(
    runtime: *quickjs_runtime.Runtime,
    scene: *scene_module.Scene,
    manager: *focus.Manager,
    event: terminal_input.Event,
    result: node_events.Result,
    mouse_target: ?scene_module.NodeId,
) !void {
    var declarative_focus_changed = false;
    if (try manager.syncRequested(scene)) |change| {
        declarative_focus_changed = true;
        try input_events.dispatchFocusChange(runtime, change);
    }
    if (declarative_focus_changed or result.default_prevented) return;

    if (traversalDirection(event)) |direction| {
        if (try manager.traverse(scene, direction, true)) |change| {
            try input_events.dispatchFocusChange(runtime, change);
        }
        return;
    }

    if (isPrimaryMousePress(event)) {
        if (mouse_target) |target| {
            if (try manager.setNearest(scene, target)) |change| {
                try input_events.dispatchFocusChange(runtime, change);
            }
        }
    }
}

fn traversalDirection(event: terminal_input.Event) ?focus.Direction {
    return switch (event) {
        .key => |key| switch (key) {
            .tab => .forward,
            .shift_tab => .backward,
            else => null,
        },
        else => null,
    };
}

fn isPrimaryMousePress(event: terminal_input.Event) bool {
    return switch (event) {
        .mouse => |mouse| mouse.button == .left and mouse.action == .press,
        else => false,
    };
}

var benchmark_input_count: usize = 0;

fn benchmarkCreate(
    allocator: std.mem.Allocator,
    context: native_view.Context,
    props_json: []const u8,
) !?*anyopaque {
    _ = allocator;
    _ = context;
    _ = props_json;
    return null;
}

fn benchmarkDestroy(allocator: std.mem.Allocator, state: ?*anyopaque) void {
    _ = allocator;
    _ = state;
}

fn benchmarkMeasure(
    state: ?*anyopaque,
    context: native_view.Context,
    constraints: native_view.Constraints,
) !native_view.Size {
    _ = state;
    _ = context;
    return .{
        .width = @min(@as(usize, 8), constraints.max_width),
        .height = @min(@as(usize, 1), constraints.max_height),
    };
}

fn benchmarkPaint(
    state: ?*anyopaque,
    context: native_view.Context,
    grid: *@import("../render/cell_grid.zig").CellGrid,
    bounds: native_view.Bounds,
) !void {
    _ = state;
    _ = context;
    _ = grid;
    _ = bounds;
}

fn benchmarkInput(
    state: ?*anyopaque,
    context: native_view.Context,
    event: terminal_input.Event,
) !native_view.InputResult {
    _ = state;
    _ = context;
    switch (event) {
        .key => {
            benchmark_input_count += 1;
            return .handled;
        },
        else => return .ignored,
    }
}

const benchmark_component = native_view.Component{
    .create = benchmarkCreate,
    .destroy = benchmarkDestroy,
    .measure = benchmarkMeasure,
    .paint = benchmarkPaint,
    .input = benchmarkInput,
};

test "focused NativeView handles hot-path keys without a JavaScript node dispatcher" {
    var scene = try scene_module.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "box");
    try scene.setPropertyJson(1, "nativeType", "\"benchmark\"");
    try scene.setPropertyJson(1, "focusable", "true");
    try scene.insertNode(0, 1, null);

    var registry = native_view.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register("benchmark", benchmark_component);
    try registry.sync(&scene);

    var manager = focus.Manager{};
    _ = try manager.set(&scene, 1);

    // Intentionally do not install the scene bridge or evaluate a Hondo bundle.
    // Any accidental JS node-event dispatch on this path would fail because
    // __hondoDispatchNodeEvent does not exist in this QuickJS context.
    var runtime = try quickjs_runtime.Runtime.init();
    defer runtime.deinit();

    benchmark_input_count = 0;
    const iterations: usize = 10_000;
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    for (0..iterations) |_| {
        const dispatch = try dispatchInteractive(
            std.testing.allocator,
            &runtime,
            &scene,
            &manager,
            &registry,
            .{ .key = .{ .codepoint = 'x' } },
            80,
            24,
        );
        try std.testing.expectEqual(DispatchPath.native, dispatch.path);
    }
    const end = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const elapsed_ns = start.durationTo(end).raw.toNanoseconds();
    try std.testing.expectEqual(iterations, benchmark_input_count);
    try std.testing.expect(elapsed_ns > 0);
}

test "NativeView notification queue reaches the JavaScript nativeState event surface" {
    var registry = native_view.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.queueNotification(7, "{\"line\":42}");

    var runtime = try quickjs_runtime.Runtime.init();
    defer runtime.deinit();
    try runtime.eval(
        \\globalThis.__hondoDispatchNodeEvent = function(id, type, payload) {
        \\  if (id !== 7 || type !== 'nativeState') throw new Error('wrong native state target');
        \\  const value = JSON.parse(payload);
        \\  if (value.line !== 42) throw new Error('wrong native state payload');
        \\  globalThis.__nativeStateSeen = true;
        \\  return false;
        \\};
    , "native-view-notification-setup.js");

    try flushNotifications(&runtime, &registry);
    try runtime.eval(
        "if (globalThis.__nativeStateSeen !== true) throw new Error('native state not delivered');",
        "native-view-notification-verify.js",
    );
}
