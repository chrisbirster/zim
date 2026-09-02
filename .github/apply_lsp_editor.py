from pathlib import Path


def once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return text.replace(old, new, 1)

bridge_path = Path("src/lsp_bridge.zig")
bridge = bridge_path.read_text()
bridge = once(
    bridge,
    "pub const BufferId = buffer_module.BufferId;\n",
    "pub const BufferId = buffer_module.BufferId;\n"
    "pub const ProtocolPosition = lsp.types.Position;\n"
    "pub const ProtocolRange = lsp.types.Range;\n\n"
    "pub fn fileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {\n"
    "    return lsp.uri.fileUriAlloc(allocator, path);\n"
    "}\n\n"
    "pub fn filePathAlloc(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {\n"
    "    return lsp.uri.filePathAlloc(allocator, uri);\n"
    "}\n\n"
    "pub fn byteOffsetFromProtocolPosition(text: []const u8, position: ProtocolPosition) usize {\n"
    "    return lsp.types.byteOffsetFromPositionUtf16(text, position);\n"
    "}\n",
    "bridge public protocol seam",
)
bridge_path.write_text(bridge)

editor_path = Path("src/editor.zig")
editor = editor_path.read_text()
editor = once(
    editor,
    'const language_bridge = @import("language_bridge.zig");\n',
    'const language_bridge = @import("language_bridge.zig");\nconst lsp_bridge = @import("lsp_bridge.zig");\n',
    "editor lsp import",
)
editor = once(
    editor,
    "    project_root: ?[]u8 = null,\n    language_state: language_bridge.State,\n",
    "    project_root: ?[]u8 = null,\n    language_state: language_bridge.State,\n    lsp_state: lsp_bridge.State,\n",
    "editor lsp field",
)
editor = once(
    editor,
    "            .language_state = try language_bridge.State.init(allocator),\n",
    "            .language_state = try language_bridge.State.init(allocator),\n            .lsp_state = lsp_bridge.State.init(allocator, io),\n",
    "editor lsp init",
)
editor = once(
    editor,
    "        self.language_state.deinit();\n",
    "        self.language_state.deinit();\n        self.lsp_state.deinit();\n",
    "editor lsp deinit",
)
editor = once(
    editor,
    "        try self.syncCurrentLanguage(true);\n    }\n\n    pub fn text",
    "        try self.syncCurrentLanguage(true);\n        try self.syncCurrentLsp(true);\n    }\n\n    pub fn text",
    "load initial lsp sync",
)
editor = once(
    editor,
    "    pub fn setText(self: *Editor, value: []const u8) !void {\n        try self.currentBuffer().setLoadedText(self.allocator, value);\n        self.currentWindow().cursor = 0;\n        try self.syncCurrentLanguage(true);\n    }\n",
    "    pub fn setText(self: *Editor, value: []const u8) !void {\n        try self.currentBuffer().setLoadedText(self.allocator, value);\n        self.currentWindow().cursor = 0;\n        try self.syncCurrentLanguage(true);\n        try self.syncCurrentLsp(true);\n    }\n",
    "set text lsp sync",
)

