const c = @cImport({
    @cInclude("windows.h");
    @cInclude("io.h");
});

pub const SessionError = error{
    NotTerminal,
    InvalidHandle,
    ReadModeFailed,
    EnterRawModeFailed,
    RestoreFailed,
};

pub const Session = struct {
    input_handle: c.HANDLE,
    output_handle: c.HANDLE,
    original_input_mode: c.DWORD,
    original_output_mode: c.DWORD,
    active: bool = true,

    pub fn begin(input_fd: c_int, output_fd: c_int) SessionError!Session {
        const input_handle = handleForFd(input_fd) catch return SessionError.NotTerminal;
        const output_handle = handleForFd(output_fd) catch return SessionError.NotTerminal;

        // The CRT's _isatty() is not authoritative for modern Windows terminal
        // attachment. In particular, a process attached through ConPTY can have
        // valid console handles while the CRT descriptor is reported as non-TTY.
        // Query the Win32 console mode directly instead.
        var original_input_mode: c.DWORD = 0;
        var original_output_mode: c.DWORD = 0;
        if (c.GetConsoleMode(input_handle, &original_input_mode) == 0) return SessionError.NotTerminal;
        if (c.GetConsoleMode(output_handle, &original_output_mode) == 0) return SessionError.NotTerminal;

        var raw_input_mode = original_input_mode;
        raw_input_mode &= ~@as(c.DWORD, c.ENABLE_ECHO_INPUT | c.ENABLE_LINE_INPUT | c.ENABLE_PROCESSED_INPUT);
        // Keep ENABLE_WINDOW_INPUT if the terminal supplied it. ConPTY uses the
        // resulting WINDOW_BUFFER_SIZE_EVENT as part of resize propagation; the
        // Windows wait layer drains that record before handing character input
        // to the existing VT byte decoder.
        raw_input_mode |= c.ENABLE_VIRTUAL_TERMINAL_INPUT;
        if (c.SetConsoleMode(input_handle, raw_input_mode) == 0) return SessionError.EnterRawModeFailed;

        const vt_output_mode = original_output_mode | c.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        if (c.SetConsoleMode(output_handle, vt_output_mode) == 0) {
            _ = c.SetConsoleMode(input_handle, original_input_mode);
            return SessionError.EnterRawModeFailed;
        }

        return .{
            .input_handle = input_handle,
            .output_handle = output_handle,
            .original_input_mode = original_input_mode,
            .original_output_mode = original_output_mode,
        };
    }

    pub fn restore(self: *Session) SessionError!void {
        if (!self.active) return;
        self.active = false;

        var failed = false;
        if (c.SetConsoleMode(self.input_handle, self.original_input_mode) == 0) failed = true;
        if (c.SetConsoleMode(self.output_handle, self.original_output_mode) == 0) failed = true;
        if (failed) return SessionError.RestoreFailed;
    }
};

pub fn isTerminal(fd: c_int) bool {
    const handle = handleForFd(fd) catch return false;
    var mode: c.DWORD = 0;
    return c.GetConsoleMode(handle, &mode) != 0;
}

fn handleForFd(fd: c_int) SessionError!c.HANDLE {
    const os_handle = c._get_osfhandle(fd);
    if (os_handle == -1) return SessionError.InvalidHandle;
    const handle: c.HANDLE = @ptrFromInt(@as(usize, @intCast(os_handle)));
    return handle;
}
