const std = @import("std");
const lsp = @import("lsp/root.zig");
const buffer_module = @import("buffer.zig");

pub const BufferId = buffer_module.BufferId;
pub const ProtocolPosition = lsp.types.Position;
pub const ProtocolRange = lsp.types.Range;

pub fn fileUriAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return lsp.uri.fileUriAlloc(allocator, path);
}

pub fn filePathAlloc(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    return lsp.uri.filePathAlloc(allocator, uri);
}

pub fn byteOffsetFromProtocolPosition(text: []const u8, position: ProtocolPosition) usize {
    return lsp.types.byteOffsetFromPositionUtf16(text, position);
}

const Document = struct {
    buffer_id: BufferId,
    uri: []u8,
    language_id: []const u8,
    revision: u64,
    opened: bool = false,

    fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.* = undefined;
    }
};

const RequestKind = enum {
    hover,
    signature,
    definition,
    references,
    document_symbols,
    workspace_symbols,
    rename,
    code_action,
    formatting,
    completion,
};

const Pending = struct {
    id: u64,
    kind: RequestKind,
    uri: []u8,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: lsp.Client,
    diagnostics: lsp.diagnostics.Store,
    documents: std.ArrayList(Document) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    active_server: ?*const lsp.registry.ServerSpec = null,
    last_hover: ?[]u8 = null,
    last_signature: ?[]u8 = null,
    last_locations: ?lsp.responses.LocationList = null,
    last_locations_are_references: bool = false,
    last_symbols: ?lsp.responses.SymbolList = null,
    last_completions: ?lsp.completion.List = null,
    pending_workspace_edit: ?lsp.workspace_edit.Plan = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) State {
        return .{
            .allocator = allocator,
            .io = io,
            .client = lsp.Client.init(allocator, io),
            .diagnostics = lsp.diagnostics.Store.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.client.deinit();
        self.diagnostics.deinit();
        for (self.documents.items) |*document| document.deinit(self.allocator);
        self.documents.deinit(self.allocator);
        for (self.pending.items) |*pending| pending.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        if (self.last_hover) |text| self.allocator.free(text);
        if (self.last_signature) |text| self.allocator.free(text);
        if (self.last_locations) |*locations| locations.deinit();
        if (self.last_symbols) |*symbols| symbols.deinit();
        if (self.last_completions) |*completions| completions.deinit();
        if (self.pending_workspace_edit) |*plan| plan.deinit();
        self.* = undefined;
    }

    pub fn startForPath(self: *State, path: []const u8, root_path: []const u8) !void {
        const spec = lsp.registry.findByPath(path) orelse return error.NoLanguageServer;
        const root_uri = try lsp.uri.fileUriAlloc(self.allocator, root_path);
        defer self.allocator.free(root_uri);
        self.active_server = spec;
        try self.client.spawn(spec.argv, root_uri);
    }

    pub fn beginDetachedForPath(self: *State, path: []const u8, root_path: []const u8) !u64 {
        const spec = lsp.registry.findByPath(path) orelse return error.NoLanguageServer;
        const root_uri = try lsp.uri.fileUriAlloc(self.allocator, root_path);
        defer self.allocator.free(root_uri);
        self.active_server = spec;
        return self.client.beginInitialize(root_uri);
    }

    pub fn syncBuffer(self: *State, buffer: *const buffer_module.Buffer, force: bool) !void {
        const path = buffer.path orelse return;
        const spec = lsp.registry.findByPath(path) orelse return;
        const index = try self.documentIndexOrAppend(buffer.id, path, spec.language_id, buffer.revision);
        const document = &self.documents.items[index];
        if (self.client.state != .ready) {
            document.revision = buffer.revision;
            return;
        }
        if (!document.opened) {
            try lsp.documents.didOpen(&self.client, document.uri, document.language_id, versionOf(buffer.revision), buffer.text.items);
            document.opened = true;
            document.revision = buffer.revision;
            return;
        }
        if (!force and document.revision == buffer.revision) return;
        try lsp.documents.didChange(&self.client, document.uri, versionOf(buffer.revision), buffer.text.items);
        document.revision = buffer.revision;
    }

    pub fn didSave(self: *State, buffer: *const buffer_module.Buffer) !void {
        if (self.client.state != .ready) return;
        const index = self.documentIndex(buffer.id) orelse return;
        const document = &self.documents.items[index];
        if (!document.opened) return;
        try lsp.documents.didSave(&self.client, document.uri, buffer.text.items);
    }

    pub fn didClose(self: *State, buffer_id: BufferId) !void {
        const index = self.documentIndex(buffer_id) orelse return;
        const document = &self.documents.items[index];
        if (self.client.state == .ready and document.opened) try lsp.documents.didClose(&self.client, document.uri);
        var removed = self.documents.swapRemove(index);
        removed.deinit(self.allocator);
    }

    pub fn handleIncoming(self: *State, body: []const u8) !void {
        try self.client.handleBody(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        if (lsp.protocol.method(parsed.value)) |method_name| {
            if (std.mem.eql(u8, method_name, "textDocument/publishDiagnostics")) {
                const params = parsed.value.object.get("params") orelse return;
                const json = try std.json.Stringify.valueAlloc(self.allocator, params, .{});
                defer self.allocator.free(json);
                try self.diagnostics.replaceFromParamsJson(json);
            }
            return;
        }

        const id = lsp.protocol.responseId(parsed.value) orelse return;
        const pending_index = self.pendingIndex(id) orelse return;
        var request = self.pending.swapRemove(pending_index);
        defer request.deinit(self.allocator);
        switch (request.kind) {
            .hover => {
                if (self.last_hover) |old| self.allocator.free(old);
                self.last_hover = try lsp.responses.parseHoverText(self.allocator, body);
            },
            .signature => {
                if (self.last_signature) |old| self.allocator.free(old);
                self.last_signature = try lsp.responses.parseSignatureLabel(self.allocator, body);
            },
            .definition, .references => {
                if (self.last_locations) |*old| old.deinit();
                self.last_locations = try lsp.responses.parseLocations(self.allocator, body);
                self.last_locations_are_references = request.kind == .references;
            },
            .document_symbols, .workspace_symbols => {
                if (self.last_symbols) |*old| old.deinit();
                self.last_symbols = try lsp.responses.parseSymbols(self.allocator, body, request.uri);
            },
            .rename => {
                if (self.pending_workspace_edit) |*old| old.deinit();
                self.pending_workspace_edit = try lsp.workspace_edit.Plan.parseResponse(self.allocator, body);
            },
            .code_action => {
                if (self.pending_workspace_edit) |*old| old.deinit();
                self.pending_workspace_edit = try lsp.workspace_edit.parseCodeActionResponse(self.allocator, body);
            },
            .formatting => {
                if (self.pending_workspace_edit) |*old| old.deinit();
                self.pending_workspace_edit = try lsp.workspace_edit.parseTextEditResponse(self.allocator, body, request.uri);
            },
            .completion => {
                if (self.last_completions) |*old| old.deinit();
                self.last_completions = try lsp.completion.parse(self.allocator, body);
            },
        }
    }

    pub fn requestHover(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.hover(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset));
        try self.track(id, .hover, uri);
        return id;
    }

    pub fn requestSignatureHelp(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.signatureHelp(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset));
        try self.track(id, .signature, uri);
        return id;
    }

    pub fn requestDefinition(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.definition(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset));
        try self.track(id, .definition, uri);
        return id;
    }

    pub fn requestReferences(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.references(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset));
        try self.track(id, .references, uri);
        return id;
    }

    pub fn requestDocumentSymbols(self: *State, buffer: *const buffer_module.Buffer) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.documentSymbols(&self.client, uri);
        try self.track(id, .document_symbols, uri);
        return id;
    }

    pub fn requestWorkspaceSymbols(self: *State, query: []const u8, current_uri: []const u8) !u64 {
        const id = try lsp.documents.workspaceSymbols(&self.client, query);
        try self.track(id, .workspace_symbols, current_uri);
        return id;
    }

    pub fn requestRename(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize, new_name: []const u8) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.rename(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset), new_name);
        try self.track(id, .rename, uri);
        return id;
    }

    pub fn requestCodeAction(self: *State, buffer: *const buffer_module.Buffer, range: lsp.types.Range) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const source = self.diagnostics.itemsFor(uri);
        const diagnostics = try self.allocator.alloc(lsp.types.Diagnostic, source.len);
        defer self.allocator.free(diagnostics);
        for (source, diagnostics) |item, *target| {
            target.* = .{
                .range = item.range,
                .severity = item.severity,
                .message = item.message,
                .source = item.source,
            };
        }
        const id = try lsp.documents.codeAction(&self.client, uri, range, diagnostics);
        try self.track(id, .code_action, uri);
        return id;
    }

    pub fn requestFormatting(self: *State, buffer: *const buffer_module.Buffer, tab_size: u32, insert_spaces: bool) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.formatting(&self.client, uri, tab_size, insert_spaces);
        try self.track(id, .formatting, uri);
        return id;
    }

    pub fn requestCompletion(self: *State, buffer: *const buffer_module.Buffer, byte_offset: usize) !u64 {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        const id = try lsp.documents.completion(&self.client, uri, lsp.types.positionFromByteOffsetUtf16(buffer.text.items, byte_offset));
        try self.track(id, .completion, uri);
        return id;
    }

    pub fn completionCount(self: *const State) usize {
        return if (self.last_completions) |completions| completions.items.len else 0;
    }

    pub fn completionLabel(self: *const State, index: usize) ?[]const u8 {
        const completions = self.last_completions orelse return null;
        if (index >= completions.items.len) return null;
        return completions.items[index].label;
    }

    pub fn nextDiagnosticOffset(self: *const State, buffer: *const buffer_module.Buffer, current: usize, forward: bool) !?usize {
        const uri = try self.uriForBuffer(buffer);
        defer self.allocator.free(uri);
        return self.diagnostics.nextOffset(uri, buffer.text.items, current, forward);
    }

    pub fn applyPendingWorkspaceEdit(self: *State, buffers: []buffer_module.Buffer) !usize {
        var plan = self.pending_workspace_edit orelse return 0;
        self.pending_workspace_edit = null;
        defer plan.deinit();
        var changed: usize = 0;
        for (plan.files.items) |file_edit| {
            const path = try lsp.uri.filePathAlloc(self.allocator, file_edit.uri);
            defer self.allocator.free(path);
            if (findBufferByPath(buffers, path)) |buffer| {
                const updated = try lsp.workspace_edit.applyTextEdits(self.allocator, buffer.text.items, file_edit.edits.items);
                defer self.allocator.free(updated);
                try buffer.recordUndo(self.allocator, 0);
                buffer.text.items.len = 0;
                try buffer.text.appendSlice(self.allocator, updated);
                buffer.markChanged();
                changed += 1;
            } else {
                var temporary = try buffer_module.Buffer.init(self.allocator, 0, path);
                defer temporary.deinit(self.allocator);
                const loaded = try temporary.loadFromDisk(self.io, self.allocator);
                if (loaded != .loaded) return error.WorkspaceEditTargetUnavailable;
                const updated = try lsp.workspace_edit.applyTextEdits(self.allocator, temporary.text.items, file_edit.edits.items);
                defer self.allocator.free(updated);
                temporary.text.items.len = 0;
                try temporary.text.appendSlice(self.allocator, updated);
                temporary.markChanged();
                try temporary.writeToDisk(self.io, self.allocator);
                changed += 1;
            }
        }
        return changed;
    }

    fn documentIndexOrAppend(self: *State, buffer_id: BufferId, path: []const u8, language_id: []const u8, revision: u64) !usize {
        if (self.documentIndex(buffer_id)) |index| return index;
        const file_uri = try lsp.uri.fileUriAlloc(self.allocator, path);
        errdefer self.allocator.free(file_uri);
        try self.documents.append(self.allocator, .{
            .buffer_id = buffer_id,
            .uri = file_uri,
            .language_id = language_id,
            .revision = revision,
        });
        return self.documents.items.len - 1;
    }

    fn documentIndex(self: *const State, buffer_id: BufferId) ?usize {
        for (self.documents.items, 0..) |document, index| {
            if (document.buffer_id == buffer_id) return index;
        }
        return null;
    }

    fn pendingIndex(self: *const State, id: u64) ?usize {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.id == id) return index;
        }
        return null;
    }

    fn track(self: *State, id: u64, kind: RequestKind, uri: []const u8) !void {
        try self.pending.append(self.allocator, .{ .id = id, .kind = kind, .uri = try self.allocator.dupe(u8, uri) });
    }

    fn uriForBuffer(self: *const State, buffer: *const buffer_module.Buffer) ![]u8 {
        return lsp.uri.fileUriAlloc(self.allocator, buffer.path orelse return error.NoFileName);
    }
};

