//! Embedded status bar — reads system info (battery, time) and renders it
//! directly into the bar's status text buffer. Replaces the external
//! xsetroot/slstatus workflow with an internal timer-driven update.
//!
//! Uses a Linux timerfd to fire periodic updates, which integrates cleanly
//! with the poll()-based event loop in events.zig.

const std = @import("std");
const bar = @import("bar.zig");

const c = @cImport({
    @cInclude("time.h");
});

// ── Battery icon mapping ────────────────────────────────────────────────────

const bat_icon_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Full", "■" },
    .{ "Not charging", "■" },
    .{ "Charging", "▲" },
    .{ "Discharging", "▼" },
});

// ── Sysfs helpers ───────────────────────────────────────────────────────────

/// Read a sysfs file into `buf`, stripping a trailing newline. Returns the
/// slice on success, or an empty string on any error.
fn readSysFile(buf: []u8, comptime path: [*:0]const u8) []const u8 {
    const file_fd = std.c.open(path, .{});
    if (file_fd < 0) return "";
    defer _ = std.c.close(file_fd);
    const n = std.c.read(file_fd, buf.ptr, buf.len);
    if (n <= 0) return "";
    const len: usize = @intCast(n);
    if (buf[len - 1] == '\n') return buf[0 .. len - 1];
    return buf[0..len];
}

// ── Status segments ─────────────────────────────────────────────────────────

const StatusFn = *const fn ([]u8) ?[]const u8;

fn getBattery(buf: []u8) ?[]const u8 {
    var status_buf: [64]u8 = undefined;
    var cap_buf: [16]u8 = undefined;
    const status = readSysFile(&status_buf, "/sys/class/power_supply/BAT0/status");
    const icon = bat_icon_map.get(status) orelse "?";
    const capacity = readSysFile(&cap_buf, "/sys/class/power_supply/BAT0/capacity");
    return std.fmt.bufPrint(buf, "{s} {s}%", .{ icon, capacity }) catch null;
}

fn getTime(buf: []u8) ?[]const u8 {
    var now: c.time_t = undefined;
    _ = c.time(&now);
    const tm = c.localtime(&now) orelse return null;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(tm.*.tm_hour)),
        @as(u64, @intCast(tm.*.tm_min)),
    }) catch null;
}

const segments: []const StatusFn = &.{
    &getBattery,
    &getTime,
};

// ── Status builder ──────────────────────────────────────────────────────────

/// Calls each segment function and joins non-null results with " | ".
/// Writes the result (null-terminated) directly into `bar.status_text`.
pub fn update() void {
    var pos: usize = 0;
    var first = true;
    const buf = &bar.status_text;

    for (segments) |seg| {
        var seg_buf: [64]u8 = undefined;
        const text = seg(&seg_buf) orelse continue;
        if (!first) {
            if (pos + 3 > buf.len) return;
            @memcpy(buf[pos..][0..3], " | ");
            pos += 3;
        }
        if (pos + text.len > buf.len - 1) return;
        @memcpy(buf[pos..][0..text.len], text);
        pos += text.len;
        first = false;
    }

    buf[pos] = 0;
}

// ── Timer integration ───────────────────────────────────────────────────────

const linux = std.os.linux;

/// File descriptor for the timerfd, or -1 if creation failed.
var timer_fd: std.posix.fd_t = -1;

/// Create a 1-second periodic timerfd. Call once during setup.
pub fn init() void {
    timer_fd = std.posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }) catch -1;
    if (timer_fd < 0) return;

    const spec = linux.itimerspec{
        .it_interval = .{ .sec = 1, .nsec = 0 },
        .it_value = .{ .sec = 1, .nsec = 0 },
    };
    _ = linux.timerfd_settime(@intCast(timer_fd), .{}, &spec, null);
}

/// Drain the timerfd (must be called when poll reports it readable).
pub fn acknowledge() void {
    if (timer_fd < 0) return;
    var buf: [8]u8 = undefined;
    _ = std.c.read(timer_fd, &buf, 8);
}

/// Returns the timerfd for use in a poll set, or -1 if unavailable.
pub fn fd() std.posix.fd_t {
    return timer_fd;
}

/// Clean up the timerfd.
pub fn deinit() void {
    if (timer_fd >= 0) std.posix.close(timer_fd);
    timer_fd = -1;
}
