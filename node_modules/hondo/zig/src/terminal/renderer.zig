const std = @import("std");
const cell_grid = @import("../render/cell_grid.zig");
const capabilities = @import("capabilities.zig");
const frame = @import("frame.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: cell_grid.CellGrid,
    previous: cell_grid.CellGrid,
    capabilities: capabilities.Capabilities,
    invalidated: bool = true,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Renderer {
        return initWithCapabilities(allocator, width, height, capabilities.detectEnvironment());
    }

    pub fn initWithCapabilities(
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
        caps: capabilities.Capabilities,
    ) !Renderer {
        var current = try cell_grid.CellGrid.init(allocator, width, height);
        errdefer current.deinit();
        var previous = try cell_grid.CellGrid.init(allocator, width, height);
        errdefer previous.deinit();

        return .{
            .allocator = allocator,
            .current = current,
            .previous = previous,
            .capabilities = caps,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.current.deinit();
        self.previous.deinit();
        self.* = undefined;
    }

    pub fn grid(self: *Renderer) *cell_grid.CellGrid {
        return &self.current;
    }

    pub fn invalidate(self: *Renderer) void {
        self.invalidated = true;
    }

    pub fn resize(self: *Renderer, width: usize, height: usize) !bool {
        if (self.current.width == width and self.current.height == height) return false;

        var next_current = try cell_grid.CellGrid.init(self.allocator, width, height);
        errdefer next_current.deinit();
        var next_previous = try cell_grid.CellGrid.init(self.allocator, width, height);
        errdefer next_previous.deinit();

        self.current.deinit();
        self.previous.deinit();
        self.current = next_current;
        self.previous = next_previous;
        self.invalidated = true;
        return true;
    }

    pub fn encode(self: *Renderer) ![]u8 {
        const bytes = if (self.invalidated)
            try frame.encodeWithCapabilities(self.allocator, &self.current, self.capabilities)
        else
            try frame.encodeDiffWithCapabilities(self.allocator, &self.previous, &self.current, self.capabilities);
        errdefer self.allocator.free(bytes);

        try self.previous.copyFrom(&self.current);
        self.invalidated = false;
        return bytes;
    }
};

test "renderer sends a full frame once then incremental cell diffs" {
    var renderer = try Renderer.initWithCapabilities(std.testing.allocator, 4, 1, capabilities.Capabilities.full());
    defer renderer.deinit();

    try renderer.grid().paintUtf8(0, 0, "A", 4);
    const first = try renderer.encode();
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("\x1b[H\x1b[2KA   ", first);

    renderer.grid().clear();
    try renderer.grid().paintUtf8(0, 0, "B", 4);
    const second = try renderer.encode();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("\x1b[1;1HB", second);

    const unchanged = try renderer.encode();
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("", unchanged);
}

test "renderer resize invalidates the previous frame" {
    var renderer = try Renderer.initWithCapabilities(std.testing.allocator, 4, 1, capabilities.Capabilities.full());
    defer renderer.deinit();

    const initial = try renderer.encode();
    std.testing.allocator.free(initial);
    try std.testing.expect(try renderer.resize(2, 1));
    try std.testing.expect(!try renderer.resize(2, 1));

    try renderer.grid().paintUtf8(0, 0, "C", 2);
    const bytes = try renderer.encode();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x1b[H\x1b[2KC ", bytes);
}

test "renderer snapshots capabilities at construction" {
    const caps = capabilities.Capabilities{ .color_depth = .mono };
    var renderer = try Renderer.initWithCapabilities(std.testing.allocator, 1, 1, caps);
    defer renderer.deinit();
    try std.testing.expectEqual(capabilities.ColorDepth.mono, renderer.capabilities.color_depth);
}
