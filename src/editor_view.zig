const std = @import("std");
const hondo = @import("hondo");
const editor_module = @import("editor.zig");
const theme_module = @import("theme.zig");

pub const native_type = "zim.editor";

const BindError = error{NoBoundEditor};
const gutter_width: usize = 6;
const scrolloff: usize = 8;
const max_tree_entries: usize = 2048;

var bound_editor: ?*editor_module.Editor = null;
var bound_editor_state: ?*State = null;

const ViewRole = enum {
    editor,
    project_tree,
};

const ViewProps = struct {
    role: ?[]const u8 = null,
    refreshNonce: u64 = 0,
};

const TreeEntry = struct {
    path: []u8,
    is_dir: bool,
    depth: usize,

    fn deinit(self: *TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const State = struct {
    editor: *editor_module.Editor,
    role: ViewRole = .editor,
    last_bounds: hondo.native_view.Bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    has_bounds: bool = false,
    props_initialized: bool = false,
    refresh_nonce: u64 = 0,
    tree_entries: std.ArrayList(TreeEntry) = .empty,
    tree_expanded: std.ArrayList([]u8) = .empty,
    tree_selected: usize = 0,
    tree_scroll: usize = 0,
};

var bound_project_tree: ?*State = null;

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
    pins_revision: u64,
    pin_switcher_open: bool,
    pin_switcher_index: usize,
    extmarks_revision: u64,
    popup_revision: u64,
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
    const editor = bound_editor orelse return BindError.NoBoundEditor;
    const state = try allocator.create(State);
    state.* = .{ .editor = editor };
    errdefer allocator.destroy(state);

    if (props_json.len != 0) {
        const parsed = std.json.parseFromSlice(ViewProps, allocator, props_json, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |value| {
            defer value.deinit();
            if (value.value.role) |role| {
                if (std.mem.eql(u8, role, "project-tree")) state.role = .project_tree;
            }
            state.refresh_nonce = value.value.refreshNonce;
        }
    }
    if (state.role == .project_tree) {
        bound_project_tree = state;
        try reloadProjectTree(state);
    } else {
        bound_editor_state = state;
    }
    return state;
}

fn destroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
    if (bound_project_tree == state) bound_project_tree = null;
    if (bound_editor_state == state) bound_editor_state = null;
    clearProjectTree(state, allocator);
    state.tree_entries.deinit(allocator);
    clearExpandedPaths(state, allocator);
    state.tree_expanded.deinit(allocator);
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
    switch (state.role) {
        .editor => {
            const tab = state.editor.activeTabConst();
            try paintLayout(state.editor, grid, tab, tab.root, bounds);
        },
        .project_tree => try paintProjectTree(state, grid, bounds),
    }
}

fn updateProps(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    props_json: []const u8,
) !void {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
    const parsed = try std.json.parseFromSlice(ViewProps, state.editor.allocator, props_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (state.role == .project_tree and parsed.value.refreshNonce != state.refresh_nonce) {
        state.refresh_nonce = parsed.value.refreshNonce;
        try reloadProjectTree(state);
        context.invalidate();
    }

    if (!state.props_initialized) {
        state.props_initialized = true;
        try publishState(state, context);
    }
}

fn input(
    state_ptr: ?*anyopaque,
    context: hondo.native_view.Context,
    event: hondo.terminal.input.Event,
) !hondo.native_view.InputResult {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return .ignored));
    return switch (state.role) {
        .editor => switch (event) {
            .key => |key| try handleKey(state, context, key),
            .mouse => |mouse| try handleMouse(state, context, mouse),
            .focus => .ignored,
        },
        .project_tree => switch (event) {
            .key => |key| try handleProjectTreeKey(state, context, key),
            .mouse, .focus => .ignored,
        },
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

pub fn publishBoundEditorState(
    registry: *hondo.native_view.Registry,
    scene: *hondo.scene.Scene,
) !void {
    const state = bound_editor_state orelse return;
    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (node.id == 0 or !registry.isNative(node.id)) continue;
        const native_name = (try hondo.native_view.nativeType(scene, node.id)) orelse continue;
        if (!std.mem.eql(u8, native_name, native_type)) continue;
        const context = hondo.native_view.Context{ .registry = registry, .node_id = node.id };
        try publishState(state, context);
    }
}

pub fn dispatchProjectTreeKey(key: hondo.terminal.input.Key) !bool {
    const state = bound_project_tree orelse return false;
    if (state.tree_entries.items.len == 0) {
        return switch (key) {
            .codepoint => |cp| if (cp == 'r') blk: {
                try reloadProjectTree(state);
                break :blk true;
            } else false,
            else => false,
        };
    }

    const moved = switch (key) {
        .down => moveTreeSelection(state, 1),
        .up => moveTreeSelection(state, -1),
        .codepoint => |cp| if (cp == 'j') moveTreeSelection(state, 1) else if (cp == 'k') moveTreeSelection(state, -1) else false,
        else => false,
    };
    if (moved) return true;

    return switch (key) {
        .enter => blk: {
            try activateTreeEntryDirect(state);
            break :blk true;
        },
        .right => blk: {
            try expandTreeEntryDirect(state);
            break :blk true;
        },
        .left => blk: {
            try collapseTreeEntryOrParentDirect(state);
            break :blk true;
        },
        .codepoint => |cp| switch (cp) {
            'l' => blk: {
                try expandTreeEntryDirect(state);
                break :blk true;
            },
            'h' => blk: {
                try collapseTreeEntryOrParentDirect(state);
                break :blk true;
            },
            'r' => blk: {
                try reloadProjectTree(state);
                break :blk true;
            },
            else => false,
        },
        else => false,
    };
}

fn activateTreeEntryDirect(state: *State) !void {
    const entry = &state.tree_entries.items[state.tree_selected];
    if (entry.is_dir) {
        if (isTreeExpanded(state, entry.path)) {
            removeTreeExpanded(state, entry.path);
        } else {
            try addTreeExpanded(state, entry.path);
        }
        try reloadProjectTree(state);
        return;
    }

    const root = state.editor.pinProjectRoot();
    const target = if (std.mem.eql(u8, root, "."))
        try state.editor.allocator.dupe(u8, entry.path)
    else
        try std.fs.path.join(state.editor.allocator, &.{ root, entry.path });
    defer state.editor.allocator.free(target);
    _ = try state.editor.editPath(target);
}

fn expandTreeEntryDirect(state: *State) !void {
    const entry = state.tree_entries.items[state.tree_selected];
    if (!entry.is_dir) return;
    if (!isTreeExpanded(state, entry.path)) {
        try addTreeExpanded(state, entry.path);
        try reloadProjectTree(state);
    } else if (state.tree_selected + 1 < state.tree_entries.items.len and
        state.tree_entries.items[state.tree_selected + 1].depth > entry.depth)
    {
        state.tree_selected += 1;
    }
}

fn collapseTreeEntryOrParentDirect(state: *State) !void {
    const entry = state.tree_entries.items[state.tree_selected];
    if (entry.is_dir and isTreeExpanded(state, entry.path)) {
        removeTreeExpanded(state, entry.path);
        try reloadProjectTree(state);
        return;
    }
    const parent = parentTreePath(entry.path) orelse return;
    for (state.tree_entries.items, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.path, parent)) {
            state.tree_selected = index;
            return;
        }
    }
}

