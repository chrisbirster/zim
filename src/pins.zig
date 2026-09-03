const std = @import("std");

pub const PinId = u64;
const format_version: u32 = 1;
const max_file_bytes = 4 * 1024 * 1024;

pub const Entry = struct {
    id: PinId,
    path: []u8,
    line: usize,
    column: usize,
    label: ?[]u8 = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.label) |label| allocator.free(label);
        self.* = undefined;
    }
};

const PersistedEntry = struct {
    id: PinId,
    path: []const u8,
    line: usize,
    column: usize,
    label: ?[]const u8 = null,
};

const PersistedFile = struct {
    version: u32,
    next_id: PinId,
    pins: []const PersistedEntry,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    next_id: PinId = 1,
    revision: u64 = 0,
    root: ?[]u8 = null,
    storage_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Store) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        if (self.root) |root| self.allocator.free(root);
        if (self.storage_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn configure(self: *Store, config_root: []const u8, project_root: []const u8) !void {
        self.clearEntries();
        self.next_id = 1;
        if (self.root) |root| self.allocator.free(root);
        if (self.storage_path) |path| self.allocator.free(path);
        self.root = null;
        self.storage_path = null;

        const owned_root = try self.allocator.dupe(u8, project_root);
        errdefer self.allocator.free(owned_root);
        const sessions_root = try std.fmt.allocPrint(self.allocator, "{s}/sessions", .{config_root});
        defer self.allocator.free(sessions_root);
        try std.Io.Dir.cwd().createDirPath(self.io, sessions_root);
        const hash = std.hash.Wyhash.hash(0, project_root);
        const storage_path = try std.fmt.allocPrint(self.allocator, "{s}/{x}.pins.json", .{ sessions_root, hash });

        self.root = owned_root;
        self.storage_path = storage_path;
        try self.load();
        self.revision +%= 1;
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    pub fn entryAtSlot(self: *const Store, slot: usize) ?*const Entry {
        if (slot == 0 or slot > self.entries.items.len) return null;
        return &self.entries.items[slot - 1];
    }

    pub fn entryById(self: *const Store, id: PinId) ?*const Entry {
        for (self.entries.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn add(
        self: *Store,
        path: []const u8,
        line: usize,
        column: usize,
        label: ?[]const u8,
    ) !PinId {
        const stored_path = try self.storedPathAlloc(path);
        errdefer self.allocator.free(stored_path);
        const owned_label = if (label) |value| blk: {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, trimmed);
        } else null;
        errdefer if (owned_label) |value| self.allocator.free(value);

        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .path = stored_path,
            .line = @max(line, 1),
            .column = @max(column, 1),
            .label = owned_label,
        });
        errdefer {
            var removed = self.entries.pop().?;
            removed.deinit(self.allocator);
            self.next_id -= 1;
        }
        try self.save();
        self.revision +%= 1;
        return id;
    }

    pub fn removeSlot(self: *Store, slot: usize) !bool {
        if (slot == 0 or slot > self.entries.items.len) return false;
        const index = slot - 1;
        self.entries.items[index].deinit(self.allocator);
        var cursor = index + 1;
        while (cursor < self.entries.items.len) : (cursor += 1) {
            self.entries.items[cursor - 1] = self.entries.items[cursor];
        }
        self.entries.items.len -= 1;
        try self.save();
        self.revision +%= 1;
        return true;
    }

    pub fn moveSlot(self: *Store, from_slot: usize, to_slot: usize) !bool {
        if (from_slot == 0 or to_slot == 0 or from_slot > self.entries.items.len or to_slot > self.entries.items.len) return false;
        if (from_slot == to_slot) return true;
        const from = from_slot - 1;
        const to = to_slot - 1;
        const moving = self.entries.items[from];
        if (from < to) {
            var index = from;
            while (index < to) : (index += 1) self.entries.items[index] = self.entries.items[index + 1];
        } else {
            var index = from;
            while (index > to) : (index -= 1) self.entries.items[index] = self.entries.items[index - 1];
        }
        self.entries.items[to] = moving;
        try self.save();
        self.revision +%= 1;
        return true;
    }

    pub fn resolvePathAlloc(self: *const Store, entry: *const Entry) ![]u8 {
        if (std.fs.path.isAbsolute(entry.path)) return self.allocator.dupe(u8, entry.path);
        const root = self.root orelse return self.allocator.dupe(u8, entry.path);
        if (std.mem.eql(u8, root, ".")) return self.allocator.dupe(u8, entry.path);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, entry.path });
    }

    pub fn save(self: *Store) !void {
        const path = self.storage_path orelse return;
        const persisted = try self.allocator.alloc(PersistedEntry, self.entries.items.len);
        defer self.allocator.free(persisted);
        for (self.entries.items, persisted) |entry, *target| {
            target.* = .{
                .id = entry.id,
                .path = entry.path,
                .line = entry.line,
                .column = entry.column,
                .label = entry.label,
            };
        }
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, PersistedFile{
            .version = format_version,
            .next_id = self.next_id,
            .pins = persisted,
        }, .{});
        defer self.allocator.free(encoded);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, encoded);
        try file.writeStreamingAll(self.io, "\n");
    }

    fn load(self: *Store) !void {
        const path = self.storage_path orelse return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(PersistedFile, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value.version != format_version) return error.UnsupportedPinsFormat;

        self.clearEntries();
        self.next_id = @max(parsed.value.next_id, 1);
        var highest_id: PinId = 0;
        for (parsed.value.pins) |source| {
            if (source.id == 0 or source.path.len == 0 or source.line == 0 or source.column == 0) return error.InvalidPin;
            const owned_path = try self.allocator.dupe(u8, source.path);
            errdefer self.allocator.free(owned_path);
            const owned_label = if (source.label) |label| try self.allocator.dupe(u8, label) else null;
            errdefer if (owned_label) |label| self.allocator.free(label);
            try self.entries.append(self.allocator, .{
                .id = source.id,
                .path = owned_path,
                .line = source.line,
                .column = source.column,
                .label = owned_label,
            });
            highest_id = @max(highest_id, source.id);
        }
        if (self.next_id <= highest_id) self.next_id = highest_id + 1;
    }

    fn storedPathAlloc(self: *const Store, path: []const u8) ![]u8 {
        const root = self.root orelse return self.allocator.dupe(u8, path);
        if (std.mem.eql(u8, root, ".")) return self.allocator.dupe(u8, path);
        if (path.len > root.len and std.mem.startsWith(u8, path, root)) {
            const boundary = path[root.len];
            if (boundary == '/' or boundary == '\\') {
                return self.allocator.dupe(u8, path[root.len + 1 ..]);
            }
        }
        return self.allocator.dupe(u8, path);
    }

    fn clearEntries(self: *Store) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.items.len = 0;
    }
};

