const std = @import("std");

const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cInclude("windows.h");
});

pub const local_kind = "windows-named-pipe";

pub const StdioStream = struct {
    input: c.HANDLE,
    output: c.HANDLE,

    pub fn init() !StdioStream {
        const input = c.GetStdHandle(c.STD_INPUT_HANDLE);
        const output = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
        if (input == null or input == c.INVALID_HANDLE_VALUE) return error.RpcStdinUnavailable;
        if (output == null or output == c.INVALID_HANDLE_VALUE) return error.RpcStdoutUnavailable;
        return .{ .input = input, .output = output };
    }

    pub fn read(self: *StdioStream, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        var read_count: c.DWORD = 0;
        const size: c.DWORD = @intCast(@min(buffer.len, std.math.maxInt(c.DWORD)));
        if (c.ReadFile(self.input, buffer.ptr, size, &read_count, null) == 0) {
            if (c.GetLastError() == c.ERROR_BROKEN_PIPE) return 0;
            return error.RpcReadFailed;
        }
        return @intCast(read_count);
    }

    pub fn writeAll(self: *StdioStream, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: c.DWORD = 0;
            const size: c.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(c.DWORD)));
            if (c.WriteFile(self.output, bytes.ptr + offset, size, &written, null) == 0 or written == 0) return error.RpcWriteFailed;
            offset += @intCast(written);
        }
    }
};

pub const LocalEndpoint = struct {
    allocator: std.mem.Allocator,
    handle: c.HANDLE,
    connected_flag: bool = false,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !LocalEndpoint {
        const full_name = try pipeNameAlloc(allocator, endpoint);
        defer allocator.free(full_name);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, full_name);
        defer allocator.free(wide);

        const handle = c.CreateNamedPipeW(
            wide.ptr,
            c.PIPE_ACCESS_DUPLEX,
            c.PIPE_TYPE_BYTE | c.PIPE_READMODE_BYTE | c.PIPE_NOWAIT,
            1,
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (handle == c.INVALID_HANDLE_VALUE) return error.RpcPipeCreateFailed;
        return .{ .allocator = allocator, .handle = handle };
    }

    pub fn deinit(self: *LocalEndpoint) void {
        self.disconnect();
        _ = c.CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn connected(self: *const LocalEndpoint) bool {
        return self.connected_flag;
    }

    pub fn pollAccept(self: *LocalEndpoint) !bool {
        if (self.connected_flag) return false;
        if (c.ConnectNamedPipe(self.handle, null) != 0) {
            self.connected_flag = true;
            return true;
        }
        const code = c.GetLastError();
        if (code == c.ERROR_PIPE_CONNECTED) {
            self.connected_flag = true;
            return true;
        }
        if (code == c.ERROR_PIPE_LISTENING or code == c.ERROR_NO_DATA) return false;
        return error.RpcPipeConnectFailed;
    }

    pub fn readAvailable(self: *LocalEndpoint, buffer: []u8) !ReadResult {
        if (!self.connected_flag or buffer.len == 0) return .{};
        var read_count: c.DWORD = 0;
        const size: c.DWORD = @intCast(@min(buffer.len, std.math.maxInt(c.DWORD)));
        if (c.ReadFile(self.handle, buffer.ptr, size, &read_count, null) != 0) return .{ .count = @intCast(read_count) };
        const code = c.GetLastError();
        if (code == c.ERROR_NO_DATA or code == c.ERROR_PIPE_LISTENING) return .{};
        if (code == c.ERROR_BROKEN_PIPE) {
            self.disconnect();
            return .{ .disconnected = true };
        }
        return error.RpcPipeReadFailed;
    }

    pub fn writeAvailable(self: *LocalEndpoint, bytes: []const u8) !usize {
        if (!self.connected_flag or bytes.len == 0) return 0;
        var written: c.DWORD = 0;
        const size: c.DWORD = @intCast(@min(bytes.len, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(self.handle, bytes.ptr, size, &written, null) != 0) return @intCast(written);
        const code = c.GetLastError();
        if (code == c.ERROR_NO_DATA or code == c.ERROR_PIPE_LISTENING) return 0;
        if (code == c.ERROR_BROKEN_PIPE) {
            self.disconnect();
            return 0;
        }
        return error.RpcPipeWriteFailed;
    }

    pub fn disconnect(self: *LocalEndpoint) void {
        if (!self.connected_flag) return;
        _ = c.FlushFileBuffers(self.handle);
        _ = c.DisconnectNamedPipe(self.handle);
        self.connected_flag = false;
    }
};

pub const ReadResult = struct {
    count: usize = 0,
    disconnected: bool = false,
};

pub fn sleepOneMs() void {
    c.Sleep(1);
}

pub fn pipeNameAlloc(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    if (endpoint.len == 0) return error.EmptyRpcEndpoint;
    if (std.mem.startsWith(u8, endpoint, "\\\\.\\pipe\\")) return allocator.dupe(u8, endpoint);
    return std.fmt.allocPrint(allocator, "\\\\.\\pipe\\{s}", .{endpoint});
}

test "Windows local endpoint names are normalized to the named-pipe namespace" {
    const name = try pipeNameAlloc(std.testing.allocator, "zim-test");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\zim-test", name);
}
