const std = @import("std");

pub const Family = enum {
    kitty,
    wezterm,
    alacritty,
    apple_terminal,
    windows_terminal,
    xterm,
    screen,
    tmux,
    dumb,
    unknown,
};

pub const Report = struct {
    family: Family,
    term: []const u8,
    color_term: ?[]const u8,
    under_ssh: bool,
    under_tmux: bool,
    interactive_color: bool,
};

pub fn inspect(environment: *const std.process.Environ.Map) Report {
    const term = environment.get("TERM") orelse "unknown";
    const program = environment.get("TERM_PROGRAM");
    const family: Family = if (environment.get("WT_SESSION") != null)
        .windows_terminal
    else if (program) |value| classifyProgram(value, term)
    else
        classifyTerm(term);
    return .{
        .family = if (environment.get("TMUX") != null and family == .screen) .tmux else family,
        .term = term,
        .color_term = environment.get("COLORTERM"),
        .under_ssh = environment.get("SSH_CONNECTION") != null or environment.get("SSH_TTY") != null,
        .under_tmux = environment.get("TMUX") != null,
        .interactive_color = family != .dumb and !std.mem.eql(u8, term, "dumb"),
    };
}

pub fn classifyTerm(term: []const u8) Family {
    if (std.mem.eql(u8, term, "dumb")) return .dumb;
    if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
    if (std.mem.indexOf(u8, term, "alacritty") != null) return .alacritty;
    if (std.mem.indexOf(u8, term, "tmux") != null) return .tmux;
    if (std.mem.indexOf(u8, term, "screen") != null) return .screen;
    if (std.mem.indexOf(u8, term, "xterm") != null) return .xterm;
    return .unknown;
}

fn classifyProgram(program: []const u8, term: []const u8) Family {
    if (std.ascii.eqlIgnoreCase(program, "WezTerm")) return .wezterm;
    if (std.ascii.eqlIgnoreCase(program, "Alacritty")) return .alacritty;
    if (std.ascii.eqlIgnoreCase(program, "Apple_Terminal")) return .apple_terminal;
    return classifyTerm(term);
}

test "terminal families cover the v1 compatibility matrix" {
    try std.testing.expectEqual(Family.kitty, classifyTerm("xterm-kitty"));
    try std.testing.expectEqual(Family.alacritty, classifyTerm("alacritty"));
    try std.testing.expectEqual(Family.tmux, classifyTerm("tmux-256color"));
    try std.testing.expectEqual(Family.screen, classifyTerm("screen-256color"));
    try std.testing.expectEqual(Family.xterm, classifyTerm("xterm-256color"));
    try std.testing.expectEqual(Family.dumb, classifyTerm("dumb"));
}
