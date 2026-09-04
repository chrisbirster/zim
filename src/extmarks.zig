const std = @import("std");

pub const NamespaceId = u32;
pub const ExtmarkId = u64;

pub const Gravity = enum {
    left,
    right,
};

pub const DiagnosticSeverity = enum {
    error_level,
    warning,
    information,
    hint,
};

pub const Options = struct {
    end: ?usize = null,
    right_gravity: Gravity = .right,
    end_right_gravity: Gravity = .left,
    highlight: ?[]const u8 = null,
    sign: ?[]const u8 = null,
    virtual_text: ?[]const u8 = null,
    diagnostic_message: ?[]const u8 = null,
    diagnostic_severity: ?DiagnosticSeverity = null,
};

pub const Diagnostic = struct {
    start: usize,
    end: usize,
    severity: DiagnosticSeverity,
    message: []const u8,
};

pub const Namespace = struct {
    id: NamespaceId,
    name: []u8,

    fn deinit(self: *Namespace, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Namespace) = .empty,
    next_id: NamespaceId = 1,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *Registry, name: []const u8) !NamespaceId {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.id;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{ .id = id, .name = owned });
        self.revision += 1;
        return id;
    }

    pub fn contains(self: *const Registry, id: NamespaceId) bool {
        for (self.entries.items) |entry| if (entry.id == id) return true;
        return false;
    }

    pub fn name(self: *const Registry, id: NamespaceId) ?[]const u8 {
        for (self.entries.items) |entry| if (entry.id == id) return entry.name;
        return null;
    }

    pub fn delete(self: *Registry, id: NamespaceId) bool {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id != id) continue;
            entry.deinit(self.allocator);
            var cursor = index + 1;
            while (cursor < self.entries.items.len) : (cursor += 1) self.entries.items[cursor - 1] = self.entries.items[cursor];
            self.entries.items.len -= 1;
            self.revision += 1;
            return true;
        }
        return false;
    }
};

