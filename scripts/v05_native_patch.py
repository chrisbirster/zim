from pathlib import Path
import re


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"marker not found in {path}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def regex_replace(path: str, pattern: str, replacement: str) -> None:
    p = Path(path)
    text = p.read_text()
    text, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"regex marker not found in {path}: {pattern!r}")
    p.write_text(text)


# Coherent v0.5 development version.
replace("src/app.zig", 'pub const version = "0.4.0";', 'pub const version = "0.5.0";')
replace(
    "src/app.zig",
    "try lua.eval(\"zim.version = '0.4.0'\");",
    "try lua.eval(\"zim.version = '0.5.0'\");",
)
replace("src/plugin_manager.zig", 'pub const zim_version = "0.4.0";', 'pub const zim_version = "0.5.0";')
replace("src/lua_runtime.zig", 'self.lua.pushString("0.4.0")', 'self.lua.pushString("0.5.0")')
replace("src/lua_runtime.zig", "assert(zim.version == '0.4.0')", "assert(zim.version == '0.5.0')")
replace("build.zig.zon", '.version = "0.3.0",', '.version = "0.5.0",')

# Keep references semantically distinct from definition results.
replace(
    "src/lsp_bridge.zig",
    "    last_locations: ?lsp.responses.LocationList = null;\n    last_symbols:",
    "    last_locations: ?lsp.responses.LocationList = null;\n"
    "    last_locations_are_references: bool = false,\n"
    "    last_symbols:",
)
replace(
    "src/lsp_bridge.zig",
    "            .definition, .references => {\n"
    "                if (self.last_locations) |*old| old.deinit();\n"
    "                self.last_locations = try lsp.responses.parseLocations(self.allocator, body);\n"
    "            },",
    "            .definition, .references => {\n"
    "                if (self.last_locations) |*old| old.deinit();\n"
    "                self.last_locations = try lsp.responses.parseLocations(self.allocator, body);\n"
    "                self.last_locations_are_references = request.kind == .references;\n"
    "            },",
)

# Publish initial/coarse workspace state from the native editor view.
replace("src/editor_view.zig", "    _ = context;\n    _ = props_json;", "    _ = props_json;")
replace(
    "src/editor_view.zig",
    "    state.* = .{ .editor = editor };\n    return state;",
    "    state.* = .{ .editor = editor };\n"
    "    try publishState(state, context);\n"
    "    return state;",
)
new_publish = r'''fn publishState(state: *State, context: hondo.native_view.Context) !void {
    const position = state.editor.cursorPosition();
    var command_buffer: [160]u8 = undefined;
    const command = state.editor.commandDisplay(&command_buffer);
    var command_escaped: [320]u8 = undefined;
    const safe_command = escapeJson(command, &command_escaped);
    var status_escaped: [512]u8 = undefined;
    const safe_status = escapeJson(state.editor.status(), &status_escaped);
    var path_escaped: [512]u8 = undefined;
    const safe_path = escapeJson(state.editor.currentPath() orelse "[No Name]", &path_escaped);
    var project_escaped: [512]u8 = undefined;
    const safe_project = escapeJson(state.editor.project_root orelse "", &project_escaped);
    const diagnostics = diagnosticCount(state.editor);
    const symbols = if (state.editor.lsp_state.last_symbols) |value| value.items.len else 0;
    const references = if (state.editor.lsp_state.last_locations_are_references)
        if (state.editor.lsp_state.last_locations) |value| value.items.len else 0
    else
        0;

    var payload_buffer: [2304]u8 = undefined;
    const payload = try std.fmt.bufPrint(
        &payload_buffer,
        "{{\"mode\":\"{s}\",\"line\":{d},\"column\":{d},\"modified\":{},\"revision\":{d},\"commandOpen\":{},\"commandText\":\"{s}\",\"status\":\"{s}\",\"path\":\"{s}\",\"project\":\"{s}\",\"buffers\":{d},\"windows\":{d},\"tabs\":{d},\"diagnostics\":{d},\"symbols\":{d},\"references\":{d}}}",
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
            safe_project,
            state.editor.buffers.items.len,
            state.editor.activeTab().window_ids.items.len,
            state.editor.tabs.items.len,
            diagnostics,
            symbols,
            references,
        },
    );
    try context.notify(payload);
}

fn diagnosticCount(editor: *const editor_module.Editor) usize {
    var total: usize = 0;
    for (editor.lsp_state.diagnostics.entries.items) |entry| total += entry.items.items.len;
    return total;
}
'''
regex_replace(
    "src/editor_view.zig",
    r"fn publishState\(state: \*State, context: hondo\.native_view\.Context\) !void \{.*?\n\}\n\n(?=fn escapeJson)",
    new_publish,
)

