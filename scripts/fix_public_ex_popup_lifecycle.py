#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

# Public commands execute from the TUI preprocessor rather than the native-view
# key callback. Expose one explicit state-publish bridge so those mutations reach
# the Solid/Hondo chrome immediately.
p = Path("src/editor_view.zig")
s = p.read_text()
s = replace_once(
    s,
    """var bound_editor: ?*editor_module.Editor = null;

const ViewRole = enum {
""",
    """var bound_editor: ?*editor_module.Editor = null;
var bound_editor_state: ?*State = null;

const ViewRole = enum {
""",
    "bound editor state",
)

s = replace_once(
    s,
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
    """    if (state.role == .project_tree) {
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
""",
    "bind editor native state",
)

anchor = """pub fn dispatchProjectTreeKey(key: hondo.terminal.input.Key) !bool {
"""
bridge = r'''pub fn publishBoundEditorState(
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

'''
s = replace_once(s, anchor, bridge + anchor, "public state publish bridge")
p.write_text(s)

p = Path("src/tui.zig")
s = p.read_text()
s = replace_once(
    s,
    """        if (key == .enter and self.editor.commandOpen()) {
            if (try self.executePublicCommandLine()) return .escape;
        }
""",
    """        if (key == .enter and self.editor.commandOpen()) {
            if (try self.executePublicCommandLine()) return null;
        }
""",
    "consume public command Enter",
)

s = replace_once(
    s,
    """        if (std.mem.eql(u8, name, \"w\") or std.mem.eql(u8, name, \"write\")) {
            _ = try self.api.writeCurrent(self.editor);
            return true;
        }

        if (self.api.commands.find(name) != null) {
            try self.api.commandExecute(self.editor, name, args);
            return true;
        }
""",
    """        if (std.mem.eql(u8, name, \"w\") or std.mem.eql(u8, name, \"write\")) {
            _ = try self.editor.handleKey(.escape);
            _ = try self.api.writeCurrent(self.editor);
            try self.publishEditorState();
            return true;
        }

        if (self.api.commands.find(name) != null) {
            // Leave command-line mode before invoking the command. Dispatching a
            // synthetic Escape afterwards would also close any popup the command
            // intentionally created (for example :help or :checkhealth).
            _ = try self.editor.handleKey(.escape);
            try self.api.commandExecute(self.editor, name, args);
            try self.publishEditorState();
            return true;
        }
""",
    "public command lifecycle",
)

s = replace_once(
    s,
    """    fn render(self: *TuiApp) !void {
""",
    """    fn publishEditorState(self: *TuiApp) !void {
        try editor_view.publishBoundEditorState(&self.registry, self.scene);
        try hondo.native_view_runtime.flushNotifications(&self.runtime, &self.registry);
        try self.registry.sync(self.scene);
        try self.syncFocus();
    }

    fn render(self: *TuiApp) !void {
""",
    "TUI public state flush",
)

anchor = """test \"plugin popup and completion popup render in Hondo while keys stay native\" {
"""
regression = r'''test "public Ex command popup survives Enter dispatch" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();

    const Callback = struct {
        fn run(context: *api_module.commands.Context) !void {
            const labels = [_][]const u8{"public command stayed open"};
            try context.editor.popupShow(.plugin, "PUBLIC EX POPUP", &labels);
        }
    };
    _ = try api.commandCreate("PopupTest", "popup lifecycle regression", Callback.run, null);

    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 100, 30);
    defer app.deinit();
    _ = try app.dispatch(.{ .key = .{ .codepoint = ':' } });
    for ("PopupTest") |byte| _ = try app.dispatch(.{ .key = .{ .codepoint = byte } });
    _ = try app.dispatch(.{ .key = .enter });

    try std.testing.expectEqual(editor_module.Mode.normal, editor.mode);
    try std.testing.expect(editor.popup.open);
    try std.testing.expect(sceneContainsText(app.scene, "PUBLIC EX POPUP"));
    _ = try app.dispatch(.{ .key = .escape });
    try std.testing.expect(!editor.popup.open);
}

'''
s = replace_once(s, anchor, regression + anchor, "public Ex popup regression test")
p.write_text(s)
