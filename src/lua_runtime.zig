const std = @import("std");
const zlua = @import("zlua");
const api_module = @import("api.zig");
const editor_module = @import("editor.zig");

const Lua = zlua.Lua;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    lua: *Lua,
    api: *api_module.Api,
    editor: *editor_module.Editor,

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
        try runtime.installNamespace();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.lua.deinit();
        self.* = undefined;
    }

    pub fn eval(self: *Runtime, source: [:0]const u8) !void {
        try self.lua.doString(source);
    }

    fn installNamespace(self: *Runtime) !void {
        self.lua.createTable(0, 1);
        _ = self.lua.pushString("0.3.0");
        self.lua.setField(-2, "version");
        self.lua.setGlobal("zim");
    }
};

test "embedded Lua exposes the zim namespace" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &api, &editor);
    defer runtime.deinit();

    try runtime.eval("assert(zim.version == '0.3.0')");
}
