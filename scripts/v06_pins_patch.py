from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one marker, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path: str, marker: str, block: str) -> None:
    p = Path(path)
    text = p.read_text()
    if marker in text:
        return
    p.write_text(text.rstrip() + "\n\n" + block.rstrip() + "\n")


# Pins model revision for UI/state invalidation.
replace_once(
    "src/pins.zig",
    "    next_id: PinId = 1,\n    root: ?[]u8 = null,",
    "    next_id: PinId = 1,\n    revision: u64 = 0,\n    root: ?[]u8 = null,",
)
replace_once(
    "src/pins.zig",
    "        self.storage_path = storage_path;\n        try self.load();",
    "        self.storage_path = storage_path;\n        try self.load();\n        self.revision +%= 1;",
)
replace_once(
    "src/pins.zig",
    "        try self.save();\n        return id;",
    "        try self.save();\n        self.revision +%= 1;\n        return id;",
)
replace_once(
    "src/pins.zig",
    "        self.entries.items.len -= 1;\n        try self.save();\n        return true;",
    "        self.entries.items.len -= 1;\n        try self.save();\n        self.revision +%= 1;\n        return true;",
)
replace_once(
    "src/pins.zig",
    "        self.entries.items[to] = moving;\n        try self.save();\n        return true;",
    "        self.entries.items[to] = moving;\n        try self.save();\n        self.revision +%= 1;\n        return true;",
)

