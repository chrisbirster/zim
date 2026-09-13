const builtin = @import("builtin");

const platform = if (builtin.os.tag == .windows)
    @import("wait_windows.zig")
else
    @import("wait_posix.zig");

pub const WaitError = platform.WaitError;
pub const readable = platform.readable;
