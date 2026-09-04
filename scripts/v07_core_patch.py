from pathlib import Path


def replace_once(path: str, old: str, new: str):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one marker, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path: str, marker: str, content: str):
    p = Path(path)
    text = p.read_text()
    if marker in text:
        return
    p.write_text(text + "\n" + content + "\n")

# Clean one accidental no-op from the initial extmark store implementation.
replace_once("src/extmarks.zig", "            if (write != @intFromPtr(mark)) {}\n            self.marks.items[write] = mark.*;", "            self.marks.items[write] = mark.*;")

# Buffer owns extmarks so all edit paths share the same anchor model.
replace_once("src/buffer.zig", 'const std = @import("std");\n', 'const std = @import("std");\nconst extmarks_module = @import("extmarks.zig");\n')
replace_once("src/buffer.zig", "    redo: std.ArrayList(Snapshot) = .empty,\n", "    redo: std.ArrayList(Snapshot) = .empty,\n    extmarks: extmarks_module.Store,\n")
replace_once(
    "src/buffer.zig",
    "        return .{\n            .id = id,\n            .path = if (path) |value| try allocator.dupe(u8, value) else null,\n        };",
    "        return .{\n            .id = id,\n            .path = if (path) |value| try allocator.dupe(u8, value) else null,\n            .extmarks = extmarks_module.Store.init(allocator),\n        };",
)
replace_once("src/buffer.zig", "        self.text.deinit(allocator);\n", "        self.text.deinit(allocator);\n        self.extmarks.deinit();\n")
replace_once("src/buffer.zig", "    pub fn setLoadedText(self: *Buffer, allocator: std.mem.Allocator, value: []const u8) !void {\n        self.text.items.len = 0;", "    pub fn setLoadedText(self: *Buffer, allocator: std.mem.Allocator, value: []const u8) !void {\n        self.extmarks.applyTextReplacement(self.text.items, value);\n        self.text.items.len = 0;")
replace_once("src/buffer.zig", "        defer previous.deinit(allocator);\n        try self.restoreSnapshot(allocator, previous);", "        defer previous.deinit(allocator);\n        self.extmarks.applyTextReplacement(self.text.items, previous.text);\n        try self.restoreSnapshot(allocator, previous);")
replace_once("src/buffer.zig", "        defer next.deinit(allocator);\n        try self.restoreSnapshot(allocator, next);", "        defer next.deinit(allocator);\n        self.extmarks.applyTextReplacement(self.text.items, next.text);\n        try self.restoreSnapshot(allocator, next);")
replace_once(
    "src/buffer.zig",
    "    pub fn encodeUndoJournal(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {",
    '''    pub fn insertBytesAt(self: *Buffer, allocator: std.mem.Allocator, index: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const insertion = @min(index, self.text.items.len);
        const old_len = self.text.items.len;
        self.extmarks.applyEdit(insertion, insertion, bytes.len);
        try self.text.ensureTotalCapacity(allocator, old_len + bytes.len);
        self.text.items.len = old_len + bytes.len;
        std.mem.copyBackwards(
            u8,
            self.text.items[insertion + bytes.len ..],
            self.text.items[insertion..old_len],
        );
        @memcpy(self.text.items[insertion .. insertion + bytes.len], bytes);
    }

    pub fn deleteBytes(self: *Buffer, start_index: usize, end_index: usize) void {
        const start = @min(start_index, self.text.items.len);
        const end = @min(@max(end_index, start), self.text.items.len);
        if (start == end) return;
        self.extmarks.applyEdit(start, end, 0);
        const old_len = self.text.items.len;
        std.mem.copyForwards(
            u8,
            self.text.items[start .. old_len - (end - start)],
            self.text.items[end..old_len],
        );
        self.text.items.len = old_len - (end - start);
    }

    pub fn replaceText(self: *Buffer, allocator: std.mem.Allocator, value: []const u8) !void {
        self.extmarks.applyTextReplacement(self.text.items, value);
        self.text.items.len = 0;
        try self.text.appendSlice(allocator, value);
    }

    pub fn encodeUndoJournal(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {''',
)

