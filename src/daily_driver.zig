const std = @import("std");
const api_module = @import("api.zig");
const build_info = @import("build_info.zig");
const editor_module = @import("editor.zig");
const session = @import("session_recovery.zig");
const theme_module = @import("theme.zig");

const max_errors: usize = 32;

const ErrorEntry = struct {
    sequence: u64,
    message: []u8,

    fn deinit(self: *ErrorEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

const Topic = struct {
    name: []const u8,
    body: []const u8,
};

const topics = [_]Topic{
    .{ .name = "daily-driver", .body = "Zim 1.0 Daily Driver\n\n:Checkhealth       runtime diagnostics\n:Errors            recent recoverable errors\n:SessionSave       save the current workspace\n:SessionRestore    restore the last workspace\n:RecoveryWrite     checkpoint unsaved buffers\n:RecoveryRestore   restore a crash checkpoint\n:RecoveryDiscard   discard crash recovery\n:Colorscheme NAME  zim | mono | ember\n:Highlight ...     override a highlight group\n:Help TOPIC        open built-in help" },
    .{ .name = "recovery", .body = "Recovery\n\nZim checkpoints modified buffers atomically at stable editing boundaries. Insert-mode typing is not written on every keystroke; leaving insert mode creates a checkpoint. Normal-mode edits checkpoint after the command completes.\n\nUse :RecoveryRestore after an abnormal exit. Use :RecoveryDiscard to ignore the pending crash snapshot. Normal exits persist the full workspace as the last session." },
    .{ .name = "sessions", .body = "Sessions\n\nThe last clean session stores project root, buffers (including unsaved text), windows, tab pages, split layouts, cursors and scroll positions. Pins remain in their existing project-scoped persistent store and are reloaded after workspace restore.\n\n:SessionSave\n:SessionRestore" },
    .{ .name = "lua", .body = "Lua\n\nConfiguration lives in ~/.config/zim/init.lua (or the platform config root). The stable v1 namespace includes zim.opt, zim.keymap, zim.command, zim.autocmd, zim.buf, zim.win, zim.tab, zim.pin, zim.job, zim.extmark, zim.diagnostic, zim.ui, zim.lsp, zim.colorscheme and zim.highlight." },
    .{ .name = "plugins", .body = "Plugins\n\nUse :PackAdd, :PackUpdate, :PackRemove and :PackList. Plugin failures are isolated from the editor and incompatible plugin API versions are rejected. v1 keeps plugin API version 1 stable for the 1.x line." },
    .{ .name = "rpc", .body = "Remote plugins\n\nMessagePack-RPC remains local-only by default: stdio, Unix-domain sockets, and Windows named pipes. The v1 protocol/API versions remain 1. Clients must handshake before editor methods are available." },
    .{ .name = "jobs-terminal", .body = "Jobs + Terminal\n\n:JobStart, :JobStop and :JobList manage editor-owned asynchronous jobs. :terminal opens the native PTY/ConPTY terminal surface. External tool failures should be reported without terminating the editor process." },
    .{ .name = "pins", .body = "Pins\n\n:PinAdd, :PinRemove, :PinMove, :PinJump and :PinList provide project-persistent fast navigation. Pins are restored independently from the workspace session." },
    .{ .name = "themes", .body = "Themes\n\n:Colorscheme zim\n:Colorscheme mono\n:Colorscheme ember\n\nOverride a group with :Highlight, for example:\n:Highlight Keyword fg=13 bold\n:Highlight Comment fg=8 italic dim\n\nLua: zim.colorscheme('ember') and zim.highlight.set('Keyword', { fg = 13, bold = true })." },
    .{ .name = "compatibility", .body = "v1 compatibility\n\nZim follows semantic-version compatibility for its public Zig/Lua/RPC contracts. Public API version 1, plugin API version 1 and RPC API version 1 remain compatible throughout 1.x. Breaking public changes require a major-version decision." },
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *api_module.Api,
    editor: *editor_module.Editor,
    config_root: []u8,
    session_path: []u8,
    recovery_path: []u8,
    errors: std.ArrayList(ErrorEntry) = .empty,
    next_error_sequence: u64 = 1,
    pending_recovery: bool = false,
    text_autocmd: api_module.events.AutocmdId = 0,
    mode_autocmd: api_module.events.AutocmdId = 0,
    write_autocmd: api_module.events.AutocmdId = 0,
    leave_autocmd: api_module.events.AutocmdId = 0,
    theme: theme_module.Store,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_root: []const u8,
        api: *api_module.Api,
        editor: *editor_module.Editor,
    ) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const owned_root = try allocator.dupe(u8, config_root);
        errdefer allocator.free(owned_root);
        const state_root = try std.fmt.allocPrint(allocator, "{s}/state", .{config_root});
        defer allocator.free(state_root);
        try std.Io.Dir.cwd().createDirPath(io, state_root);
        const session_path = try std.fmt.allocPrint(allocator, "{s}/session.json", .{state_root});
        errdefer allocator.free(session_path);
        const recovery_path = try std.fmt.allocPrint(allocator, "{s}/recovery.json", .{state_root});
        errdefer allocator.free(recovery_path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .api = api,
            .editor = editor,
            .config_root = owned_root,
            .session_path = session_path,
            .recovery_path = recovery_path,
            .theme = theme_module.Store.init(allocator),
        };
        errdefer self.destroy();
        try self.theme.load("zim");
        theme_module.activate(&self.theme);
        try self.registerCommands();
        try self.registerAutocmds();

        if (session.fileDirty(allocator, io, recovery_path) catch |err| blk: {
            self.recordError("recovery probe", err);
            break :blk false;
        }) {
            self.setStatus("recovery available; use :RecoveryRestore");
        }
        return self;
    }

    pub fn destroy(self: *Service) void {
        const allocator = self.allocator;
        const command_names = [_][]const u8{
            "Help", "help", "Errors", "Checkhealth", "SessionSave", "SessionRestore",
            "RecoveryWrite", "RecoveryRestore", "RecoveryDiscard", "Colorscheme", "Highlight",
        };
        for (command_names) |name| _ = self.api.commandDelete(name);
        if (self.text_autocmd != 0) _ = self.api.autocmdDelete(self.text_autocmd);
        if (self.mode_autocmd != 0) _ = self.api.autocmdDelete(self.mode_autocmd);
        if (self.write_autocmd != 0) _ = self.api.autocmdDelete(self.write_autocmd);
        if (self.leave_autocmd != 0) _ = self.api.autocmdDelete(self.leave_autocmd);
        theme_module.deactivate(&self.theme);
        self.theme.deinit();
        for (self.errors.items) |*entry| entry.deinit(allocator);
        self.errors.deinit(allocator);
        allocator.free(self.config_root);
        allocator.free(self.session_path);
        allocator.free(self.recovery_path);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn restoreLastSession(self: *Service) bool {
        const restored = session.restoreFile(self.allocator, self.io, self.editor, self.session_path) catch |err| {
            self.recordError("session restore", err);
            return false;
        };
        if (!restored) return false;
        self.editor.configurePins(self.config_root) catch |err| self.recordError("pins restore", err);
        self.pending_recovery = anyModified(self.editor);
        self.setStatus("restored last Zim session");
        return true;
    }

    pub fn saveCleanState(self: *Service) !void {
        try session.writeAtomic(self.allocator, self.io, self.editor, self.session_path, false);
        try session.writeAtomic(self.allocator, self.io, self.editor, self.recovery_path, false);
        self.pending_recovery = false;
    }

    pub fn recordError(self: *Service, source: []const u8, err: anyerror) void {
        const message = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ source, @errorName(err) }) catch return;
        self.appendError(message);
    }

    pub fn recordMessage(self: *Service, source: []const u8, message: []const u8) void {
        const rendered = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ source, message }) catch return;
        self.appendError(rendered);
    }

    fn appendError(self: *Service, owned_message: []u8) void {
        if (self.errors.items.len >= max_errors) {
            var oldest = self.errors.items[0];
            oldest.deinit(self.allocator);
            std.mem.copyForwards(ErrorEntry, self.errors.items[0 .. self.errors.items.len - 1], self.errors.items[1..]);
            self.errors.items.len -= 1;
        }
        self.errors.append(self.allocator, .{
            .sequence = self.next_error_sequence,
            .message = owned_message,
        }) catch {
            self.allocator.free(owned_message);
            return;
        };
        self.next_error_sequence += 1;
        self.setStatus(owned_message);
    }

    fn registerCommands(self: *Service) !void {
        _ = try self.api.commandCreate("Help", "open built-in Zim help", helpCommand, self);
        _ = try self.api.commandCreate("help", "open built-in Zim help", helpCommand, self);
        _ = try self.api.commandCreate("Errors", "show recent recoverable errors", errorsCommand, self);
        _ = try self.api.commandCreate("Checkhealth", "show v1 runtime diagnostics", checkhealthCommand, self);
        _ = try self.api.commandCreate("SessionSave", "persist the current workspace session", sessionSaveCommand, self);
        _ = try self.api.commandCreate("SessionRestore", "restore the last workspace session", sessionRestoreCommand, self);
        _ = try self.api.commandCreate("RecoveryWrite", "write an atomic crash-recovery checkpoint", recoveryWriteCommand, self);
        _ = try self.api.commandCreate("RecoveryRestore", "restore the pending crash-recovery checkpoint", recoveryRestoreCommand, self);
        _ = try self.api.commandCreate("RecoveryDiscard", "discard the pending crash-recovery checkpoint", recoveryDiscardCommand, self);
        _ = try self.api.commandCreate("Colorscheme", "select a built-in colorscheme", colorschemeCommand, self);
        _ = try self.api.commandCreate("Highlight", "override a native highlight group", highlightCommand, self);
    }

    fn registerAutocmds(self: *Service) !void {
        self.text_autocmd = try self.api.autocmdCreate(.text_changed, .{}, textChanged, self);
        self.mode_autocmd = try self.api.autocmdCreate(.mode_changed, .{}, modeChanged, self);
        self.write_autocmd = try self.api.autocmdCreate(.buffer_write_post, .{}, bufferWritten, self);
        self.leave_autocmd = try self.api.autocmdCreate(.buffer_leave, .{}, bufferLeft, self);
    }

    fn checkpoint(self: *Service) void {
        const dirty = anyModified(self.editor);
        session.writeAtomic(self.allocator, self.io, self.editor, self.recovery_path, dirty) catch |err| {
            self.recordError("recovery checkpoint", err);
            return;
        };
        self.pending_recovery = false;
    }

    fn showHelp(self: *Service, query_raw: []const u8) !void {
        const query = std.mem.trim(u8, query_raw, " \t\r\n");
        if (query.len == 0) {
            var labels: [topics.len][]const u8 = undefined;
            for (topics, &labels) |topic, *label| label.* = topic.name;
            try self.editor.popupShow(.plugin, "Zim Help", &labels);
            self.setStatus(":Help <topic> · :Help commands · :Help keymaps");
            return;
        }
        if (std.ascii.eqlIgnoreCase(query, "commands")) return self.showCommands();
        if (std.ascii.eqlIgnoreCase(query, "keymaps")) return self.showKeymaps();
        for (topics) |topic| {
            if (std.ascii.eqlIgnoreCase(query, topic.name)) {
                var lines: std.ArrayList([]const u8) = .empty;
                defer lines.deinit(self.allocator);
                var split = std.mem.splitScalar(u8, topic.body, '\n');
                while (split.next()) |line| try lines.append(self.allocator, line);
                try self.editor.popupShow(.plugin, topic.name, lines.items);
                return;
            }
        }

        var matches: std.ArrayList([]const u8) = .empty;
        defer matches.deinit(self.allocator);
        for (topics) |topic| {
            if (containsIgnoreCase(topic.name, query)) try matches.append(self.allocator, topic.name);
        }
        if (matches.items.len == 0) {
            self.setStatus("help topic not found");
            return;
        }
        try self.editor.popupShow(.plugin, "Help matches", matches.items);
    }

    fn showCommands(self: *Service) !void {
        var labels: std.ArrayList([]u8) = .empty;
        defer {
            for (labels.items) |label| self.allocator.free(label);
            labels.deinit(self.allocator);
        }
        for (self.api.commands.entries.items) |entry| {
            try labels.append(self.allocator, try std.fmt.allocPrint(self.allocator, ":{s} — {s}", .{ entry.name, entry.description }));
        }
        const view = try self.allocator.alloc([]const u8, labels.items.len);
        defer self.allocator.free(view);
        for (labels.items, view) |label, *target| target.* = label;
        try self.editor.popupShow(.plugin, "Commands", view);
    }

    fn showKeymaps(self: *Service) !void {
        var labels: std.ArrayList([]u8) = .empty;
        defer {
            for (labels.items) |label| self.allocator.free(label);
            labels.deinit(self.allocator);
        }
        for (self.api.keymaps.entries.items) |entry| {
            try labels.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} U+{X:0>4} → U+{X:0>4}", .{ @tagName(entry.mode), entry.from, entry.to }));
        }
        if (labels.items.len == 0) {
            const empty = [_][]const u8{"No public keymap overrides are registered."};
            try self.editor.popupShow(.plugin, "Keymaps", &empty);
            return;
        }
        const view = try self.allocator.alloc([]const u8, labels.items.len);
        defer self.allocator.free(view);
        for (labels.items, view) |label, *target| target.* = label;
        try self.editor.popupShow(.plugin, "Keymaps", view);
    }

    fn showErrors(self: *Service) !void {
        if (self.errors.items.len == 0) {
            const labels = [_][]const u8{"No recoverable errors recorded in this session."};
            try self.editor.popupShow(.plugin, "Errors", &labels);
            return;
        }
        const labels = try self.allocator.alloc([]const u8, self.errors.items.len);
        defer self.allocator.free(labels);
        for (self.errors.items, labels) |entry, *label| label.* = entry.message;
        try self.editor.popupShow(.plugin, "Errors", labels);
    }

    fn showHealth(self: *Service) !void {
        var version_buffer: [96]u8 = undefined;
        var workspace_buffer: [96]u8 = undefined;
        var api_buffer: [128]u8 = undefined;
        var recovery_buffer: [96]u8 = undefined;
        const version_line = try std.fmt.bufPrint(&version_buffer, "Zim {s} · Daily Driver", .{build_info.version});
        const workspace_line = try std.fmt.bufPrint(&workspace_buffer, "workspace: {d} buffers · {d} windows · {d} tabs", .{ self.editor.buffers.items.len, self.editor.windows.items.len, self.editor.tabs.items.len });
        const api_line = try std.fmt.bufPrint(&api_buffer, "API: public {d} · plugin {d} · RPC {d}/{d}", .{ build_info.public_api_version, build_info.plugin_api_version, build_info.rpc_protocol_version, build_info.rpc_api_version });
        const recovery_pending = session.fileDirty(self.allocator, self.io, self.recovery_path) catch false;
        const recovery_line = try std.fmt.bufPrint(&recovery_buffer, "recovery: {s} · errors: {d}", .{ if (recovery_pending) "pending" else "clean", self.errors.items.len });
        const labels = [_][]const u8{
            version_line,
            api_line,
            workspace_line,
            recovery_line,
            "Lua/plugin callbacks use protected error boundaries.",
            "Sessions/recovery use atomic replacement.",
            "RPC remains local-only by default.",
            "Run :Help daily-driver for v1 commands.",
        };
        try self.editor.popupShow(.plugin, "Checkhealth", &labels);
    }

    fn applyColorscheme(self: *Service, name_raw: []const u8) !void {
        const name = std.mem.trim(u8, name_raw, " \t\r\n");
        if (name.len == 0) {
            self.setStatus(self.theme.scheme());
            return;
        }
        try self.theme.load(name);
        self.setStatusFmt("colorscheme {s}", .{name});
    }

    fn applyHighlight(self: *Service, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const group = tokens.next() orelse return error.Usage;
        var style = self.theme.get(group) orelse theme_module.Style{};
        var saw_option = false;
        while (tokens.next()) |token| {
            saw_option = true;
            if (std.mem.startsWith(u8, token, "fg=")) {
                style.foreground = try parseAnsi(token[3..]);
            } else if (std.mem.startsWith(u8, token, "bg=")) {
                style.background = try parseAnsi(token[3..]);
            } else if (std.mem.eql(u8, token, "bold")) style.bold = true
            else if (std.mem.eql(u8, token, "italic")) style.italic = true
            else if (std.mem.eql(u8, token, "dim")) style.dim = true
            else if (std.mem.eql(u8, token, "underline")) style.underline = true
            else if (std.mem.eql(u8, token, "nobold")) style.bold = false
            else if (std.mem.eql(u8, token, "noitalic")) style.italic = false
            else if (std.mem.eql(u8, token, "nodim")) style.dim = false
            else if (std.mem.eql(u8, token, "nounderline")) style.underline = false
            else return error.Usage;
        }
        if (!saw_option) return error.Usage;
        try self.theme.set(group, style);
        self.setStatusFmt("highlight {s}", .{group});
    }

    fn setStatus(self: *Service, message: []const u8) void {
        const len = @min(message.len, self.editor.status_buffer.len);
        @memcpy(self.editor.status_buffer[0..len], message[0..len]);
        self.editor.status_len = len;
    }

    fn setStatusFmt(self: *Service, comptime fmt: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(&self.editor.status_buffer, fmt, args) catch {
            self.editor.status_len = 0;
            return;
        };
        self.editor.status_len = rendered.len;
    }
};

