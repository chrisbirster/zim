const std = @import("std");
const pty = @import("pty.zig");

pub const TerminalId = u64;

pub const Status = enum(u8) {
    running,
    exited,
    stopped,
    failed,
};

pub const Options = struct {
    dimensions: pty.Dimensions = .{},
    output_limit: usize = 1024 * 1024,
};

pub const Snapshot = struct {
    id: TerminalId,
    status: Status,
    dimensions: pty.Dimensions,
    output_len: usize,
    output_truncated: bool,
};

const Entry = struct {
    id: TerminalId,
    allocator: std.mem.Allocator,
    session: pty.Session,
    status_value: Status = .running,
    dimensions: pty.Dimensions,
    output_storage: []u8,
    output_len: usize = 0,
    output_truncated: bool = false,

    fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        id: TerminalId,
        argv: []const []const u8,
        options: Options,
    ) !*Entry {
        if (options.output_limit == 0) return error.InvalidOutputLimit;

        var session = try pty.Session.spawn(allocator, io, argv, .{ .dimensions = options.dimensions });
        errdefer session.deinit();
        const storage = try allocator.alloc(u8, options.output_limit);
        errdefer allocator.free(storage);
        const entry = try allocator.create(Entry);
        entry.* = .{
            .id = id,
            .allocator = allocator,
            .session = session,
            .dimensions = options.dimensions,
            .output_storage = storage,
        };
        return entry;
    }

    fn deinit(self: *Entry) void {
        self.session.deinit();
        self.allocator.free(self.output_storage);
        self.* = undefined;
    }

    fn appendOutput(self: *Entry, bytes: []const u8) void {
        const remaining = self.output_storage.len - self.output_len;
        const accepted = @min(remaining, bytes.len);
        if (accepted != 0) {
            @memcpy(self.output_storage[self.output_len..][0..accepted], bytes[0..accepted]);
            self.output_len += accepted;
        }
        if (accepted != bytes.len) self.output_truncated = true;
    }

    fn poll(self: *Entry) !bool {
        if (self.status_value != .running) return false;

        var changed = false;
        var scratch: [4096]u8 = undefined;
        var drains: usize = 0;
        while (drains < 64) : (drains += 1) {
            const n = self.session.readAvailable(&scratch) catch |err| {
                self.status_value = .failed;
                return err;
            };
            if (n == 0) break;
            self.appendOutput(scratch[0..n]);
            changed = true;
        }

        if (try self.session.exited()) {
            self.status_value = .exited;
            changed = true;
        }
        return changed;
    }

    fn wait(self: *Entry) !void {
        if (self.status_value != .running) return;

        var scratch: [4096]u8 = undefined;
        while (true) {
            const n = self.session.read(&scratch) catch |err| {
                self.status_value = .failed;
                return err;
            };
            if (n == 0) break;
            self.appendOutput(scratch[0..n]);
        }
        self.session.wait() catch |err| {
            self.status_value = .failed;
            return err;
        };
        self.status_value = .exited;
    }

    fn input(self: *Entry, bytes: []const u8) !void {
        if (self.status_value != .running) return error.TerminalNotRunning;
        try self.session.write(bytes);
    }

    fn resize(self: *Entry, dimensions: pty.Dimensions) !bool {
        if (self.status_value != .running) return false;
        if (self.dimensions.columns == dimensions.columns and self.dimensions.rows == dimensions.rows) return false;
        try self.session.resize(dimensions);
        self.dimensions = dimensions;
        return true;
    }

    fn stop(self: *Entry) !bool {
        if (self.status_value != .running) return false;
        try self.session.terminate();
        try self.session.wait();
        self.status_value = .stopped;
        return true;
    }

    fn snapshot(self: *const Entry) Snapshot {
        return .{
            .id = self.id,
            .status = self.status_value,
            .dimensions = self.dimensions,
            .output_len = self.output_len,
            .output_truncated = self.output_truncated,
        };
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    next_id: TerminalId = 1,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Manager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |entry| {
            entry.deinit();
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *Manager, id: TerminalId) ?*Entry {
        for (self.entries.items) |entry| if (entry.id == id) return entry;
        return null;
    }

    fn findConst(self: *const Manager, id: TerminalId) ?*const Entry {
        for (self.entries.items) |entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn supported() bool {
        return pty.Session.supported();
    }

    pub fn start(self: *Manager, argv: []const []const u8, options: Options) !TerminalId {
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

    pub fn poll(self: *Manager, id: TerminalId) !bool {
        const entry = self.find(id) orelse return error.UnknownTerminal;
        return entry.poll();
    }

    pub fn pollAll(self: *Manager) !bool {
        var changed = false;
        for (self.entries.items) |entry| {
            if (try entry.poll()) changed = true;
        }
        return changed;
    }

    pub fn wait(self: *Manager, id: TerminalId) !void {
        const entry = self.find(id) orelse return error.UnknownTerminal;
        try entry.wait();
    }

    pub fn input(self: *Manager, id: TerminalId, bytes: []const u8) !void {
        const entry = self.find(id) orelse return error.UnknownTerminal;
        try entry.input(bytes);
    }

    pub fn resize(self: *Manager, id: TerminalId, dimensions: pty.Dimensions) !bool {
        const entry = self.find(id) orelse return error.UnknownTerminal;
        return entry.resize(dimensions);
    }

    pub fn stop(self: *Manager, id: TerminalId) !bool {
        const entry = self.find(id) orelse return error.UnknownTerminal;
        return entry.stop();
    }

    pub fn snapshot(self: *const Manager, id: TerminalId) ?Snapshot {
        const entry = self.findConst(id) orelse return null;
        return entry.snapshot();
    }

    pub fn snapshotAt(self: *const Manager, index: usize) ?Snapshot {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index].snapshot();
    }

    pub fn output(self: *const Manager, id: TerminalId) ?[]const u8 {
        const entry = self.findConst(id) orelse return null;
        return entry.output_storage[0..entry.output_len];
    }

    pub fn count(self: *const Manager) usize {
        return self.entries.items.len;
    }
};

test "terminal manager owns PTY lifecycle and output" {
    if (!Manager.supported()) return error.SkipZigTest;

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "version" }, .{ .dimensions = .{ .columns = 100, .rows = 30 } });
    try std.testing.expectEqual(Status.running, manager.snapshot(id).?.status);
    try std.testing.expect(try manager.resize(id, .{ .columns = 120, .rows = 40 }));
    try manager.wait(id);

    const snap = manager.snapshot(id).?;
    try std.testing.expectEqual(Status.exited, snap.status);
    try std.testing.expectEqual(@as(u16, 120), snap.dimensions.columns);
    try std.testing.expectEqual(@as(u16, 40), snap.dimensions.rows);
    try std.testing.expect(std.mem.indexOf(u8, manager.output(id).?, "0.16") != null);
}

test "terminal output is bounded" {
    if (!Manager.supported()) return error.SkipZigTest;

    var manager = Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();

    const id = try manager.start(&.{ "zig", "version" }, .{ .output_limit = 4 });
    try manager.wait(id);
    const snap = manager.snapshot(id).?;
    try std.testing.expectEqual(@as(usize, 4), snap.output_len);
    try std.testing.expect(snap.output_truncated);
}
