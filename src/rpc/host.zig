const std = @import("std");
const api_module = @import("../api.zig");
const editor_module = @import("../editor.zig");
const msgpack = @import("msgpack.zig");
const protocol = @import("protocol.zig");

pub const zim_version = "0.9.0";

const capability_names = [_][]const u8{
    "buffers",
    "commands",
    "keymaps",
    "autocmds",
    "rpc.callbacks",
    "rpc.stdio",
    "rpc.local",
};

const Binding = struct {
    host: *Host,
    callback_id: u64,
};

const KeymapRegistration = struct {
    scope: api_module.keymaps.Scope,
    mode: editor_module.Mode,
    from: u21,
};

const RegistrationKind = union(enum) {
    command: struct {
        name: []u8,
        binding: *Binding,
    },
    keymap: KeymapRegistration,
    autocmd: struct {
        id: api_module.events.AutocmdId,
        binding: *Binding,
    },
};

const Registration = struct {
    remote_id: u64,
    kind: RegistrationKind,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    api: *api_module.Api,
    editor: *editor_module.Editor,
    handshaken: bool = false,
    next_registration_id: u64 = 1,
    registrations: std.ArrayList(Registration) = .empty,
    outbox: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, api: *api_module.Api, editor: *editor_module.Editor) Host {
        return .{ .allocator = allocator, .api = api, .editor = editor };
    }

    pub fn deinit(self: *Host) void {
        while (self.registrations.items.len != 0) self.removeAt(self.registrations.items.len - 1);
        self.registrations.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleFrame(self: *Host, frame: protocol.Frame, output: *std.ArrayList(u8)) !void {
        switch (frame) {
            .request => |request| try self.handleRequest(request, output),
            .notification => |notification| {
                var result = try self.dispatch(notification.method, notification.params);
                result.deinit(self.allocator);
            },
            .response => return error.UnexpectedClientResponse,
        }
    }

    pub fn queuedBytes(self: *const Host) []const u8 {
        return self.outbox.items;
    }

    pub fn clearQueued(self: *Host) void {
        self.outbox.clearRetainingCapacity();
    }

    pub fn registrationCount(self: *const Host) usize {
        return self.registrations.items.len;
    }

    fn handleRequest(self: *Host, request: protocol.Request, output: *std.ArrayList(u8)) !void {
        var result = self.dispatch(request.method, request.params) catch |err| {
            try protocol.encodeResponse(self.allocator, output, request.msgid, @errorName(err), .nil);
            return;
        };
        defer result.deinit(self.allocator);
        try protocol.encodeResponse(self.allocator, output, request.msgid, null, result);
    }

    fn dispatch(self: *Host, method: []const u8, params: []const msgpack.Value) !msgpack.Value {
        if (std.mem.eql(u8, method, "zim.ping")) {
            try expectCount(params, 0);
            return .{ .string = "pong" };
        }
        if (std.mem.eql(u8, method, "zim.api_info")) {
            try expectCount(params, 0);
            return self.apiInfo();
        }
        if (std.mem.eql(u8, method, "zim.handshake")) return self.handshake(params);
        if (!self.handshaken) return error.HandshakeRequired;

        if (std.mem.eql(u8, method, "zim.capabilities")) return self.capabilities(params);
        if (std.mem.eql(u8, method, "zim.buffer.current")) return self.bufferCurrent(params);
        if (std.mem.eql(u8, method, "zim.buffer.get_text")) return self.bufferGetText(params);
        if (std.mem.eql(u8, method, "zim.buffer.set_text")) return self.bufferSetText(params);
        if (std.mem.eql(u8, method, "zim.command.execute")) return self.commandExecute(params);
        if (std.mem.eql(u8, method, "zim.command.register")) return self.commandRegister(params);
        if (std.mem.eql(u8, method, "zim.keymap.set")) return self.keymapSet(params);
        if (std.mem.eql(u8, method, "zim.autocmd.register")) return self.autocmdRegister(params);
        if (std.mem.eql(u8, method, "zim.registration.remove")) return self.registrationRemove(params);
        if (std.mem.eql(u8, method, "zim.registration.count")) {
            try expectCount(params, 0);
            return .{ .unsigned = self.registrations.items.len };
        }
        return error.UnknownRpcMethod;
    }

    fn handshake(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 2);
        const requested_protocol = try asUnsigned(params[0]);
        const requested_api = try asUnsigned(params[1]);
        if (requested_protocol != protocol.protocol_version) return error.ProtocolVersionMismatch;
        if (requested_api != protocol.api_version) return error.ApiVersionMismatch;
        self.handshaken = true;
        return self.apiInfo();
    }

    fn apiInfo(self: *Host) !msgpack.Value {
        const entries = try self.allocator.alloc(msgpack.MapEntry, 5);
        entries[0] = .{ .key = .{ .string = "name" }, .value = .{ .string = "zim" } };
        entries[1] = .{ .key = .{ .string = "zim_version" }, .value = .{ .string = zim_version } };
        entries[2] = .{ .key = .{ .string = "protocol_version" }, .value = .{ .unsigned = protocol.protocol_version } };
        entries[3] = .{ .key = .{ .string = "api_version" }, .value = .{ .unsigned = protocol.api_version } };
        entries[4] = .{ .key = .{ .string = "callback_model" }, .value = .{ .string = "notifications" } };
        return .{ .map = entries };
    }

    fn capabilities(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 0);
        const items = try self.allocator.alloc(msgpack.Value, capability_names.len);
        for (capability_names, 0..) |name, index| items[index] = .{ .string = name };
        return .{ .array = items };
    }

    fn bufferCurrent(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 0);
        return .{ .unsigned = self.api.currentBuffer(self.editor).id };
    }

    fn bufferGetText(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        if (params.len > 1) return error.InvalidParams;
        const handle = if (params.len == 0)
            self.api.currentBuffer(self.editor)
        else
            api_module.BufferHandle{ .id = try asBufferId(params[0]) };
        return .{ .string = self.api.bufferText(self.editor, handle) orelse return error.InvalidBuffer };
    }

    fn bufferSetText(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 1);
        try self.api.setCurrentText(self.editor, try asString(params[0]));
        return .{ .boolean = true };
    }

    fn commandExecute(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        if (params.len < 1 or params.len > 2) return error.InvalidParams;
        const name = try asString(params[0]);
        const args = if (params.len == 2) try asString(params[1]) else "";
        try self.api.commandExecute(self.editor, name, args);
        return .{ .boolean = true };
    }

    fn commandRegister(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 3);
        const name = try asString(params[0]);
        const description = try asString(params[1]);
        const callback_id = try asUnsigned(params[2]);

        const binding = try self.allocator.create(Binding);
        errdefer self.allocator.destroy(binding);
        binding.* = .{ .host = self, .callback_id = callback_id };
        _ = try self.api.commandCreate(name, description, remoteCommandCallback, binding);
        errdefer _ = self.api.commandDelete(name);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const remote_id = self.nextRemoteId();
        try self.registrations.append(self.allocator, .{
            .remote_id = remote_id,
            .kind = .{ .command = .{ .name = owned_name, .binding = binding } },
        });
        return .{ .unsigned = remote_id };
    }

    fn keymapSet(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 4);
        const mode_name = try asString(params[0]);
        const mode = std.meta.stringToEnum(editor_module.Mode, mode_name) orelse return error.InvalidMode;
        const from = try asCodepoint(params[1]);
        const to = try asCodepoint(params[2]);
        const scope: api_module.keymaps.Scope = switch (params[3]) {
            .nil => .global,
            else => .{ .buffer = try asBufferId(params[3]) },
        };
        _ = try self.api.keymapSet(self.editor, scope, mode, from, to);
        errdefer _ = self.api.keymapDelete(self.editor, scope, mode, from);

        const remote_id = self.nextRemoteId();
        try self.registrations.append(self.allocator, .{
            .remote_id = remote_id,
            .kind = .{ .keymap = .{ .scope = scope, .mode = mode, .from = from } },
        });
        return .{ .unsigned = remote_id };
    }

    fn autocmdRegister(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 4);
        const kind_name = try asString(params[0]);
        const kind = std.meta.stringToEnum(api_module.events.Kind, kind_name) orelse return error.InvalidEventKind;
        const callback_id = try asUnsigned(params[1]);
        const buffer_id: ?editor_module.BufferId = switch (params[2]) {
            .nil => null,
            else => try asBufferId(params[2]),
        };
        const once = try asBool(params[3]);

        const binding = try self.allocator.create(Binding);
        errdefer self.allocator.destroy(binding);
        binding.* = .{ .host = self, .callback_id = callback_id };
        const id = try self.api.autocmdCreate(kind, .{ .buffer_id = buffer_id, .once = once }, remoteAutocmdCallback, binding);
        errdefer _ = self.api.autocmdDelete(id);

        const remote_id = self.nextRemoteId();
        try self.registrations.append(self.allocator, .{
            .remote_id = remote_id,
            .kind = .{ .autocmd = .{ .id = id, .binding = binding } },
        });
        return .{ .unsigned = remote_id };
    }

    fn registrationRemove(self: *Host, params: []const msgpack.Value) !msgpack.Value {
        try expectCount(params, 1);
        const remote_id = try asUnsigned(params[0]);
        for (self.registrations.items, 0..) |registration, index| {
            if (registration.remote_id == remote_id) {
                self.removeAt(index);
                return .{ .boolean = true };
            }
        }
        return .{ .boolean = false };
    }

    fn nextRemoteId(self: *Host) u64 {
        const id = self.next_registration_id;
        self.next_registration_id += 1;
        return id;
    }

    fn removeAt(self: *Host, index: usize) void {
        const registration = self.registrations.items[index];
        switch (registration.kind) {
            .command => |command| {
                _ = self.api.commandDelete(command.name);
                self.allocator.free(command.name);
                self.allocator.destroy(command.binding);
            },
            .keymap => |keymap| {
                _ = self.api.keymapDelete(self.editor, keymap.scope, keymap.mode, keymap.from);
            },
            .autocmd => |autocmd| {
                _ = self.api.autocmdDelete(autocmd.id);
                self.allocator.destroy(autocmd.binding);
            },
        }
        var cursor = index + 1;
        while (cursor < self.registrations.items.len) : (cursor += 1) {
            self.registrations.items[cursor - 1] = self.registrations.items[cursor];
        }
        self.registrations.items.len -= 1;
    }

    fn queueCommand(self: *Host, callback_id: u64, name: []const u8, args: []const u8) !void {
        const params = [_]msgpack.Value{
            .{ .unsigned = callback_id },
            .{ .string = name },
            .{ .string = args },
        };
        try protocol.encodeNotification(self.allocator, &self.outbox, "zim.callback.command", &params);
    }

    fn queueAutocmd(self: *Host, callback_id: u64, event: api_module.events.Event) !void {
        const params = [_]msgpack.Value{
            .{ .unsigned = callback_id },
            .{ .string = @tagName(event.kind) },
            .{ .unsigned = event.sequence },
            optionalUnsigned(event.buffer_id),
            optionalUnsigned(event.window_id),
            optionalUnsigned(event.tab_id),
        };
        try protocol.encodeNotification(self.allocator, &self.outbox, "zim.callback.autocmd", &params);
    }
};

