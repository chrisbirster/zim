const std = @import("std");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const process = @import("process.zig");

pub const State = enum {
    stopped,
    initializing,
    ready,
    shutdown_requested,
    exited,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: ?process.Transport = null,
    decoder: framing.Decoder = .{},
    outbox: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    initialize_id: ?u64 = null,
    shutdown_id: ?u64 = null,
    state: State = .stopped,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Client {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Client) void {
        if (self.transport) |*transport| transport.kill();
        self.decoder.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn spawn(self: *Client, argv: []const []const u8, root_uri: []const u8) !void {
        if (self.transport != null) return error.AlreadyRunning;
        self.transport = try process.Transport.spawn(self.io, argv);
        errdefer {
            self.transport.?.kill();
            self.transport = null;
        }
        try self.beginInitialize(root_uri);
    }

    pub fn beginInitialize(self: *Client, root_uri: []const u8) !u64 {
        if (self.state != .stopped) return error.InvalidState;
        const id = try self.sendRequest("initialize", .{
            .processId = @as(?i64, null),
            .rootUri = root_uri,
            .capabilities = .{
                .workspace = .{ .workspaceEdit = .{ .documentChanges = true } },
                .textDocument = .{
                    .synchronization = .{ .dynamicRegistration = false, .willSave = false, .didSave = true },
                    .hover = .{ .dynamicRegistration = false },
                    .signatureHelp = .{ .dynamicRegistration = false },
                    .definition = .{ .dynamicRegistration = false },
                    .references = .{ .dynamicRegistration = false },
                    .documentSymbol = .{ .dynamicRegistration = false },
                    .rename = .{ .dynamicRegistration = false },
                    .codeAction = .{ .dynamicRegistration = false },
                },
            },
        });
        self.initialize_id = id;
        self.state = .initializing;
        return id;
    }

    pub fn handleBody(self: *Client, body: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        const id = protocol.responseId(parsed.value) orelse return;
        if (self.initialize_id != null and id == self.initialize_id.?) {
            if (parsed.value.object.get("error") != null) return error.InitializeFailed;
            self.initialize_id = null;
            self.state = .ready;
            try self.sendNotification("initialized", .{});
            return;
        }
        if (self.shutdown_id != null and id == self.shutdown_id.?) {
            self.shutdown_id = null;
            try self.sendNotification("exit", .{});
            if (self.transport) |*transport| transport.closeInput();
            self.state = .exited;
        }
    }

    pub fn requestShutdown(self: *Client) !void {
        if (self.state != .ready) return error.InvalidState;
        self.shutdown_id = try self.sendRequest("shutdown", .{});
        self.state = .shutdown_requested;
    }

    pub fn sendRequest(self: *Client, method_name: []const u8, params: anytype) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        const bytes = try protocol.request(self.allocator, id, method_name, params);
        defer self.allocator.free(bytes);
        try self.emit(bytes);
        return id;
    }

    pub fn sendNotification(self: *Client, method_name: []const u8, params: anytype) !void {
        const bytes = try protocol.notification(self.allocator, method_name, params);
        defer self.allocator.free(bytes);
        try self.emit(bytes);
    }

    pub fn receiveOnce(self: *Client, scratch: []u8) !?[]u8 {
        if (self.transport) |*transport| {
            const count = transport.read(scratch) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            if (count == 0) return null;
            try self.decoder.feed(self.allocator, scratch[0..count]);
            return self.decoder.next(self.allocator);
        }
        return error.ProcessNotRunning;
    }

    pub fn clearOutbox(self: *Client) void {
        self.outbox.items.len = 0;
    }

    fn emit(self: *Client, bytes: []const u8) !void {
        if (self.transport) |*transport| {
            try transport.send(bytes);
        } else {
            try self.outbox.appendSlice(self.allocator, bytes);
        }
    }
};

test "client negotiates initialize and shutdown lifecycle without a process" {
    var client = Client.init(std.testing.allocator, std.testing.io);
    defer client.deinit();
    const initialize_id = try client.beginInitialize("file:///tmp/project");
    try std.testing.expectEqual(State.initializing, client.state);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "\"method\":\"initialize\"") != null);

    const initialize_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}", .{initialize_id});
    defer std.testing.allocator.free(initialize_response);
    try client.handleBody(initialize_response);
    try std.testing.expectEqual(State.ready, client.state);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "\"method\":\"initialized\"") != null);

    client.clearOutbox();
    try client.requestShutdown();
    const shutdown_id = client.shutdown_id.?;
    const shutdown_response = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{shutdown_id});
    defer std.testing.allocator.free(shutdown_response);
    try client.handleBody(shutdown_response);
    try std.testing.expectEqual(State.exited, client.state);
    try std.testing.expect(std.mem.indexOf(u8, client.outbox.items, "\"method\":\"exit\"") != null);
}
