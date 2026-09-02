const std = @import("std");
const api_module = @import("api.zig");
const editor_module = @import("editor.zig");
const lua_runtime = @import("lua_runtime.zig");

pub const zim_version = "0.4.0";
pub const plugin_api_version: u32 = 1;

const manifest_name = "zim-plugin.meta";
const lock_name = "plugins.lock";
const lock_header = "# zim-plugin-lock-v1\n";
const max_file_bytes = 4 * 1024 * 1024;
const max_git_output = 1024 * 1024;

const PluginState = enum {
    loaded,
    failed,
    incompatible,
};

const Plugin = struct {
    name: []u8,
    version: []u8,
    capabilities: []u8,
    state: PluginState,
    detail: []u8,

    fn deinit(self: *Plugin, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.capabilities);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

const LockEntry = struct {
    name: []u8,
    source: []u8,
    revision: []u8,

    fn deinit(self: *LockEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
        allocator.free(self.revision);
        self.* = undefined;
    }
};

const Manifest = struct {
    name: []u8,
    version: []u8,
    entry: []u8,
    capabilities: []u8,
    min_zim: []u8,
    max_zim: ?[]u8,
    api_version: u32,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.entry);
        allocator.free(self.capabilities);
        allocator.free(self.min_zim);
        if (self.max_zim) |value| allocator.free(value);
        self.* = undefined;
    }
};

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config_root: []u8,
    plugins_root: []u8,
    lock_path: []u8,
    api: *api_module.Api,
    editor: *editor_module.Editor,
    lua: *lua_runtime.Runtime,
    plugins: std.ArrayList(Plugin) = .empty,
    locks: std.ArrayList(LockEntry) = .empty,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_root: []const u8,
        api: *api_module.Api,
        editor: *editor_module.Editor,
        lua: *lua_runtime.Runtime,
    ) !*Manager {
        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);

        const owned_root = try allocator.dupe(u8, config_root);
        errdefer allocator.free(owned_root);
        const plugins_root = try std.fmt.allocPrint(allocator, "{s}/plugins", .{config_root});
        errdefer allocator.free(plugins_root);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_root, lock_name });
        errdefer allocator.free(lock_path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .config_root = owned_root,
            .plugins_root = plugins_root,
            .lock_path = lock_path,
            .api = api,
            .editor = editor,
            .lua = lua,
        };
        errdefer self.deinit();

        try std.Io.Dir.cwd().createDirPath(io, self.plugins_root);
        try self.loadLock();
        try self.registerCommands();
        try self.configureLuaSearchPath();
        try self.loadInstalled();
        return self;
    }

    pub fn destroy(self: *Manager) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn deinit(self: *Manager) void {
        _ = self.api.commandDelete("PackAdd");
        _ = self.api.commandDelete("PackUpdate");
        _ = self.api.commandDelete("PackRemove");
        _ = self.api.commandDelete("PackList");
        _ = self.api.commandDelete("Commands");
        _ = self.api.commandDelete("Keymaps");

        for (self.plugins.items) |*plugin| plugin.deinit(self.allocator);
        self.plugins.deinit(self.allocator);
        for (self.locks.items) |*entry| entry.deinit(self.allocator);
        self.locks.deinit(self.allocator);
        self.allocator.free(self.config_root);
        self.allocator.free(self.plugins_root);
        self.allocator.free(self.lock_path);
        self.* = undefined;
    }

    fn registerCommands(self: *Manager) !void {
        _ = try self.api.commandCreate("PackAdd", "install a Git-backed Zim plugin", packAddCommand, self);
        _ = try self.api.commandCreate("PackUpdate", "update one or all installed plugins", packUpdateCommand, self);
        _ = try self.api.commandCreate("PackRemove", "remove an installed plugin", packRemoveCommand, self);
        _ = try self.api.commandCreate("PackList", "list plugin load and lock state", packListCommand, self);
        _ = try self.api.commandCreate("Commands", "list registered public commands", commandsCommand, self);
        _ = try self.api.commandCreate("Keymaps", "list registered public keymaps", keymapsCommand, self);
    }

    fn configureLuaSearchPath(self: *Manager) !void {
        if (std.mem.indexOf(u8, self.plugins_root, "]=]") != null) return error.UnsupportedPluginPath;
        const source = try std.fmt.allocPrintSentinel(self.allocator,
            \\local root = [=[{s}]=]
            \\package.path = package.path
            \\  .. ';' .. root .. '/?.lua'
            \\  .. ';' .. root .. '/?/init.lua'
            \\  .. ';' .. root .. '/?/lua/?.lua'
            \\  .. ';' .. root .. '/?/lua/?/init.lua'
        , .{self.plugins_root}, 0);
        defer self.allocator.free(source);
        try self.lua.eval(source);
    }

    fn loadInstalled(self: *Manager) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.plugins_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!validPluginName(entry.name)) continue;
            try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]u8, names.items, {}, lessName);

        for (names.items) |name| try self.loadOne(name);
        if (self.plugins.items.len != 0) self.reportStartupSummary();
    }

    fn loadOne(self: *Manager, name: []const u8) !void {
        const root = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.plugins_root, name });
        defer self.allocator.free(root);
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, manifest_name });
        defer self.allocator.free(manifest_path);

        const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            manifest_path,
            self.allocator,
            .limited(max_file_bytes),
        ) catch |err| {
            try self.appendFailure(name, "0.0.0", "", .failed, @errorName(err));
            return;
        };
        defer self.allocator.free(manifest_bytes);

        var manifest = parseManifest(self.allocator, manifest_bytes) catch |err| {
            try self.appendFailure(name, "0.0.0", "", .failed, @errorName(err));
            return;
        };
        defer manifest.deinit(self.allocator);

        if (!std.mem.eql(u8, name, manifest.name)) {
            try self.appendFailure(name, manifest.version, manifest.capabilities, .failed, "manifest name does not match plugin directory");
            return;
        }
        if (manifest.api_version != plugin_api_version) {
            try self.appendFailure(name, manifest.version, manifest.capabilities, .incompatible, "unsupported plugin API version");
            return;
        }
        if (!versionInRange(zim_version, manifest.min_zim, manifest.max_zim)) {
            try self.appendFailure(name, manifest.version, manifest.capabilities, .incompatible, "Zim version is outside plugin compatibility range");
            return;
        }
        if (!capabilitiesSupported(manifest.capabilities)) {
            try self.appendFailure(name, manifest.version, manifest.capabilities, .incompatible, "plugin requests an unsupported capability");
            return;
        }
        if (!safeRelativePath(manifest.entry)) {
            try self.appendFailure(name, manifest.version, manifest.capabilities, .failed, "plugin entry must be a safe relative path");
            return;
        }

        const command_count = self.api.commands.entries.items.len;
        const keymap_snapshot = try self.allocator.dupe(api_module.keymaps.Entry, self.api.keymaps.entries.items);
        defer self.allocator.free(keymap_snapshot);
        const autocmd_count = self.api.autocmds.entries.items.len;

        const entry_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, manifest.entry });
        defer self.allocator.free(entry_path);
        const loaded = self.lua.loadFile(self.io, entry_path) catch |err| {
            self.rollbackRegistrations(command_count, keymap_snapshot, autocmd_count);
            try self.appendFailure(name, manifest.version, manifest.capabilities, .failed, @errorName(err));
            return;
        };
        if (!loaded) {
            self.rollbackRegistrations(command_count, keymap_snapshot, autocmd_count);
            try self.appendFailure(name, manifest.version, manifest.capabilities, .failed, "plugin entry file not found");
            return;
        }

        try self.appendFailure(name, manifest.version, manifest.capabilities, .loaded, "loaded");
    }

    fn rollbackRegistrations(
        self: *Manager,
        command_count: usize,
        keymap_snapshot: []const api_module.keymaps.Entry,
        autocmd_count: usize,
    ) void {
        while (self.api.commands.entries.items.len > command_count) {
            const name = self.api.commands.entries.items[self.api.commands.entries.items.len - 1].name;
            _ = self.api.commandDelete(name);
        }
        while (self.api.autocmds.entries.items.len > autocmd_count) {
            const id = self.api.autocmds.entries.items[self.api.autocmds.entries.items.len - 1].id;
            _ = self.api.autocmdDelete(id);
        }
        while (self.api.keymaps.entries.items.len > keymap_snapshot.len) {
            const entry = self.api.keymaps.entries.items[self.api.keymaps.entries.items.len - 1];
            _ = self.api.keymapDelete(self.editor, entry.scope, entry.mode, entry.from);
        }
        for (keymap_snapshot) |entry| {
            _ = self.api.keymapSet(self.editor, entry.scope, entry.mode, entry.from, entry.to) catch {};
        }
    }

    fn appendFailure(
        self: *Manager,
        name: []const u8,
        version: []const u8,
        capabilities: []const u8,
        state: PluginState,
        detail: []const u8,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_version = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(owned_version);
        const owned_capabilities = try self.allocator.dupe(u8, capabilities);
        errdefer self.allocator.free(owned_capabilities);
        const owned_detail = try self.allocator.dupe(u8, detail);
        errdefer self.allocator.free(owned_detail);
        try self.plugins.append(self.allocator, .{
            .name = owned_name,
            .version = owned_version,
            .capabilities = owned_capabilities,
            .state = state,
            .detail = owned_detail,
        });
    }

    fn reportStartupSummary(self: *Manager) void {
        var loaded: usize = 0;
        var failed: usize = 0;
        for (self.plugins.items) |plugin| switch (plugin.state) {
            .loaded => loaded += 1,
            .failed, .incompatible => failed += 1,
        };
        if (failed == 0) return;
        self.setStatusFmt("plugins: {d} loaded, {d} failed; :PackList for details", .{ loaded, failed });
    }

    fn packAdd(self: *Manager, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const source = tokens.next() orelse return error.Usage;
        const revision = tokens.next();
        if (tokens.next() != null) return error.Usage;

        const name = try derivePluginName(self.allocator, source);
        defer self.allocator.free(name);
        const destination = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.plugins_root, name });
        defer self.allocator.free(destination);

        try self.runGitSuccess(&.{ "git", "clone", "--filter=blob:none", source, destination });
        errdefer std.Io.Dir.cwd().deleteTree(self.io, destination) catch {};

        if (revision) |target| {
            try self.runGitSuccess(&.{ "git", "-C", destination, "checkout", "--detach", target });
        }
        const head = try self.gitHead(destination);
        defer self.allocator.free(head);
        try self.setLock(name, source, head);
        try self.writeLock();
        self.setStatusFmt("installed {s}@{s}; restart Zim to load", .{ name, shortRevision(head) });
    }

    fn packUpdate(self: *Manager, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const maybe_name = tokens.next();
        const maybe_revision = tokens.next();
        if (tokens.next() != null) return error.Usage;

        if (maybe_name) |name| {
            if (!validPluginName(name)) return error.InvalidPluginName;
            const index = self.findLockIndex(name) orelse return error.PluginNotInstalled;
            try self.updateLocked(index, maybe_revision);
            try self.writeLock();
            self.setStatusFmt("updated {s}@{s}; restart Zim to reload", .{ self.locks.items[index].name, shortRevision(self.locks.items[index].revision) });
            return;
        }
        if (maybe_revision != null) return error.Usage;

        if (self.locks.items.len == 0) {
            self.setStatus("no locked plugins");
            return;
        }
        var index: usize = 0;
        while (index < self.locks.items.len) : (index += 1) try self.updateLocked(index, null);
        try self.writeLock();
        self.setStatusFmt("updated {d} plugins; restart Zim to reload", .{self.locks.items.len});
    }

    fn updateLocked(self: *Manager, index: usize, revision: ?[]const u8) !void {
        const entry = &self.locks.items[index];
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.plugins_root, entry.name });
        defer self.allocator.free(path);

        try self.runGitSuccess(&.{ "git", "-C", path, "fetch", "origin", "--tags", "--prune" });
        if (revision) |target| {
            try self.runGitSuccess(&.{ "git", "-C", path, "checkout", "--detach", target });
        } else {
            try self.runGitSuccess(&.{ "git", "-C", path, "remote", "set-head", "origin", "-a" });
            try self.runGitSuccess(&.{ "git", "-C", path, "checkout", "--detach", "origin/HEAD" });
        }
        const head = try self.gitHead(path);
        defer self.allocator.free(head);
        const owned = try self.allocator.dupe(u8, head);
        self.allocator.free(entry.revision);
        entry.revision = owned;
    }

    fn packRemove(self: *Manager, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const name = tokens.next() orelse return error.Usage;
        if (tokens.next() != null) return error.Usage;
        if (!validPluginName(name)) return error.InvalidPluginName;
        const index = self.findLockIndex(name) orelse return error.PluginNotInstalled;
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.plugins_root, name });
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().deleteTree(self.io, path);
        self.removeLockAt(index);
        try self.writeLock();
        self.setStatusFmt("removed {s}; restart Zim to unload", .{name});
    }

    fn packList(self: *Manager) void {
        var used: usize = 0;
        if (self.plugins.items.len == 0 and self.locks.items.len == 0) {
            self.setStatus("no plugins installed");
            return;
        }
        for (self.plugins.items, 0..) |plugin, index| {
            if (index != 0) appendStatus(&used, self.editor, " | ");
            appendStatusFmt(&used, self.editor, "{s}:{s}", .{ plugin.name, @tagName(plugin.state) });
            if (self.findLockIndex(plugin.name)) |lock_index| {
                appendStatusFmt(&used, self.editor, "@{s}", .{shortRevision(self.locks.items[lock_index].revision)});
            }
            if (plugin.state != .loaded) appendStatusFmt(&used, self.editor, "({s})", .{plugin.detail});
        }
        for (self.locks.items) |entry| {
            if (self.findPlugin(entry.name) != null) continue;
            if (used != 0) appendStatus(&used, self.editor, " | ");
            appendStatusFmt(&used, self.editor, "{s}:installed@{s}(restart to load)", .{ entry.name, shortRevision(entry.revision) });
        }
        self.editor.status_len = used;
    }

    fn listCommands(self: *Manager) void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (self.api.commands.entries.items) |entry| names.append(self.allocator, entry.name) catch {
            self.setStatus("Commands: out of memory");
            return;
        };
        std.mem.sort([]const u8, names.items, {}, lessConstName);
        var used: usize = 0;
        appendStatus(&used, self.editor, "Commands: ");
        for (names.items, 0..) |name, index| {
            if (index != 0) appendStatus(&used, self.editor, ", ");
            appendStatus(&used, self.editor, name);
        }
        self.editor.status_len = used;
    }

    fn listKeymaps(self: *Manager) void {
        var used: usize = 0;
        appendStatus(&used, self.editor, "Keymaps: ");
        if (self.api.keymaps.entries.items.len == 0) appendStatus(&used, self.editor, "none");
        for (self.api.keymaps.entries.items, 0..) |entry, index| {
            if (index != 0) appendStatus(&used, self.editor, ", ");
            switch (entry.scope) {
                .global => appendStatusFmt(&used, self.editor, "{s}:U+{X:0>4}->U+{X:0>4}", .{ modeName(entry.mode), entry.from, entry.to }),
                .buffer => |buffer_id| appendStatusFmt(&used, self.editor, "{s}[buf {d}]:U+{X:0>4}->U+{X:0>4}", .{ modeName(entry.mode), buffer_id, entry.from, entry.to }),
            }
        }
        self.editor.status_len = used;
    }

    fn runGitSuccess(self: *Manager, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(max_git_output),
            .stderr_limit = .limited(max_git_output),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
    }

    fn gitHead(self: *Manager, path: []const u8) ![]u8 {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "-C", path, "rev-parse", "HEAD" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        const revision = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (revision.len == 0) return error.GitFailed;
        return self.allocator.dupe(u8, revision);
    }

    fn loadLock(self: *Manager) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.lock_path,
            self.allocator,
            .limited(max_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const name = fields.next() orelse continue;
            const source = fields.next() orelse continue;
            const revision = fields.next() orelse continue;
            if (fields.next() != null or !validPluginName(name) or source.len == 0 or revision.len == 0) continue;
            try self.setLock(name, source, revision);
        }
        self.sortLocks();
    }

    fn writeLock(self: *Manager) !void {
        self.sortLocks();
        const file = try std.Io.Dir.cwd().createFile(self.io, self.lock_path, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, lock_header);
        for (self.locks.items) |entry| {
            try file.writeStreamingAll(self.io, entry.name);
            try file.writeStreamingAll(self.io, "\t");
            try file.writeStreamingAll(self.io, entry.source);
            try file.writeStreamingAll(self.io, "\t");
            try file.writeStreamingAll(self.io, entry.revision);
            try file.writeStreamingAll(self.io, "\n");
        }
    }

    fn setLock(self: *Manager, name: []const u8, source: []const u8, revision: []const u8) !void {
        if (!validPluginName(name)) return error.InvalidPluginName;
        if (self.findLockIndex(name)) |index| {
            const owned_source = try self.allocator.dupe(u8, source);
            errdefer self.allocator.free(owned_source);
            const owned_revision = try self.allocator.dupe(u8, revision);
            self.allocator.free(self.locks.items[index].source);
            self.allocator.free(self.locks.items[index].revision);
            self.locks.items[index].source = owned_source;
            self.locks.items[index].revision = owned_revision;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        const owned_revision = try self.allocator.dupe(u8, revision);
        errdefer self.allocator.free(owned_revision);
        try self.locks.append(self.allocator, .{
            .name = owned_name,
            .source = owned_source,
            .revision = owned_revision,
        });
    }

    fn removeLockAt(self: *Manager, index: usize) void {
        self.locks.items[index].deinit(self.allocator);
        var cursor = index + 1;
        while (cursor < self.locks.items.len) : (cursor += 1) self.locks.items[cursor - 1] = self.locks.items[cursor];
        self.locks.items.len -= 1;
    }

    fn findLockIndex(self: *const Manager, name: []const u8) ?usize {
        for (self.locks.items, 0..) |entry, index| if (std.mem.eql(u8, entry.name, name)) return index;
        return null;
    }

    fn findPlugin(self: *const Manager, name: []const u8) ?*const Plugin {
        for (self.plugins.items) |*plugin| if (std.mem.eql(u8, plugin.name, name)) return plugin;
        return null;
    }

    fn sortLocks(self: *Manager) void {
        std.mem.sort(LockEntry, self.locks.items, {}, lessLock);
    }

    fn setStatus(self: *Manager, message: []const u8) void {
        const len = @min(message.len, self.editor.status_buffer.len);
        @memcpy(self.editor.status_buffer[0..len], message[0..len]);
        self.editor.status_len = len;
    }

    fn setStatusFmt(self: *Manager, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.editor.status_buffer, format, args) catch {
            self.setStatus("plugin status too long");
            return;
        };
        self.editor.status_len = written.len;
    }
};

