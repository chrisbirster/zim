const std = @import("std");
const api_module = @import("api.zig");
const build_info = @import("build_info.zig");
const cli = @import("cli.zig");
const daily_driver = @import("daily_driver.zig");
const editor = @import("editor.zig");
const lua_runtime = @import("lua_runtime.zig");
const plugin_manager = @import("plugin_manager.zig");
const rpc = @import("rpc/root.zig");
const terminal_compat = @import("terminal_compat.zig");
const terminal_controller = @import("terminal_controller.zig");
const tui = @import("tui.zig");

pub const version = build_info.version;

const help_text =
    \\Zim — your new code overlord.
    \\
    \\Usage:
    \\  zim [options] [file|directory]
    \\
    \\Options:
    \\  -h, --help              Show this help
    \\  -v, --version           Show version and public API metadata
    \\      --check             Print Daily Driver runtime diagnostics
    \\      --headless          Start the editor core without the Hondo TUI
    \\      --rpc-stdio         Serve MessagePack-RPC on stdin/stdout (headless)
    \\      --rpc-listen NAME   Serve local RPC (Unix socket path / Windows pipe name)
    \\
;

const lua_v1_bootstrap =
    \\zim.version = '1.0.0'
    \\function zim.colorscheme(name)
    \\  return zim.command.execute('Colorscheme', name or '')
    \\end
    \\zim.highlight = zim.highlight or {}
    \\function zim.highlight.set(group, opts)
    \\  assert(type(group) == 'string' and #group > 0, 'highlight group must be a non-empty string')
    \\  opts = opts or {}
    \\  local parts = {group}
    \\  if opts.fg ~= nil then table.insert(parts, 'fg=' .. tostring(opts.fg)) end
    \\  if opts.bg ~= nil then table.insert(parts, 'bg=' .. tostring(opts.bg)) end
    \\  if opts.bold == true then table.insert(parts, 'bold') end
    \\  if opts.italic == true then table.insert(parts, 'italic') end
    \\  if opts.dim == true then table.insert(parts, 'dim') end
    \\  if opts.underline == true then table.insert(parts, 'underline') end
    \\  if opts.bold == false then table.insert(parts, 'nobold') end
    \\  if opts.italic == false then table.insert(parts, 'noitalic') end
    \\  if opts.dim == false then table.insert(parts, 'nodim') end
    \\  if opts.underline == false then table.insert(parts, 'nounderline') end
    \\  return zim.command.execute('Highlight', table.concat(parts, ' '))
    \\end
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
            var buffer: [256]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &buffer);
            try writer.interface.print(
                "zim {s}\npublic-api {d} · plugin-api {d} · rpc {d}/{d}\n",
                .{ build_info.version, build_info.public_api_version, build_info.plugin_api_version, build_info.rpc_protocol_version, build_info.rpc_api_version },
            );
            try writer.interface.flush();
            return 0;
        },
        .check => return printCheck(init),
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

            const config_root = try configRootAlloc(init.gpa, init.environ_map);
            defer if (config_root) |root| init.gpa.free(root);

            var driver: ?*daily_driver.Service = null;
            defer if (driver) |service| service.destroy();
            if (config_root) |root| {
                driver = daily_driver.Service.create(init.gpa, init.io, root, &api, &state) catch |err| blk: {
                    try printRecoverable(init.io, "Daily Driver service", err);
                    break :blk null;
                };
                if (options.target == null) {
                    if (driver) |service| _ = service.restoreLastSession();
                }
                state.configurePins(root) catch |err| reportRecoverable(driver, init.io, "Pins", err);
            }

            var lua_state: ?lua_runtime.Runtime = lua_runtime.Runtime.init(init.gpa, &api, &state) catch |err| blk: {
                reportRecoverable(driver, init.io, "Lua runtime", err);
                break :blk null;
            };
            defer if (lua_state) |*lua| lua.deinit();

            var plugins: ?*plugin_manager.Manager = null;
            defer if (plugins) |manager| manager.destroy();
            if (lua_state) |*lua| {
                lua.eval(lua_v1_bootstrap) catch |err| reportRecoverable(driver, init.io, "Lua v1 bootstrap", err);
                if (config_root) |root| {
                    plugins = plugin_manager.Manager.create(init.gpa, init.io, root, &api, &state, lua) catch |err| blk: {
                        reportRecoverable(driver, init.io, "Plugin manager", err);
                        break :blk null;
                    };
                    const config_path = try std.fmt.allocPrint(init.gpa, "{s}/init.lua", .{root});
                    defer init.gpa.free(config_path);
                    _ = lua.loadFile(init.io, config_path) catch |err| blk: {
                        if (driver) |service| service.recordError("Lua config", err) else try printConfigError(init.io, config_path, err);
                        break :blk false;
                    };
                }
            }

            const current = api.currentBuffer(&state);
            const window = api.currentWindow(&state);
            const tab = api.currentTab(&state);
            try api.emit(&state, .{ .kind = .editor_enter, .buffer_id = current.id, .window_id = window.id, .tab_id = tab.id });
            try api.emit(&state, .{ .kind = .buffer_enter, .buffer_id = current.id, .window_id = window.id, .tab_id = tab.id });
            defer api.emit(&state, .{
                .kind = .editor_leave,
                .buffer_id = state.currentBufferConst().id,
                .window_id = state.currentWindowConst().id,
                .tab_id = state.activeTabConst().id,
            }) catch {};

            if (options.rpc_stdio) {
                var host = rpc.Host.init(init.gpa, &api, &state);
                defer host.deinit();
                try rpc.transport.serveStdio(init.gpa, &host);
                return finish(driver, 0);
            }

            if (options.rpc_listen) |endpoint| {
                if (options.headless) {
                    var rpc_controller = try rpc.Controller.init(init.gpa, &api, &state, endpoint);
                    defer rpc_controller.deinit();
                    try rpc_controller.serveUntilDisconnect();
                    return finish(driver, 0);
                }
                terminal.attachRpc(&api, &state, endpoint) catch |err| reportRecoverable(driver, init.io, "RPC listener", err);
            }

            if (options.headless) return finish(driver, 0);
            const result = try tui.run(init, &state, &api, &terminal);
            return finish(driver, result);
        },
    }
}

