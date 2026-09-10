const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const local_kind = "unix-domain-socket";

pub const StdioStream = struct {
    pub fn init() StdioStream {
        return .{};
    }

    pub fn read(self: *StdioStream, buffer: []u8) !usize {
        _ = self;
        const result = c.read(0, buffer.ptr, buffer.len);
        if (result < 0) return error.RpcReadFailed;
        return @intCast(result);
    }

    pub fn writeAll(self: *StdioStream, bytes: []const u8) !void {
        _ = self;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = c.write(1, bytes.ptr + offset, bytes.len - offset);
            if (result <= 0) return error.RpcWriteFailed;
            offset += @intCast(result);
        }
    }
};

pub const LocalEndpoint = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    listener_fd: c_int,
    client_fd: c_int = -1,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !LocalEndpoint {
        if (path.len == 0) return error.EmptyRpcEndpoint;
        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (path.len >= @sizeOf(@TypeOf(address.sun_path))) return error.RpcEndpointTooLong;
        address.sun_family = c.AF_UNIX;
        for (path, 0..) |byte, index| address.sun_path[index] = @bitCast(byte);

        const owned_path = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned_path);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.RpcSocketCreateFailed;
        errdefer _ = c.close(fd);
        _ = c.unlink(owned_path.ptr);
        if (c.bind(fd, @ptrCast(&address), @intCast(@sizeOf(c.struct_sockaddr_un))) != 0) return error.RpcSocketBindFailed;
        if (c.listen(fd, 1) != 0) return error.RpcSocketListenFailed;
        try setNonblocking(fd);

        return .{
            .allocator = allocator,
            .path = owned_path,
            .listener_fd = fd,
        };
    }

    pub fn deinit(self: *LocalEndpoint) void {
        self.disconnect();
        _ = c.close(self.listener_fd);
        _ = c.unlink(self.path.ptr);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn connected(self: *const LocalEndpoint) bool {
        return self.client_fd >= 0;
    }

    pub fn pollAccept(self: *LocalEndpoint) !bool {
        if (self.connected()) return false;
        const fd = c.accept(self.listener_fd, null, null);
        if (fd < 0) return false;
        errdefer _ = c.close(fd);
        try setNonblocking(fd);
        self.client_fd = fd;
        return true;
    }

    pub fn readAvailable(self: *LocalEndpoint, buffer: []u8) !ReadResult {
        if (!self.connected() or buffer.len == 0) return .{};
        const result = c.recv(self.client_fd, buffer.ptr, buffer.len, 0);
        if (result > 0) return .{ .count = @intCast(result) };
        if (result == 0) {
            self.disconnect();
            return .{ .disconnected = true };
        }
        return .{};
    }

    pub fn writeAvailable(self: *LocalEndpoint, bytes: []const u8) !usize {
        if (!self.connected() or bytes.len == 0) return 0;
        const result = c.send(self.client_fd, bytes.ptr, bytes.len, 0);
        if (result > 0) return @intCast(result);
        return 0;
    }

    pub fn disconnect(self: *LocalEndpoint) void {
        if (self.client_fd >= 0) {
            _ = c.close(self.client_fd);
            self.client_fd = -1;
        }
    }
};

pub const ReadResult = struct {
    count: usize = 0,
    disconnected: bool = false,
};

pub fn sleepOneMs() void {
    _ = c.usleep(1000);
}

fn setNonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return error.RpcSocketFlagsFailed;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.RpcSocketFlagsFailed;
}
