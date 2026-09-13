const std = @import("std");

const windows = std.os.windows;

const std_input_handle: windows.DWORD = 0xfffffff6;
const std_output_handle: windows.DWORD = 0xfffffff5;
const std_error_handle: windows.DWORD = 0xfffffff4;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) c_int;

pub const IoError = error{ ReadFailed, WriteFailed };

fn standardHandle(fd: c_int) IoError!windows.HANDLE {
    const id: windows.DWORD = switch (fd) {
        0 => std_input_handle,
        1 => std_output_handle,
        2 => std_error_handle,
        else => return IoError.ReadFailed,
    };
    const handle = GetStdHandle(id) orelse return IoError.ReadFailed;
    if (handle == windows.INVALID_HANDLE_VALUE) return IoError.ReadFailed;
    return handle;
}

pub fn readByte(fd: c_int) IoError!?u8 {
    const handle = try standardHandle(fd);
    var byte: [1]u8 = undefined;
    var read_count: windows.DWORD = 0;
    if (ReadFile(handle, &byte, 1, &read_count, null) == 0) return IoError.ReadFailed;
    if (read_count == 0) return null;
    return byte[0];
}

pub fn writeAll(fd: c_int, bytes: []const u8) IoError!void {
    const handle = standardHandle(fd) catch return IoError.WriteFailed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: windows.DWORD = 0;
        const chunk: windows.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(windows.DWORD)));
        if (WriteFile(handle, bytes.ptr + offset, chunk, &written, null) == 0 or written == 0) return IoError.WriteFailed;
        offset += @intCast(written);
    }
}
