const std = @import("std");
const Io = std.Io;

const Command = @import("command.zig").Command;
const root = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        try root.printHelp(init);
        return;
    }

    const command = try Command.parse(args[1]);
    switch (command) {
        .help => try root.printHelp(init),
        .version => try root.printVersion(init),
        .workspace => try root.startWorkspace(init, command.workspace),
    }
}
