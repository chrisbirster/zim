#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

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
            return true;
        }

        if (self.api.commands.find(name) != null) {
            // Leave command-line mode before invoking the command. Dispatching a
            // synthetic Escape afterwards would also close any popup the command
            // intentionally created (for example :help or :checkhealth).
            _ = try self.editor.handleKey(.escape);
            try self.api.commandExecute(self.editor, name, args);
            return true;
        }
""",
    "public command lifecycle",
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