# Editor ownership, persistence configuration, commands, switcher, and native jumps.
replace_once(
    "src/editor.zig",
    'const lsp_bridge = @import("lsp_bridge.zig");\n',
    'const lsp_bridge = @import("lsp_bridge.zig");\nconst pins_module = @import("pins.zig");\n',
)
replace_once(
    "src/editor.zig",
    "    lsp_state: lsp_bridge.State,\n\n    unnamed_register:",
    "    lsp_state: lsp_bridge.State,\n    pins: pins_module.Store,\n    pin_switcher_open: bool = false,\n    pin_switcher_index: usize = 0,\n\n    unnamed_register:",
)
replace_once(
    "src/editor.zig",
    "            .lsp_state = lsp_bridge.State.init(allocator, io),\n        };",
    "            .lsp_state = lsp_bridge.State.init(allocator, io),\n            .pins = pins_module.Store.init(allocator, io),\n        };",
)
replace_once(
    "src/editor.zig",
    "        self.language_state.deinit();\n        self.lsp_state.deinit();",
    "        self.language_state.deinit();\n        self.lsp_state.deinit();\n        self.pins.deinit();",
)
replace_once(
    "src/editor.zig",
    "    pub fn currentPath(self: *const Editor) ?[]const u8 {\n        return self.currentBufferConst().path;\n    }\n",
    """    pub fn currentPath(self: *const Editor) ?[]const u8 {
        return self.currentBufferConst().path;
    }

    pub fn pinProjectRoot(self: *const Editor) []const u8 {
        if (self.project_root) |root| return root;
        if (self.currentPath()) |path| return std.fs.path.dirname(path) orelse ".";
        return ".";
    }

    pub fn configurePins(self: *Editor, config_root: []const u8) !void {
        try self.pins.configure(config_root, self.pinProjectRoot());
    }

    pub fn pinAddCurrent(self: *Editor, label: ?[]const u8) !?pins_module.PinId {
        const path = self.currentPath() orelse {
            self.setStatus("PinAdd requires a file-backed buffer", .{});
            return null;
        };
        const position = self.cursorPosition();
        const id = try self.pins.add(path, position.line, position.column, label);
        self.setStatus("pin {d}: {s}:{d}:{d}", .{ self.pins.count(), path, position.line, position.column });
        return id;
    }

    pub fn pinRemoveSlot(self: *Editor, slot: usize) !bool {
        if (!(try self.pins.removeSlot(slot))) {
            self.setStatus("pin {d} does not exist", .{slot});
            return false;
        }
        if (self.pin_switcher_index >= self.pins.count() and self.pin_switcher_index != 0) self.pin_switcher_index -= 1;
        if (self.pins.count() == 0) self.pin_switcher_open = false;
        self.setStatus("removed pin {d}", .{slot});
        return true;
    }

    pub fn pinMoveSlot(self: *Editor, from_slot: usize, to_slot: usize) !bool {
        if (!(try self.pins.moveSlot(from_slot, to_slot))) {
            self.setStatus("invalid pin move {d} -> {d}", .{ from_slot, to_slot });
            return false;
        }
        self.setStatus("moved pin {d} -> {d}", .{ from_slot, to_slot });
        return true;
    }

    pub fn pinJumpSlot(self: *Editor, slot: usize, exact: bool) !bool {
        const entry = self.pins.entryAtSlot(slot) orelse {
            self.setStatus("pin {d} does not exist", .{slot});
            return false;
        };
        const resolved = try self.pins.resolvePathAlloc(entry);
        defer self.allocator.free(resolved);

        const current_matches = if (self.currentPath()) |path| std.mem.eql(u8, path, resolved) else false;
        if (!current_matches) {
            _ = std.Io.Dir.cwd().statFile(self.io, resolved) catch |err| switch (err) {
                error.FileNotFound => {
                    self.setStatus("pin {d} target missing: {s}", .{ slot, resolved });
                    return false;
                },
                else => return err,
            };
            if (!(try self.editPath(resolved))) return false;
        }
        self.setCursorFromLineColumn(entry.line - 1, if (exact) entry.column - 1 else 0);
        self.setStatus("pin {d}: {s}:{d}:{d}", .{ slot, resolved, entry.line, entry.column });
        return true;
    }

    pub fn openPinSwitcher(self: *Editor) bool {
        if (self.pins.count() == 0) {
            self.setStatus("no pins; use :PinAdd first", .{});
            return false;
        }
        self.pin_switcher_open = true;
        if (self.pin_switcher_index >= self.pins.count()) self.pin_switcher_index = 0;
        self.setStatus("pins: 1-9 jump · j/k select · Enter jump · Esc close", .{});
        return true;
    }

    pub fn closePinSwitcher(self: *Editor) void {
        self.pin_switcher_open = false;
    }
""",
)
replace_once(
    "src/editor.zig",
    "        const handled = switch (self.mode) {\n            .insert => try self.handleInsert(key),",
    "        const handled = if (self.pin_switcher_open) try self.handlePinSwitcher(key) else switch (self.mode) {\n            .insert => try self.handleInsert(key),",
)
replace_once(
    "src/editor.zig",
    "        if (self.pending_mark_line or self.pending_mark_exact) {\n            const linewise = self.pending_mark_line;\n            self.pending_mark_line = false;\n            self.pending_mark_exact = false;\n            const index = letterIndex(cp) orelse return false;\n            return self.jumpToMark(index, linewise);\n        }",
    """        if (self.pending_mark_line or self.pending_mark_exact) {
            const linewise = self.pending_mark_line;
            self.pending_mark_line = false;
            self.pending_mark_exact = false;
            if (cp >= '1' and cp <= '9') return self.pinJumpSlot(@intCast(cp - '0'), !linewise);
            const index = letterIndex(cp) orelse return false;
            return self.jumpToMark(index, linewise);
        }""",
)
replace_once(
    "src/editor.zig",
    "            if (cp == ';') return self.changeListMove(-1);\n            if (cp == ',') return self.changeListMove(1);",
    "            if (cp == 'p') return self.openPinSwitcher();\n            if (cp == ';') return self.changeListMove(-1);\n            if (cp == ',') return self.changeListMove(1);",
)
replace_once(
    "src/editor.zig",
    "    fn handleNormal(self: *Editor, key: Key) !bool {",
    """    fn handlePinSwitcher(self: *Editor, key: Key) !bool {
        if (self.pins.count() == 0) {
            self.pin_switcher_open = false;
            return true;
        }
        return switch (key) {
            .escape => blk: {
                self.closePinSwitcher();
                break :blk true;
            },
            .enter => blk: {
                const slot = self.pin_switcher_index + 1;
                const jumped = try self.pinJumpSlot(slot, true);
                if (jumped) self.closePinSwitcher();
                break :blk true;
            },
            .up => blk: {
                self.pin_switcher_index = if (self.pin_switcher_index == 0) self.pins.count() - 1 else self.pin_switcher_index - 1;
                break :blk true;
            },
            .down => blk: {
                self.pin_switcher_index = (self.pin_switcher_index + 1) % self.pins.count();
                break :blk true;
            },
            .codepoint => |cp| blk: {
                if (cp >= '1' and cp <= '9') {
                    const slot: usize = @intCast(cp - '0');
                    if (slot <= self.pins.count() and try self.pinJumpSlot(slot, true)) self.closePinSwitcher();
                    break :blk true;
                }
                if (cp == 'j') self.pin_switcher_index = (self.pin_switcher_index + 1) % self.pins.count() else if (cp == 'k') self.pin_switcher_index = if (self.pin_switcher_index == 0) self.pins.count() - 1 else self.pin_switcher_index - 1 else if (cp == 'q') self.closePinSwitcher();
                break :blk true;
            },
            else => true,
        };
    }

    fn handleNormal(self: *Editor, key: Key) !bool {""",
)
replace_once(
    "src/editor.zig",
    "        } else if (std.mem.eql(u8, name, \"symbols\")) {",
    """        } else if (std.mem.eql(u8, name, "PinAdd") or std.mem.eql(u8, name, "pinadd")) {
            _ = try self.pinAddCurrent(if (args.len == 0) null else args);
        } else if (std.mem.eql(u8, name, "PinRemove") or std.mem.eql(u8, name, "pinremove")) {
            const slot = std.fmt.parseInt(usize, args, 10) catch {
                self.setStatus("usage: :PinRemove <slot>", .{});
                return;
            };
            _ = try self.pinRemoveSlot(slot);
        } else if (std.mem.eql(u8, name, "PinMove") or std.mem.eql(u8, name, "pinmove")) {
            var tokens = std.mem.tokenizeAny(u8, args, " \\t");
            const from_text = tokens.next() orelse {
                self.setStatus("usage: :PinMove <from> <to>", .{});
                return;
            };
            const to_text = tokens.next() orelse {
                self.setStatus("usage: :PinMove <from> <to>", .{});
                return;
            };
            if (tokens.next() != null) {
                self.setStatus("usage: :PinMove <from> <to>", .{});
                return;
            }
            const from_slot = std.fmt.parseInt(usize, from_text, 10) catch {
                self.setStatus("invalid PinMove source", .{});
                return;
            };
            const to_slot = std.fmt.parseInt(usize, to_text, 10) catch {
                self.setStatus("invalid PinMove destination", .{});
                return;
            };
            _ = try self.pinMoveSlot(from_slot, to_slot);
        } else if (std.mem.eql(u8, name, "PinJump") or std.mem.eql(u8, name, "pinjump")) {
            const slot = std.fmt.parseInt(usize, args, 10) catch {
                self.setStatus("usage: :PinJump <slot>", .{});
                return;
            };
            _ = try self.pinJumpSlot(slot, true);
        } else if (std.mem.eql(u8, name, "PinList") or std.mem.eql(u8, name, "pins") or std.mem.eql(u8, name, "pinlist")) {
            if (args.len != 0) self.setStatus("usage: :PinList", .{}) else _ = self.openPinSwitcher();
        } else if (std.mem.eql(u8, name, "symbols")) {""",
)

