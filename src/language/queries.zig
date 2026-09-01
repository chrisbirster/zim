pub const Kind = enum {
    highlights,
    folds,
    symbols,
    text_objects,
    injections,
};

pub const Sources = struct {
    highlights: []const u8,
    folds: []const u8,
    symbols: []const u8,
    text_objects: []const u8,
    injections: []const u8,

    pub fn get(self: Sources, kind: Kind) []const u8 {
        return switch (kind) {
            .highlights => self.highlights,
            .folds => self.folds,
            .symbols => self.symbols,
            .text_objects => self.text_objects,
            .injections => self.injections,
        };
    }
};

pub const zig = Sources{
    .highlights = @embedFile("queries/zig/highlights.scm"),
    .folds = @embedFile("queries/zig/folds.scm"),
    .symbols = @embedFile("queries/zig/symbols.scm"),
    .text_objects = @embedFile("queries/zig/text_objects.scm"),
    .injections = @embedFile("queries/zig/injections.scm"),
};
