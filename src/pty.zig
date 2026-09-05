const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const c = if (is_windows) @cImport({
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("NTDDI_VERSION", "0x0A000006");
    @cInclude("windows.h");
    @cInclude("consoleapi.h");
}) else @cImport({
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const WindowsOutputState = if (is_windows) struct {
    mutex: std.Thread.Mutex = .{},
    storage: []u8,
    head: usize = 0,
    len: usize = 0,
    eof: bool = false,
    failed: bool = false,

    fn push(self: *@This(), bytes: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (bytes.len > self.storage.len - self.len) {
            self.failed = true;
            return false;
        }

        const tail = (self.head + self.len) % self.storage.len;
        const first = @min(bytes.len, self.storage.len - tail);
        @memcpy(self.storage[tail .. tail + first], bytes[0..first]);
        if (first < bytes.len) {
            @memcpy(self.storage[0 .. bytes.len - first], bytes[first..]);
        }
        self.len += bytes.len;
        return true;
    }

    fn pop(self: *@This(), buffer: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.failed) return error.PtyReadFailed;
        if (self.len == 0) return 0;

        const count = @min(buffer.len, self.len);
        const first = @min(count, self.storage.len - self.head);
        @memcpy(buffer[0..first], self.storage[self.head .. self.head + first]);
        if (first < count) {
            @memcpy(buffer[first..count], self.storage[0 .. count - first]);
        }
        self.head = (self.head + count) % self.storage.len;
        self.len -= count;
        return count;
    }

    fn finish(self: *@This(), failed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.eof = true;
        if (failed) self.failed = true;
    }
} else void;

const Native = if (is_windows) struct {
    process: c.HANDLE,
    input_write: c.HANDLE,
    output_read: c.HANDLE,
    output_state: *WindowsOutputState,
    output_thread: std.Thread,
    pseudo_console: c.HPCON,
} else struct {
    pid: std.posix.pid_t,
    master: std.Io.File,
};

pub const Dimensions = struct {
    columns: u16 = 80,
    rows: u16 = 24,
};

pub const SpawnOptions = struct {
    dimensions: Dimensions = .{},
};

pub const Session = struct {
    io: std.Io,
    native: Native,
    reaped: bool = false,
    closed: bool = false,

    pub fn supported() bool {
        return true;
    }

    pub fn spawn(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: SpawnOptions,
    ) !Session {
        if (argv.len == 0) return error.EmptyArgv;
        if (comptime is_windows) return spawnWindows(allocator, io, argv, options);

        const owned = try allocator.alloc([:0]u8, argv.len);
        defer allocator.free(owned);
        var owned_count: usize = 0;
        defer for (owned[0..owned_count]) |arg| allocator.free(arg);

        const c_argv = try allocator.alloc(?[*:0]u8, argv.len + 1);
        defer allocator.free(c_argv);
        for (argv, 0..) |arg, index| {
            owned[index] = try allocator.dupeZ(u8, arg);
            owned_count += 1;
            c_argv[index] = owned[index].ptr;
        }
        c_argv[argv.len] = null;

        var master_fd: c_int = -1;
        var winsize = c.struct_winsize{
            .ws_row = options.dimensions.rows,
            .ws_col = options.dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const pid = forkpty(&master_fd, null, null, &winsize);
        if (pid < 0) return error.PtySpawnFailed;
        if (pid == 0) {
            _ = c.execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
            c._exit(127);
        }

        return .{
            .io = io,
            .native = .{
                .pid = @intCast(pid),
                .master = .{
                    .handle = @intCast(master_fd),
                    .flags = .{ .nonblocking = false },
                },
            },
        };
    }

    pub fn read(self: *Session, buffer: []u8) !usize {
        if (self.closed or buffer.len == 0) return 0;
        if (comptime is_windows) return self.native.output_state.pop(buffer);
        return self.native.master.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            error.InputOutput => 0,
            else => return err,
        };
    }

    pub fn readAvailable(self: *Session, buffer: []u8) !usize {
        if (self.closed or buffer.len == 0) return 0;
        if (comptime is_windows) return self.native.output_state.pop(buffer);

        var descriptor = c.struct_pollfd{
            .fd = self.native.master.handle,
            .events = c.POLLIN,
            .revents = 0,
        };
        const ready = c.poll(&descriptor, 1, 0);
        if (ready < 0) return error.PtyPollFailed;
        if (ready == 0) return 0;
        if ((descriptor.revents & (c.POLLIN | c.POLLHUP)) == 0) return 0;
        return self.read(buffer);
    }

    pub fn write(self: *Session, bytes: []const u8) !void {
        if (self.closed) return error.PtyClosed;
        if (comptime is_windows) return writeWindows(self.native.input_write, bytes);
        try self.native.master.writeStreamingAll(self.io, bytes);
    }

    pub fn resize(self: *Session, dimensions: Dimensions) !void {
        if (self.closed) return error.PtyClosed;
        if (comptime is_windows) {
            const size = windowsCoord(dimensions);
            if (c.ResizePseudoConsole(self.native.pseudo_console, size) < 0) return error.PtyResizeFailed;
            return;
        }

        var winsize = c.struct_winsize{
            .ws_row = dimensions.rows,
            .ws_col = dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.native.master.handle, c.TIOCSWINSZ, &winsize) != 0) return error.PtyResizeFailed;
    }

    pub fn terminate(self: *Session) !void {
        if (self.reaped) return;
        if (comptime is_windows) {
            if (c.TerminateProcess(self.native.process, 1) == 0) {
                const code = c.GetLastError();
                if (code == c.ERROR_ACCESS_DENIED and try self.exited()) return;
                return error.PtyTerminateFailed;
            }
            return;
        }

        std.posix.kill(self.native.pid, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
    }

    pub fn exited(self: *Session) !bool {
        if (self.reaped) return true;
        if (comptime is_windows) {
            const result = c.WaitForSingleObject(self.native.process, 0);
            if (result == c.WAIT_OBJECT_0) {
                self.reaped = true;
                return true;
            }
            if (result == c.WAIT_TIMEOUT) return false;
            return error.PtyWaitFailed;
        }

        var status: c_int = 0;
        const result = c.waitpid(self.native.pid, &status, c.WNOHANG);
        if (result < 0) return error.PtyWaitFailed;
        if (result == 0) return false;
        self.reaped = true;
        return true;
    }

    pub fn wait(self: *Session) !void {
        if (self.reaped) return;
        if (comptime is_windows) {
            if (c.WaitForSingleObject(self.native.process, c.INFINITE) != c.WAIT_OBJECT_0) return error.PtyWaitFailed;
            self.reaped = true;
            return;
        }

        var status: c_int = 0;
        if (c.waitpid(self.native.pid, &status, 0) < 0) return error.PtyWaitFailed;
        self.reaped = true;
    }

    pub fn deinit(self: *Session) void {
        if (comptime is_windows) {
            if (!self.reaped) self.terminate() catch {};
            if (!self.closed) {
                _ = c.CloseHandle(self.native.input_write);
                c.ClosePseudoConsole(self.native.pseudo_console);
                _ = c.CancelSynchronousIo(self.native.output_thread.getHandle());
                self.native.output_thread.join();
                _ = c.CloseHandle(self.native.output_read);
                std.heap.page_allocator.free(self.native.output_state.storage);
                std.heap.page_allocator.destroy(self.native.output_state);
                self.closed = true;
            }
            _ = c.CloseHandle(self.native.process);
            self.* = undefined;
            return;
        }

        if (!self.reaped) {
            self.terminate() catch {};
            var status: c_int = 0;
            _ = c.waitpid(self.native.pid, &status, 0);
            self.reaped = true;
        }
        if (!self.closed) {
            self.native.master.close(self.io);
            self.closed = true;
        }
        self.* = undefined;
    }
};

fn spawnWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: SpawnOptions,
) !Session {
    var input_read: c.HANDLE = null;
    var input_write: c.HANDLE = null;
    var output_read: c.HANDLE = null;
    var output_write: c.HANDLE = null;

    if (c.CreatePipe(&input_read, &input_write, null, 0) == 0) return error.PtyPipeFailed;
    errdefer {
        if (input_read != null) _ = c.CloseHandle(input_read);
        if (input_write != null) _ = c.CloseHandle(input_write);
    }
    if (c.CreatePipe(&output_read, &output_write, null, 0) == 0) return error.PtyPipeFailed;
    errdefer {
        if (output_read != null) _ = c.CloseHandle(output_read);
        if (output_write != null) _ = c.CloseHandle(output_write);
    }

    var pseudo_console: c.HPCON = undefined;
    if (c.CreatePseudoConsole(windowsCoord(options.dimensions), input_read, output_write, 0, &pseudo_console) < 0) {
        return error.PtySpawnFailed;
    }
    errdefer {
        if (input_write != null) {
            _ = c.CloseHandle(input_write);
            input_write = null;
        }
        if (output_read != null) {
            _ = c.CloseHandle(output_read);
            output_read = null;
        }
        c.ClosePseudoConsole(pseudo_console);
    }

    _ = c.CloseHandle(input_read);
    input_read = null;
    _ = c.CloseHandle(output_write);
    output_write = null;

    var attribute_size: c.SIZE_T = 0;
    _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
    if (attribute_size == 0) return error.PtySpawnFailed;
    const attribute_bytes = try allocator.alignedAlloc(u8, .of(usize), attribute_size);
    defer allocator.free(attribute_bytes);
    const attribute_list: c.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(@alignCast(attribute_bytes.ptr));
    if (c.InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size) == 0) return error.PtySpawnFailed;
    defer c.DeleteProcThreadAttributeList(attribute_list);

    if (c.UpdateProcThreadAttribute(
        attribute_list,
        0,
        c.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        @sizeOf(c.HPCON),
        null,
        null,
    ) == 0) return error.PtySpawnFailed;

    var startup = std.mem.zeroes(c.STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    startup.lpAttributeList = attribute_list;
    var process_info = std.mem.zeroes(c.PROCESS_INFORMATION);
    const command_line = try windowsCommandLineAlloc(allocator, argv);
    defer allocator.free(command_line);

    if (c.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        c.FALSE,
        c.EXTENDED_STARTUPINFO_PRESENT,
        null,
        null,
        &startup.StartupInfo,
        &process_info,
    ) == 0) return error.PtySpawnFailed;
    errdefer {
        _ = c.TerminateProcess(process_info.hProcess, 1);
        _ = c.CloseHandle(process_info.hProcess);
    }
    _ = c.CloseHandle(process_info.hThread);

    const output_state = try std.heap.page_allocator.create(WindowsOutputState);
    errdefer std.heap.page_allocator.destroy(output_state);
    const output_storage = try std.heap.page_allocator.alloc(u8, 1024 * 1024);
    errdefer std.heap.page_allocator.free(output_storage);
    output_state.* = .{ .storage = output_storage };
    const output_thread = std.Thread.spawn(.{}, windowsOutputReader, .{ output_state, output_read }) catch {
        return error.PtySpawnFailed;
    };

    return .{
        .io = io,
        .native = .{
            .process = process_info.hProcess,
            .input_write = input_write,
            .output_read = output_read,
            .output_state = output_state,
            .output_thread = output_thread,
            .pseudo_console = pseudo_console,
        },
    };
}

