const client_mod = @import("client.zig");
const types = @import("types.zig");

pub fn didOpen(
    client: *client_mod.Client,
    uri: []const u8,
    language_id: []const u8,
    version: i64,
    text: []const u8,
) !void {
    try client.sendNotification("textDocument/didOpen", .{
        .textDocument = .{
            .uri = uri,
            .languageId = language_id,
            .version = version,
            .text = text,
        },
    });
}

pub fn didChange(
    client: *client_mod.Client,
    uri: []const u8,
    version: i64,
    text: []const u8,
) !void {
    try client.sendNotification("textDocument/didChange", .{
        .textDocument = .{ .uri = uri, .version = version },
        .contentChanges = &.{.{ .text = text }},
    });
}

pub fn didSave(client: *client_mod.Client, uri: []const u8, text: []const u8) !void {
    try client.sendNotification("textDocument/didSave", .{
        .textDocument = .{ .uri = uri },
        .text = text,
    });
}

pub fn didClose(client: *client_mod.Client, uri: []const u8) !void {
    try client.sendNotification("textDocument/didClose", .{
        .textDocument = .{ .uri = uri },
    });
}

pub fn hover(client: *client_mod.Client, uri: []const u8, position: types.Position) !u64 {
    return client.sendRequest("textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = position,
    });
}

pub fn signatureHelp(client: *client_mod.Client, uri: []const u8, position: types.Position) !u64 {
    return client.sendRequest("textDocument/signatureHelp", .{
        .textDocument = .{ .uri = uri },
        .position = position,
    });
}

pub fn definition(client: *client_mod.Client, uri: []const u8, position: types.Position) !u64 {
    return client.sendRequest("textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = position,
    });
}

pub fn references(client: *client_mod.Client, uri: []const u8, position: types.Position) !u64 {
    return client.sendRequest("textDocument/references", .{
        .textDocument = .{ .uri = uri },
        .position = position,
        .context = .{ .includeDeclaration = true },
    });
}

pub fn documentSymbols(client: *client_mod.Client, uri: []const u8) !u64 {
    return client.sendRequest("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } });
}

pub fn workspaceSymbols(client: *client_mod.Client, query: []const u8) !u64 {
    return client.sendRequest("workspace/symbol", .{ .query = query });
}

pub fn rename(client: *client_mod.Client, uri: []const u8, position: types.Position, new_name: []const u8) !u64 {
    return client.sendRequest("textDocument/rename", .{
        .textDocument = .{ .uri = uri },
        .position = position,
        .newName = new_name,
    });
}

pub fn codeAction(client: *client_mod.Client, uri: []const u8, range: types.Range, diagnostics: anytype) !u64 {
    return client.sendRequest("textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = range,
        .context = .{ .diagnostics = diagnostics },
    });
}

pub fn formatting(client: *client_mod.Client, uri: []const u8, tab_size: u32, insert_spaces: bool) !u64 {
    return client.sendRequest("textDocument/formatting", .{
        .textDocument = .{ .uri = uri },
        .options = .{
            .tabSize = tab_size,
            .insertSpaces = insert_spaces,
        },
    });
}

pub fn completion(client: *client_mod.Client, uri: []const u8, position: types.Position) !u64 {
    return client.sendRequest("textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = position,
        .context = .{ .triggerKind = 1 },
    });
}

test "document synchronization and feature requests use LSP methods" {
    const std = @import("std");
    var client = client_mod.Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();
    client.state = .ready;
    try didOpen(&client, "file:///tmp/demo.zig", "zig", 1, "const x = 1;");
    try didChange(&client, "file:///tmp/demo.zig", 2, "const x = 2;");
    _ = try hover(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 });
    _ = try signatureHelp(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 });
    _ = try definition(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 });
    _ = try references(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 });
    _ = try documentSymbols(&client, "file:///tmp/demo.zig");
    _ = try workspaceSymbols(&client, "demo");
    _ = try rename(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 }, "value");
    _ = try formatting(&client, "file:///tmp/demo.zig", 4, true);
    _ = try completion(&client, "file:///tmp/demo.zig", .{ .line = 0, .character = 6 });
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "textDocument/didOpen") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "textDocument/rename") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "textDocument/formatting") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "textDocument/completion") != null);
}
