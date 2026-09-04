from pathlib import Path


def replace_once(path: str, old: str, new: str):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one marker, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path: str, marker: str, content: str):
    p = Path(path)
    text = p.read_text()
    if marker in text:
        return
    p.write_text(text + "\n" + content + "\n")

# Lua: public extmark, diagnostics, and UI wrappers over the public Zig API.
replace_once(
    "src/lua_runtime.zig",
    "    \\\\function zim.pin.list() return n.pin_list() end\n    \\\\zim.lsp = {}",
    """    \\function zim.pin.list() return n.pin_list() end
    \\zim.extmark = {}
    \\function zim.extmark.namespace(name) return n.namespace_create(name) end
    \\function zim.extmark.namespace_del(namespace) return n.namespace_delete(namespace) end
    \\function zim.extmark.set(buffer, namespace, line, column, opts)
    \\  opts = opts or {}
    \\  return n.extmark_set(buffer, namespace, line, column, opts.end_line, opts.end_column, opts.highlight, opts.sign, opts.virtual_text, opts.right_gravity or 'right', opts.end_right_gravity or 'left')
    \\end
    \\function zim.extmark.del(buffer, namespace, id) return n.extmark_delete(buffer, namespace, id) end
    \\function zim.extmark.clear(buffer, namespace) return n.extmark_clear(buffer, namespace) end
    \\zim.diagnostic = {}
    \\function zim.diagnostic.publish(buffer, namespace, items)
    \\  n.extmark_clear(buffer, namespace)
    \\  for _, item in ipairs(items or {}) do
    \\    n.diagnostic_add(buffer, namespace, item.line, item.column or 1, item.end_line or item.line, item.end_column or item.column or 1, item.severity or 'information', item.message or '')
    \\  end
    \\end
    \\zim.ui = {}
    \\function zim.ui.popup(title, items) return n.popup_open(title, table.unpack(items or {})) end
    \\function zim.ui.popup_close() return n.popup_close() end
    \\zim.lsp = {}""",
)
replace_once(
    "src/lua_runtime.zig",
    '            .{ .name = "pin_list", .func = zlua.wrap(nativePinList) },\n            .{ .name = "lsp", .func = zlua.wrap(nativeLsp) },',
    '''            .{ .name = "pin_list", .func = zlua.wrap(nativePinList) },
            .{ .name = "namespace_create", .func = zlua.wrap(nativeNamespaceCreate) },
            .{ .name = "namespace_delete", .func = zlua.wrap(nativeNamespaceDelete) },
            .{ .name = "extmark_set", .func = zlua.wrap(nativeExtmarkSet) },
            .{ .name = "extmark_delete", .func = zlua.wrap(nativeExtmarkDelete) },
            .{ .name = "extmark_clear", .func = zlua.wrap(nativeExtmarkClear) },
            .{ .name = "diagnostic_add", .func = zlua.wrap(nativeDiagnosticAdd) },
            .{ .name = "popup_open", .func = zlua.wrap(nativePopupOpen) },
            .{ .name = "popup_close", .func = zlua.wrap(nativePopupClose) },
            .{ .name = "lsp", .func = zlua.wrap(nativeLsp) },''',
)
replace_once("src/lua_runtime.zig", '_ = self.lua.pushString("0.6.0");', '_ = self.lua.pushString("0.7.0");')
replace_once("src/lua_runtime.zig", "        \\\\assert(zim.version == '0.6.0')", "        \\\\assert(zim.version == '0.7.0')")
replace_once(
    "src/lua_runtime.zig",
    "fn nativeLsp(lua: *Lua) i32 {",
    r'''fn nativeNamespaceCreate(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const id = runtime.api.namespaceCreate(runtime.editor, lua.checkString(1)) catch lua.raiseErrorStr("failed to create namespace", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn nativeNamespaceDelete(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const id: api_module.NamespaceId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("namespace must be an integer", .{}));
    lua.pushBoolean(runtime.api.namespaceDelete(runtime.editor, id));
    return 1;
}

fn nativeExtmarkSet(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const buffer_id: editor_module.BufferId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("buffer must be an integer handle", .{}));
    const namespace_id: api_module.NamespaceId = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("namespace must be an integer", .{}));
    const line: usize = positiveIndex(lua, 3, "line");
    const column: usize = positiveIndex(lua, 4, "column");
    const buffer = runtime.editor.bufferByIdConst(buffer_id) orelse lua.raiseErrorStr("invalid buffer handle", .{});
    const start = byteOffsetForOneBasedPosition(buffer.text.items, line, column);
    const end = if (lua.getTop() >= 6 and !lua.isNoneOrNil(5) and !lua.isNoneOrNil(6))
        byteOffsetForOneBasedPosition(buffer.text.items, positiveIndex(lua, 5, "end_line"), positiveIndex(lua, 6, "end_column"))
    else
        null;
    const highlight = optionalString(lua, 7);
    const sign = optionalString(lua, 8);
    const virtual_text = optionalString(lua, 9);
    const right_gravity = gravity(lua, 10, .right);
    const end_right_gravity = gravity(lua, 11, .left);
    const id = runtime.api.extmarkSet(runtime.editor, .{ .id = buffer_id }, namespace_id, start, .{
        .end = end,
        .right_gravity = right_gravity,
        .end_right_gravity = end_right_gravity,
        .highlight = highlight,
        .sign = sign,
        .virtual_text = virtual_text,
    }) catch lua.raiseErrorStr("failed to create extmark", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn nativeExtmarkDelete(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const buffer_id: editor_module.BufferId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("buffer must be an integer handle", .{}));
    const namespace_id: api_module.NamespaceId = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("namespace must be an integer", .{}));
    const id: api_module.ExtmarkId = @intCast(lua.toInteger(3) catch lua.raiseErrorStr("extmark id must be an integer", .{}));
    lua.pushBoolean(runtime.api.extmarkDelete(runtime.editor, .{ .id = buffer_id }, namespace_id, id));
    return 1;
}

fn nativeExtmarkClear(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const buffer_id: editor_module.BufferId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("buffer must be an integer handle", .{}));
    const namespace_id: api_module.NamespaceId = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("namespace must be an integer", .{}));
    lua.pushBoolean(runtime.api.extmarkClear(runtime.editor, .{ .id = buffer_id }, namespace_id));
    return 1;
}

fn nativeDiagnosticAdd(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const buffer_id: editor_module.BufferId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("buffer must be an integer handle", .{}));
    const namespace_id: api_module.NamespaceId = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("namespace must be an integer", .{}));
    const buffer = runtime.editor.bufferByIdConst(buffer_id) orelse lua.raiseErrorStr("invalid buffer handle", .{});
    const start = byteOffsetForOneBasedPosition(buffer.text.items, positiveIndex(lua, 3, "line"), positiveIndex(lua, 4, "column"));
    const finish = byteOffsetForOneBasedPosition(buffer.text.items, positiveIndex(lua, 5, "end_line"), positiveIndex(lua, 6, "end_column"));
    const severity = diagnosticSeverity(lua.checkString(7)) orelse lua.raiseErrorStr("invalid diagnostic severity", .{});
    const message = lua.checkString(8);
    const visual = diagnosticVisual(severity);
    _ = runtime.api.extmarkSet(runtime.editor, .{ .id = buffer_id }, namespace_id, start, .{
        .end = finish,
        .right_gravity = .left,
        .end_right_gravity = .right,
        .highlight = visual.highlight,
        .sign = visual.sign,
        .virtual_text = message,
        .diagnostic_message = message,
        .diagnostic_severity = severity,
    }) catch lua.raiseErrorStr("failed to publish diagnostic", .{});
    return 0;
}

fn nativePopupOpen(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const title = lua.checkString(1);
    const top = lua.getTop();
    const count: usize = if (top > 1) @intCast(top - 1) else 0;
    const labels = runtime.allocator.alloc([]const u8, count) catch lua.raiseErrorStr("out of memory", .{});
    defer runtime.allocator.free(labels);
    for (labels, 0..) |*label, index| label.* = lua.checkString(@intCast(index + 2));
    runtime.api.popupOpen(runtime.editor, title, labels) catch lua.raiseErrorStr("failed to open popup", .{});
    return 0;
}

fn nativePopupClose(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    runtime.api.popupClose(runtime.editor);
    return 0;
}

fn nativeLsp(lua: *Lua) i32 {''',
)
replace_once(
    "src/lua_runtime.zig",
    "fn decodeSingleCodepoint(text: []const u8) !u21 {",
    r'''fn optionalString(lua: *Lua, index: i32) ?[]const u8 {
    if (lua.getTop() < index or lua.isNoneOrNil(index)) return null;
    return lua.checkString(index);
}

fn positiveIndex(lua: *Lua, index: i32, comptime label: []const u8) usize {
    const value = lua.toInteger(index) catch lua.raiseErrorStr(label ++ " must be an integer", .{});
    if (value < 1) lua.raiseErrorStr(label ++ " must be >= 1", .{});
    return @intCast(value);
}

fn byteOffsetForOneBasedPosition(text: []const u8, line: usize, column: usize) usize {
    var current_line: usize = 1;
    var start: usize = 0;
    while (current_line < line and start < text.len) : (start += 1) {
        if (text[start] == '\n') current_line += 1;
    }
    if (current_line != line) return text.len;
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    return @min(start + column - 1, end);
}

fn gravity(lua: *Lua, index: i32, default: api_module.extmarks.Gravity) api_module.extmarks.Gravity {
    const value = optionalString(lua, index) orelse return default;
    if (std.mem.eql(u8, value, "left")) return .left;
    if (std.mem.eql(u8, value, "right")) return .right;
    lua.raiseErrorStr("gravity must be 'left' or 'right'", .{});
}

fn diagnosticSeverity(value: []const u8) ?api_module.extmarks.DiagnosticSeverity {
    if (std.mem.eql(u8, value, "error")) return .error_level;
    if (std.mem.eql(u8, value, "warning") or std.mem.eql(u8, value, "warn")) return .warning;
    if (std.mem.eql(u8, value, "information") or std.mem.eql(u8, value, "info")) return .information;
    if (std.mem.eql(u8, value, "hint")) return .hint;
    return null;
}

fn diagnosticVisual(severity: api_module.extmarks.DiagnosticSeverity) struct { highlight: []const u8, sign: []const u8 } {
    return switch (severity) {
        .error_level => .{ .highlight = "DiagnosticError", .sign = "E" },
        .warning => .{ .highlight = "DiagnosticWarn", .sign = "W" },
        .information => .{ .highlight = "DiagnosticInfo", .sign = "I" },
        .hint => .{ .highlight = "DiagnosticHint", .sign = "H" },
    };
}

fn decodeSingleCodepoint(text: []const u8) !u21 {''',
)
append_once(
    "src/lua_runtime.zig",
    'test "Lua extmarks diagnostics and popup bind the public Zig API"',
    r'''test "Lua extmarks diagnostics and popup bind the public Zig API" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha beta");
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &api, &editor);
    defer runtime.deinit();

    try runtime.eval(
        \\local buffer = zim.buf.current()
        \\local ns = zim.extmark.namespace('lua.demo')
        \\local id = zim.extmark.set(buffer, ns, 1, 7, { end_line = 1, end_column = 11, highlight = 'Demo', sign = '*', virtual_text = 'lua note' })
        \\assert(id ~= nil)
        \\zim.diagnostic.publish(buffer, ns, {{ line = 1, column = 1, end_line = 1, end_column = 6, severity = 'warning', message = 'from lua' }})
        \\zim.ui.popup('LUA POPUP', {'one', 'two'})
    );
    try std.testing.expectEqual(@as(usize, 1), editor.currentBuffer().extmarks.diagnosticCount());
    try std.testing.expect(editor.popup.open);
    try std.testing.expectEqualStrings("LUA POPUP", editor.popup.title.items);
    try std.testing.expectEqual(@as(usize, 2), editor.popup.items.items.len);
}''',
)

