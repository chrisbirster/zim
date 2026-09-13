#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)


path = Path("src/tui.zig")
source = path.read_text()

old = '''        try self.syncFocus();
        const ex_entry = isExEntryEvent(incoming) and self.editor.mode == .normal;
        if (ex_entry) {
            try self.focusEditor();
        } else if (self.tree_open and !self.editor.commandOpen()) {
            try self.focusTree();
        }
        const before_buffer_id = self.editor.currentBufferConst().id;
        const before = api_observer.capture(self.editor);
        const maybe_event = try self.prepareEvent(incoming);
'''
new = '''        try self.syncFocus();
        const ex_entry = isExEntryEvent(incoming) and self.editor.mode == .normal;
        const before_buffer_id = self.editor.currentBufferConst().id;
        const before = api_observer.capture(self.editor);

        // Ex entry is a global TUI action. Do not rely on Hondo focus to route
        // ':' from a native tree/dashboard/overlay back into the editor. Close
        // transient editor-owned pickers, enter command-line mode directly in
        // Zig, then publish that state to the Hondo scene.
        if (ex_entry) {
            self.leader.reset();
            if (self.editor.popup.open) self.editor.popupClose();
            if (self.editor.pin_switcher_open) self.editor.closePinSwitcher();
            _ = try self.editor.handleKey(.{ .codepoint = ':' });
            try self.focusEditor();
            try self.publishEditorState();
            try api_observer.emitChanges(self.api, self.editor, before);
            return .{
                .result = .{ .default_prevented = true },
                .path = .native,
            };
        }

        if (self.tree_open and !self.editor.commandOpen()) {
            try self.focusTree();
        }
        const maybe_event = try self.prepareEvent(incoming);
'''
source = replace_once(source, old, new, "dispatch Ex focus block")

# Once Ex entry is handled above, the direct-tree condition no longer needs a
# special ex_entry escape hatch.
source = replace_once(
    source,
    "if (self.tree_open and !self.editor.commandOpen() and !ex_entry) {",
    "if (self.tree_open and !self.editor.commandOpen()) {",
    "tree direct-dispatch condition",
)

anchor = 'test "q and q! quit reliably from the Hondo command line" {'
regression = r'''test "Ex entry is global while project tree owns the keyboard" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 120, 30);
    defer app.deinit();

    try sendLeader(&app, 'e');
    try std.testing.expect(app.tree_open);

    const entered = try app.dispatch(.{ .key = .{ .codepoint = ':' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, entered.path);
    try std.testing.expect(editor.commandOpen());
    var command_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(":", editor.commandDisplay(&command_buffer));
    try std.testing.expect(sceneContainsText(app.scene, ":"));

    _ = try app.dispatch(.{ .key = .escape });
    try std.testing.expect(!editor.commandOpen());
    try std.testing.expect(app.tree_open);
}

'''
source = replace_once(source, anchor, regression + anchor, "global Ex regression test")
path.write_text(source)
