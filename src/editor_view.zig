const std = @import("std");
const hondo = @import("hondo");
const editor_module = @import("editor.zig");

pub const native_type = "zim.editor";

const BindError = error{NoBoundEditor};

var bound_editor: ?*editor_module.Editor = null;

const State = struct {
    editor: *editor_module.Editor,
    scroll_line: usize = 0,
    last_bounds: hondo.native_view.Bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    has_bounds: bool = false,
};

pub fn bind(editor: *editor_module.Editor) hondo.native_view.Component {
    bound_editor = editor;
    return component;
}

pub fn unbind(editor: *editor_module.Editor) void {
    if (bound_editor == editor) bound_editor = null;
}

fn create(
    allocator: std.mem.Allocator,
    context: hondo.native_view.Context,
    props_json: []const u8,
) !?*anyopaque {
    _ = context;
    _ = props_json;
    const editor = bound_editor orelse return BindError.NoBoundEditor;
    const state = try allocator.create(State);
    state.* = .{ .editor = editor };
    return state;
}

fn destroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
    allocator.destroy(state);
}

fn measure(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    constraints: hondo.native_view.Constraints,
) !hondo.native_view.Size {
    _ = state_ptr;
    _ = context;
    return .{
        .width = constraints.max_width,
        .height = if (constraints.max_height > 2) constraints.max_height - 2 else constraints.max_height,
    };
}

fn paint(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    grid: *hondo.cell_grid.CellGrid,
    bounds: hondo.native_view.Bounds,
) !void {
    _ = context;
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
    state.last_bounds = bounds;
    state.has_bounds = true;
    ensureCursorVisible(state, bounds.height);

    const text = state.editor.text();
    var line_start = byteOffsetForLine(text, state.scroll_line);
    var row: usize = 0;
    while (row < bounds.height) : (row += 1) {
        if (line_start > text.len) break;
        const end = lineEnd(text, line_start);
        const line = text[line_start..end];
        try grid.paintUtf8(bounds.x, bounds.y + row, line, bounds.width);

        if (state.editor.cursor >= line_start and state.editor.cursor <= end) {
            const cursor_in_line = @min(state.editor.cursor - line_start, line.len);
            const cursor_column = hondo.cell_grid.displayWidth(line[0..cursor_in_line]);
            if (cursor_column < bounds.width) {
                try grid.setStyled(
                    bounds.x + cursor_column,
                    bounds.y + row,
                    ' ',
                    .{ .attributes = .{ .reverse = true } },
                );
            }
        }

        if (end >= text.len) {
            if (row == 0 and line.len == 0 and bounds.width > 0) {
                try grid.paintUtf8Styled(
                    bounds.x,
                    bounds.y,
                    "[No Name] — press i to insert",
                    bounds.width,
                    .{ .attributes = .{ .dim = true } },
                );
            }
            break;
        }
        line_start = end + 1;
    }
}

fn updateProps(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    props_json: []const u8,
) !void {
    _ = state_ptr;
    _ = context;
    _ = props_json;
}

fn input(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    event: hondo.terminal.input.Event,
) !hondo.native_view.InputResult {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return .ignored));
    return switch (event) {
        .key => |key| try handleKey(state, context, key),
        .mouse => |mouse| try handleMouse(state, context, mouse),
        .focus => .ignored,
    };
}

fn handleKey(
    state: *State,
    context: hondo.native_view.Context,
    key: hondo.terminal.input.Key,
) !hondo.native_view.InputResult {
    var handled = true;
    var publish = false;

    switch (state.editor.mode) {
        .normal => switch (key) {
            .codepoint => |codepoint| switch (codepoint) {
                'i' => {
                    state.editor.enterInsert();
                    publish = true;
                },
                ':' => {
                    try publishState(state, context, true);
                },
                'h' => {
                    _ = state.editor.moveLeft();
                    publish = true;
                },
                'j' => {
                    _ = state.editor.moveDown();
                    publish = true;
                },
                'k' => {
                    _ = state.editor.moveUp();
                    publish = true;
                },
                'l' => {
                    _ = state.editor.moveRight();
                    publish = true;
                },
                else => handled = false,
            },
            .left => {
                _ = state.editor.moveLeft();
                publish = true;
            },
            .right => {
                _ = state.editor.moveRight();
                publish = true;
            },
            .up => {
                _ = state.editor.moveUp();
                publish = true;
            },
            .down => {
                _ = state.editor.moveDown();
                publish = true;
            },
            .escape => {},
            else => handled = false,
        },
        .insert => switch (key) {
            .escape => {
                state.editor.enterNormal();
                publish = true;
            },
            .backspace => {
                _ = state.editor.backspace();
                publish = true;
            },
            .enter => {
                try state.editor.insertNewline();
                publish = true;
            },
            .tab => try state.editor.insertCodepoint('\t'),
            .left => {
                _ = state.editor.moveLeft();
                publish = true;
            },
            .right => {
                _ = state.editor.moveRight();
                publish = true;
            },
            .up => {
                _ = state.editor.moveUp();
                publish = true;
            },
            .down => {
                _ = state.editor.moveDown();
                publish = true;
            },
            .codepoint => |codepoint| {
                if (codepoint < 0x20) {
                    handled = false;
                } else {
                    try state.editor.insertCodepoint(codepoint);
                }
            },
            else => handled = false,
        },
    }

    if (!handled) return .ignored;
    ensureCursorVisible(state, state.last_bounds.height);
    context.invalidate();
    if (publish) try publishState(state, context, false);
    return .handled;
}