fn remoteCommandCallback(context: *api_module.commands.Context) !void {
    const binding: *Binding = @ptrCast(@alignCast(context.user_data.?));
    try binding.host.queueCommand(binding.callback_id, context.name, context.args);
}

fn remoteAutocmdCallback(context: *api_module.events.Context) !void {
    const binding: *Binding = @ptrCast(@alignCast(context.user_data.?));
    try binding.host.queueAutocmd(binding.callback_id, context.event);
}

fn optionalUnsigned(value: anytype) msgpack.Value {
    return if (value) |number| .{ .unsigned = @intCast(number) } else .nil;
}

fn expectCount(params: []const msgpack.Value, expected: usize) !void {
    if (params.len != expected) return error.InvalidParams;
}

fn asString(value: msgpack.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidParams,
    };
}

fn asBool(value: msgpack.Value) !bool {
    return switch (value) {
        .boolean => |flag| flag,
        else => error.InvalidParams,
    };
}

fn asUnsigned(value: msgpack.Value) !u64 {
    return switch (value) {
        .unsigned => |number| number,
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidParams,
        else => error.InvalidParams,
    };
}

fn asBufferId(value: msgpack.Value) !editor_module.BufferId {
    const number = try asUnsigned(value);
    if (number > std.math.maxInt(editor_module.BufferId)) return error.InvalidBuffer;
    return @intCast(number);
}

