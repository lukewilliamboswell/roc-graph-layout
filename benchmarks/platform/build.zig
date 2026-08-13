const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
        }),
    });
    host.bundle_compiler_rt = true;
    b.installArtifact(host);

    const target_dir = switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "arm64mac",
            .x86_64 => "x64mac",
            else => @panic("unsupported architecture"),
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "arm64musl",
            .x86_64 => "x64musl",
            else => @panic("unsupported architecture"),
        },
        else => @panic("unsupported benchmark host"),
    };
    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(host.getEmittedBin(), b.pathJoin(&.{ "targets", target_dir, "libhost.a" }));
    b.getInstallStep().dependOn(&copy.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run host tests");
    test_step.dependOn(&run_tests.step);
}
