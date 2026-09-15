const std = @import("std");
const editor_module = @import("editor.zig");

const format_version: u32 = 1;
const max_snapshot_bytes: usize = 96 * 1024 * 1024;

const PersistedBuffer = struct {
    id: editor_module.BufferId,
    path: ?[]const u8 = null,
    text: []const u8,
    modified: bool,
};

const PersistedWindow = struct {
    id: editor_module.WindowId,
    buffer_id: editor_module.BufferId,
    cursor: usize,
    preferred_column: ?usize = null,
    scroll_line: usize,
};

const PersistedLayout = struct {
    kind: u8,
    window_id: editor_module.WindowId = 0,
    axis: u8 = 0,
    first: usize = 0,
    second: usize = 0,
};

const PersistedTab = struct {
    id: editor_module.TabId,
    window_ids: []const editor_module.WindowId,
    layout: []const PersistedLayout,
    root: usize,
    active_window_index: usize,
};

const PersistedState = struct {
    version: u32 = format_version,
    dirty: bool,
    project_root: ?[]const u8 = null,
    active_tab_index: usize,
    buffers: []const PersistedBuffer,
    windows: []const PersistedWindow,
    tabs: []const PersistedTab,
};

pub fn encode(allocator: std.mem.Allocator, editor: *const editor_module.Editor, dirty: bool) ![]u8 {
    const buffers = try allocator.alloc(PersistedBuffer, editor.buffers.items.len);
    defer allocator.free(buffers);
    for (editor.buffers.items, buffers) |source, *target| {
        target.* = .{
            .id = source.id,
            .path = source.path,
            .text = source.text.items,
            .modified = source.modified,
        };
    }

    const windows = try allocator.alloc(PersistedWindow, editor.windows.items.len);
    defer allocator.free(windows);
    for (editor.windows.items, windows) |source, *target| {
        target.* = .{
            .id = source.id,
            .buffer_id = source.buffer_id,
            .cursor = source.cursor,
            .preferred_column = source.preferred_column,
            .scroll_line = source.scroll_line,
        };
    }

    const tabs = try allocator.alloc(PersistedTab, editor.tabs.items.len);
    defer {
        for (tabs) |tab| allocator.free(tab.layout);
        allocator.free(tabs);
    }
    for (editor.tabs.items, tabs) |source, *target| {
        const layout = try allocator.alloc(PersistedLayout, source.layout_nodes.items.len);
        for (source.layout_nodes.items, layout) |node, *persisted| {
            persisted.* = switch (node) {
                .window => |window_id| .{ .kind = 0, .window_id = window_id },
                .split => |split| .{
                    .kind = 1,
                    .axis = if (split.axis == .horizontal) 0 else 1,
                    .first = split.first,
                    .second = split.second,
                },
            };
        }
        target.* = .{
            .id = source.id,
            .window_ids = source.window_ids.items,
            .layout = layout,
            .root = source.root,
            .active_window_index = source.active_window_index,
        };
    }

    return std.json.Stringify.valueAlloc(allocator, PersistedState{
        .dirty = dirty,
        .project_root = editor.project_root,
        .active_tab_index = editor.active_tab_index,
        .buffers = buffers,
        .windows = windows,
        .tabs = tabs,
    }, .{});
}

pub fn writeAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *const editor_module.Editor,
    path: []const u8,
    dirty: bool,
) !void {
    const bytes = try encode(allocator, editor, dirty);
    defer allocator.free(bytes);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .default_file,
        .make_path = false,
        .replace = true,
    });
    defer atomic.deinit(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    try atomic.replace(io);
}

pub fn restoreFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: *editor_module.Editor,
    path: []const u8,
) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_snapshot_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    return restoreBytes(allocator, editor, bytes);
}

pub fn fileDirty(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_snapshot_bytes)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(PersistedState, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.version != format_version) return error.UnsupportedSessionFormat;
    return parsed.value.dirty;
}

pub fn restoreBytes(allocator: std.mem.Allocator, editor: *editor_module.Editor, bytes: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(PersistedState, allocator, bytes, .{});
    defer parsed.deinit();
    const state = parsed.value;
    if (state.version != format_version) return error.UnsupportedSessionFormat;
    try validate(state);

    var new_buffers: std.ArrayList(editor_module.Buffer) = .empty;
    errdefer {
        for (new_buffers.items) |*buffer| buffer.deinit(allocator);
        new_buffers.deinit(allocator);
    }
    for (state.buffers) |source| {
        try new_buffers.append(allocator, try editor_module.Buffer.init(allocator, source.id, source.path));
        const buffer = &new_buffers.items[new_buffers.items.len - 1];
        try buffer.setLoadedText(allocator, source.text);
        if (source.modified) buffer.markChanged();
    }

    var new_windows: std.ArrayList(editor_module.Window) = .empty;
    errdefer new_windows.deinit(allocator);
    for (state.windows) |source| {
        try new_windows.append(allocator, .{
            .id = source.id,
            .buffer_id = source.buffer_id,
            .cursor = source.cursor,
            .preferred_column = source.preferred_column,
            .scroll_line = source.scroll_line,
        });
    }

    var new_tabs: std.ArrayList(editor_module.TabPage) = .empty;
    errdefer {
        for (new_tabs.items) |*tab| tab.deinit(allocator);
        new_tabs.deinit(allocator);
    }
    for (state.tabs) |source| {
        try new_tabs.append(allocator, .{
            .id = source.id,
            .root = source.root,
            .active_window_index = source.active_window_index,
        });
        const tab = &new_tabs.items[new_tabs.items.len - 1];
        try tab.window_ids.appendSlice(allocator, source.window_ids);
        for (source.layout) |node| {
            try tab.layout_nodes.append(allocator, if (node.kind == 0)
                .{ .window = node.window_id }
            else
                .{ .split = .{
                    .axis = if (node.axis == 0) .horizontal else .vertical,
                    .first = node.first,
                    .second = node.second,
                } });
        }
    }

    const new_project_root = if (state.project_root) |root| try allocator.dupe(u8, root) else null;
    errdefer if (new_project_root) |root| allocator.free(root);

    var old_buffers = editor.buffers;
    var old_windows = editor.windows;
    var old_tabs = editor.tabs;
    const old_project_root = editor.project_root;

    editor.buffers = new_buffers;
    editor.windows = new_windows;
    editor.tabs = new_tabs;
    editor.project_root = new_project_root;
    editor.active_tab_index = state.active_tab_index;
    editor.next_buffer_id = nextBufferId(editor.buffers.items);
    editor.next_window_id = nextWindowId(editor.windows.items);
    editor.next_tab_id = nextTabId(editor.tabs.items);
    editor.mode = .normal;
    editor.popupClose();

    for (old_buffers.items) |*buffer| buffer.deinit(allocator);
    old_buffers.deinit(allocator);
    old_windows.deinit(allocator);
    for (old_tabs.items) |*tab| tab.deinit(allocator);
    old_tabs.deinit(allocator);
    if (old_project_root) |root| allocator.free(root);

    try editor.syncCurrentLanguage(true);
    try editor.syncCurrentLsp(true);
    return true;
}