# Send real terminal dimensions to Solid and flush initial native state.
replace(
    "src/tui.zig",
    '        try runtime.eval(ui_bundle, "zim-hondo-ui.js");\n'
    '        errdefer runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};\n'
    "        try registry.sync(scene);",
    '        try runtime.eval(ui_bundle, "zim-hondo-ui.js");\n'
    '        errdefer runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};\n'
    "        try updateUiSize(&runtime, width, height);\n"
    "        try registry.sync(scene);\n"
    "        try hondo.native_view_runtime.flushNotifications(&runtime, &registry);",
)
replace(
    "src/tui.zig",
    "    fn resize(self: *TuiApp, width: usize, height: usize) !bool {\n"
    "        return self.renderer.resize(width, height);\n"
    "    }",
    "    fn resize(self: *TuiApp, width: usize, height: usize) !bool {\n"
    "        const changed = try self.renderer.resize(width, height);\n"
    "        if (changed) try updateUiSize(&self.runtime, width, height);\n"
    "        return changed;\n"
    "    }",
)
replace(
    "src/tui.zig",
    "};\n\npub fn run(init: std.process.Init, editor: *editor_module.Editor, api: *api_module.Api) !u8 {",
    '''};

fn updateUiSize(runtime: *hondo.runtime.Runtime, width: usize, height: usize) !void {
    var buffer: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &buffer,
        "globalThis.__zimUiResize?.({d}, {d});",
        .{ width, height },
    );
    try runtime.eval(script, "zim-ui-resize.js");
}

pub fn run(init: std.process.Init, editor: *editor_module.Editor, api: *api_module.Api) !u8 {''',
)

# Integration proofs for focus/collapse/responsive behavior.
tui = Path("src/tui.zig")
text = tui.read_text()
marker = 'test "Hondo status reflects native split commands" {'
test_block = r'''test "Zen workspace focus traverses chrome while insert Tab stays native" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 120, 30);
    defer app.deinit();

    try std.testing.expect(sceneContainsText(app.scene, "ZEN · EDITOR"));
    const before = editor.text().len;

    const context = try app.dispatch(.{ .key = .tab });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.javascript, context.path);
    try std.testing.expect(sceneContainsText(app.scene, "ZEN · CONTEXT"));
    try std.testing.expectEqual(before, editor.text().len);

    const project = try app.dispatch(.{ .key = .tab });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.javascript, project.path);
    try std.testing.expect(sceneContainsText(app.scene, "ZEN · PROJECT"));

    _ = try app.dispatch(.{ .key = .tab });
    try std.testing.expect(sceneContainsText(app.scene, "ZEN · EDITOR"));
    _ = try app.dispatch(.{ .key = .{ .codepoint = 'i' } });
    const insert_tab = try app.dispatch(.{ .key = .tab });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, insert_tab.path);
    try std.testing.expectEqualStrings("  ", editor.text());
    try std.testing.expect(sceneContainsText(app.scene, "ZEN · EDITOR"));
}

test "Zen workspace side zones collapse and respond to terminal width" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 120, 30);
    defer app.deinit();

    try std.testing.expect(sceneContainsText(app.scene, "PROJECT"));
    try std.testing.expect(sceneContainsText(app.scene, "Symbols"));

    _ = try app.dispatch(.{ .key = .tab });
    const collapsed = try app.dispatch(.{ .key = .{ .codepoint = 'c' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.javascript, collapsed.path);
    try std.testing.expect(sceneContainsText(app.scene, " C "));
    try std.testing.expect(!sceneContainsText(app.scene, "Symbols"));

    _ = try app.dispatch(.{ .key = .{ .codepoint = 'c' } });
    try std.testing.expect(sceneContainsText(app.scene, "Symbols"));

    try std.testing.expect(try app.resize(70, 24));
    try app.render();
    try std.testing.expect(sceneContainsText(app.scene, " P "));
    try std.testing.expect(sceneContainsText(app.scene, " C "));
}

'''
if marker not in text:
    raise SystemExit("TUI test insertion marker missing")
tui.write_text(text.replace(marker, test_block + marker, 1))
