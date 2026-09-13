const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: Rgb, other: Rgb) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Color = union(enum) {
    terminal_default,
    ansi: u4,
    indexed: u8,
    rgb: Rgb,

    pub fn eql(self: Color, other: Color) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .terminal_default => true,
            .ansi => |value| value == other.ansi,
            .indexed => |value| value == other.indexed,
            .rgb => |value| value.eql(other.rgb),
        };
    }
};

pub const Attributes = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,

    pub fn eql(self: Attributes, other: Attributes) bool {
        return self.bold == other.bold and
            self.dim == other.dim and
            self.italic == other.italic and
            self.underline == other.underline and
            self.reverse == other.reverse and
            self.strikethrough == other.strikethrough;
    }

    pub fn isDefault(self: Attributes) bool {
        return self.eql(.{});
    }
};

pub const Style = struct {
    foreground: Color = .terminal_default,
    background: Color = .terminal_default,
    attributes: Attributes = .{},

    pub fn eql(self: Style, other: Style) bool {
        return self.foreground.eql(other.foreground) and
            self.background.eql(other.background) and
            self.attributes.eql(other.attributes);
    }

    pub fn isDefault(self: Style) bool {
        return self.eql(.{});
    }
};

test "style equality includes colors and text attributes" {
    const a = Style{
        .foreground = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .attributes = .{ .bold = true, .underline = true },
    };
    const b = a;
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(.{}));
}