fn packAddCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    self.packAdd(context.args) catch |err| {
        if (err == error.Usage) self.setStatus("usage: :PackAdd <git-url> [revision]") else self.setStatusFmt("PackAdd: {s}", .{@errorName(err)});
    };
}

fn packUpdateCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    self.packUpdate(context.args) catch |err| {
        if (err == error.Usage) self.setStatus("usage: :PackUpdate [name] [revision]") else self.setStatusFmt("PackUpdate: {s}", .{@errorName(err)});
    };
}

fn packRemoveCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    self.packRemove(context.args) catch |err| {
        if (err == error.Usage) self.setStatus("usage: :PackRemove <name>") else self.setStatusFmt("PackRemove: {s}", .{@errorName(err)});
    };
}

fn packListCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    if (std.mem.trim(u8, context.args, " \t").len != 0) {
        self.setStatus("usage: :PackList");
        return;
    }
    self.packList();
}

fn commandsCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    if (std.mem.trim(u8, context.args, " \t").len != 0) {
        self.setStatus("usage: :Commands");
        return;
    }
    self.listCommands();
}

fn keymapsCommand(context: *api_module.commands.Context) !void {
    const self: *Manager = @ptrCast(@alignCast(context.user_data.?));
    if (std.mem.trim(u8, context.args, " \t").len != 0) {
        self.setStatus("usage: :Keymaps");
        return;
    }
    self.listKeymaps();
}

