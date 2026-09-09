const std = @import("std");
const editor_module = @import("../editor.zig");

pub const handles = @import("handles.zig");
pub const options = @import("options.zig");
pub const commands = @import("commands.zig");
pub const keymaps = @import("keymaps.zig");
pub const events = @import("events.zig");
pub const pins = @import("../pins.zig");
pub const extmarks = @import("../extmarks.zig");
pub const plugin_ui = @import("../plugin_ui.zig");
pub const jobs = @import("../jobs.zig");
const job_api = @import("jobs.zig");

pub const BufferHandle = handles.BufferHandle;
pub const WindowHandle = handles.WindowHandle;
pub const TabHandle = handles.TabHandle;
pub const PinId = pins.PinId;
pub const NamespaceId = extmarks.NamespaceId;
pub const ExtmarkId = extmarks.ExtmarkId;
pub const JobId = jobs.JobId;

pub const Api = struct {
    allocator: std.mem.Allocator,
    options: options.Options = .{},
    commands: commands.Registry,
    keymaps: keymaps.Registry,
    autocmds: events.Registry,
    job_service: job_api.Service,

    pub fn init(allocator: std.mem.Allocator) Api {
        return .{
            .allocator = allocator,
            .commands = commands.Registry.init(allocator),
            .keymaps = keymaps.Registry.init(allocator),
            .autocmds = events.Registry.init(allocator),
            .job_service = job_api.Service.init(allocator),
        };
    }

    pub fn deinit(self: *Api) void {
        self.job_service.deinit();
        self.commands.deinit();
        self.keymaps.deinit();
        self.autocmds.deinit();
        self.* = undefined;
    }

    pub fn registerJobCommands(self: *Api) !void {
        try self.job_service.registerCommands(&self.commands);
    }

    pub fn currentBuffer(self: *const Api, editor: *const editor_module.Editor) BufferHandle {
        _ = self;
        return .{ .id = editor.currentBufferConst().id };
    }

    pub fn currentWindow(self: *const Api, editor: *const editor_module.Editor) WindowHandle {
        _ = self;
        return .{ .id = editor.currentWindowConst().id };
    }

    pub fn currentTab(self: *const Api, editor: *const editor_module.Editor) TabHandle {
        _ = self;
        return .{ .id = editor.activeTabConst().id };
    }

    pub fn bufferIsValid(self: *const Api, editor: *const editor_module.Editor, handle: BufferHandle) bool {
        _ = self;
        return editor.bufferByIdConst(handle.id) != null;
    }

    pub fn windowIsValid(self: *const Api, editor: *const editor_module.Editor, handle: WindowHandle) bool {
        _ = self;
        return editor.windowByIdConst(handle.id) != null;
    }

    pub fn tabIsValid(self: *const Api, editor: *const editor_module.Editor, handle: TabHandle) bool {
        _ = self;
        for (editor.tabs.items) |tab| {
            if (tab.id == handle.id) return true;
        }
        return false;
    }

    pub fn bufferText(self: *const Api, editor: *const editor_module.Editor, handle: BufferHandle) ?[]const u8 {
        _ = self;
        const buffer = editor.bufferByIdConst(handle.id) orelse return null;
        return buffer.text.items;
    }

    pub fn windowBuffer(self: *const Api, editor: *const editor_module.Editor, handle: WindowHandle) ?BufferHandle {
        _ = self;
        const window = editor.windowByIdConst(handle.id) orelse return null;
        return .{ .id = window.buffer_id };
    }

    pub fn pinCount(self: *const Api, editor: *const editor_module.Editor) usize {
        _ = self;
        return editor.pins.count();
    }

    pub fn pinEntries(self: *const Api, editor: *const editor_module.Editor) []const pins.Entry {
        _ = self;
        return editor.pins.entries.items;
    }

    pub fn pinAdd(self: *Api, editor: *editor_module.Editor, label: ?[]const u8) !?PinId {
        _ = self;
        return editor.pinAddCurrent(label);
    }

    pub fn pinRemove(self: *Api, editor: *editor_module.Editor, slot: usize) !bool {
        _ = self;
        return editor.pinRemoveSlot(slot);
    }

    pub fn pinMove(self: *Api, editor: *editor_module.Editor, from_slot: usize, to_slot: usize) !bool {
        _ = self;
        return editor.pinMoveSlot(from_slot, to_slot);
    }

    pub fn pinJump(self: *Api, editor: *editor_module.Editor, slot: usize, exact: bool) !bool {
        _ = self;
        return editor.pinJumpSlot(slot, exact);
    }

    pub fn namespaceCreate(self: *Api, editor: *editor_module.Editor, name: []const u8) !NamespaceId {
        _ = self;
        return editor.extmarkNamespaceCreate(name);
    }

    pub fn namespaceDelete(self: *Api, editor: *editor_module.Editor, namespace_id: NamespaceId) bool {
        _ = self;
        return editor.extmarkNamespaceDelete(namespace_id);
    }

    pub fn extmarkSet(
        self: *Api,
        editor: *editor_module.Editor,
        buffer: BufferHandle,
        namespace_id: NamespaceId,
        start: usize,
        opts: extmarks.Options,
    ) !ExtmarkId {
        _ = self;
        return editor.extmarkSet(buffer.id, namespace_id, start, opts);
    }

    pub fn extmarkDelete(self: *Api, editor: *editor_module.Editor, buffer: BufferHandle, namespace_id: NamespaceId, id: ExtmarkId) bool {
        _ = self;
        return editor.extmarkDelete(buffer.id, namespace_id, id);
    }

    pub fn extmarkClear(self: *Api, editor: *editor_module.Editor, buffer: BufferHandle, namespace_id: NamespaceId) bool {
        _ = self;
        return editor.extmarkClear(buffer.id, namespace_id);
    }

    pub fn diagnosticPublish(
        self: *Api,
        editor: *editor_module.Editor,
        buffer: BufferHandle,
        namespace_id: NamespaceId,
        diagnostics: []const extmarks.Diagnostic,
    ) !void {
        _ = self;
        try editor.publishDiagnostics(buffer.id, namespace_id, diagnostics);
    }

    pub fn popupOpen(self: *Api, editor: *editor_module.Editor, title: []const u8, labels: []const []const u8) !void {
        _ = self;
        try editor.popupShow(.plugin, title, labels);
    }

    pub fn popupClose(self: *Api, editor: *editor_module.Editor) void {
        _ = self;
        editor.popupClose();
    }

    pub fn jobStart(self: *Api, editor: *editor_module.Editor, argv: []const []const u8, opts: jobs.Options) !JobId {
        return self.job_service.start(editor, argv, opts);
    }

    pub fn jobWait(self: *Api, id: JobId) !void {
        try self.job_service.wait(id);
    }

    pub fn jobStop(self: *Api, id: JobId) !bool {
        return self.job_service.stop(id);
    }

    pub fn jobStatus(self: *const Api, id: JobId) ?jobs.Status {
        return self.job_service.status(id);
    }

    pub fn jobSnapshot(self: *const Api, id: JobId) ?jobs.Snapshot {
        return self.job_service.snapshot(id);
    }

    pub fn jobSnapshotAt(self: *const Api, index: usize) ?jobs.Snapshot {
        return self.job_service.snapshotAt(index);
    }

    pub fn jobStdout(self: *const Api, id: JobId) ?[]const u8 {
        return self.job_service.stdout(id);
    }

    pub fn jobStderr(self: *const Api, id: JobId) ?[]const u8 {
        return self.job_service.stderr(id);
    }

    pub fn jobCount(self: *const Api) usize {
        return self.job_service.count();
    }

    pub fn optionGet(self: *const Api, name: options.Name) options.Value {
        return self.options.get(name);
    }

    pub fn optionSet(self: *Api, name: options.Name, value: options.Value) !void {
        try self.options.set(name, value);
    }

    pub fn commandCreate(
        self: *Api,
        name: []const u8,
        description: []const u8,
        callback: commands.Callback,
        user_data: ?*anyopaque,
    ) !commands.CommandId {
        return self.commands.create(name, description, callback, user_data);
    }

    pub fn commandDelete(self: *Api, name: []const u8) bool {
        return self.commands.delete(name);
    }

    pub fn commandExecute(self: *Api, editor: *editor_module.Editor, name: []const u8, args: []const u8) !void {
        try self.commands.execute(editor, name, args);
    }

    pub fn keymapSet(
        self: *Api,
        editor: *editor_module.Editor,
        scope: keymaps.Scope,
        mode: editor_module.Mode,
        from: u21,
        to: u21,
    ) !keymaps.KeymapId {
        return self.keymaps.set(editor, scope, mode, from, to);
    }

    pub fn keymapDelete(
        self: *Api,
        editor: *editor_module.Editor,
        scope: keymaps.Scope,
        mode: editor_module.Mode,
        from: u21,
    ) bool {
        return self.keymaps.delete(editor, scope, mode, from);
    }

    pub fn autocmdCreate(
        self: *Api,
        kind: events.Kind,
        opts: events.Options,
        callback: events.Callback,
        user_data: ?*anyopaque,
    ) !events.AutocmdId {
        return self.autocmds.create(kind, opts, callback, user_data);
    }

    pub fn autocmdDelete(self: *Api, id: events.AutocmdId) bool {
        return self.autocmds.delete(id);
    }

    pub fn emit(self: *Api, editor: *editor_module.Editor, event: events.Event) !void {
        try self.autocmds.emit(editor, event);
    }

    pub fn setCurrentText(self: *Api, editor: *editor_module.Editor, value: []const u8) !void {
        try editor.setText(value);
        try self.emit(editor, .{
            .kind = .text_changed,
            .buffer_id = editor.currentBuffer().id,
            .window_id = editor.currentWindow().id,
            .tab_id = editor.activeTab().id,
        });
    }

    pub fn writeCurrent(self: *Api, editor: *editor_module.Editor) !bool {
        const event = events.Event{
            .kind = .buffer_write_pre,
            .buffer_id = editor.currentBuffer().id,
            .window_id = editor.currentWindow().id,
            .tab_id = editor.activeTab().id,
        };
        try self.emit(editor, event);
        const wrote = try editor.writeCurrent();
        if (wrote) {
            var post = event;
            post.kind = .buffer_write_post;
            try self.emit(editor, post);
        }
        return wrote;
    }

    pub fn handleKey(self: *Api, editor: *editor_module.Editor, incoming: editor_module.Key) anyerror!editor_module.HandleResult {
        const before_mode = editor.mode;
        const before_buffer = editor.currentBuffer().id;
        const before_window = editor.currentWindow().id;
        const before_revision = editor.currentBuffer().revision;

        const result = try self.keymaps.handleKey(editor, incoming);

        const after_mode = editor.mode;
        const after_buffer = editor.currentBuffer().id;
        const after_window = editor.currentWindow().id;
        const after_revision = editor.currentBuffer().revision;
        const tab_id = editor.activeTab().id;

        if (before_window != after_window) {
            try self.emit(editor, .{ .kind = .window_leave, .window_id = before_window, .buffer_id = before_buffer, .tab_id = tab_id });
            try self.emit(editor, .{ .kind = .window_enter, .window_id = after_window, .buffer_id = after_buffer, .tab_id = tab_id });
        }
        if (before_buffer != after_buffer) {
            try self.emit(editor, .{ .kind = .buffer_leave, .buffer_id = before_buffer, .window_id = before_window, .tab_id = tab_id });
            try self.emit(editor, .{ .kind = .buffer_enter, .buffer_id = after_buffer, .window_id = after_window, .tab_id = tab_id });
        }
        if (before_mode != after_mode) {
            try self.emit(editor, .{ .kind = .mode_changed, .buffer_id = after_buffer, .window_id = after_window, .tab_id = tab_id });
        }
        if (before_buffer == after_buffer and before_revision != after_revision) {
            try self.emit(editor, .{ .kind = .text_changed, .buffer_id = after_buffer, .window_id = after_window, .tab_id = tab_id });
        }
        return result;
    }
};

