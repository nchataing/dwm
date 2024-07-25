const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dwm",
        .target = target,
        .optimize = optimize
    });

    exe.linkLibC();

    exe.linkSystemLibrary("x11");
    exe.linkSystemLibrary("xinerama");
    exe.linkSystemLibrary("xft");
    exe.linkSystemLibrary("fontconfig");
    exe.addCSourceFiles(.{ .files = &.{"drw.c", "dwm.c", "util.c"} });

    exe.defineCMacro("VERSION", "\"6.3\"");

    b.installArtifact(exe);
}
