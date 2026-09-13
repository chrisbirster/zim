const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const SessionError = error{
    NotTerminal,
    ReadAttributesFailed,
    EnterRawModeFailed,
    RestoreFailed,
};

pub const Session = struct {
    input_fd: c_int,
    original: c.struct_termios,
    active: bool = true,

    pub fn begin(input_fd: c_int, output_fd: c_int) SessionError!Session {
        if (c.isatty(input_fd) != 1 or c.isatty(output_fd) != 1) return SessionError.NotTerminal;

        var original: c.struct_termios = undefined;
        if (c.tcgetattr(input_fd, &original) != 0) return SessionError.ReadAttributesFailed;

        var raw = original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(input_fd, c.TCSAFLUSH, &raw) != 0) return SessionError.EnterRawModeFailed;

        return .{
            .input_fd = input_fd,
            .original = original,
        };
    }

    pub fn restore(self: *Session) SessionError!void {
        if (!self.active) return;
        self.active = false;
        if (c.tcsetattr(self.input_fd, c.TCSAFLUSH, &self.original) != 0) {
            return SessionError.RestoreFailed;
        }
    }
};

pub fn isTerminal(fd: c_int) bool {
    return c.isatty(fd) == 1;
}