# Public API.
replace_once(
    "src/api/root.zig",
    'pub const events = @import("events.zig");\n',
    'pub const events = @import("events.zig");\npub const pins = @import("../pins.zig");\n',
)
replace_once(
    "src/api/root.zig",
    "pub const TabHandle = handles.TabHandle;\n",
    "pub const TabHandle = handles.TabHandle;\npub const PinId = pins.PinId;\n",
)
replace_once(
    "src/api/root.zig",
    "    pub fn optionGet(self: *const Api, name: options.Name) options.Value {",
    """    pub fn pinCount(self: *const Api, editor: *const editor_module.Editor) usize {
        _ = self;
        return editor.pins.count();
    }

    pub fn pinEntries(self: *const Api, editor: *const editor_module.Editor) []const pins.Entry {
        _ = self;
        return editor.pins.entries.items;
    }

    pub fn pinAdd(self: *Api, editor: *editor_module.Editor, label: ?[]const u8) !?PinId {
        _ = self;
        return editor.pinAddCurrent(label);
    }

    pub fn pinRemove(self: *Api, editor: *editor_module.Editor, slot: usize) !bool {
        _ = self;
        return editor.pinRemoveSlot(slot);
    }

    pub fn pinMove(self: *Api, editor: *editor_module.Editor, from_slot: usize, to_slot: usize) !bool {
        _ = self;
        return editor.pinMoveSlot(from_slot, to_slot);
    }

    pub fn pinJump(self: *Api, editor: *editor_module.Editor, slot: usize, exact: bool) !bool {
        _ = self;
        return editor.pinJumpSlot(slot, exact);
    }

    pub fn optionGet(self: *const Api, name: options.Name) options.Value {""",
)

