const std = @import("std");
const builtin = @import("builtin");
const api_module = @import("api.zig");
const editor_module = @import("editor.zig");
const terminal = @import("terminal.zig");
const terminal_screen = @import("terminal_screen.zig");

const is_windows = builtin.os.tag == .windows;

pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    manager: terminal.Manager,
    active_id: ?terminal.TerminalId = null,
    screen_state: ?terminal_screen.Screen = null,
    visible: bool = false,
    processed_output_len: usize = 0,
    columns: u16 = 80,
    rows: u16 = 24,
    registered: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) Controller {
        return .{
            .allocator = allocator,
            .io = io,
            .environment = environment,
            .manager = terminal.Manager.init(allocator, io),
        };
    }

    pub fn register(self: *Controller, api: *api_module.Api) !void {
        if (self.registered) return;
        _ = try api.commandCreate("terminal", "open or reattach the native terminal", terminalCommand, self);
        self.registered = true;
    }

    pub fn deinit(self: *Controller, api: *api_module.Api) void {
        if (self.registered) _ = api.commandDelete("terminal");
        if (self.screen_state) |*screen_value| screen_value.deinit();
        self.manager.deinit();
        self.* = undefined;
    }

    pub fn supported(self: *const Controller) bool {
        _ = self;
        return terminal.Manager.supported();
    }

    pub fn isVisible(self: *const Controller) bool {
        return self.visible and self.active_id != null and self.screen_state != null;
    }

    pub fn activeId(self: *const Controller) ?terminal.TerminalId {
        return self.active_id;
    }

    pub fn screen(self: *const Controller) ?*const terminal_screen.Screen {
        if (!self.isVisible()) return null;
        if (self.screen_state) |*screen_value| return screen_value;
        return null;
    }

    pub fn snapshot(self: *const Controller) ?terminal.Snapshot {
        const id = self.active_id orelse return null;
        return self.manager.snapshot(id);
    }

    pub fn open(self: *Controller, editor: *editor_module.Editor, command: []const u8) !void {
        if (!self.supported()) {
            setStatus(editor, "terminal: PTY unsupported on this platform");
            return error.PtyUnsupported;
        }

        const trimmed = std.mem.trim(u8, command, " \t");
        if (trimmed.len == 0 and self.active_id != null) {
            self.visible = true;
            setStatus(editor, "terminal: reattached (Esc returns to editor)");
            return;
        }

        try self.discardActive();
        const shell = self.defaultShell();
        const id = if (trimmed.len == 0)
            try self.manager.start(&.{shell}, .{ .dimensions = self.dimensions() })
        else if (comptime is_windows)
            try self.manager.start(&.{ shell, "/d", "/s", "/c", trimmed }, .{ .dimensions = self.dimensions() })
        else
            try self.manager.start(&.{ shell, "-lc", trimmed }, .{ .dimensions = self.dimensions() });
        errdefer _ = self.manager.stop(id) catch false;

        var screen_state = try terminal_screen.Screen.init(self.allocator, self.columns, self.rows);
        errdefer screen_state.deinit();
        self.screen_state = screen_state;
        self.active_id = id;
        self.processed_output_len = 0;
        self.visible = true;
        setStatus(editor, "terminal: active (Esc returns to editor)");
    }

    pub fn poll(self: *Controller) !bool {
        const id = self.active_id orelse return false;
        var changed = try self.manager.poll(id);
        if (self.syncOutput(id)) changed = true;
        return changed;
    }

    pub fn waitActive(self: *Controller) !void {
        const id = self.active_id orelse return error.NoActiveTerminal;
        try self.manager.wait(id);
        _ = self.syncOutput(id);
    }

    pub fn input(self: *Controller, bytes: []const u8) !void {
        if (!self.isVisible()) return error.NoActiveTerminal;
        const id = self.active_id.?;
        const snap = self.manager.snapshot(id) orelse return error.UnknownTerminal;
        if (snap.status != .running) return error.TerminalNotRunning;
        try self.manager.input(id, bytes);
    }

    pub fn resize(self: *Controller, columns: usize, rows: usize) !bool {
        if (columns == 0 or rows == 0) return false;
        const new_columns: u16 = @intCast(@min(columns, std.math.maxInt(u16)));
        const new_rows: u16 = @intCast(@min(rows, std.math.maxInt(u16)));
        const size_changed = new_columns != self.columns or new_rows != self.rows;
        self.columns = new_columns;
        self.rows = new_rows;
        if (!size_changed) return false;

        var changed = false;
        if (self.screen_state) |*screen_state| {
            if (try screen_state.resize(new_columns, new_rows)) changed = true;
        }
        if (self.active_id) |id| {
            const snap = self.manager.snapshot(id);
            if (snap != null and snap.?.status == .running) {
                if (try self.manager.resize(id, self.dimensions())) changed = true;
            }
        }
        return changed;
    }

    pub fn hide(self: *Controller) void {
        self.visible = false;
    }

    pub fn stopActive(self: *Controller) !bool {
        const id = self.active_id orelse return false;
        const stopped = try self.manager.stop(id);
        _ = self.syncOutput(id);
        return stopped;
    }

    fn discardActive(self: *Controller) !void {
        if (self.active_id) |id| {
            if (self.manager.snapshot(id)) |snap| {
                if (snap.status == .running) _ = try self.manager.stop(id);
            }
        }
        if (self.screen_state) |*screen_state| screen_state.deinit();
        self.screen_state = null;
        self.active_id = null;
        self.visible = false;
        self.processed_output_len = 0;
    }

    fn syncOutput(self: *Controller, id: terminal.TerminalId) bool {
        const output = self.manager.output(id) orelse return false;
        if (self.processed_output_len > output.len) self.processed_output_len = 0;
        if (self.processed_output_len == output.len) return false;
        if (self.screen_state) |*screen_state| {
            screen_state.feed(output[self.processed_output_len..]);
        }
        self.processed_output_len = output.len;
        return true;
    }

    fn dimensions(self: *const Controller) @import("pty.zig").Dimensions {
        return .{ .columns = self.columns, .rows = self.rows };
    }

    fn defaultShell(self: *const Controller) []const u8 {
        if (comptime is_windows) return self.environment.get("COMSPEC") orelse "cmd.exe";
        return self.environment.get("SHELL") orelse "/bin/sh";
    }
};

