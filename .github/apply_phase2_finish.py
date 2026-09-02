from pathlib import Path


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return text.replace(old, new, 1)

editor_path = Path("src/editor.zig")
editor = editor_path.read_text()

old_methods = '''    pub fn lspRequestCodeAction(self: *Editor) !u64 {
        try self.ensureLspReady();
        const position = lsp_bridge.ProtocolPosition{
            .line = @intCast(self.cursorPosition().line - 1),
            .character = @intCast(self.cursorPosition().column - 1),
        };
        return self.lsp_state.requestCodeAction(self.currentBufferConst(), .{ .start = position, .end = position });
    }

    pub fn lspNextDiagnostic'''
new_methods = '''    pub fn lspRequestCodeAction(self: *Editor) !u64 {
        try self.ensureLspReady();
        const position = lsp_bridge.ProtocolPosition{
            .line = @intCast(self.cursorPosition().line - 1),
            .character = @intCast(self.cursorPosition().column - 1),
        };
        return self.lsp_state.requestCodeAction(self.currentBufferConst(), .{ .start = position, .end = position });
    }

    pub fn lspRequestFormatting(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestFormatting(self.currentBufferConst(), 4, true);
    }

    pub fn lspRequestCompletion(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestCompletion(self.currentBufferConst(), self.cursor());
    }

    pub fn lspCompletionCount(self: *const Editor) usize {
        return self.lsp_state.completionCount();
    }

    pub fn lspCompletionLabel(self: *const Editor, index: usize) ?[]const u8 {
        return self.lsp_state.completionLabel(index);
    }

    pub fn lspNextDiagnostic'''
editor = once(editor, old_methods, new_methods, "editor formatting/completion API")

old_ex = '''        } else if (std.mem.eql(u8, name, "codeaction")) {
            _ = self.lspRequestCodeAction() catch |err| self.setStatus("code action unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "lspapply")) {
            _ = try self.lspApplyPendingWorkspaceEdit();
'''
new_ex = '''        } else if (std.mem.eql(u8, name, "codeaction")) {
            _ = self.lspRequestCodeAction() catch |err| self.setStatus("code action unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "format")) {
            _ = self.lspRequestFormatting() catch |err| self.setStatus("format unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "complete")) {
            _ = self.lspRequestCompletion() catch |err| self.setStatus("completion unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "lspapply")) {
            _ = try self.lspApplyPendingWorkspaceEdit();
'''
editor = once(editor, old_ex, new_ex, "editor Ex formatting/completion commands")

old_tail = '''    const action_id = try editor.lspRequestCodeAction();
    const action_response = try std.fmt.allocPrint(std.testing.allocator, "{{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":{d},\\\"result\\\":[{{\\\"title\\\":\\\"fix\\\",\\\"edit\\\":{{\\\"changes\\\":{{\\\"file:///tmp/demo.zig\\\":[{{\\\"range\\\":{{\\\"start\\\":{{\\\"line\\\":0,\\\"character\\\":6}},\\\"end\\\":{{\\\"line\\\":0,\\\"character\\\":13}}}},\\\"newText\\\":\\\"value\\\"}}]}}}}}}]}}", .{action_id});
    defer std.testing.allocator.free(action_response);
    try editor.lspHandleIncoming(action_response);
    try std.testing.expectEqual(@as(usize, 1), try editor.lspApplyPendingWorkspaceEdit());
    try std.testing.expect(std.mem.indexOf(u8, editor.text(), "value") != null);
}'''
new_tail = '''    const action_id = try editor.lspRequestCodeAction();
    const action_response = try std.fmt.allocPrint(std.testing.allocator, "{{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":{d},\\\"result\\\":[{{\\\"title\\\":\\\"fix\\\",\\\"edit\\\":{{\\\"changes\\\":{{\\\"file:///tmp/demo.zig\\\":[{{\\\"range\\\":{{\\\"start\\\":{{\\\"line\\\":0,\\\"character\\\":6}},\\\"end\\\":{{\\\"line\\\":0,\\\"character\\\":13}}}},\\\"newText\\\":\\\"value\\\"}}]}}}}}}]}}", .{action_id});
    defer std.testing.allocator.free(action_response);
    try editor.lspHandleIncoming(action_response);
    try std.testing.expectEqual(@as(usize, 1), try editor.lspApplyPendingWorkspaceEdit());
    try std.testing.expect(std.mem.indexOf(u8, editor.text(), "value") != null);

    editor.setCursor(6);
    const completion_id = try editor.lspRequestCompletion();
    const completion_response = try std.fmt.allocPrint(std.testing.allocator, "{{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":{d},\\\"result\\\":{{\\\"isIncomplete\\\":false,\\\"items\\\":[{{\\\"label\\\":\\\"value\\\",\\\"detail\\\":\\\"const\\\",\\\"insertText\\\":\\\"value\\\"}}]}}}}", .{completion_id});
    defer std.testing.allocator.free(completion_response);
    try editor.lspHandleIncoming(completion_response);
    try std.testing.expectEqual(@as(usize, 1), editor.lspCompletionCount());
    try std.testing.expectEqualStrings("value", editor.lspCompletionLabel(0).?);

    const formatting_id = try editor.lspRequestFormatting();
    const formatting_response = try std.fmt.allocPrint(std.testing.allocator, "{{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":{d},\\\"result\\\":[{{\\\"range\\\":{{\\\"start\\\":{{\\\"line\\\":0,\\\"character\\\":0}},\\\"end\\\":{{\\\"line\\\":0,\\\"character\\\":0}}}},\\\"newText\\\":\\\"// formatted\\\\n\\\"}}]}}", .{formatting_id});
    defer std.testing.allocator.free(formatting_response);
    try editor.lspHandleIncoming(formatting_response);
    try std.testing.expectEqual(@as(usize, 1), try editor.lspApplyPendingWorkspaceEdit());
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "// formatted\\n"));
}'''
editor = once(editor, old_tail, new_tail, "editor Phase 2 integration test")
editor_path.write_text(editor)

bridge_path = Path("src/lsp_bridge.zig")
bridge = bridge_path.read_text()
bridge = once(
    bridge,
    '    try state.handleIncoming(formatting_response);\n    try std.testing.expectEqual(@as(usize, 1), try state.applyPendingWorkspaceEdit(&.{buffer}));\n',
    '    try state.handleIncoming(formatting_response);\n    try std.testing.expectEqual(@as(usize, 1), state.pending_workspace_edit.?.files.items.len);\n',
    "bridge formatting fixture",
)
bridge_path.write_text(bridge)
