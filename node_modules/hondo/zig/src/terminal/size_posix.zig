const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const SizeError = error{
    NotTerminal,
    QueryFailed,
    InvalidSize,
};

pub fn query(output_fd: i32) SizeError!Size {
    if (c.isatty(output_fd) != 1) return SizeError.NotTerminal;

    var window: c.struct_winsize = undefined;
    if (c.ioctl(output_fd, c.TIOCGWINSZ, &window) != 0) return SizeError.QueryFailed;
    if (window.ws_col == 0 or window.ws_row == 0) return SizeError.InvalidSize;

    return .{
        .width = @intCast(window.ws_col),
        .height = @intCast(window.ws_row),
    };
}
