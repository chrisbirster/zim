const std = @import("std");
const api_module = @import("api.zig");
const cli = @import("cli.zig");
const editor = @import("editor.zig");
const lua_runtime = @import("lua_runtime.zig");
const plugin_manager = @import("plugin_manager.zig");
const terminal_controller = @import("terminal_controller.zig");
const tui = @import("tui.zig");

pub const version = "0.7.0";

const help_text =
    \\Zim — your new code overlord.
    \\
    \\Usage:
    \\  zim [options] [file|directory]
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -v, --version    Show the Zim version
    \\      --headless   Start the editor core without the Hondo TUI
    \\
;

pub fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = cli.parse(args[1..]) catch |err| {
        try printParseError(init.io, err);
        return 2;
    };

    switch (command) {
        .help => {
            try std.Io.File.stdout().writeStreamingAll(init.io, help_text);
            return 0;
        },
        .version => {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &buffer);
            try writer.interface.print("zim {s}\n", .{version});
            try writer.interface.flush();
            return 0;
        },
        .run => |options| {
            var state = try editor.Editor.init(init.gpa, init.io, options.target);
            defer state.deinit();
            try state.loadInitial();

            var api = api_module.Api.init(init.gpa);
            defer api.deinit();
            try api.registerJobCommands();

            var terminal = terminal_controller.Controller.init(init.gpa, init.io, init.environ_map);
            defer terminal.deinit(&api);
            try terminal.register(&api);

            var lua = try lua_runtime.Runtime.init(init.gpa, &api, &state);
            defer lua.deinit();
            try lua.eval("zim.version = '0.7.0'");

            var plugins: ?*plugin_manager.Manager = null;
            defer if (plugins) |manager| manager.destroy();

            if (try configRootAlloc(init.gpa, init.environ_map)) |config_root| {
                defer init.gpa.free(config_root);
                try state.configurePins(config_root);
                plugins = try plugin_manager.Manager.create(
                    init.gpa,
                    init.io,
                    config_root,
                    &api,
                    &state,
                    &lua,
                );

                const config_path = try std.fmt.allocPrint(init.gpa, "{s}/init.lua", .{config_root});
                defer init.gpa.free(config_path);
                _ = lua.loadFile(init.io, config_path) catch |err| blk: {
                    try printConfigError(init.io, config_path, err);
                    break :blk false;
                };
            }

            const current = api.currentBuffer(&state);
            const window = api.currentWindow(&state);
            const tab = api.currentTab(&state);
            try api.emit(&state, .{
                .kind = .editor_enter,
                .buffer_id = current.id,
                .window_id = window.id,
                .tab_id = tab.id,
            });
            try api.emit(&state, .{
                .kind = .buffer_enter,
                .buffer_id = current.id,
                .window_id = window.id,
                .tab_id = tab.id,
            });
            defer api.emit(&state, .{
                .kind = .editor_leave,
                .buffer_id = state.currentBufferConst().id,
                .window_id = state.currentWindowConst().id,
                .tab_id = state.activeTabConst().id,
            }) catch {};

            if (options.headless) return 0;
            return tui.run(init, &state, &api, &terminal);
        },
    }
}

fn configRootAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !?[]u8 {
    if (environment.get("XDG_CONFIG_HOME")) |root| {
        return try std.fmt.allocPrint(allocator, "{s}/zim", .{root});
    }
    if (environment.get("APPDATA")) |root| {
        return try std.fmt.allocPrint(allocator, "{s}/zim", .{root});
    }
    if (environment.get("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/zim", .{home});
    }
    return null;
}

fn printParseError(io: std.Io, err: cli.ParseError) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);

    switch (err) {
        error.UnknownOption => try writer.interface.writeAll("zim: unknown option\n"),
        error.TooManyTargets => try writer.interface.writeAll("zim: only one file or directory may be opened at startup\n"),
    }

    try writer.interface.writeAll("Run 'zim --help' for usage.\n");
    try writer.interface.flush();
}

fn printConfigError(io: std.Io, path: []const u8, err: anyerror) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print("zim: Lua config error in {s}: {s}\n", .{ path, @errorName(err) });
    try writer.interface.flush();
}