fn terminalCommand(context: *api_module.commands.Context) !void {
    const self: *Controller = @ptrCast(@alignCast(context.user_data.?));
    self.open(context.editor, context.args) catch |err| {
        if (err != error.PtyUnsupported) setStatusFmt(context.editor, "terminal: {s}", .{@errorName(err)});
    };
}

fn setStatus(editor: *editor_module.Editor, message: []const u8) void {
    const len = @min(message.len, editor.status_buffer.len);
    @memcpy(editor.status_buffer[0..len], message[0..len]);
    editor.status_len = len;
}

fn setStatusFmt(editor: *editor_module.Editor, comptime format: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&editor.status_buffer, format, args) catch {
        setStatus(editor, "terminal: error");
        return;
    };
    editor.status_len = written.len;
}

test "terminal controller registers the public terminal command" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var controller = Controller.init(std.testing.allocator, std.testing.io, &environment);
    defer controller.deinit(&api);
    try controller.register(&api);
    try std.testing.expect(api.commands.find("terminal") != null);
}

test "terminal shell selection follows the native platform" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("SHELL", "/test/shell");
    try environment.put("COMSPEC", "C:\\test\\cmd.exe");
    var controller = Controller.init(std.testing.allocator, std.testing.io, &environment);
    defer controller.manager.deinit();

    if (comptime is_windows) {
        try std.testing.expectEqualStrings("C:\\test\\cmd.exe", controller.defaultShell());
    } else {
        try std.testing.expectEqualStrings("/test/shell", controller.defaultShell());
    }
}