# Editor: completion responses become native popup state; popup keys never enter modal grammar.
replace_once(
    "src/editor.zig",
    "        try self.lsp_state.handleIncoming(body);\n        try self.syncLspDiagnosticExtmarks();",
    "        try self.lsp_state.handleIncoming(body);\n        try self.syncLspDiagnosticExtmarks();\n        try self.syncCompletionPopup();",
)
replace_once(
    "src/editor.zig",
    "    fn syncLspDiagnosticExtmarks(self: *Editor) !void {",
    r'''    fn syncCompletionPopup(self: *Editor) !void {
        if (self.completion_generation_seen == self.lsp_state.completion_generation) return;
        self.completion_generation_seen = self.lsp_state.completion_generation;
        const completions = self.lsp_state.last_completions orelse {
            self.popup.close();
            return;
        };
        if (completions.items.len == 0) {
            self.popup.close();
            self.setStatus("no completions", .{});
            return;
        }
        const labels = try self.allocator.alloc([]const u8, completions.items.len);
        defer self.allocator.free(labels);
        for (completions.items, labels) |item, *label| label.* = item.label;
        try self.popup.show(.completion, "COMPLETION", labels);
        self.setStatus("completion: j/k select · Enter accept · Esc close", .{});
    }

    fn syncLspDiagnosticExtmarks(self: *Editor) !void {''',
)
replace_once(
    "src/editor.zig",
    "        const key = self.resolveKey(incoming);\n        if (self.recording_macro) |macro_index| {",
    r'''        const key = self.resolveKey(incoming);
        if (self.popup.open) {
            const handled = try self.handlePopup(key);
            if (handled) {
                const after_window = self.currentWindowConst();
                const after_buffer = self.currentBufferConst();
                if (after_window.id != before_window_id or after_buffer.id != before_buffer_id or after_buffer.revision != before_revision) {
                    try self.syncCurrentLanguage(false);
                    try self.syncCurrentLsp(false);
                }
            }
            return .{ .handled = handled, .command_open = self.commandOpen(), .quit_requested = self.quit_requested };
        }
        if (self.recording_macro) |macro_index| {''',
)
replace_once(
    "src/editor.zig",
    "    fn handlePinSwitcher(self: *Editor, key: Key) !bool {",
    r'''    fn handlePopup(self: *Editor, key: Key) !bool {
        switch (key) {
            .escape => self.popup.close(),
            .up => self.popup.move(-1),
            .down => self.popup.move(1),
            .enter => {
                if (self.popup.kind == .completion) {
                    if (self.lsp_state.last_completions) |completions| {
                        if (self.popup.selected < completions.items.len) {
                            const insert_text = completions.items[self.popup.selected].insert_text;
                            const buffer = self.currentBuffer();
                            const cursor = self.cursor();
                            try buffer.recordUndo(self.allocator, cursor);
                            try buffer.insertBytesAt(self.allocator, cursor, insert_text);
                            buffer.markChanged();
                            self.currentWindow().cursor = cursor + insert_text.len;
                            self.setStatus("completion: {s}", .{completions.items[self.popup.selected].label});
                        }
                    }
                } else if (self.popup.selectedLabel()) |label| {
                    self.setStatus("popup: {s}", .{label});
                }
                self.popup.close();
            },
            .codepoint => |cp| switch (cp) {
                'j' => self.popup.move(1),
                'k' => self.popup.move(-1),
                'q' => self.popup.close(),
                else => {},
            },
            else => {},
        }
        return true;
    }

    fn handlePinSwitcher(self: *Editor, key: Key) !bool {''',
)
append_once(
    "src/editor.zig",
    'test "LSP completion response opens native popup and acceptance inserts insertText"',
    r'''test "LSP completion response opens native popup and acceptance inserts insertText" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, "/tmp/completion.zig");
    defer editor.deinit();
    try editor.setText("x");
    const initialize_id = try editor.lspBeginDetachedForCurrent();
    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try editor.lspHandleIncoming(initialize_response);
    const completion_id = try editor.lspRequestCompletion();
    const completion_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"label\":\"value\",\"insertText\":\"value()\"}}]}}", .{completion_id});
    defer std.testing.allocator.free(completion_response);
    try editor.lspHandleIncoming(completion_response);
    try std.testing.expect(editor.popup.open);
    try std.testing.expectEqual(@import("plugin_ui.zig").Kind.completion, editor.popup.kind);
    _ = try editor.handleKey(.enter);
    try std.testing.expectEqualStrings("value()x", editor.text());
    try std.testing.expect(!editor.popup.open);
}''',
)

