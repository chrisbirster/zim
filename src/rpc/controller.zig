const std = @import("std");
const api_module = @import("../api.zig");
const editor_module = @import("../editor.zig");
const host_module = @import("host.zig");
const server = @import("server.zig");
const transport = @import("transport.zig");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    host: host_module.Host,
    endpoint: transport.LocalEndpoint,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    had_connection: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        api: *api_module.Api,
        editor: *editor_module.Editor,
        endpoint_name: []const u8,
    ) !Controller {
        return .{
            .allocator = allocator,
            .host = host_module.Host.init(allocator, api, editor),
            .endpoint = try transport.LocalEndpoint.init(allocator, endpoint_name),
        };
    }

    pub fn deinit(self: *Controller) void {
        self.host.deinit();
        self.endpoint.deinit();
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn poll(self: *Controller) !bool {
        var changed = false;
        if (try self.endpoint.pollAccept()) {
            self.had_connection = true;
            changed = true;
        }
        if (!self.endpoint.connected()) return changed;

        var scratch: [8192]u8 = undefined;
        var reads: usize = 0;
        while (reads < 16) : (reads += 1) {
            const result = try self.endpoint.readAvailable(&scratch);
            if (result.disconnected) {
                self.resetConnection();
                return true;
            }
            if (result.count == 0) break;
            if (self.input.items.len + result.count > server.max_pending_bytes) return error.RpcFrameTooLarge;
            try self.input.appendSlice(self.allocator, scratch[0..result.count]);
            changed = true;
        }

        if (self.input.items.len != 0) {
            const consumed = try server.processAvailable(self.allocator, &self.host, self.input.items, &self.output);
            if (consumed != 0) {
                const remaining = self.input.items.len - consumed;
                if (remaining != 0) std.mem.copyForwards(u8, self.input.items[0..remaining], self.input.items[consumed..]);
                self.input.items.len = remaining;
                changed = true;
            }
        }
        if (self.host.queuedBytes().len != 0) {
            try self.output.appendSlice(self.allocator, self.host.queuedBytes());
            self.host.clearQueued();
            changed = true;
        }

        if (self.output.items.len != 0) {
            const written = try self.endpoint.writeAvailable(self.output.items);
            if (written != 0) {
                const remaining = self.output.items.len - written;
                if (remaining != 0) std.mem.copyForwards(u8, self.output.items[0..remaining], self.output.items[written..]);
                self.output.items.len = remaining;
                changed = true;
            }
        }
        return changed;
    }

    pub fn serveUntilDisconnect(self: *Controller) !void {
        while (true) {
            _ = try self.poll();
            if (self.had_connection and !self.endpoint.connected()) return;
            transport.sleepOneMs();
        }
    }

    pub fn connected(self: *const Controller) bool {
        return self.endpoint.connected();
    }

    fn resetConnection(self: *Controller) void {
        const api = self.host.api;
        const editor = self.host.editor;
        self.host.deinit();
        self.host = host_module.Host.init(self.allocator, api, editor);
        self.input.clearRetainingCapacity();
        self.output.clearRetainingCapacity();
    }
};
