const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const posix_c = if (is_windows) struct {} else @cImport({
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const win = struct {
    const HPCON = windows.HANDLE;
    const STARTUPINFOEXW = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
    const EXTENDED_STARTUPINFO_PRESENT: windows.CreateProcessFlags = @bitCast(@as(windows.DWORD, 0x00080000));

    extern "kernel32" fn CreatePipe(
        hReadPipe: *windows.HANDLE,
        hWritePipe: *windows.HANDLE,
        lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
        nSize: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreatePseudoConsole(
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        flags: windows.DWORD,
        phPC: *HPCON,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(
        lpAttributeList: ?*anyopaque,
        dwAttributeCount: windows.DWORD,
        dwFlags: windows.DWORD,
        lpSize: *usize,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(
        lpAttributeList: *anyopaque,
        dwFlags: windows.DWORD,
        attribute: usize,
        lpValue: ?*anyopaque,
        cbSize: usize,
        lpPreviousValue: ?*anyopaque,
        lpReturnSize: ?*usize,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?windows.LPCWSTR,
        lpCommandLine: ?windows.LPWSTR,
        lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
        bInheritHandles: windows.BOOL,
        dwCreationFlags: windows.CreateProcessFlags,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?windows.LPCWSTR,
        lpStartupInfo: *windows.STARTUPINFOW,
        lpProcessInformation: *windows.PROCESS_INFORMATION,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadFile(
        hFile: windows.HANDLE,
        lpBuffer: windows.LPVOID,
        nNumberOfBytesToRead: windows.DWORD,
        lpNumberOfBytesRead: ?*windows.DWORD,
        lpOverlapped: ?*windows.OVERLAPPED,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(
        hFile: windows.HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: windows.DWORD,
        lpNumberOfBytesWritten: ?*windows.DWORD,
        lpOverlapped: ?*windows.OVERLAPPED,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CancelSynchronousIo(hThread: windows.HANDLE) callconv(.winapi) windows.BOOL;
};

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
    process: windows.HANDLE,
    input_write: windows.HANDLE,
    output_read: windows.HANDLE,
    output_state: *WindowsOutputState,
    output_thread: std.Thread,
    pseudo_console: win.HPCON,
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
        var winsize = posix_c.struct_winsize{
            .ws_row = options.dimensions.rows,
            .ws_col = options.dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        const pid = forkpty(&master_fd, null, null, &winsize);
        if (pid < 0) return error.PtySpawnFailed;
        if (pid == 0) {
            _ = posix_c.execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
            posix_c._exit(127);
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

        var descriptor = posix_c.struct_pollfd{
            .fd = self.native.master.handle,
            .events = posix_c.POLLIN,
            .revents = 0,
        };
        const ready = posix_c.poll(&descriptor, 1, 0);
        if (ready < 0) return error.PtyPollFailed;
        if (ready == 0) return 0;
        if ((descriptor.revents & (posix_c.POLLIN | posix_c.POLLHUP)) == 0) return 0;
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
            if (win.ResizePseudoConsole(self.native.pseudo_console, windowsCoord(dimensions)) < 0) return error.PtyResizeFailed;
            return;
        }

        var winsize = posix_c.struct_winsize{
            .ws_row = dimensions.rows,
            .ws_col = dimensions.columns,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (posix_c.ioctl(self.native.master.handle, posix_c.TIOCSWINSZ, &winsize) != 0) return error.PtyResizeFailed;
    }

    pub fn terminate(self: *Session) !void {
        if (self.reaped) return;
        if (comptime is_windows) {
            if (win.TerminateProcess(self.native.process, 1) == 0) {
                const code = windows.GetLastError();
                if (code == .ACCESS_DENIED and try self.exited()) return;
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
            const result = win.WaitForSingleObject(self.native.process, 0);
            if (result == windows.WAIT_OBJECT_0) {
                self.reaped = true;
                return true;
            }
            if (result == windows.WAIT_TIMEOUT) return false;
            return error.PtyWaitFailed;
        }

        var status: c_int = 0;
        const result = posix_c.waitpid(self.native.pid, &status, posix_c.WNOHANG);
        if (result < 0) return error.PtyWaitFailed;
        if (result == 0) return false;
        self.reaped = true;
        return true;
    }

    pub fn wait(self: *Session) !void {
        if (self.reaped) return;
        if (comptime is_windows) {
            if (win.WaitForSingleObject(self.native.process, windows.INFINITE) != windows.WAIT_OBJECT_0) return error.PtyWaitFailed;
            self.reaped = true;
            return;
        }

        var status: c_int = 0;
        if (posix_c.waitpid(self.native.pid, &status, 0) < 0) return error.PtyWaitFailed;
        self.reaped = true;
    }

    pub fn deinit(self: *Session) void {
        if (comptime is_windows) {
            if (!self.reaped) self.terminate() catch {};
            if (!self.closed) {
                _ = win.CloseHandle(self.native.input_write);
                win.ClosePseudoConsole(self.native.pseudo_console);
                _ = win.CancelSynchronousIo(self.native.output_thread.getHandle());
                self.native.output_thread.join();
                _ = win.CloseHandle(self.native.output_read);
                std.heap.page_allocator.free(self.native.output_state.storage);
                std.heap.page_allocator.destroy(self.native.output_state);
                self.closed = true;
            }
            _ = win.CloseHandle(self.native.process);
            self.* = undefined;
            return;
        }

        if (!self.reaped) {
            self.terminate() catch {};
            var status: c_int = 0;
            _ = posix_c.waitpid(self.native.pid, &status, 0);
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
    var input_read: windows.HANDLE = undefined;
    var input_write: windows.HANDLE = undefined;
    if (win.CreatePipe(&input_read, &input_write, null, 0) == 0) return error.PtyPipeFailed;
    var input_read_open = true;
    errdefer if (input_read_open) _ = win.CloseHandle(input_read);
    errdefer _ = win.CloseHandle(input_write);

    var output_read: windows.HANDLE = undefined;
    var output_write: windows.HANDLE = undefined;
    if (win.CreatePipe(&output_read, &output_write, null, 0) == 0) return error.PtyPipeFailed;
    var output_write_open = true;
    errdefer _ = win.CloseHandle(output_read);
    errdefer if (output_write_open) _ = win.CloseHandle(output_write);

    var pseudo_console: win.HPCON = undefined;
    if (win.CreatePseudoConsole(windowsCoord(options.dimensions), input_read, output_write, 0, &pseudo_console) < 0) {
        return error.PtySpawnFailed;
    }
    errdefer {
        _ = win.CloseHandle(input_write);
        _ = win.CloseHandle(output_read);
        win.ClosePseudoConsole(pseudo_console);
    }

    _ = win.CloseHandle(input_read);
    input_read_open = false;
    _ = win.CloseHandle(output_write);
    output_write_open = false;

    var attribute_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
    if (attribute_size == 0) return error.PtySpawnFailed;
    const attribute_bytes = try allocator.alignedAlloc(u8, .of(usize), attribute_size);
    defer allocator.free(attribute_bytes);
    const attribute_list: *anyopaque = @ptrCast(@alignCast(attribute_bytes.ptr));
    if (win.InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size) == 0) return error.PtySpawnFailed;
    defer win.DeleteProcThreadAttributeList(attribute_list);

    if (win.UpdateProcThreadAttribute(
        attribute_list,
        0,
        win.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        @sizeOf(win.HPCON),
        null,
        null,
    ) == 0) return error.PtySpawnFailed;

    var startup = std.mem.zeroes(win.STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
    startup.lpAttributeList = attribute_list;
    var process_info = std.mem.zeroes(windows.PROCESS_INFORMATION);
    const command_line = try windowsCommandLineAlloc(allocator, argv);
    defer allocator.free(command_line);

    if (win.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        windows.FALSE,
        win.EXTENDED_STARTUPINFO_PRESENT,
        null,
        null,
        &startup.StartupInfo,
        &process_info,
    ) == 0) return error.PtySpawnFailed;
    errdefer {
        _ = win.TerminateProcess(process_info.hProcess, 1);
        _ = win.CloseHandle(process_info.hProcess);
    }
    _ = win.CloseHandle(process_info.hThread);

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

fn windowsOutputReader(state: *WindowsOutputState, handle: windows.HANDLE) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        var read_count: windows.DWORD = 0;
        if (win.ReadFile(handle, @ptrCast(&buffer), @intCast(buffer.len), &read_count, null) == 0) {
            const code = windows.GetLastError();
            state.finish(code != .BROKEN_PIPE and code != .OPERATION_ABORTED);
            return;
        }
        if (read_count == 0) {
            state.finish(false);
            return;
        }
        if (!state.push(buffer[0..read_count])) return;
    }
}

fn writeWindows(handle: windows.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: windows.DWORD = 0;
        const count: windows.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(windows.DWORD)));
        if (win.WriteFile(handle, bytes[offset..].ptr, count, &written, null) == 0) return error.PtyWriteFailed;
        if (written == 0) return error.PtyWriteFailed;
        offset += written;
    }
}

fn windowsCoord(dimensions: Dimensions) windows.COORD {
    const max_short: u16 = @intCast(std.math.maxInt(i16));
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
    winp: ?*const if (is_windows) anyopaque else posix_c.struct_winsize,
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
