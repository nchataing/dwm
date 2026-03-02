//! Status bar rendering.
//!
//! Draws the tag labels, layout symbol, window title, and status text
//! into each monitor's bar window. Also handles bar window creation and
//! status text updates via the embedded status module (status.zig).

const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const systray = @import("systray.zig");
const status = @import("status.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const Monitor = dwm.Monitor;

// ── Bar config ──────────────────────────────────────────────────────────────
pub const tags = [_][*:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };

// ── Bar state ───────────────────────────────────────────────────────────────

pub var status_text: [256:0]u8 = [_:0]u8{0} ** 256; // status text, populated by the embedded status module
pub var bar_height: c_int = 0; // height of the status bar (font height + 2)
pub var text_lr_pad: c_int = 0; // left+right padding for text drawn in the bar
pub var layout_label_width: c_int = 0; // width of the layout symbol text in the bar

// ── Functions ───────────────────────────────────────────────────────────────

/// Measure the pixel width of a text string, including left+right padding.
pub fn textWidth(x: [*:0]const u8) c_int {
    if (dwm.draw) |d| {
        return @as(c_int, @intCast(d.fontsetGetWidth(x))) + text_lr_pad;
    }
    return 0;
}

/// Renders the entire status bar for one monitor: tag labels, layout symbol,
/// focused window title, and status text. Accounts for systray width when the
/// tray is on this monitor.
pub fn drawbar(m: *Monitor) void {
    const d = dwm.draw orelse return;
    const s = dwm.scheme orelse return;
    if (!m.showbar) return;

    var stw: c_uint = 0;
    if (systray.systraytomon(m) == m and !systray.systrayonleft)
        stw = systray.getsystraywidth();

    // draw status first
    var tw: c_int = 0;
    if (dwm.selmon == m) {
        d.setScheme(s[dwm.SchemeNorm]);
        tw = textWidth(&status_text) - @divTrunc(text_lr_pad, 2) + 2;
        _ = d.text(m.window_w - tw - @as(c_int, @intCast(stw)), 0, @intCast(tw), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2) - 2), &status_text, false);
    }

    systray.resizebarwin(m);

    var occ = [_]bool{false} ** tags.len; // which tags have clients
    var urg = [_]bool{false} ** tags.len; // which tags have urgent clients
    var cl_it = m.clients;
    while (cl_it) |cl_c| : (cl_it = cl_c.next) {
        occ[cl_c.tag] = true;
        if (cl_c.isurgent) urg[cl_c.tag] = true;
    }

    var x: c_int = 0;
    const boxs = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 9);
    const boxw = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 6) + 2;

    for (0..tags.len) |i| {
        const w = textWidth(tags[i]);
        d.setScheme(if (m.tag == i) s[dwm.SchemeSel] else s[dwm.SchemeNorm]);
        _ = d.text(x, 0, @intCast(w), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), tags[i], urg[i]);
        if (occ[i]) {
            d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), m == dwm.selmon and m.sel != null and m.sel.?.tag == i, urg[i]);
        }
        x += w;
    }

    const ltw = textWidth(&m.layout_symbol);
    layout_label_width = ltw;
    d.setScheme(s[dwm.SchemeNorm]);
    x = d.text(x, 0, @intCast(ltw), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), &m.layout_symbol, false);

    const w_remaining = m.window_w - tw - @as(c_int, @intCast(stw)) - x;
    if (w_remaining > bar_height) {
        if (m.sel) |sel_cl| {
            d.setScheme(if (m == dwm.selmon) s[dwm.SchemeSel] else s[dwm.SchemeNorm]);
            _ = d.text(x, 0, @intCast(w_remaining), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), &sel_cl.name, false);
            if (sel_cl.isfloating) d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), sel_cl.isfixed, false);
        } else {
            d.setScheme(s[dwm.SchemeNorm]);
            d.rect(x, 0, @intCast(w_remaining), @intCast(bar_height), true, true);
        }
    }
    d.map(m.barwin, 0, 0, @intCast(m.window_w - @as(c_int, @intCast(stw))), @intCast(bar_height));
}

/// Redraws the bar on every monitor. Called after global state changes like
/// focus changes or urgency updates that could affect any monitor's bar.
pub fn drawbars() void {
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) drawbar(mon);
}

/// Creates the bar X window for each monitor that doesn't already have one.
/// Sets override-redirect so the WM doesn't try to manage its own bar windows,
/// and registers for ButtonPress + Expose events to handle clicks and repaints.
pub fn updateBars() void {
    const d = dwm.dpy orelse return;
    var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
    wa.override_redirect = x11.True;
    wa.background_pixmap = x11.ParentRelative;
    wa.event_mask = x11.ButtonPressMask | x11.ExposureMask;
    var ch: x11.XClassHint = .{ .res_name = @constCast("dwm"), .res_class = @constCast("dwm") };
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) {
        if (mon.barwin != 0) continue;
        var w: c_uint = @intCast(mon.window_w);
        if (systray.systraytomon(mon) == mon) w -= systray.getsystraywidth();
        mon.barwin = c.XCreateWindow(d, dwm.root, mon.window_x, mon.bar_y, w, @intCast(bar_height), 0, @intCast(c.DefaultDepth(d, dwm.screen)), x11.CopyFromParent, c.DefaultVisual(d, dwm.screen), x11.CWOverrideRedirect | x11.CWBackPixmap | x11.CWEventMask, &wa);
        if (dwm.cursor[dwm.CurNormal]) |cur| _ = c.XDefineCursor(d, mon.barwin, cur.cursor);
        if (systray.systraytomon(mon) == mon) {
            if (systray.ptr) |st| _ = c.XMapRaised(d, st.win);
        }
        _ = c.XMapRaised(d, mon.barwin);
        _ = c.XSetClassHint(d, mon.barwin, &ch);
    }
}

/// Updates the status bar text from the embedded status module and redraws.
/// Called on timer ticks from the event loop, and once during initial setup.
pub fn updateStatus() void {
    status.update();
    if (dwm.selmon) |sm| drawbar(sm);
    systray.update();
}
