const std = @import("std");

pub const JobId = u64;
pub const Stream = enum { stdout, stderr };

pub const Status = enum {
    running,
    completed,
    cancelled,
    failed,
};

pub const Input = enum {
    ignore,
    pipe,
};

pub const Options = struct {
    output_limit: usize = 256 * 1024,
    stdin: Input = .ignore,
};

pub const Snapshot = struct {
    id: JobId,
    status: Status,
    exit_code: ?u8,
    stdout_len: usize,
    stderr_len: usize,
    stdout_truncated: bool,
    stderr_truncated: bool,
};

const Capture = struct {
    len: usize = 0,
    truncated: bool = false,
};

const WorkerOutput = struct {
    term: std.process.Child.Term,
    stdout: Capture,
    stderr: Capture,
};

const WorkerResult = anyerror!WorkerOutput;
const WorkerFuture = std.Io.Future(WorkerResult);

const Entry = struct {
    id: JobId,
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    future: WorkerFuture,
    status: Status = .running,
    term: ?std.process.Child.Term = null,
    stdout_storage: []u8,
    stderr_storage: []u8,
    stdout_len: usize = 0,
    stderr_len: usize = 0,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,

    fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        id: JobId,
        argv: []const []const u8,
        options: Options,
    ) !*Entry {
        if (argv.len == 0) return error.EmptyArgv;

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = switch (options.stdin) {
                .ignore => .ignore,
                .pipe => .pipe,
            },
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);

        const stdout_storage = try allocator.alloc(u8, options.output_limit);
        errdefer allocator.free(stdout_storage);
        const stderr_storage = try allocator.alloc(u8, options.output_limit);
        errdefer allocator.free(stderr_storage);

        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{
            .id = id,
            .io = io,
            .allocator = allocator,
            .child = child,
            .future = undefined,
            .stdout_storage = stdout_storage,
            .stderr_storage = stderr_storage,
        };
        entry.future = io.async(runJob, .{entry});
        return entry;
    }

    fn deinit(self: *Entry) void {
        if (self.status == .running) {
            _ = self.future.cancel(self.io) catch {};
        }
        self.allocator.free(self.stdout_storage);
        self.allocator.free(self.stderr_storage);
        self.* = undefined;
    }

    fn install(self: *Entry, output: WorkerOutput) void {
        self.term = output.term;
        self.stdout_len = output.stdout.len;
        self.stderr_len = output.stderr.len;
        self.stdout_truncated = output.stdout.truncated;
        self.stderr_truncated = output.stderr.truncated;
        self.status = .completed;
    }

    fn exitCode(self: *const Entry) ?u8 {
        const term = self.term orelse return null;
        return switch (term) {
            .exited => |code| code,
            else => null,
        };
    }

    fn snapshot(self: *const Entry) Snapshot {
        return .{
            .id = self.id,
            .status = self.status,
            .exit_code = self.exitCode(),
            .stdout_len = self.stdout_len,
            .stderr_len = self.stderr_len,
            .stdout_truncated = self.stdout_truncated,
            .stderr_truncated = self.stderr_truncated,
        };
    }
};

fn readCapture(io: std.Io, file: std.Io.File, storage: []u8) !Capture {
    var capture: Capture = .{};
    var scratch: [4096]u8 = undefined;

    while (true) {
        const n = try file.readStreaming(io, &.{&scratch});
        if (n == 0) break;

        const remaining = storage.len - capture.len;
        const accepted = @min(remaining, n);
        if (accepted > 0) {
            @memcpy(storage[capture.len..][0..accepted], scratch[0..accepted]);
            capture.len += accepted;
        }
        if (accepted != n) capture.truncated = true;
    }

    return capture;
}

