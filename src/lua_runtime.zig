const std = @import("std");
const zlua = @import("zlua");
const api_module = @import("api.zig");
const editor_module = @import("editor.zig");

const Lua = zlua.Lua;

threadlocal var active_runtime: ?*Runtime = null;

const LuaCallback = struct {
    runtime: *Runtime,
    ref: i32,
};

const bootstrap =
    \\local n = zim._native
    \\zim.opt = setmetatable({}, {
    \\  __index = function(_, name) return n.opt_get(name) end,
    \\  __newindex = function(_, name, value) n.opt_set(name, value) end,
    \\})
    \\zim.keymap = {}
    \\function zim.keymap.set(mode, lhs, rhs, opts)
    \\  opts = opts or {}
    \\  return n.keymap_set(mode, lhs, rhs, opts.buffer)
    \\end
    \\function zim.keymap.del(mode, lhs, opts)
    \\  opts = opts or {}
    \\  return n.keymap_del(mode, lhs, opts.buffer)
    \\end
    \\zim.command = {}
    \\function zim.command.create(name, callback, opts)
    \\  assert(type(callback) == 'function', 'command callback must be a function')
    \\  opts = opts or {}
    \\  return n.command_create(name, callback, opts.description or '')
    \\end
    \\function zim.command.del(name) return n.command_del(name) end
    \\function zim.command.execute(name, args) return n.command_execute(name, args or '') end
    \\zim.autocmd = {}
    \\function zim.autocmd.create(event, opts, callback)
    \\  if type(opts) == 'function' and callback == nil then callback, opts = opts, {} end
    \\  opts = opts or {}
    \\  assert(type(callback) == 'function', 'autocmd callback must be a function')
    \\  return n.autocmd_create(event, callback, opts.once == true, opts.buffer)
    \\end
    \\function zim.autocmd.del(id) return n.autocmd_del(id) end
    \\zim.buf = {}
    \\function zim.buf.current() return n.current_buffer() end
    \\function zim.buf.get_text(buffer) return n.buffer_text(buffer) end
    \\function zim.buf.set_text(text) return n.set_text(text) end
    \\zim.win = {}
    \\function zim.win.current() return n.current_window() end
    \\function zim.win.buffer(window) return n.window_buffer(window) end
    \\zim.tab = {}
    \\function zim.tab.current() return n.current_tab() end
    \\zim.lsp = {}
    \\function zim.lsp.start() return n.lsp('start') end
    \\function zim.lsp.hover() return n.lsp('hover') end
    \\function zim.lsp.signature_help() return n.lsp('signature_help') end
    \\function zim.lsp.definition() return n.lsp('definition') end
    \\function zim.lsp.references() return n.lsp('references') end
    \\function zim.lsp.document_symbols() return n.lsp('document_symbols') end
    \\function zim.lsp.workspace_symbols(query) return n.lsp('workspace_symbols', query or '') end
    \\function zim.lsp.rename(name) return n.lsp('rename', name) end
    \\function zim.lsp.code_action() return n.lsp('code_action') end
    \\function zim.lsp.format() return n.lsp('format') end
    \\function zim.lsp.complete() return n.lsp('complete') end
