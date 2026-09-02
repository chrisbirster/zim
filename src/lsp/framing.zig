const std = @import("std");

const header_delimiter = "\r\n\r\n";
const content_length_prefix = "Content-Length:";
const max_message_bytes: usize = 16 * 1024 * 1024;

pub fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > max_message_bytes) return error.MessageTooLarge;
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

pub const Decoder = struct {
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buffer.appendSlice(allocator, bytes);
    }

    pub fn next(self: *Decoder, allocator: std.mem.Allocator) !?[]u8 {
        const header_end = std.mem.indexOf(u8, self.buffer.items, header_delimiter) orelse return null;
        const header = self.buffer.items[0..header_end];
        const body_len = try parseContentLength(header);
        if (body_len > max_message_bytes) return error.MessageTooLarge;
        const body_start = header_end + header_delimiter.len;
        const frame_end = body_start + body_len;
        if (self.buffer.items.len < frame_end) return null;

        const body = try allocator.dupe(u8, self.buffer.items[body_start..frame_end]);
        const remaining = self.buffer.items.len - frame_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[frame_end..]);
        }
        self.buffer.items.len = remaining;
        return body;
    }
};

fn parseContentLength(header: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (line.len < content_length_prefix.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..content_length_prefix.len], content_length_prefix)) continue;
        const raw = std.mem.trim(u8, line[content_length_prefix.len..], " \t");
        return std.fmt.parseInt(usize, raw, 10);
    }
    return error.MissingContentLength;
}

test "LSP framing decodes fragmented and back-to-back messages" {
    const first_body = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const second_body = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}";
    const first = try frame(std.testing.allocator, first_body);
    defer std.testing.allocator.free(first);
    const second = try frame(std.testing.allocator, second_body);
    defer std.testing.allocator.free(second);

    var decoder: Decoder = .{};
    defer decoder.deinit(std.testing.allocator);
    try decoder.feed(std.testing.allocator, first[0..7]);
    try std.testing.expect((try decoder.next(std.testing.allocator)) == null);
    try decoder.feed(std.testing.allocator, first[7..]);
    try decoder.feed(std.testing.allocator, second);

    const decoded_first = (try decoder.next(std.testing.allocator)).?;
    defer std.testing.allocator.free(decoded_first);
    try std.testing.expectEqualStrings(first_body, decoded_first);
    const decoded_second = (try decoder.next(std.testing.allocator)).?;
    defer std.testing.allocator.free(decoded_second);
    try std.testing.expectEqualStrings(second_body, decoded_second);
    try std.testing.expect((try decoder.next(std.testing.allocator)) == null);
}
