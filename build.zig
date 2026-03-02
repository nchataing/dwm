const std = @import("std");

/// Build configuration for dwm.
/// Links against system X11 libraries; they must be installed as dev packages
/// (e.g. libx11-dev, libxinerama-dev, libxft-dev, libfontconfig-dev on Debian).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // needed for Xlib (C ABI) and libc calls (setlocale, fork, exec)
    });

    mod.linkSystemLibrary("x11", .{}); // core Xlib — display, windows, events, atoms
    mod.linkSystemLibrary("xinerama", .{}); // multi-monitor geometry queries
    mod.linkSystemLibrary("xft", .{}); // Xft font rendering (anti-aliased, Unicode-aware)
    mod.linkSystemLibrary("fontconfig", .{}); // font matching and fallback discovery

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