fn parseManifest(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    var name: ?[]u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var version: ?[]u8 = null;
    errdefer if (version) |value| allocator.free(value);
    var entry: ?[]u8 = null;
    errdefer if (entry) |value| allocator.free(value);
    var capabilities: ?[]u8 = null;
    errdefer if (capabilities) |value| allocator.free(value);
    var min_zim: ?[]u8 = null;
    errdefer if (min_zim) |value| allocator.free(value);
    var max_zim: ?[]u8 = null;
    errdefer if (max_zim) |value| allocator.free(value);
    var api_version: ?u32 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidManifest;

        if (std.mem.eql(u8, key, "name")) {
            if (name != null) return error.InvalidManifest;
            name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (version != null) return error.InvalidManifest;
            _ = try parseVersion(value);
            version = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "entry")) {
            if (entry != null) return error.InvalidManifest;
            entry = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "capabilities")) {
            if (capabilities != null) return error.InvalidManifest;
            capabilities = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "min_zim")) {
            if (min_zim != null) return error.InvalidManifest;
            _ = try parseVersion(value);
            min_zim = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "max_zim")) {
            if (max_zim != null) return error.InvalidManifest;
            _ = try parseVersion(value);
            max_zim = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "zim_api")) {
            if (api_version != null) return error.InvalidManifest;
            api_version = try std.fmt.parseInt(u32, value, 10);
        } else {
            return error.UnknownManifestKey;
        }
    }

    return .{
        .name = name orelse return error.MissingManifestName,
        .version = version orelse return error.MissingManifestVersion,
        .entry = entry orelse try allocator.dupe(u8, "plugin.lua"),
        .capabilities = capabilities orelse try allocator.dupe(u8, ""),
        .min_zim = min_zim orelse try allocator.dupe(u8, zim_version),
        .max_zim = max_zim,
        .api_version = api_version orelse return error.MissingPluginApi,
    };
}

