const std = @import("std");
const ts = @import("tree-sitter");
const query_sources = @import("queries.zig");

pub const LanguageFactory = *const fn () callconv(.c) *const ts.Language;

pub const LanguageSpec = struct {
    id: []const u8,
    display_name: []const u8,
    extensions: []const []const u8,
    factory: LanguageFactory,
    queries: query_sources.Sources,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    languages: std.ArrayList(LanguageSpec) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Registry {
        var registry = init(allocator);
        errdefer registry.deinit();
        try registry.register(zigSpec());
        return registry;
    }

    pub fn deinit(self: *Registry) void {
        self.languages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, spec: LanguageSpec) !void {
        if (self.findIndex(spec.id) != null) return error.DuplicateLanguage;
        try self.languages.append(self.allocator, spec);
    }

    pub fn findIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.languages.items, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.id, id)) return index;
        }
        return null;
    }

    pub fn find(self: *const Registry, id: []const u8) ?LanguageSpec {
        const index = self.findIndex(id) orelse return null;
        return self.languages.items[index];
    }

    pub fn findByExtension(self: *const Registry, extension: []const u8) ?LanguageSpec {
        const normalized = if (extension.len > 0 and extension[0] == '.') extension[1..] else extension;
        for (self.languages.items) |spec| {
            for (spec.extensions) |candidate| {
                if (std.mem.eql(u8, candidate, normalized)) return spec;
            }
        }
        return null;
    }

    pub fn querySource(self: *const Registry, language_id: []const u8, kind: query_sources.Kind) ?[]const u8 {
        const spec = self.find(language_id) orelse return null;
        return spec.queries.get(kind);
    }
};

const zig_extensions = [_][]const u8{"zig"};

fn zigSpec() LanguageSpec {
    return .{
        .id = "zig",
        .display_name = "Zig",
        .extensions = &zig_extensions,
        .factory = tree_sitter_zig,
        .queries = query_sources.zig,
    };
}

extern fn tree_sitter_zig() callconv(.c) *const ts.Language;

test "default registry resolves Zig metadata and queries" {
    var registry = try Registry.initDefault(std.testing.allocator);
    defer registry.deinit();

    const zig = registry.find("zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Zig", zig.display_name);
    try std.testing.expect(registry.findByExtension(".zig") != null);
    const highlights = registry.querySource("zig", .highlights) orelse return error.TestUnexpectedResult;
    try std.testing.expect(highlights.len > 0);
}
