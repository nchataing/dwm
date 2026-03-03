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
const config = @import("config");

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
    /// Optional click handler for this block.
    onClick: ?*const fn () void = null,
    /// Pixel x position and width, set during drawbar for hit-testing.
    x: c_int = 0,
    w: c_int = 0,

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
var col_btc_fg: drw.Color = undefined;
var col_brightness_fg: drw.Color = undefined;
var col_time_fg: drw.Color = undefined;
var col_status_bg: drw.Color = undefined;

/// Allocate all status XftColors from the draw context. Must be called once
/// during setup(), after the DrawContext is created.
pub fn initColors(d: *drw.DrawContext) void {
    d.colorCreate(&col_bat_normal, colors.bat_normal);
    d.colorCreate(&col_bat_warning, colors.bat_warning);
    d.colorCreate(&col_bat_critical, colors.bat_critical);
    d.colorCreate(&col_bat_charging, colors.bat_charging);
    d.colorCreate(&col_btc_fg, colors.btc_fg);
    d.colorCreate(&col_brightness_fg, colors.brightness_fg);
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
fn readSysFile(buf: []u8, comptime path: []const u8) []const u8 {
    const path_z: [*:0]const u8 = (path ++ .{0})[0..path.len :0];
    const file_fd = std.c.open(path_z, .{});
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

// ── Bitcoin price ───────────────────────────────────────────────────────────

const btc_interval: u32 = 300; // fetch every 300 ticks (5 minutes)
var btc_tick: u32 = btc_interval; // start at interval so first update() triggers a fetch

const btc_cache_path: []const u8 = "/tmp/dwm_btc_price";

/// Fork a child that runs curl to fetch BTC price into the cache file.
/// Non-blocking: the parent returns immediately.
fn forkBtcFetch() void {
    const pid = std.c.fork();
    if (pid == 0) {
        // child — close X connection, setsid, exec curl
        const x11 = @import("x11.zig");
        const d = @import("dwm.zig");
        if (d.dpy) |dp| std.posix.close(@intCast(x11.c.ConnectionNumber(dp)));
        _ = std.c.setsid();
        const argv = [_:null]?[*:0]const u8{
            "sh", "-c", "curl -sf 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur' > /tmp/dwm_btc_price.tmp && mv /tmp/dwm_btc_price.tmp /tmp/dwm_btc_price",
            null,
        };
        _ = x11.c.execvp("sh", @ptrCast(&argv));
        std.process.exit(0);
    }
}

/// Parse the price from the cached JSON file and format e.g. "₿ 62,340".
fn getBtc(block: *Block) bool {
    var file_buf: [256]u8 = undefined;
    const json = readSysFile(&file_buf, btc_cache_path);
    if (json.len == 0) {
        const text = std.fmt.bufPrint(&block.text, "\xe2\x82\xbf ---", .{}) catch return false;
        block.text[text.len] = 0;
        block.colors[0] = col_btc_fg;
        block.colors[1] = col_status_bg;
        return true;
    }

    // Simple scan for "eur": followed by a number.
    // JSON looks like: {"bitcoin":{"eur":62340.5}}  or  {"bitcoin":{"eur":62340}}
    const needle = "\"eur\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse {
        const text = std.fmt.bufPrint(&block.text, "\xe2\x82\xbf ---", .{}) catch return false;
        block.text[text.len] = 0;
        block.colors[0] = col_btc_fg;
        block.colors[1] = col_status_bg;
        return true;
    };

    // Extract the numeric part (digits and '.') after "eur":
    var start = pos + needle.len;
    // skip whitespace
    while (start < json.len and json[start] == ' ') start += 1;
    var end = start;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '.')) end += 1;
    if (end == start) {
        const text = std.fmt.bufPrint(&block.text, "\xe2\x82\xbf ---", .{}) catch return false;
        block.text[text.len] = 0;
        block.colors[0] = col_btc_fg;
        block.colors[1] = col_status_bg;
        return true;
    }

    // Parse as float, round to integer
    const price_f = std.fmt.parseFloat(f64, json[start..end]) catch {
        const text = std.fmt.bufPrint(&block.text, "\xe2\x82\xbf ---", .{}) catch return false;
        block.text[text.len] = 0;
        block.colors[0] = col_btc_fg;
        block.colors[1] = col_status_bg;
        return true;
    };
    const price: u64 = @intFromFloat(@round(price_f));

    // Format with thousand separator: e.g. 62340 -> "62,340"
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{price}) catch return false;

    var fmt_buf: [48]u8 = undefined;
    var fi: usize = 0;
    for (num_str, 0..) |ch, idx| {
        if (idx > 0 and (num_str.len - idx) % 3 == 0) {
            fmt_buf[fi] = ',';
            fi += 1;
        }
        fmt_buf[fi] = ch;
        fi += 1;
    }

    const text = std.fmt.bufPrint(&block.text, "\xe2\x82\xbf {s}", .{fmt_buf[0..fi]}) catch return false;
    block.text[text.len] = 0;
    block.colors[0] = col_btc_fg;
    block.colors[1] = col_status_bg;
    block.onClick = &forkBtcFetch;
    return true;
}