# App startup/version and persistence before plugins/config.
replace_once("src/app.zig", 'pub const version = "0.5.0";', 'pub const version = "0.6.0";')
replace_once("src/app.zig", "            try lua.eval(\"zim.version = '0.5.0'\");", "            try lua.eval(\"zim.version = '0.6.0'\");")
replace_once(
    "src/app.zig",
    "                defer init.gpa.free(config_root);\n                plugins = try plugin_manager.Manager.create(",
    "                defer init.gpa.free(config_root);\n                try state.configurePins(config_root);\n                plugins = try plugin_manager.Manager.create(",
)

# Plugin/build version compatibility.
replace_once("src/plugin_manager.zig", 'pub const zim_version = "0.5.0";', 'pub const zim_version = "0.6.0";')
replace_once(
    "src/plugin_manager.zig",
    '        if (std.mem.eql(u8, capability, "lsp")) continue;\n',
    '        if (std.mem.eql(u8, capability, "lsp")) continue;\n        if (std.mem.eql(u8, capability, "pins")) continue;\n',
)
replace_once("build.zig.zon", '    .version = "0.5.0",', '    .version = "0.6.0",')
replace_once(
    "src/core_tests.zig",
    '    _ = @import("editor.zig");\n',
    '    _ = @import("editor.zig");\n    _ = @import("pins.zig");\n',
)

