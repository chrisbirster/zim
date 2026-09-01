const std = @import("std");
const language = @import("language");
const buffer_module = @import("buffer.zig");

pub const HighlightSpan = language.HighlightSpan;
pub const Symbol = language.Symbol;
pub const FoldRange = language.FoldRange;
pub const StructuralKind = language.StructuralObjectKind;
pub const ObjectScope = language.ObjectScope;
pub const MotionDirection = language.MotionDirection;

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

const Cache = struct {
    buffer_id: buffer_module.BufferId,
    revision: u64,
    language_id: []const u8,
    highlights: language.HighlightList,
    folds: language.FoldList,
    symbols: language.SymbolList,

    fn deinit(self: *Cache) void {
        self.highlights.deinit();
        self.folds.deinit();
        self.symbols.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    service: language.Service,
    caches: std.ArrayList(Cache) = .empty,

    pub fn init(allocator: std.mem.Allocator) !State {
        return .{
            .allocator = allocator,
            .service = try language.Service.initDefault(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        for (self.caches.items) |*cache| cache.deinit();
        self.caches.deinit(self.allocator);
        self.service.deinit();
        self.* = undefined;
    }

    pub fn syncBuffer(self: *State, buffer: *const buffer_module.Buffer, force: bool) !void {
        const language_id = self.languageForPath(buffer.path) orelse {
            _ = self.service.close(@intCast(buffer.id));
            self.removeCache(buffer.id);
            return;
        };
        const cache_index = self.cacheIndex(buffer.id);
        if (!force) {
            if (cache_index) |index| {
                const cache = &self.caches.items[index];
                if (cache.revision == buffer.revision and std.mem.eql(u8, cache.language_id, language_id)) return;
            }
        }

        const service_id: language.BufferId = @intCast(buffer.id);
        const service_revision = self.service.revision(service_id);
        const cache_language_matches = if (cache_index) |index|
            std.mem.eql(u8, self.caches.items[index].language_id, language_id)
        else
            false;

        if (force or !cache_language_matches or service_revision == null or buffer.revision <= service_revision.?) {
            _ = try self.service.open(service_id, buffer.text.items, buffer.revision, language_id);
        } else {
            var changed = try self.service.sync(self.allocator, service_id, buffer.text.items, buffer.revision);
            changed.deinit();
        }
        try self.refreshCache(buffer.id, buffer.revision, language_id);
    }

    pub fn revision(self: *const State, buffer_id: buffer_module.BufferId) ?u64 {
        const index = self.cacheIndex(buffer_id) orelse return null;
        return self.caches.items[index].revision;
    }

    pub fn highlights(self: *const State, buffer_id: buffer_module.BufferId) []const HighlightSpan {
        const index = self.cacheIndex(buffer_id) orelse return &[_]HighlightSpan{};
        return self.caches.items[index].highlights.items;
    }

    pub fn folds(self: *const State, buffer_id: buffer_module.BufferId) []const FoldRange {
        const index = self.cacheIndex(buffer_id) orelse return &[_]FoldRange{};
        return self.caches.items[index].folds.items;
    }

    pub fn symbols(self: *const State, buffer_id: buffer_module.BufferId) []const Symbol {
        const index = self.cacheIndex(buffer_id) orelse return &[_]Symbol{};
        return self.caches.items[index].symbols.items;
    }

    pub fn textObject(
        self: *const State,
        buffer_id: buffer_module.BufferId,
        kind: StructuralKind,
        scope: ObjectScope,
        cursor: usize,
        count: usize,
    ) !?ByteRange {
        if (self.cacheIndex(buffer_id) == null) return null;
        var objects = try self.service.textObjects(self.allocator, @intCast(buffer_id), kind, scope);
        defer objects.deinit();
        if (objects.items.len == 0) return null;

        var selected: ?usize = null;
        var selected_len: u32 = std.math.maxInt(u32);
        for (objects.items, 0..) |object, index| {
            const start: usize = @intCast(object.range.start_byte);
            const end: usize = @intCast(object.range.end_byte);
            if (start <= cursor and cursor < end and object.range.len() <= selected_len) {
                selected = index;
                selected_len = object.range.len();
            }
        }
        const first_index = selected orelse return null;
        var result = ByteRange{
            .start = @intCast(objects.items[first_index].range.start_byte),
            .end = @intCast(objects.items[first_index].range.end_byte),
        };
        var remaining = if (count == 0) 0 else count - 1;
        while (remaining > 0) : (remaining -= 1) {
            var next_index: ?usize = null;
            var next_start: u32 = std.math.maxInt(u32);
            for (objects.items, 0..) |object, index| {
                if (object.range.start_byte < result.end) continue;
                if (object.range.start_byte < next_start) {
                    next_start = object.range.start_byte;
                    next_index = index;
                }
            }
            const index = next_index orelse break;
            result.end = @intCast(objects.items[index].range.end_byte);
        }
        return result;
    }

    pub fn structuralMotion(
        self: *const State,
        buffer_id: buffer_module.BufferId,
        kind: StructuralKind,
        direction: MotionDirection,
        cursor: usize,
        count: usize,
    ) !?usize {
        if (self.cacheIndex(buffer_id) == null) return null;
        var from: u32 = @intCast(@min(cursor, std.math.maxInt(u32)));
        var destination: ?usize = null;
        const repetitions = if (count == 0) 1 else count;
        for (0..repetitions) |_| {
            const range = try self.service.structuralMotion(self.allocator, @intCast(buffer_id), kind, direction, from) orelse break;
            destination = @intCast(range.start_byte);
            from = range.start_byte;
        }
        return destination;
    }

    fn refreshCache(self: *State, buffer_id: buffer_module.BufferId, revision_value: u64, language_id: []const u8) !void {
        const service_id: language.BufferId = @intCast(buffer_id);
        var highlights_value = try self.service.highlights(self.allocator, service_id);
        errdefer highlights_value.deinit();
        var folds_value = try self.service.folds(self.allocator, service_id);
        errdefer folds_value.deinit();
        var symbols_value = try self.service.symbols(self.allocator, service_id);
        errdefer symbols_value.deinit();

        const replacement = Cache{
            .buffer_id = buffer_id,
            .revision = revision_value,
            .language_id = language_id,
            .highlights = highlights_value,
            .folds = folds_value,
            .symbols = symbols_value,
        };
        if (self.cacheIndex(buffer_id)) |index| {
            self.caches.items[index].deinit();
            self.caches.items[index] = replacement;
        } else {
            try self.caches.append(self.allocator, replacement);
        }
    }

    fn removeCache(self: *State, buffer_id: buffer_module.BufferId) void {
        const index = self.cacheIndex(buffer_id) orelse return;
        var removed = self.caches.swapRemove(index);
        removed.deinit();
    }

    fn cacheIndex(self: *const State, buffer_id: buffer_module.BufferId) ?usize {
        for (self.caches.items, 0..) |cache, index| {
            if (cache.buffer_id == buffer_id) return index;
        }
        return null;
    }

    fn languageForPath(self: *const State, maybe_path: ?[]const u8) ?[]const u8 {
        const path = maybe_path orelse return null;
        const extension = extensionOf(path);
        if (extension.len == 0) return null;
        const spec = self.service.registry.findByExtension(extension) orelse return null;
        return spec.id;
    }
};

fn extensionOf(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    if (slash) |index| if (dot < index) return "";
    if (dot + 1 >= path.len) return "";
    return path[dot + 1 ..];
}

test "bridge syncs revisions and caches structural language data" {
    var buffer = try buffer_module.Buffer.init(std.testing.allocator, 1, "demo.zig");
    defer buffer.deinit(std.testing.allocator);
    try buffer.setLoadedText(std.testing.allocator,
        \\const std = @import("std");
        \\fn alpha() i32 {
        \\    return 1;
        \\}
        \\fn beta(value: i32) i32 {
        \\    return value + 1;
        \\}
    );

    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    try state.syncBuffer(&buffer, true);
    try std.testing.expect(state.highlights(buffer.id).len > 0);
    try std.testing.expect(state.symbols(buffer.id).len >= 2);
    try std.testing.expect(state.folds(buffer.id).len > 0);

    const inside_alpha = std.mem.indexOf(u8, buffer.text.items, "return 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect((try state.textObject(buffer.id, .function, .inner, inside_alpha, 1)) != null);
    try std.testing.expect((try state.structuralMotion(buffer.id, .function, .next, 0, 1)) != null);

    try buffer.text.appendSlice(std.testing.allocator, "\n");
    buffer.markChanged();
    try state.syncBuffer(&buffer, false);
    try std.testing.expectEqual(buffer.revision, state.revision(buffer.id).?);
}
