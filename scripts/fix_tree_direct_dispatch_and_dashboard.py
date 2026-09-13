#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

# Make tree input correctness independent from Hondo focus ownership.
p = Path("src/editor_view.zig")
s = p.read_text()
s = replace_once(
    s,
    """const CoarseState = struct {
""",
    """var bound_project_tree: ?*State = null;

const CoarseState = struct {
""",
    "bound tree state",
)
s = replace_once(
    s,
    """    if (state.role == .project_tree) try reloadProjectTree(state);
    return state;
}

fn destroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
""",
    """    if (state.role == .project_tree) {
        bound_project_tree = state;
        try reloadProjectTree(state);
    }
    return state;
}

fn destroy(allocator: std.mem.Allocator, state_ptr: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(state_ptr orelse return));
    if (bound_project_tree == state) bound_project_tree = null;
""",
    "bind/unbind tree state",
)

anchor = """fn handleProjectTreeKey(
    state: *State,
    context: hondo.native_view.Context,
    key: hondo.terminal.input.Key,
) !hondo.native_view.InputResult {
"""
direct = r'''pub fn dispatchProjectTreeKey(key: hondo.terminal.input.Key) !bool {
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

'''
s = replace_once(s, anchor, direct + anchor, "direct tree dispatch")
p.write_text(s)

# Route tree keys directly from Zig's TUI before Hondo interactive dispatch.
p = Path("src/tui.zig")
s = p.read_text()
old = """        const grid = self.renderer.grid();
        const result = try hondo.native_view_runtime.dispatchInteractive(
"""
new = """        if (self.tree_open and !self.editor.commandOpen() and !ex_entry) {
            const tree_handled = switch (maybe_event.?) {
                .key => |key| try editor_view.dispatchProjectTreeKey(key),
                else => false,
            };
            if (tree_handled) {
                if (before_buffer_id != self.editor.currentBufferConst().id) {
                    self.tree_open = false;
                    try self.runtime.eval(
                        \"globalThis.__zimCloseTree?.();\",
                        \"zim-close-tree-after-direct-open.js\",
                    );
                    try self.registry.sync(self.scene);
                    try self.syncFocus();
                }
                try api_observer.emitChanges(self.api, self.editor, before);
                return .{
                    .result = .{ .default_prevented = true },
                    .path = .native,
                };
            }

            // While the explorer owns the keyboard, unknown keys must not fall
            // through and mutate the editor buffer behind it.
            try api_observer.emitChanges(self.api, self.editor, before);
            return .{
                .result = .{ .default_prevented = true },
                .path = .native,
            };
        }

        const grid = self.renderer.grid();
        const result = try hondo.native_view_runtime.dispatchInteractive(
"""
s = replace_once(s, old, new, "TUI direct tree route")

# Strengthen an existing TUI test so the dashboard contract cannot regress.
s = replace_once(
    s,
    """    try std.testing.expect(sceneContainsText(app.scene, \"NORMAL\"));
    try std.testing.expect(sceneContainsText(app.scene, \"your new code overlord.\"));

""",
    """    try std.testing.expect(sceneContainsText(app.scene, \"NORMAL\"));
    try std.testing.expect(sceneContainsText(app.scene, \"your new code overlord.\"));
    try std.testing.expect(sceneContainsText(app.scene, \"ZIM v1.0.0\"));
    try std.testing.expect(sceneContainsText(app.scene, \":checkhealth\"));

""",
    "dashboard assertions",
)
p.write_text(s)

# Fulfil the visible dashboard wording in the Solid/Hondo chrome.
p = Path("ui/src/bundle.ts")
s = p.read_text()
s = replace_once(s, "children: '                  ZIM v1.0'", "children: '                 ZIM v1.0.0'", "dashboard version")
s = replace_once(
    s,
    """      Text({ children: '      :help         built-in documentation' }),
      Text({ children: '      :q            quit' }),
""",
    """      Text({ children: '      :help         built-in documentation' }),
      Text({ children: '      :checkhealth  runtime diagnostics' }),
      Text({ children: '      :q            quit' }),
""",
    "dashboard checkhealth",
)
p.write_text(s)

# Register the lowercase command promised by the v1 contract.
p = Path("src/daily_driver.zig")
s = p.read_text()
s = replace_once(
    s,
    '            "Help",          "help",            "Errors",          "Checkhealth", "SessionSave", "SessionRestore",\n',
    '            "Help",          "help",            "Errors",          "Checkhealth", "checkhealth", "SessionSave", "SessionRestore",\n',
    "checkhealth cleanup alias",
)
s = replace_once(
    s,
    '        _ = try self.api.commandCreate("Checkhealth", "show v1 runtime diagnostics", checkhealthCommand, self);\n',
    '        _ = try self.api.commandCreate("Checkhealth", "show v1 runtime diagnostics", checkhealthCommand, self);\n        _ = try self.api.commandCreate("checkhealth", "show v1 runtime diagnostics", checkhealthCommand, self);\n',
    "checkhealth registration alias",
)
p.write_text(s)
