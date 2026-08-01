const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const Command = @import("command.zig").Command;
const Workspace = @import("workspace.zig").Workspace;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len > 2) {
        std.log.err(
            "expected one workspace path, received {d} arguments",
            .{args.len},
        );

        try cli.printHelp(init.io);
        return;
    }

    // Running zim by itself opens the current directory
    const command: Command = if (args.len == 1)
        .{ .workspace = "." }
    else
        Command.parse(args[1]) catch {
            std.log.err(
                "unknown option: {s}",
                .{args[1]},
            );

            try cli.printHelp(init.io);
            return;
        };

    switch (command) {
        .help => try cli.printHelp(init.io),
        .version => try cli.printVersion(init.io),

        .workspace => |input_path| {
            var workspace = Workspace.open(
                init.io,
                init.gpa,
                input_path,
            ) catch |err| switch (err) {
                error.EmptyWorkspacePath => {
                    std.log.err(
                        "workspace path cannot be empty",
                        .{},
                    );
                    return;
                },

                error.FileNotFound => {
                    std.log.err(
                        "workspace does not exist: {s}",
                        .{input_path},
                    );
                    return;
                },

                error.NotDir => {
                    std.log.err(
                        "workspace is not a directory: {s}",
                        .{input_path},
                    );
                    return;
                },

                else => return err,
            };
            defer workspace.deinit(init.io);

            try cli.printIntro(
                init.io,
                workspace.path,
            );

            // The next major milestone goes here:
            //
            // try server.run(
            //     init,
            //     &workspace,
            // );
        },
    }
}

test {
    _ = @import("command.zig");
    _ = @import("workspace.zig");
}