# EditorView: extmark paint and generic popup coarse-state publishing.
replace_once(
    "src/editor_view.zig",
    "    pin_switcher_index: usize,\n};",
    "    pin_switcher_index: usize,\n    extmarks_revision: u64,\n    popup_revision: u64,\n};",
)
replace_once(
    "src/editor_view.zig",
    "        .pin_switcher_index = editor.pin_switcher_index,\n    };",
    "        .pin_switcher_index = editor.pin_switcher_index,\n        .extmarks_revision = editor.currentBufferConst().extmarks.revision,\n        .popup_revision = editor.popup.revision,\n    };",
)
replace_once(
    "src/editor_view.zig",
    "        before.pin_switcher_index != after.pin_switcher_index;",
    "        before.pin_switcher_index != after.pin_switcher_index or\n        before.extmarks_revision != after.extmarks_revision or\n        before.popup_revision != after.popup_revision;",
)
replace_once(
    "src/editor_view.zig",
    '''            try paintSyntaxHighlights(
                editor,
                grid,
                buffer.id,
                line_start,
                end,
                bounds.x + gutter,
                bounds.y + row,
                content_width,
            );''',
    '''            try paintSyntaxHighlights(
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
            );''',
)
replace_once(
    "src/editor_view.zig",
    "fn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {",
    r'''fn paintExtmarks(
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
                    try grid.paintUtf8Styled(content_x + used + 1, y, annotation, content_width - used - 1, .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true, .dim = true } });
                }
            }
        }
    }
}

fn extmarkStyle(name: ?[]const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {
    const value = name orelse return .{ .foreground = .{ .ansi = 13 } };
    if (std.mem.eql(u8, value, "DiagnosticError")) return .{ .foreground = .{ .ansi = 9 }, .attributes = .{ .bold = true } };
    if (std.mem.eql(u8, value, "DiagnosticWarn")) return .{ .foreground = .{ .ansi = 11 }, .attributes = .{ .bold = true } };
    if (std.mem.eql(u8, value, "DiagnosticInfo")) return .{ .foreground = .{ .ansi = 14 } };
    if (std.mem.eql(u8, value, "DiagnosticHint")) return .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } };
    return .{ .foreground = .{ .ansi = 13 } };
}

fn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {''',
)
replace_once(
    "src/editor_view.zig",
    "        .pinSwitcherIndex = state.editor.pin_switcher_index,\n    }, .{});",
    "        .pinSwitcherIndex = state.editor.pin_switcher_index,\n        .popupOpen = state.editor.popup.open,\n        .popupKind = @tagName(state.editor.popup.kind),\n        .popupTitle = state.editor.popup.title.items,\n        .popupItems = state.editor.popup.items.items,\n        .popupSelected = state.editor.popup.selected,\n    }, .{});",
)
replace_once(
    "src/editor_view.zig",
    '''fn diagnosticCount(editor: *const editor_module.Editor) usize {
    var total: usize = 0;
    for (editor.lsp_state.diagnostics.entries.items) |entry| total += entry.items.items.len;
    return total;
}''',
    '''fn diagnosticCount(editor: *const editor_module.Editor) usize {
    var total: usize = 0;
    for (editor.buffers.items) |buffer| total += buffer.extmarks.diagnosticCount();
    return total;
}''',
)

