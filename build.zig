const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.linkSystemLibrary("x11", .{});
    mod.linkSystemLibrary("xinerama", .{});
    mod.linkSystemLibrary("xft", .{});
    mod.linkSystemLibrary("fontconfig", .{});

    const exe = b.addExecutable(.{
        .name = "dwm",
        .root_module = mod,
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run dwm");
    run_step.dependOn(&run_cmd.step);
}