# Lua API + tests.
replace_once(
    "src/lua_runtime.zig",
    "    \\\\function zim.tab.current() return n.current_tab() end\n    \\\\zim.lsp = {}",
    """    \\\\function zim.tab.current() return n.current_tab() end
    \\\\zim.pin = {}
    \\\\function zim.pin.add(label) return n.pin_add(label) end
    \\\\function zim.pin.remove(slot) return n.pin_remove(slot) end
    \\\\function zim.pin.move(from_slot, to_slot) return n.pin_move(from_slot, to_slot) end
    \\\\function zim.pin.jump(slot) return n.pin_jump(slot) end
    \\\\function zim.pin.list() return n.pin_list() end
    \\\\zim.lsp = {}""",
)
replace_once(
    "src/lua_runtime.zig",
    '            .{ .name = "current_tab", .func = zlua.wrap(nativeCurrentTab) },\n            .{ .name = "lsp",',
    '            .{ .name = "current_tab", .func = zlua.wrap(nativeCurrentTab) },\n            .{ .name = "pin_add", .func = zlua.wrap(nativePinAdd) },\n            .{ .name = "pin_remove", .func = zlua.wrap(nativePinRemove) },\n            .{ .name = "pin_move", .func = zlua.wrap(nativePinMove) },\n            .{ .name = "pin_jump", .func = zlua.wrap(nativePinJump) },\n            .{ .name = "pin_list", .func = zlua.wrap(nativePinList) },\n            .{ .name = "lsp",',
)
replace_once("src/lua_runtime.zig", '        _ = self.lua.pushString("0.5.0");', '        _ = self.lua.pushString("0.6.0");')
replace_once(
    "src/lua_runtime.zig",
    "fn nativeLsp(lua: *Lua) i32 {",
    """fn nativePinAdd(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const label = if (lua.getTop() >= 1 and !lua.isNoneOrNil(1)) lua.checkString(1) else null;
    const id = runtime.api.pinAdd(runtime.editor, label) catch lua.raiseErrorStr("failed to add pin", .{});
    if (id) |value| {
        lua.pushInteger(@intCast(value));
    } else {
        lua.pushNil();
    }
    return 1;
}

fn nativePinRemove(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const slot: usize = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("pin slot must be an integer", .{}));
    lua.pushBoolean(runtime.api.pinRemove(runtime.editor, slot) catch lua.raiseErrorStr("failed to remove pin", .{}));
    return 1;
}

fn nativePinMove(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const from_slot: usize = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("source pin slot must be an integer", .{}));
    const to_slot: usize = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("destination pin slot must be an integer", .{}));
    lua.pushBoolean(runtime.api.pinMove(runtime.editor, from_slot, to_slot) catch lua.raiseErrorStr("failed to move pin", .{}));
    return 1;
}

fn nativePinJump(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const slot: usize = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("pin slot must be an integer", .{}));
    lua.pushBoolean(runtime.api.pinJump(runtime.editor, slot, true) catch lua.raiseErrorStr("failed to jump to pin", .{}));
    return 1;
}

fn nativePinList(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const entries = runtime.api.pinEntries(runtime.editor);
    lua.createTable(@intCast(entries.len), 0);
    for (entries, 0..) |entry, index| {
        lua.createTable(0, 5);
        lua.pushInteger(@intCast(entry.id));
        lua.setField(-2, "id");
        _ = lua.pushString(entry.path);
        lua.setField(-2, "path");
        lua.pushInteger(@intCast(entry.line));
        lua.setField(-2, "line");
        lua.pushInteger(@intCast(entry.column));
        lua.setField(-2, "column");
        if (entry.label) |label| {
            _ = lua.pushString(label);
            lua.setField(-2, "label");
        }
        lua.setIndexRaw(-2, @intCast(index + 1));
    }
    return 1;
}

fn nativeLsp(lua: *Lua) i32 {""",
)
replace_once("src/lua_runtime.zig", "        \\\\assert(zim.version == '0.5.0')", "        \\\\assert(zim.version == '0.6.0')")
append_once(
    "src/lua_runtime.zig",
    'test "Lua Pins API is backed by the public Zig Pins API"',
    r'''test "Lua Pins API is backed by the public Zig Pins API" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, "demo.zig");
    defer editor.deinit();
    try editor.setText("one\ntwo\nthree\n");
    editor.setCursorFromLineColumn(1, 1);
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &api, &editor);
    defer runtime.deinit();

    try runtime.eval(
        \\local id = zim.pin.add('middle')
        \\assert(id ~= nil)
        \\local pins = zim.pin.list()
        \\assert(#pins == 1)
        \\assert(pins[1].label == 'middle')
        \\assert(pins[1].line == 2)
        \\assert(zim.pin.jump(1) == true)
    );
    try std.testing.expectEqual(@as(usize, 1), api.pinCount(&editor));
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().line);
}''',
)

