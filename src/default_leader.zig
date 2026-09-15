const std = @import("std");
const editor_module = @import("editor.zig");

pub const leader: u21 = ' ';

pub const Action = enum {
    explorer,
    pin_add,
    pin_list,
    zen,
};

pub const State = struct {
    pending: bool = false,

    pub fn reset(self: *State) void {
        self.pending = false;
    }

    pub fn consume(self: *State, editor: *const editor_module.Editor, cp: u21) ?Action {
        if (editor.mode != .normal or editor.commandOpen() or editor.pin_switcher_open or editor.popup.open) {
            self.pending = false;
            return null;
        }

        if (!self.pending) {
            if (cp == leader) self.pending = true;
            return null;
        }

        self.pending = false;
        return switch (cp) {
            'e' => .explorer,
            'a' => .pin_add,
            'h' => .pin_list,
            'z' => .zen,
            else => null,
        };
    }
};

test "default leader recognizes v1 workspace actions" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var state = State{};

    try std.testing.expect(state.consume(&editor, ' ') == null);
    try std.testing.expectEqual(Action.explorer, state.consume(&editor, 'e').?);
    try std.testing.expect(state.consume(&editor, ' ') == null);
    try std.testing.expectEqual(Action.pin_add, state.consume(&editor, 'a').?);
    try std.testing.expect(state.consume(&editor, ' ') == null);
    try std.testing.expectEqual(Action.pin_list, state.consume(&editor, 'h').?);
    try std.testing.expect(state.consume(&editor, ' ') == null);
    try std.testing.expectEqual(Action.zen, state.consume(&editor, 'z').?);
}
