// systray.zig — System tray subsystem
// Manages the XEMBED-based system tray: a row of embedded applet icons
// (volume, network, bluetooth, etc.) displayed in the status bar.
//
// This module was extracted from dwm.zig. It owns the Systray type,
// the systray_ptr global, all XEMBED constants, and the functions that
// create, update, and destroy systray icons.
const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const bar = @import("bar.zig");
const dwm = @import("dwm.zig");
const client = @import("client.zig");
const c = x11.c;

const SizeHints = client.SizeHints;

// ── Systray config ──
pub const systraypinning: c_uint = 0; // 0: sloppy systray follows selected monitor, >0: pin systray to monitor X
pub const systrayonleft: bool = false; // false: systray in the right corner, true: systray on left of status text
pub const systrayspacing: c_uint = 2; // pixel gap between systray icons
pub const systraypinningfailfirst: bool = true; // if pinning fails, fall back to the first monitor

// XEMBED visibility state for system tray icons.
pub const EmbedState = enum { inactive, active };

// A TrayIcon represents a single embedded system tray applet window.
// It only holds the fields actually needed by the systray subsystem,
// keeping it decoupled from the full Client struct.
pub const TrayIcon = struct {
    window: x11.Window = 0, // the applet's X11 window id
    monitor: ?*dwm.Monitor = null, // the monitor this icon is displayed on
    next: ?*TrayIcon = null, // next icon in the linked list

    // Current geometry (position + size within the tray container)
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,

    // ICCCM WM_NORMAL_HINTS — parsed size constraints
    size_hints: SizeHints = .{},

    border_width: c_int = 0,
    embed_state: EmbedState = .inactive,

    /// Sets the WM_STATE property on this icon's window.
    pub fn setClientState(self: *TrayIcon, state: c_long) void {
        const d = dwm.dpy orelse return;
        const data = [2]c_long{ state, x11.None };
        _ = c.XChangeProperty(d, self.window, dwm.wmatom[dwm.WMState], dwm.wmatom[dwm.WMState], 32, x11.PropModeReplace, @ptrCast(&data), 2);
    }

    /// Reads ICCCM WM_NORMAL_HINTS from the X server and stores them.
    /// Used to constrain icon geometry via applySizeHints.
    pub fn updateSizeHints(self: *TrayIcon) void {
        _ = self.size_hints.update(self.window);
    }

    /// Constrains (w, h) to ICCCM size hints. Returns true if the result
    /// differs from the icon's current size. Used by updatesystrayicongeom.
    pub fn applySizeHints(self: *TrayIcon, w: *c_int, h: *c_int) bool {
        self.size_hints.apply(w, h);
        return w.* != self.w or h.* != self.h;
    }
};

// --- XEMBED protocol constants (see freedesktop XEMBED spec) ---
// These are used by the system tray to embed applet windows into the bar.
pub const SYSTEM_TRAY_REQUEST_DOCK = 0;
pub const XEMBED_EMBEDDED_NOTIFY = 0;
pub const XEMBED_WINDOW_ACTIVATE = 1;
pub const XEMBED_WINDOW_DEACTIVATE = 2;
pub const XEMBED_FOCUS_IN = 4;
pub const XEMBED_MODALITY_ON = 10;
pub const XEMBED_MAPPED = (1 << 0);
pub const XEMBED_EMBEDDED_VERSION = 0;

const alloc = std.heap.c_allocator;

// The system tray — an area in the bar that embeds external applet windows
// (e.g. volume, network, bluetooth indicators) via the XEMBED protocol.
pub const Systray = struct {
    win: x11.Window = 0, // the container window that holds all tray icons
    icons: ?*TrayIcon = null, // linked list of embedded tray icons
};

/// The global system tray instance. Null until the first `update()` call
/// creates it. Owned by this module — all access from dwm.zig goes through
/// the public functions below.
pub var ptr: ?*Systray = null;

/// Finds a systray icon by its X window ID.
/// Returns null if the systray is disabled, the window is 0, or no match is found.
pub fn wintosystrayicon(w: x11.Window) ?*TrayIcon {
    if (w == 0) return null;
    const st = ptr orelse return null;
    var i = st.icons;
    while (i) |icon| : (i = icon.next) {
        if (icon.window == w) return icon;
    }
    return null;
}

