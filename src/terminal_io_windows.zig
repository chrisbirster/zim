const std = @import("std");

const windows = std.os.windows;

pub const IoError = error{ ReadFailed, WriteFailed };

fn standardHandle(fd: c_int) IoError!windows.HANDLE {
    const id: windows.DWORD = switch (fd) {
        0 => windows.STD_INPUT_HANDLE,
        1 => windows.STD_OUTPUT_HANDLE,
        2 => windows.STD_ERROR_HANDLE,
        else => return IoError.ReadFailed,
    };
    return windows.GetStdHandle(id) catch return IoError.ReadFailed;
}

pub fn readByte(fd: c_int) IoError!?u8 {
    const handle = try standardHandle(fd);
    var byte: [1]u8 = undefined;
    const count = windows.ReadFile(handle, &byte, null) catch return IoError.ReadFailed;
    if (count == 0) return null;
    return byte[0];
}

pub fn writeAll(fd: c_int, bytes: []const u8) IoError!void {
    const handle = standardHandle(fd) catch return IoError.WriteFailed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = windows.WriteFile(handle, bytes[offset..], null) catch return IoError.WriteFailed;
        if (written == 0) return IoError.WriteFailed;
        offset += written;
    }
}