fn serviceFrom(data: ?*anyopaque) *Service {
    return @ptrCast(@alignCast(data.?));
}

fn textChanged(context: *api_module.events.Context) !void {
    const self = serviceFrom(context.user_data);
    self.pending_recovery = true;
    if (context.editor.mode == .normal) self.checkpoint();
}

fn modeChanged(context: *api_module.events.Context) !void {
    const self = serviceFrom(context.user_data);
    if (self.pending_recovery and context.editor.mode == .normal) self.checkpoint();
}

fn bufferWritten(context: *api_module.events.Context) !void {
    const self = serviceFrom(context.user_data);
    self.pending_recovery = true;
    self.checkpoint();
}

fn bufferLeft(context: *api_module.events.Context) !void {
    const self = serviceFrom(context.user_data);
    if (self.pending_recovery) self.checkpoint();
}

fn helpCommand(context: *api_module.commands.Context) !void {
    try serviceFrom(context.user_data).showHelp(context.args);
}

fn errorsCommand(context: *api_module.commands.Context) !void {
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    try serviceFrom(context.user_data).showErrors();
}

fn checkhealthCommand(context: *api_module.commands.Context) !void {
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    try serviceFrom(context.user_data).showHealth();
}

fn sessionSaveCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    session.writeAtomic(self.allocator, self.io, self.editor, self.session_path, false) catch |err| {
        self.recordError("session save", err);
        return;
    };
    self.setStatus("session saved");
}