# Hondo: passive generic popup driven entirely by native state.
replace_once(
    "ui/src/bundle.ts",
    "type PinView = { id: number; path: string; line: number; column: number; label?: string };\n",
    "type PinView = { id: number; path: string; line: number; column: number; label?: string };\ntype NativePopupItem = { label: string; detail?: string };\n",
)
replace_once(
    "ui/src/bundle.ts",
    "const [pinSwitcherIndex, setPinSwitcherIndex] = createSignal(0);\n",
    "const [pinSwitcherIndex, setPinSwitcherIndex] = createSignal(0);\nconst [nativePopupOpen, setNativePopupOpen] = createSignal(false);\nconst [nativePopupKind, setNativePopupKind] = createSignal('plugin');\nconst [nativePopupTitle, setNativePopupTitle] = createSignal('');\nconst [nativePopupItems, setNativePopupItems] = createSignal<NativePopupItem[]>([]);\nconst [nativePopupSelected, setNativePopupSelected] = createSignal(0);\n",
)
replace_once(
    "ui/src/bundle.ts",
    "function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {",
    r'''function nativePopupItemsPayload(value: HondoValue): NativePopupItem[] {
  if (!Array.isArray(value)) return [];
  const result: NativePopupItem[] = [];
  for (const candidate of value) {
    const item = payloadObject(candidate);
    if (!item || typeof item.label !== 'string') continue;
    result.push({ label: item.label, detail: typeof item.detail === 'string' ? item.detail : undefined });
  }
  return result;
}

function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {''',
)
replace_once(
    "ui/src/bundle.ts",
    "  if (typeof value.pinSwitcherIndex === 'number') setPinSwitcherIndex(value.pinSwitcherIndex);\n",
    "  if (typeof value.pinSwitcherIndex === 'number') setPinSwitcherIndex(value.pinSwitcherIndex);\n  if (typeof value.popupOpen === 'boolean') setNativePopupOpen(value.popupOpen);\n  if (typeof value.popupKind === 'string') setNativePopupKind(value.popupKind);\n  if (typeof value.popupTitle === 'string') setNativePopupTitle(value.popupTitle);\n  if (value.popupItems !== undefined) setNativePopupItems(nativePopupItemsPayload(value.popupItems));\n  if (typeof value.popupSelected === 'number') setNativePopupSelected(value.popupSelected);\n",
)
replace_once(
    "ui/src/bundle.ts",
    "const disposeRender = render(() =>\n",
    r'''const nativePopup = Popup({
  get x() {
    return Math.max(0, Math.floor((terminalWidth() - 58) / 2));
  },
  get y() {
    return Math.max(1, Math.floor((terminalHeight() - Math.min(16, nativePopupItems().length + 5)) / 2));
  },
  zIndex: 30,
  style: { width: 58, paddingX: 1, background: '#20242c' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-cyan' }, children: () => nativePopupTitle() || nativePopupKind().toUpperCase() }),
      Text({ style: { dim: true }, children: () => nativePopupKind() === 'completion' ? 'j/k select · Enter accept · Esc close' : 'j/k select · Enter choose · Esc close' }),
      () => nativePopupItems().map((item, index) =>
        Text({
          get style() {
            return { bold: index === nativePopupSelected(), reverse: index === nativePopupSelected(), foreground: index === nativePopupSelected() ? 'bright-cyan' : 'bright-white' } as const;
          },
          get children() {
            return item.detail ? `${item.label}  ${item.detail}` : item.label;
          },
        }),
      ),
    ],
  }),
});

const disposeRender = render(() =>
''',
)
replace_once(
    "ui/src/bundle.ts",
    "      () => (pinSwitcherOpen() ? pinSwitcher : null),\n",
    "      () => (nativePopupOpen() ? nativePopup : null),\n      () => (pinSwitcherOpen() ? pinSwitcher : null),\n",
)

