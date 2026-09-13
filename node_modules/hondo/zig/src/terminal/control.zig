const std = @import("std");

pub const enter_alternate_screen = "\x1b[?1049h";
pub const leave_alternate_screen = "\x1b[?1049l";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const home = "\x1b[H";
pub const clear_screen = "\x1b[2J";
pub const clear_line = "\x1b[2K";
pub const reset_style = "\x1b[0m";
pub const enable_mouse_buttons = "\x1b[?1000h";
pub const disable_mouse_buttons = "\x1b[?1000l";
pub const enable_sgr_mouse = "\x1b[?1006h";
pub const disable_sgr_mouse = "\x1b[?1006l";
pub const enable_focus_events = "\x1b[?1004h";
pub const disable_focus_events = "\x1b[?1004l";

pub fn beginSequence(allocator: std.mem.Allocator) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ enter_alternate_screen, hide_cursor, home, clear_screen });
}

pub fn restoreSequence(allocator: std.mem.Allocator) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ reset_style, show_cursor, leave_alternate_screen });
}

pub fn inputFeaturesBeginSequence(allocator: std.mem.Allocator) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ enable_mouse_buttons, enable_sgr_mouse, enable_focus_events });
}

pub fn inputFeaturesRestoreSequence(allocator: std.mem.Allocator) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ disable_focus_events, disable_sgr_mouse, disable_mouse_buttons });
}

test "terminal lifecycle sequences are deterministic" {
    const begin = try beginSequence(std.testing.allocator);
    defer std.testing.allocator.free(begin);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J", begin);

    const restore = try restoreSequence(std.testing.allocator);
    defer std.testing.allocator.free(restore);
    try std.testing.expectEqualStrings("\x1b[0m\x1b[?25h\x1b[?1049l", restore);
}

test "mouse and focus feature sequences restore in reverse order" {
    const begin = try inputFeaturesBeginSequence(std.testing.allocator);
    defer std.testing.allocator.free(begin);
    try std.testing.expectEqualStrings("\x1b[?1000h\x1b[?1006h\x1b[?1004h", begin);

    const restore = try inputFeaturesRestoreSequence(std.testing.allocator);
    defer std.testing.allocator.free(restore);
    try std.testing.expectEqualStrings("\x1b[?1004l\x1b[?1006l\x1b[?1000l", restore);
}