// ── Brightness ──────────────────────────────────────────────────────────────

const brightness_presets = [_]u8{ 25, 10, 3 };

fn getBrightness(block: *Block) bool {
    var cur_buf: [16]u8 = undefined;
    var max_buf: [16]u8 = undefined;
    const cur_str = readSysFile(&cur_buf, config.backlight_brightness);
    const max_str = readSysFile(&max_buf, config.backlight_max_brightness);

    const cur = std.fmt.parseInt(u32, cur_str, 10) catch return false;
    const max = std.fmt.parseInt(u32, max_str, 10) catch return false;
    if (max == 0) return false;

    const pct = (cur * 100 + max / 2) / max; // rounded percentage
    const text = std.fmt.bufPrint(&block.text, "\xe2\x98\x80 {d}%", .{pct}) catch return false;
    block.text[text.len] = 0;

    block.colors[0] = col_brightness_fg;
    block.colors[1] = col_status_bg;
    block.onClick = &onClickBrightness;
    return true;
}

fn onClickBrightness() void {
    // Read current brightness percentage
    var cur_buf: [16]u8 = undefined;
    var max_buf: [16]u8 = undefined;
    const cur_str = readSysFile(&cur_buf, config.backlight_brightness);
    const max_str = readSysFile(&max_buf, config.backlight_max_brightness);
    const cur = std.fmt.parseInt(u32, cur_str, 10) catch return;
    const max = std.fmt.parseInt(u32, max_str, 10) catch return;
    if (max == 0) return;
    const pct = (cur * 100 + max / 2) / max;

    // Find next preset: first one strictly below current, or wrap to highest
    var target: u8 = brightness_presets[0];
    for (brightness_presets) |preset| {
        if (preset < pct) {
            target = preset;
            break;
        }
    }

    // Format the target as a string for xbacklight
    var arg_buf: [8:0]u8 = undefined;
    const arg_str = std.fmt.bufPrint(&arg_buf, "{d}", .{target}) catch return;
    arg_buf[arg_str.len] = 0;

    const pid = std.c.fork();
    if (pid == 0) {
        // child — close X connection and exec xbacklight
        const x11 = @import("x11.zig");
        const dwm = @import("dwm.zig");
        if (dwm.dpy) |dp| std.posix.close(@intCast(x11.c.ConnectionNumber(dp)));
        _ = std.c.setsid();
        const argv = [_:null]?[*:0]const u8{ "xbacklight", "-set", &arg_buf, null };
        _ = x11.c.execvp("xbacklight", @ptrCast(&argv));
        std.process.exit(0);
    }
}

// ── Battery ─────────────────────────────────────────────────────────────────

fn getBattery(block: *Block) bool {
    var status_buf: [64]u8 = undefined;
    var cap_buf: [16]u8 = undefined;
    const status = readSysFile(&status_buf, config.battery_status);
    const icon = bat_icon_map.get(status) orelse "?";
    const capacity = readSysFile(&cap_buf, config.battery_capacity);

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
    &getBtc,
    &getBrightness,
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

/// Hit-test: find the block at pixel position `px` and invoke its onClick.
pub fn handleClick(px: c_int) void {
    for (0..block_count) |i| {
        if (px >= blocks[i].x and px < blocks[i].x + blocks[i].w) {
            if (blocks[i].onClick) |cb| cb();
            return;
        }
    }
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
/// Also ticks the BTC fetch counter and forks curl when it expires.
pub fn acknowledge() void {
    if (timer_fd < 0) return;
    var buf: [8]u8 = undefined;
    _ = std.c.read(timer_fd, &buf, 8);

    btc_tick += 1;
    if (btc_tick >= btc_interval) {
        btc_tick = 0;
        forkBtcFetch();
    }
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
