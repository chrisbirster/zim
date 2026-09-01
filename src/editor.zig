const std = @import("std");
const buffer_module = @import("buffer.zig");
const workspace = @import("workspace.zig");

pub const Buffer = buffer_module.Buffer;
pub const BufferId = buffer_module.BufferId;
pub const Window = workspace.Window;
pub const WindowId = workspace.WindowId;
pub const TabPage = workspace.TabPage;
pub const TabId = workspace.TabId;
pub const SplitAxis = workspace.SplitAxis;
pub const LayoutNode = workspace.LayoutNode;

pub const Mode = enum {
    normal,
    insert,
    visual,
    visual_line,
    visual_block,
    operator_pending,
    command_line,
};

pub const Position = struct {
    line: usize,
    column: usize,
};

pub const Key = union(enum) {
    codepoint: u21,
    enter,
    backspace,
    tab,
    shift_tab,
    escape,
    ctrl_c,
    ctrl_r,
    ctrl_v,
    ctrl_h,
    ctrl_j,
    ctrl_k,
    ctrl_l,
    ctrl_u,
    ctrl_d,
    up,
    down,
    left,
    right,
};

pub const HandleResult = struct {
    handled: bool = true,
    command_open: bool = false,
    quit_requested: bool = false,
};

pub const Operator = enum {
    delete,
    change,
    yank,
};

pub const RegisterKind = buffer_module.RegisterKind;