fn parseVersion(text: []const u8) !Version {
    var fields = std.mem.splitScalar(u8, text, '.');
    const major = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidVersion, 10);
    const minor = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidVersion, 10);
    const patch = try std.fmt.parseInt(u32, fields.next() orelse return error.InvalidVersion, 10);
    if (fields.next() != null) return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn compareVersion(a: Version, b: Version) std.math.Order {
    if (a.major != b.major) return std.math.order(a.major, b.major);
    if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
    return std.math.order(a.patch, b.patch);
}

fn versionInRange(current_text: []const u8, min_text: []const u8, max_text: ?[]const u8) bool {
    const current = parseVersion(current_text) catch return false;
    const minimum = parseVersion(min_text) catch return false;
    if (compareVersion(current, minimum) == .lt) return false;
    if (max_text) |text| {
        const maximum = parseVersion(text) catch return false;
        if (compareVersion(current, maximum) == .gt) return false;
    }
    return true;
}

fn capabilitiesSupported(text: []const u8) bool {
    if (text.len == 0) return true;
    var capabilities = std.mem.splitScalar(u8, text, ',');
    while (capabilities.next()) |raw| {
        const capability = std.mem.trim(u8, raw, " \t");
        if (capability.len == 0) return false;
        if (std.mem.eql(u8, capability, "commands")) continue;
        if (std.mem.eql(u8, capability, "keymaps")) continue;
        if (std.mem.eql(u8, capability, "autocmds")) continue;
        if (std.mem.eql(u8, capability, "buffers")) continue;
        if (std.mem.eql(u8, capability, "lsp")) continue;
        return false;
    }
    return true;
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn derivePluginName(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, source, "/\\");
    if (trimmed.len == 0) return error.InvalidPluginSource;
    const slash = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
    const raw = if (slash) |index| trimmed[index + 1 ..] else trimmed;
    const name = if (std.mem.endsWith(u8, raw, ".git")) raw[0 .. raw.len - 4] else raw;
    if (!validPluginName(name)) return error.InvalidPluginName;
    return allocator.dupe(u8, name);
}

