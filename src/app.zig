const std = @import("std");
const cli = @import("cli.zig");
const editor = @import("editor.zig");

pub const version = "0.1.0";

const help_text =
    \\Zim — your new code overlord.
    \\
    \\Usage:
    \\  zim [options] [file|directory]
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -v, --version    Show the Zim version
    \\      --headless   Start the editor core without the TUI
    \\
;

pub fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = cli.parse(args[1..]) catch |err| {
        try printParseError(init.io, err);
        return 2;
    };

    switch (command) {
        .help => {
            try std.Io.File.stdout().writeStreamingAll(init.io, help_text);
            return 0;
        },
        .version => {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &buffer);
            try writer.interface.print("zim {s}\n", .{version});
            try writer.interface.flush();
            return 0;
        },
        .run => |options| {
            var state = editor.Editor.init(options.target);
            _ = &state;

            if (options.headless) {
                return 0;
            }

            try printBanner(init.io, options.target);
            return 0;
        },
    }
}

fn printParseError(io: std.Io, err: cli.ParseError) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);

    switch (err) {
        error.UnknownOption => try writer.interface.writeAll("zim: unknown option\n"),
        error.TooManyTargets => try writer.interface.writeAll("zim: only one file or directory may be opened at startup\n"),
    }

    try writer.interface.writeAll("Run 'zim --help' for usage.\n");
    try writer.interface.flush();
}

fn printBanner(io: std.Io, target: ?[]const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);

    try writer.interface.print(
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
    , .{ version, target orelse "[No Name]" });

    try writer.interface.flush();
}