fn asCodepoint(value: msgpack.Value) !u21 {
    const number = try asUnsigned(value);
    if (number > std.math.maxInt(u21)) return error.InvalidCodepoint;
    return @intCast(number);
}

fn requestThroughHost(host: *Host, msgid: u64, method: []const u8, params: []const msgpack.Value, response_wire: *std.ArrayList(u8)) !protocol.DecodedFrame {
    var request_wire: std.ArrayList(u8) = .empty;
    defer request_wire.deinit(std.testing.allocator);
    try protocol.encodeRequest(std.testing.allocator, &request_wire, msgid, method, params);
    var request = try protocol.decodeFrame(std.testing.allocator, request_wire.items);
    defer request.deinit(std.testing.allocator);
    try host.handleFrame(request.frame, response_wire);
    return protocol.decodeFrame(std.testing.allocator, response_wire.items);
}

test "RPC handshake exposes version metadata and capabilities" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var host = Host.init(std.testing.allocator, &api, &editor);
    defer host.deinit();

    const handshake = [_]msgpack.Value{ .{ .unsigned = protocol.protocol_version }, .{ .unsigned = protocol.api_version } };
    var response_wire: std.ArrayList(u8) = .empty;
    defer response_wire.deinit(std.testing.allocator);
    var response = try requestThroughHost(&host, 1, "zim.handshake", &handshake, &response_wire);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(host.handshaken);
    try std.testing.expect(response.frame.response.error_value == .nil);

    response_wire.clearRetainingCapacity();
    var capabilities_response = try requestThroughHost(&host, 2, "zim.capabilities", &.{}, &response_wire);
    defer capabilities_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(capability_names.len, capabilities_response.frame.response.result.array.len);
}

