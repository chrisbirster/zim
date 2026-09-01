const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("test-core", "Run editor/headless tests without Hondo");
    core_test_step.dependOn(&run_core_tests.step);

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
        .imports = &.{.{ .name = "hondo", .module = hondo }},
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
            .imports = &.{.{ .name = "hondo", .module = hondo }},
        }),
    });
    integration_tests.step.dependOn(&build_ui.step);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run Hondo/Zim integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run all Zim tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
