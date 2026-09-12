const std = @import("std");

const windows = std.os.windows;

const std_input_handle: windows.DWORD = 0xfffffff6;
const std_output_handle: windows.DWORD = 0xfffffff5;

const pipe_access_duplex: windows.DWORD = 0x00000003;
const pipe_type_byte: windows.DWORD = 0x00000000;
const pipe_readmode_byte: windows.DWORD = 0x00000000;
const pipe_nowait: windows.DWORD = 0x00000001;

const error_broken_pipe: windows.DWORD = 109;
const error_no_data: windows.DWORD = 232;
const error_pipe_connected: windows.DWORD = 535;
const error_pipe_listening: windows.DWORD = 536;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: windows.DWORD,
    dwPipeMode: windows.DWORD,
    nMaxInstances: windows.DWORD,
    nOutBufferSize: windows.DWORD,
    nInBufferSize: windows.DWORD,
    nDefaultTimeOut: windows.DWORD,
    lpSecurityAttributes: ?*const anyopaque,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FlushFileBuffers(hFile: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;

pub const local_kind = "windows-named-pipe";

pub const StdioStream = struct {
    input: windows.HANDLE,
    output: windows.HANDLE,

    pub fn init() !StdioStream {
        const input = GetStdHandle(std_input_handle) orelse return error.RpcStdinUnavailable;
        const output = GetStdHandle(std_output_handle) orelse return error.RpcStdoutUnavailable;
        if (input == windows.INVALID_HANDLE_VALUE) return error.RpcStdinUnavailable;
        if (output == windows.INVALID_HANDLE_VALUE) return error.RpcStdoutUnavailable;
        return .{ .input = input, .output = output };
    }

    pub fn read(self: *StdioStream, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        var read_count: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (ReadFile(self.input, buffer.ptr, size, &read_count, null) == 0) {
            if (GetLastError() == error_broken_pipe) return 0;
            return error.RpcReadFailed;
        }
        return @intCast(read_count);
    }

    pub fn writeAll(self: *StdioStream, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var written: windows.DWORD = 0;
            const size: windows.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(windows.DWORD)));
            if (WriteFile(self.output, bytes.ptr + offset, size, &written, null) == 0 or written == 0) return error.RpcWriteFailed;
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

        const handle = CreateNamedPipeW(
            wide.ptr,
            pipe_access_duplex,
            pipe_type_byte | pipe_readmode_byte | pipe_nowait,
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
        _ = CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn connected(self: *const LocalEndpoint) bool {
        return self.connected_flag;
    }

    pub fn pollAccept(self: *LocalEndpoint) !bool {
        if (self.connected_flag) return false;
        if (ConnectNamedPipe(self.handle, null) != 0) {
            self.connected_flag = true;
            return true;
        }
        const code = GetLastError();
        if (code == error_pipe_connected) {
            self.connected_flag = true;
            return true;
        }
        if (code == error_pipe_listening or code == error_no_data) return false;
        return error.RpcPipeConnectFailed;
    }

    pub fn readAvailable(self: *LocalEndpoint, buffer: []u8) !ReadResult {
        if (!self.connected_flag or buffer.len == 0) return .{};
        var read_count: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD)));
        if (ReadFile(self.handle, buffer.ptr, size, &read_count, null) != 0) return .{ .count = @intCast(read_count) };
        const code = GetLastError();
        if (code == error_no_data or code == error_pipe_listening) return .{};
        if (code == error_broken_pipe) {
            self.disconnect();
            return .{ .disconnected = true };
        }
        return error.RpcPipeReadFailed;
    }

    pub fn writeAvailable(self: *LocalEndpoint, bytes: []const u8) !usize {
        if (!self.connected_flag or bytes.len == 0) return 0;
        var written: windows.DWORD = 0;
        const size: windows.DWORD = @intCast(@min(bytes.len, std.math.maxInt(windows.DWORD)));
        if (WriteFile(self.handle, bytes.ptr, size, &written, null) != 0) return @intCast(written);
        const code = GetLastError();
        if (code == error_no_data or code == error_pipe_listening) return 0;
        if (code == error_broken_pipe) {
            self.disconnect();
            return 0;
        }
        return error.RpcPipeWriteFailed;
    }

    pub fn disconnect(self: *LocalEndpoint) void {
        if (!self.connected_flag) return;
        _ = FlushFileBuffers(self.handle);
        _ = DisconnectNamedPipe(self.handle);
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