fn versionOf(revision: u64) i64 {
    return @intCast(@min(revision, std.math.maxInt(i64)));
}

fn findBufferByPath(buffers: []buffer_module.Buffer, path: []const u8) ?*buffer_module.Buffer {
    for (buffers) |*buffer| {
        const candidate = buffer.path orelse continue;
        if (std.mem.eql(u8, candidate, path)) return buffer;
    }
    return null;
}

test "LSP bridge synchronizes buffers and consumes semantic responses" {
    var buffer = try buffer_module.Buffer.init(std.testing.allocator, 1, "/tmp/demo.zig");
    defer buffer.deinit(std.testing.allocator);
    try buffer.setLoadedText(std.testing.allocator, "const value = 1;\n");

    var state = State.init(std.testing.allocator, std.testing.io);
    defer state.deinit();
    const initialize_id = try state.beginDetachedForPath("/tmp/demo.zig", "/tmp");
    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try state.handleIncoming(initialize_response);
    try state.syncBuffer(&buffer, false);
    try std.testing.expect(std.mem.indexOf(u8, state.client.outbox.items, "textDocument/didOpen") != null);

    buffer.text.items.len = 0;
    try buffer.text.appendSlice(std.testing.allocator, "const value = 2;\n");
    buffer.markChanged();
    try state.syncBuffer(&buffer, false);
    try std.testing.expect(std.mem.indexOf(u8, state.client.outbox.items, "textDocument/didChange") != null);

    try state.handleIncoming(
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/demo.zig","version":1,"diagnostics":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"severity":1,"message":"demo"}]}}
    );
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics.itemsFor("file:///tmp/demo.zig").len);
    try std.testing.expect((try state.nextDiagnosticOffset(&buffer, 0, true)) != null);

    const hover_id = try state.requestHover(&buffer, 6);
    const hover_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"contents\":{{\"kind\":\"plaintext\",\"value\":\"i32\"}}}}}}", .{hover_id});
    defer std.testing.allocator.free(hover_response);
    try state.handleIncoming(hover_response);
    try std.testing.expectEqualStrings("i32", state.last_hover.?);

    const completion_id = try state.requestCompletion(&buffer, 6);
    const completion_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"isIncomplete\":false,\"items\":[{{\"label\":\"value\",\"insertText\":\"value\"}}]}}}}", .{completion_id});
    defer std.testing.allocator.free(completion_response);
    try state.handleIncoming(completion_response);
    try std.testing.expectEqual(@as(usize, 1), state.completionCount());
    try std.testing.expectEqualStrings("value", state.completionLabel(0).?);

    const formatting_id = try state.requestFormatting(&buffer, 4, true);
    const formatting_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"newText\":\"// formatted\\n\"}}]}}", .{formatting_id});
    defer std.testing.allocator.free(formatting_response);
    try state.handleIncoming(formatting_response);
    try std.testing.expectEqual(@as(usize, 1), state.pending_workspace_edit.?.files.items.len);
}