fn windowsOutputReader(state: *WindowsOutputState, handle: c.HANDLE) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        var read_count: c.DWORD = 0;
        if (c.ReadFile(handle, &buffer, @intCast(buffer.len), &read_count, null) == 0) {
            const code = c.GetLastError();
            state.finish(code != c.ERROR_BROKEN_PIPE and code != c.ERROR_OPERATION_ABORTED);
            return;
        }
        if (read_count == 0) {
            state.finish(false);
            return;
        }
        if (!state.push(buffer[0..read_count])) {
            return;
        }
    }
}

fn writeWindows(handle: c.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: c.DWORD = 0;
        const count: c.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(handle, bytes[offset..].ptr, count, &written, null) == 0) return error.PtyWriteFailed;
        if (written == 0) return error.PtyWriteFailed;
        offset += written;
    }
}

fn windowsCoord(dimensions: Dimensions) c.COORD {
    const max_short: u16 = @intCast(std.math.maxInt(c.SHORT));
    return .{
        .X = @intCast(@max(@as(u16, 1), @min(dimensions.columns, max_short))),
        .Y = @intCast(@max(@as(u16, 1), @min(dimensions.rows, max_short))),
    };
}

fn windowsCommandLineAlloc(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (argv, 0..) |arg, index| {
        if (index != 0) try buffer.append(allocator, ' ');
        var needs_quotes = arg.len == 0;
        for (arg) |byte| {
            if (byte <= ' ' or byte == '"') needs_quotes = true;
            if (index == 0 and byte == '"') return error.InvalidArg0;
        }
        if (!needs_quotes) {
            try buffer.appendSlice(allocator, arg);
            continue;
        }

        try buffer.append(allocator, '"');
        var backslashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                backslashes += 1;
                continue;
            }
            if (byte == '"') {
                try appendByteNTimes(&buffer, allocator, '\\', backslashes * 2 + 1);
                try buffer.append(allocator, '"');
                backslashes = 0;
                continue;
            }
            try appendByteNTimes(&buffer, allocator, '\\', backslashes);
            backslashes = 0;
            try buffer.append(allocator, byte);
        }
        try appendByteNTimes(&buffer, allocator, '\\', backslashes * 2);
        try buffer.append(allocator, '"');
    }

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, buffer.items);
}