fn sessionRestoreCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    if (!self.restoreLastSession()) self.setStatus("no restorable session");
}

fn recoveryWriteCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    self.pending_recovery = true;
    self.checkpoint();
    self.setStatus("recovery checkpoint written");
}

fn recoveryRestoreCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    const dirty = session.fileDirty(self.allocator, self.io, self.recovery_path) catch |err| {
        self.recordError("recovery inspect", err);
        return;
    };
    if (!dirty) {
        self.setStatus("no crash recovery is pending");
        return;
    }
    const restored = session.restoreFile(self.allocator, self.io, self.editor, self.recovery_path) catch |err| {
        self.recordError("recovery restore", err);
        return;
    };
    if (!restored) {
        self.setStatus("no crash recovery is pending");
        return;
    }
    self.editor.configurePins(self.config_root) catch |err| self.recordError("pins restore", err);
    self.pending_recovery = anyModified(self.editor);
    self.setStatus("recovered workspace; unsaved buffers remain modified");
}

fn recoveryDiscardCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    if (std.mem.trim(u8, context.args, " \t").len != 0) return error.Usage;
    session.writeAtomic(self.allocator, self.io, self.editor, self.recovery_path, false) catch |err| {
        self.recordError("recovery discard", err);
        return;
    };
    self.pending_recovery = false;
    self.setStatus("recovery checkpoint discarded");
}

