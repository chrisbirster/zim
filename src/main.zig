const std = @import("std");
const Io = std.Io;

const version = "0.1.0";

const Command = enum {
    version,
    help,
    workspace,

    pub fn parse(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "--version")) {
            return .version;
        }

        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
            return .help;
        }

        if (std.mem.eql(u8, s, ".")) {
            return .workspace;
        }

        return null;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        try printHelp(init);
        return;
    }

    const command = Command.parse(args[1]) orelse {
        std.log.err("unknown command: {s}", .{args[1]});
        try printHelp(init);
        return;
    };

    switch (command) {
        .help => try printHelp(init),
        .version => try printVersion(init),
        .workspace => try startWorkspace(init),
    }
}

pub fn printVersion(init: std.process.Init) !void {
    try writeOutput(
        init.io,
        "ZIM version {s}\n",
        .{version},
    );
}

pub fn printHelp(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);

    const help_template =
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
    ;

    try writeOutput(
        init.io,
        help_template,
        .{ version, cwd },
    );
}

pub fn startWorkspace(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);

    try writeOutput(
        init.io,
        "Starting workspace in {s}\n",
        .{cwd},
    );
}

fn writeOutput(
    io: std.Io,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;

    try writer.print(format, args);
    try writer.flush();
}
