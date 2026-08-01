const std = @import("std");

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    dir: std.Io.Dir,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, input_path: []const u8) !Workspace {
        if (input_path.len == 0) {
            return error.EmptyWorkspacePath;
        }

        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        const resolved_path = try std.Io.Dir.path.resolve(allocator, &.{
            cwd,
            input_path,
        });

        errdefer allocator.free(resolved_path);
        const dir = try std.Io.Dir.cwd().openDir(io, resolved_path, .{
            .iterate = true,
        });

        return .{ .allocator = allocator, .path = resolved_path, .dir = dir };
    }

    pub fn deinit(self: *Workspace, io: std.Io) void {
        self.dir.close(io);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};
