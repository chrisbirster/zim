const std = @import("std");
const editor_module = @import("../editor.zig");

pub const CommandId = u64;

pub const Context = struct {
    editor: *editor_module.Editor,
    name: []const u8,
    args: []const u8,
    user_data: ?*anyopaque,
};

pub const Callback = *const fn (context: *Context) anyerror!void;

pub const Entry = struct {
    id: CommandId,
    name: []u8,
    description: []u8,
    callback: Callback,
    user_data: ?*anyopaque,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    next_id: CommandId = 1,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.description);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(
        self: *Registry,
        name: []const u8,
        description: []const u8,
        callback: Callback,
        user_data: ?*anyopaque,
    ) !CommandId {
        if (!validName(name)) return error.InvalidCommandName;
        if (self.find(name) != null) return error.CommandAlreadyExists;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_description = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_description);

        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .description = owned_description,
            .callback = callback,
            .user_data = user_data,
        });
        return id;
    }

    pub fn delete(self: *Registry, name: []const u8) bool {
        const index = self.findIndex(name) orelse return false;
        self.removeAt(index);
        return true;
    }

    pub fn deleteById(self: *Registry, id: CommandId) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id == id) {
                self.removeAt(index);
                return true;
            }
        }
        return false;
    }

    pub fn execute(
        self: *Registry,
        editor: *editor_module.Editor,
        name: []const u8,
        args: []const u8,
    ) !void {
        const entry = self.find(name) orelse return error.UnknownCommand;
        const callback = entry.callback;
        const user_data = entry.user_data;
        var context = Context{
            .editor = editor,
            .name = name,
            .args = args,
            .user_data = user_data,
        };
        try callback(&context);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Entry {
        const index = self.findIndex(name) orelse return null;
        return &self.entries.items[index];
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    fn findIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) return index;
        }
        return null;
    }

    fn removeAt(self: *Registry, index: usize) void {
        const removed = self.entries.items[index];
        self.allocator.free(removed.name);
        self.allocator.free(removed.description);
        var cursor = index + 1;
        while (cursor < self.entries.items.len) : (cursor += 1) {
            self.entries.items[cursor - 1] = self.entries.items[cursor];
        }
        self.entries.items.len -= 1;
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |byte, index| {
        const alpha = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
        const digit = byte >= '0' and byte <= '9';
        if (!(alpha or digit or byte == '_' or byte == '-')) return false;
        if (index == 0 and digit) return false;
    }
    return true;
}

const TestState = struct {
    calls: usize = 0,
    last_args: [16]u8 = [_]u8{0} ** 16,
    last_args_len: usize = 0,
};

fn recordCommand(context: *Context) !void {
    const state: *TestState = @ptrCast(@alignCast(context.user_data.?));
    state.calls += 1;
    state.last_args_len = @min(context.args.len, state.last_args.len);
    @memcpy(state.last_args[0..state.last_args_len], context.args[0..state.last_args_len]);
}

test "commands register execute discover and delete" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var state = TestState{};

    const id = try registry.create("Format", "format current buffer", recordCommand, &state);
    try std.testing.expect(id != 0);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqualStrings("format current buffer", registry.find("Format").?.description);
    try registry.execute(&editor, "Format", "range=all");
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqualStrings("range=all", state.last_args[0..state.last_args_len]);
    try std.testing.expectError(error.CommandAlreadyExists, registry.create("Format", "duplicate", recordCommand, &state));
    try std.testing.expect(registry.delete("Format"));
    try std.testing.expectError(error.UnknownCommand, registry.execute(&editor, "Format", ""));
}
