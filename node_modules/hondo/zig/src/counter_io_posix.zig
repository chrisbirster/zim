const c = @cImport({
    @cInclude("unistd.h");
});

pub const IoError = error{
    ReadFailed,
    WriteFailed,
};

pub fn readByte(fd: c_int) IoError!?u8 {
    var byte: u8 = 0;
    const result = c.read(fd, &byte, 1);
    if (result == 1) return byte;
    if (result == 0) return null;
    return IoError.ReadFailed;
}

pub fn writeAll(fd: c_int, bytes: []const u8) IoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (result <= 0) return IoError.WriteFailed;
        offset += @intCast(result);
    }
}
