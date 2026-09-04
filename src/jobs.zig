const std = @import("std");

pub const JobId = u64;
pub const Stream = enum { stdout, stderr };

const JobPoller = @TypeOf(std.Io.poll(undefined, Stream, .{
    .stdout = undefined,
    .stderr = undefined,
}));

pub const Status = enum {
    running,
    completed,
    cancelled,
};

pub const Options = struct {
    output_limit: usize = 1024 * 1024,
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

const Entry = struct {
    id: JobId,
    io: std.Io,
    allocator: std.mem.Allocator,
    child: ?std.process.Child,
    poller: JobPoller,
    status: Status = .running,
    term: ?std.process.Child.Term = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    output_limit: usize,

    fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        id: JobId,
        argv: []const []const u8,
        options: Options,
    ) !Entry {
        if (argv.len == 0) return error.EmptyArgv;

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);

        const stdout_file = child.stdout orelse return error.StdoutUnavailable;
        const stderr_file = child.stderr orelse return error.StderrUnavailable;

        return .{
            .id = id,
            .io = io,
            .allocator = allocator,
            .child = child,
            .poller = std.Io.poll(allocator, Stream, .{
                .stdout = stdout_file,
                .stderr = stderr_file,
            }),
            .output_limit = options.output_limit,
        };
    }

    fn deinit(self: *Entry) void {
        if (self.child) |child_value| {
            var child = child_value;
            child.kill(self.io);
            self.child = null;
        }
        self.poller.deinit();
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendBounded(
        self: *Entry,
        target: *std.ArrayList(u8),
        truncated: *bool,
        bytes: []const u8,
    ) !void {
        if (bytes.len == 0) return;

        const used = @min(target.items.len, self.output_limit);
        const remaining = self.output_limit - used;
        const accepted = @min(remaining, bytes.len);
        if (accepted > 0) try target.appendSlice(self.allocator, bytes[0..accepted]);
        if (accepted != bytes.len) truncated.* = true;
    }

    fn drain(self: *Entry) !void {
        const stdout_reader = self.poller.reader(.stdout);
        const stdout_bytes = stdout_reader.buffered();
        try self.appendBounded(&self.stdout, &self.stdout_truncated, stdout_bytes);
        stdout_reader.toss(stdout_bytes.len);

        const stderr_reader = self.poller.reader(.stderr);
        const stderr_bytes = stderr_reader.buffered();
        try self.appendBounded(&self.stderr, &self.stderr_truncated, stderr_bytes);
        stderr_reader.toss(stderr_bytes.len);
    }

    fn finish(self: *Entry) !void {
        if (self.status != .running) return;
        var child = self.child orelse return error.ProcessNotRunning;
        self.child = null;
        self.term = try child.wait(self.io);
        self.status = .completed;
    }

    fn poll(self: *Entry) !void {
        if (self.status != .running) return;
        const keep_polling = try self.poller.pollTimeout(0);
        try self.drain();
        if (!keep_polling) try self.finish();
    }

    fn wait(self: *Entry) !void {
        while (self.status == .running) {
            const keep_polling = try self.poller.poll();
            try self.drain();
            if (!keep_polling) try self.finish();
        }
    }

    fn cancel(self: *Entry) bool {
        if (self.status != .running) return false;
        var child = self.child orelse return false;
        self.child = null;
        child.kill(self.io);
        self.status = .cancelled;
        return true;
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
            .stdout_len = self.stdout.items.len,
            .stderr_len = self.stderr.items.len,
            .stdout_truncated = self.stdout_truncated,
            .stderr_truncated = self.stderr_truncated,
        };
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    next_id: JobId = 1,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *Manager, id: JobId) ?*Entry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn findConst(self: *const Manager, id: JobId) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    pub fn start(self: *Manager, argv: []const []const u8, options: Options) !JobId {
        const id = self.next_id;
        self.next_id += 1;

        var entry = try Entry.spawn(self.allocator, self.io, id, argv, options);
        errdefer entry.deinit();
        try self.entries.append(self.allocator, entry);
        return id;
    }

    pub fn poll(self: *Manager, id: JobId) !bool {
        const entry = self.find(id) orelse return error.UnknownJob;
        try entry.poll();
        return entry.status == .running;
    }

    pub fn pollAll(self: *Manager) !usize {
        var running: usize = 0;
        for (self.entries.items) |*entry| {
            try entry.poll();
            if (entry.status == .running) running += 1;
        }
        return running;
    }

    pub fn wait(self: *Manager, id: JobId) !void {
        const entry = self.find(id) orelse return error.UnknownJob;
        try entry.wait();
    }

    pub fn cancel(self: *Manager, id: JobId) !bool {
        const entry = self.find(id) orelse return error.UnknownJob;
        return entry.cancel();
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
        return entry.stdout.items;
    }

    pub fn stderr(self: *const Manager, id: JobId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        return entry.stderr.items;
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

test "job cancellation is stable and idempotent" {
    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "version" }, .{});
    try std.testing.expect(try manager.cancel(id));
    try std.testing.expectEqual(Status.cancelled, manager.status(id).?);
    try std.testing.expect(!(try manager.cancel(id)));
}
