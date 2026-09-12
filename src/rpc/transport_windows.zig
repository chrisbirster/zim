const std = @import("std");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn FlushFileBuffers(hFile: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;

pub const local_kind = "windows-named-pipe";

pub const StdioStream = struct {
    input: windows.HANDLE,
    output: windows.HANDLE,

    pub fn init() !StdioStream {
        const input = GetStdHandle(windows.STD_INPUT_HANDLE) orelse return error.RpcStdinUnavailable;
        const output = GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return error.RpcStdoutUnavailable;
        if (input == windows.INVALID_HANDLE_VALUE) return error.RpcStdinUnavailable;
        if (output == windows.INVALID_HANDLE_VALUE) return error.RpcStdoutUnavailable;
        return .{ .input = input, .output = output };
    }

    pub fn read(self: *StdioStream, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        var read_count: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (kernel32.ReadFile(self.input, buffer.ptr, size, &read_count, null) == 0) {
            if (windows.GetLastError() == .BROKEN_PIPE) return 0;
            return error.RpcReadFailed;
        }
        return @intCast(read_count);
    }

    pub fn writeAll(self: *StdioStream, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: windows.DWORD = 0;
            const size: windows.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(windows.DWORD)));
            if (kernel32.WriteFile(self.output, bytes.ptr + offset, size, &written, null) == 0 or written == 0) return error.RpcWriteFailed;
            offset += @intCast(written);
        }
    }
};

pub const LocalEndpoint = struct {
    allocator: std.mem.Allocator,
    handle: windows.HANDLE,
    connected_flag: bool = false,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !LocalEndpoint {
        const full_name = try pipeNameAlloc(allocator, endpoint);
        defer allocator.free(full_name);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, full_name);
        defer allocator.free(wide);

        const handle = kernel32.CreateNamedPipeW(
            wide.ptr,
            windows.PIPE_ACCESS_DUPLEX,
            windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE | windows.PIPE_NOWAIT,
            1,
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.RpcPipeCreateFailed;
        return .{ .allocator = allocator, .handle = handle };
    }

    pub fn deinit(self: *LocalEndpoint) void {
        self.disconnect();
        windows.CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn connected(self: *const LocalEndpoint) bool {
        return self.connected_flag;
    }

    pub fn pollAccept(self: *LocalEndpoint) !bool {
        if (self.connected_flag) return false;
        if (kernel32.ConnectNamedPipe(self.handle, null) != 0) {
            self.connected_flag = true;
            return true;
        }
        const code = windows.GetLastError();
        if (code == .PIPE_CONNECTED) {
            self.connected_flag = true;
            return true;
        }
        if (code == .PIPE_LISTENING or code == .NO_DATA) return false;
        return error.RpcPipeConnectFailed;
    }

    pub fn readAvailable(self: *LocalEndpoint, buffer: []u8) !ReadResult {
        if (!self.connected_flag or buffer.len == 0) return .{};
        var read_count: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (kernel32.ReadFile(self.handle, buffer.ptr, size, &read_count, null) != 0) return .{ .count = @intCast(read_count) };
        const code = windows.GetLastError();
        if (code == .NO_DATA or code == .PIPE_LISTENING) return .{};
        if (code == .BROKEN_PIPE) {
            self.disconnect();
            return .{ .disconnected = true };
        }
        return error.RpcPipeReadFailed;
    }

    pub fn writeAvailable(self: *LocalEndpoint, bytes: []const u8) !usize {
        if (!self.connected_flag or bytes.len == 0) return 0;
        var written: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(bytes.len, std.math.maxInt(windows.DWORD)));
        if (kernel32.WriteFile(self.handle, bytes.ptr, size, &written, null) != 0) return @intCast(written);
        const code = windows.GetLastError();
        if (code == .NO_DATA or code == .PIPE_LISTENING) return 0;
        if (code == .BROKEN_PIPE) {
            self.disconnect();
            return 0;
        }
        return error.RpcPipeWriteFailed;
    }

    pub fn disconnect(self: *LocalEndpoint) void {
        if (!self.connected_flag) return;
        _ = FlushFileBuffers(self.handle);
        _ = kernel32.DisconnectNamedPipe(self.handle);
        self.connected_flag = false;
    }
};

pub const ReadResult = struct {
    count: usize = 0,
    disconnected: bool = false,
};

pub fn sleepOneMs() void {
    Sleep(1);
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
