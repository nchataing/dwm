//! Embedded status bar — reads system info (battery, time) and renders it
//! as individually colored blocks in the bar. Replaces the external
//! xsetroot/slstatus workflow with an internal timer-driven update.
//!
//! Each block carries its own text + fg/bg XftColors, allowing segments to
//! pick colors dynamically at runtime (e.g. red battery when capacity < 10%).
//!
//! Uses a Linux timerfd to fire periodic updates, which integrates cleanly
//! with the poll()-based event loop in events.zig.

const std = @import("std");
const drw = @import("drw.zig");
const colors = @import("colors.zig");

const c = @cImport({
    @cInclude("time.h");
});

// ── Block ───────────────────────────────────────────────────────────────────

/// A single status segment with its own text and color pair.
pub const Block = struct {
    text: [64:0]u8 = [_:0]u8{0} ** 64,
    /// Color pair: [0] = fg (ColFg), [1] = bg (ColBg).
    /// Stored as a 2-element array so we can pass it directly to drw.setScheme().
    colors: [2]drw.Color = undefined,

    pub fn scheme(self: *Block) [*]drw.Color {
        return &self.colors;
    }
};

pub var blocks: [segments.len]Block = [_]Block{.{}} ** segments.len;
pub var block_count: usize = 0;

// ── Pre-allocated XftColors ─────────────────────────────────────────────────

var col_bat_normal: drw.Color = undefined;
var col_bat_warning: drw.Color = undefined;
var col_bat_critical: drw.Color = undefined;
var col_bat_charging: drw.Color = undefined;
var col_time_fg: drw.Color = undefined;
var col_status_bg: drw.Color = undefined;

/// Allocate all status XftColors from the draw context. Must be called once
/// during setup(), after the DrawContext is created.
pub fn initColors(d: *drw.DrawContext) void {
    d.colorCreate(&col_bat_normal, colors.bat_normal);
    d.colorCreate(&col_bat_warning, colors.bat_warning);
    d.colorCreate(&col_bat_critical, colors.bat_critical);
    d.colorCreate(&col_bat_charging, colors.bat_charging);
    d.colorCreate(&col_time_fg, colors.time_fg);
    d.colorCreate(&col_status_bg, colors.status_bg);
}

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

const SegmentFn = *const fn (*Block) bool;

fn getBattery(block: *Block) bool {
    var status_buf: [64]u8 = undefined;
    var cap_buf: [16]u8 = undefined;
    const status = readSysFile(&status_buf, "/sys/class/power_supply/BAT0/status");
    const icon = bat_icon_map.get(status) orelse "?";
    const capacity = readSysFile(&cap_buf, "/sys/class/power_supply/BAT0/capacity");

    // Format text
    const text = std.fmt.bufPrint(&block.text, "{s} {s}%", .{ icon, capacity }) catch return false;
    block.text[text.len] = 0;

    // Pick fg color based on charging status and capacity
    block.colors[1] = col_status_bg;
    if (std.mem.eql(u8, status, "Charging") or std.mem.eql(u8, status, "Full") or std.mem.eql(u8, status, "Not charging")) {
        block.colors[0] = col_bat_charging;
    } else {
        // Discharging — color by capacity level
        const cap = std.fmt.parseInt(u8, capacity, 10) catch 50;
        if (cap < 10) {
            block.colors[0] = col_bat_critical;
        } else if (cap < 30) {
            block.colors[0] = col_bat_warning;
        } else {
            block.colors[0] = col_bat_normal;
        }
    }
    return true;
}

fn getTime(block: *Block) bool {
    var now: c.time_t = undefined;
    _ = c.time(&now);
    const tm = c.localtime(&now) orelse return false;
    const text = std.fmt.bufPrint(&block.text, "{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(tm.*.tm_hour)),
        @as(u64, @intCast(tm.*.tm_min)),
    }) catch return false;
    block.text[text.len] = 0;

    block.colors[0] = col_time_fg;
    block.colors[1] = col_status_bg;
    return true;
}

const segments: []const SegmentFn = &.{
    &getBattery,
    &getTime,
};

// ── Status builder ──────────────────────────────────────────────────────────

/// Calls each segment function and populates the blocks array.
pub fn update() void {
    var count: usize = 0;
    for (segments) |seg| {
        if (seg(&blocks[count])) {
            count += 1;
        }
    }
    block_count = count;
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
