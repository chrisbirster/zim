#!/usr/bin/env python3
from pathlib import Path

path = Path("src/editor_view.zig")
text = path.read_text()

old_state = '''    tree_entries: std.ArrayList(TreeEntry) = .empty,
    tree_selected: usize = 0,
    tree_scroll: usize = 0,
'''
new_state = '''    tree_entries: std.ArrayList(TreeEntry) = .empty,
    tree_expanded: std.ArrayList([]u8) = .empty,
    tree_selected: usize = 0,
    tree_scroll: usize = 0,
'''
assert old_state in text
text = text.replace(old_state, new_state, 1)

old_destroy = '''    clearProjectTree(state, allocator);
    state.tree_entries.deinit(allocator);
    allocator.destroy(state);
'''
new_destroy = '''    clearProjectTree(state, allocator);
    state.tree_entries.deinit(allocator);
    clearExpandedPaths(state, allocator);
    state.tree_expanded.deinit(allocator);
    allocator.destroy(state);
'''
assert old_destroy in text
text = text.replace(old_destroy, new_destroy, 1)

start = text.index("fn handleProjectTreeKey(")
end = text.index("fn baseName(", start)
new_tree = r'''fn handleProjectTreeKey(
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

'''
text = text[:start] + new_tree + text[end:]

old_header = '    try grid.paintUtf8Styled(bounds.x, bounds.y + 1, "j/k move · Enter open · r refresh", bounds.width, .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .dim = true } });\n'
new_header = '    try grid.paintUtf8Styled(bounds.x, bounds.y + 1, "j/k move · h/l collapse/expand · Enter open", bounds.width, .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .dim = true } });\n'
assert old_header in text
text = text.replace(old_header, new_header, 1)

old_label = '''        const label = std.fmt.bufPrint(
            &line_buffer,
            "{s}{s}{s}",
            .{ indent_buffer[0..indent_len], if (entry.is_dir) "+ " else "  ", baseName(entry.path) },
        ) catch baseName(entry.path);
'''
new_label = '''        const marker = if (!entry.is_dir)
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
'''
assert old_label in text
text = text.replace(old_label, new_label, 1)

path.write_text(text)