# Native integration: Lua popup and LSP completion never cross into JS key handlers.
append_once(
    "src/tui.zig",
    'test "plugin popup and completion popup render in Hondo while keys stay native"',
    r'''test "plugin popup and completion popup render in Hondo while keys stay native" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, "/tmp/popup-demo.zig");
    defer editor.deinit();
    try editor.setText("x");
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var lua = try lua_runtime.Runtime.init(std.testing.allocator, &api, &editor);
    defer lua.deinit();
    try lua.eval("zim.ui.popup('PLUGIN POPUP', {'one', 'two'})");

    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 120, 30);
    defer app.deinit();
    const moved = try app.dispatch(.{ .key = .{ .codepoint = 'j' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, moved.path);
    try std.testing.expectEqual(@as(usize, 1), editor.popup.selected);
    try std.testing.expect(sceneContainsText(app.scene, "PLUGIN POPUP"));
    _ = try app.dispatch(.{ .key = .escape });
    try std.testing.expect(!editor.popup.open);

    const initialize_id = try editor.lspBeginDetachedForCurrent();
    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try editor.lspHandleIncoming(initialize_response);
    const completion_id = try editor.lspRequestCompletion();
    const completion_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"label\":\"value\",\"detail\":\"const\",\"insertText\":\"value()\"}}]}}", .{completion_id});
    defer std.testing.allocator.free(completion_response);
    try editor.lspHandleIncoming(completion_response);

    const completion_move = try app.dispatch(.{ .key = .down });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, completion_move.path);
    try std.testing.expect(sceneContainsText(app.scene, "COMPLETION"));
    const accepted = try app.dispatch(.{ .key = .enter });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, accepted.path);
    try std.testing.expectEqualStrings("value()x", editor.text());
    try std.testing.expect(!editor.popup.open);

    try app.runtime.eval(
        "if (globalThis.__zimJsKeyEvents !== 0) throw new Error('popup key crossed into JavaScript');",
        "zim-popup-native-key-proof.js",
    );
}''',
)
