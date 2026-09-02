const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const DiagnosticSeverity = enum(u8) {
    error = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?DiagnosticSeverity = null,
    message: []const u8,
    source: ?[]const u8 = null,
};

pub const Symbol = struct {
    name: []const u8,
    kind: u32,
    location: Location,
};

pub const TextEdit = struct {
    range: Range,
    new_text: []const u8,
};

pub fn positionFromByteOffsetUtf16(text: []const u8, requested_offset: usize) Position {
    const limit = @min(requested_offset, text.len);
    var line: u32 = 0;
    var character: u32 = 0;
    var index: usize = 0;
    while (index < limit) {
        const byte = text[index];
        if (byte == '\n') {
            line += 1;
            character = 0;
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const end = @min(text.len, index + sequence_len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch @as(u21, byte);
        character += if (codepoint > 0xffff) 2 else 1;
        index = end;
    }
    return .{ .line = line, .character = character };
}

pub fn byteOffsetFromPositionUtf16(text: []const u8, position: Position) usize {
    var line: u32 = 0;
    var index: usize = 0;
    while (index < text.len and line < position.line) {
        if (text[index] == '\n') line += 1;
        index += 1;
    }
    if (line < position.line) return text.len;

    var units: u32 = 0;
    while (index < text.len and text[index] != '\n' and units < position.character) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(text.len, index + sequence_len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch @as(u21, text[index]);
        const width: u32 = if (codepoint > 0xffff) 2 else 1;
        if (units + width > position.character) break;
        units += width;
        index = end;
    }
    return index;
}

test "UTF-16 protocol positions round trip UTF-8 byte offsets" {
    const text = "a🙂b\nβeta";
    const after_emoji = "a🙂".len;
    const position = positionFromByteOffsetUtf16(text, after_emoji);
    try std.testing.expectEqual(@as(u32, 0), position.line);
    try std.testing.expectEqual(@as(u32, 3), position.character);
    try std.testing.expectEqual(after_emoji, byteOffsetFromPositionUtf16(text, position));

    const beta = std.mem.indexOf(u8, text, "β") orelse unreachable;
    const beta_position = positionFromByteOffsetUtf16(text, beta);
    try std.testing.expectEqual(@as(u32, 1), beta_position.line);
    try std.testing.expectEqual(@as(u32, 0), beta_position.character);
}
