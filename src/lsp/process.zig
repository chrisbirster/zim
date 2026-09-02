const std = @import("std");

pub const Transport = struct {
    io: std.Io,
    child: ?std.process.Child = null,

    pub fn spawn(io: std.Io, argv: []const []const u8) !Transport {
        return .{
            .io = io,
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
            }),
        };
    }

    pub fn send(self: *Transport, bytes: []const u8) !void {
        if (self.child) |*child| {
            const stdin = child.stdin orelse return error.StdinClosed;
            try stdin.writeStreamingAll(self.io, bytes);
            return;
        }
        return error.ProcessNotRunning;
    }

    pub fn read(self: *Transport, buffer: []u8) !usize {
        if (self.child) |*child| {
            const stdout = child.stdout orelse return error.StdoutClosed;
            return stdout.readStreaming(self.io, &.{buffer});
        }
        return error.ProcessNotRunning;
    }

    pub fn closeInput(self: *Transport) void {
        if (self.child) |*child| {
            if (child.stdin) |stdin| {
                stdin.close(self.io);
                child.stdin = null;
            }
        }
    }

    pub fn wait(self: *Transport) !std.process.Child.Term {
        var child = self.child orelse return error.ProcessNotRunning;
        self.child = null;
        return child.wait(self.io);
    }

    pub fn kill(self: *Transport) void {
        var child = self.child orelse return;
        self.child = null;
        child.kill(self.io);
    }
};

test "native process transport spawns and captures Zig" {
    var transport = try Transport.spawn(std.testing.io, &.{ "zig", "version" });
    errdefer transport.kill();
    transport.closeInput();
    var buffer: [128]u8 = undefined;
    const count = transport.read(&buffer) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    const term = try transport.wait();
    const exit_code = switch (term) {
        .exited => |code| code,
        else => return error.UnexpectedTermination,
    };
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(count > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..count], "0.16") != null);
}
