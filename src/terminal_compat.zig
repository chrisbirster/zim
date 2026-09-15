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
    return inspectValues(
        environment.get("TERM") orelse "unknown",
        environment.get("TERM_PROGRAM"),
        environment.get("WT_SESSION") != null,
        environment.get("COLORTERM"),
        environment.get("SSH_CONNECTION") != null or environment.get("SSH_TTY") != null,
        environment.get("TMUX") != null,
    );
}

pub fn inspectValues(
    term: []const u8,
    program: ?[]const u8,
    windows_terminal: bool,
    color_term: ?[]const u8,
    under_ssh: bool,
    under_tmux: bool,
) Report {
    const base_family: Family = if (windows_terminal)
        .windows_terminal
    else if (program) |value|
        classifyProgram(value, term)
    else
        classifyTerm(term);
    const family = if (under_tmux and base_family == .screen) .tmux else base_family;
    return .{
        .family = family,
        .term = term,
        .color_term = color_term,
        .under_ssh = under_ssh,
        .under_tmux = under_tmux,
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

test "SSH and tmux context remain explicit while terminal capability is classified" {
    const tmux_over_ssh = inspectValues("screen-256color", null, false, "truecolor", true, true);
    try std.testing.expectEqual(Family.tmux, tmux_over_ssh.family);
    try std.testing.expect(tmux_over_ssh.under_ssh);
    try std.testing.expect(tmux_over_ssh.under_tmux);
    try std.testing.expect(tmux_over_ssh.interactive_color);

    const wezterm_over_ssh = inspectValues("xterm-256color", "WezTerm", false, "truecolor", true, false);
    try std.testing.expectEqual(Family.wezterm, wezterm_over_ssh.family);
    try std.testing.expect(wezterm_over_ssh.under_ssh);
    try std.testing.expect(!wezterm_over_ssh.under_tmux);

    const dumb = inspectValues("dumb", null, false, null, false, false);
    try std.testing.expectEqual(Family.dumb, dumb.family);
    try std.testing.expect(!dumb.interactive_color);
}