# EditorView coarse Pins state and JSON payload.
replace_once(
    "src/editor_view.zig",
    "    status_hash: u64,\n};",
    "    status_hash: u64,\n    pins_revision: u64,\n    pin_switcher_open: bool,\n    pin_switcher_index: usize,\n};",
)
replace_once(
    "src/editor_view.zig",
    "        .status_hash = hashBytes(editor.status()),\n    };",
    "        .status_hash = hashBytes(editor.status()),\n        .pins_revision = editor.pins.revision,\n        .pin_switcher_open = editor.pin_switcher_open,\n        .pin_switcher_index = editor.pin_switcher_index,\n    };",
)
replace_once(
    "src/editor_view.zig",
    "        before.quit_requested != after.quit_requested or\n        before.status_hash != after.status_hash;",
    "        before.quit_requested != after.quit_requested or\n        before.status_hash != after.status_hash or\n        before.pins_revision != after.pins_revision or\n        before.pin_switcher_open != after.pin_switcher_open or\n        before.pin_switcher_index != after.pin_switcher_index;",
)
replace_once(
    "src/editor_view.zig",
    "    var payload_buffer: [2304]u8 = undefined;\n    const payload = try std.fmt.bufPrint(\n        &payload_buffer,\n        \"{{\\\"mode\\\":\\\"{s}\\\",\\\"line\\\":{d},\\\"column\\\":{d},\\\"modified\\\":{},\\\"revision\\\":{d},\\\"commandOpen\\\":{},\\\"commandText\\\":\\\"{s}\\\",\\\"status\\\":\\\"{s}\\\",\\\"path\\\":\\\"{s}\\\",\\\"project\\\":\\\"{s}\\\",\\\"buffers\\\":{d},\\\"windows\\\":{d},\\\"tabs\\\":{d},\\\"diagnostics\\\":{d},\\\"symbols\\\":{d},\\\"references\\\":{d}}}\",\n        .{\n            state.editor.modeName(),\n            position.line,\n            position.column,\n            state.editor.currentBuffer().modified,\n            state.editor.currentBuffer().revision,\n            state.editor.commandOpen(),\n            safe_command,\n            safe_status,\n            safe_path,\n            safe_project,\n            state.editor.buffers.items.len,\n            state.editor.activeTab().window_ids.items.len,\n            state.editor.tabs.items.len,\n            diagnostics,\n            symbols,\n            references,\n        },\n    );\n    try context.notify(payload);",
    """    const pins_json = try std.json.Stringify.valueAlloc(state.editor.allocator, state.editor.pins.entries.items, .{});
    defer state.editor.allocator.free(pins_json);
    const payload = try std.fmt.allocPrint(
        state.editor.allocator,
        "{{\"mode\":\"{s}\",\"line\":{d},\"column\":{d},\"modified\":{},\"revision\":{d},\"commandOpen\":{},\"commandText\":\"{s}\",\"status\":\"{s}\",\"path\":\"{s}\",\"project\":\"{s}\",\"buffers\":{d},\"windows\":{d},\"tabs\":{d},\"diagnostics\":{d},\"symbols\":{d},\"references\":{d},\"pins\":{s},\"pinSwitcherOpen\":{},\"pinSwitcherIndex\":{d}}}",
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
            pins_json,
            state.editor.pin_switcher_open,
            state.editor.pin_switcher_index,
        },
    );
    defer state.editor.allocator.free(payload);
    try context.notify(payload);""",
)

