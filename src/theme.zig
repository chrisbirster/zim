const std = @import("std");

pub const Style = struct {
    foreground: ?u8 = null,
    background: ?u8 = null,
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    underline: bool = false,
};

pub const Entry = struct {
    name: []u8,
    style: Style,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    name: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.name.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn load(self: *Store, scheme: []const u8) !void {
        self.clear();
        self.name.items.len = 0;
        if (std.mem.eql(u8, scheme, "zim")) {
            try self.loadZim();
        } else if (std.mem.eql(u8, scheme, "mono")) {
            try self.loadMono();
        } else if (std.mem.eql(u8, scheme, "ember")) {
            try self.loadEmber();
        } else return error.UnknownColorscheme;
        try self.name.appendSlice(self.allocator, scheme);
        self.revision +%= 1;
    }

    pub fn set(self: *Store, name: []const u8, style: Style) !void {
        if (!validGroup(name)) return error.InvalidHighlightGroup;
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.style = style;
                self.revision +%= 1;
                return;
            }
        }
        try self.entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .style = style,
        });
        self.revision +%= 1;
    }

    pub fn get(self: *const Store, name: []const u8) ?Style {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.style;
        }
        return null;
    }

    pub fn scheme(self: *const Store) []const u8 {
        return self.name.items;
    }

    fn clear(self: *Store) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.items.len = 0;
    }

    fn loadZim(self: *Store) !void {
        try self.set("LineNr", .{ .foreground = 8, .dim = true });
        try self.set("CursorLineNr", .{ .foreground = 13, .bold = true });
        try self.set("Comment", .{ .foreground = 8, .italic = true });
        try self.set("String", .{ .foreground = 10 });
        try self.set("Keyword", .{ .foreground = 13, .bold = true });
        try self.set("Function", .{ .foreground = 14 });
        try self.set("Type", .{ .foreground = 12 });
        try self.set("Number", .{ .foreground = 11 });
        try self.set("Operator", .{ .foreground = 6 });
        try self.set("DiagnosticError", .{ .foreground = 9, .bold = true });
        try self.set("DiagnosticWarn", .{ .foreground = 11, .bold = true });
        try self.set("DiagnosticInfo", .{ .foreground = 14 });
        try self.set("DiagnosticHint", .{ .foreground = 8, .italic = true });
        try self.set("VirtualText", .{ .foreground = 8, .italic = true, .dim = true });
        try self.set("PluginAccent", .{ .foreground = 13 });
    }

    fn loadMono(self: *Store) !void {
        try self.set("LineNr", .{ .dim = true });
        try self.set("CursorLineNr", .{ .bold = true });
        try self.set("Comment", .{ .italic = true, .dim = true });
        try self.set("String", .{});
        try self.set("Keyword", .{ .bold = true });
        try self.set("Function", .{});
        try self.set("Type", .{ .bold = true });
        try self.set("Number", .{});
        try self.set("Operator", .{});
        try self.set("DiagnosticError", .{ .bold = true, .underline = true });
        try self.set("DiagnosticWarn", .{ .bold = true });
        try self.set("DiagnosticInfo", .{});
        try self.set("DiagnosticHint", .{ .italic = true });
        try self.set("VirtualText", .{ .italic = true, .dim = true });
        try self.set("PluginAccent", .{ .bold = true });
    }

    fn loadEmber(self: *Store) !void {
        try self.set("LineNr", .{ .foreground = 8, .dim = true });
        try self.set("CursorLineNr", .{ .foreground = 11, .bold = true });
        try self.set("Comment", .{ .foreground = 8, .italic = true });
        try self.set("String", .{ .foreground = 11 });
        try self.set("Keyword", .{ .foreground = 9, .bold = true });
        try self.set("Function", .{ .foreground = 11 });
        try self.set("Type", .{ .foreground = 13 });
        try self.set("Number", .{ .foreground = 9 });
        try self.set("Operator", .{ .foreground = 11 });
        try self.set("DiagnosticError", .{ .foreground = 9, .bold = true });
        try self.set("DiagnosticWarn", .{ .foreground = 11, .bold = true });
        try self.set("DiagnosticInfo", .{ .foreground = 13 });
        try self.set("DiagnosticHint", .{ .foreground = 8, .italic = true });
        try self.set("VirtualText", .{ .foreground = 8, .italic = true, .dim = true });
        try self.set("PluginAccent", .{ .foreground = 11 });
    }
};

threadlocal var active_store: ?*Store = null;

pub fn activate(store: *Store) void {
    active_store = store;
}

pub fn deactivate(store: *Store) void {
    if (active_store == store) active_store = null;
}

pub fn activeStyle(name: []const u8) ?Style {
    const store = active_store orelse return null;
    return store.get(name);
}

pub fn groupForCapture(capture: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, capture, "comment") != null) return "Comment";
    if (std.mem.indexOf(u8, capture, "string") != null) return "String";
    if (std.mem.indexOf(u8, capture, "keyword") != null) return "Keyword";
    if (std.mem.indexOf(u8, capture, "function") != null) return "Function";
    if (std.mem.indexOf(u8, capture, "type") != null) return "Type";
    if (std.mem.indexOf(u8, capture, "number") != null or std.mem.indexOf(u8, capture, "constant") != null) return "Number";
    if (std.mem.indexOf(u8, capture, "operator") != null) return "Operator";
    return null;
}

fn validGroup(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.')) return false;
    }
    return true;
}

test "colorschemes and overrides share one native registry" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.load("zim");
    try std.testing.expectEqual(@as(?u8, 13), store.get("Keyword").?.foreground);
    try store.set("Keyword", .{ .foreground = 2, .italic = true });
    try std.testing.expectEqual(@as(?u8, 2), store.get("Keyword").?.foreground);
    try std.testing.expect(store.get("Keyword").?.italic);
    try std.testing.expectEqualStrings("Keyword", groupForCapture("keyword.function").?);
}