lsp_api = r'''
    pub fn syncCurrentLsp(self: *Editor, force: bool) !void {
        try self.lsp_state.syncBuffer(self.currentBufferConst(), force);
    }

    pub fn lspStart(self: *Editor) !void {
        const path = self.currentPath() orelse return error.NoFileName;
        try self.lsp_state.startForPath(path, self.project_root orelse ".");
    }

    pub fn lspBeginDetachedForCurrent(self: *Editor) !u64 {
        const path = self.currentPath() orelse return error.NoFileName;
        return self.lsp_state.beginDetachedForPath(path, self.project_root orelse ".");
    }

    pub fn lspHandleIncoming(self: *Editor, body: []const u8) !void {
        const was_ready = self.lsp_state.client.state == .ready;
        try self.lsp_state.handleIncoming(body);
        if (!was_ready and self.lsp_state.client.state == .ready) {
            for (self.buffers.items) |*buffer| try self.lsp_state.syncBuffer(buffer, false);
        }
    }

    pub fn lspPollOnce(self: *Editor) !bool {
        var scratch: [64 * 1024]u8 = undefined;
        const body = try self.lsp_state.client.receiveOnce(&scratch) orelse return false;
        defer self.allocator.free(body);
        try self.lspHandleIncoming(body);
        return true;
    }

    pub fn lspRequestHover(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestHover(self.currentBufferConst(), self.cursor());
    }

    pub fn lspRequestSignatureHelp(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestSignatureHelp(self.currentBufferConst(), self.cursor());
    }

    pub fn lspRequestDefinition(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestDefinition(self.currentBufferConst(), self.cursor());
    }

    pub fn lspRequestReferences(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestReferences(self.currentBufferConst(), self.cursor());
    }

    pub fn lspRequestDocumentSymbols(self: *Editor) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestDocumentSymbols(self.currentBufferConst());
    }

    pub fn lspRequestWorkspaceSymbols(self: *Editor, query: []const u8) !u64 {
        try self.ensureLspReady();
        const path = self.currentPath() orelse return error.NoFileName;
        const current_uri = try lsp_bridge.fileUriAlloc(self.allocator, path);
        defer self.allocator.free(current_uri);
        return self.lsp_state.requestWorkspaceSymbols(query, current_uri);
    }

    pub fn lspRequestRename(self: *Editor, new_name: []const u8) !u64 {
        try self.ensureLspReady();
        return self.lsp_state.requestRename(self.currentBufferConst(), self.cursor(), new_name);
    }

    pub fn lspRequestCodeAction(self: *Editor) !u64 {
        try self.ensureLspReady();
        const position = lsp_bridge.ProtocolPosition{
            .line = @intCast(self.cursorPosition().line - 1),
            .character = @intCast(self.cursorPosition().column - 1),
        };
        return self.lsp_state.requestCodeAction(self.currentBufferConst(), .{ .start = position, .end = position });
    }

    pub fn lspNextDiagnostic(self: *Editor, forward: bool) !bool {
        const destination = try self.lsp_state.nextDiagnosticOffset(self.currentBufferConst(), self.cursor(), forward) orelse {
            self.setStatus("no diagnostics", .{});
            return false;
        };
        self.setCursor(destination);
        self.setStatus(if (forward) "next diagnostic" else "previous diagnostic", .{});
        return true;
    }

    pub fn lspJumpToFirstLocation(self: *Editor) !bool {
        const locations = self.lsp_state.last_locations orelse return false;
        if (locations.items.len == 0) return false;
        const target = locations.items[0];
        const path = try lsp_bridge.filePathAlloc(self.allocator, target.uri);
        defer self.allocator.free(path);
        const origin = self.currentLocation();
        if (!(try self.editPath(path))) return false;
        self.setCursor(lsp_bridge.byteOffsetFromProtocolPosition(self.text(), target.range.start));
        self.recordJump(origin, self.currentLocation()) catch {};
        try self.syncCurrentLanguage(false);
        try self.syncCurrentLsp(false);
        return true;
    }

    pub fn lspApplyPendingWorkspaceEdit(self: *Editor) !usize {
        const changed = try self.lsp_state.applyPendingWorkspaceEdit(self.buffers.items);
        if (changed > 0) {
            try self.syncCurrentLanguage(false);
            try self.syncCurrentLsp(false);
        }
        self.setStatus("applied {d} LSP file edits", .{changed});
        return changed;
    }

    pub fn lspHoverText(self: *const Editor) ?[]const u8 {
        return self.lsp_state.last_hover;
    }

    pub fn lspSignatureText(self: *const Editor) ?[]const u8 {
        return self.lsp_state.last_signature;
    }

    pub fn lspLocationCount(self: *const Editor) usize {
        return if (self.lsp_state.last_locations) |locations| locations.items.len else 0;
    }

    pub fn lspSymbolCount(self: *const Editor) usize {
        return if (self.lsp_state.last_symbols) |symbols| symbols.items.len else 0;
    }

    fn ensureLspReady(self: *const Editor) !void {
        if (self.lsp_state.client.state != .ready) return error.LanguageServerNotReady;
    }

'''
editor = once(
    editor,
    "    pub fn map(self: *Editor, mode: Mode, from: u21, to: u21) !void {\n",
    lsp_api + "    pub fn map(self: *Editor, mode: Mode, from: u21, to: u21) !void {\n",
    "editor lsp api insertion",
)
editor = once(
    editor,
    "                try self.syncCurrentLanguage(false);\n",
    "                try self.syncCurrentLanguage(false);\n                try self.syncCurrentLsp(false);\n",
    "key path lsp sync",
)
editor = once(
    editor,
    "        const path = self.currentBuffer().path.?;\n        self.setStatus(\"wrote {s}\", .{path});\n",
    "        try self.lsp_state.didSave(self.currentBufferConst());\n        const path = self.currentBuffer().path.?;\n        self.setStatus(\"wrote {s}\", .{path});\n",
    "didSave wiring",
)
old_symbols = '        } else if (std.mem.eql(u8, name, "symbols")) {\n            self.setStatus("{d} symbols", .{self.symbolsForBuffer(self.currentBufferConst().id).len});\n'
new_symbols = '''        } else if (std.mem.eql(u8, name, "symbols")) {
            self.setStatus("{d} tree-sitter, {d} LSP symbols", .{ self.symbolsForBuffer(self.currentBufferConst().id).len, self.lspSymbolCount() });
        } else if (std.mem.eql(u8, name, "lspstart")) {
            self.lspStart() catch |err| self.setStatus("LSP start failed: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "lsppoll")) {
            _ = self.lspPollOnce() catch |err| {
                self.setStatus("LSP poll failed: {s}", .{@errorName(err)});
                return;
            };
        } else if (std.mem.eql(u8, name, "diagnosticnext")) {
            _ = try self.lspNextDiagnostic(true);
        } else if (std.mem.eql(u8, name, "diagnosticprev")) {
            _ = try self.lspNextDiagnostic(false);
        } else if (std.mem.eql(u8, name, "hover")) {
            _ = self.lspRequestHover() catch |err| self.setStatus("hover unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "signature")) {
            _ = self.lspRequestSignatureHelp() catch |err| self.setStatus("signature unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "definition")) {
            _ = self.lspRequestDefinition() catch |err| self.setStatus("definition unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "references")) {
            _ = self.lspRequestReferences() catch |err| self.setStatus("references unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "lspjump")) {
            _ = try self.lspJumpToFirstLocation();
        } else if (std.mem.eql(u8, name, "lspsymbols")) {
            if (args.len == 0) {
                _ = self.lspRequestDocumentSymbols() catch |err| self.setStatus("symbols unavailable: {s}", .{@errorName(err)});
            } else {
                _ = self.lspRequestWorkspaceSymbols(args) catch |err| self.setStatus("workspace symbols unavailable: {s}", .{@errorName(err)});
            }
        } else if (std.mem.eql(u8, name, "rename")) {
            if (args.len == 0) self.setStatus("rename requires a new name", .{}) else _ = self.lspRequestRename(args) catch |err| self.setStatus("rename unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "codeaction")) {
            _ = self.lspRequestCodeAction() catch |err| self.setStatus("code action unavailable: {s}", .{@errorName(err)});
        } else if (std.mem.eql(u8, name, "lspapply")) {
            _ = try self.lspApplyPendingWorkspaceEdit();
'''
editor = once(editor, old_symbols, new_symbols, "editor lsp ex commands")

