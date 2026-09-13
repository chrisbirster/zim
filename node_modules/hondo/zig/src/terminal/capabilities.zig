const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});

pub const ColorDepth = enum {
    mono,
    ansi16,
    ansi256,
    truecolor,
};

pub const Capabilities = struct {
    color_depth: ColorDepth = .ansi16,
    unicode: bool = true,
    mouse: bool = true,
    focus_events: bool = true,
    bracketed_paste: bool = true,
    synchronized_output: bool = false,

    pub fn full() Capabilities {
        return .{
            .color_depth = .truecolor,
            .unicode = true,
            .mouse = true,
            .focus_events = true,
            .bracketed_paste = true,
            .synchronized_output = true,
        };
    }
};

pub fn detectEnvironment() Capabilities {
    return detectValues(.{
        .term = env("TERM"),
        .colorterm = env("COLORTERM"),
        .no_color = envPresent("NO_COLOR"),
        .wt_session = envPresent("WT_SESSION"),
        .term_program = env("TERM_PROGRAM"),
    });
}

pub const Values = struct {
    term: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    no_color: bool = false,
    wt_session: bool = false,
    term_program: ?[]const u8 = null,
};

pub fn detectValues(values: Values) Capabilities {
    const dumb = if (values.term) |term| std.ascii.eqlIgnoreCase(term, "dumb") else false;
    if (dumb) {
        return .{
            .color_depth = .mono,
            .unicode = false,
            .mouse = false,
            .focus_events = false,
            .bracketed_paste = false,
            .synchronized_output = false,
        };
    }

    var result = Capabilities{};
    if (values.no_color) {
        result.color_depth = .mono;
    } else if (values.wt_session or isTrueColor(values.colorterm)) {
        result.color_depth = .truecolor;
    } else if (values.term) |term| {
        result.color_depth = if (containsIgnoreCase(term, "256color")) .ansi256 else .ansi16;
    }

    if (values.term_program) |program| {
        result.synchronized_output = std.ascii.eqlIgnoreCase(program, "WezTerm") or
            std.ascii.eqlIgnoreCase(program, "kitty");
    }
    if (values.term) |term| {
        if (containsIgnoreCase(term, "kitty")) result.synchronized_output = true;
    }
    return result;
}

fn isTrueColor(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "truecolor") or
        std.ascii.eqlIgnoreCase(text, "24bit");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn envPresent(name: [*:0]const u8) bool {
    return c.getenv(name) != null;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "capabilities detect truecolor, 256 color, NO_COLOR and dumb terminals" {
    try std.testing.expectEqual(ColorDepth.truecolor, detectValues(.{ .colorterm = "truecolor" }).color_depth);
    try std.testing.expectEqual(ColorDepth.truecolor, detectValues(.{ .wt_session = true }).color_depth);
    try std.testing.expectEqual(ColorDepth.ansi256, detectValues(.{ .term = "xterm-256color" }).color_depth);
    try std.testing.expectEqual(ColorDepth.mono, detectValues(.{ .no_color = true }).color_depth);

    const dumb = detectValues(.{ .term = "dumb" });
    try std.testing.expectEqual(ColorDepth.mono, dumb.color_depth);
    try std.testing.expect(!dumb.mouse);
    try std.testing.expect(!dumb.focus_events);
}

test "capabilities recognize synchronized output terminals" {
    try std.testing.expect(detectValues(.{ .term_program = "WezTerm" }).synchronized_output);
    try std.testing.expect(detectValues(.{ .term = "xterm-kitty" }).synchronized_output);
}