fn runJob(entry: *Entry) WorkerResult {
    errdefer entry.child.kill(entry.io);

    const stdout_file = entry.child.stdout orelse return error.StdoutUnavailable;
    const stderr_file = entry.child.stderr orelse return error.StderrUnavailable;

    var stdout_future = entry.io.async(readCapture, .{
        entry.io,
        stdout_file,
        entry.stdout_storage,
    });
    defer _ = stdout_future.cancel(entry.io) catch {};

    var stderr_future = entry.io.async(readCapture, .{
        entry.io,
        stderr_file,
        entry.stderr_storage,
    });
    defer _ = stderr_future.cancel(entry.io) catch {};

    const stdout_capture = try stdout_future.await(entry.io);
    const stderr_capture = try stderr_future.await(entry.io);
    const term = try entry.child.wait(entry.io);

    return .{
        .term = term,
        .stdout = stdout_capture,
        .stderr = stderr_capture,
    };
}

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    next_id: JobId = 1,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |entry| {
            entry.deinit();
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *Manager, id: JobId) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn findConst(self: *const Manager, id: JobId) ?*const Entry {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    pub fn start(self: *Manager, argv: []const []const u8, options: Options) !JobId {
        const id = self.next_id;
        self.next_id += 1;

        const entry = try Entry.spawn(self.allocator, self.io, id, argv, options);
        errdefer {
            entry.deinit();
            self.allocator.destroy(entry);
        }
        try self.entries.append(self.allocator, entry);
        return id;
    }

    pub fn wait(self: *Manager, id: JobId) !void {
        const entry = self.find(id) orelse return error.UnknownJob;
        if (entry.status != .running) return;

        const output = entry.future.await(self.io) catch |err| {
            std.debug.print("zim job {d} worker error: {s}\n", .{ id, @errorName(err) });
            entry.status = if (err == error.Canceled) .cancelled else .failed;
            return err;
        };
        entry.install(output);
    }

    pub fn cancel(self: *Manager, id: JobId) !bool {
        const entry = self.find(id) orelse return error.UnknownJob;
        if (entry.status != .running) return false;

        if (entry.future.cancel(self.io)) |output| {
            entry.install(output);
            return false;
        } else |err| {
            if (err == error.Canceled) {
                entry.status = .cancelled;
                return true;
            }
            entry.status = .failed;
            return err;
        }
    }

    pub fn status(self: *const Manager, id: JobId) ?Status {
        const entry = self.findConst(id) orelse return null;
        return entry.status;
    }

    pub fn snapshot(self: *const Manager, id: JobId) ?Snapshot {
        const entry = self.findConst(id) orelse return null;
        return entry.snapshot();
    }

    pub fn stdout(self: *const Manager, id: JobId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        return entry.stdout_storage[0..entry.stdout_len];
    }

    pub fn stderr(self: *const Manager, id: JobId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        return entry.stderr_storage[0..entry.stderr_len];
    }

    pub fn count(self: *const Manager) usize {
        return self.entries.items.len;
    }
};

test "job manager starts asynchronously and captures stdout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "version" }, .{});
    try std.testing.expectEqual(Status.running, manager.status(id).?);
    try manager.wait(id);

    const snap = manager.snapshot(id).?;
    try std.testing.expectEqual(Status.completed, snap.status);
    try std.testing.expectEqual(@as(?u8, 0), snap.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, manager.stdout(id).?, "0.16") != null);
    try std.testing.expectEqual(@as(usize, 0), manager.stderr(id).?.len);
}

test "job manager captures stderr independently" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "__zim_invalid_command__" }, .{});
    try manager.wait(id);

    const snap = manager.snapshot(id).?;
    try std.testing.expectEqual(Status.completed, snap.status);
    try std.testing.expect(snap.exit_code != null);
    try std.testing.expect(snap.exit_code.? != 0);
    try std.testing.expect(manager.stderr(id).?.len > 0);
}

test "job output is bounded and reports truncation" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "__zim_invalid_command__" }, .{ .output_limit = 8 });
    try manager.wait(id);

    const snap = manager.snapshot(id).?;
    try std.testing.expect(manager.stderr(id).?.len <= 8);
    try std.testing.expect(snap.stderr_truncated);
}

test "job cancellation interrupts a running child" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "fmt", "--stdin" }, .{ .stdin = .pipe });
    try std.testing.expect(try manager.cancel(id));
    try std.testing.expectEqual(Status.cancelled, manager.status(id).?);
    try std.testing.expect(!(try manager.cancel(id)));
}
