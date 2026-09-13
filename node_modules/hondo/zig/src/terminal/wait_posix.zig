const c = @cImport({
    @cInclude("poll.h");
});

pub const WaitError = error{
    WaitFailed,
};

pub fn readable(input_fd: i32, timeout_ms: u32) WaitError!bool {
    var descriptor = c.struct_pollfd{
        .fd = input_fd,
        .events = @intCast(c.POLLIN),
        .revents = 0,
    };
    const max_timeout: u32 = 2_147_483_647;
    const timeout: c_int = @intCast(@min(timeout_ms, max_timeout));
    const result = c.poll(&descriptor, 1, timeout);
    if (result < 0) return WaitError.WaitFailed;
    if (result == 0) return false;

    const readable_mask: @TypeOf(descriptor.revents) = @intCast(c.POLLIN | c.POLLHUP | c.POLLERR);
    return (descriptor.revents & readable_mask) != 0;
}
