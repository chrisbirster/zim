const std = @import("std");
const hondo = @import("hondo");
const editor_module = @import("editor.zig");

pub const native_type = "zim.editor";

const BindError = error{NoBoundEditor};
const gutter_width: usize = 6;
const scrolloff: usize = 8;

var bound_editor: ?*editor_module.Editor = null;

const State = struct {
    editor: *editor_module.Editor,
    last_bounds: hondo.native_view.Bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    has_bounds: bool = false,
};

const CoarseState = struct {
    mode: editor_module.Mode,
    command_open: bool,
    buffer_id: editor_module.BufferId,
    window_id: editor_module.WindowId,
    modified: bool,
    buffer_count: usize,
    window_count: usize,
    tab_count: usize,
    quit_requested: bool,
    status_hash: u64,
};

const WindowHit = struct {
    window_id: editor_module.WindowId,
    bounds: hondo.native_view.Bounds,
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
    return .{ .width = constraints.max_width, .height = constraints.max_height };
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
    const tab = state.editor.activeTabConst();
    try paintLayout(state.editor, grid, tab, tab.root, bounds);
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
    const translated = translateKey(key) orelse return .ignored;
    const before = captureCoarseState(state.editor);
    const result = try state.editor.handleKey(translated);
    if (!result.handled) return .ignored;
    context.invalidate();
    const after = captureCoarseState(state.editor);
    if (shouldPublishKeyState(before, after)) try publishState(state, context);
    return .handled;
}

fn captureCoarseState(editor: *const editor_module.Editor) CoarseState {
    const window = editor.currentWindowConst();
    return .{
        .mode = editor.mode,
        .command_open = editor.commandOpen(),
        .buffer_id = window.buffer_id,
        .window_id = window.id,
        .modified = editor.currentBufferConst().modified,
        .buffer_count = editor.buffers.items.len,
        .window_count = editor.activeTabConst().window_ids.items.len,
        .tab_count = editor.tabs.items.len,
        .quit_requested = editor.quit_requested,
        .status_hash = hashBytes(editor.status()),
    };
}

