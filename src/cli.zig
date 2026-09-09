const std = @import("std");

pub const Command = union(enum) {
    run: RunOptions,
    help,
    version,
};

pub const RunOptions = struct {
    target: ?[]const u8 = null,
    headless: bool = false,
    rpc_stdio: bool = false,
    rpc_listen: ?[]const u8 = null,
};

pub const ParseError = error{
    UnknownOption,
    TooManyTargets,
    MissingOptionValue,
    MultipleRpcEndpoints,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    var options: RunOptions = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) return .version;

        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rpc-stdio")) {
            if (options.rpc_stdio or options.rpc_listen != null) return error.MultipleRpcEndpoints;
            options.rpc_stdio = true;
            options.headless = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rpc-listen")) {
            if (options.rpc_stdio or options.rpc_listen != null) return error.MultipleRpcEndpoints;
            if (index + 1 >= args.len) return error.MissingOptionValue;
            const endpoint = args[index + 1];
            if (endpoint.len == 0 or std.mem.startsWith(u8, endpoint, "-")) return error.MissingOptionValue;
            options.rpc_listen = endpoint;
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--rpc-listen=")) {
            if (options.rpc_stdio or options.rpc_listen != null) return error.MultipleRpcEndpoints;
            const endpoint = arg["--rpc-listen=".len..];
            if (endpoint.len == 0) return error.MissingOptionValue;
            options.rpc_listen = endpoint;
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
        if (options.target != null) return error.TooManyTargets;
        options.target = arg;
        index += 1;
    }
    return .{ .run = options };
}

test "parse empty command" {
    const command = try parse(&.{});
    switch (command) {
        .run => |options| {
            try std.testing.expect(options.target == null);
            try std.testing.expect(!options.headless);
            try std.testing.expect(!options.rpc_stdio);
            try std.testing.expect(options.rpc_listen == null);
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

test "parse RPC endpoints" {
    switch (try parse(&.{"--rpc-stdio"})) {
        .run => |options| {
            try std.testing.expect(options.rpc_stdio);
            try std.testing.expect(options.headless);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(&.{ "--rpc-listen", "/tmp/zim.sock" })) {
        .run => |options| try std.testing.expectEqualStrings("/tmp/zim.sock", options.rpc_listen.?),
        else => return error.TestUnexpectedResult,
    }
    switch (try parse(&.{"--rpc-listen=zim-test"})) {
        .run => |options| try std.testing.expectEqualStrings("zim-test", options.rpc_listen.?),
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

test "reject invalid startup arguments" {
    try std.testing.expectError(error.UnknownOption, parse(&.{"--wat"}));
    try std.testing.expectError(error.TooManyTargets, parse(&.{ "one", "two" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{"--rpc-listen"}));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{"--rpc-listen="}));
    try std.testing.expectError(error.MultipleRpcEndpoints, parse(&.{ "--rpc-stdio", "--rpc-listen", "zim-test" }));
}