fn finish(driver: ?*daily_driver.Service, result: u8) u8 {
    if (driver) |service| service.saveCleanState() catch |err| service.recordError("session shutdown save", err);
    return result;
}

fn printCheck(init: std.process.Init) u8 {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const terminal = terminal_compat.inspect(init.environ_map);
    writer.interface.print("Zim {s} Daily Driver\n", .{build_info.version}) catch return 1;
    writer.interface.print("public-api={d} plugin-api={d} rpc={d}/{d} compatibility={s}\n", .{
        build_info.public_api_version,
        build_info.plugin_api_version,
        build_info.rpc_protocol_version,
        build_info.rpc_api_version,
        build_info.compatibility_policy,
    }) catch return 1;
    writer.interface.print("terminal={s} TERM={s} color={s} ssh={s} tmux={s}\n", .{
        @tagName(terminal.family),
        terminal.term,
        if (terminal.interactive_color) "yes" else "no",
        if (terminal.under_ssh) "yes" else "no",
        if (terminal.under_tmux) "yes" else "no",
    }) catch return 1;
    writer.interface.flush() catch return 1;
    return 0;
}

fn configRootAlloc(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !?[]u8 {
    if (environment.get("XDG_CONFIG_HOME")) |root| return try std.fmt.allocPrint(allocator, "{s}/zim", .{root});
    if (environment.get("APPDATA")) |root| return try std.fmt.allocPrint(allocator, "{s}/zim", .{root});
    if (environment.get("HOME")) |home| return try std.fmt.allocPrint(allocator, "{s}/.config/zim", .{home});
    return null;
}

fn reportRecoverable(driver: ?*daily_driver.Service, io: std.Io, source: []const u8, err: anyerror) void {
    if (driver) |service| {
        service.recordError(source, err);
        return;
    }
    printRecoverable(io, source, err) catch {};
}

fn printParseError(io: std.Io, err: cli.ParseError) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    switch (err) {
        error.UnknownOption => try writer.interface.writeAll("zim: unknown option\n"),
        error.TooManyTargets => try writer.interface.writeAll("zim: only one file or directory may be opened at startup\n"),
        error.MissingOptionValue => try writer.interface.writeAll("zim: RPC option requires an endpoint value\n"),
        error.MultipleRpcEndpoints => try writer.interface.writeAll("zim: only one RPC endpoint may be configured\n"),
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

fn printRecoverable(io: std.Io, source: []const u8, err: anyerror) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print("zim: {s}: {s}\n", .{ source, @errorName(err) });
    try writer.interface.flush();
}