fn handleProjectTreeKey(
    state: *State,
    context: hondo.native_view.Context,
    key: hondo.terminal.input.Key,
) !hondo.native_view.InputResult {
    if (state.tree_entries.items.len == 0) {
        return switch (key) {
            .escape => blk: {
                try context.notify("{\"treeClose\":true}");
                break :blk .handled;
            },
            .codepoint => |cp| if (cp == 'r') blk: {
                try reloadProjectTree(state);
                context.invalidate();
                break :blk .handled;
            } else .ignored,
            else => .ignored,
        };
    }

    const moved = switch (key) {
        .down => moveTreeSelection(state, 1),
        .up => moveTreeSelection(state, -1),
        .codepoint => |cp| if (cp == 'j') moveTreeSelection(state, 1) else if (cp == 'k') moveTreeSelection(state, -1) else false,
        else => false,
    };
    if (moved) {
        context.invalidate();
        return .handled;
    }

    return switch (key) {
        .enter => try activateTreeEntry(state, context),
        .right => try expandTreeEntry(state, context),
        .left => try collapseTreeEntryOrParent(state, context),
        .escape => blk: {
            try context.notify("{\"treeClose\":true}");
            break :blk .handled;
        },
        .codepoint => |cp| switch (cp) {
            'l' => try expandTreeEntry(state, context),
            'h' => try collapseTreeEntryOrParent(state, context),
            'r' => blk: {
                try reloadProjectTree(state);
                context.invalidate();
                break :blk .handled;
            },
            else => .ignored,
        },
        else => .ignored,
    };
}

