const std = @import("std");
const core = @import("../jobs.zig");
const editor_module = @import("../editor.zig");
const commands = @import("commands.zig");

pub const Service = struct {
    allocator: std.mem.Allocator,
    manager: ?core.Manager = null,
    commands_registered: bool = false,

    pub fn init(allocator: std.mem.Allocator) Service {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Service) void {
        if (self.manager) |*manager| manager.deinit();
        self.* = undefined;
    }

    fn ensure(self: *Service, editor: *editor_module.Editor) *core.Manager {
        if (self.manager == null) {
            self.manager = core.Manager.init(self.allocator, editor.io);
        }
        return &self.manager.?;
    }

    pub fn registerCommands(self: *Service, registry: *commands.Registry) !void {
        if (self.commands_registered) return;
        _ = try registry.create("JobStart", "start an asynchronous argv-based job", jobStartCommand, self);
        errdefer _ = registry.delete("JobStart");
        _ = try registry.create("JobStop", "stop a running asynchronous job", jobStopCommand, self);
        errdefer _ = registry.delete("JobStop");
        _ = try registry.create("JobList", "list asynchronous jobs and states", jobListCommand, self);
        self.commands_registered = true;
    }

    pub fn start(self: *Service, editor: *editor_module.Editor, argv: []const []const u8, options: core.Options) !core.JobId {
        return self.ensure(editor).start(argv, options);
    }

    pub fn wait(self: *Service, id: core.JobId) !void {
        const manager = if (self.manager) |*value| value else return error.UnknownJob;
        try manager.wait(id);
    }

    pub fn stop(self: *Service, id: core.JobId) !bool {
        const manager = if (self.manager) |*value| value else return error.UnknownJob;
        return manager.cancel(id);
    }

    pub fn status(self: *const Service, id: core.JobId) ?core.Status {
        const manager = if (self.manager) |*value| value else return null;
        return manager.status(id);
    }

    pub fn snapshot(self: *const Service, id: core.JobId) ?core.Snapshot {
        const manager = if (self.manager) |*value| value else return null;
        return manager.snapshot(id);
    }

    pub fn snapshotAt(self: *const Service, index: usize) ?core.Snapshot {
        const manager = if (self.manager) |*value| value else return null;
        return manager.snapshotAt(index);
    }

    pub fn stdout(self: *const Service, id: core.JobId) ?[]const u8 {
        const manager = if (self.manager) |*value| value else return null;
        return manager.stdout(id);
    }

    pub fn stderr(self: *const Service, id: core.JobId) ?[]const u8 {
        const manager = if (self.manager) |*value| value else return null;
        return manager.stderr(id);
    }

    pub fn count(self: *const Service) usize {
        const manager = if (self.manager) |*value| value else return 0;
        return manager.count();
    }
};

fn serviceFromContext(context: *commands.Context) *Service {
    return @ptrCast(@alignCast(context.user_data.?));
}

fn setStatus(editor: *editor_module.Editor, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&editor.status_buffer, fmt, args) catch {
        editor.status_len = 0;
        return;
    };
    editor.status_len = written.len;
}

fn appendStatus(editor: *editor_module.Editor, used: *usize, comptime fmt: []const u8, args: anytype) bool {
    if (used.* >= editor.status_buffer.len) return false;
    const written = std.fmt.bufPrint(editor.status_buffer[used.*..], fmt, args) catch return false;
    used.* += written.len;
    return true;
}

fn jobStartCommand(context: *commands.Context) !void {
    const service = serviceFromContext(context);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(service.allocator);

    var parts = std.mem.tokenizeAny(u8, context.args, " \t\r\n");
    while (parts.next()) |part| try argv.append(service.allocator, part);
    if (argv.items.len == 0) {
        setStatus(context.editor, "usage: JobStart <program> [args...]", .{});
        return;
    }

    const id = service.start(context.editor, argv.items, .{}) catch |err| {
        setStatus(context.editor, "JobStart failed: {s}", .{@errorName(err)});
        return;
    };
    setStatus(context.editor, "job {d} started: {s}", .{ id, argv.items[0] });
}

fn jobStopCommand(context: *commands.Context) !void {
    const service = serviceFromContext(context);
    const text = std.mem.trim(u8, context.args, " \t\r\n");
    if (text.len == 0) {
        setStatus(context.editor, "usage: JobStop <job-id>", .{});
        return;
    }
    const id = std.fmt.parseUnsigned(core.JobId, text, 10) catch {
        setStatus(context.editor, "JobStop: invalid job id", .{});
        return;
    };
    const stopped = service.stop(id) catch |err| {
        setStatus(context.editor, "JobStop failed: {s}", .{@errorName(err)});
        return;
    };
    if (stopped) {
        setStatus(context.editor, "job {d} stopped", .{id});
    } else {
        const status = service.status(id) orelse .failed;
        setStatus(context.editor, "job {d} is {s}", .{ id, @tagName(status) });
    }
}

fn jobListCommand(context: *commands.Context) !void {
    const service = serviceFromContext(context);
    if (service.count() == 0) {
        setStatus(context.editor, "no jobs", .{});
        return;
    }

    var used: usize = 0;
    _ = appendStatus(context.editor, &used, "jobs:", .{});
    var index: usize = 0;
    while (index < service.count()) : (index += 1) {
        const snapshot = service.snapshotAt(index) orelse continue;
        if (!appendStatus(context.editor, &used, " {d}:{s}", .{ snapshot.id, @tagName(snapshot.status) })) break;
    }
    context.editor.status_len = used;
}

test "job command service uses the public command registry" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var registry = commands.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    try service.registerCommands(&registry);
    try registry.execute(&editor, "JobStart", "zig version");
    try std.testing.expectEqual(@as(usize, 1), service.count());
    try service.wait(1);
    try std.testing.expectEqual(core.Status.completed, service.status(1).?);
    try std.testing.expect(std.mem.indexOf(u8, service.stdout(1).?, "0.16") != null);

    try registry.execute(&editor, "JobList", "");
    try std.testing.expect(std.mem.indexOf(u8, editor.status_buffer[0..editor.status_len], "1:completed") != null);
}