# Editor owns namespace identity; buffers own marks.
replace_once("src/editor.zig", 'const pins_module = @import("pins.zig");\n', 'const pins_module = @import("pins.zig");\nconst extmarks_module = @import("extmarks.zig");\nconst plugin_ui = @import("plugin_ui.zig");\n')
replace_once(
    "src/editor.zig",
    "    pins: pins_module.Store,\n    pin_switcher_open: bool = false,",
    "    pins: pins_module.Store,\n    extmark_namespaces: extmarks_module.Registry,\n    lsp_diagnostic_namespace: extmarks_module.NamespaceId = 0,\n    popup: plugin_ui.Model,\n    completion_generation_seen: u64 = 0,\n    pin_switcher_open: bool = false,",
)
replace_once(
    "src/editor.zig",
    "            .pins = pins_module.Store.init(allocator, io),\n        };\n        errdefer self.deinit();",
    "            .pins = pins_module.Store.init(allocator, io),\n            .extmark_namespaces = extmarks_module.Registry.init(allocator),\n            .popup = plugin_ui.Model.init(allocator),\n        };\n        errdefer self.deinit();\n        self.lsp_diagnostic_namespace = try self.extmark_namespaces.create(\"zim.lsp.diagnostics\");",
)
replace_once("src/editor.zig", "        self.pins.deinit();\n", "        self.pins.deinit();\n        self.extmark_namespaces.deinit();\n        self.popup.deinit();\n")
replace_once(
    "src/editor.zig",
    "    pub fn currentBuffer(self: *Editor) *Buffer {",
    '''    pub fn extmarkNamespaceCreate(self: *Editor, name: []const u8) !extmarks_module.NamespaceId {
        return self.extmark_namespaces.create(name);
    }

    pub fn extmarkNamespaceDelete(self: *Editor, namespace_id: extmarks_module.NamespaceId) bool {
        if (namespace_id == self.lsp_diagnostic_namespace) return false;
        if (!self.extmark_namespaces.delete(namespace_id)) return false;
        for (self.buffers.items) |*buffer| _ = buffer.extmarks.clearNamespace(namespace_id);
        return true;
    }

    pub fn extmarkSet(
        self: *Editor,
        buffer_id: BufferId,
        namespace_id: extmarks_module.NamespaceId,
        start: usize,
        options: extmarks_module.Options,
    ) !extmarks_module.ExtmarkId {
        if (!self.extmark_namespaces.contains(namespace_id)) return error.InvalidExtmarkNamespace;
        const buffer = self.bufferById(buffer_id) orelse return error.InvalidBuffer;
        const bounded_start = @min(start, buffer.text.items.len);
        var bounded = options;
        if (bounded.end) |finish| bounded.end = @min(finish, buffer.text.items.len);
        return buffer.extmarks.set(namespace_id, bounded_start, bounded);
    }

    pub fn extmarkDelete(self: *Editor, buffer_id: BufferId, namespace_id: extmarks_module.NamespaceId, id: extmarks_module.ExtmarkId) bool {
        const buffer = self.bufferById(buffer_id) orelse return false;
        return buffer.extmarks.remove(namespace_id, id);
    }

    pub fn extmarkClear(self: *Editor, buffer_id: BufferId, namespace_id: extmarks_module.NamespaceId) bool {
        const buffer = self.bufferById(buffer_id) orelse return false;
        return buffer.extmarks.clearNamespace(namespace_id);
    }

    pub fn publishDiagnostics(
        self: *Editor,
        buffer_id: BufferId,
        namespace_id: extmarks_module.NamespaceId,
        diagnostics: []const extmarks_module.Diagnostic,
    ) !void {
        if (!self.extmark_namespaces.contains(namespace_id)) return error.InvalidExtmarkNamespace;
        const buffer = self.bufferById(buffer_id) orelse return error.InvalidBuffer;
        try buffer.extmarks.publishDiagnostics(namespace_id, diagnostics);
    }

    pub fn popupShow(self: *Editor, kind: plugin_ui.Kind, title: []const u8, labels: []const []const u8) !void {
        try self.popup.show(kind, title, labels);
    }

    pub fn popupClose(self: *Editor) void {
        self.popup.close();
    }

    pub fn currentBuffer(self: *Editor) *Buffer {''',
)
replace_once(
    "src/editor.zig",
    "    pub fn lspHandleIncoming(self: *Editor, body: []const u8) !void {\n        const was_ready = self.lsp_state.client.state == .ready;\n        try self.lsp_state.handleIncoming(body);",
    "    pub fn lspHandleIncoming(self: *Editor, body: []const u8) !void {\n        const was_ready = self.lsp_state.client.state == .ready;\n        try self.lsp_state.handleIncoming(body);\n        try self.syncLspDiagnosticExtmarks();",
)
replace_once(
    "src/editor.zig",
    "    pub fn lspNextDiagnostic(self: *Editor, forward: bool) !bool {",
    '''    fn syncLspDiagnosticExtmarks(self: *Editor) !void {
        for (self.buffers.items) |*buffer| {
            const path = buffer.path orelse continue;
            const uri = try lsp_bridge.fileUriAlloc(self.allocator, path);
            defer self.allocator.free(uri);
            const source = self.lsp_state.diagnostics.itemsFor(uri);
            const diagnostics = try self.allocator.alloc(extmarks_module.Diagnostic, source.len);
            defer self.allocator.free(diagnostics);
            for (source, diagnostics) |item, *target| {
                const severity: extmarks_module.DiagnosticSeverity = if (item.severity) |value| switch (value) {
                    .error_level => .error_level,
                    .warning => .warning,
                    .information => .information,
                    .hint => .hint,
                } else .information;
                target.* = .{
                    .start = lsp_bridge.byteOffsetFromProtocolPosition(buffer.text.items, item.range.start),
                    .end = lsp_bridge.byteOffsetFromProtocolPosition(buffer.text.items, item.range.end),
                    .severity = severity,
                    .message = item.message,
                };
            }
            try buffer.extmarks.publishDiagnostics(self.lsp_diagnostic_namespace, diagnostics);
        }
    }

    pub fn lspNextDiagnostic(self: *Editor, forward: bool) !bool {''',
)
# Use buffer mutation APIs for native editing.
replace_once(
    "src/editor.zig",
    '''        const old_len = buffer.text.items.len;
        std.mem.copyForwards(
            u8,
            buffer.text.items[start .. old_len - (end - start)],
            buffer.text.items[end..old_len],
        );
        buffer.text.items.len = old_len - (end - start);
        buffer.markChanged();''',
    '''        buffer.deleteBytes(start, end);
        buffer.markChanged();''',
)
replace_once(
    "src/editor.zig",
    '''fn insertSliceAt(buffer: *Buffer, allocator: std.mem.Allocator, index: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const insertion = @min(index, buffer.text.items.len);
    const old_len = buffer.text.items.len;
    try buffer.text.ensureTotalCapacity(allocator, old_len + bytes.len);
    buffer.text.items.len = old_len + bytes.len;
    std.mem.copyBackwards(
        u8,
        buffer.text.items[insertion + bytes.len ..],
        buffer.text.items[insertion..old_len],
    );
    @memcpy(buffer.text.items[insertion .. insertion + bytes.len], bytes);
}''',
    '''fn insertSliceAt(buffer: *Buffer, allocator: std.mem.Allocator, index: usize, bytes: []const u8) !void {
    try buffer.insertBytesAt(allocator, index, bytes);
}''',
)