fn handleMouse(
    state: *State,
    context: hondo.native_view.Context,
    mouse: hondo.terminal.input.MouseEvent,
) !hondo.native_view.InputResult {
    if (mouse.action == .scroll) {
        switch (mouse.button) {
            .wheel_up => state.scroll_line -|= 1,
            .wheel_down => state.scroll_line += 1,
            else => return .ignored,
        }
        context.invalidate();
        return .handled;
    }

    if (mouse.button != .left or mouse.action != .press or !state.has_bounds) return .ignored;
    const bounds = state.last_bounds;
    if (mouse.x < bounds.x or mouse.y < bounds.y or
        mouse.x >= bounds.x + bounds.width or mouse.y >= bounds.y + bounds.height)
    {
        return .ignored;
    }

    const line_index = state.scroll_line + (mouse.y - bounds.y);
    const byte_column = mouse.x - bounds.x;
    state.editor.setCursorFromLineColumn(line_index, byte_column);
    context.invalidate();
    try publishState(state, context, false);
    return .handled;
}

fn publishState(state: *State, context: hondo.native_view.Context, command_open: bool) !void {
    const position = state.editor.cursorPosition();
    const mode = switch (state.editor.mode) {
        .normal => "NORMAL",
        .insert => "INSERT",
    };
    var buffer: [256]u8 = undefined;
    const payload = try std.fmt.bufPrint(
        &buffer,
        "{{\"mode\":\"{s}\",\"line\":{d},\"column\":{d},\"modified\":{},\"revision\":{d},\"commandOpen\":{}}}",
        .{ mode, position.line, position.column, state.editor.buffer.modified, state.editor.buffer.revision, command_open },
    );
    try context.notify(payload);
}

fn ensureCursorVisible(state: *State, viewport_height: usize) void {
    if (viewport_height == 0) return;
    const cursor_line = state.editor.cursorPosition().line - 1;
    if (cursor_line < state.scroll_line) {
        state.scroll_line = cursor_line;
    } else if (cursor_line >= state.scroll_line + viewport_height) {
        state.scroll_line = cursor_line - viewport_height + 1;
    }
}

fn byteOffsetForLine(text: []const u8, line_index: usize) usize {
    var line: usize = 0;
    var index: usize = 0;
    while (line < line_index and index < text.len) : (index += 1) {
        if (text[index] == '\n') line += 1;
    }
    return if (line == line_index) index else text.len;
}

fn lineEnd(text: []const u8, start: usize) usize {
    var end = @min(start, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    return end;
}

const component = hondo.native_view.Component{
    .create = create,
    .destroy = destroy,
    .measure = measure,
    .paint = paint,
    .update_props = updateProps,
    .input = input,
};

test "Zim EditorView handles 10000 insert keys without JavaScript dispatch" {
    var editor = editor_module.Editor.init(std.testing.allocator, null);
    defer editor.deinit();
    editor.enterInsert();
    _ = bind(&editor);
    defer unbind(&editor);

    var scene = try hondo.scene.Scene.init(std.testing.allocator);
    defer scene.deinit();
    try scene.createElement(1, "box");
    try scene.setPropertyJson(1, "nativeType", "\"zim.editor\"");
    try scene.setPropertyJson(1, "focusable", "true");
    try scene.insertNode(0, 1, null);

    var registry = hondo.native_view.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(native_type, component);
    try registry.sync(&scene);

    var focus = hondo.focus.Manager{};
    _ = try focus.set(&scene, 1);
    var runtime = try hondo.runtime.Runtime.init();
    defer runtime.deinit();

    const iterations: usize = 10_000;
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    for (0..iterations) |_| {
        const result = try hondo.native_view_runtime.dispatchInteractive(
            std.testing.allocator,
            &runtime,
            &scene,
            &focus,
            &registry,
            .{ .key = .{ .codepoint = 'x' } },
            80,
            24,
        );
        try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, result.path);
    }
    const end = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectEqual(iterations, editor.text().len);
    try std.testing.expect(start.durationTo(end).raw.toNanoseconds() > 0);
}
