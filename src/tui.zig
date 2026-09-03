const std = @import("std");
const hondo = @import("hondo");
const api_module = @import("api.zig");
const api_observer = @import("api/observer.zig");
const editor_module = @import("editor.zig");
const editor_view = @import("editor_view.zig");
const lua_runtime = @import("lua_runtime.zig");
const terminal_io = @import("terminal_io.zig");

const ui_bundle = @embedFile("generated/zim_ui.js");
const fallback_width = 80;
const fallback_height = 24;
const resize_poll_ms = 50;
const sequence_wait_ms = 10;

const TuiApp = struct {
    allocator: std.mem.Allocator,
    editor: *editor_module.Editor,
    api: *api_module.Api,
    scene: *hondo.scene.Scene,
    runtime: hondo.runtime.Runtime,
    renderer: hondo.terminal.renderer.Renderer,
    focus: hondo.focus.Manager,
    registry: hondo.native_view.Registry,

    fn init(
        allocator: std.mem.Allocator,
        editor: *editor_module.Editor,
        api: *api_module.Api,
        width: usize,
        height: usize,
    ) !TuiApp {
        const scene = try allocator.create(hondo.scene.Scene);
        errdefer allocator.destroy(scene);
        scene.* = try hondo.scene.Scene.init(allocator);
        errdefer scene.deinit();

        var runtime = try hondo.runtime.Runtime.init();
        errdefer runtime.deinit();
        try runtime.installSceneBridge(scene);

        var registry = hondo.native_view.Registry.init(allocator);
        errdefer registry.deinit();
        try registry.register(editor_view.native_type, editor_view.bind(editor));
        errdefer editor_view.unbind(editor);

        try runtime.eval(ui_bundle, "zim-hondo-ui.js");
        errdefer runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};
        try updateUiSize(&runtime, width, height);
        try registry.sync(scene);
        try hondo.native_view_runtime.flushNotifications(&runtime, &registry);

        var renderer = try hondo.terminal.renderer.Renderer.init(allocator, width, height);
        errdefer renderer.deinit();

        var app = TuiApp{
            .allocator = allocator,
            .editor = editor,
            .api = api,
            .scene = scene,
            .runtime = runtime,
            .renderer = renderer,
            .focus = .{},
            .registry = registry,
        };
        try app.syncFocus();
        return app;
    }

    fn deinit(self: *TuiApp) void {
        if (self.focus.clear()) |change| {
            hondo.input_events.dispatchFocusChange(&self.runtime, change) catch {};
        }
        self.runtime.eval("globalThis.__zimUiDispose?.();", "zim-hondo-ui-dispose.js") catch {};
        self.registry.deinit();
        editor_view.unbind(self.editor);
        self.renderer.deinit();
        self.runtime.deinit();
        self.scene.deinit();
        self.allocator.destroy(self.scene);
        self.* = undefined;
    }

    fn syncFocus(self: *TuiApp) !void {
        if (try self.focus.syncRequested(self.scene)) |change| {
            try hondo.input_events.dispatchFocusChange(&self.runtime, change);
        }
    }

    fn dispatch(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.native_view_runtime.DispatchResult {
        const before = api_observer.capture(self.editor);
        const event = try self.prepareEvent(incoming);
        const grid = self.renderer.grid();
        const result = try hondo.native_view_runtime.dispatchInteractive(
            self.allocator,
            &self.runtime,
            self.scene,
            &self.focus,
            &self.registry,
            event,
            grid.width,
            grid.height,
        );
        try api_observer.emitChanges(self.api, self.editor, before);
        return result;
    }

    fn prepareEvent(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.terminal.input.Event {
        return switch (incoming) {
            .key => |key| .{ .key = try self.prepareKey(key) },
            else => incoming,
        };
    }

    fn prepareKey(self: *TuiApp, key: hondo.terminal.input.Key) !hondo.terminal.input.Key {
        if (key == .enter and self.editor.commandOpen()) {
            if (try self.executePublicCommandLine()) return .escape;
        }

        return switch (key) {
            .codepoint => |cp| blk: {
                const buffer_id = self.editor.currentBufferConst().id;
                if (self.api.keymaps.find(.{ .buffer = buffer_id }, self.editor.mode, cp)) |mapping| {
                    break :blk .{ .codepoint = mapping.to };
                }
                break :blk key;
            },
            else => key,
        };
    }

    fn executePublicCommandLine(self: *TuiApp) !bool {
        var display_buffer: [1024]u8 = undefined;
        const display = self.editor.commandDisplay(&display_buffer);
        if (display.len < 2 or display[0] != ':') return false;
        const command = std.mem.trim(u8, display[1..], " \t");
        if (command.len == 0) return false;

        const split = std.mem.indexOfAny(u8, command, " \t") orelse command.len;
        const name = command[0..split];
        const args = if (split < command.len)
            std.mem.trimStart(u8, command[split..], " \t")
        else
            "";

        if (std.mem.eql(u8, name, "w") or std.mem.eql(u8, name, "write")) {
            _ = try self.api.writeCurrent(self.editor);
            return true;
        }

        if (self.api.commands.find(name) != null) {
            try self.api.commandExecute(self.editor, name, args);
            return true;
        }
        return false;
    }

    fn render(self: *TuiApp) !void {
        try hondo.native_view_renderer.render(self.scene, &self.registry, self.renderer.grid());
    }

    fn resize(self: *TuiApp, width: usize, height: usize) !bool {
        const changed = try self.renderer.resize(width, height);
        if (changed) try updateUiSize(&self.runtime, width, height);
        return changed;
    }

    fn writeFrame(self: *TuiApp) !void {
        try self.render();
        const bytes = try self.renderer.encode();
        defer self.allocator.free(bytes);
        if (bytes.len != 0) try terminal_io.writeAll(terminal_io.stdout_fd, bytes);
    }
};

fn updateUiSize(runtime: *hondo.runtime.Runtime, width: usize, height: usize) !void {
    var buffer: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &buffer,
        "if (globalThis.__zimUiResize) globalThis.__zimUiResize({d}, {d});",
        .{ width, height },
    );
    try runtime.eval(script, "zim-ui-resize.js");
}

