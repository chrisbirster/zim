const std = @import("std");
const root = @import("root.zig");

pub const ParseError = error{
    InvalidCommand,
};

pub const Command = union(enum) {
    version,
    help,
    workspace: []const u8,

    pub fn parse(s: []const u8) ParseError!Command {
        if (std.mem.eql(u8, s, "--version")) {
            return .version;
        }

        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
            return .help;
        }

        // Reject other -[opts] besides the --help or --version.
        if (std.mem.startsWith(u8, s, "-")) {
            return ParseError.InvalidCommand;
        }

        // assuming any other string is a workspace path
        return .{ .workspace = s };
    }
};

test "parse --version" {
    const command = try Command.parse("--version");

    try std.testing.expectEqual(
        Command.version,
        command,
    );
}

test "parse -h" {
    const command = try Command.parse("-h");

    try std.testing.expectEqual(
        Command.help,
        command,
    );
}

test "parse --help" {
    const command = try Command.parse("--help");

    try std.testing.expectEqual(
        Command.help,
        command,
    );
}

test "parse current directory as workspace path" {
    const command = try Command.parse(".");

    switch (command) {
        .workspace => |path| {
            try std.testing.expectEqualStrings(".", path);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse relative directory as workspace path" {
    const command = try Command.parse("../my-project");

    switch (command) {
        .workspace => |path| {
            try std.testing.expectEqualStrings(
                "../my-project",
                path,
            );
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse absolute directory as workspace path" {
    const command = try Command.parse("/Users/someone/projects/zim");

    switch (command) {
        .workspace => |path| {
            try std.testing.expectEqualStrings(
                "/Users/someone/projects/zim",
                path,
            );
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a directory named workspace is parsed as a path" {
    const command = try Command.parse("workspace");

    switch (command) {
        .workspace => |path| {
            try std.testing.expectEqualStrings(
                "workspace",
                path,
            );
        },
        else => return error.TestUnexpectedResult,
    }
}

test "reject unknown option" {
    try std.testing.expectError(
        error.InvalidCommand,
        Command.parse("--unknown"),
    );
}
