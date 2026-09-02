const root = @import("root.zig");
const editor_module = @import("../editor.zig");

pub const Snapshot = struct {
    mode: editor_module.Mode,
    buffer_id: editor_module.BufferId,
    window_id: editor_module.WindowId,
    tab_id: editor_module.TabId,
    revision: u64,
};

pub fn capture(editor: *const editor_module.Editor) Snapshot {
    return .{
        .mode = editor.mode,
        .buffer_id = editor.currentBufferConst().id,
        .window_id = editor.currentWindowConst().id,
        .tab_id = editor.activeTabConst().id,
        .revision = editor.currentBufferConst().revision,
    };
}

pub fn emitChanges(api: *root.Api, editor: *editor_module.Editor, before: Snapshot) !void {
    const after = capture(editor);

    if (after.window_id != before.window_id) {
        try api.emit(editor, .{
            .kind = .window_leave,
            .buffer_id = before.buffer_id,
            .window_id = before.window_id,
            .tab_id = before.tab_id,
        });
        try api.emit(editor, .{
            .kind = .window_enter,
            .buffer_id = after.buffer_id,
            .window_id = after.window_id,
            .tab_id = after.tab_id,
        });
    }

    if (after.buffer_id != before.buffer_id) {
        try api.emit(editor, .{
            .kind = .buffer_leave,
            .buffer_id = before.buffer_id,
            .window_id = before.window_id,
            .tab_id = before.tab_id,
        });
        try api.emit(editor, .{
            .kind = .buffer_enter,
            .buffer_id = after.buffer_id,
            .window_id = after.window_id,
            .tab_id = after.tab_id,
        });
    }

    if (after.mode != before.mode) {
        try api.emit(editor, .{
            .kind = .mode_changed,
            .buffer_id = after.buffer_id,
            .window_id = after.window_id,
            .tab_id = after.tab_id,
        });
    }

    if (after.revision != before.revision) {
        try api.emit(editor, .{
            .kind = .text_changed,
            .buffer_id = after.buffer_id,
            .window_id = after.window_id,
            .tab_id = after.tab_id,
        });
    }
}
