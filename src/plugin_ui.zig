const std = @import("std");

pub const Kind = enum {
    plugin,
    completion,
};

pub const Item = struct {
    label: []u8,
    detail: ?[]u8 = null,

    fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.detail) |detail| allocator.free(detail);
        self.* = undefined;
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    kind: Kind = .plugin,
    title: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    selected: usize = 0,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        self.clearItems();
        self.items.deinit(self.allocator);
        self.title.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn show(self: *Model, kind: Kind, title: []const u8, labels: []const []const u8) !void {
        self.clearItems();
        self.title.items.len = 0;
        try self.title.appendSlice(self.allocator, title);
        for (labels) |label| {
            try self.items.append(self.allocator, .{ .label = try self.allocator.dupe(u8, label) });
        }
        self.kind = kind;
        self.selected = 0;
        self.open = true;
        self.revision += 1;
    }

    pub fn close(self: *Model) void {
        if (!self.open) return;
        self.open = false;
        self.revision += 1;
    }

    pub fn move(self: *Model, direction: i8) void {
        if (!self.open or self.items.items.len == 0) return;
        if (direction < 0) {
            self.selected = if (self.selected == 0) self.items.items.len - 1 else self.selected - 1;
        } else {
            self.selected = (self.selected + 1) % self.items.items.len;
        }
        self.revision += 1;
    }

    pub fn selectedLabel(self: *const Model) ?[]const u8 {
        if (!self.open or self.selected >= self.items.items.len) return null;
        return self.items.items[self.selected].label;
    }

    fn clearItems(self: *Model) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.items.len = 0;
    }
};

test "native popup model owns selection independent of Hondo" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.show(.plugin, "Actions", &.{ "one", "two", "three" });
    try std.testing.expect(model.open);
    try std.testing.expectEqualStrings("one", model.selectedLabel().?);
    model.move(1);
    try std.testing.expectEqualStrings("two", model.selectedLabel().?);
    model.move(-1);
    try std.testing.expectEqualStrings("one", model.selectedLabel().?);
    model.close();
    try std.testing.expect(!model.open);
}