fn shouldPublishKeyState(before: CoarseState, after: CoarseState) bool {
    if (before.mode == .command_line or after.mode == .command_line) return true;
    if (before.mode == .insert and after.mode == .insert) return false;
    return before.mode != after.mode or
        before.command_open != after.command_open or
        before.buffer_id != after.buffer_id or
        before.window_id != after.window_id or
        before.modified != after.modified or
        before.buffer_count != after.buffer_count or
        before.window_count != after.window_count or
        before.tab_count != after.tab_count or
        before.quit_requested != after.quit_requested or
        before.status_hash != after.status_hash;
}

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn translateKey(key: hondo.terminal.input.Key) ?editor_module.Key {
    return switch (key) {
        .codepoint => |cp| .{ .codepoint = cp },
        .enter => .enter,
        .backspace => .backspace,
        .tab => .tab,
        .shift_tab => .shift_tab,
        .escape => .escape,
        .ctrl_c => .ctrl_c,
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}

fn handleMouse(
    state: *State,
    context: hondo.native_view.Context,
    mouse: hondo.terminal.input.MouseEvent,
) !hondo.native_view.InputResult {
    if (!state.has_bounds) return .ignored;
    const tab = state.editor.activeTabConst();
    const hit = hitLayout(tab, tab.root, state.last_bounds, mouse.x, mouse.y) orelse return .ignored;

    if (mouse.action == .scroll) {
        const window = state.editor.windowById(hit.window_id) orelse return .ignored;
        switch (mouse.button) {
            .wheel_up => window.scroll_line -|= 3,
            .wheel_down => window.scroll_line += 3,
            else => return .ignored,
        }
        _ = state.editor.setActiveWindow(hit.window_id);
        try state.editor.syncCurrentLanguage(false);
        context.invalidate();
        try publishState(state, context);
        return .handled;
    }

    if (mouse.button != .left or mouse.action != .press) return .ignored;
    _ = state.editor.setActiveWindow(hit.window_id);
    try state.editor.syncCurrentLanguage(false);
    const window = state.editor.windowById(hit.window_id) orelse return .ignored;
    const line_index = window.scroll_line + (mouse.y - hit.bounds.y);
    const content_x = hit.bounds.x + @min(gutter_width, hit.bounds.width);
    const byte_column = if (mouse.x > content_x) mouse.x - content_x else 0;
    state.editor.setCursorForWindowFromLineColumn(hit.window_id, line_index, byte_column);
    context.invalidate();
    try publishState(state, context);
    return .handled;
}

fn paintLayout(
    editor: *editor_module.Editor,
    grid: *hondo.cell_grid.CellGrid,
    tab: *const editor_module.TabPage,
    node_index: usize,
    bounds: hondo.native_view.Bounds,
) !void {
    if (bounds.width == 0 or bounds.height == 0 or node_index >= tab.layout_nodes.items.len) return;
    switch (tab.layout_nodes.items[node_index]) {
        .window => |window_id| try paintWindow(editor, grid, window_id, bounds),
        .split => |split| switch (split.axis) {
            .vertical => {
                if (bounds.width < 3) return paintLayout(editor, grid, tab, split.first, bounds);
                const first_width = (bounds.width - 1) / 2;
                const second_width = bounds.width - first_width - 1;
                const divider_x = bounds.x + first_width;
                for (0..bounds.height) |offset| {
                    try grid.setStyled(divider_x, bounds.y + offset, '│', .{ .attributes = .{ .dim = true } });
                }
                try paintLayout(editor, grid, tab, split.first, .{
                    .x = bounds.x,
                    .y = bounds.y,
                    .width = first_width,
                    .height = bounds.height,
                });
                try paintLayout(editor, grid, tab, split.second, .{
                    .x = divider_x + 1,
                    .y = bounds.y,
                    .width = second_width,
                    .height = bounds.height,
                });
            },
            .horizontal => {
                if (bounds.height < 3) return paintLayout(editor, grid, tab, split.first, bounds);
                const first_height = (bounds.height - 1) / 2;
                const second_height = bounds.height - first_height - 1;
                const divider_y = bounds.y + first_height;
                for (0..bounds.width) |offset| {
                    try grid.setStyled(bounds.x + offset, divider_y, '─', .{ .attributes = .{ .dim = true } });
                }
                try paintLayout(editor, grid, tab, split.first, .{
                    .x = bounds.x,
                    .y = bounds.y,
                    .width = bounds.width,
                    .height = first_height,
                });
                try paintLayout(editor, grid, tab, split.second, .{
                    .x = bounds.x,
                    .y = divider_y + 1,
                    .width = bounds.width,
                    .height = second_height,
                });
            },
        },
    }
}

fn paintWindow(
    editor: *editor_module.Editor,
    grid: *hondo.cell_grid.CellGrid,
    window_id: editor_module.WindowId,
    bounds: hondo.native_view.Bounds,
) !void {
    const window = editor.windowById(window_id) orelse return;
    const buffer = editor.bufferById(window.buffer_id) orelse return;
    ensureCursorVisible(editor, window_id, bounds.height);

    const active = editor.activeTabConst().activeWindowId() == window_id;
    const cursor_position = editor.positionForWindow(window_id);
    const gutter = @min(gutter_width, bounds.width);
    const content_width = bounds.width - gutter;
    var line_start = byteOffsetForLine(buffer.text.items, window.scroll_line);

    var row: usize = 0;
    while (row < bounds.height) : (row += 1) {
        const line_number = window.scroll_line + row + 1;
        const current_line = line_number == cursor_position.line;
        if (active and current_line) {
            for (0..bounds.width) |offset| {
                try grid.setStyled(bounds.x + offset, bounds.y + row, ' ', .{
                    .background = .{ .rgb = .{ .r = 18, .g = 22, .b = 30 } },
                });
            }
        }

        if (gutter > 0) {
            var number_buffer: [16]u8 = undefined;
            const display_number = if (current_line)
                line_number
            else if (line_number > cursor_position.line)
                line_number - cursor_position.line
            else
                cursor_position.line - line_number;
            const number = std.fmt.bufPrint(&number_buffer, "{d} ", .{display_number}) catch "";
            try grid.paintUtf8Styled(bounds.x, bounds.y + row, number, gutter, .{
                .foreground = if (current_line) .{ .ansi = 13 } else .{ .ansi = 8 },
                .attributes = .{ .dim = !current_line },
            });
        }

        if (line_start > buffer.text.items.len) break;
        const end = editor_module.lineEnd(buffer.text.items, line_start);
        const line = buffer.text.items[line_start..end];
        if (content_width > 0) {
            try grid.paintUtf8(bounds.x + gutter, bounds.y + row, line, content_width);
            try paintSyntaxHighlights(
                editor,
                grid,
                buffer.id,
                line_start,
                end,
                bounds.x + gutter,
                bounds.y + row,
                content_width,
            );
        }

        if (active and window.cursor >= line_start and window.cursor <= end and content_width > 0) {
            const cursor_in_line = @min(window.cursor - line_start, line.len);
            const cursor_column = hondo.cell_grid.displayWidth(line[0..cursor_in_line]);
            if (cursor_column < content_width) {
                const x = bounds.x + gutter + cursor_column;
                if (grid.get(x, bounds.y + row)) |cell| {
                    if (cell.kind == .lead) {
                        var style = cell.style;
                        style.attributes.reverse = true;
                        try grid.setGraphemeStyled(x, bounds.y + row, cell.grapheme, cell.width, style);
                    } else {
                        try grid.setStyled(x, bounds.y + row, ' ', .{ .attributes = .{ .reverse = true } });
                    }
                }
            }
        }

        if (end >= buffer.text.items.len) {
            if (row == 0 and line.len == 0 and content_width > 0) {
                try grid.paintUtf8Styled(
                    bounds.x + gutter,
                    bounds.y,
                    "[No Name] — i insert  : command",
                    content_width,
                    .{ .attributes = .{ .dim = true } },
                );
            }
            break;
        }
        line_start = end + 1;
    }
}

fn paintSyntaxHighlights(
    editor: *const editor_module.Editor,
    grid: *hondo.cell_grid.CellGrid,
    buffer_id: editor_module.BufferId,
    line_start: usize,
    line_end: usize,
    content_x: usize,
    y: usize,
    content_width: usize,
) !void {
    const buffer = editor.bufferByIdConst(buffer_id) orelse return;
    for (editor.syntaxHighlightsForBuffer(buffer_id)) |highlight| {
        const start = @max(line_start, @as(usize, @intCast(highlight.range.start_byte)));
        const end = @min(line_end, @as(usize, @intCast(highlight.range.end_byte)));
        if (start >= end or start > buffer.text.items.len or end > buffer.text.items.len) continue;
        const prefix_width = hondo.cell_grid.displayWidth(buffer.text.items[line_start..start]);
        if (prefix_width >= content_width) continue;
        try grid.paintUtf8Styled(
            content_x + prefix_width,
            y,
            buffer.text.items[start..end],
            content_width - prefix_width,
            syntaxStyle(highlight.capture),
        );
    }
}

fn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {
    if (std.mem.indexOf(u8, capture, "comment") != null) return .{
        .foreground = .{ .ansi = 8 },
        .attributes = .{ .italic = true },
    };
    if (std.mem.indexOf(u8, capture, "string") != null) return .{ .foreground = .{ .ansi = 10 } };
    if (std.mem.indexOf(u8, capture, "keyword") != null) return .{
        .foreground = .{ .ansi = 13 },
        .attributes = .{ .bold = true },
    };
    if (std.mem.indexOf(u8, capture, "function") != null) return .{ .foreground = .{ .ansi = 14 } };
    if (std.mem.indexOf(u8, capture, "type") != null) return .{ .foreground = .{ .ansi = 12 } };
    if (std.mem.indexOf(u8, capture, "number") != null or std.mem.indexOf(u8, capture, "constant") != null) {
        return .{ .foreground = .{ .ansi = 11 } };
    }
    if (std.mem.indexOf(u8, capture, "operator") != null) return .{ .foreground = .{ .ansi = 6 } };
    return .{};
}

fn ensureCursorVisible(editor: *editor_module.Editor, window_id: editor_module.WindowId, viewport_height: usize) void {
    if (viewport_height == 0) return;
    const window = editor.windowById(window_id) orelse return;
    const cursor_line = editor.positionForWindow(window_id).line - 1;
    const margin = @min(scrolloff, viewport_height / 2);
    if (cursor_line < window.scroll_line + margin) {
        window.scroll_line = cursor_line -| margin;
    } else {
        const lower_guard = window.scroll_line + viewport_height - margin - 1;
        if (cursor_line > lower_guard) {
            window.scroll_line = cursor_line - (viewport_height - margin - 1);
        }
    }
}

fn hitLayout(
    tab: *const editor_module.TabPage,
    node_index: usize,
    bounds: hondo.native_view.Bounds,
    x: usize,
    y: usize,
) ?WindowHit {
    if (x < bounds.x or y < bounds.y or x >= bounds.x + bounds.width or y >= bounds.y + bounds.height) return null;
    if (node_index >= tab.layout_nodes.items.len) return null;
    return switch (tab.layout_nodes.items[node_index]) {
        .window => |window_id| .{ .window_id = window_id, .bounds = bounds },
        .split => |split| switch (split.axis) {
            .vertical => blk: {
                if (bounds.width < 3) break :blk hitLayout(tab, split.first, bounds, x, y);
                const first_width = (bounds.width - 1) / 2;
                const divider_x = bounds.x + first_width;
                if (x < divider_x) break :blk hitLayout(tab, split.first, .{
                    .x = bounds.x,
                    .y = bounds.y,
                    .width = first_width,
                    .height = bounds.height,
                }, x, y);
                if (x == divider_x) break :blk null;
                break :blk hitLayout(tab, split.second, .{
                    .x = divider_x + 1,
                    .y = bounds.y,
                    .width = bounds.width - first_width - 1,
                    .height = bounds.height,
                }, x, y);
            },
            .horizontal => blk: {
                if (bounds.height < 3) break :blk hitLayout(tab, split.first, bounds, x, y);
                const first_height = (bounds.height - 1) / 2;
                const divider_y = bounds.y + first_height;
                if (y < divider_y) break :blk hitLayout(tab, split.first, .{
                    .x = bounds.x,
                    .y = bounds.y,
                    .width = bounds.width,
                    .height = first_height,
                }, x, y);
                if (y == divider_y) break :blk null;
                break :blk hitLayout(tab, split.second, .{
                    .x = bounds.x,
                    .y = divider_y + 1,
                    .width = bounds.width,
                    .height = bounds.height - first_height - 1,
                }, x, y);
            },
        },
    };
}

fn publishState(state: *State, context: hondo.native_view.Context) !void {
    const position = state.editor.cursorPosition();
    var command_buffer: [160]u8 = undefined;
    const command = state.editor.commandDisplay(&command_buffer);
    var command_escaped: [320]u8 = undefined;
    const safe_command = escapeJson(command, &command_escaped);
    var status_escaped: [512]u8 = undefined;
    const safe_status = escapeJson(state.editor.status(), &status_escaped);
    var path_escaped: [512]u8 = undefined;
    const safe_path = escapeJson(state.editor.currentPath() orelse "[No Name]", &path_escaped);

    var payload_buffer: [1536]u8 = undefined;
    const payload = try std.fmt.bufPrint(
        &payload_buffer,
        "{{\"mode\":\"{s}\",\"line\":{d},\"column\":{d},\"modified\":{},\"revision\":{d},\"commandOpen\":{},\"commandText\":\"{s}\",\"status\":\"{s}\",\"path\":\"{s}\",\"buffers\":{d},\"windows\":{d},\"tabs\":{d}}}",
        .{
            state.editor.modeName(),
            position.line,
            position.column,
            state.editor.currentBuffer().modified,
            state.editor.currentBuffer().revision,
            state.editor.commandOpen(),
            safe_command,
            safe_status,
            safe_path,
            state.editor.buffers.items.len,
            state.editor.activeTab().window_ids.items.len,
            state.editor.tabs.items.len,
        },
    );
    try context.notify(payload);
}

fn escapeJson(source: []const u8, output: []u8) []const u8 {
    var index: usize = 0;
    for (source) |byte| {
        const escaped: []const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => "",
        };
        if (escaped.len != 0) {
            if (index + escaped.len > output.len) break;
            @memcpy(output[index .. index + escaped.len], escaped);
            index += escaped.len;
        } else if (byte >= 0x20) {
            if (index >= output.len) break;
            output[index] = byte;
            index += 1;
        }
    }
    return output[0..index];
}

fn byteOffsetForLine(text: []const u8, line_index: usize) usize {
    var line: usize = 0;
    var index: usize = 0;
    while (line < line_index and index < text.len) : (index += 1) {
        if (text[index] == '\n') line += 1;
    }
    return if (line == line_index) index else text.len;
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
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    _ = try editor.handleKey(.{ .codepoint = 'i' });
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

test "split layout paints two native editor windows with a divider" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("left\nwindow");
    _ = try editor.splitActive(.vertical);

    var grid = try hondo.cell_grid.CellGrid.init(std.testing.allocator, 40, 8);
    defer grid.deinit();
    try paintLayout(&editor, &grid, editor.activeTabConst(), editor.activeTabConst().root, .{
        .x = 0,
        .y = 0,
        .width = 40,
        .height = 8,
    });
    const divider = grid.get(19, 0).?;
    try std.testing.expectEqualStrings("│", divider.grapheme);
}