/// Determines which monitor hosts the system tray.
/// If systraypinning is 0 (the default), the tray follows the selected monitor.
/// Otherwise it's pinned to a specific monitor index.
pub fn systraytomon(m: ?*dwm.Monitor) ?*dwm.Monitor {
    if (systraypinning == 0) {
        if (m == null) return dwm.selmon;
        return if (m == dwm.selmon) m else null;
    }
    var n: c_int = 1;
    var t = dwm.mons;
    while (t != null and t.?.next != null) : ({
        n += 1;
        t = t.?.next;
    }) {}
    t = dwm.mons;
    var i: c_uint = 1;
    while (t != null and t.?.next != null and i < systraypinning) : ({
        i += 1;
        t = t.?.next;
    }) {}
    if (systraypinningfailfirst and n < @as(c_int, @intCast(systraypinning))) return dwm.mons;
    return t;
}

/// Calculates the total pixel width of all systray icons plus spacing.
/// Returns 1 (minimum width) if there are no icons, or the systray is disabled.
pub fn getsystraywidth() c_uint {
    var w: c_uint = 0;
    if (ptr) |st| {
        var i = st.icons;
        while (i) |icon| : (i = icon.next) {
            w += @intCast(icon.w);
            w += systrayspacing;
        }
    }
    return if (w != 0) w + systrayspacing else 1;
}

/// Unlinks a systray icon from the icon list and frees its memory.
pub fn removesystrayicon(i: ?*TrayIcon) void {
    const icon = i orelse return;
    const st = ptr orelse return;
    var ii: *?*TrayIcon = &st.icons;
    while (ii.* != null) {
        if (ii.* == icon) {
            ii.* = icon.next;
            break;
        }
        ii = &ii.*.?.next;
    }
    alloc.destroy(icon);
}

/// Adjusts the bar window width to account for the systray, and repositions it.
/// Called after systray icon changes so the bar and tray don't overlap.
pub fn resizebarwin(m: *dwm.Monitor) void {
    const d = dwm.dpy orelse return;
    var w: c_uint = @intCast(m.window_w);
    if (systraytomon(m) == m and !systrayonleft)
        w -= getsystraywidth();
    _ = c.XMoveResizeWindow(d, m.barwin, m.window_x, m.bar_y, w, @intCast(bar.bar_height));
}

/// Scales a systray icon to fit the bar height, preserving aspect ratio.
/// Icons that are square get bar_height x bar_height; non-square icons are
/// scaled proportionally. Ensures no icon exceeds the bar height.
pub fn updatesystrayicongeom(icon: *TrayIcon, w: c_int, h: c_int) void {
    icon.h = bar.bar_height;
    if (w == h) {
        icon.w = bar.bar_height;
    } else if (h == bar.bar_height) {
        icon.w = w;
    } else {
        icon.w = @intFromFloat(@as(f32, @floatFromInt(bar.bar_height)) * (@as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h))));
    }
    var wv = icon.w;
    var hv = icon.h;
    _ = icon.applySizeHints(&wv, &hv);
    icon.w = wv;
    icon.h = hv;
    if (icon.h > bar.bar_height) {
        if (icon.w == icon.h) {
            icon.w = bar.bar_height;
        } else {
            icon.w = @intFromFloat(@as(f32, @floatFromInt(bar.bar_height)) * (@as(f32, @floatFromInt(icon.w)) / @as(f32, @floatFromInt(icon.h))));
        }
        icon.h = bar.bar_height;
    }
}