integration_test = r'''

test "native LSP augments editor with diagnostics navigation semantic requests and workspace edits" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, "/tmp/demo.zig");
    defer editor.deinit();
    try editor.setText("const value = 1;\n");

    const initialize_id = try editor.lspBeginDetachedForCurrent();
    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try editor.lspHandleIncoming(initialize_response);
    try std.testing.expect(std.mem.indexOf(u8, editor.lsp_state.client.outbox.items, "textDocument/didOpen") != null);

    try editor.lspHandleIncoming(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/demo.zig","version":0,"diagnostics":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"severity":1,"message":"demo diagnostic"}]}}
    );
    editor.setCursor(0);
    try std.testing.expect(try editor.lspNextDiagnostic(true));
    try std.testing.expectEqual(@as(usize, 6), editor.cursor());

    const hover_id = try editor.lspRequestHover();
    const hover_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"plaintext\",\"value\":\"i32\"}}}}}}", .{hover_id});
    defer std.testing.allocator.free(hover_response);
    try editor.lspHandleIncoming(hover_response);
    try std.testing.expectEqualStrings("i32", editor.lspHoverText().?);

    const signature_id = try editor.lspRequestSignatureHelp();
    const signature_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"signatures\":[{{\"label\":\"demo(value: i32)\"}}]}}}}", .{signature_id});
    defer std.testing.allocator.free(signature_response);
    try editor.lspHandleIncoming(signature_response);
    try std.testing.expectEqualStrings("demo(value: i32)", editor.lspSignatureText().?);

    const definition_id = try editor.lspRequestDefinition();
    const definition_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uri\":\"file:///tmp/demo.zig\",\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":11}}}}}}}}", .{definition_id});
    defer std.testing.allocator.free(definition_response);
    try editor.lspHandleIncoming(definition_response);
    try std.testing.expectEqual(@as(usize, 1), editor.lspLocationCount());
    try std.testing.expect(try editor.lspJumpToFirstLocation());

    const references_id = try editor.lspRequestReferences();
    const references_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"uri\":\"file:///tmp/demo.zig\",\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":11}}}}}}]}}", .{references_id});
    defer std.testing.allocator.free(references_response);
    try editor.lspHandleIncoming(references_response);
    try std.testing.expectEqual(@as(usize, 1), editor.lspLocationCount());

    const symbols_id = try editor.lspRequestDocumentSymbols();
    const symbols_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"name\":\"value\",\"kind\":13,\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":11}}}}}}]}}", .{symbols_id});
    defer std.testing.allocator.free(symbols_response);
    try editor.lspHandleIncoming(symbols_response);
    try std.testing.expectEqual(@as(usize, 1), editor.lspSymbolCount());

    const workspace_symbols_id = try editor.lspRequestWorkspaceSymbols("value");
    const workspace_symbols_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"name\":\"value\",\"kind\":13,\"location\":{{\"uri\":\"file:///tmp/demo.zig\",\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":11}}}}}}}}]}}", .{workspace_symbols_id});
    defer std.testing.allocator.free(workspace_symbols_response);
    try editor.lspHandleIncoming(workspace_symbols_response);
    try std.testing.expectEqual(@as(usize, 1), editor.lspSymbolCount());

    editor.setCursor(6);
    const rename_id = try editor.lspRequestRename("renamed");
    const rename_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"changes\":{{\"file:///tmp/demo.zig\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":11}}}},\"newText\":\"renamed\"}}]}}}}}}", .{rename_id});
    defer std.testing.allocator.free(rename_response);
    try editor.lspHandleIncoming(rename_response);
    try std.testing.expectEqual(@as(usize, 1), try editor.lspApplyPendingWorkspaceEdit());
    try std.testing.expect(std.mem.indexOf(u8, editor.text(), "renamed") != null);

    const action_id = try editor.lspRequestCodeAction();
    const action_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"title\":\"fix\",\"edit\":{{\"changes\":{{\"file:///tmp/demo.zig\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":13}}}},\"newText\":\"value\"}}]}}}}}}]}}", .{action_id});
    defer std.testing.allocator.free(action_response);
    try editor.lspHandleIncoming(action_response);
    try std.testing.expectEqual(@as(usize, 1), try editor.lspApplyPendingWorkspaceEdit());
    try std.testing.expect(std.mem.indexOf(u8, editor.text(), "value") != null);
}
'''
if 'test "native LSP augments editor' in editor:
    raise SystemExit("editor LSP integration test already present")
editor += integration_test
editor_path.write_text(editor)