const EventCount = struct {
    mode_changes: usize = 0,
    text_changes: usize = 0,
};

fn countMode(context: *events.Context) !void {
    const count: *EventCount = @ptrCast(@alignCast(context.user_data.?));
    count.mode_changes += 1;
}

fn countText(context: *events.Context) !void {
    const count: *EventCount = @ptrCast(@alignCast(context.user_data.?));
    count.text_changes += 1;
}

test "public API exposes stable typed handles and editor state" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = Api.init(std.testing.allocator);
    defer api.deinit();

    const buffer = api.currentBuffer(&editor);
    const window = api.currentWindow(&editor);
    const tab = api.currentTab(&editor);
    try std.testing.expect(api.bufferIsValid(&editor, buffer));
    try std.testing.expect(api.windowIsValid(&editor, window));
    try std.testing.expect(api.tabIsValid(&editor, tab));
    try std.testing.expectEqual(buffer.id, api.windowBuffer(&editor, window).?.id);

    try api.setCurrentText(&editor, "hello");
    try std.testing.expectEqualStrings("hello", api.bufferText(&editor, buffer).?);
}

test "public key handling emits typed mode and text events" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = Api.init(std.testing.allocator);
    defer api.deinit();
    var count = EventCount{};

    _ = try api.autocmdCreate(.mode_changed, .{}, countMode, &count);
    _ = try api.autocmdCreate(.text_changed, .{}, countText, &count);
    _ = try api.handleKey(&editor, .{ .codepoint = 'i' });
    _ = try api.handleKey(&editor, .{ .codepoint = 'x' });
    _ = try api.handleKey(&editor, .escape);

    try std.testing.expectEqual(@as(usize, 2), count.mode_changes);
    try std.testing.expectEqual(@as(usize, 1), count.text_changes);
    try std.testing.expectEqualStrings("x", editor.text());
}