# Hondo UI: Pins in Project + passive centered Popup driven by native state.
replace_once(
    "ui/src/bundle.ts",
    "  NativeView,\n  Row,",
    "  NativeView,\n  Popup,\n  Row,",
)
replace_once(
    "ui/src/bundle.ts",
    "const [references, setReferences] = createSignal(0);\n",
    """type PinView = { id: number; path: string; line: number; column: number; label?: string };
const [references, setReferences] = createSignal(0);
const [pins, setPins] = createSignal<PinView[]>([]);
const [pinSwitcherOpen, setPinSwitcherOpen] = createSignal(false);
const [pinSwitcherIndex, setPinSwitcherIndex] = createSignal(0);
""",
)
replace_once(
    "ui/src/bundle.ts",
    "function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {",
    """function pinsPayload(value: HondoValue): PinView[] {
  if (!Array.isArray(value)) return [];
  const result: PinView[] = [];
  for (const candidate of value) {
    const item = payloadObject(candidate);
    if (!item) continue;
    if (typeof item.id !== 'number' || typeof item.path !== 'string' || typeof item.line !== 'number' || typeof item.column !== 'number') continue;
    result.push({
      id: item.id,
      path: item.path,
      line: item.line,
      column: item.column,
      label: typeof item.label === 'string' ? item.label : undefined,
    });
  }
  return result;
}

function keyPayload(event: HondoNodeEvent): { kind?: string; codepoint?: number } | undefined {""",
)
replace_once(
    "ui/src/bundle.ts",
    "  if (typeof value.references === 'number') setReferences(value.references);\n",
    "  if (typeof value.references === 'number') setReferences(value.references);\n  if (value.pins !== undefined) setPins(pinsPayload(value.pins));\n  if (typeof value.pinSwitcherOpen === 'boolean') setPinSwitcherOpen(value.pinSwitcherOpen);\n  if (typeof value.pinSwitcherIndex === 'number') setPinSwitcherIndex(value.pinSwitcherIndex);\n",
)
replace_once(
    "ui/src/bundle.ts",
    "      Text({ children: () => `Open buffers: ${buffers()}` }),\n      Spacer({ grow: 1 }),",
    """      Text({ children: () => `Open buffers: ${buffers()}` }),
      Text({ style: { bold: true, foreground: 'bright-yellow' }, children: () => `PINS (${pins().length})` }),
      ...pins().slice(0, 9).map((pin, index) =>
        Text({
          get children() {
            const name = pin.label || pin.path;
            return `${index + 1} ${name} :${pin.line}`;
          },
          style: { dim: true },
        }),
      ),
      Spacer({ grow: 1 }),""",
)
replace_once(
    "ui/src/bundle.ts",
    "const disposeRender = render(() =>\n",
    """const pinSwitcher = Popup({
  get x() {
    return Math.max(0, Math.floor((terminalWidth() - 52) / 2));
  },
  get y() {
    return Math.max(1, Math.floor((terminalHeight() - Math.min(14, pins().length + 5)) / 2));
  },
  zIndex: 20,
  style: { width: 52, paddingX: 1, background: '#20242c' },
  children: Column({
    children: [
      Text({ style: { bold: true, foreground: 'bright-magenta' }, children: 'PIN SWITCHER' }),
      Text({ style: { dim: true }, children: '1-9 jump · j/k select · Enter jump · Esc close' }),
      () => pins().map((pin, index) =>
        Text({
          get style() {
            return {
              bold: index === pinSwitcherIndex(),
              reverse: index === pinSwitcherIndex(),
              foreground: index === pinSwitcherIndex() ? 'bright-cyan' : 'bright-white',
            } as const;
          },
          get children() {
            const label = pin.label ? `${pin.label} · ` : '';
            return `${index + 1} ${label}${pin.path}:${pin.line}:${pin.column}`;
          },
        }),
      ),
    ],
  }),
});

const disposeRender = render(() =>
""",
)
replace_once(
    "ui/src/bundle.ts",
    "      Row({\n        style: { height: 1, background: '#161b22' },",
    """      () => (pinSwitcherOpen() ? pinSwitcher : null),
      Row({
        style: { height: 1, background: '#161b22' },""",
)

# Integration test proving passive switcher UI + native direct slots.
append_once(
    "src/tui.zig",
    'test "Pins switcher renders in Hondo while navigation stays native"',
    r'''test "Pins switcher renders in Hondo while navigation stays native" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, "demo.zig");
    defer editor.deinit();
    try editor.setText("one\ntwo\nthree\n");
    editor.setCursorFromLineColumn(1, 1);
    _ = try editor.pinAddCurrent("middle");
    editor.setCursor(0);

    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 120, 30);
    defer app.deinit();

    _ = try app.dispatch(.{ .key = .{ .codepoint = 'g' } });
    const opened = try app.dispatch(.{ .key = .{ .codepoint = 'p' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, opened.path);
    try std.testing.expect(editor.pin_switcher_open);
    try std.testing.expect(sceneContainsText(app.scene, "PIN SWITCHER"));

    const jumped = try app.dispatch(.{ .key = .{ .codepoint = '1' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, jumped.path);
    try std.testing.expect(!editor.pin_switcher_open);
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().line);
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().column);

    editor.setCursor(0);
    _ = try app.dispatch(.{ .key = .{ .codepoint = '\'' } });
    const linewise = try app.dispatch(.{ .key = .{ .codepoint = '1' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, linewise.path);
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().line);
    try std.testing.expectEqual(@as(usize, 1), editor.cursorPosition().column);

    try app.runtime.eval(
        "if (globalThis.__zimJsKeyEvents !== 0) throw new Error('pin navigation crossed into JavaScript');",
        "zim-pin-native-key-proof.js",
    );
}''',
)
