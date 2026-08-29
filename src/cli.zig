const std = @import("std");

pub const Command = union(enum) {
    run: RunOptions,
    help,
    version,
};

pub const RunOptions = struct {
    target: ?[]const u8 = null,
    headless: bool = false,
};

pub const ParseError = error{
    UnknownOption,
    TooManyTargets,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    var options: RunOptions = .{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return .version;
        }

        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        }

        if (options.target != null) {
            return error.TooManyTargets;
        }

        options.target = arg;
    }

    return .{ .run = options };
}

test "parse empty command" {
    const command = try parse(&.{});

    switch (command) {
        .run => |options| {
            try std.testing.expect(options.target == null);
            try std.testing.expect(!options.headless);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse target" {
    const command = try parse(&.{"src/main.zig"});

    switch (command) {
        .run => |options| {
            try std.testing.expectEqualStrings("src/main.zig", options.target.?);
            try std.testing.expect(!options.headless);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse headless target" {
    const command = try parse(&.{ "--headless", "src/main.zig" });

    switch (command) {
        .run => |options| {
            try std.testing.expectEqualStrings("src/main.zig", options.target.?);
            try std.testing.expect(options.headless);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse help and version" {
    switch (try parse(&.{"--help"})) {
        .help => {},
        else => return error.TestUnexpectedResult,
    }

    switch (try parse(&.{"-h"})) {
        .help => {},
        else => return error.TestUnexpectedResult,
    }

    switch (try parse(&.{"--version"})) {
        .version => {},
        else => return error.TestUnexpectedResult,
    }

    switch (try parse(&.{"-v"})) {
        .version => {},
        else => return error.TestUnexpectedResult,
    }
}

test "reject unknown options and extra targets" {
    try std.testing.expectError(error.UnknownOption, parse(&.{"--wat"}));
    try std.testing.expectError(error.TooManyTargets, parse(&.{ "one", "two" }));
}
