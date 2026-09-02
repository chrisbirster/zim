const std = @import("std");
const api_module = @import("api.zig");
const editor_module = @import("editor.zig");
const lua_runtime = @import("lua_runtime.zig");
const plugin_manager = @import("plugin_manager.zig");

const max_git_output = 1024 * 1024;

fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(max_git_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn gitHead(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "rev-parse", "HEAD" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "PackAdd PackUpdate and PackRemove maintain an exact-SHA lockfile" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "source-plugin");
    try tmp.dir.writeFile(io, .{ .sub_path = "source-plugin/zim-plugin.meta", .data =
        \\name=source-plugin
        \\version=0.1.0
        \\zim_api=1
        \\min_zim=0.4.0
        \\capabilities=commands
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "source-plugin/plugin.lua", .data =
        \\zim.command.create('PackageHello', function(args)
        \\  zim.buf.set_text('v1:' .. args)
        \\end)
    });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const source = try std.fmt.allocPrint(allocator, "{s}/source-plugin", .{root});
    defer allocator.free(source);

    try runGit(allocator, io, &.{ "git", "init", source });
    try runGit(allocator, io, &.{ "git", "-C", source, "config", "user.name", "Zim Tests" });
    try runGit(allocator, io, &.{ "git", "-C", source, "config", "user.email", "zim-tests@example.invalid" });
    try runGit(allocator, io, &.{ "git", "-C", source, "add", "." });
    try runGit(allocator, io, &.{ "git", "-C", source, "commit", "-m", "initial" });
    const first_head = try gitHead(allocator, io, source);
    defer allocator.free(first_head);

    var editor = try editor_module.Editor.init(allocator, io, null);
    defer editor.deinit();
    var api = api_module.Api.init(allocator);
    defer api.deinit();
    var lua = try lua_runtime.Runtime.init(allocator, &api, &editor);
    defer lua.deinit();
    try lua.eval("zim.version = '0.4.0'");

    var manager = try plugin_manager.Manager.create(allocator, io, root, &api, &editor, &lua);
    try api.commandExecute(&editor, "PackAdd", source);
    try std.testing.expectEqual(@as(usize, 1), manager.locks.items.len);
    try std.testing.expectEqualStrings(first_head, manager.locks.items[0].revision);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/plugins.lock", .{root});
    defer allocator.free(lock_path);
    const first_lock = try std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(1024 * 1024));
    defer allocator.free(first_lock);
    try expectContains(first_lock, "source-plugin\t");
    try expectContains(first_lock, first_head);

    manager.destroy();
    manager = try plugin_manager.Manager.create(allocator, io, root, &api, &editor, &lua);
    defer manager.destroy();
    try std.testing.expect(api.commands.find("PackageHello") != null);
    try api.commandExecute(&editor, "PackageHello", "installed");
    try std.testing.expectEqualStrings("v1:installed", editor.currentBufferConst().text.items);

    try tmp.dir.writeFile(io, .{ .sub_path = "source-plugin/plugin.lua", .data =
        \\zim.command.create('PackageHello', function(args)
        \\  zim.buf.set_text('v2:' .. args)
        \\end)
    });
    try runGit(allocator, io, &.{ "git", "-C", source, "add", "plugin.lua" });
    try runGit(allocator, io, &.{ "git", "-C", source, "commit", "-m", "update plugin" });
    const second_head = try gitHead(allocator, io, source);
    defer allocator.free(second_head);
    try std.testing.expect(!std.mem.eql(u8, first_head, second_head));

    try api.commandExecute(&editor, "PackUpdate", "source-plugin");
    try std.testing.expectEqualStrings(second_head, manager.locks.items[0].revision);
    const second_lock = try std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(1024 * 1024));
    defer allocator.free(second_lock);
    try expectContains(second_lock, second_head);
    try std.testing.expect(std.mem.indexOf(u8, second_lock, first_head) == null);

    try api.commandExecute(&editor, "PackRemove", "source-plugin");
    try std.testing.expectEqual(@as(usize, 0), manager.locks.items.len);
    const final_lock = try std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(1024 * 1024));
    defer allocator.free(final_lock);
    try std.testing.expectEqualStrings("# zim-plugin-lock-v1\n", final_lock);
}
