const std = @import("std");

pub const JobId = u64;
pub const Stream = enum { stdout, stderr };

pub const Status = enum(u8) {
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
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
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
    future_consumed: bool = false,
    status_value: std.atomic.Value(Status) = .init(.running),
    term: ?std.process.Child.Term = null,
    stdout_storage: []u8,
    stderr_storage: []u8,
    stdout_len: std.atomic.Value(usize) = .init(0),
    stderr_len: std.atomic.Value(usize) = .init(0),
    stdout_truncated: std.atomic.Value(bool) = .init(false),
    stderr_truncated: std.atomic.Value(bool) = .init(false),

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
            .cwd = if (options.cwd) |path| .{ .path = path } else .{ .inherit = {} },
            .environ_map = options.environ_map,
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
        if (!self.future_consumed) {
            _ = self.future.cancel(self.io) catch {};
            self.future_consumed = true;
        }
        self.allocator.free(self.stdout_storage);
        self.allocator.free(self.stderr_storage);
        self.* = undefined;
    }

    fn install(self: *Entry, output: WorkerOutput) void {
        self.term = output.term;
        self.stdout_len.store(output.stdout.len, .release);
        self.stderr_len.store(output.stderr.len, .release);
        self.stdout_truncated.store(output.stdout.truncated, .release);
        self.stderr_truncated.store(output.stderr.truncated, .release);
        self.status_value.store(.completed, .release);
    }

    fn status(self: *const Entry) Status {
        return self.status_value.load(.acquire);
    }

    fn exitCode(self: *const Entry, status_value: Status) ?u8 {
        if (status_value != .completed) return null;
        const term = self.term orelse return null;
        return switch (term) {
            .exited => |code| code,
            else => null,
        };
    }

    fn snapshot(self: *const Entry) Snapshot {
        const status_value = self.status();
        return .{
            .id = self.id,
            .status = status_value,
            .exit_code = self.exitCode(status_value),
            .stdout_len = self.stdout_len.load(.acquire),
            .stderr_len = self.stderr_len.load(.acquire),
            .stdout_truncated = self.stdout_truncated.load(.acquire),
            .stderr_truncated = self.stderr_truncated.load(.acquire),
        };
    }
};

fn readCapture(
    io: std.Io,
    file: std.Io.File,
    storage: []u8,
    visible_len: *std.atomic.Value(usize),
    visible_truncated: *std.atomic.Value(bool),
) !Capture {
    var capture: Capture = .{};
    var scratch: [4096]u8 = undefined;

    while (true) {
        const n = file.readStreaming(io, &.{&scratch}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;

        const remaining = storage.len - capture.len;
        const accepted = @min(remaining, n);
        if (accepted > 0) {
            @memcpy(storage[capture.len..][0..accepted], scratch[0..accepted]);
            capture.len += accepted;
            visible_len.store(capture.len, .release);
        }
        if (accepted != n) {
            capture.truncated = true;
            visible_truncated.store(true, .release);
        }
    }

    return capture;
}

fn runJob(entry: *Entry) WorkerResult {
    const output = runJobInner(entry) catch |err| {
        if (err != error.Canceled) entry.status_value.store(.failed, .release);
        return err;
    };
    entry.install(output);
    return output;
}

fn runJobInner(entry: *Entry) WorkerResult {
    errdefer entry.child.kill(entry.io);

    const stdout_file = entry.child.stdout orelse return error.StdoutUnavailable;
    const stderr_file = entry.child.stderr orelse return error.StderrUnavailable;

    var stdout_future = try entry.io.concurrent(readCapture, .{
        entry.io,
        stdout_file,
        entry.stdout_storage,
        &entry.stdout_len,
        &entry.stdout_truncated,
    });
    defer _ = stdout_future.cancel(entry.io) catch {};

    var stderr_future = try entry.io.concurrent(readCapture, .{
        entry.io,
        stderr_file,
        entry.stderr_storage,
        &entry.stderr_len,
        &entry.stderr_truncated,
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
        if (entry.future_consumed) return;

        const output = entry.future.await(self.io) catch |err| {
            entry.future_consumed = true;
            if (err == error.Canceled) {
                entry.status_value.store(.cancelled, .release);
            } else {
                entry.status_value.store(.failed, .release);
            }
            return err;
        };
        entry.future_consumed = true;
        entry.install(output);
    }

    pub fn cancel(self: *Manager, id: JobId) !bool {
        const entry = self.find(id) orelse return error.UnknownJob;
        if (entry.status() != .running or entry.future_consumed) return false;

        if (entry.future.cancel(self.io)) |output| {
            entry.future_consumed = true;
            entry.install(output);
            return false;
        } else |err| {
            entry.future_consumed = true;
            if (err == error.Canceled) {
                entry.status_value.store(.cancelled, .release);
                return true;
            }
            entry.status_value.store(.failed, .release);
            return err;
        }
    }

    pub fn status(self: *const Manager, id: JobId) ?Status {
        const entry = self.findConst(id) orelse return null;
        return entry.status();
    }

    pub fn snapshot(self: *const Manager, id: JobId) ?Snapshot {
        const entry = self.findConst(id) orelse return null;
        return entry.snapshot();
    }

    pub fn snapshotAt(self: *const Manager, index: usize) ?Snapshot {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index].snapshot();
    }

    pub fn stdout(self: *const Manager, id: JobId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        const len = entry.stdout_len.load(.acquire);
        return entry.stdout_storage[0..len];
    }

    pub fn stderr(self: *const Manager, id: JobId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        const len = entry.stderr_len.load(.acquire);
        return entry.stderr_storage[0..len];
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

test "job manager exposes ordered snapshots" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const first = try manager.start(&.{ "zig", "version" }, .{});
    const second = try manager.start(&.{ "zig", "version" }, .{});
    try manager.wait(first);
    try manager.wait(second);

    try std.testing.expectEqual(first, manager.snapshotAt(0).?.id);
    try std.testing.expectEqual(second, manager.snapshotAt(1).?.id);
    try std.testing.expect(manager.snapshotAt(2) == null);
}

test "job manager applies an explicit working directory" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    var failed = false;
    _ = manager.start(&.{ "zig", "version" }, .{ .cwd = "__zim_missing_working_directory__" }) catch {
        failed = true;
    };
    try std.testing.expect(failed);
}