append_once(
    "src/editor.zig",
    'test "extmarks survive native insert delete undo and redo"',
    r'''test "extmarks survive native insert delete undo and redo" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("abc def");
    const ns = try editor.extmarkNamespaceCreate("test");
    const id = try editor.extmarkSet(editor.currentBuffer().id, ns, 4, .{});

    editor.setCursor(0);
    _ = try editor.handleKey(.{ .codepoint = 'i' });
    _ = try editor.handleKey(.{ .codepoint = 'X' });
    _ = try editor.handleKey(.escape);
    try std.testing.expectEqual(@as(usize, 5), editor.currentBuffer().extmarks.mark(ns, id).?.start);

    try std.testing.expect(try editor.undo());
    try std.testing.expectEqual(@as(usize, 4), editor.currentBuffer().extmarks.mark(ns, id).?.start);
    try std.testing.expect(try editor.redo());
    try std.testing.expectEqual(@as(usize, 5), editor.currentBuffer().extmarks.mark(ns, id).?.start);

    editor.setCursor(0);
    _ = try editor.handleKey(.{ .codepoint = 'x' });
    try std.testing.expectEqual(@as(usize, 4), editor.currentBuffer().extmarks.mark(ns, id).?.start);
}''',
)

# Workspace edits go through the same buffer replacement tracking.
replace_once(
    "src/lsp_bridge.zig",
    "    pending_workspace_edit: ?lsp.workspace_edit.Plan = null,\n",
    "    pending_workspace_edit: ?lsp.workspace_edit.Plan = null,\n    completion_generation: u64 = 0,\n",
)
replace_once(
    "src/lsp_bridge.zig",
    "                self.last_completions = try lsp.completion.parse(self.allocator, body);\n",
    "                self.last_completions = try lsp.completion.parse(self.allocator, body);\n                self.completion_generation += 1;\n",
)
replace_once(
    "src/lsp_bridge.zig",
    '''                buffer.text.items.len = 0;
                try buffer.text.appendSlice(self.allocator, updated);
                buffer.markChanged();''',
    '''                try buffer.replaceText(self.allocator, updated);
                buffer.markChanged();''',
)
replace_once(
    "src/lsp_bridge.zig",
    '''                temporary.text.items.len = 0;
                try temporary.text.appendSlice(self.allocator, updated);
                temporary.markChanged();''',
    '''                try temporary.replaceText(self.allocator, updated);
                temporary.markChanged();''',
)
append_once(
    "src/lsp_bridge.zig",
    'test "workspace edits move extmarks through the buffer primitive"',
    r'''test "workspace edits move extmarks through the buffer primitive" {
    var buffer = try buffer_module.Buffer.init(std.testing.allocator, 1, "/tmp/extmark-demo.zig");
    defer buffer.deinit(std.testing.allocator);
    try buffer.setLoadedText(std.testing.allocator, "const value = 1;\n");
    const mark_id = try buffer.extmarks.set(1, 6, .{});

    var state = State.init(std.testing.allocator, std.testing.io);
    defer state.deinit();
    const initialize_id = try state.beginDetachedForPath("/tmp/extmark-demo.zig", "/tmp");
    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try state.handleIncoming(initialize_response);
    try state.syncBuffer(&buffer, false);

    const formatting_id = try state.requestFormatting(&buffer, 4, true);
    const response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"newText\":\"// fmt\\n\"}}]}}", .{formatting_id});
    defer std.testing.allocator.free(response);
    try state.handleIncoming(response);
    try std.testing.expectEqual(@as(usize, 1), try state.applyPendingWorkspaceEdit((&[_]buffer_module.Buffer{buffer})[0..]));
    try std.testing.expectEqual(@as(usize, 13), buffer.extmarks.mark(1, mark_id).?.start);
}''',
)

