const std = @import("std");
const Io = std.Io;

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(
        init.io,
        &stdout_buffer,
    );

    const stdout = &stdout_writer.interface;
    try stdout.print(
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
    , .{ version, cwd });

    try stdout.flush();
}
