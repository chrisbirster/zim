const std = @import("std");
const Io = std.Io;

const VERSION = "0.1.0";

pub fn printVersion(io: std.Io) !void {
    try writeOutput(
        io,
        "ZIM version {s}\n",
        .{VERSION},
    );
}

pub fn printHelp(io: std.Io) !void {
    try writeOutput(
        io,
        \\
        \\ZIM - {s} - YOUR NEW CODE OVERLORD
        \\
        \\THE CODE... IT FILLS ME... IT IS NEAT!
        \\
        \\USAGE:
        \\  zim [OPTIONS] [WORKSPACE_PATH]
        \\
        \\OPTIONS:
        \\  -h, --help      Show this help message
        \\  -v, --version   Show the Zim version
        \\
        \\WORKSPACE_PATH:
        \\  Directory to open as a workspace.
        \\  Defaults to the current directory.
        \\
        \\EXAMPLES:
        \\  zim
        \\  zim .
        \\  zim ../my-project
        \\  zim /Users/me/projects/example
        \\
    ,
        .{VERSION},
    );
}

pub fn printIntro(
    io: std.Io,
    workspace_path: []const u8,
) !void {
    try writeOutput(
        io,
        \\
        \\ZIM - {s} - YOUR NEW CODE OVERLORD
        \\
        \\THE CODE... IT FILLS ME... IT IS NEAT!
        \\
        \\[INVADING]    {s}
        \\[CATALOGING]  Human files
        \\[AWAKENING]   Language intelligence
        \\[STARTING]    Operation Impending Build
        \\[READY]       Commence coding
        \\
    ,
        .{ VERSION, workspace_path },
    );
}

fn writeOutput(
    io: std.Io,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(
        io,
        &buffer,
    );

    const writer = &file_writer.interface;

    try writer.print(format, args);
    try writer.flush();
}
