const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("io.h");
});

pub const IoError = error{
    ReadFailed,
    WriteFailed,
};

pub fn readByte(fd: c_int) IoError!?u8 {
    const os_handle = c._get_osfhandle(fd);
    if (os_handle == -1) return IoError.ReadFailed;
    const handle: c.HANDLE = @ptrFromInt(@as(usize, @intCast(os_handle)));

    var byte: u8 = 0;
    var read: c.DWORD = 0;
    if (c.ReadFile(handle, &byte, 1, &read, null) == 0) return IoError.ReadFailed;
    if (read == 0) return null;
    return byte;
}

pub fn writeAll(fd: c_int, bytes: []const u8) IoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const chunk: c_uint = @intCast(@min(remaining, std.math.maxInt(c_uint)));
        const result = c._write(fd, bytes.ptr + offset, chunk);
        if (result <= 0) return IoError.WriteFailed;
        offset += @intCast(result);
    }
}