pub fn run(init: std.process.Init, editor: *editor_module.Editor, api: *api_module.Api) !u8 {
    var session = try hondo.terminal.session.Session.begin(
        terminal_io.stdin_fd,
        terminal_io.stdout_fd,
    );
    defer session.restore() catch {};

    const restore = try hondo.terminal.control.restoreSequence(init.gpa);
    defer init.gpa.free(restore);
    defer terminal_io.writeAll(terminal_io.stdout_fd, restore) catch {};

    const input_restore = try hondo.terminal.control.inputFeaturesRestoreSequence(init.gpa);
    defer init.gpa.free(input_restore);
    defer terminal_io.writeAll(terminal_io.stdout_fd, input_restore) catch {};

    const begin = try hondo.terminal.control.beginSequence(init.gpa);
    defer init.gpa.free(begin);
    try terminal_io.writeAll(terminal_io.stdout_fd, begin);

    const input_begin = try hondo.terminal.control.inputFeaturesBeginSequence(init.gpa);
    defer init.gpa.free(input_begin);
    try terminal_io.writeAll(terminal_io.stdout_fd, input_begin);

    const initial_size = hondo.terminal.size.query(terminal_io.stdout_fd) catch hondo.terminal.size.Size{
        .width = fallback_width,
        .height = fallback_height,
    };
    var size_tracker = hondo.terminal.size.Tracker.initKnown(initial_size);

    var app = try TuiApp.init(init.gpa, editor, api, initial_size.width, initial_size.height);
    defer app.deinit();
    try app.writeFrame();

    while (true) {
        const has_input = try hondo.terminal.wait.readable(terminal_io.stdin_fd, resize_poll_ms);
        const resize = size_tracker.poll(terminal_io.stdout_fd) catch null;
        if (resize) |new_size| {
            if (try app.resize(new_size.width, new_size.height)) try app.writeFrame();
        }
        if (!has_input) continue;

        const event = (try readTerminalEvent(terminal_io.stdin_fd)) orelse break;
        if (isImmediateQuitEvent(event)) break;
        _ = try app.dispatch(event);
        if (editor.quit_requested) break;
        try app.writeFrame();
    }
    return 0;
}