fn activateTreeEntry(state: *State, context: hondo.native_view.Context) !hondo.native_view.InputResult {
    const entry = &state.tree_entries.items[state.tree_selected];
    if (entry.is_dir) {
        if (isTreeExpanded(state, entry.path)) {
            removeTreeExpanded(state, entry.path);
        } else {
            try addTreeExpanded(state, entry.path);
        }
        try reloadProjectTree(state);
        context.invalidate();
        return .handled;
    }

    const root = state.editor.pinProjectRoot();
    const target = if (std.mem.eql(u8, root, "."))
        try state.editor.allocator.dupe(u8, entry.path)
    else
        try std.fs.path.join(state.editor.allocator, &.{ root, entry.path });
    defer state.editor.allocator.free(target);
    if (try state.editor.editPath(target)) {
        context.invalidate();
        try publishState(state, context);
        try context.notify("{\"treeOpenedFile\":true}");
    }
    return .handled;
}

fn expandTreeEntry(state: *State, context: hondo.native_view.Context) !hondo.native_view.InputResult {
    const entry = state.tree_entries.items[state.tree_selected];
    if (!entry.is_dir) return .handled;
    if (!isTreeExpanded(state, entry.path)) {
        try addTreeExpanded(state, entry.path);
        try reloadProjectTree(state);
    } else if (state.tree_selected + 1 < state.tree_entries.items.len and
        state.tree_entries.items[state.tree_selected + 1].depth > entry.depth)
    {
        state.tree_selected += 1;
    }
    context.invalidate();
    return .handled;
}

fn collapseTreeEntryOrParent(state: *State, context: hondo.native_view.Context) !hondo.native_view.InputResult {
    const entry = state.tree_entries.items[state.tree_selected];
    if (entry.is_dir and isTreeExpanded(state, entry.path)) {
        removeTreeExpanded(state, entry.path);
        try reloadProjectTree(state);
        context.invalidate();
        return .handled;
    }

    const parent = parentTreePath(entry.path) orelse return .handled;
    for (state.tree_entries.items, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.path, parent)) {
            state.tree_selected = index;
            context.invalidate();
            break;
        }
    }
    return .handled;
}

fn moveTreeSelection(state: *State, direction: i8) bool {
    if (state.tree_entries.items.len == 0) return false;
    if (direction < 0) {
        state.tree_selected = if (state.tree_selected == 0) state.tree_entries.items.len - 1 else state.tree_selected - 1;
    } else {
        state.tree_selected = (state.tree_selected + 1) % state.tree_entries.items.len;
    }
    return true;
}

fn reloadProjectTree(state: *State) !void {
    var selected_path: ?[]u8 = null;
    if (state.tree_entries.items.len != 0 and state.tree_selected < state.tree_entries.items.len) {
        selected_path = try state.editor.allocator.dupe(u8, state.tree_entries.items[state.tree_selected].path);
    }
    defer if (selected_path) |value| state.editor.allocator.free(value);

    const previous_index = state.tree_selected;
    clearProjectTree(state, state.editor.allocator);
    state.tree_scroll = 0;

    const root = state.editor.pinProjectRoot();
    var dir = std.Io.Dir.cwd().openDir(state.editor.io, root, .{ .iterate = true }) catch return;
    defer dir.close(state.editor.io);

    var walker = try dir.walk(state.editor.allocator);
    defer walker.deinit();
    while (state.tree_entries.items.len < max_tree_entries) {
        const entry = (try walker.next(state.editor.io)) orelse break;
        if (!treePathVisible(state, entry.path)) continue;
        const path_copy = try state.editor.allocator.dupe(u8, entry.path);
        errdefer state.editor.allocator.free(path_copy);
        try state.tree_entries.append(state.editor.allocator, .{
            .path = path_copy,
            .is_dir = entry.kind == .directory,
            .depth = pathDepth(entry.path),
        });
    }

    state.tree_selected = if (state.tree_entries.items.len == 0)
        0
    else
        @min(previous_index, state.tree_entries.items.len - 1);
    if (selected_path) |wanted| {
        for (state.tree_entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, wanted)) {
                state.tree_selected = index;
                break;
            }
        }
    }
}