fn validPluginName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        const alpha = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
        const digit = byte >= '0' and byte <= '9';
        if (!(alpha or digit or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 8)];
}

fn modeName(mode: editor_module.Mode) []const u8 {
    return switch (mode) {
        .normal => "normal",
        .insert => "insert",
        .visual => "visual",
        .visual_line => "visual_line",
        .visual_block => "visual_block",
        .operator_pending => "operator_pending",
        .command_line => "command_line",
    };
}

fn lessName(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessConstName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessLock(_: void, a: LockEntry, b: LockEntry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn appendStatus(used: *usize, editor: *editor_module.Editor, text: []const u8) void {
    if (used.* >= editor.status_buffer.len) return;
    const count = @min(text.len, editor.status_buffer.len - used.*);
    @memcpy(editor.status_buffer[used.* .. used.* + count], text[0..count]);
    used.* += count;
}

fn appendStatusFmt(used: *usize, editor: *editor_module.Editor, comptime format: []const u8, args: anytype) void {
    if (used.* >= editor.status_buffer.len) return;
    const written = std.fmt.bufPrint(editor.status_buffer[used.*..], format, args) catch return;
    used.* += written.len;
}

test "plugin manifest parses compatibility metadata" {
    var manifest = try parseManifest(std.testing.allocator,
        \\name=hello
        \\version=1.2.3
        \\zim_api=1
        \\min_zim=0.4.0
        \\max_zim=0.5.9
        \\entry=lua/hello/init.lua
        \\capabilities=commands,keymaps,autocmds
    );
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", manifest.name);
    try std.testing.expectEqualStrings("1.2.3", manifest.version);
    try std.testing.expectEqual(@as(u32, 1), manifest.api_version);
    try std.testing.expect(versionInRange("0.4.0", manifest.min_zim, manifest.max_zim));
    try std.testing.expect(!versionInRange("0.6.0", manifest.min_zim, manifest.max_zim));
    try std.testing.expect(capabilitiesSupported(manifest.capabilities));
}

test "plugin source derives a safe deterministic install name" {
    const https_name = try derivePluginName(std.testing.allocator, "https://github.com/example/hello-zim.git");
    defer std.testing.allocator.free(https_name);
    try std.testing.expectEqualStrings("hello-zim", https_name);
    const ssh_name = try derivePluginName(std.testing.allocator, "git@github.com:example/hello-zim.git");
    defer std.testing.allocator.free(ssh_name);
    try std.testing.expectEqualStrings("hello-zim", ssh_name);
    try std.testing.expectError(error.InvalidPluginName, derivePluginName(std.testing.allocator, "https://example.com/.."));
}

test "plugin discovery is sorted and isolates a broken Lua plugin" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "plugins/a-good");
    try tmp.dir.writeFile(io, .{ .sub_path = "plugins/a-good/zim-plugin.meta", .data =
        \\name=a-good
        \\version=0.1.0
        \\zim_api=1
        \\min_zim=0.4.0
        \\capabilities=commands,keymaps,autocmds
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "plugins/a-good/plugin.lua", .data =
        \\zim.command.create('PluginHello', function() end)
        \\zim.keymap.set('normal', 'z', 'i')
        \\zim.autocmd.create('TextChanged', function() end)
    });
    try tmp.dir.createDirPath(io, "plugins/z-bad");
    try tmp.dir.writeFile(io, .{ .sub_path = "plugins/z-bad/zim-plugin.meta", .data =
        \\name=z-bad
        \\version=0.1.0
        \\zim_api=1
        \\min_zim=0.4.0
        \\capabilities=commands,keymaps,autocmds
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "plugins/z-bad/plugin.lua", .data =
        \\zim.command.create('BrokenPartial', function() end)
        \\zim.keymap.set('normal', 'x', 'i')
        \\zim.autocmd.create('TextChanged', function() end)
        \\error('broken after registration')
    });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var editor = try editor_module.Editor.init(allocator, io, null);
    defer editor.deinit();
    var api = api_module.Api.init(allocator);
    defer api.deinit();
    var lua = try lua_runtime.Runtime.init(allocator, &api, &editor);
    defer lua.deinit();
    try lua.eval("zim.version = '0.4.0'");

    const manager = try Manager.create(allocator, io, root, &api, &editor, &lua);
    defer manager.destroy();

    try std.testing.expectEqual(@as(usize, 2), manager.plugins.items.len);
    try std.testing.expectEqualStrings("a-good", manager.plugins.items[0].name);
    try std.testing.expectEqual(PluginState.loaded, manager.plugins.items[0].state);
    try std.testing.expectEqualStrings("z-bad", manager.plugins.items[1].name);
    try std.testing.expectEqual(PluginState.failed, manager.plugins.items[1].state);
    try std.testing.expect(api.commands.find("PluginHello") != null);
    try std.testing.expect(api.commands.find("BrokenPartial") == null);
    try std.testing.expectEqual(@as(usize, 1), api.keymaps.count());
    try std.testing.expectEqual(@as(usize, 1), api.autocmds.count());
}
