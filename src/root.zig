const std = @import("std");
const Io = std.Io;

const VERSION = "0.1.0";

pub fn getCwd(init: std.process.Init) ![:0]u8 {
    return std.process.currentPathAlloc(init.io, init.gpa);
}

pub fn printVersion(init: std.process.Init) !void {
    try writeOutput(
        init.io,
        "ZIM version {s}\n",
        .{VERSION},
    );
}

pub fn printHelp(init: std.process.Init) !void {
    const help_template =
        \\
        \\ZIM - {s} - YOUR NEW CODE OVERLORD 
        \\
        \\THE CODE... IT FILLS ME... IT IS NEAT!
        \\
        \\USAGE: zim [OPTIONS] [WORKSPACE_PATH]
        \\OPTIONS:
        \\  -h, --help      Show this help message
        \\  --version       Show the version of ZIM
        \\
        \\WORKSPACE_PATH:
        \\  The path to the workspace directory. If not provided, the current working directory will
        \\ be used as the workspace.
        \\
    ;

    try writeOutput(
        init.io,
        help_template,
        .{VERSION},
    );
}

pub fn printIntro(init: std.process.Init, cwd: []const u8) !void {
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
        .{ VERSION, cwd },
    );
}

pub fn startWorkspace(init: std.process.Init, workspace: []const u8) !void {
    // _ = init; // TODO: Use the init to start the workspace
    std.debug.print("Starting workspace at: {s}\n", .{workspace});

    const cwd = try getCwd(init);
    defer init.gpa.free(cwd);
    std.debug.print("Current working directory: {s}\n", .{cwd});

    // cwd is absolute, the result will be absolute path.
    //
    // Examples:
    // "."                  -> /current/directory
    // "../"                -> /current
    // "some/project"       -> /current/directory/some/project
    // "/Users/me/project"  -> /Users/me/project
    const workspace_path = try std.Io.Dir.path.resolve(
        init.gpa,
        &.{
            cwd,
            workspace,
        },
    );
    defer init.gpa.free(workspace_path);

    // Verify that it exists and is actually a directory.
    var workspace_dir = std.Io.Dir.cwd().openDir(
        init.io,
        workspace_path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err(
                "workspace does not exist: {s}",
                .{workspace_path},
            );
            return;
        },
        error.NotDir => {
            std.log.err(
                "workspace is not a directory: {s}",
                .{workspace_path},
            );
            return;
        },
        else => return err,
    };
    defer workspace_dir.close(init.io);

    std.debug.print(
        "Starting workspace at: {s}\n",
        .{workspace_path},
    );

    // TODO:
    // - scan workspace files
    // - create editor state
    // - start HTTP/RPC server
    // - open the SolidJS frontend
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