fn validate(state: PersistedState) !void {
    if (state.buffers.len == 0 or state.windows.len == 0 or state.tabs.len == 0) return error.InvalidSession;
    if (state.active_tab_index >= state.tabs.len) return error.InvalidSession;

    for (state.buffers, 0..) |buffer, index| {
        if (buffer.id == 0) return error.InvalidSession;
        for (state.buffers[0..index]) |previous| if (previous.id == buffer.id) return error.InvalidSession;
    }
    for (state.windows, 0..) |window, index| {
        if (window.id == 0 or !hasBuffer(state.buffers, window.buffer_id)) return error.InvalidSession;
        for (state.windows[0..index]) |previous| if (previous.id == window.id) return error.InvalidSession;
    }
    for (state.tabs, 0..) |tab, index| {
        if (tab.id == 0 or tab.window_ids.len == 0 or tab.layout.len == 0) return error.InvalidSession;
        if (tab.active_window_index >= tab.window_ids.len or tab.root >= tab.layout.len) return error.InvalidSession;
        for (state.tabs[0..index]) |previous| if (previous.id == tab.id) return error.InvalidSession;
        for (tab.window_ids) |window_id| if (!hasWindow(state.windows, window_id)) return error.InvalidSession;
        for (tab.layout) |node| {
            if (node.kind == 0) {
                if (node.window_id == 0 or !containsWindow(tab.window_ids, node.window_id)) return error.InvalidSession;
            } else if (node.kind == 1) {
                if (node.axis > 1 or node.first >= tab.layout.len or node.second >= tab.layout.len) return error.InvalidSession;
            } else return error.InvalidSession;
        }
    }
}

fn hasBuffer(buffers: []const PersistedBuffer, id: editor_module.BufferId) bool {
    for (buffers) |buffer| if (buffer.id == id) return true;
    return false;
}

fn hasWindow(windows: []const PersistedWindow, id: editor_module.WindowId) bool {
    for (windows) |window| if (window.id == id) return true;
    return false;
}

fn containsWindow(windows: []const editor_module.WindowId, id: editor_module.WindowId) bool {
    for (windows) |window_id| if (window_id == id) return true;
    return false;
}

fn nextBufferId(buffers: []const editor_module.Buffer) editor_module.BufferId {
    var highest: editor_module.BufferId = 0;
    for (buffers) |buffer| highest = @max(highest, buffer.id);
    return highest + 1;
}

fn nextWindowId(windows: []const editor_module.Window) editor_module.WindowId {
    var highest: editor_module.WindowId = 0;
    for (windows) |window| highest = @max(highest, window.id);
    return highest + 1;
}

fn nextTabId(tabs: []const editor_module.TabPage) editor_module.TabId {
    var highest: editor_module.TabId = 0;
    for (tabs) |tab| highest = @max(highest, tab.id);
    return highest + 1;
}

test "session snapshot restores buffers windows tabs cursors and modified state" {
    const allocator = std.testing.allocator;
    var editor = try editor_module.Editor.init(allocator, std.testing.io, "src/one.zig");
    defer editor.deinit();
    try editor.setText("one\ntwo\n");
    editor.currentBuffer().markChanged();
    editor.setCursorFromLineColumn(1, 1);
    _ = try editor.splitActive(.vertical);

    const encoded = try encode(allocator, &editor, true);
    defer allocator.free(encoded);

    var restored = try editor_module.Editor.init(allocator, std.testing.io, null);
    defer restored.deinit();
    try std.testing.expect(try restoreBytes(allocator, &restored, encoded));
    try std.testing.expectEqualStrings("one\ntwo\n", restored.text());
    try std.testing.expect(restored.currentBuffer().modified);
    try std.testing.expectEqual(@as(usize, 2), restored.windows.items.len);
    try std.testing.expectEqual(@as(usize, 1), restored.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), restored.activeTab().window_ids.items.len);
}

test "invalid session is rejected before mutating editor" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("keep");
    const invalid = "{\"version\":1,\"dirty\":true,\"project_root\":null,\"active_tab_index\":0,\"buffers\":[],\"windows\":[],\"tabs\":[]}";
    try std.testing.expectError(error.InvalidSession, restoreBytes(std.testing.allocator, &editor, invalid));
    try std.testing.expectEqualStrings("keep", editor.text());
}