;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    lua: *Lua,
    api: *api_module.Api,
    editor: *editor_module.Editor,
    callbacks: std.ArrayList(*LuaCallback) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        api: *api_module.Api,
        editor: *editor_module.Editor,
    ) !Runtime {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();
        lua.openLibs();

        var runtime = Runtime{
            .allocator = allocator,
            .lua = lua,
            .api = api,
            .editor = editor,
        };
        errdefer runtime.deinit();
        try runtime.installNamespace();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        for (self.callbacks.items) |callback| {
            self.lua.unref(zlua.registry_index, callback.ref);
            self.allocator.destroy(callback);
        }
        self.callbacks.deinit(self.allocator);
        self.lua.deinit();
        self.* = undefined;
    }

    pub fn eval(self: *Runtime, source: [:0]const u8) !void {
        const previous = active_runtime;
        active_runtime = self;
        defer active_runtime = previous;
        try self.lua.doString(source);
    }

    pub fn loadFile(self: *Runtime, io: std.Io, path: []const u8) !bool {
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(source);
        const terminated = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(terminated);
        try self.eval(terminated);
        return true;
    }

    fn installNamespace(self: *Runtime) !void {
        const native_fns = [_]zlua.FnReg{
            .{ .name = "opt_get", .func = zlua.wrap(nativeOptGet) },
            .{ .name = "opt_set", .func = zlua.wrap(nativeOptSet) },
            .{ .name = "keymap_set", .func = zlua.wrap(nativeKeymapSet) },
            .{ .name = "keymap_del", .func = zlua.wrap(nativeKeymapDel) },
            .{ .name = "command_create", .func = zlua.wrap(nativeCommandCreate) },
            .{ .name = "command_del", .func = zlua.wrap(nativeCommandDel) },
            .{ .name = "command_execute", .func = zlua.wrap(nativeCommandExecute) },
            .{ .name = "autocmd_create", .func = zlua.wrap(nativeAutocmdCreate) },
            .{ .name = "autocmd_del", .func = zlua.wrap(nativeAutocmdDel) },
            .{ .name = "current_buffer", .func = zlua.wrap(nativeCurrentBuffer) },
            .{ .name = "buffer_text", .func = zlua.wrap(nativeBufferText) },
            .{ .name = "set_text", .func = zlua.wrap(nativeSetText) },
            .{ .name = "current_window", .func = zlua.wrap(nativeCurrentWindow) },
            .{ .name = "window_buffer", .func = zlua.wrap(nativeWindowBuffer) },
            .{ .name = "current_tab", .func = zlua.wrap(nativeCurrentTab) },
            .{ .name = "lsp", .func = zlua.wrap(nativeLsp) },
        };

        self.lua.createTable(0, 2);
        _ = self.lua.pushString("0.3.0");
        self.lua.setField(-2, "version");
        self.lua.newLib(&native_fns);
        self.lua.setField(-2, "_native");
        self.lua.setGlobal("zim");
        try self.eval(bootstrap);
    }

    fn retainCallback(self: *Runtime, stack_index: i32) !*LuaCallback {
        self.lua.pushValue(stack_index);
        const ref = self.lua.ref(zlua.registry_index);
        const callback = try self.allocator.create(LuaCallback);
        errdefer self.allocator.destroy(callback);
        callback.* = .{ .runtime = self, .ref = ref };
        try self.callbacks.append(self.allocator, callback);
        return callback;
    }

    fn invokeCommand(self: *Runtime, callback: *LuaCallback, args: []const u8) void {
        const previous = active_runtime;
        active_runtime = self;
        defer active_runtime = previous;

        _ = self.lua.getIndexRaw(zlua.registry_index, callback.ref);
        _ = self.lua.pushString(args);
        self.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
            self.reportTopError("Lua command");
        };
    }

    fn invokeAutocmd(self: *Runtime, callback: *LuaCallback, event: api_module.events.Event) void {
        const previous = active_runtime;
        active_runtime = self;
        defer active_runtime = previous;

        _ = self.lua.getIndexRaw(zlua.registry_index, callback.ref);
        self.lua.createTable(0, 5);
        _ = self.lua.pushString(eventName(event.kind));
        self.lua.setField(-2, "event");
        self.lua.pushInteger(@intCast(event.sequence));
        self.lua.setField(-2, "sequence");
        if (event.buffer_id) |id| {
            self.lua.pushInteger(@intCast(id));
            self.lua.setField(-2, "buffer");
        }
        if (event.window_id) |id| {
            self.lua.pushInteger(@intCast(id));
            self.lua.setField(-2, "window");
        }
        if (event.tab_id) |id| {
            self.lua.pushInteger(@intCast(id));
            self.lua.setField(-2, "tab");
        }
        self.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
            self.reportTopError("Lua autocmd");
        };
    }

    fn reportTopError(self: *Runtime, prefix: []const u8) void {
        const message = self.lua.toString(-1) catch "unknown Lua error";
        self.editor.setStatusText(prefix, message);
        self.lua.pop(1);
    }
};

fn runtimeFor(lua: *Lua) *Runtime {
    return active_runtime orelse lua.raiseErrorStr("no active Zim Lua runtime", .{});
}

