const std = @import("std");
const editor_module = @import("../editor.zig");

pub const KeymapId = u64;

pub const Scope = union(enum) {
    global,
    buffer: editor_module.BufferId,
};

pub const Entry = struct {
    id: KeymapId,
    scope: Scope,
    mode: editor_module.Mode,
    from: u21,
    to: u21,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    next_id: KeymapId = 1,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn set(
        self: *Registry,
        editor: *editor_module.Editor,
        scope: Scope,
        mode: editor_module.Mode,
        from: u21,
        to: u21,
    ) !KeymapId {
        for (self.entries.items) |*entry| {
            if (entry.mode == mode and entry.from == from and scopeEql(entry.scope, scope)) {
                entry.to = to;
                if (scope == .global) try editor.map(mode, from, to);
                return entry.id;
            }
        }

        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .scope = scope,
            .mode = mode,
            .from = from,
            .to = to,
        });
        if (scope == .global) try editor.map(mode, from, to);
        return id;
    }

    pub fn delete(
        self: *Registry,
        editor: *editor_module.Editor,
        scope: Scope,
        mode: editor_module.Mode,
        from: u21,
    ) bool {
        const index = self.findIndex(scope, mode, from) orelse return false;
        removeAt(self, index);
        if (scope == .global) removeEditorGlobal(editor, mode, from);
        return true;
    }

    pub fn find(
        self: *const Registry,
        scope: Scope,
        mode: editor_module.Mode,
        from: u21,
    ) ?Entry {
        const index = self.findIndex(scope, mode, from) orelse return null;
        return self.entries.items[index];
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    pub fn handleKey(
        self: *const Registry,
        editor: *editor_module.Editor,
        incoming: editor_module.Key,
    ) anyerror!editor_module.HandleResult {
        const local = switch (incoming) {
            .codepoint => |from| self.find(.{ .buffer = editor.currentBuffer().id }, editor.mode, from),
            else => null,
        };
        if (local) |mapping| return editor.handleKey(.{ .codepoint = mapping.to });
        return editor.handleKey(incoming);
    }

    fn findIndex(
        self: *const Registry,
        scope: Scope,
        mode: editor_module.Mode,
        from: u21,
    ) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.mode == mode and entry.from == from and scopeEql(entry.scope, scope)) return index;
        }
        return null;
    }

    fn removeAt(self: *Registry, index: usize) void {
        var cursor = index + 1;
        while (cursor < self.entries.items.len) : (cursor += 1) {
            self.entries.items[cursor - 1] = self.entries.items[cursor];
        }
        self.entries.items.len -= 1;
    }
};

fn scopeEql(a: Scope, b: Scope) bool {
    return switch (a) {
        .global => b == .global,
        .buffer => |a_buffer| switch (b) {
            .buffer => |b_buffer| a_buffer == b_buffer,
            .global => false,
        },
    };
}

fn removeEditorGlobal(editor: *editor_module.Editor, mode: editor_module.Mode, from: u21) void {
    for (editor.keymaps.items, 0..) |mapping, index| {
        if (mapping.mode == mode and mapping.from == from) {
            var cursor = index + 1;
            while (cursor < editor.keymaps.items.len) : (cursor += 1) {
                editor.keymaps.items[cursor - 1] = editor.keymaps.items[cursor];
            }
            editor.keymaps.items.len -= 1;
            return;
        }
    }
}

test "global keymaps update the native editor mapping table" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    _ = try registry.set(&editor, .global, .normal, 'z', 'i');
    _ = try editor.handleKey(.{ .codepoint = 'z' });
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);

    editor.mode = .normal;
    try std.testing.expect(registry.delete(&editor, .global, .normal, 'z'));
    _ = try editor.handleKey(.{ .codepoint = 'z' });
    try std.testing.expectEqual(editor_module.Mode.normal, editor.mode);
}

test "buffer-local keymaps resolve before native global mappings" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const buffer_id = editor.currentBuffer().id;
    _ = try registry.set(&editor, .{ .buffer = buffer_id }, .normal, 'z', 'i');
    _ = try registry.handleKey(&editor, .{ .codepoint = 'z' });
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);
}
