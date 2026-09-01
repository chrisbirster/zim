const std = @import("std");

pub const BufferId = u64;
pub const Revision = u64;

pub const Position = struct {
    row: u32,
    column: u32,
};

pub const Range = struct {
    start_byte: u32,
    end_byte: u32,
    start_point: Position,
    end_point: Position,

    pub fn len(self: Range) u32 {
        return self.end_byte - self.start_byte;
    }
};

pub const Edit = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Position,
    old_end_point: Position,
    new_end_point: Position,
};

pub const ParseSummary = struct {
    revision: Revision,
    root: Range,
    has_error: bool,
};

pub const ChangedRangeList = struct {
    allocator: std.mem.Allocator,
    items: []Range,

    pub fn deinit(self: *ChangedRangeList) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const HighlightSpan = struct {
    range: Range,
    capture: []u8,
};

pub const HighlightList = struct {
    allocator: std.mem.Allocator,
    items: []HighlightSpan,

    pub fn deinit(self: *HighlightList) void {
        for (self.items) |item| self.allocator.free(item.capture);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const FoldRange = struct {
    range: Range,
};

pub const FoldList = struct {
    allocator: std.mem.Allocator,
    items: []FoldRange,

    pub fn deinit(self: *FoldList) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SymbolKind = enum {
    function,
    class,
    other,
};

pub const Symbol = struct {
    range: Range,
    selection_range: ?Range,
    name: ?[]u8,
    kind: SymbolKind,
};

pub const SymbolList = struct {
    allocator: std.mem.Allocator,
    items: []Symbol,

    pub fn deinit(self: *SymbolList) void {
        for (self.items) |item| {
            if (item.name) |name| self.allocator.free(name);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const StructuralObjectKind = enum {
    function,
    class,
    parameter,
    block,
};

pub const ObjectScope = enum {
    inner,
    around,
};

pub const TextObject = struct {
    kind: StructuralObjectKind,
    scope: ObjectScope,
    range: Range,
};

pub const TextObjectList = struct {
    allocator: std.mem.Allocator,
    items: []TextObject,

    pub fn deinit(self: *TextObjectList) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const MotionDirection = enum {
    next,
    previous,
};

pub const InjectionRegion = struct {
    range: Range,
    language_id: ?[]u8,
};

pub const InjectionList = struct {
    allocator: std.mem.Allocator,
    items: []InjectionRegion,

    pub fn deinit(self: *InjectionList) void {
        for (self.items) |item| {
            if (item.language_id) |language_id| self.allocator.free(language_id);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};