test "public extmark diagnostics and popup API share native editor state" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha beta");
    var api = Api.init(std.testing.allocator);
    defer api.deinit();
    const buffer = api.currentBuffer(&editor);
    const ns = try api.namespaceCreate(&editor, "plugin.demo");
    const id = try api.extmarkSet(&editor, buffer, ns, 6, .{ .highlight = "Demo", .sign = "*", .virtual_text = "note" });
    try std.testing.expectEqual(@as(usize, 6), editor.currentBuffer().extmarks.find(ns, id).?.start);
    try api.diagnosticPublish(&editor, buffer, ns, &.{.{ .start = 0, .end = 5, .severity = .warning, .message = "warn" }});
    try std.testing.expectEqual(@as(usize, 1), editor.currentBuffer().extmarks.diagnosticCount());
    try api.popupOpen(&editor, "Demo", &.{ "one", "two" });
    try std.testing.expect(editor.popup.open);
    try std.testing.expectEqualStrings("one", editor.popup.selectedLabel().?);
}

test "public job API owns asynchronous job state and commands" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = Api.init(std.testing.allocator);
    defer api.deinit();
    try api.registerJobCommands();

    const id = try api.jobStart(&editor, &.{ "zig", "version" }, .{});
    try api.jobWait(id);
    try std.testing.expectEqual(jobs.Status.completed, api.jobStatus(id).?);
    try std.testing.expect(std.mem.indexOf(u8, api.jobStdout(id).?, "0.16") != null);
    try std.testing.expectEqual(@as(usize, 1), api.jobCount());

    try api.commandExecute(&editor, "JobStart", "zig version");
    try api.jobWait(2);
    try std.testing.expectEqual(jobs.Status.completed, api.jobSnapshotAt(1).?.status);
    try api.commandExecute(&editor, "JobList", "");
    try std.testing.expect(std.mem.indexOf(u8, editor.status_buffer[0..editor.status_len], "2:completed") != null);
}
