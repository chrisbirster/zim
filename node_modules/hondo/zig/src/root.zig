const std = @import("std");

pub const quickjs = @import("quickjs.zig");
pub const runtime = @import("runtime/quickjs.zig");
pub const native_events = @import("runtime/native_events.zig");
pub const node_events = @import("runtime/node_events.zig");
pub const input_events = @import("runtime/input_events.zig");
pub const native_view_runtime = @import("runtime/native_view_runtime.zig");
pub const focus = @import("focus.zig");
pub const scene = @import("scene.zig");
pub const native_view = @import("native_view.zig");
pub const style = @import("render/style.zig");
pub const cell_grid = @import("render/cell_grid.zig");
pub const scene_renderer = @import("render/scene_renderer.zig");
pub const native_view_renderer = @import("render/native_view_renderer.zig");
pub const hit_test = @import("render/hit_test.zig");
pub const terminal = @import("terminal/mod.zig");
pub const version = "0.1.0-alpha.2";

pub const RuntimeBoundary = enum {
    solid,
    hondo,
    zig,
};

test "foundation exposes a version" {
    try std.testing.expect(version.len > 0);
}

test {
    _ = quickjs;
    _ = runtime;
    _ = native_events;
    _ = node_events;
    _ = input_events;
    _ = native_view_runtime;
    _ = focus;
    _ = scene;
    _ = native_view;
    _ = style;
    _ = cell_grid;
    _ = scene_renderer;
    _ = native_view_renderer;
    _ = hit_test;
    _ = terminal;
}