pub const Mark = struct {
    id: ExtmarkId,
    namespace_id: NamespaceId,
    start: usize,
    end: usize,
    right_gravity: Gravity,
    end_right_gravity: Gravity,
    highlight: ?[]u8 = null,
    sign: ?[]u8 = null,
    virtual_text: ?[]u8 = null,
    diagnostic_message: ?[]u8 = null,
    diagnostic_severity: ?DiagnosticSeverity = null,

    fn deinit(self: *Mark, allocator: std.mem.Allocator) void {
        if (self.highlight) |value| allocator.free(value);
        if (self.sign) |value| allocator.free(value);
        if (self.virtual_text) |value| allocator.free(value);
        if (self.diagnostic_message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    marks: std.ArrayList(Mark) = .empty,
    next_id: ExtmarkId = 1,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.marks.items) |*mark| mark.deinit(self.allocator);
        self.marks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn set(self: *Store, namespace_id: NamespaceId, start: usize, options: Options) !ExtmarkId {
        const id = self.next_id;
        self.next_id += 1;
        const finish = @max(start, options.end orelse start);
        var mark = Mark{
            .id = id,
            .namespace_id = namespace_id,
            .start = start,
            .end = finish,
            .right_gravity = options.right_gravity,
            .end_right_gravity = options.end_right_gravity,
            .highlight = try dupeOptional(self.allocator, options.highlight),
            .sign = try dupeOptional(self.allocator, options.sign),
            .virtual_text = try dupeOptional(self.allocator, options.virtual_text),
            .diagnostic_message = try dupeOptional(self.allocator, options.diagnostic_message),
            .diagnostic_severity = options.diagnostic_severity,
        };
        errdefer mark.deinit(self.allocator);
        try self.marks.append(self.allocator, mark);
        self.revision += 1;
        return id;
    }

    pub fn remove(self: *Store, namespace_id: NamespaceId, id: ExtmarkId) bool {
        for (self.marks.items, 0..) |*mark, index| {
            if (mark.namespace_id != namespace_id or mark.id != id) continue;
            mark.deinit(self.allocator);
            var cursor = index + 1;
            while (cursor < self.marks.items.len) : (cursor += 1) self.marks.items[cursor - 1] = self.marks.items[cursor];
            self.marks.items.len -= 1;
            self.revision += 1;
            return true;
        }
        return false;
    }

    pub fn clearNamespace(self: *Store, namespace_id: NamespaceId) bool {
        var write: usize = 0;
        var removed = false;
        for (self.marks.items) |*mark| {
            if (mark.namespace_id == namespace_id) {
                mark.deinit(self.allocator);
                removed = true;
                continue;
            }
            if (write != @intFromPtr(mark)) {}
            self.marks.items[write] = mark.*;
            write += 1;
        }
        self.marks.items.len = write;
        if (removed) self.revision += 1;
        return removed;
    }

    pub fn items(self: *const Store) []const Mark {
        return self.marks.items;
    }

    pub fn mark(self: *const Store, namespace_id: NamespaceId, id: ExtmarkId) ?*const Mark {
        for (self.marks.items) |*entry| {
            if (entry.namespace_id == namespace_id and entry.id == id) return entry;
        }
        return null;
    }

    pub fn applyEdit(self: *Store, start: usize, old_end: usize, new_len: usize) void {
        const normalized_end = @max(start, old_end);
        if (normalized_end == start and new_len == 0) return;
        for (self.marks.items) |*mark| {
            mark.start = transformPoint(mark.start, start, normalized_end, new_len, mark.right_gravity);
            mark.end = transformPoint(mark.end, start, normalized_end, new_len, mark.end_right_gravity);
            if (mark.end < mark.start) mark.end = mark.start;
        }
        self.revision += 1;
    }

    pub fn applyTextReplacement(self: *Store, before: []const u8, after: []const u8) void {
        if (std.mem.eql(u8, before, after)) return;
        var prefix: usize = 0;
        const common_max = @min(before.len, after.len);
        while (prefix < common_max and before[prefix] == after[prefix]) : (prefix += 1) {}

        var suffix: usize = 0;
        while (suffix < before.len - prefix and suffix < after.len - prefix and
            before[before.len - suffix - 1] == after[after.len - suffix - 1]) : (suffix += 1)
        {}

        self.applyEdit(prefix, before.len - suffix, after.len - prefix - suffix);
    }

    pub fn publishDiagnostics(self: *Store, namespace_id: NamespaceId, diagnostics: []const Diagnostic) !void {
        _ = self.clearNamespace(namespace_id);
        for (diagnostics) |diagnostic| {
            _ = try self.set(namespace_id, diagnostic.start, .{
                .end = diagnostic.end,
                .right_gravity = .left,
                .end_right_gravity = .right,
                .highlight = diagnosticHighlight(diagnostic.severity),
                .sign = diagnosticSign(diagnostic.severity),
                .virtual_text = diagnostic.message,
                .diagnostic_message = diagnostic.message,
                .diagnostic_severity = diagnostic.severity,
            });
        }
    }

    pub fn diagnosticCount(self: *const Store) usize {
        var count: usize = 0;
        for (self.marks.items) |mark| if (mark.diagnostic_message != null) count += 1;
        return count;
    }
};

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn transformPoint(position: usize, start: usize, old_end: usize, new_len: usize, gravity: Gravity) usize {
    const old_len = old_end - start;
    if (old_len == 0) {
        if (position < start) return position;
        if (position > start) return position + new_len;
        return if (gravity == .right) start + new_len else start;
    }

    if (position < start) return position;
    if (position > old_end) return shifted(position, old_len, new_len);
    if (position == old_end) return start + new_len;
    if (position == start) return start;
    return if (gravity == .right) start + new_len else start;
}

fn shifted(position: usize, old_len: usize, new_len: usize) usize {
    if (new_len >= old_len) return position + (new_len - old_len);
    return position - @min(position, old_len - new_len);
}

fn diagnosticHighlight(severity: DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .error_level => "DiagnosticError",
        .warning => "DiagnosticWarn",
        .information => "DiagnosticInfo",
        .hint => "DiagnosticHint",
    };
}

fn diagnosticSign(severity: DiagnosticSeverity) []const u8 {
    return switch (severity) {
        .error_level => "E",
        .warning => "W",
        .information => "I",
        .hint => "H",
    };
}

test "extmarks track insertions with gravity and ranges" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const left_id = try store.set(1, 3, .{ .right_gravity = .left });
    const right_id = try store.set(1, 3, .{ .right_gravity = .right });
    const range_id = try store.set(1, 1, .{ .end = 5, .right_gravity = .left, .end_right_gravity = .right });
    store.applyEdit(3, 3, 2);

    try std.testing.expectEqual(@as(usize, 3), store.mark(1, left_id).?.start);
    try std.testing.expectEqual(@as(usize, 5), store.mark(1, right_id).?.start);
    try std.testing.expectEqual(@as(usize, 1), store.mark(1, range_id).?.start);
    try std.testing.expectEqual(@as(usize, 7), store.mark(1, range_id).?.end);
}

test "extmarks survive replacement and diagnostics share the primitive" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const id = try store.set(7, 6, .{ .virtual_text = "note" });
    store.applyTextReplacement("hello world", "hello brave world");
    try std.testing.expectEqual(@as(usize, 12), store.mark(7, id).?.start);

    try store.publishDiagnostics(9, &.{.{
        .start = 0,
        .end = 5,
        .severity = .warning,
        .message = "demo warning",
    }});
    try std.testing.expectEqual(@as(usize, 1), store.diagnosticCount());
    try std.testing.expectEqualStrings("W", store.items()[1].sign.?);
}