fn clearProjectTree(state: *State, allocator: std.mem.Allocator) void {
    for (state.tree_entries.items) |*entry| entry.deinit(allocator);
    state.tree_entries.items.len = 0;
}

fn clearExpandedPaths(state: *State, allocator: std.mem.Allocator) void {
    for (state.tree_expanded.items) |value| allocator.free(value);
    state.tree_expanded.items.len = 0;
}

fn isTreeExpanded(state: *const State, path_value: []const u8) bool {
    for (state.tree_expanded.items) |value| {
        if (std.mem.eql(u8, value, path_value)) return true;
    }
    return false;
}

fn addTreeExpanded(state: *State, path_value: []const u8) !void {
    if (isTreeExpanded(state, path_value)) return;
    try state.tree_expanded.append(state.editor.allocator, try state.editor.allocator.dupe(u8, path_value));
}

fn removeTreeExpanded(state: *State, path_value: []const u8) void {
    for (state.tree_expanded.items, 0..) |value, index| {
        if (!std.mem.eql(u8, value, path_value)) continue;
        state.editor.allocator.free(value);
        _ = state.tree_expanded.orderedRemove(index);
        return;
    }
}

fn treePathVisible(state: *const State, path_value: []const u8) bool {
    for (path_value, 0..) |byte, index| {
        if (byte != '/' and byte != '\\') continue;
        if (!isTreeExpanded(state, path_value[0..index])) return false;
    }
    return true;
}

fn parentTreePath(path_value: []const u8) ?[]const u8 {
    var index = path_value.len;
    while (index > 0) {
        index -= 1;
        if (path_value[index] == '/' or path_value[index] == '\\') return path_value[0..index];
    }
    return null;
}

fn pathDepth(path_value: []const u8) usize {
    var depth: usize = 0;
    for (path_value) |byte| {
        if (byte == '/' or byte == '\\') depth += 1;
    }
    return depth;
}

fn baseName(path: []const u8) []const u8 {
    var index: usize = 0;
    for (path, 0..) |byte, position| {
        if (byte == '/' or byte == '\\') index = position + 1;
    }
    return path[index..];
}