fn readTerminalEvent(fd: c_int) !?hondo.terminal.input.Event {
    const first = (try terminal_io.readByte(fd)) orelse return null;
    var bytes: [64]u8 = undefined;
    bytes[0] = first;
    var len: usize = 1;

    if (first == 0x1b) {
        if (!try hondo.terminal.wait.readable(fd, sequence_wait_ms)) {
            return .{ .key = .escape };
        }
        bytes[len] = (try terminal_io.readByte(fd)) orelse return .{ .key = .escape };
        len += 1;
        if (bytes[1] != '[') return .{ .key = .escape };
        while (len < bytes.len) {
            if (len >= 3) {
                if (hondo.terminal.input.decode(bytes[0..len])) |decoded| {
                    if (decoded.consumed == len) return decoded.event;
                }
            }
            if (!try hondo.terminal.wait.readable(fd, sequence_wait_ms)) return .{ .key = .escape };
            bytes[len] = (try terminal_io.readByte(fd)) orelse return .{ .key = .escape };
            len += 1;
        }
        return .{ .key = .escape };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    while (len < sequence_len and len < bytes.len) : (len += 1) {
        bytes[len] = (try terminal_io.readByte(fd)) orelse break;
    }
    return if (hondo.terminal.input.decode(bytes[0..len])) |decoded|
        decoded.event
    else
        .{ .key = .{ .codepoint = 0xfffd } };
}

fn isImmediateQuitEvent(event: hondo.terminal.input.Event) bool {
    return switch (event) {
        .key => |key| switch (key) {
            .ctrl_c => true,
            else => false,
        },
        else => false,
    };
}

fn sceneContainsText(scene: *hondo.scene.Scene, expected: []const u8) bool {
    for (scene.nodes.items) |maybe_node| {
        const node = maybe_node orelse continue;
        if (!hondo.native_view.isAttached(scene, node.id)) continue;
        if (node.text) |text| {
            if (std.mem.indexOf(u8, text, expected) != null) return true;
        }
    }
    return false;
}

test "Hondo chrome reacts while the expanded editor grammar stays native" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 80, 24);
    defer app.deinit();

    try std.testing.expect(sceneContainsText(app.scene, "NORMAL"));

    const insert_mode = try app.dispatch(.{ .key = .{ .codepoint = 'i' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, insert_mode.path);
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);
    try std.testing.expect(sceneContainsText(app.scene, "INSERT"));

    const edit = try app.dispatch(.{ .key = .{ .codepoint = 'x' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, edit.path);
    try std.testing.expectEqualStrings("x", editor.text());
    try app.runtime.eval(
        "if (globalThis.__zimJsKeyEvents !== 0) throw new Error('editor key crossed into JavaScript');",
        "zim-native-key-proof.js",
    );

    _ = try app.dispatch(.{ .key = .escape });
    const command = try app.dispatch(.{ .key = .{ .codepoint = ':' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, command.path);
    try std.testing.expectEqual(editor_module.Mode.command_line, editor.mode);
    try std.testing.expect(sceneContainsText(app.scene, ":"));

    _ = try app.dispatch(.{ .key = .escape });
    try std.testing.expectEqual(editor_module.Mode.normal, editor.mode);
    const native_again = try app.dispatch(.{ .key = .{ .codepoint = 'i' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, native_again.path);
}

test "Zen workspace focus traverses chrome while insert Tab stays native" {
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

test "Hondo status reflects native split commands" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 80, 24);
    defer app.deinit();

    _ = try app.dispatch(.{ .key = .{ .codepoint = ':' } });
    for ("vsplit") |byte| _ = try app.dispatch(.{ .key = .{ .codepoint = byte } });
    _ = try app.dispatch(.{ .key = .enter });
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().window_ids.items.len);
    try std.testing.expect(sceneContainsText(app.scene, "W2"));
}

test "buffer-local public keymaps stay on the native Hondo input path" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    _ = try api.keymapSet(&editor, .{ .buffer = editor.currentBuffer().id }, .normal, 'z', 'i');
    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 80, 24);
    defer app.deinit();

    const result = try app.dispatch(.{ .key = .{ .codepoint = 'z' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, result.path);
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);
}

test "Lua configuration drives native Hondo keymaps commands and autocmds" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var lua = try lua_runtime.Runtime.init(std.testing.allocator, &api, &editor);
    defer lua.deinit();

    try lua.eval(
        \\mode_events = 0
        \\zim.autocmd.create('ModeChanged', function(ev) mode_events = mode_events + 1 end)
        \\zim.keymap.set('normal', 'z', 'i', { buffer = zim.buf.current() })
        \\zim.command.create('LuaHello', function(args) zim.buf.set_text(args) end)
    );

    var app = try TuiApp.init(std.testing.allocator, &editor, &api, 80, 24);
    defer app.deinit();

    const mapped = try app.dispatch(.{ .key = .{ .codepoint = 'z' } });
    try std.testing.expectEqual(hondo.native_view_runtime.DispatchPath.native, mapped.path);
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);
    try lua.eval("assert(mode_events == 1)");

    _ = try app.dispatch(.{ .key = .escape });
    _ = try app.dispatch(.{ .key = .{ .codepoint = ':' } });
    for ("LuaHello configured") |byte| _ = try app.dispatch(.{ .key = .{ .codepoint = byte } });
    _ = try app.dispatch(.{ .key = .enter });
    try std.testing.expectEqualStrings("configured", editor.text());
    try std.testing.expectEqual(editor_module.Mode.normal, editor.mode);
}
