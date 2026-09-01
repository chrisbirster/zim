const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows)
    @import("terminal_io_windows.zig")
else
    @import("terminal_io_posix.zig");

pub const IoError = platform.IoError;
pub const readByte = platform.readByte;
pub const writeAll = platform.writeAll;

pub const stdin_fd: c_int = 0;
pub const stdout_fd: c_int = 1;
