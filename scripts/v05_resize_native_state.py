from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'marker not found in {path}: {old[:100]!r}')
    p.write_text(text.replace(old, new, 1))


# Solid consumes dimensions from the same nativeState channel as other coarse editor state.
replace(
    'ui/src/bundle.ts',
    "  if (typeof value.references === 'number') setReferences(value.references);\n  flush();",
    "  if (typeof value.references === 'number') setReferences(value.references);\n"
    "  if (typeof value.terminalWidth === 'number') setTerminalWidth(value.terminalWidth);\n"
    "  if (typeof value.terminalHeight === 'number') setTerminalHeight(value.terminalHeight);\n"
    "  flush();",
)
replace(
    'ui/src/bundle.ts',
    "  __zimUiResize?: (width: number, height: number) => void;\n",
    "",
)
old_resize_global = '''globals.__zimUiResize = (width, height) => {
  setTerminalWidth(Math.max(1, Math.trunc(width)));
  setTerminalHeight(Math.max(1, Math.trunc(height)));
  flush();
};

'''
replace('ui/src/bundle.ts', old_resize_global, '')

# TuiApp uses NativeView notifications instead of generating JS source.
replace(
    'src/tui.zig',
    '        try runtime.eval(ui_bundle, "zim-hondo-ui.js");\n'
    '        errdefer runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};\n'
    '        try updateUiSize(&runtime, width, height);\n'
    '        try registry.sync(scene);\n'
    '        try hondo.native_view_runtime.flushNotifications(&runtime, &registry);',
    '        try runtime.eval(ui_bundle, "zim-hondo-ui.js");\n'
    '        errdefer runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};\n'
    '        try registry.sync(scene);\n'
    '        try notifyWorkspaceSize(&runtime, &registry, scene, width, height);',
)
replace(
    'src/tui.zig',
    '    fn resize(self: *TuiApp, width: usize, height: usize) !bool {\n'
    '        const changed = try self.renderer.resize(width, height);\n'
    '        if (changed) try updateUiSize(&self.runtime, width, height);\n'
    '        return changed;\n'
    '    }',
    '    fn resize(self: *TuiApp, width: usize, height: usize) !bool {\n'
    '        const changed = try self.renderer.resize(width, height);\n'
    '        if (changed) try notifyWorkspaceSize(&self.runtime, &self.registry, self.scene, width, height);\n'
    '        return changed;\n'
    '    }',
)
old_helper = '''fn updateUiSize(runtime: *hondo.runtime.Runtime, width: usize, height: usize) !void {
    var buffer: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &buffer,
        "globalThis.__zimUiResize({d}, {d})",
        .{ width, height },
    );
    try runtime.eval(script, "zim-ui-resize.js");
}
'''
new_helper = '''fn notifyWorkspaceSize(
    runtime: *hondo.runtime.Runtime,
    registry: *hondo.native_view.Registry,
    scene: *hondo.scene.Scene,
    width: usize,
    height: usize,
) !void {
    var payload_buffer: [128]u8 = undefined;
    const payload = try std.fmt.bufPrint(
        &payload_buffer,
        "{{\\\"terminalWidth\\\":{d},\\\"terminalHeight\\\":{d}}}",
        .{ width, height },
    );

    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (node.id == 0 or !registry.isNative(node.id)) continue;
        const native_type = (try hondo.native_view.nativeType(scene, node.id)) orelse continue;
        if (!std.mem.eql(u8, native_type, editor_view.native_type)) continue;
        const context = hondo.native_view.Context{ .registry = registry, .node_id = node.id };
        try context.notify(payload);
        break;
    }
    try hondo.native_view_runtime.flushNotifications(runtime, registry);
}
'''
replace('src/tui.zig', old_helper, new_helper)
