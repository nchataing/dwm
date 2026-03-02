//! Layout engine.
//!
//! Defines available layout algorithms and the functions that drive window
//! arrangement. Layouts are nearly stateless — they read Monitor geometry
//! and the client list, then position windows via dwm.resize().

const std = @import("std");
const x11 = @import("x11.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const Monitor = dwm.Monitor;
const Client = dwm.Client;

// ── Layout definition ───────────────────────────────────────────────────────

pub const Layout = struct {
    symbol: [*:0]const u8,
    arrange: ?*const fn (*Monitor) void,
};

pub const layouts = [_]Layout{
    .{ .symbol = "[]=", .arrange = &tile }, // first entry is default
    .{ .symbol = "><>", .arrange = null }, // no layout function means floating behavior
    .{ .symbol = "[M]", .arrange = &monocle },
};

// ── Layout functions ────────────────────────────────────────────────────────

/// Triggers a full layout recalculation. If a specific monitor is given, only that
/// monitor is re-laid-out; if null, all monitors are updated. This is the main
/// entry point called after any state change that affects window positions (tag
/// switches, client add/remove, layout changes, etc.).
pub fn arrange(m: ?*Monitor) void {
    if (m) |mon| {
        showHide(mon.stack);
    } else {
        var it = dwm.mons;
        while (it) |mon| : (it = mon.next) showHide(mon.stack);
    }
    if (m) |mon| {
        mon.applyLayout();
        dwm.restack(mon);
    } else {
        var it = dwm.mons;
        while (it) |mon| : (it = mon.next) mon.applyLayout();
    }
}

/// Master-stack tiling layout (the default "[]=" layout). Splits the monitor
/// into a left master area and right stack area based on master_factor. The
/// first client fills the master area; the rest fill the stack area (split
/// vertically). This is dwm's signature layout — efficient for coding with
/// one main editor and several terminals.
pub fn tile(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = nextTiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nextTiled(cl_c.next)) n += 1;
    if (n == 0) return;

    const mw: c_int = if (n > 1)
        @intFromFloat(@as(f32, @floatFromInt(m.window_w)) * m.master_factor)
    else
        m.window_w;

    var i: c_uint = 0;
    var ty: c_int = 0;
    cl_it = nextTiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nextTiled(cl_c.next)) {
        if (i == 0) {
            dwm.resize(cl_c, m.window_x, m.window_y, mw - (2 * cl_c.border_width), m.window_h - (2 * cl_c.border_width), false);
        } else {
            const h = @divTrunc(m.window_h - ty, @as(c_int, @intCast(n - i)));
            dwm.resize(cl_c, m.window_x + mw, m.window_y + ty, m.window_w - mw - (2 * cl_c.border_width), h - (2 * cl_c.border_width), false);
            if (ty + cl_c.getHeight() < m.window_h) ty += cl_c.getHeight();
        }
        i += 1;
    }
}

/// Monocle layout: every tiled window gets the full monitor area. The layout
/// symbol shows the window count "[N]" so the user knows how many are stacked.
/// Useful for maximizing screen real estate on small displays.
pub fn monocle(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = m.clients;
    while (cl_it) |cl_c| : (cl_it = cl_c.next) {
        if (cl_c.isVisible()) n += 1;
    }
    if (n > 0) {
        _ = std.fmt.bufPrint(&m.layout_symbol, "[{d}]", .{n}) catch {};
    }
    var c_it = nextTiled(m.clients);
    while (c_it) |cl_c| : (c_it = nextTiled(cl_c.next)) {
        dwm.resize(cl_c, m.window_x, m.window_y, m.window_w - 2 * cl_c.border_width, m.window_h - 2 * cl_c.border_width, false);
    }
}

/// Skips floating and invisible clients in the client list, returning the next
/// tiled (non-floating, visible) client. Used by tile/monocle layouts to iterate
/// only over clients that participate in the layout.
pub fn nextTiled(cl: ?*Client) ?*Client {
    var c_it = cl;
    while (c_it) |cc| : (c_it = cc.next) {
        if (!cc.isfloating and cc.isVisible()) return cc;
    }
    return null;
}

/// Recursively shows visible clients and hides invisible ones by walking the
/// focus stack. Visible clients are moved to their actual position; invisible
/// ones are moved off-screen (x = -2 * width). This is called before layout
/// arrange so that hidden windows don't interfere with tiling calculations.
/// Floating/non-fullscreen clients are also resized to enforce size hints.
pub fn showHide(cl: ?*Client) void {
    const d = dwm.dpy orelse return;
    const cl_c = cl orelse return;
    if (cl_c.isVisible()) {
        _ = c.XMoveWindow(d, cl_c.window, cl_c.x, cl_c.y);
        if ((cl_c.monitor != null and cl_c.monitor.?.layout.arrange == null or cl_c.isfloating) and !cl_c.isfullscreen)
            dwm.resize(cl_c, cl_c.x, cl_c.y, cl_c.w, cl_c.h, false);
        showHide(cl_c.snext);
    } else {
        showHide(cl_c.snext);
        _ = c.XMoveWindow(d, cl_c.window, cl_c.getWidth() * -2, cl_c.y);
    }
}