pub const Register = struct {
    bytes: std.ArrayList(u8) = .empty,
    kind: RegisterKind = .characterwise,

    fn deinit(self: *Register, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    fn set(self: *Register, allocator: std.mem.Allocator, bytes: []const u8, kind: RegisterKind) !void {
        self.bytes.items.len = 0;
        try self.bytes.appendSlice(allocator, bytes);
        self.kind = kind;
    }
};

pub const Keymap = struct {
    mode: Mode,
    from: u21,
    to: u21,
};

const CommandPrompt = enum {
    ex,
    search_forward,
    search_backward,
};

const TextObjectScope = enum {
    inner,
    around,
};

const FindPending = struct {
    till: bool,
    backwards: bool,
};

const Range = struct {
    start: usize,
    end: usize,
    kind: RegisterKind = .characterwise,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode = .normal,
    buffers: std.ArrayList(Buffer) = .empty,
    windows: std.ArrayList(Window) = .empty,
    tabs: std.ArrayList(TabPage) = .empty,
    active_tab_index: usize = 0,
    next_buffer_id: BufferId = 1,
    next_window_id: WindowId = 1,
    next_tab_id: TabId = 1,
    project_root: ?[]u8 = null,

    unnamed_register: Register = .{},
    search_pattern: std.ArrayList(u8) = .empty,
    command_line: std.ArrayList(u8) = .empty,
    command_prompt: CommandPrompt = .ex,
    visual_anchor: ?usize = null,
    count_prefix: usize = 0,
    pending_operator: ?Operator = null,
    pending_text_object: ?TextObjectScope = null,
    pending_find: ?FindPending = null,
    pending_g: bool = false,
    operator_count: usize = 1,

    undo_group_active: bool = false,
    recording_change: bool = false,
    replaying_change: bool = false,
    current_change: std.ArrayList(Key) = .empty,
    last_change: std.ArrayList(Key) = .empty,
    keymaps: std.ArrayList(Keymap) = .empty,

    quit_requested: bool = false,
    status_buffer: [256]u8 = [_]u8{0} ** 256,
    status_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        target: ?[]const u8,
    ) !Editor {
        var self = Editor{
            .allocator = allocator,
            .io = io,
        };
        errdefer self.deinit();

        const buffer_id = self.allocateBufferId();
        try self.buffers.append(allocator, try Buffer.init(allocator, buffer_id, target));
        const window_id = self.allocateWindowId();
        try self.windows.append(allocator, .{ .id = window_id, .buffer_id = buffer_id });
        const tab_id = self.allocateTabId();
        try self.tabs.append(allocator, try TabPage.init(allocator, tab_id, window_id));
        return self;
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |*buffer| buffer.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        for (self.tabs.items) |*tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        if (self.project_root) |root| self.allocator.free(root);
        self.unnamed_register.deinit(self.allocator);
        self.search_pattern.deinit(self.allocator);
        self.command_line.deinit(self.allocator);
        self.current_change.deinit(self.allocator);
        self.last_change.deinit(self.allocator);
        self.keymaps.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadInitial(self: *Editor) !void {
        const buffer = self.currentBuffer();
        switch (try buffer.loadFromDisk(self.io, self.allocator)) {
            .loaded => self.setStatus("opened {s}", .{buffer.path.?}),
            .new_file => if (buffer.path) |path| self.setStatus("new file {s}", .{path}),
            .directory => {
                if (buffer.path) |path| {
                    if (self.project_root) |old| self.allocator.free(old);
                    self.project_root = try self.allocator.dupe(u8, path);
                    try buffer.setPath(self.allocator, null);
                    self.setStatus("project {s}", .{self.project_root.?});
                }
            },
        }
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.currentBufferConst().text.items;
    }

    pub fn currentPath(self: *const Editor) ?[]const u8 {
        return self.currentBufferConst().path;
    }

    pub fn currentBuffer(self: *Editor) *Buffer {
        const id = self.currentWindow().buffer_id;
        return &self.buffers.items[self.bufferIndexById(id).?];
    }

    pub fn currentBufferConst(self: *const Editor) *const Buffer {
        const id = self.currentWindowConst().buffer_id;
        return &self.buffers.items[self.bufferIndexById(id).?];
    }

    pub fn bufferById(self: *Editor, id: BufferId) ?*Buffer {
        const index = self.bufferIndexById(id) orelse return null;
        return &self.buffers.items[index];
    }

    pub fn bufferByIdConst(self: *const Editor, id: BufferId) ?*const Buffer {
        const index = self.bufferIndexById(id) orelse return null;
        return &self.buffers.items[index];
    }

    pub fn currentWindow(self: *Editor) *Window {
        const id = self.activeTab().activeWindowId();
        return &self.windows.items[self.windowIndexById(id).?];
    }

    pub fn currentWindowConst(self: *const Editor) *const Window {
        const id = self.activeTabConst().activeWindowId();
        return &self.windows.items[self.windowIndexById(id).?];
    }

    pub fn windowById(self: *Editor, id: WindowId) ?*Window {
        const index = self.windowIndexById(id) orelse return null;
        return &self.windows.items[index];
    }

    pub fn windowByIdConst(self: *const Editor, id: WindowId) ?*const Window {
        const index = self.windowIndexById(id) orelse return null;
        return &self.windows.items[index];
    }

    pub fn activeTab(self: *Editor) *TabPage {
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activeTabConst(self: *const Editor) *const TabPage {
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn setActiveWindow(self: *Editor, window_id: WindowId) bool {
        return self.activeTab().setActiveWindow(window_id);
    }

    pub fn cursor(self: *const Editor) usize {
        return self.currentWindowConst().cursor;
    }

    pub fn setCursor(self: *Editor, new_cursor: usize) void {
        const max = self.currentBuffer().text.items.len;
        self.currentWindow().cursor = @min(new_cursor, max);
    }

    pub fn cursorPosition(self: *const Editor) Position {
        return positionForOffset(self.currentBufferConst().text.items, self.cursor());
    }

    pub fn positionForWindow(self: *const Editor, window_id: WindowId) Position {
        const window = self.windowByIdConst(window_id) orelse return .{ .line = 1, .column = 1 };
        const buffer = self.bufferByIdConst(window.buffer_id) orelse return .{ .line = 1, .column = 1 };
        return positionForOffset(buffer.text.items, window.cursor);
    }

    pub fn setCursorFromLineColumn(self: *Editor, line_index: usize, byte_column: usize) void {
        const buffer = self.currentBuffer();
        self.currentWindow().cursor = offsetForLineColumn(buffer.text.items, line_index, byte_column);
    }

    pub fn setCursorForWindowFromLineColumn(
        self: *Editor,
        window_id: WindowId,
        line_index: usize,
        byte_column: usize,
    ) void {
        const window = self.windowById(window_id) orelse return;
        const buffer = self.bufferById(window.buffer_id) orelse return;
        window.cursor = offsetForLineColumn(buffer.text.items, line_index, byte_column);
    }

    pub fn setText(self: *Editor, value: []const u8) !void {
        try self.currentBuffer().setLoadedText(self.allocator, value);
        self.currentWindow().cursor = 0;
    }

    pub fn map(self: *Editor, mode: Mode, from: u21, to: u21) !void {
        for (self.keymaps.items) |*mapping| {
            if (mapping.mode == mode and mapping.from == from) {
                mapping.to = to;
                return;
            }
        }
        try self.keymaps.append(self.allocator, .{ .mode = mode, .from = from, .to = to });
    }

    pub fn modeName(self: *const Editor) []const u8 {
        return switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "V-LINE",
            .visual_block => "V-BLOCK",
            .operator_pending => "OP-PENDING",
            .command_line => "COMMAND",
        };
    }

    pub fn status(self: *const Editor) []const u8 {
        return self.status_buffer[0..self.status_len];
    }

    pub fn commandOpen(self: *const Editor) bool {
        return self.mode == .command_line;
    }

    pub fn commandDisplay(self: *const Editor, output: []u8) []const u8 {
        if (output.len == 0) return "";
        const prefix: u8 = switch (self.command_prompt) {
            .ex => ':',
            .search_forward => '/',
            .search_backward => '?',
        };
        output[0] = prefix;
        const len = @min(self.command_line.items.len, output.len - 1);
        @memcpy(output[1 .. 1 + len], self.command_line.items[0..len]);
        return output[0 .. 1 + len];
    }

    pub fn handleKey(self: *Editor, incoming: Key) !HandleResult {
        const key = self.resolveKey(incoming);
        if (self.recording_change and !self.replaying_change) {
            try self.current_change.append(self.allocator, key);
        }

        const handled = switch (self.mode) {
            .insert => try self.handleInsert(key),
            .operator_pending => try self.handleOperatorPending(key),
            .visual, .visual_line, .visual_block => try self.handleVisual(key),
            .command_line => try self.handleCommandLine(key),
            .normal => try self.handleNormal(key),
        };
        return .{
            .handled = handled,
            .command_open = self.commandOpen(),
            .quit_requested = self.quit_requested,
        };
    }

    pub fn undo(self: *Editor) !bool {
        self.finishUndoGroup();
        const window = self.currentWindow();
        if (try self.currentBuffer().undoOne(self.allocator, window.cursor)) |restored_cursor| {
            window.cursor = restored_cursor;
            self.setStatus("undo", .{});
            return true;
        }
        self.setStatus("already at oldest change", .{});
        return false;
    }

    pub fn redo(self: *Editor) !bool {
        self.finishUndoGroup();
        const window = self.currentWindow();
        if (try self.currentBuffer().redoOne(self.allocator, window.cursor)) |restored_cursor| {
            window.cursor = restored_cursor;
            self.setStatus("redo", .{});
            return true;
        }
        self.setStatus("already at newest change", .{});
        return false;
    }

    pub fn splitActive(self: *Editor, axis: SplitAxis) !WindowId {
        const current = self.currentWindow().*;
        const id = self.allocateWindowId();
        try self.windows.append(self.allocator, .{
            .id = id,
            .buffer_id = current.buffer_id,
            .cursor = current.cursor,
            .preferred_column = current.preferred_column,
            .scroll_line = current.scroll_line,
        });
        try self.activeTab().splitActive(self.allocator, axis, id);
        if (axis == .vertical) self.setStatus("vertical split", .{}) else self.setStatus("horizontal split", .{});
        return id;
    }

    pub fn newTab(self: *Editor) !TabId {
        const buffer_id = self.allocateBufferId();
        try self.buffers.append(self.allocator, try Buffer.init(self.allocator, buffer_id, null));
        const window_id = self.allocateWindowId();
        try self.windows.append(self.allocator, .{ .id = window_id, .buffer_id = buffer_id });
        const tab_id = self.allocateTabId();
        try self.tabs.append(self.allocator, try TabPage.init(self.allocator, tab_id, window_id));
        self.active_tab_index = self.tabs.items.len - 1;
        self.setStatus("new tab", .{});
        return tab_id;
    }

    pub fn nextWindow(self: *Editor) void {
        self.activeTab().cycleWindow(1);
    }

    pub fn previousWindow(self: *Editor) void {
        self.activeTab().cycleWindow(-1);
    }

    pub fn nextTab(self: *Editor) void {
        if (self.tabs.items.len > 1) self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
    }

    pub fn previousTab(self: *Editor) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = if (self.active_tab_index == 0) self.tabs.items.len - 1 else self.active_tab_index - 1;
    }

    pub fn nextBuffer(self: *Editor) void {
        if (self.buffers.items.len <= 1) return;
        const current_id = self.currentWindow().buffer_id;
        const index = self.bufferIndexById(current_id).?;
        const next = (index + 1) % self.buffers.items.len;
        self.currentWindow().buffer_id = self.buffers.items[next].id;
        self.currentWindow().cursor = 0;
    }

    pub fn previousBuffer(self: *Editor) void {
        if (self.buffers.items.len <= 1) return;
        const current_id = self.currentWindow().buffer_id;
        const index = self.bufferIndexById(current_id).?;
        const previous = if (index == 0) self.buffers.items.len - 1 else index - 1;
        self.currentWindow().buffer_id = self.buffers.items[previous].id;
        self.currentWindow().cursor = 0;
    }

    pub fn editPath(self: *Editor, path: []const u8) !bool {
        if (self.currentBuffer().modified) {
            self.setStatus("No write since last change (add ! to override later)", .{});
            return false;
        }
        for (self.buffers.items) |*buffer| {
            if (buffer.path) |existing| {
                if (std.mem.eql(u8, existing, path)) {
                    self.currentWindow().buffer_id = buffer.id;
                    self.currentWindow().cursor = 0;
                    self.setStatus("buffer {s}", .{path});
                    return true;
                }
            }
        }

        const id = self.allocateBufferId();
        var buffer = try Buffer.init(self.allocator, id, path);
        errdefer buffer.deinit(self.allocator);
        const load_result = try buffer.loadFromDisk(self.io, self.allocator);
        if (load_result == .directory) {
            buffer.deinit(self.allocator);
            self.setStatus("directory editing is not implemented yet", .{});
            return false;
        }
        try self.buffers.append(self.allocator, buffer);
        self.currentWindow().buffer_id = id;
        self.currentWindow().cursor = 0;
        if (load_result == .new_file) self.setStatus("new file {s}", .{path}) else self.setStatus("opened {s}", .{path});
        return true;
    }

    pub fn writeCurrent(self: *Editor) !bool {
        self.currentBuffer().writeToDisk(self.io, self.allocator) catch |err| switch (err) {
            error.NoFileName => {
                self.setStatus("No file name", .{});
                return false;
            },
            else => return err,
        };
        const path = self.currentBuffer().path.?;
        self.setStatus("wrote {s}", .{path});
        return true;
    }

    fn handleNormal(self: *Editor, key: Key) !bool {
        if (self.pending_find) |pending| {
            self.pending_find = null;
            return switch (key) {
                .codepoint => |cp| self.finishFind(pending, cp),
                .escape => true,
                else => false,
            };
        }

        return switch (key) {
            .escape => blk: {
                self.resetPending();
                break :blk true;
            },
            .left => self.repeatMotion(.left, self.takeCount()),
            .right => self.repeatMotion(.right, self.takeCount()),
            .up => self.repeatMotion(.up, self.takeCount()),
            .down => self.repeatMotion(.down, self.takeCount()),
            .ctrl_r => try self.redo(),
            .ctrl_v => blk: {
                self.enterVisual(.visual_block);
                break :blk true;
            },
            .ctrl_u => blk: {
                self.pageMove(-1);
                break :blk true;
            },
            .ctrl_d => blk: {
                self.pageMove(1);
                break :blk true;
            },
            .ctrl_h => blk: {
                self.previousWindow();
                break :blk true;
            },
            .ctrl_l => blk: {
                self.nextWindow();
                break :blk true;
            },
            .codepoint => |cp| try self.handleNormalCodepoint(cp, key),
            else => false,
        };
    }

    fn handleNormalCodepoint(self: *Editor, cp: u21, key: Key) !bool {
        if (cp >= '1' and cp <= '9') {
            self.count_prefix = self.count_prefix * 10 + @as(usize, @intCast(cp - '0'));
            return true;
        }
        if (cp == '0' and self.count_prefix != 0) {
            self.count_prefix *= 10;
            return true;
        }

        if (self.pending_g) {
            self.pending_g = false;
            if (cp == 'g') {
                self.moveToLine(if (self.count_prefix == 0) 0 else self.takeCount() - 1);
                self.count_prefix = 0;
                return true;
            }
        }

        const count = self.takeCount();
        return switch (cp) {
            'h' => self.repeatMotion(.left, count),
            'j' => self.repeatMotion(.down, count),
            'k' => self.repeatMotion(.up, count),
            'l' => self.repeatMotion(.right, count),
            'w' => blk: {
                for (0..count) |_| self.moveWordForward();
                break :blk true;
            },
            'b' => blk: {
                for (0..count) |_| self.moveWordBackward();
                break :blk true;
            },
            'e' => blk: {
                for (0..count) |_| self.moveWordEnd();
                break :blk true;
            },
            '0' => blk: {
                self.currentWindow().cursor = lineStartAt(self.text(), self.cursor());
                break :blk true;
            },
            '^' => blk: {
                self.currentWindow().cursor = firstNonBlank(self.text(), lineStartAt(self.text(), self.cursor()));
                break :blk true;
            },
            '$' => blk: {
                self.currentWindow().cursor = lineEnd(self.text(), self.cursor());
                break :blk true;
            },
            'g' => blk: {
                self.pending_g = true;
                self.count_prefix = if (count == 1) 0 else count;
                break :blk true;
            },
            'G' => blk: {
                if (count > 1) self.moveToLine(count - 1) else self.currentWindow().cursor = self.text().len;
                break :blk true;
            },
            'i' => blk: {
                try self.beginChange(key);
                self.mode = .insert;
                break :blk true;
            },
            'a' => blk: {
                try self.beginChange(key);
                _ = self.moveRight();
                self.mode = .insert;
                break :blk true;
            },
            'o' => blk: {
                try self.beginChange(key);
                try self.openLineBelow();
                self.mode = .insert;
                break :blk true;
            },
            'O' => blk: {
                try self.beginChange(key);
                try self.openLineAbove();
                self.mode = .insert;
                break :blk true;
            },
            'x' => blk: {
                try self.beginChange(key);
                for (0..count) |_| if (!(try self.deleteCharacter())) break;
                self.finishUndoGroup();
                try self.finishChange();
                break :blk true;
            },
            'd', 'c', 'y' => blk: {
                const op: Operator = if (cp == 'd') .delete else if (cp == 'c') .change else .yank;
                if (op != .yank) try self.beginChange(key);
                self.pending_operator = op;
                self.operator_count = count;
                self.mode = .operator_pending;
                break :blk true;
            },
            'p', 'P' => blk: {
                try self.beginChange(key);
                for (0..count) |_| try self.putRegister(cp == 'p');
                self.finishUndoGroup();
                try self.finishChange();
                break :blk true;
            },
            'u' => try self.undo(),
            '.' => blk: {
                try self.repeatLastChange(count);
                break :blk true;
            },
            'v' => blk: {
                self.enterVisual(.visual);
                break :blk true;
            },
            'V' => blk: {
                self.enterVisual(.visual_line);
                break :blk true;
            },
            ':' => blk: {
                self.enterCommand(.ex);
                break :blk true;
            },
            '/' => blk: {
                self.enterCommand(.search_forward);
                break :blk true;
            },
            '?' => blk: {
                self.enterCommand(.search_backward);
                break :blk true;
            },
            'n' => blk: {
                _ = self.search(true);
                break :blk true;
            },
            'N' => blk: {
                _ = self.search(false);
                break :blk true;
            },
            'f' => blk: {
                self.pending_find = .{ .till = false, .backwards = false };
                break :blk true;
            },
            'F' => blk: {
                self.pending_find = .{ .till = false, .backwards = true };
                break :blk true;
            },
            't' => blk: {
                self.pending_find = .{ .till = true, .backwards = false };
                break :blk true;
            },
            'T' => blk: {
                self.pending_find = .{ .till = true, .backwards = true };
                break :blk true;
            },
            else => false,
        };
    }

    fn handleInsert(self: *Editor, key: Key) !bool {
        return switch (key) {
            .escape => blk: {
                self.mode = .normal;
                self.finishUndoGroup();
                if (self.recording_change) try self.finishChange();
                break :blk true;
            },
            .backspace => try self.backspace(),
            .enter => blk: {
                try self.insertBytes("\n");
                break :blk true;
            },
            .tab => blk: {
                try self.insertBytes("  ");
                break :blk true;
            },
            .left => self.moveLeft(),
            .right => self.moveRight(),
            .up => self.moveUp(),
            .down => self.moveDown(),
            .codepoint => |cp| blk: {
                if (cp < 0x20) break :blk false;
                try self.insertCodepoint(cp);
                break :blk true;
            },
            else => false,
        };
    }

    fn handleOperatorPending(self: *Editor, key: Key) !bool {
        switch (key) {
            .escape => {
                self.resetPending();
                self.mode = .normal;
                if (self.recording_change) self.cancelChange();
                return true;
            },
            else => {},
        }
        const op = self.pending_operator orelse {
            self.mode = .normal;
            return false;
        };

        if (self.pending_text_object) |scope| {
            return switch (key) {
                .codepoint => |cp| blk: {
                    self.pending_text_object = null;
                    const range = self.textObjectRange(scope, cp) orelse {
                        self.resetOperator();
                        break :blk true;
                    };
                    try self.applyOperator(op, range);
                    break :blk true;
                },
                else => false,
            };
        }

        return switch (key) {
            .codepoint => |cp| blk: {
                if (cp == 'i' or cp == 'a') {
                    self.pending_text_object = if (cp == 'i') .inner else .around;
                    break :blk true;
                }
                const op_char: u21 = switch (op) {
                    .delete => 'd',
                    .change => 'c',
                    .yank => 'y',
                };
                if (cp == op_char) {
                    const range = self.lineRange(self.cursor(), self.operator_count);
                    try self.applyOperator(op, range);
                    break :blk true;
                }
                const range = self.motionRange(cp, self.operator_count) orelse {
                    self.resetOperator();
                    break :blk false;
                };
                try self.applyOperator(op, range);
                break :blk true;
            },
            else => false,
        };
    }

    fn handleVisual(self: *Editor, key: Key) !bool {
        return switch (key) {
            .escape => blk: {
                self.mode = .normal;
                self.visual_anchor = null;
                break :blk true;
            },
            .left => self.repeatMotion(.left, 1),
            .right => self.repeatMotion(.right, 1),
            .up => self.repeatMotion(.up, 1),
            .down => self.repeatMotion(.down, 1),
            .codepoint => |cp| blk: {
                switch (cp) {
                    'h' => _ = self.moveLeft(),
                    'j' => _ = self.moveDown(),
                    'k' => _ = self.moveUp(),
                    'l' => _ = self.moveRight(),
                    'w' => self.moveWordForward(),
                    'b' => self.moveWordBackward(),
                    'e' => self.moveWordEnd(),
                    '0' => self.currentWindow().cursor = lineStartAt(self.text(), self.cursor()),
                    '$' => self.currentWindow().cursor = lineEnd(self.text(), self.cursor()),
                    'y', 'd', 'c' => {
                        const op: Operator = if (cp == 'y') .yank else if (cp == 'd') .delete else .change;
                        const range = self.visualRange();
                        try self.applyOperator(op, range);
                    },
                    else => break :blk false,
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn handleCommandLine(self: *Editor, key: Key) !bool {
        return switch (key) {
            .escape => blk: {
                self.command_line.items.len = 0;
                self.mode = .normal;
                break :blk true;
            },
            .backspace => blk: {
                if (self.command_line.items.len > 0) {
                    const previous = previousCodepointStart(self.command_line.items, self.command_line.items.len);
                    self.command_line.items.len = previous;
                }
                break :blk true;
            },
            .enter => blk: {
                try self.submitCommandLine();
                break :blk true;
            },
            .codepoint => |cp| blk: {
                if (cp < 0x20) break :blk false;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encoded) catch 0;
                if (len == 0) break :blk false;
                try self.command_line.appendSlice(self.allocator, encoded[0..len]);
                break :blk true;
            },
            else => false,
        };
    }

    fn submitCommandLine(self: *Editor) !void {
        const command = self.command_line.items;
        switch (self.command_prompt) {
            .ex => try self.executeEx(command),
            .search_forward, .search_backward => {
                self.search_pattern.items.len = 0;
                try self.search_pattern.appendSlice(self.allocator, command);
                _ = self.search(self.command_prompt == .search_forward);
            },
        }
        self.command_line.items.len = 0;
        if (!self.quit_requested) self.mode = .normal;
    }

    fn executeEx(self: *Editor, raw: []const u8) !void {
        const command = std.mem.trim(u8, raw, " \t\r\n");
        if (command.len == 0) return;
        const split_index = std.mem.indexOfScalar(u8, command, ' ');
        const name = if (split_index) |index| command[0..index] else command;
        const args = if (split_index) |index| std.mem.trim(u8, command[index + 1 ..], " \t") else "";

        if (std.mem.eql(u8, name, "w") or std.mem.eql(u8, name, "write")) {
            _ = try self.writeCurrent();
        } else if (std.mem.eql(u8, name, "q") or std.mem.eql(u8, name, "quit")) {
            if (self.currentBuffer().modified) {
                self.setStatus("No write since last change (use :q! to discard)", .{});
            } else {
                self.quit_requested = true;
            }
        } else if (std.mem.eql(u8, name, "q!")) {
            self.quit_requested = true;
        } else if (std.mem.eql(u8, name, "wq") or std.mem.eql(u8, name, "x")) {
            if (try self.writeCurrent()) self.quit_requested = true;
        } else if (std.mem.eql(u8, name, "e") or std.mem.eql(u8, name, "edit")) {
            if (args.len == 0) {
                self.setStatus("edit requires a path", .{});
            } else {
                _ = try self.editPath(args);
            }
        } else if (std.mem.eql(u8, name, "bn") or std.mem.eql(u8, name, "bnext")) {
            self.nextBuffer();
        } else if (std.mem.eql(u8, name, "bp") or std.mem.eql(u8, name, "bprev")) {
            self.previousBuffer();
        } else if (std.mem.eql(u8, name, "buffer") or std.mem.eql(u8, name, "b")) {
            if (args.len == 0) {
                self.setStatus("buffer requires a number", .{});
            } else if (std.fmt.parseInt(usize, args, 10)) |number| {
                if (number == 0 or number > self.buffers.items.len) {
                    self.setStatus("buffer {d} does not exist", .{number});
                } else {
                    self.currentWindow().buffer_id = self.buffers.items[number - 1].id;
                    self.currentWindow().cursor = 0;
                }
            } else |_| {
                self.setStatus("invalid buffer number", .{});
            }
        } else if (std.mem.eql(u8, name, "split") or std.mem.eql(u8, name, "sp")) {
            _ = try self.splitActive(.horizontal);
            if (args.len != 0) _ = try self.editPath(args);
        } else if (std.mem.eql(u8, name, "vsplit") or std.mem.eql(u8, name, "vs")) {
            _ = try self.splitActive(.vertical);
            if (args.len != 0) _ = try self.editPath(args);
        } else if (std.mem.eql(u8, name, "tabnew")) {
            _ = try self.newTab();
            if (args.len != 0) _ = try self.editPath(args);
        } else if (std.mem.eql(u8, name, "tabnext") or std.mem.eql(u8, name, "tabn")) {
            self.nextTab();
        } else if (std.mem.eql(u8, name, "tabprevious") or std.mem.eql(u8, name, "tabp")) {
            self.previousTab();
        } else if (std.mem.eql(u8, name, "wincmd")) {
            if (args.len == 0 or std.mem.eql(u8, args, "w")) self.nextWindow() else if (std.mem.eql(u8, args, "W")) self.previousWindow();
        } else {
            self.setStatus("Not an editor command: {s}", .{name});
        }
    }

    fn enterCommand(self: *Editor, prompt: CommandPrompt) void {
        self.command_line.items.len = 0;
        self.command_prompt = prompt;
        self.mode = .command_line;
    }

    fn enterVisual(self: *Editor, mode: Mode) void {
        self.visual_anchor = self.cursor();
        self.mode = mode;
    }

    fn visualRange(self: *const Editor) Range {
        const anchor = self.visual_anchor orelse self.cursor();
        const current = self.cursor();
        if (self.mode == .visual_line) {
            const start = lineStartAt(self.text(), @min(anchor, current));
            const end_line = lineEnd(self.text(), @max(anchor, current));
            const end = if (end_line < self.text().len) end_line + 1 else end_line;
            return .{ .start = start, .end = end, .kind = .linewise };
        }
        const start = @min(anchor, current);
        const end = nextCodepointStart(self.text(), @max(anchor, current));
        return .{
            .start = start,
            .end = @max(end, start),
            .kind = if (self.mode == .visual_block) .blockwise else .characterwise,
        };
    }

    fn lineRange(self: *const Editor, at: usize, count: usize) Range {
        const bytes = self.text();
        const start = lineStartAt(bytes, at);
        var end = start;
        for (0..count) |_| {
            const line_end = lineEnd(bytes, end);
            end = if (line_end < bytes.len) line_end + 1 else line_end;
            if (end >= bytes.len) break;
        }
        return .{ .start = start, .end = end, .kind = .linewise };
    }

    fn motionRange(self: *Editor, cp: u21, count: usize) ?Range {
        const start = self.cursor();
        var target = start;
        var inclusive = false;
        switch (cp) {
            'h' => {
                for (0..count) |_| target = previousCodepointStartSafe(self.text(), target);
            },
            'l' => {
                for (0..count) |_| target = nextCodepointStart(self.text(), target);
            },
            'w' => {
                for (0..count) |_| target = nextWordStart(self.text(), target);
            },
            'b' => {
                for (0..count) |_| target = previousWordStart(self.text(), target);
            },
            'e' => {
                for (0..count) |_| target = wordEndOffset(self.text(), target);
                inclusive = true;
            },
            '0' => target = lineStartAt(self.text(), start),
            '^' => target = firstNonBlank(self.text(), lineStartAt(self.text(), start)),
            '$' => {
                target = lineEnd(self.text(), start);
                inclusive = false;
            },
            'j', 'k' => {
                const original = self.cursor();
                for (0..count) |_| {
                    if (cp == 'j') _ = self.moveDown() else _ = self.moveUp();
                }
                const destination = self.cursor();
                self.currentWindow().cursor = original;
                const first = @min(original, destination);
                const last = @max(original, destination);
                const line_start = lineStartAt(self.text(), first);
                const last_end = lineEnd(self.text(), last);
                return .{
                    .start = line_start,
                    .end = if (last_end < self.text().len) last_end + 1 else last_end,
                    .kind = .linewise,
                };
            },
            else => return null,
        }
        const a = @min(start, target);
        var b = @max(start, target);
        if (inclusive and b < self.text().len) b = nextCodepointStart(self.text(), b);
        if (a == b and cp == 'l') b = nextCodepointStart(self.text(), b);
        return .{ .start = a, .end = b };
    }

    fn textObjectRange(self: *const Editor, scope: TextObjectScope, cp: u21) ?Range {
        const bytes = self.text();
        const at = self.cursor();
        if (cp == 'w') {
            var start = at;
            if (start >= bytes.len and start > 0) start = previousCodepointStartSafe(bytes, start);
            while (start > 0 and isWordByte(bytes[previousCodepointStartSafe(bytes, start)])) {
                const previous = previousCodepointStartSafe(bytes, start);
                if (!isWordByte(bytes[previous])) break;
                start = previous;
            }
            var end = at;
            while (end < bytes.len and isWordByte(bytes[end])) end = nextCodepointStart(bytes, end);
            if (start == end) return null;
            if (scope == .around) {
                while (end < bytes.len and isSpaceByte(bytes[end])) end += 1;
                if (end == at) {
                    while (start > 0 and isSpaceByte(bytes[start - 1])) start -= 1;
                }
            }
            return .{ .start = start, .end = end };
        }

        const pair = delimiterPair(cp) orelse return null;
        const line_start = lineStartAt(bytes, at);
        const line_end = lineEnd(bytes, at);
        var left: ?usize = null;
        var index = at;
        while (index > line_start) {
            index -= 1;
            if (bytes[index] == pair.open) {
                left = index;
                break;
            }
        }
        if (left == null and at < line_end and bytes[at] == pair.open) left = at;
        const start_delimiter = left orelse return null;
        var right = @max(at +| 1, start_delimiter + 1);
        while (right < line_end and bytes[right] != pair.close) : (right += 1) {}
        if (right >= line_end or bytes[right] != pair.close) return null;
        return if (scope == .inner)
            .{ .start = start_delimiter + 1, .end = right }
        else
            .{ .start = start_delimiter, .end = right + 1 };
    }

    fn applyOperator(self: *Editor, op: Operator, range: Range) !void {
        switch (op) {
            .yank => {
                try self.setRegister(range);
                self.setStatus("yanked", .{});
                self.mode = .normal;
                self.visual_anchor = null;
                self.resetOperator();
            },
            .delete => {
                try self.deleteRange(range);
                self.mode = .normal;
                self.visual_anchor = null;
                self.resetOperator();
                self.finishUndoGroup();
                if (self.recording_change) try self.finishChange();
            },
            .change => {
                try self.deleteRange(range);
                self.mode = .insert;
                self.visual_anchor = null;
                self.resetOperator();
            },
        }
    }

    fn deleteCharacter(self: *Editor) !bool {
        if (self.cursor() >= self.text().len) return false;
        const end = nextCodepointStart(self.text(), self.cursor());
        try self.deleteRange(.{ .start = self.cursor(), .end = end });
        return true;
    }

    fn deleteRange(self: *Editor, range: Range) !void {
        const buffer = self.currentBuffer();
        const start = @min(range.start, buffer.text.items.len);
        const end = @min(@max(range.end, start), buffer.text.items.len);
        if (start == end) return;
        try self.setRegister(.{ .start = start, .end = end, .kind = range.kind });
        try self.ensureUndoSnapshot();
        const old_len = buffer.text.items.len;
        std.mem.copyForwards(
            u8,
            buffer.text.items[start .. old_len - (end - start)],
            buffer.text.items[end..old_len],
        );
        buffer.text.items.len = old_len - (end - start);
        buffer.markChanged();
        self.currentWindow().cursor = @min(start, buffer.text.items.len);
    }

    fn setRegister(self: *Editor, range: Range) !void {
        const bytes = self.text();
        const start = @min(range.start, bytes.len);
        const end = @min(@max(range.end, start), bytes.len);
        try self.unnamed_register.set(self.allocator, bytes[start..end], range.kind);
    }

    fn putRegister(self: *Editor, after: bool) !void {
        if (self.unnamed_register.bytes.items.len == 0) return;
        try self.ensureUndoSnapshot();
        const buffer = self.currentBuffer();
        var insertion = self.cursor();
        if (self.unnamed_register.kind == .linewise) {
            const end = lineEnd(buffer.text.items, insertion);
            insertion = if (after and end < buffer.text.items.len) end + 1 else lineStartAt(buffer.text.items, insertion);
        } else if (after and insertion < buffer.text.items.len) {
            insertion = nextCodepointStart(buffer.text.items, insertion);
        }
        try insertSliceAt(buffer, self.allocator, insertion, self.unnamed_register.bytes.items);
        buffer.markChanged();
        self.currentWindow().cursor = @min(insertion, buffer.text.items.len);
    }

    fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch
            std.unicode.utf8Encode(0xfffd, &bytes) catch unreachable;
        try self.insertBytes(bytes[0..len]);
    }

    fn insertBytes(self: *Editor, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.ensureUndoSnapshot();
        const buffer = self.currentBuffer();
        const insertion_cursor = self.cursor();
        try insertSliceAt(buffer, self.allocator, insertion_cursor, bytes);
        self.currentWindow().cursor = insertion_cursor + bytes.len;
        buffer.markChanged();
    }

    fn backspace(self: *Editor) !bool {
        if (self.cursor() == 0) return false;
        const previous = previousCodepointStartSafe(self.text(), self.cursor());
        try self.deleteRange(.{ .start = previous, .end = self.cursor() });
        return true;
    }

    fn openLineBelow(self: *Editor) !void {
        const end = lineEnd(self.text(), self.cursor());
        self.currentWindow().cursor = end;
        try self.insertBytes("\n");
    }

    fn openLineAbove(self: *Editor) !void {
        const start = lineStartAt(self.text(), self.cursor());
        self.currentWindow().cursor = start;
        try self.insertBytes("\n");
        self.currentWindow().cursor = start;
    }

    fn moveLeft(self: *Editor) bool {
        if (self.cursor() == 0) return false;
        self.currentWindow().cursor = previousCodepointStartSafe(self.text(), self.cursor());
        return true;
    }

    fn moveRight(self: *Editor) bool {
        if (self.cursor() >= self.text().len) return false;
        self.currentWindow().cursor = nextCodepointStart(self.text(), self.cursor());
        return true;
    }

    fn moveUp(self: *Editor) bool {
        return self.moveVertical(-1);
    }

    fn moveDown(self: *Editor) bool {
        return self.moveVertical(1);
    }

    fn moveVertical(self: *Editor, direction: i8) bool {
        const bytes = self.text();
        const current_cursor = self.cursor();
        const current_start = lineStartAt(bytes, current_cursor);
        const byte_column = current_cursor - current_start;
        if (direction < 0) {
            if (current_start == 0) return false;
            const previous_end = current_start - 1;
            const previous_start = lineStartAt(bytes, previous_end);
            self.currentWindow().cursor = previous_start + @min(byte_column, previous_end - previous_start);
            return true;
        }
        const current_end = lineEnd(bytes, current_cursor);
        if (current_end >= bytes.len) return false;
        const next_start = current_end + 1;
        const next_end = lineEnd(bytes, next_start);
        self.currentWindow().cursor = next_start + @min(byte_column, next_end - next_start);
        return true;
    }

    const SimpleMotion = enum { left, right, up, down };

    fn repeatMotion(self: *Editor, motion: SimpleMotion, count: usize) bool {
        var moved = false;
        for (0..count) |_| {
            const result = switch (motion) {
                .left => self.moveLeft(),
                .right => self.moveRight(),
                .up => self.moveUp(),
                .down => self.moveDown(),
            };
            moved = moved or result;
            if (!result) break;
        }
        return moved or count > 0;
    }

    fn moveWordForward(self: *Editor) void {
        self.currentWindow().cursor = nextWordStart(self.text(), self.cursor());
    }

    fn moveWordBackward(self: *Editor) void {
        self.currentWindow().cursor = previousWordStart(self.text(), self.cursor());
    }

    fn moveWordEnd(self: *Editor) void {
        self.currentWindow().cursor = wordEndOffset(self.text(), self.cursor());
    }

    fn moveToLine(self: *Editor, line_index: usize) void {
        self.currentWindow().cursor = offsetForLineColumn(self.text(), line_index, 0);
    }

    fn pageMove(self: *Editor, direction: i8) void {
        for (0..10) |_| {
            if (direction < 0) {
                if (!self.moveUp()) break;
            } else if (!self.moveDown()) break;
        }
    }

    fn finishFind(self: *Editor, pending: FindPending, cp: u21) bool {
        if (cp > 0x7f) return false;
        const target: u8 = @intCast(cp);
        const bytes = self.text();
        const current_cursor = self.cursor();
        const start = lineStartAt(bytes, current_cursor);
        const end = lineEnd(bytes, current_cursor);
        if (pending.backwards) {
            if (current_cursor <= start) return true;
            var index = current_cursor;
            while (index > start) {
                index -= 1;
                if (bytes[index] == target) {
                    self.currentWindow().cursor = if (pending.till) @min(index + 1, current_cursor) else index;
                    return true;
                }
            }
        } else {
            var index = @min(current_cursor + 1, end);
            while (index < end) : (index += 1) {
                if (bytes[index] == target) {
                    self.currentWindow().cursor = if (pending.till and index > 0) index - 1 else index;
                    return true;
                }
            }
        }
        return true;
    }

    fn search(self: *Editor, forward: bool) bool {
        const pattern = self.search_pattern.items;
        if (pattern.len == 0) return false;
        const bytes = self.text();
        if (forward) {
            const from = @min(self.cursor() +| 1, bytes.len);
            if (std.mem.indexOfPos(u8, bytes, from, pattern)) |index| {
                self.currentWindow().cursor = index;
                return true;
            }
            if (std.mem.indexOf(u8, bytes[0..from], pattern)) |index| {
                self.currentWindow().cursor = index;
                return true;
            }
        } else {
            const upto = @min(self.cursor(), bytes.len);
            if (std.mem.lastIndexOf(u8, bytes[0..upto], pattern)) |index| {
                self.currentWindow().cursor = index;
                return true;
            }
            if (std.mem.lastIndexOf(u8, bytes, pattern)) |index| {
                self.currentWindow().cursor = index;
                return true;
            }
        }
        self.setStatus("pattern not found: {s}", .{pattern});
        return false;
    }

    fn ensureUndoSnapshot(self: *Editor) !void {
        if (self.undo_group_active) return;
        try self.currentBuffer().recordUndo(self.allocator, self.cursor());
        self.undo_group_active = true;
    }

    fn finishUndoGroup(self: *Editor) void {
        self.undo_group_active = false;
    }

    fn beginChange(self: *Editor, key: Key) !void {
        if (self.replaying_change) return;
        self.current_change.items.len = 0;
        try self.current_change.append(self.allocator, key);
        self.recording_change = true;
    }

    fn finishChange(self: *Editor) !void {
        if (self.replaying_change) return;
        self.last_change.items.len = 0;
        try self.last_change.appendSlice(self.allocator, self.current_change.items);
        self.current_change.items.len = 0;
        self.recording_change = false;
    }

    fn cancelChange(self: *Editor) void {
        self.current_change.items.len = 0;
        self.recording_change = false;
        self.finishUndoGroup();
    }

    fn repeatLastChange(self: *Editor, count: usize) !void {
        if (self.last_change.items.len == 0) return;
        self.replaying_change = true;
        defer self.replaying_change = false;
        for (0..count) |_| {
            for (self.last_change.items) |key| {
                _ = try self.handleKey(key);
            }
        }
    }

    fn resolveKey(self: *const Editor, key: Key) Key {
        return switch (key) {
            .codepoint => |cp| blk: {
                for (self.keymaps.items) |mapping| {
                    if (mapping.mode == self.mode and mapping.from == cp) {
                        break :blk .{ .codepoint = mapping.to };
                    }
                }
                break :blk key;
            },
            else => key,
        };
    }

    fn takeCount(self: *Editor) usize {
        const count = if (self.count_prefix == 0) 1 else self.count_prefix;
        self.count_prefix = 0;
        return count;
    }

    fn resetOperator(self: *Editor) void {
        self.pending_operator = null;
        self.pending_text_object = null;
        self.operator_count = 1;
        self.count_prefix = 0;
    }

    fn resetPending(self: *Editor) void {
        self.resetOperator();
        self.pending_find = null;
        self.pending_g = false;
        self.count_prefix = 0;
    }

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(&self.status_buffer, fmt, args) catch {
            const fallback = "status message too long";
            @memcpy(self.status_buffer[0..fallback.len], fallback);
            self.status_len = fallback.len;
            return;
        };
        self.status_len = rendered.len;
    }

    fn allocateBufferId(self: *Editor) BufferId {
        const id = self.next_buffer_id;
        self.next_buffer_id += 1;
        return id;
    }

    fn allocateWindowId(self: *Editor) WindowId {
        const id = self.next_window_id;
        self.next_window_id += 1;
        return id;
    }

    fn allocateTabId(self: *Editor) TabId {
        const id = self.next_tab_id;
        self.next_tab_id += 1;
        return id;
    }

    fn bufferIndexById(self: *const Editor, id: BufferId) ?usize {
        for (self.buffers.items, 0..) |buffer, index| if (buffer.id == id) return index;
        return null;
    }

    fn windowIndexById(self: *const Editor, id: WindowId) ?usize {
        for (self.windows.items, 0..) |window, index| if (window.id == id) return index;
        return null;
    }
};

fn insertSliceAt(buffer: *Buffer, allocator: std.mem.Allocator, index: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const insertion = @min(index, buffer.text.items.len);
    const old_len = buffer.text.items.len;
    try buffer.text.ensureTotalCapacity(allocator, old_len + bytes.len);
    buffer.text.items.len = old_len + bytes.len;
    std.mem.copyBackwards(
        u8,
        buffer.text.items[insertion + bytes.len ..],
        buffer.text.items[insertion..old_len],
    );
    @memcpy(buffer.text.items[insertion .. insertion + bytes.len], bytes);
}

fn positionForOffset(bytes: []const u8, cursor: usize) Position {
    var line: usize = 1;
    var column: usize = 1;
    for (bytes[0..@min(cursor, bytes.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else if (!isContinuation(byte)) {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

pub fn offsetForLineColumn(bytes: []const u8, line_index: usize, byte_column: usize) usize {
    var start: usize = 0;
    var line: usize = 0;
    while (line < line_index and start < bytes.len) : (line += 1) {
        const end = lineEnd(bytes, start);
        if (end >= bytes.len) return bytes.len;
        start = end + 1;
    }
    const end = lineEnd(bytes, start);
    var cursor = start + @min(byte_column, end - start);
    while (cursor > start and cursor < bytes.len and isContinuation(bytes[cursor])) cursor -= 1;
    return cursor;
}

pub fn lineStartAt(bytes: []const u8, index: usize) usize {
    var start = @min(index, bytes.len);
    while (start > 0 and bytes[start - 1] != '\n') start -= 1;
    return start;
}

pub fn lineEnd(bytes: []const u8, index: usize) usize {
    var end = @min(index, bytes.len);
    while (end < bytes.len and bytes[end] != '\n') end += 1;
    return end;
}

fn firstNonBlank(bytes: []const u8, start: usize) usize {
    const end = lineEnd(bytes, start);
    var index = start;
    while (index < end and (bytes[index] == ' ' or bytes[index] == '\t')) index += 1;
    return index;
}

fn previousCodepointStart(bytes: []const u8, cursor: usize) usize {
    var index = cursor - 1;
    while (index > 0 and isContinuation(bytes[index])) index -= 1;
    return index;
}

fn previousCodepointStartSafe(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    return previousCodepointStart(bytes, @min(cursor, bytes.len));
}

fn nextCodepointStart(bytes: []const u8, cursor: usize) usize {
    if (cursor >= bytes.len) return bytes.len;
    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch 1;
    return @min(bytes.len, cursor + sequence_len);
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn isWordByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '_' or byte >= 0x80;
}

fn nextWordStart(bytes: []const u8, cursor: usize) usize {
    var index = @min(cursor, bytes.len);
    if (index < bytes.len) {
        const current_word = isWordByte(bytes[index]);
        const current_space = isSpaceByte(bytes[index]);
        while (index < bytes.len) {
            if (current_word and !isWordByte(bytes[index])) break;
            if (!current_word and !current_space and (isWordByte(bytes[index]) or isSpaceByte(bytes[index]))) break;
            if (current_space and !isSpaceByte(bytes[index])) break;
            index = nextCodepointStart(bytes, index);
        }
    }
    while (index < bytes.len and isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    return index;
}

fn previousWordStart(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index = previousCodepointStartSafe(bytes, cursor);
    while (index > 0 and isSpaceByte(bytes[index])) index = previousCodepointStartSafe(bytes, index);
    const word = isWordByte(bytes[index]);
    while (index > 0) {
        const previous = previousCodepointStartSafe(bytes, index);
        if (isWordByte(bytes[previous]) != word or isSpaceByte(bytes[previous])) break;
        index = previous;
    }
    return index;
}

fn wordEndOffset(bytes: []const u8, cursor: usize) usize {
    var index = @min(cursor, bytes.len);
    while (index < bytes.len and isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    if (index >= bytes.len) return bytes.len;
    const word = isWordByte(bytes[index]);
    var last = index;
    while (index < bytes.len and !isSpaceByte(bytes[index]) and isWordByte(bytes[index]) == word) {
        last = index;
        index = nextCodepointStart(bytes, index);
    }
    return last;
}

const DelimiterPair = struct { open: u8, close: u8 };

fn delimiterPair(cp: u21) ?DelimiterPair {
    if (cp > 0x7f) return null;
    return switch (@as(u8, @intCast(cp))) {
        '"' => .{ .open = '"', .close = '"' },
        '\'' => .{ .open = '\'', .close = '\'' },
        '(' => .{ .open = '(', .close = ')' },
        ')' => .{ .open = '(', .close = ')' },
        '[' => .{ .open = '[', .close = ']' },
        ']' => .{ .open = '[', .close = ']' },
        '{' => .{ .open = '{', .close = '}' },
        '}' => .{ .open = '{', .close = '}' },
        else => null,
    };
}

test "editor initializes real buffer window and tab state" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, "src/main.zig");
    defer editor.deinit();
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expectEqual(@as(usize, 1), editor.buffers.items.len);
    try std.testing.expectEqual(@as(usize, 1), editor.windows.items.len);
    try std.testing.expectEqual(@as(usize, 1), editor.tabs.items.len);
    try std.testing.expectEqualStrings("src/main.zig", editor.currentPath().?);
}

test "insert mode edits UTF-8 as one undo group" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    _ = try editor.handleKey(.{ .codepoint = 'i' });
    _ = try editor.handleKey(.{ .codepoint = 'λ' });
    _ = try editor.handleKey(.{ .codepoint = 'x' });
    _ = try editor.handleKey(.escape);
    try std.testing.expectEqualStrings("λx", editor.text());
    try std.testing.expectEqual(@as(usize, 1), editor.currentBuffer().undo.items.len);
    try std.testing.expect(try editor.undo());
    try std.testing.expectEqualStrings("", editor.text());
}

test "vim operator motion grammar composes dd dw and ciw" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("one two\nthree four\n");

    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("two\nthree four\n", editor.text());

    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("three four\n", editor.text());

    editor.setCursorFromLineColumn(0, 2);
    _ = try editor.handleKey(.{ .codepoint = 'c' });
    _ = try editor.handleKey(.{ .codepoint = 'i' });
    _ = try editor.handleKey(.{ .codepoint = 'w' });
    try std.testing.expectEqual(Mode.insert, editor.mode);
    _ = try editor.handleKey(.{ .codepoint = 'X' });
    _ = try editor.handleKey(.escape);
    try std.testing.expectEqualStrings("X four\n", editor.text());
}

test "counts registers put and repeat last change work headlessly" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("one two three");
    _ = try editor.handleKey(.{ .codepoint = '2' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("three", editor.text());
    try std.testing.expectEqualStrings("one two ", editor.unnamed_register.bytes.items);
    _ = try editor.handleKey(.{ .codepoint = 'p' });
    try std.testing.expect(std.mem.indexOf(u8, editor.text(), "one two ") != null);
    _ = try editor.handleKey(.{ .codepoint = '.' });
    try std.testing.expect(editor.text().len > "threeone two ".len);
}

test "visual line delete and search are editor-core behavior" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha\nbeta\ngamma\n");
    _ = try editor.handleKey(.{ .codepoint = 'V' });
    _ = try editor.handleKey(.{ .codepoint = 'j' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("gamma\n", editor.text());

    try editor.setText("alpha beta alpha");
    _ = try editor.handleKey(.{ .codepoint = '/' });
    for ("beta") |byte| _ = try editor.handleKey(.{ .codepoint = byte });
    _ = try editor.handleKey(.enter);
    try std.testing.expectEqual(@as(usize, 6), editor.cursor());
}

test "workspace supports buffers splits tabs and window cycling" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    const first_window = editor.currentWindow().id;
    const second_window = try editor.splitActive(.vertical);
    try std.testing.expect(first_window != second_window);
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().window_ids.items.len);
    editor.previousWindow();
    try std.testing.expectEqual(first_window, editor.currentWindow().id);
    _ = try editor.newTab();
    try std.testing.expectEqual(@as(usize, 2), editor.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), editor.buffers.items.len);
}

test "single-key maps are configurable without a terminal dependency" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("abc");
    try editor.map(.normal, 'H', 'l');
    _ = try editor.handleKey(.{ .codepoint = 'H' });
    try std.testing.expectEqual(@as(usize, 1), editor.cursor());
}
