const std = @import("std");

const ParseState = enum {
    ground,
    escape,
    csi,
    osc,
    osc_escape,
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    rows: usize,
    cells: []u21,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    state: ParseState = .ground,
    csi_params: [8]u16 = [_]u16{0} ** 8,
    csi_count: usize = 0,
    csi_value: u16 = 0,
    csi_has_value: bool = false,
    csi_private: bool = false,
    utf8_skip: u3 = 0,

    pub fn init(allocator: std.mem.Allocator, columns: usize, rows: usize) !Screen {
        if (columns == 0 or rows == 0) return error.InvalidDimensions;
        const cells = try allocator.alloc(u21, columns * rows);
        @memset(cells, ' ');
        return .{
            .allocator = allocator,
            .columns = columns,
            .rows = rows,
            .cells = cells,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn reset(self: *Screen) void {
        @memset(self.cells, ' ');
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.state = .ground;
        self.resetCsi();
        self.utf8_skip = 0;
    }

    pub fn resize(self: *Screen, columns: usize, rows: usize) !bool {
        if (columns == 0 or rows == 0) return error.InvalidDimensions;
        if (columns == self.columns and rows == self.rows) return false;

        const replacement = try self.allocator.alloc(u21, columns * rows);
        @memset(replacement, ' ');
        const copy_rows = @min(rows, self.rows);
        const copy_columns = @min(columns, self.columns);
        const old_row_start = self.rows - copy_rows;
        const new_row_start = rows - copy_rows;
        for (0..copy_rows) |row| {
            const old_base = (old_row_start + row) * self.columns;
            const new_base = (new_row_start + row) * columns;
            @memcpy(replacement[new_base..][0..copy_columns], self.cells[old_base..][0..copy_columns]);
        }

        self.allocator.free(self.cells);
        self.cells = replacement;
        self.columns = columns;
        self.rows = rows;
        self.cursor_x = @min(self.cursor_x, columns - 1);
        self.cursor_y = @min(self.cursor_y + new_row_start, rows - 1);
        return true;
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |byte| self.feedByte(byte);
    }

    pub fn cell(self: *const Screen, row: usize, column: usize) ?u21 {
        if (row >= self.rows or column >= self.columns) return null;
        return self.cells[row * self.columns + column];
    }

    pub fn row(self: *const Screen, index: usize) ?[]const u21 {
        if (index >= self.rows) return null;
        const start = index * self.columns;
        return self.cells[start .. start + self.columns];
    }

    fn feedByte(self: *Screen, byte: u8) void {
        switch (self.state) {
            .ground => self.feedGround(byte),
            .escape => self.feedEscape(byte),
            .csi => self.feedCsi(byte),
            .osc => {
                if (byte == 0x07) {
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .osc_escape;
                }
            },
            .osc_escape => {
                self.state = if (byte == '\\') .ground else .osc;
            },
        }
    }

    fn feedGround(self: *Screen, byte: u8) void {
        if (self.utf8_skip != 0) {
            if ((byte & 0xc0) == 0x80) {
                self.utf8_skip -= 1;
                return;
            }
            self.utf8_skip = 0;
        }

        switch (byte) {
            0x1b => self.state = .escape,
            '\r' => self.cursor_x = 0,
            '\n' => self.newLine(),
            0x08 => self.cursor_x -|= 1,
            '\t' => {
                const next = ((self.cursor_x / 8) + 1) * 8;
                self.cursor_x = @min(next, self.columns - 1);
            },
            0x00...0x1f, 0x7f => {},
            0x20...0x7e => self.put(@intCast(byte)),
            else => {
                self.put(0xfffd);
                self.utf8_skip = utf8ContinuationCount(byte);
            },
        }
    }

    fn feedEscape(self: *Screen, byte: u8) void {
        switch (byte) {
            '[' => {
                self.resetCsi();
                self.state = .csi;
            },
            ']' => self.state = .osc,
            'c' => {
                self.reset();
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    fn feedCsi(self: *Screen, byte: u8) void {
        if (byte >= '0' and byte <= '9') {
            self.csi_value = self.csi_value *| 10 +| @as(u16, byte - '0');
            self.csi_has_value = true;
            return;
        }
        if (byte == ';') {
            self.pushCsiParam();
            return;
        }
        if (byte == '?' and self.csi_count == 0 and !self.csi_has_value) {
            self.csi_private = true;
            return;
        }
        if (byte >= 0x40 and byte <= 0x7e) {
            self.pushCsiParam();
            self.applyCsi(byte);
            self.resetCsi();
            self.state = .ground;
        }
    }

    fn pushCsiParam(self: *Screen) void {
        if (self.csi_count < self.csi_params.len) {
            self.csi_params[self.csi_count] = if (self.csi_has_value) self.csi_value else 0;
            self.csi_count += 1;
        }
        self.csi_value = 0;
        self.csi_has_value = false;
    }

    fn resetCsi(self: *Screen) void {
        @memset(&self.csi_params, 0);
        self.csi_count = 0;
        self.csi_value = 0;
        self.csi_has_value = false;
        self.csi_private = false;
    }

    fn param(self: *const Screen, index: usize, default: usize) usize {
        if (index >= self.csi_count or self.csi_params[index] == 0) return default;
        return self.csi_params[index];
    }

    fn applyCsi(self: *Screen, final: u8) void {
        if (self.csi_private) return;
        switch (final) {
            'A' => self.cursor_y -|= self.param(0, 1),
            'B' => self.cursor_y = @min(self.rows - 1, self.cursor_y + self.param(0, 1)),
            'C' => self.cursor_x = @min(self.columns - 1, self.cursor_x + self.param(0, 1)),
            'D' => self.cursor_x -|= self.param(0, 1),
            'G' => self.cursor_x = @min(self.columns - 1, self.param(0, 1) - 1),
            'd' => self.cursor_y = @min(self.rows - 1, self.param(0, 1) - 1),
            'H', 'f' => {
                self.cursor_y = @min(self.rows - 1, self.param(0, 1) - 1);
                self.cursor_x = @min(self.columns - 1, self.param(1, 1) - 1);
            },
            'J' => self.eraseDisplay(self.param(0, 0)),
            'K' => self.eraseLine(self.param(0, 0)),
            'm', 'h', 'l' => {},
            else => {},
        }
    }

    fn put(self: *Screen, codepoint: u21) void {
        self.cells[self.cursor_y * self.columns + self.cursor_x] = codepoint;
        self.cursor_x += 1;
        if (self.cursor_x >= self.columns) {
            self.cursor_x = 0;
            self.newLine();
        }
    }

    fn newLine(self: *Screen) void {
        if (self.cursor_y + 1 < self.rows) {
            self.cursor_y += 1;
            return;
        }
        self.scrollUp();
        self.cursor_y = self.rows - 1;
    }

    fn scrollUp(self: *Screen) void {
        if (self.rows <= 1) {
            @memset(self.cells, ' ');
            return;
        }
        var row_index: usize = 1;
        while (row_index < self.rows) : (row_index += 1) {
            const source = row_index * self.columns;
            const target = (row_index - 1) * self.columns;
            @memcpy(self.cells[target..][0..self.columns], self.cells[source..][0..self.columns]);
        }
        const last = (self.rows - 1) * self.columns;
        @memset(self.cells[last .. last + self.columns], ' ');
    }

    fn eraseDisplay(self: *Screen, mode: usize) void {
        switch (mode) {
            0 => {
                const start = self.cursor_y * self.columns + self.cursor_x;
                @memset(self.cells[start..], ' ');
            },
            1 => {
                const end = self.cursor_y * self.columns + self.cursor_x + 1;
                @memset(self.cells[0..end], ' ');
            },
            2, 3 => @memset(self.cells, ' '),
            else => {},
        }
    }

    fn eraseLine(self: *Screen, mode: usize) void {
        const start = self.cursor_y * self.columns;
        switch (mode) {
            0 => @memset(self.cells[start + self.cursor_x .. start + self.columns], ' '),
            1 => @memset(self.cells[start .. start + self.cursor_x + 1], ' '),
            2 => @memset(self.cells[start .. start + self.columns], ' '),
            else => {},
        }
    }
};

fn utf8ContinuationCount(byte: u8) u3 {
    if ((byte & 0xe0) == 0xc0) return 1;
    if ((byte & 0xf0) == 0xe0) return 2;
    if ((byte & 0xf8) == 0xf0) return 3;
    return 0;
}

test "terminal screen handles line flow carriage return and scrolling" {
    var screen = try Screen.init(std.testing.allocator, 5, 2);
    defer screen.deinit();

    screen.feed("hello\nworld\rZ");
    try std.testing.expectEqual(@as(u21, 'w'), screen.cell(0, 0).?);
    try std.testing.expectEqual(@as(u21, 'Z'), screen.cell(1, 0).?);
    try std.testing.expectEqual(@as(u21, 'o'), screen.cell(1, 1).?);
}

test "terminal screen applies basic CSI cursor and erase commands" {
    var screen = try Screen.init(std.testing.allocator, 8, 3);
    defer screen.deinit();

    screen.feed("abcdef\x1b[2DXY");
    try std.testing.expectEqual(@as(u21, 'X'), screen.cell(0, 4).?);
    try std.testing.expectEqual(@as(u21, 'Y'), screen.cell(0, 5).?);
    screen.feed("\x1b[2J\x1b[2;3HQ");
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(0, 0).?);
    try std.testing.expectEqual(@as(u21, 'Q'), screen.cell(1, 2).?);
}

test "terminal screen ignores SGR and OSC metadata" {
    var screen = try Screen.init(std.testing.allocator, 20, 2);
    defer screen.deinit();

    screen.feed("\x1b[31mred\x1b[0m\x1b]0;title\x07 ok");
    try std.testing.expectEqual(@as(u21, 'r'), screen.cell(0, 0).?);
    try std.testing.expectEqual(@as(u21, 'e'), screen.cell(0, 1).?);
    try std.testing.expectEqual(@as(u21, 'd'), screen.cell(0, 2).?);
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(0, 3).?);
    try std.testing.expectEqual(@as(u21, 'o'), screen.cell(0, 4).?);
}
