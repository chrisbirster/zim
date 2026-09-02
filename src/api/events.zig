const std = @import("std");
const editor_module = @import("../editor.zig");

pub const AutocmdId = u64;

pub const Kind = enum {
    editor_enter,
    editor_leave,
    buffer_enter,
    buffer_leave,
    buffer_write_pre,
    buffer_write_post,
    text_changed,
    mode_changed,
    window_enter,
    window_leave,
    lsp_attach,
    lsp_detach,
    diagnostics_changed,
};

pub const Event = struct {
    kind: Kind,
    sequence: u64 = 0,
    buffer_id: ?editor_module.BufferId = null,
    window_id: ?editor_module.WindowId = null,
    tab_id: ?editor_module.TabId = null,
};

pub const Options = struct {
    buffer_id: ?editor_module.BufferId = null,
    once: bool = false,
};

pub const Context = struct {
    registry: *Registry,
    editor: *editor_module.Editor,
    event: Event,
    autocmd_id: AutocmdId,
    user_data: ?*anyopaque,
};

pub const Callback = *const fn (context: *Context) anyerror!void;

pub const Entry = struct {
    id: AutocmdId,
    kind: Kind,
    buffer_id: ?editor_module.BufferId,
    once: bool,
    callback: Callback,
    user_data: ?*anyopaque,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    next_id: AutocmdId = 1,
    next_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(
        self: *Registry,
        kind: Kind,
        options: Options,
        callback: Callback,
        user_data: ?*anyopaque,
    ) !AutocmdId {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .buffer_id = options.buffer_id,
            .once = options.once,
            .callback = callback,
            .user_data = user_data,
        });
        return id;
    }

    pub fn delete(self: *Registry, id: AutocmdId) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id == id) {
                removeAt(self, index);
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *Registry, kind: ?Kind) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (kind == null or self.entries.items[index].kind == kind.?) {
                removeAt(self, index);
            } else {
                index += 1;
            }
        }
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    pub fn emit(self: *Registry, editor: *editor_module.Editor, incoming: Event) !void {
        var event = incoming;
        event.sequence = self.next_sequence;
        self.next_sequence += 1;

        var snapshot: std.ArrayList(Entry) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (!matches(entry, event)) continue;
            try snapshot.append(self.allocator, entry);
        }

        for (snapshot.items) |entry| {
            var context = Context{
                .registry = self,
                .editor = editor,
                .event = event,
                .autocmd_id = entry.id,
                .user_data = entry.user_data,
            };
            try entry.callback(&context);
            if (entry.once) _ = self.delete(entry.id);
        }
    }

    fn removeAt(self: *Registry, index: usize) void {
        var cursor = index + 1;
        while (cursor < self.entries.items.len) : (cursor += 1) {
            self.entries.items[cursor - 1] = self.entries.items[cursor];
        }
        self.entries.items.len -= 1;
    }
};

fn matches(entry: Entry, event: Event) bool {
    if (entry.kind != event.kind) return false;
    if (entry.buffer_id) |expected| return event.buffer_id != null and event.buffer_id.? == expected;
    return true;
}

const OrderState = struct {
    values: [16]u8 = [_]u8{0} ** 16,
    len: usize = 0,
    added_late: bool = false,
};

fn appendValue(state: *OrderState, value: u8) void {
    state.values[state.len] = value;
    state.len += 1;
}

fn firstCallback(context: *Context) !void {
    const state: *OrderState = @ptrCast(@alignCast(context.user_data.?));
    appendValue(state, 1);
    if (!state.added_late) {
        state.added_late = true;
        _ = try context.registry.create(.text_changed, .{}, lateCallback, state);
    }
}

fn secondCallback(context: *Context) !void {
    const state: *OrderState = @ptrCast(@alignCast(context.user_data.?));
    appendValue(state, 2);
}

fn lateCallback(context: *Context) !void {
    const state: *OrderState = @ptrCast(@alignCast(context.user_data.?));
    appendValue(state, 3);
}

fn onceCallback(context: *Context) !void {
    const state: *OrderState = @ptrCast(@alignCast(context.user_data.?));
    appendValue(state, 9);
}

test "autocommands dispatch in registration order with snapshot mutation semantics" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var state = OrderState{};

    _ = try registry.create(.text_changed, .{}, firstCallback, &state);
    _ = try registry.create(.text_changed, .{}, secondCallback, &state);
    try registry.emit(&editor, .{ .kind = .text_changed, .buffer_id = editor.currentBuffer().id });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, state.values[0..state.len]);

    state.len = 0;
    try registry.emit(&editor, .{ .kind = .text_changed, .buffer_id = editor.currentBuffer().id });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, state.values[0..state.len]);
}

test "autocommands support buffer filters and once callbacks" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var state = OrderState{};

    const current = editor.currentBuffer().id;
    _ = try registry.create(.buffer_enter, .{ .buffer_id = current, .once = true }, onceCallback, &state);
    try registry.emit(&editor, .{ .kind = .buffer_enter, .buffer_id = current + 100 });
    try std.testing.expectEqual(@as(usize, 0), state.len);
    try registry.emit(&editor, .{ .kind = .buffer_enter, .buffer_id = current });
    try registry.emit(&editor, .{ .kind = .buffer_enter, .buffer_id = current });
    try std.testing.expectEqualSlices(u8, &.{9}, state.values[0..state.len]);
}