test "Pins persist project-relative paths stable IDs labels and ordering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config");
    try tmp.dir.createDirPath(io, "project/src");

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const config_root = try std.fmt.allocPrint(allocator, "{s}/config", .{root});
    defer allocator.free(config_root);
    const project_root = try std.fmt.allocPrint(allocator, "{s}/project", .{root});
    defer allocator.free(project_root);
    const first_path = try std.fmt.allocPrint(allocator, "{s}/src/first.zig", .{project_root});
    defer allocator.free(first_path);
    const second_path = try std.fmt.allocPrint(allocator, "{s}/src/second.zig", .{project_root});
    defer allocator.free(second_path);

    var store = Store.init(allocator, io);
    try store.configure(config_root, project_root);
    const first = try store.add(first_path, 4, 2, "core");
    const second = try store.add(second_path, 9, 1, null);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expect(try store.moveSlot(2, 1));
    store.deinit();

    var restored = Store.init(allocator, io);
    defer restored.deinit();
    try restored.configure(config_root, project_root);
    try std.testing.expectEqual(@as(usize, 2), restored.count());
    try std.testing.expectEqual(second, restored.entryAtSlot(1).?.id);
    try std.testing.expectEqualStrings("src/second.zig", restored.entryAtSlot(1).?.path);
    try std.testing.expectEqualStrings("core", restored.entryAtSlot(2).?.label.?);
    const resolved = try restored.resolvePathAlloc(restored.entryAtSlot(2).?);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(first_path, resolved);
    try std.testing.expect(try restored.removeSlot(1));
    try std.testing.expectEqual(@as(usize, 1), restored.count());
}