fn appendByteNTimes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8, count: usize) !void {
    for (0..count) |_| try list.append(allocator, byte);
}

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const if (is_windows) anyopaque else c.struct_winsize,
) c_int;

fn collectUntilExit(session: *Session, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    var buffer: [1024]u8 = undefined;
    var attempts: usize = 0;
    var idle_after_exit: usize = 0;

    while (attempts < 5000) : (attempts += 1) {
        var drained = false;
        var drains: usize = 0;
        while (drains < 64) : (drains += 1) {
            const n = try session.readAvailable(&buffer);
            if (n == 0) break;
            try output.appendSlice(allocator, buffer[0..n]);
            drained = true;
        }

        const done = try session.exited();
        if (done) {
            if (drained) {
                idle_after_exit = 0;
            } else {
                idle_after_exit += 1;
                if (idle_after_exit >= 50) return;
            }
        }
        session.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.PtyTestTimeout;
}

test "PTY platform boundary is explicit" {
    try std.testing.expect(Session.supported());
}

test "PTY runs a child with terminal semantics" {
    var session = try Session.spawn(std.testing.allocator, std.testing.io, &.{ "zig", "version" }, .{ .dimensions = .{ .columns = 100, .rows = 30 } });
    defer session.deinit();
    try session.resize(.{ .columns = 120, .rows = 40 });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try collectUntilExit(&session, std.testing.allocator, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "0.16") != null);
}

test "PTY exposes nonblocking output and exit polling" {
    var session = try Session.spawn(std.testing.allocator, std.testing.io, &.{ "zig", "version" }, .{});
    defer session.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try collectUntilExit(&session, std.testing.allocator, &output);

    try std.testing.expect(try session.exited());
    try std.testing.expect(std.mem.indexOf(u8, output.items, "0.16") != null);
}
