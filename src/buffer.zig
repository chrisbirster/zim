const std = @import("std");

pub const BufferId = u32;

pub const LoadResult = enum {
    loaded,
    new_file,
    directory,
};

pub const RegisterKind = enum {
    characterwise,
    linewise,
    blockwise,
};

const journal_magic = "ZIMUNDO1";
const max_file_bytes: usize = 64 * 1024 * 1024;
const max_undo_entries: usize = 256;

pub const Snapshot = struct {
    text: []u8,
    cursor: usize,
    state_id: u64,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Buffer = struct {
    id: BufferId,
    path: ?[]u8 = null,
    text: std.ArrayList(u8) = .empty,
    modified: bool = false,
    revision: u64 = 0,
    state_id: u64 = 1,
    saved_state_id: u64 = 1,
    next_state_id: u64 = 2,
    undo: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        id: BufferId,
        path: ?[]const u8,
    ) !Buffer {
        return .{
            .id = id,
            .path = if (path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.text.deinit(allocator);
        freeSnapshots(&self.undo, allocator);
        self.undo.deinit(allocator);
        freeSnapshots(&self.redo, allocator);
        self.redo.deinit(allocator);
        self.* = undefined;
    }

    pub fn setPath(self: *Buffer, allocator: std.mem.Allocator, path: ?[]const u8) !void {
        const replacement = if (path) |value| try allocator.dupe(u8, value) else null;
        if (self.path) |old| allocator.free(old);
        self.path = replacement;
    }

    pub fn setLoadedText(self: *Buffer, allocator: std.mem.Allocator, value: []const u8) !void {
        self.text.items.len = 0;
        try self.text.appendSlice(allocator, value);
        self.modified = false;
        self.revision = 0;
        self.state_id = 1;
        self.saved_state_id = 1;
        self.next_state_id = 2;
        freeSnapshots(&self.undo, allocator);
        freeSnapshots(&self.redo, allocator);
    }

    pub fn loadFromDisk(
        self: *Buffer,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !LoadResult {
        const path = self.path orelse return .new_file;
        const contents = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return .new_file,
            error.IsDir => return .directory,
            else => return err,
        };
        defer allocator.free(contents);
        try self.setLoadedText(allocator, contents);
        try self.loadUndoJournal(io, allocator);
        return .loaded;
    }

    pub fn writeToDisk(
        self: *Buffer,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        const path = self.path orelse return error.NoFileName;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .permissions = .default_file,
            .make_path = false,
            .replace = true,
        });
        defer atomic.deinit(io);

        var write_buffer: [4096]u8 = undefined;
        var file_writer = atomic.file.writer(io, &write_buffer);
        try file_writer.interface.writeAll(self.text.items);
        try file_writer.interface.flush();
        try atomic.replace(io);

        self.saved_state_id = self.state_id;
        self.modified = false;
        try self.persistUndoJournal(io, allocator);
    }

    pub fn recordUndo(self: *Buffer, allocator: std.mem.Allocator, cursor: usize) !void {
        if (self.undo.items.len >= max_undo_entries) {
            var oldest = self.undo.items[0];
            oldest.deinit(allocator);
            std.mem.copyForwards(
                Snapshot,
                self.undo.items[0 .. self.undo.items.len - 1],
                self.undo.items[1..],
            );
            self.undo.items.len -= 1;
        }
        try self.undo.append(allocator, try self.snapshot(allocator, cursor));
        freeSnapshots(&self.redo, allocator);
    }

    pub fn markChanged(self: *Buffer) void {
        self.revision += 1;
        self.state_id = self.next_state_id;
        self.next_state_id += 1;
        self.modified = self.state_id != self.saved_state_id;
    }

    pub fn undoOne(
        self: *Buffer,
        allocator: std.mem.Allocator,
        cursor: usize,
    ) !?usize {
        if (self.undo.items.len == 0) return null;
        try self.redo.append(allocator, try self.snapshot(allocator, cursor));
        var previous = self.undo.items[self.undo.items.len - 1];
        self.undo.items.len -= 1;
        defer previous.deinit(allocator);
        try self.restoreSnapshot(allocator, previous);
        self.revision += 1;
        self.modified = self.state_id != self.saved_state_id;
        return @min(previous.cursor, self.text.items.len);
    }

    pub fn redoOne(
        self: *Buffer,
        allocator: std.mem.Allocator,
        cursor: usize,
    ) !?usize {
        if (self.redo.items.len == 0) return null;
        try self.undo.append(allocator, try self.snapshot(allocator, cursor));
        var next = self.redo.items[self.redo.items.len - 1];
        self.redo.items.len -= 1;
        defer next.deinit(allocator);
        try self.restoreSnapshot(allocator, next);
        self.revision += 1;
        self.modified = self.state_id != self.saved_state_id;
        return @min(next.cursor, self.text.items.len);
    }

    pub fn encodeUndoJournal(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try bytes.appendSlice(allocator, journal_magic);
        try appendU64(&bytes, allocator, std.hash.Wyhash.hash(0, self.text.items));
        try appendU64(&bytes, allocator, self.undo.items.len);
        for (self.undo.items) |entry| {
            try appendU64(&bytes, allocator, entry.state_id);
            try appendU64(&bytes, allocator, entry.cursor);
            try appendU64(&bytes, allocator, entry.text.len);
            try bytes.appendSlice(allocator, entry.text);
        }
        return bytes.toOwnedSlice(allocator);
    }

    pub fn restoreUndoJournal(
        self: *Buffer,
        allocator: std.mem.Allocator,
        encoded: []const u8,
    ) !bool {
        if (encoded.len < journal_magic.len + 16) return false;
        if (!std.mem.eql(u8, encoded[0..journal_magic.len], journal_magic)) return false;
        var index = journal_magic.len;
        const expected_hash = readU64(encoded, &index) orelse return false;
        if (expected_hash != std.hash.Wyhash.hash(0, self.text.items)) return false;
        const entry_count = readU64(encoded, &index) orelse return false;
        if (entry_count > max_undo_entries) return false;

        var rebuilt: std.ArrayList(Snapshot) = .empty;
        var keep_rebuilt = false;
        defer if (!keep_rebuilt) {
            freeSnapshots(&rebuilt, allocator);
            rebuilt.deinit(allocator);
        };
        var max_state: u64 = 1;
        var entry_index: u64 = 0;
        while (entry_index < entry_count) : (entry_index += 1) {
            const state_id = readU64(encoded, &index) orelse return false;
            const cursor_u64 = readU64(encoded, &index) orelse return false;
            const len_u64 = readU64(encoded, &index) orelse return false;
            const len = std.math.cast(usize, len_u64) orelse return false;
            const cursor = std.math.cast(usize, cursor_u64) orelse return false;
            if (index + len > encoded.len) return false;
            const text = try allocator.dupe(u8, encoded[index .. index + len]);
            index += len;
            try rebuilt.append(allocator, .{
                .text = text,
                .cursor = @min(cursor, len),
                .state_id = state_id,
            });
            max_state = @max(max_state, state_id);
        }
        if (index != encoded.len) return false;

        freeSnapshots(&self.undo, allocator);
        self.undo.deinit(allocator);
        self.undo = rebuilt;
        keep_rebuilt = true;
        freeSnapshots(&self.redo, allocator);
        self.state_id = max_state + 1;
        self.saved_state_id = self.state_id;
        self.next_state_id = self.state_id + 1;
        self.modified = false;
        return true;
    }

    fn persistUndoJournal(
        self: *const Buffer,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        const path = self.path orelse return;
        const undo_path = try undoSidecarPath(allocator, path);
        defer allocator.free(undo_path);
        const encoded = try self.encodeUndoJournal(allocator);
        defer allocator.free(encoded);

        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, undo_path, .{
            .permissions = .default_file,
            .make_path = false,
            .replace = true,
        });
        defer atomic.deinit(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
        try atomic.replace(io);
    }

    fn loadUndoJournal(
        self: *Buffer,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !void {
        const path = self.path orelse return;
        const undo_path = try undoSidecarPath(allocator, path);
        defer allocator.free(undo_path);
        const encoded = std.Io.Dir.cwd().readFileAlloc(
            io,
            undo_path,
            allocator,
            .limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer allocator.free(encoded);
        _ = try self.restoreUndoJournal(allocator, encoded);
    }

    fn snapshot(self: *const Buffer, allocator: std.mem.Allocator, cursor: usize) !Snapshot {
        return .{
            .text = try allocator.dupe(u8, self.text.items),
            .cursor = @min(cursor, self.text.items.len),
            .state_id = self.state_id,
        };
    }

    fn restoreSnapshot(self: *Buffer, allocator: std.mem.Allocator, entry: Snapshot) !void {
        self.text.items.len = 0;
        try self.text.appendSlice(allocator, entry.text);
        self.state_id = entry.state_id;
        self.next_state_id = @max(self.next_state_id, entry.state_id + 1);
    }
};

fn freeSnapshots(list: *std.ArrayList(Snapshot), allocator: std.mem.Allocator) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.items.len = 0;
}

fn undoSidecarPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const suffix = ".zimundo";
    const result = try allocator.alloc(u8, path.len + suffix.len);
    @memcpy(result[0..path.len], path);
    @memcpy(result[path.len..], suffix);
    return result;
}

