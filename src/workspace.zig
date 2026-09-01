const std = @import("std");
const buffer_module = @import("buffer.zig");

pub const WindowId = u32;
pub const TabId = u32;

pub const SplitAxis = enum {
    horizontal,
    vertical,
};

pub const Window = struct {
    id: WindowId,
    buffer_id: buffer_module.BufferId,
    cursor: usize = 0,
    preferred_column: ?usize = null,
    scroll_line: usize = 0,
};

pub const Split = struct {
    axis: SplitAxis,
    first: usize,
    second: usize,
};

pub const LayoutNode = union(enum) {
    window: WindowId,
    split: Split,
};

pub const TabPage = struct {
    id: TabId,
    window_ids: std.ArrayList(WindowId) = .empty,
    layout_nodes: std.ArrayList(LayoutNode) = .empty,
    root: usize = 0,
    active_window_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, id: TabId, window_id: WindowId) !TabPage {
        var tab = TabPage{ .id = id };
        errdefer tab.deinit(allocator);
        try tab.window_ids.append(allocator, window_id);
        try tab.layout_nodes.append(allocator, .{ .window = window_id });
        return tab;
    }

    pub fn deinit(self: *TabPage, allocator: std.mem.Allocator) void {
        self.window_ids.deinit(allocator);
        self.layout_nodes.deinit(allocator);
        self.* = undefined;
    }

    pub fn activeWindowId(self: *const TabPage) WindowId {
        return self.window_ids.items[self.active_window_index];
    }

    pub fn setActiveWindow(self: *TabPage, window_id: WindowId) bool {
        for (self.window_ids.items, 0..) |candidate, index| {
            if (candidate == window_id) {
                self.active_window_index = index;
                return true;
            }
        }
        return false;
    }

    pub fn cycleWindow(self: *TabPage, delta: i8) void {
        if (self.window_ids.items.len <= 1) return;
        if (delta < 0) {
            self.active_window_index = if (self.active_window_index == 0)
                self.window_ids.items.len - 1
            else
                self.active_window_index - 1;
        } else {
            self.active_window_index = (self.active_window_index + 1) % self.window_ids.items.len;
        }
    }

    pub fn splitActive(
        self: *TabPage,
        allocator: std.mem.Allocator,
        axis: SplitAxis,
        new_window_id: WindowId,
    ) !void {
        const active = self.activeWindowId();
        const leaf = findWindowLeaf(self, self.root, active) orelse return error.WindowNotInLayout;
        const first_index = self.layout_nodes.items.len;
        try self.layout_nodes.append(allocator, .{ .window = active });
        const second_index = self.layout_nodes.items.len;
        try self.layout_nodes.append(allocator, .{ .window = new_window_id });
        self.layout_nodes.items[leaf] = .{ .split = .{
            .axis = axis,
            .first = first_index,
            .second = second_index,
        } };
        try self.window_ids.append(allocator, new_window_id);
        self.active_window_index = self.window_ids.items.len - 1;
    }

    fn findWindowLeaf(self: *const TabPage, node_index: usize, window_id: WindowId) ?usize {
        if (node_index >= self.layout_nodes.items.len) return null;
        return switch (self.layout_nodes.items[node_index]) {
            .window => |candidate| if (candidate == window_id) node_index else null,
            .split => |split| findWindowLeaf(self, split.first, window_id) orelse
                findWindowLeaf(self, split.second, window_id),
        };
    }
};

test "tab page builds a real split layout tree" {
    var tab = try TabPage.init(std.testing.allocator, 1, 10);
    defer tab.deinit(std.testing.allocator);
    try tab.splitActive(std.testing.allocator, .vertical, 11);
    try std.testing.expectEqual(@as(usize, 2), tab.window_ids.items.len);
    try std.testing.expectEqual(@as(WindowId, 11), tab.activeWindowId());
    const root = tab.layout_nodes.items[tab.root].split;
    try std.testing.expectEqual(SplitAxis.vertical, root.axis);
    try std.testing.expectEqual(@as(WindowId, 10), tab.layout_nodes.items[root.first].window);
    try std.testing.expectEqual(@as(WindowId, 11), tab.layout_nodes.items[root.second].window);
}