fn paintProjectTree(
    state: *State,
    grid: *hondo.cell_grid.CellGrid,
    bounds: hondo.native_view.Bounds,
) !void {
    if (bounds.width == 0 or bounds.height == 0) return;
    try grid.paintUtf8Styled(bounds.x, bounds.y, "FILES", bounds.width, themedStyle("Title", .{ .foreground = .{ .ansi = 14 }, .attributes = .{ .bold = true } }));
    if (bounds.height == 1) return;
    try grid.paintUtf8Styled(bounds.x, bounds.y + 1, "j/k move · h/l collapse/expand · Enter open", bounds.width, .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .dim = true } });
    if (bounds.height <= 2) return;

    const body_height = bounds.height - 2;
    if (state.tree_selected < state.tree_scroll) state.tree_scroll = state.tree_selected;
    if (state.tree_selected >= state.tree_scroll + body_height) {
        state.tree_scroll = state.tree_selected - body_height + 1;
    }

    var row: usize = 0;
    while (row < body_height) : (row += 1) {
        const entry_index = state.tree_scroll + row;
        if (entry_index >= state.tree_entries.items.len) break;
        const entry = state.tree_entries.items[entry_index];
        var indent_buffer: [32]u8 = undefined;
        const indent_len = @min(entry.depth * 2, indent_buffer.len);
        @memset(indent_buffer[0..indent_len], ' ');
        var line_buffer: [512]u8 = undefined;
        const marker = if (!entry.is_dir)
            "  "
        else if (isTreeExpanded(state, entry.path))
            "▾ "
        else
            "▸ ";
        const label = std.fmt.bufPrint(
            &line_buffer,
            "{s}{s}{s}",
            .{ indent_buffer[0..indent_len], marker, baseName(entry.path) },
        ) catch baseName(entry.path);
        const selected = entry_index == state.tree_selected;
        try grid.paintUtf8Styled(bounds.x, bounds.y + 2 + row, label, bounds.width, if (selected)
            .{ .foreground = .{ .ansi = 14 }, .attributes = .{ .reverse = true, .bold = true } }
        else if (entry.is_dir)
            .{ .foreground = .{ .ansi = 12 }, .attributes = .{ .bold = true } }
        else
            .{});
    }
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
        .pins_revision = editor.pins.revision,
        .pin_switcher_open = editor.pin_switcher_open,
        .pin_switcher_index = editor.pin_switcher_index,
        .extmarks_revision = editor.currentBufferConst().extmarks.revision,
        .popup_revision = editor.popup.revision,
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
        before.status_hash != after.status_hash or
        before.pins_revision != after.pins_revision or
        before.pin_switcher_open != after.pin_switcher_open or
        before.pin_switcher_index != after.pin_switcher_index or
        before.extmarks_revision != after.extmarks_revision or
        before.popup_revision != after.popup_revision;
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
        // The currently pinned Hondo decoder exposes Ctrl-C explicitly and
        // preserves the other legacy C0 control bytes as codepoints. Translate
        // those bytes here so interactive Vim controls reach the same grammar as
        // headless Editor.handleKey tests.
        .codepoint => |cp| switch (cp) {
            0x02 => .ctrl_b,
            0x04 => .ctrl_d,
            0x05 => .ctrl_e,
            0x06 => .ctrl_f,
            0x0b => .ctrl_k,
            0x0c => .ctrl_l,
            0x0f => .ctrl_o,
            0x12 => .ctrl_r,
            0x15 => .ctrl_u,
            0x16 => .ctrl_v,
            0x19 => .ctrl_y,
            else => .{ .codepoint = cp },
        },
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
    window.viewport_height = @max(@as(usize, 1), bounds.height);
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
            const line_style = if (current_line)
                themedStyle("CursorLineNr", .{ .foreground = .{ .ansi = 13 } })
            else
                themedStyle("LineNr", .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .dim = true } });
            try grid.paintUtf8Styled(bounds.x, bounds.y + row, number, gutter, line_style);
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
            try paintExtmarks(
                editor,
                grid,
                buffer.id,
                line_start,
                end,
                bounds.x,
                gutter,
                bounds.x + gutter,
                bounds.y + row,
                content_width,
                line,
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

fn paintExtmarks(
    editor: *const editor_module.Editor,
    grid: *hondo.cell_grid.CellGrid,
    buffer_id: editor_module.BufferId,
    line_start: usize,
    line_end: usize,
    gutter_x: usize,
    gutter: usize,
    content_x: usize,
    y: usize,
    content_width: usize,
    line: []const u8,
) !void {
    const buffer = editor.bufferByIdConst(buffer_id) orelse return;
    for (buffer.extmarks.items()) |mark| {
        const anchored_here = mark.start >= line_start and mark.start <= line_end;
        if (anchored_here and gutter > 0) {
            if (mark.sign) |sign| try grid.paintUtf8Styled(gutter_x, y, sign, 1, extmarkStyle(mark.highlight));
        }
        if (mark.highlight != null and mark.end > mark.start) {
            const start = @max(line_start, mark.start);
            const finish = @min(line_end, mark.end);
            if (start < finish and start <= buffer.text.items.len and finish <= buffer.text.items.len) {
                const prefix = hondo.cell_grid.displayWidth(buffer.text.items[line_start..start]);
                if (prefix < content_width) {
                    try grid.paintUtf8Styled(content_x + prefix, y, buffer.text.items[start..finish], content_width - prefix, extmarkStyle(mark.highlight));
                }
            }
        }
        if (anchored_here) {
            if (mark.virtual_text) |annotation| {
                const used = hondo.cell_grid.displayWidth(line);
                if (used + 1 < content_width) {
                    try grid.paintUtf8Styled(
                        content_x + used + 1,
                        y,
                        annotation,
                        content_width - used - 1,
                        themedStyle("VirtualText", .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true, .dim = true } }),
                    );
                }
            }
        }
    }
}

fn extmarkStyle(name: ?[]const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {
    const value = name orelse return themedStyle("PluginAccent", .{ .foreground = .{ .ansi = 13 } });
    if (theme_module.activeStyle(value) != null) return themedStyle(value, .{});
    if (std.mem.eql(u8, value, "DiagnosticError")) return .{ .foreground = .{ .ansi = 9 }, .attributes = .{ .bold = true } };
    if (std.mem.eql(u8, value, "DiagnosticWarn")) return .{ .foreground = .{ .ansi = 11 }, .attributes = .{ .bold = true } };
    if (std.mem.eql(u8, value, "DiagnosticInfo")) return .{ .foreground = .{ .ansi = 14 } };
    if (std.mem.eql(u8, value, "DiagnosticHint")) return .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } };
    return themedStyle("PluginAccent", .{ .foreground = .{ .ansi = 13 } });
}