fn appendU64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    var remaining = value;
    for (0..8) |index| {
        bytes[index] = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
    try list.appendSlice(allocator, &bytes);
}

fn readU64(bytes: []const u8, index: *usize) ?u64 {
    if (index.* + 8 > bytes.len) return null;
    var value: u64 = 0;
    for (0..8) |offset| {
        value |= @as(u64, bytes[index.* + offset]) << @intCast(offset * 8);
    }
    index.* += 8;
    return value;
}

test "buffer undo and redo restore content states" {
    var buffer = try Buffer.init(std.testing.allocator, 1, null);
    defer buffer.deinit(std.testing.allocator);
    try buffer.setLoadedText(std.testing.allocator, "one");
    try buffer.recordUndo(std.testing.allocator, 3);
    try buffer.text.appendSlice(std.testing.allocator, " two");
    buffer.markChanged();
    try std.testing.expect(buffer.modified);

    const undo_cursor = (try buffer.undoOne(std.testing.allocator, 7)).?;
    try std.testing.expectEqualStrings("one", buffer.text.items);
    try std.testing.expectEqual(@as(usize, 3), undo_cursor);

    const redo_cursor = (try buffer.redoOne(std.testing.allocator, undo_cursor)).?;
    try std.testing.expectEqualStrings("one two", buffer.text.items);
    try std.testing.expectEqual(@as(usize, 7), redo_cursor);
}

test "undo journal round trips only when saved content hash matches" {
    var source = try Buffer.init(std.testing.allocator, 1, null);
    defer source.deinit(std.testing.allocator);
    try source.setLoadedText(std.testing.allocator, "saved");
    try source.recordUndo(std.testing.allocator, 2);
    source.undo.items[0].state_id = 41;

    const encoded = try source.encodeUndoJournal(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    var target = try Buffer.init(std.testing.allocator, 2, null);
    defer target.deinit(std.testing.allocator);
    try target.setLoadedText(std.testing.allocator, "saved");
    try std.testing.expect(try target.restoreUndoJournal(std.testing.allocator, encoded));
    try std.testing.expectEqual(@as(usize, 1), target.undo.items.len);
    try std.testing.expectEqual(@as(u64, 42), target.state_id);

    try target.setLoadedText(std.testing.allocator, "changed externally");
    try std.testing.expect(!(try target.restoreUndoJournal(std.testing.allocator, encoded)));
}
