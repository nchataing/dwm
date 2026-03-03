const std = @import("std");

/// Build configuration for dwm.
/// Links against system X11 libraries; they must be installed as dev packages
/// (e.g. libx11-dev, libxinerama-dev, libxft-dev, libfontconfig-dev on Debian).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Machine-dependent sysfs paths (auto-detected, overridable with -D flags) ──

    const backlight_name = b.option([]const u8, "backlight", "Backlight device name under /sys/class/backlight/ (auto-detected if omitted)") orelse
        detectSysDir(b, "/sys/class/backlight") orelse
        @panic("No backlight device found in /sys/class/backlight/. Pass -Dbacklight=<name> manually.");

    const battery_name = b.option([]const u8, "battery", "Battery device name under /sys/class/power_supply/ (auto-detected if omitted)") orelse
        detectBattery(b) orelse
        @panic("No battery device found in /sys/class/power_supply/. Pass -Dbattery=<name> manually.");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // needed for Xlib (C ABI) and libc calls (setlocale, fork, exec)
    });

    const options = b.addOptions();
    options.addOption([]const u8, "backlight_brightness", b.fmt("/sys/class/backlight/{s}/brightness", .{backlight_name}));
    options.addOption([]const u8, "backlight_max_brightness", b.fmt("/sys/class/backlight/{s}/max_brightness", .{backlight_name}));
    options.addOption([]const u8, "battery_status", b.fmt("/sys/class/power_supply/{s}/status", .{battery_name}));
    options.addOption([]const u8, "battery_capacity", b.fmt("/sys/class/power_supply/{s}/capacity", .{battery_name}));
    mod.addOptions("config", options);

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

    // Install to ~/.local/bin
    const install_home_step = b.step("install-home", "Copy the executable to ~/.local/bin");
    const home = b.graph.environ_map.get("HOME") orelse return;
    const cp = b.addSystemCommand(&.{ "cp", "-f" });
    cp.addArtifactArg(exe);
    cp.addArg(b.fmt("{s}/.local/bin/,dwm", .{home}));
    install_home_step.dependOn(&cp.step);
}

// ── Sysfs auto-detection helpers (run at build time on the host) ────────────

const Io = std.Io;
const Dir = Io.Dir;

/// Return the first entry name in a sysfs class directory, or null if
/// the directory doesn't exist or is empty.
fn detectSysDir(b: *std.Build, dir_path: []const u8) ?[]const u8 {
    const io = b.graph.io;
    var dir = Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    const entry = (it.next(io) catch return null) orelse return null;
    return b.allocator.dupe(u8, entry.name) catch return null;
}

/// Return the first BAT* entry under /sys/class/power_supply/.
fn detectBattery(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    var dir = Dir.openDirAbsolute(io, "/sys/class/power_supply", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "BAT"))
            return b.allocator.dupe(u8, entry.name) catch return null;
    }
    return null;
}
