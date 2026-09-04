const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const c = if (is_windows) struct {} else @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

const Native = if (is_windows) struct {} else struct {
    pid: std.posix.pid_t,
    master: std.Io.File,
};

pub const Dimensions = struct {
    columns: u16 = 80,
    rows: u16 = 24,
};

pub const SpawnOptions = struct {
    dimensions: Dimensions = .{},
};

pub const Session = struct {
    io: std.Io,
    native: Native,
    reaped: bool = false,
    closed: bool = false,

    pub fn supported() bool {
        return !is_windows;
    }

    pub fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: SpawnOptions,
    ) !Session {
        if (comptime is_windows) return error.PtyUnsupported;
        if (argv.len == 0) return error.EmptyArgv;

        const owned = try allocator.alloc([:0]u8, argv.len);
        defer allocator.free(owned);
        var owned_count: usize = 0;
        defer for (owned[0..owned_count]) |arg| allocator.free(arg);

        const c_argv = try allocator.alloc(?[*:0]u8, argv.len + 1);
        defer allocator.free(c_argv);
        for (argv, 0..) |arg, index| {
            owned[index] = try allocator.dupeZ(u8, arg);
            owned_count += 1;
            c_argv[index] = owned[index].ptr;
        }
        c_argv[argv.len] = null;

        var master_fd: c_int = -1;
        var winsize = c.struct_winsize{
            .ws_row = options.dimensions.rows,
            .ws_col = options.dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const pid = forkpty(&master_fd, null, null, &winsize);
        if (pid < 0) return error.PtySpawnFailed;
        if (pid == 0) {
            _ = c.execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
            c._exit(127);
        }

        return .{
            .io = io,
            .native = .{
                .pid = @intCast(pid),
                .master = .{ .handle = @intCast(master_fd) },
            },
        };
    }

    pub fn read(self: *Session, buffer: []u8) !usize {
        if (comptime is_windows) return error.PtyUnsupported;
        if (self.closed) return 0;
        return self.native.master.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            error.InputOutput => 0,
            else => return err,
        };
    }

    pub fn write(self: *Session, bytes: []const u8) !void {
        if (comptime is_windows) return error.PtyUnsupported;
        if (self.closed) return error.PtyClosed;
        try self.native.master.writeStreamingAll(self.io, bytes);
    }

    pub fn resize(self: *Session, dimensions: Dimensions) !void {
        if (comptime is_windows) return error.PtyUnsupported;
        if (self.closed) return error.PtyClosed;
        var winsize = c.struct_winsize{
            .ws_row = dimensions.rows,
            .ws_col = dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.native.master.handle, c.TIOCSWINSZ, &winsize) != 0) return error.PtyResizeFailed;
    }

    pub fn terminate(self: *Session) !void {
        if (comptime is_windows) return error.PtyUnsupported;
        if (self.reaped) return;
        std.posix.kill(self.native.pid, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
    }

    pub fn wait(self: *Session) !void {
        if (comptime is_windows) return error.PtyUnsupported;
        if (self.reaped) return;
        _ = std.posix.waitpid(self.native.pid, 0);
        self.reaped = true;
    }

    pub fn deinit(self: *Session) void {
        if (comptime is_windows) {
            self.* = undefined;
            return;
        }
        if (!self.reaped) {
            self.terminate() catch {};
            _ = std.posix.waitpid(self.native.pid, 0);
            self.reaped = true;
        }
        if (!self.closed) {
            self.native.master.close(self.io);
            self.closed = true;
        }
        self.* = undefined;
    }
};

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const if (is_windows) anyopaque else c.struct_winsize,
) c_int;

test "PTY platform boundary is explicit" {
    if (comptime is_windows) {
        try std.testing.expect(!Session.supported());
        try std.testing.expectError(error.PtyUnsupported, Session.spawn(std.testing.allocator, std.testing.io, &.{ "zig", "version" }, .{}));
    } else {
        try std.testing.expect(Session.supported());
    }
}

test "POSIX PTY runs a child with terminal semantics" {
    if (comptime is_windows) return error.SkipZigTest;

    var session = try Session.spawn(std.testing.allocator, std.testing.io, &.{ "zig", "version" }, .{ .dimensions = .{ .columns = 100, .rows = 30 } });
    defer session.deinit();
    try session.resize(.{ .columns = 120, .rows = 40 });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var buffer: [1024]u8 = undefined;
    while (true) {
        const n = try session.read(&buffer);
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buffer[0..n]);
    }
    try session.wait();
    try std.testing.expect(std.mem.indexOf(u8, output.items, "0.16") != null);
}