fn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {
    const fallback: @TypeOf((hondo.cell_grid.Cell{}).style) = if (std.mem.indexOf(u8, capture, "comment") != null)
        .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } }
    else if (std.mem.indexOf(u8, capture, "string") != null)
        .{ .foreground = .{ .ansi = 10 } }
    else if (std.mem.indexOf(u8, capture, "keyword") != null)
        .{ .foreground = .{ .ansi = 13 }, .attributes = .{ .bold = true } }
    else if (std.mem.indexOf(u8, capture, "function") != null)
        .{ .foreground = .{ .ansi = 14 } }
    else if (std.mem.indexOf(u8, capture, "type") != null)
        .{ .foreground = .{ .ansi = 12 } }
    else if (std.mem.indexOf(u8, capture, "number") != null or std.mem.indexOf(u8, capture, "constant") != null)
        .{ .foreground = .{ .ansi = 11 } }
    else if (std.mem.indexOf(u8, capture, "operator") != null)
        .{ .foreground = .{ .ansi = 6 } }
    else
        .{};
    const group = theme_module.groupForCapture(capture) orelse return fallback;
    return themedStyle(group, fallback);
}

fn themedStyle(
    group: []const u8,
    fallback: @TypeOf((hondo.cell_grid.Cell{}).style),
) @TypeOf((hondo.cell_grid.Cell{}).style) {
    const source = theme_module.activeStyle(group) orelse return fallback;
    var result: @TypeOf((hondo.cell_grid.Cell{}).style) = .{};
    if (source.foreground) |foreground| result.foreground = .{ .ansi = @intCast(foreground) };
    if (source.background) |background| result.background = .{ .ansi = @intCast(background) };
    result.attributes.bold = source.bold;
    result.attributes.italic = source.italic;
    result.attributes.dim = source.dim;
    result.attributes.underline = source.underline;
    return result;
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
    const diagnostics = diagnosticCount(state.editor);
    const symbols = if (state.editor.lsp_state.last_symbols) |value| value.items.len else 0;
    const references = if (state.editor.lsp_state.last_locations_are_references)
        if (state.editor.lsp_state.last_locations) |value| value.items.len else 0
    else
        0;

    const payload = try std.json.Stringify.valueAlloc(state.editor.allocator, .{
        .mode = state.editor.modeName(),
        .line = position.line,
        .column = position.column,
        .modified = state.editor.currentBuffer().modified,
        .revision = state.editor.currentBuffer().revision,
        .commandOpen = state.editor.commandOpen(),
        .commandText = command,
        .status = state.editor.status(),
        .path = state.editor.currentPath() orelse "[No Name]",
        .project = state.editor.pinProjectRoot(),
        .buffers = state.editor.buffers.items.len,
        .windows = state.editor.activeTab().window_ids.items.len,
        .tabs = state.editor.tabs.items.len,
        .diagnostics = diagnostics,
        .symbols = symbols,
        .references = references,
        .pins = state.editor.pins.entries.items,
        .pinSwitcherOpen = state.editor.pin_switcher_open,
        .pinSwitcherIndex = state.editor.pin_switcher_index,
        .popupOpen = state.editor.popup.open,
        .popupKind = @tagName(state.editor.popup.kind),
        .popupTitle = state.editor.popup.title.items,
        .popupItems = state.editor.popup.items.items,
        .popupSelected = state.editor.popup.selected,
    }, .{});
    defer state.editor.allocator.free(payload);
    try context.notify(payload);
}

fn diagnosticCount(editor: *const editor_module.Editor) usize {
    var total: usize = 0;
    for (editor.buffers.items) |buffer| total += buffer.extmarks.diagnosticCount();
    return total;
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

test "native renderer styles follow the active v1 theme registry" {
    var store = theme_module.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.load("zim");
    theme_module.activate(&store);
    defer theme_module.deactivate(&store);

    try store.set("Keyword", .{ .foreground = 2, .italic = true });
    const style = syntaxStyle("keyword.function");
    try std.testing.expect(style.foreground.eql(.{ .ansi = 2 }));
    try std.testing.expect(style.attributes.italic);
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