fn nativeOptGet(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const name = optionName(lua.checkString(1)) orelse lua.raiseErrorStr("unknown option", .{});
    switch (runtime.api.optionGet(name)) {
        .boolean => |value| lua.pushBoolean(value),
        .integer => |value| lua.pushInteger(value),
    }
    return 1;
}

fn nativeOptSet(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const name = optionName(lua.checkString(1)) orelse lua.raiseErrorStr("unknown option", .{});
    const value: api_module.options.Value = switch (name) {
        .number, .expandtab => .{ .boolean = lua.toBoolean(2) },
        .tabstop => .{ .integer = @intCast(lua.toInteger(2) catch lua.raiseErrorStr("tabstop must be an integer", .{})) },
    };
    runtime.api.optionSet(name, value) catch lua.raiseErrorStr("invalid option value", .{});
    return 0;
}

fn nativeKeymapSet(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const mode = parseMode(lua.checkString(1)) orelse lua.raiseErrorStr("invalid mode", .{});
    const from = decodeSingleCodepoint(lua.checkString(2)) catch lua.raiseErrorStr("lhs must be one character", .{});
    const to = decodeSingleCodepoint(lua.checkString(3)) catch lua.raiseErrorStr("rhs must be one character", .{});
    const scope = if (lua.getTop() >= 4 and !lua.isNoneOrNil(4))
        api_module.keymaps.Scope{ .buffer = @intCast(lua.toInteger(4) catch lua.raiseErrorStr("buffer must be an integer handle", .{})) }
    else
        api_module.keymaps.Scope.global;
    const id = runtime.api.keymapSet(runtime.editor, scope, mode, from, to) catch lua.raiseErrorStr("failed to create keymap", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn nativeKeymapDel(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const mode = parseMode(lua.checkString(1)) orelse lua.raiseErrorStr("invalid mode", .{});
    const from = decodeSingleCodepoint(lua.checkString(2)) catch lua.raiseErrorStr("lhs must be one character", .{});
    const scope = if (lua.getTop() >= 3 and !lua.isNoneOrNil(3))
        api_module.keymaps.Scope{ .buffer = @intCast(lua.toInteger(3) catch lua.raiseErrorStr("buffer must be an integer handle", .{})) }
    else
        api_module.keymaps.Scope.global;
    lua.pushBoolean(runtime.api.keymapDelete(runtime.editor, scope, mode, from));
    return 1;
}

fn nativeCommandCreate(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const name = lua.checkString(1);
    const description = if (lua.getTop() >= 3) lua.checkString(3) else "";
    const callback = runtime.retainCallback(2) catch lua.raiseErrorStr("failed to retain command callback", .{});
    const id = runtime.api.commandCreate(name, description, commandThunk, callback) catch lua.raiseErrorStr("failed to create command", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn nativeCommandDel(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    lua.pushBoolean(runtime.api.commandDelete(lua.checkString(1)));
    return 1;
}

fn nativeCommandExecute(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const name = lua.checkString(1);
    const args = if (lua.getTop() >= 2) lua.checkString(2) else "";
    runtime.api.commandExecute(runtime.editor, name, args) catch lua.raiseErrorStr("unknown or failed command", .{});
    return 0;
}

fn nativeAutocmdCreate(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const kind = parseEvent(lua.checkString(1)) orelse lua.raiseErrorStr("unknown autocmd event", .{});
    const callback = runtime.retainCallback(2) catch lua.raiseErrorStr("failed to retain autocmd callback", .{});
    const once = lua.getTop() >= 3 and lua.toBoolean(3);
    const buffer_id: ?editor_module.BufferId = if (lua.getTop() >= 4 and !lua.isNoneOrNil(4))
        @intCast(lua.toInteger(4) catch lua.raiseErrorStr("buffer must be an integer handle", .{}))
    else
        null;
    const id = runtime.api.autocmdCreate(kind, .{ .buffer_id = buffer_id, .once = once }, autocmdThunk, callback) catch lua.raiseErrorStr("failed to create autocmd", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn nativeAutocmdDel(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const id: api_module.events.AutocmdId = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("autocmd id must be an integer", .{}));
    lua.pushBoolean(runtime.api.autocmdDelete(id));
    return 1;
}

fn nativeCurrentBuffer(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    lua.pushInteger(@intCast(runtime.api.currentBuffer(runtime.editor).id));
    return 1;
}

fn nativeBufferText(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const handle = if (lua.getTop() >= 1 and !lua.isNoneOrNil(1))
        api_module.BufferHandle{ .id = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("buffer must be an integer handle", .{})) }
    else
        runtime.api.currentBuffer(runtime.editor);
    const text = runtime.api.bufferText(runtime.editor, handle) orelse lua.raiseErrorStr("invalid buffer handle", .{});
    _ = lua.pushString(text);
    return 1;
}

fn nativeSetText(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    runtime.api.setCurrentText(runtime.editor, lua.checkString(1)) catch lua.raiseErrorStr("failed to set buffer text", .{});
    return 0;
}

fn nativeCurrentWindow(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    lua.pushInteger(@intCast(runtime.api.currentWindow(runtime.editor).id));
    return 1;
}

fn nativeWindowBuffer(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const handle = if (lua.getTop() >= 1 and !lua.isNoneOrNil(1))
        api_module.WindowHandle{ .id = @intCast(lua.toInteger(1) catch lua.raiseErrorStr("window must be an integer handle", .{})) }
    else
        runtime.api.currentWindow(runtime.editor);
    const buffer = runtime.api.windowBuffer(runtime.editor, handle) orelse lua.raiseErrorStr("invalid window handle", .{});
    lua.pushInteger(@intCast(buffer.id));
    return 1;
}

fn nativeCurrentTab(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    lua.pushInteger(@intCast(runtime.api.currentTab(runtime.editor).id));
    return 1;
}

fn nativeLsp(lua: *Lua) i32 {
    const runtime = runtimeFor(lua);
    const action = lua.checkString(1);
    if (std.mem.eql(u8, action, "start")) {
        runtime.editor.lspStart() catch lua.raiseErrorStr("failed to start language server", .{});
        return 0;
    }

    const request_id = if (std.mem.eql(u8, action, "hover"))
        runtime.editor.lspRequestHover()
    else if (std.mem.eql(u8, action, "signature_help"))
        runtime.editor.lspRequestSignatureHelp()
    else if (std.mem.eql(u8, action, "definition"))
        runtime.editor.lspRequestDefinition()
    else if (std.mem.eql(u8, action, "references"))
        runtime.editor.lspRequestReferences()
    else if (std.mem.eql(u8, action, "document_symbols"))
        runtime.editor.lspRequestDocumentSymbols()
    else if (std.mem.eql(u8, action, "workspace_symbols"))
        runtime.editor.lspRequestWorkspaceSymbols(lua.checkString(2))
    else if (std.mem.eql(u8, action, "rename"))
        runtime.editor.lspRequestRename(lua.checkString(2))
    else if (std.mem.eql(u8, action, "code_action"))
        runtime.editor.lspRequestCodeAction()
    else if (std.mem.eql(u8, action, "format"))
        runtime.editor.lspRequestFormatting()
    else if (std.mem.eql(u8, action, "complete"))
        runtime.editor.lspRequestCompletion()
    else
        lua.raiseErrorStr("unknown LSP action", .{});

    const id = request_id catch lua.raiseErrorStr("language server is not ready", .{});
    lua.pushInteger(@intCast(id));
    return 1;
}

fn commandThunk(context: *api_module.commands.Context) !void {
    const callback: *LuaCallback = @ptrCast(@alignCast(context.user_data.?));
    callback.runtime.invokeCommand(callback, context.args);
}

fn autocmdThunk(context: *api_module.events.Context) !void {
    const callback: *LuaCallback = @ptrCast(@alignCast(context.user_data.?));
    callback.runtime.invokeAutocmd(callback, context.event);
}

fn optionName(name: []const u8) ?api_module.options.Name {
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "tabstop")) return .tabstop;
    if (std.mem.eql(u8, name, "expandtab")) return .expandtab;
    return null;
}

fn parseMode(name: []const u8) ?editor_module.Mode {
    if (std.mem.eql(u8, name, "normal") or std.mem.eql(u8, name, "n")) return .normal;
    if (std.mem.eql(u8, name, "insert") or std.mem.eql(u8, name, "i")) return .insert;
    if (std.mem.eql(u8, name, "visual") or std.mem.eql(u8, name, "v")) return .visual;
    if (std.mem.eql(u8, name, "visual_line")) return .visual_line;
    if (std.mem.eql(u8, name, "visual_block")) return .visual_block;
    if (std.mem.eql(u8, name, "operator_pending")) return .operator_pending;
    if (std.mem.eql(u8, name, "command_line")) return .command_line;
    return null;
}

fn parseEvent(name: []const u8) ?api_module.events.Kind {
    if (std.mem.eql(u8, name, "EditorEnter")) return .editor_enter;
    if (std.mem.eql(u8, name, "EditorLeave")) return .editor_leave;
    if (std.mem.eql(u8, name, "BufEnter")) return .buffer_enter;
    if (std.mem.eql(u8, name, "BufLeave")) return .buffer_leave;
    if (std.mem.eql(u8, name, "BufWritePre")) return .buffer_write_pre;
    if (std.mem.eql(u8, name, "BufWritePost")) return .buffer_write_post;
    if (std.mem.eql(u8, name, "TextChanged")) return .text_changed;
    if (std.mem.eql(u8, name, "ModeChanged")) return .mode_changed;
    if (std.mem.eql(u8, name, "WinEnter")) return .window_enter;
    if (std.mem.eql(u8, name, "WinLeave")) return .window_leave;
    if (std.mem.eql(u8, name, "LspAttach")) return .lsp_attach;
    if (std.mem.eql(u8, name, "LspDetach")) return .lsp_detach;
    if (std.mem.eql(u8, name, "DiagnosticsChanged")) return .diagnostics_changed;
    return null;
}

fn eventName(kind: api_module.events.Kind) []const u8 {
    return switch (kind) {
        .editor_enter => "EditorEnter",
        .editor_leave => "EditorLeave",
        .buffer_enter => "BufEnter",
        .buffer_leave => "BufLeave",
        .buffer_write_pre => "BufWritePre",
        .buffer_write_post => "BufWritePost",
        .text_changed => "TextChanged",
        .mode_changed => "ModeChanged",
        .window_enter => "WinEnter",
        .window_leave => "WinLeave",
        .lsp_attach => "LspAttach",
        .lsp_detach => "LspDetach",
        .diagnostics_changed => "DiagnosticsChanged",
    };
}

fn decodeSingleCodepoint(text: []const u8) !u21 {
    if (text.len == 0) return error.InvalidKey;
    const len = try std.unicode.utf8ByteSequenceLength(text[0]);
    if (len != text.len) return error.InvalidKey;
    return try std.unicode.utf8Decode(text);
}

test "embedded Lua exposes options keymaps commands and autocommands" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &api, &editor);
    defer runtime.deinit();

    try runtime.eval(
        \\assert(zim.version == '0.3.0')
        \\zim.opt.number = true
        \\zim.opt.tabstop = 8
        \\zim.keymap.set('normal', 'z', 'i')
        \\command_calls = 0
        \\zim.command.create('Hello', function(args) command_calls = command_calls + 1 end)
        \\zim.command.execute('Hello')
        \\event_calls = 0
        \\zim.autocmd.create('TextChanged', function(ev) event_calls = event_calls + 1 end)
    );
    try std.testing.expect(api.options.number);
    try std.testing.expectEqual(@as(u16, 8), api.options.tabstop);
    try std.testing.expectEqual(@as(usize, 1), api.commands.count());
    try std.testing.expectEqual(@as(usize, 1), api.events.count());
    try api.emit(&editor, .{ .kind = .text_changed, .buffer_id = editor.currentBuffer().id });
    try runtime.eval("assert(command_calls == 1); assert(event_calls == 1)");
}

test "Lua buffer and handle API is backed by the public Zig API" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &api, &editor);
    defer runtime.deinit();

    try runtime.eval(
        \\zim.buf.set_text('from lua')
        \\local b = zim.buf.current()
        \\assert(zim.buf.get_text(b) == 'from lua')
        \\assert(zim.win.buffer(zim.win.current()) == b)
        \\assert(zim.tab.current() > 0)
    );
    try std.testing.expectEqualStrings("from lua", editor.text());
}