test "remote command and autocmd registrations queue callback notifications" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var host = Host.init(std.testing.allocator, &api, &editor);
    defer host.deinit();
    host.handshaken = true;

    const command_params = [_]msgpack.Value{
        .{ .string = "RemoteHello" },
        .{ .string = "remote test command" },
        .{ .unsigned = 77 },
    };
    var response_wire: std.ArrayList(u8) = .empty;
    defer response_wire.deinit(std.testing.allocator);
    var command_response = try requestThroughHost(&host, 1, "zim.command.register", &command_params, &response_wire);
    defer command_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), host.registrationCount());

    try api.commandExecute(&editor, "RemoteHello", "world");
    var callback = try protocol.decodeFrame(std.testing.allocator, host.queuedBytes());
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zim.callback.command", callback.frame.notification.method);
    try std.testing.expectEqual(@as(u64, 77), callback.frame.notification.params[0].unsigned);
    try std.testing.expectEqualStrings("world", callback.frame.notification.params[2].string);
    host.clearQueued();

    const autocmd_params = [_]msgpack.Value{
        .{ .string = "text_changed" },
        .{ .unsigned = 88 },
        .nil,
        .{ .boolean = false },
    };
    response_wire.clearRetainingCapacity();
    var autocmd_response = try requestThroughHost(&host, 2, "zim.autocmd.register", &autocmd_params, &response_wire);
    defer autocmd_response.deinit(std.testing.allocator);
    try api.emit(&editor, .{ .kind = .text_changed, .buffer_id = editor.currentBuffer().id });
    var event_callback = try protocol.decodeFrame(std.testing.allocator, host.queuedBytes());
    defer event_callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zim.callback.autocmd", event_callback.frame.notification.method);
    try std.testing.expectEqual(@as(u64, 88), event_callback.frame.notification.params[0].unsigned);
}

test "remote keymaps use the native keymap registry and clean up by remote id" {
    var editor = try editor_module.Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    var api = api_module.Api.init(std.testing.allocator);
    defer api.deinit();
    var host = Host.init(std.testing.allocator, &api, &editor);
    defer host.deinit();
    host.handshaken = true;

    const params = [_]msgpack.Value{
        .{ .string = "normal" },
        .{ .unsigned = 'z' },
        .{ .unsigned = 'i' },
        .nil,
    };
    var response_wire: std.ArrayList(u8) = .empty;
    defer response_wire.deinit(std.testing.allocator);
    var response = try requestThroughHost(&host, 1, "zim.keymap.set", &params, &response_wire);
    defer response.deinit(std.testing.allocator);
    const remote_id = response.frame.response.result.unsigned;

    _ = try api.handleKey(&editor, .{ .codepoint = 'z' });
    try std.testing.expectEqual(editor_module.Mode.insert, editor.mode);

    editor.mode = .normal;
    response_wire.clearRetainingCapacity();
    const remove_params = [_]msgpack.Value{.{ .unsigned = remote_id }};
    var removed = try requestThroughHost(&host, 2, "zim.registration.remove", &remove_params, &response_wire);
    defer removed.deinit(std.testing.allocator);
    try std.testing.expect(removed.frame.response.result.boolean);
    _ = try api.handleKey(&editor, .{ .codepoint = 'z' });
    try std.testing.expectEqual(editor_module.Mode.normal, editor.mode);
}