# Public Zig API.
replace_once("src/api/root.zig", "pub const pins = @import(\"../pins.zig\");\n", "pub const pins = @import(\"../pins.zig\");\npub const extmarks = @import(\"../extmarks.zig\");\npub const plugin_ui = @import(\"../plugin_ui.zig\");\n")
replace_once("src/api/root.zig", "pub const PinId = pins.PinId;\n", "pub const PinId = pins.PinId;\npub const NamespaceId = extmarks.NamespaceId;\npub const ExtmarkId = extmarks.ExtmarkId;\n")
replace_once(
    "src/api/root.zig",
    "    pub fn optionGet(self: *const Api, name: options.Name) options.Value {",
    '''    pub fn namespaceCreate(self: *Api, editor: *editor_module.Editor, name: []const u8) !NamespaceId {
        _ = self;
        return editor.extmarkNamespaceCreate(name);
    }

    pub fn namespaceDelete(self: *Api, editor: *editor_module.Editor, namespace_id: NamespaceId) bool {
        _ = self;
        return editor.extmarkNamespaceDelete(namespace_id);
    }

    pub fn extmarkSet(
        self: *Api,
        editor: *editor_module.Editor,
        buffer: BufferHandle,
        namespace_id: NamespaceId,
        start: usize,
        opts: extmarks.Options,
    ) !ExtmarkId {
        _ = self;
        return editor.extmarkSet(buffer.id, namespace_id, start, opts);
    }

    pub fn extmarkDelete(self: *Api, editor: *editor_module.Editor, buffer: BufferHandle, namespace_id: NamespaceId, id: ExtmarkId) bool {
        _ = self;
        return editor.extmarkDelete(buffer.id, namespace_id, id);
    }

    pub fn extmarkClear(self: *Api, editor: *editor_module.Editor, buffer: BufferHandle, namespace_id: NamespaceId) bool {
        _ = self;
        return editor.extmarkClear(buffer.id, namespace_id);
    }

    pub fn diagnosticPublish(
        self: *Api,
        editor: *editor_module.Editor,
        buffer: BufferHandle,
        namespace_id: NamespaceId,
        diagnostics: []const extmarks.Diagnostic,
    ) !void {
        _ = self;
        try editor.publishDiagnostics(buffer.id, namespace_id, diagnostics);
    }

    pub fn popupOpen(self: *Api, editor: *editor_module.Editor, title: []const u8, labels: []const []const u8) !void {
        _ = self;
        try editor.popupShow(.plugin, title, labels);
    }

    pub fn popupClose(self: *Api, editor: *editor_module.Editor) void {
        _ = self;
        editor.popupClose();
    }

    pub fn optionGet(self: *const Api, name: options.Name) options.Value {''',
)
append_once(
    "src/api/root.zig",
    'test "public extmark diagnostics and popup API share native editor state"',
    r'''test "public extmark diagnostics and popup API share native editor state" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha beta");
    var api = Api.init(std.testing.allocator);
    defer api.deinit();
    const buffer = api.currentBuffer(&editor);
    const ns = try api.namespaceCreate(&editor, "plugin.demo");
    const id = try api.extmarkSet(&editor, buffer, ns, 6, .{ .highlight = "Demo", .sign = "*", .virtual_text = "note" });
    try std.testing.expectEqual(@as(usize, 6), editor.currentBuffer().extmarks.mark(ns, id).?.start);
    try api.diagnosticPublish(&editor, buffer, ns, &.{.{ .start = 0, .end = 5, .severity = .warning, .message = "warn" }});
    try std.testing.expectEqual(@as(usize, 1), editor.currentBuffer().extmarks.diagnosticCount());
    try api.popupOpen(&editor, "Demo", &.{ "one", "two" });
    try std.testing.expect(editor.popup.open);
    try std.testing.expectEqualStrings("one", editor.popup.selectedLabel().?);
}''',
)

# Core suite and coherent version/capability surface.
replace_once("src/core_tests.zig", '    _ = @import("pins.zig");\n', '    _ = @import("pins.zig");\n    _ = @import("extmarks.zig");\n    _ = @import("plugin_ui.zig");\n')
replace_once("src/app.zig", 'pub const version = "0.6.0";', 'pub const version = "0.7.0";')
replace_once("src/app.zig", "try lua.eval(\"zim.version = '0.6.0'\");", "try lua.eval(\"zim.version = '0.7.0'\");")
replace_once("build.zig.zon", '.version = "0.6.0",', '.version = "0.7.0",')
replace_once("src/plugin_manager.zig", 'pub const zim_version = "0.6.0";', 'pub const zim_version = "0.7.0";')
replace_once("src/plugin_manager.zig", '        if (std.mem.eql(u8, capability, "pins")) continue;\n', '        if (std.mem.eql(u8, capability, "pins")) continue;\n        if (std.mem.eql(u8, capability, "extmarks")) continue;\n        if (std.mem.eql(u8, capability, "diagnostics")) continue;\n        if (std.mem.eql(u8, capability, "ui")) continue;\n')
