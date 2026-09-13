const std = @import("std");

pub const Key = union(enum) {
    codepoint: u21,
    enter,
    backspace,
    tab,
    shift_tab,
    escape,
    ctrl_c,
    up,
    down,
    left,
    right,
};

pub const MouseButton = enum {
    none,
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
};

pub const MouseAction = enum {
    press,
    release,
    move,
    scroll,
};

pub const MouseEvent = struct {
    x: usize,
    y: usize,
    button: MouseButton,
    action: MouseAction,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const FocusEvent = enum {
    in,
    out,
};

pub const Event = union(enum) {
    key: Key,
    mouse: MouseEvent,
    focus: FocusEvent,
};

pub const Decoded = struct {
    event: Event,
    consumed: usize,
};

pub fn decode(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;

    if (bytes[0] == 0x03) return .{ .event = .{ .key = .ctrl_c }, .consumed = 1 };
    if (bytes[0] == 0x08 or bytes[0] == 0x7f) return .{ .event = .{ .key = .backspace }, .consumed = 1 };
    if (bytes[0] == '\t') return .{ .event = .{ .key = .tab }, .consumed = 1 };
    if (bytes[0] == '\r' or bytes[0] == '\n') return .{ .event = .{ .key = .enter }, .consumed = 1 };

    if (bytes[0] == 0x1b) {
        if (bytes.len >= 3 and bytes[1] == '[') {
            if (bytes[2] == 'I') return .{ .event = .{ .focus = .in }, .consumed = 3 };
            if (bytes[2] == 'O') return .{ .event = .{ .focus = .out }, .consumed = 3 };
            if (bytes[2] == '<') return decodeSgrMouse(bytes);

            return switch (bytes[2]) {
                'A' => .{ .event = .{ .key = .up }, .consumed = 3 },
                'B' => .{ .event = .{ .key = .down }, .consumed = 3 },
                'C' => .{ .event = .{ .key = .right }, .consumed = 3 },
                'D' => .{ .event = .{ .key = .left }, .consumed = 3 },
                'Z' => .{ .event = .{ .key = .shift_tab }, .consumed = 3 },
                else => .{ .event = .{ .key = .escape }, .consumed = 1 },
            };
        }
        return .{ .event = .{ .key = .escape }, .consumed = 1 };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch
        return .{ .event = .{ .key = .{ .codepoint = 0xfffd } }, .consumed = 1 };
    if (bytes.len < sequence_len) return null;
    const codepoint = std.unicode.utf8Decode(bytes[0..sequence_len]) catch 0xfffd;
    return .{ .event = .{ .key = .{ .codepoint = codepoint } }, .consumed = sequence_len };
}

fn decodeSgrMouse(bytes: []const u8) ?Decoded {
    if (bytes.len < 4) return null;
    var terminator_index: ?usize = null;
    var index: usize = 3;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == 'M' or bytes[index] == 'm') {
            terminator_index = index;
            break;
        }
        if ((bytes[index] < '0' or bytes[index] > '9') and bytes[index] != ';') {
            return .{ .event = .{ .key = .escape }, .consumed = 1 };
        }
    }
    const end = terminator_index orelse return null;

    var parts = std.mem.splitScalar(u8, bytes[3..end], ';');
    const code_text = parts.next() orelse return null;
    const x_text = parts.next() orelse return null;
    const y_text = parts.next() orelse return null;
    if (parts.next() != null) return null;

    const code = std.fmt.parseInt(u16, code_text, 10) catch return null;
    const terminal_x = std.fmt.parseInt(usize, x_text, 10) catch return null;
    const terminal_y = std.fmt.parseInt(usize, y_text, 10) catch return null;

    const wheel = code & 64 != 0;
    const motion = code & 32 != 0;
    const base_button = code & 3;
    const release = bytes[end] == 'm';

    const button: MouseButton = if (wheel)
        (if (base_button & 1 == 0) .wheel_up else .wheel_down)
    else switch (base_button) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };

    const action: MouseAction = if (wheel)
        .scroll
    else if (release)
        .release
    else if (motion)
        .move
    else
        .press;

    return .{
        .event = .{ .mouse = .{
            .x = terminal_x -| 1,
            .y = terminal_y -| 1,
            .button = button,
            .action = action,
            .shift = code & 4 != 0,
            .alt = code & 8 != 0,
            .ctrl = code & 16 != 0,
        } },
        .consumed = end + 1,
    };
}

test "terminal input decodes control navigation and arrow keys" {
    try std.testing.expectEqual(Key.enter, decode("\r").?.event.key);
    try std.testing.expectEqual(Key.backspace, decode("\x08").?.event.key);
    try std.testing.expectEqual(Key.backspace, decode("\x7f").?.event.key);
    try std.testing.expectEqual(Key.tab, decode("\t").?.event.key);
    try std.testing.expectEqual(Key.shift_tab, decode("\x1b[Z").?.event.key);
    try std.testing.expectEqual(Key.escape, decode("\x1b").?.event.key);
    try std.testing.expectEqual(Key.ctrl_c, decode("\x03").?.event.key);
    try std.testing.expectEqual(Key.up, decode("\x1b[A").?.event.key);
    try std.testing.expectEqual(Key.down, decode("\x1b[B").?.event.key);
    try std.testing.expectEqual(Key.left, decode("\x1b[D").?.event.key);
    try std.testing.expectEqual(Key.right, decode("\x1b[C").?.event.key);
}

test "terminal input decodes UTF-8 codepoints" {
    const ascii = decode("x").?;
    try std.testing.expectEqual(@as(u21, 'x'), ascii.event.key.codepoint);
    try std.testing.expectEqual(@as(usize, 1), ascii.consumed);

    const lambda = decode("λ").?;
    try std.testing.expectEqual(@as(u21, 'λ'), lambda.event.key.codepoint);
    try std.testing.expectEqual("λ".len, lambda.consumed);
}

test "terminal input waits for incomplete UTF-8" {
    const bytes = [_]u8{0xce};
    try std.testing.expect(decode(&bytes) == null);
}

test "terminal input decodes SGR mouse press release move scroll and modifiers" {
    const press = decode("\x1b[<0;10;5M").?;
    try std.testing.expectEqual(@as(usize, 9), press.event.mouse.x);
    try std.testing.expectEqual(@as(usize, 4), press.event.mouse.y);
    try std.testing.expectEqual(MouseButton.left, press.event.mouse.button);
    try std.testing.expectEqual(MouseAction.press, press.event.mouse.action);

    const release = decode("\x1b[<0;10;5m").?;
    try std.testing.expectEqual(MouseAction.release, release.event.mouse.action);

    const move = decode("\x1b[<36;3;4M").?;
    try std.testing.expectEqual(MouseAction.move, move.event.mouse.action);
    try std.testing.expect(move.event.mouse.shift);

    const scroll = decode("\x1b[<65;1;1M").?;
    try std.testing.expectEqual(MouseAction.scroll, scroll.event.mouse.action);
    try std.testing.expectEqual(MouseButton.wheel_down, scroll.event.mouse.button);
}

test "terminal input waits for incomplete SGR mouse and decodes focus events" {
    try std.testing.expect(decode("\x1b[<0;2;") == null);
    try std.testing.expectEqual(FocusEvent.in, decode("\x1b[I").?.event.focus);
    try std.testing.expectEqual(FocusEvent.out, decode("\x1b[O").?.event.focus);
}