fn colorschemeCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    self.applyColorscheme(context.args) catch |err| {
        self.recordError("colorscheme", err);
        return;
    };
}

fn highlightCommand(context: *api_module.commands.Context) !void {
    const self = serviceFrom(context.user_data);
    self.applyHighlight(context.args) catch |err| {
        self.recordError("highlight", err);
        self.setStatus("usage: :Highlight Group fg=N bg=N bold italic dim underline");
        return;
    };
}

fn parseAnsi(value: []const u8) !u8 {
    const parsed = try std.fmt.parseInt(u8, value, 10);
    if (parsed > 15) return error.InvalidAnsiColor;
    return parsed;
}

fn anyModified(editor: *const editor_module.Editor) bool {
    for (editor.buffers.items) |buffer| if (buffer.modified) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

test "daily driver records bounded recoverable errors and exposes help/theme commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    var editor = try editor_module.Editor.init(allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(allocator);
    defer api.deinit();
    const service = try Service.create(allocator, std.testing.io, root_buffer[0..root_len], &api, &editor);
    defer service.destroy();

    try api.commandExecute(&editor, "Help", "recovery");
    try std.testing.expect(editor.popup.open);
    editor.popupClose();
    try api.commandExecute(&editor, "Colorscheme", "ember");
    try std.testing.expectEqualStrings("ember", service.theme.scheme());
    service.recordMessage("test", "one");
    try std.testing.expectEqual(@as(usize, 1), service.errors.items.len);
}