/// Reacts to XEMBED_INFO property changes on a systray icon. Maps or unmaps
/// the icon based on the XEMBED_MAPPED flag, and sends the appropriate
/// XEMBED activate/deactivate message so the icon knows its visibility state.
pub fn updatesystrayiconstate(icon: *TrayIcon, ev: *x11.XPropertyEvent) void {
    if (ev.atom != dwm.xatom[dwm.XembedInfo]) return;
    const flags = getatomprop(icon, dwm.xatom[dwm.XembedInfo]);
    if (flags == 0) return;

    var code: c_long = 0;
    if (flags & XEMBED_MAPPED != 0 and icon.embed_state == .inactive) {
        icon.embed_state = .active;
        code = XEMBED_WINDOW_ACTIVATE;
        _ = c.XMapRaised(dwm.dpy.?, icon.window);
        icon.setClientState(x11.NormalState);
    } else if (flags & XEMBED_MAPPED == 0 and icon.embed_state == .active) {
        icon.embed_state = .inactive;
        code = XEMBED_WINDOW_DEACTIVATE;
        _ = c.XUnmapWindow(dwm.dpy.?, icon.window);
        icon.setClientState(x11.WithdrawnState);
    } else {
        return;
    }
    if (ptr) |st| {
        _ = dwm.sendevent(icon.window, dwm.xatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, code, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    }
}

/// Reads an Atom-typed XEMBED_INFO property from a tray icon window.
/// Returns the flags field (second atom) which indicates mapped/unmapped state.
fn getatomprop(icon: *TrayIcon, prop: x11.Atom) x11.Atom {
    const d = dwm.dpy orelse return x11.None;
    var di: c_int = undefined;
    var dl: c_ulong = undefined;
    var dl2: c_ulong = undefined;
    var p: ?[*]u8 = null;
    var da: x11.Atom = undefined;
    var atom: x11.Atom = x11.None;
    if (c.XGetWindowProperty(d, icon.window, prop, 0, @sizeOf(x11.Atom), x11.False, dwm.xatom[dwm.XembedInfo], &da, &di, &dl, &dl2, @ptrCast(&p)) == x11.Success and p != null) {
        atom = @as(*x11.Atom, @ptrCast(@alignCast(p.?))).*;
        if (da == dwm.xatom[dwm.XembedInfo] and dl == 2) atom = @as([*]x11.Atom, @ptrCast(@alignCast(p.?)))[1];
        _ = c.XFree(p);
    }
    return atom;
}

/// Creates (if first call) or repositions/redraws the system tray window. On
/// first call, creates a simple window, claims the _NET_SYSTEM_TRAY_S0 selection,
/// and advertises itself as the tray manager. On subsequent calls, repositions
/// all embedded icons in a horizontal row, resizes the tray window to fit,
/// and stacks it above the bar. This is the systray's main rendering function.
pub fn update() void {
    const d = dwm.dpy orelse return;
    const s = dwm.scheme orelse return;

    const m = systraytomon(null) orelse return;
    var x_pos: c_int = m.monitor_x + m.monitor_w;
    const status_w = bar.textWidth(&bar.status_text) - bar.text_lr_pad + @as(c_int, @intCast(systrayspacing));
    var w: c_uint = 1;

    if (systrayonleft) x_pos -= status_w + @divTrunc(bar.text_lr_pad, 2);

    if (ptr == null) {
        // init systray
        const st = alloc.create(Systray) catch {
            dwm.die("fatal: could not allocate Systray");
            return;
        };
        st.* = Systray{};
        ptr = st;
        st.win = c.XCreateSimpleWindow(d, dwm.root, x_pos, m.bar_y, w, @intCast(bar.bar_height), 0, 0, s[dwm.SchemeSel][drw.ColBg].pixel);
        var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
        wa.event_mask = x11.ButtonPressMask | x11.ExposureMask;
        wa.override_redirect = x11.True;
        wa.background_pixel = s[dwm.SchemeNorm][drw.ColBg].pixel;
        _ = c.XSelectInput(d, st.win, x11.SubstructureNotifyMask);
        _ = c.XChangeProperty(d, st.win, dwm.netatom[dwm.NetSystemTrayOrientation], x11.XA_CARDINAL, 32, x11.PropModeReplace, @ptrCast(&dwm.netatom[dwm.NetSystemTrayOrientationHorz]), 1);
        _ = c.XChangeWindowAttributes(d, st.win, x11.CWEventMask | x11.CWOverrideRedirect | x11.CWBackPixel, &wa);
        _ = c.XMapRaised(d, st.win);
        _ = c.XSetSelectionOwner(d, dwm.netatom[dwm.NetSystemTray], st.win, x11.CurrentTime);
        if (c.XGetSelectionOwner(d, dwm.netatom[dwm.NetSystemTray]) == st.win) {
            _ = dwm.sendevent(dwm.root, dwm.xatom[dwm.XembedManager], x11.StructureNotifyMask, x11.CurrentTime, @intCast(dwm.netatom[dwm.NetSystemTray]), @intCast(st.win), 0, 0);
            _ = c.XSync(d, x11.False);
        } else {
            std.debug.print("dwm: unable to obtain system tray.\n", .{});
            alloc.destroy(st);
            ptr = null;
            return;
        }
    }

    const st = ptr orelse return;
    w = 0;
    var icon = st.icons;
    while (icon) |i| : (icon = i.next) {
        var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
        wa.background_pixel = s[dwm.SchemeNorm][drw.ColBg].pixel;
        _ = c.XChangeWindowAttributes(d, i.window, x11.CWBackPixel, &wa);
        _ = c.XMapRaised(d, i.window);
        w += systrayspacing;
        i.x = @intCast(w);
        _ = c.XMoveResizeWindow(d, i.window, i.x, 0, @intCast(i.w), @intCast(i.h));
        w += @intCast(i.w);
        if (i.monitor != m) i.monitor = m;
    }
    w = if (w != 0) w + systrayspacing else 1;
    x_pos -= @intCast(w);
    _ = c.XMoveResizeWindow(d, st.win, x_pos, m.bar_y, w, @intCast(bar.bar_height));
    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.x = x_pos;
    wc.y = m.bar_y;
    wc.width = @intCast(w);
    wc.height = bar.bar_height;
    wc.stack_mode = x11.Above;
    wc.sibling = m.barwin;
    _ = c.XConfigureWindow(d, st.win, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWSibling | x11.CWStackMode, &wc);
    _ = c.XMapWindow(d, st.win);
    _ = c.XMapSubwindows(d, st.win);
    if (dwm.draw) |dr| {
        _ = c.XSetForeground(d, dr.gc, s[dwm.SchemeNorm][drw.ColBg].pixel);
        _ = c.XFillRectangle(d, st.win, dr.gc, 0, 0, w, @intCast(bar.bar_height));
    }
    _ = c.XSync(d, x11.False);
}

/// Cleans up the systray: unmaps and destroys the container window, frees memory.
/// Called during WM shutdown.
pub fn cleanup() void {
    const d = dwm.dpy orelse return;
    if (ptr) |st| {
        _ = c.XUnmapWindow(d, st.win);
        _ = c.XDestroyWindow(d, st.win);
        alloc.destroy(st);
        ptr = null;
    }
}

/// Handles a SYSTEM_TRAY_REQUEST_DOCK ClientMessage: creates a new TrayIcon,
/// sets up its geometry and XEMBED properties, reparents it into the tray window,
/// and refreshes the tray layout. Called from the clientmessage event handler.
pub fn handleDockRequest(cme_window: c_long) void {
    const d = dwm.dpy orelse return;
    const st = ptr orelse return;

    const icon = alloc.create(TrayIcon) catch {
        dwm.die("fatal: could not allocate TrayIcon");
        return;
    };
    icon.* = TrayIcon{};
    icon.window = @intCast(cme_window);
    if (icon.window == 0) {
        alloc.destroy(icon);
        return;
    }
    icon.monitor = dwm.selmon;
    icon.next = st.icons;
    st.icons = icon;

    var wa: x11.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(d, icon.window, &wa) == 0) {
        wa.width = @intCast(bar.bar_height);
        wa.height = @intCast(bar.bar_height);
        wa.border_width = 0;
    }
    icon.x = 0;
    icon.y = 0;
    icon.w = wa.width;
    icon.h = wa.height;
    icon.border_width = 0;
    icon.embed_state = .active;
    icon.updateSizeHints();
    updatesystrayicongeom(icon, wa.width, wa.height);
    _ = c.XAddToSaveSet(d, icon.window);
    _ = c.XSelectInput(d, icon.window, x11.StructureNotifyMask | x11.PropertyChangeMask | x11.ResizeRedirectMask);
    _ = c.XReparentWindow(d, icon.window, st.win, 0, 0);

    if (dwm.scheme) |s| {
        var swa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
        swa.background_pixel = s[dwm.SchemeNorm][drw.ColBg].pixel;
        _ = c.XChangeWindowAttributes(d, icon.window, x11.CWBackPixel, &swa);
    }
    _ = dwm.sendevent(icon.window, dwm.netatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_EMBEDDED_NOTIFY, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    _ = dwm.sendevent(icon.window, dwm.netatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_FOCUS_IN, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    _ = dwm.sendevent(icon.window, dwm.netatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_WINDOW_ACTIVATE, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    _ = dwm.sendevent(icon.window, dwm.netatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_MODALITY_ON, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    _ = c.XSync(d, x11.False);
    if (dwm.selmon) |sm| resizebarwin(sm);
    update();
    icon.setClientState(x11.NormalState);
}
