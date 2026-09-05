const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pty_test_filter = b.option(
        []const u8,
        "pty-test-filter",
        "Only run PTY tests whose names contain this substring",
    );
    const pty_test_module = b.createModule(.{
        .root_source_file = b.path("src/pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const pty_tests = b.addTest(.{
        .root_module = pty_test_module,
        .filters = if (pty_test_filter) |filter| &.{filter} else &.{},
    });
    const run_pty_tests = b.addRunArtifact(pty_tests);
    const pty_test_step = b.step("test-pty", "Run native PTY backend tests");
    pty_test_step.dependOn(&run_pty_tests.step);

    const pty_only = b.option(
        bool,
        "pty-only",
        "Configure only the native PTY test graph",
    ) orelse false;
    if (pty_only) {
        b.default_step = pty_test_step;
        return;
    }

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });
    const zlua = zlua_dep.module("zlua");

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter = tree_sitter_dep.module("tree_sitter");
    const tree_sitter_zig_dep = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = optimize,
        .@"build-shared" = false,
    });
    const tree_sitter_zig = tree_sitter_zig_dep.artifact("tree-sitter-zig");

    const language_module = b.createModule(.{
        .root_source_file = b.path("src/language/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    language_module.addImport("tree-sitter", tree_sitter);
    language_module.linkLibrary(tree_sitter_zig);

    const core_test_filter = b.option(
        []const u8,
        "core-test-filter",
        "Only run core tests whose names contain this substring",
    );
    const core_test_module = b.createModule(.{
        .root_source_file = b.path("src/core_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_test_module.addImport("language", language_module);
    core_test_module.addImport("zlua", zlua);
    const core_tests = b.addTest(.{
        .root_module = core_test_module,
        .filters = if (core_test_filter) |filter| &.{filter} else &.{},
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const language_test_module = b.createModule(.{
        .root_source_file = b.path("src/language/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    language_test_module.addImport("tree-sitter", tree_sitter);
    language_test_module.linkLibrary(tree_sitter_zig);
    const language_tests = b.addTest(.{
        .root_module = language_test_module,
    });
    const run_language_tests = b.addRunArtifact(language_tests);
    const language_test_step = b.step("test-language", "Run headless Tree-sitter language-core tests");
    language_test_step.dependOn(&run_language_tests.step);

    const zls_smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/zls_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zls_smoke_tests = b.addRunArtifact(zls_smoke_tests);
    const zls_smoke_step = b.step("test-zls-smoke", "Run real ZLS stdio lifecycle smoke test");
    zls_smoke_step.dependOn(&run_zls_smoke_tests.step);

    const core_test_step = b.step("test-core", "Run editor/headless tests without Hondo");
    core_test_step.dependOn(&run_core_tests.step);
    core_test_step.dependOn(&run_language_tests.step);

    const headless_only = b.option(
        bool,
        "headless-only",
        "Configure only the pure-Zig editor/headless test graph",
    ) orelse false;
    if (headless_only) {
        b.default_step = core_test_step;
        return;
    }

    const hondo_dep = b.lazyDependency("hondo", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const hondo = hondo_dep.module("hondo");

    const build_ui = b.addSystemCommand(&.{ "node", "scripts/build-ui.mjs" });
    const ui_step = b.step("ui", "Bundle the Solid/Hondo Zim application chrome");
    ui_step.dependOn(&build_ui.step);

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "hondo", .module = hondo },
            .{ .name = "language", .module = language_module },
            .{ .name = "zlua", .module = zlua },
        },
    });
    const exe = b.addExecutable(.{
        .name = "zim",
        .root_module = app_module,
    });
    exe.step.dependOn(&build_ui.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Zim");
    run_step.dependOn(&run_cmd.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hondo", .module = hondo },
                .{ .name = "language", .module = language_module },
                .{ .name = "zlua", .module = zlua },
            },
        }),
    });
    integration_tests.step.dependOn(&build_ui.step);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run Hondo/Zim integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run all Zim tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_language_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
