// client.zig — Client lifecycle management.
//
// Owns the Client type and all functions related to creating, destroying,
// resizing, and updating client windows. This module was extracted from
// dwm.zig. It imports dwm.zig for shared global state (dpy, selmon, atoms,
// etc.) — circular imports work fine in Zig.

const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const xerror = @import("xerror.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const Monitor = dwm.Monitor;
const alloc = std.heap.c_allocator;

// ── Client config ──────────────────────────────────────────────────────────
pub const borderpx: c_uint = 1; // border pixel of windows
pub const resizehints: bool = false; // true means respect size hints in tiled resizals (can cause gaps)

pub const Rule = struct {
    class: ?[*:0]const u8,
    instance: ?[*:0]const u8,
    title: ?[*:0]const u8,
    tag: ?u5, // null = inherit monitor's current tag
    isfloating: bool,
    monitor: i32,
};

pub const rules = [_]Rule{
    .{ .class = "Gimp", .instance = null, .title = null, .tag = null, .isfloating = true, .monitor = -1 },
    .{ .class = "Firefox", .instance = null, .title = null, .tag = 8, .isfloating = false, .monitor = -1 },
};

// Fallback window title when WM_NAME is empty.
const broken: [*:0]const u8 = "broken";

/// ICCCM WM_NORMAL_HINTS: the size-constraint data shared by both Client
/// and TrayIcon. Owns the parsing logic (update) and the core constraint
/// logic (apply), so neither struct duplicates it.
pub const SizeHints = struct {
    min_aspect: f32 = 0,
    max_aspect: f32 = 0,
    base_width: c_int = 0,
    base_height: c_int = 0,
    inc_width: c_int = 0,
    inc_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    min_width: c_int = 0,
    min_height: c_int = 0,

    /// Reads WM_NORMAL_HINTS from the X server for `window` and populates
    /// this struct. Returns whether the window has fixed size (min == max).
    pub fn update(self: *SizeHints, window: x11.Window) bool {
        const d = dwm.dpy orelse return false;
        var msize: c_long = undefined;
        var size: x11.XSizeHints = std.mem.zeroes(x11.XSizeHints);
        if (c.XGetWMNormalHints(d, window, &size, &msize) == 0) {
            size.flags = x11.PSize;
        }
        if (size.flags & x11.PBaseSize != 0) {
            self.base_width = @intCast(size.base_width);
            self.base_height = @intCast(size.base_height);
        } else if (size.flags & x11.PMinSize != 0) {
            self.base_width = @intCast(size.min_width);
            self.base_height = @intCast(size.min_height);
        } else {
            self.base_width = 0;
            self.base_height = 0;
        }
        if (size.flags & x11.PResizeInc != 0) {
            self.inc_width = @intCast(size.width_inc);
            self.inc_height = @intCast(size.height_inc);
        } else {
            self.inc_width = 0;
            self.inc_height = 0;
        }
        if (size.flags & x11.PMaxSize != 0) {
            self.max_width = @intCast(size.max_width);
            self.max_height = @intCast(size.max_height);
        } else {
            self.max_width = 0;
            self.max_height = 0;
        }
        if (size.flags & x11.PMinSize != 0) {
            self.min_width = @intCast(size.min_width);
            self.min_height = @intCast(size.min_height);
        } else if (size.flags & x11.PBaseSize != 0) {
            self.min_width = @intCast(size.base_width);
            self.min_height = @intCast(size.base_height);
        } else {
            self.min_width = 0;
            self.min_height = 0;
        }
        if (size.flags & x11.PAspect != 0) {
            self.min_aspect = @as(f32, @floatFromInt(size.min_aspect.y)) / @as(f32, @floatFromInt(size.min_aspect.x));
            self.max_aspect = @as(f32, @floatFromInt(size.max_aspect.x)) / @as(f32, @floatFromInt(size.max_aspect.y));
        } else {
            self.min_aspect = 0.0;
            self.max_aspect = 0.0;
        }
        return self.max_width != 0 and self.max_height != 0 and
            self.max_width == self.min_width and self.max_height == self.min_height;
    }

    /// Constrains (w, h) to ICCCM size hints in-place.
    pub fn apply(self: *SizeHints, w: *c_int, h: *c_int) void {
        w.* = @max(1, w.*);
        h.* = @max(1, h.*);
        const baseismin = self.base_width == self.min_width and self.base_height == self.min_height;
        if (!baseismin) {
            w.* -= self.base_width;
            h.* -= self.base_height;
        }
        if (self.min_aspect > 0 and self.max_aspect > 0) {
            if (self.max_aspect < @as(f32, @floatFromInt(w.*)) / @as(f32, @floatFromInt(h.*))) {
                w.* = @intFromFloat(@as(f32, @floatFromInt(h.*)) * self.max_aspect + 0.5);
            } else if (self.min_aspect < @as(f32, @floatFromInt(h.*)) / @as(f32, @floatFromInt(w.*))) {
                h.* = @intFromFloat(@as(f32, @floatFromInt(w.*)) * self.min_aspect + 0.5);
            }
        }
        if (baseismin) {
            w.* -= self.base_width;
            h.* -= self.base_height;
        }
        if (self.inc_width != 0) w.* -= @mod(w.*, self.inc_width);
        if (self.inc_height != 0) h.* -= @mod(h.*, self.inc_height);
        w.* = @max(w.* + self.base_width, self.min_width);
        h.* = @max(h.* + self.base_height, self.min_height);
        if (self.max_width != 0) w.* = @min(w.*, self.max_width);
        if (self.max_height != 0) h.* = @min(h.*, self.max_height);
    }
};

// A Client represents a single managed window (X11 toplevel).
pub const Client = struct {
    name: [256:0]u8 = [_:0]u8{0} ** 256, // window title (WM_NAME)

    // ICCCM WM_NORMAL_HINTS — parsed size constraints (base, increment, min/max, aspect)
    size_hints: SizeHints = .{},

    // Current geometry (position + size)
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,
    // Previous geometry — saved before fullscreen or layout change so we can restore
    oldx: c_int = 0,
    oldy: c_int = 0,
    oldw: c_int = 0,
    oldh: c_int = 0,

    border_width: c_int = 0, // current border thickness
    old_border_width: c_int = 0, // saved before fullscreen (which sets border to 0)

    tag: u5 = 0, // tag index this client is shown on (0..8)
    isfixed: bool = false, // true if min==max size (cannot be resized)
    isfloating: bool = false, // true if exempt from tiling layout
    isurgent: bool = false, // true if demands attention (flashing tag)
    neverfocus: bool = false, // true if client told us not to give it input focus
    was_floating: bool = false, // floating state before entering fullscreen
    isfullscreen: bool = false,

    next: ?*Client = null, // next in the per-monitor client list (creation order)
    snext: ?*Client = null, // next in the per-monitor focus stack (most-recently-focused order)
    monitor: ?*Monitor = null, // the monitor this client belongs to
    window: x11.Window = 0, // the underlying X11 window id

    // --- Methods ---

    /// A client is visible if its tag matches the monitor's active tag.
    pub fn isVisible(self: *Client) bool {
        const m = self.monitor orelse return false;
        return self.tag == m.tag;
    }

    /// Total width of a client window including its borders on both sides.
    pub fn getWidth(self: *Client) c_int {
        return self.w + 2 * self.border_width;
    }

    /// Total height of a client window including its borders on top and bottom.
    pub fn getHeight(self: *Client) c_int {
        return self.h + 2 * self.border_width;
    }

    /// Inserts this client at the head of its monitor's client list.
    /// New windows appear at the top of the master area because dwm uses a
    /// stack-like insertion order — the most recently attached client tiles first.
    pub fn attach(self: *Client) void {
        const m = self.monitor orelse return;
        self.next = m.clients;
        m.clients = self;
    }

    /// Inserts this client at the head of its monitor's focus-order stack.
    /// The stack list is separate from the client list and tracks focus history —
    /// the most recently focused client is always first, which determines what
    /// gets focused when the current selection is closed.
    pub fn attachStack(self: *Client) void {
        const m = self.monitor orelse return;
        self.snext = m.stack;
        m.stack = self;
    }

    /// Removes this client from its monitor's tiling-order client list.
    /// Used before re-attaching to a different position, or before destroying the client.
    pub fn detach(self: *Client) void {
        const m = self.monitor orelse return;
        var tc: *?*Client = &m.clients;
        while (tc.* != null) {
            if (tc.* == self) {
                tc.* = self.next;
                return;
            }
            tc = &tc.*.?.next;
        }
    }

    /// Removes this client from its monitor's focus-order stack. If this client
    /// was the selected one, picks the next visible client in focus order as the
    /// new selection — this is how focus "falls through" when a window is closed.
    pub fn detachStack(self: *Client) void {
        const m = self.monitor orelse return;
        var tc: *?*Client = &m.stack;
        while (tc.* != null) {
            if (tc.* == self) {
                tc.* = self.snext;
                break;
            }
            tc = &tc.*.?.snext;
        }

        if (self == m.sel) {
            var t = m.stack;
            while (t) |tt| : (t = tt.snext) {
                if (tt.isVisible()) break;
            }
            m.sel = t;
        }
    }

    /// Sends a synthetic ConfigureNotify event to this client, informing it of its
    /// current geometry. Required by ICCCM after we change a window's size/position
    /// so the client knows where it actually ended up (the WM may have adjusted
    /// what the client requested).
    pub fn sendConfigure(self: *Client) void {
        const d = dwm.dpy orelse return;
        var ce: x11.XConfigureEvent = std.mem.zeroes(x11.XConfigureEvent);
        ce.type = x11.ConfigureNotify;
        ce.display = d;
        ce.event = self.window;
        ce.window = self.window;
        ce.x = self.x;
        ce.y = self.y;
        ce.width = self.w;
        ce.height = self.h;
        ce.border_width = self.border_width;
        ce.above = x11.None;
        ce.override_redirect = x11.False;
        _ = c.XSendEvent(d, self.window, x11.False, x11.StructureNotifyMask, @ptrCast(&ce));
    }

    /// Sets the WM_STATE property on this client window (NormalState, IconicState, or
    /// WithdrawnState). Required by ICCCM so pagers and session managers can query
    /// window state.
    pub fn setClientState(self: *Client, state: c_long) void {
        const d = dwm.dpy orelse return;
        const data = [2]c_long{ state, x11.None };
        _ = c.XChangeProperty(d, self.window, dwm.wmatom[dwm.WMState], dwm.wmatom[dwm.WMState], 32, x11.PropModeReplace, @ptrCast(&data), 2);
    }

    /// Sets or clears the urgency flag on this client and updates the X11 WM_HINTS
    /// accordingly. Urgent windows get highlighted in the bar's tag indicators
    /// so the user notices they need attention.
    pub fn setUrgent(self: *Client, urg: bool) void {
        const d = dwm.dpy orelse return;
        self.isurgent = urg;
        const wmh = c.XGetWMHints(d, self.window) orelse return;
        if (urg) {
            wmh.*.flags |= x11.XUrgencyHint;
        } else {
            wmh.*.flags &= ~@as(c_long, x11.XUrgencyHint);
        }
        _ = c.XSetWMHints(d, self.window, wmh);
        _ = c.XFree(wmh);
    }

    /// Constrains proposed geometry (x, y, w, h) to ICCCM size hints. Returns true
    /// if the result differs from the client's current geometry. When interact is true
    /// (user-driven resize), clamps to screen; otherwise clamps to monitor work area.
    pub fn applySizeHints(self: *Client, x: *c_int, y: *c_int, w: *c_int, h: *c_int, interact: bool) bool {
        const m = self.monitor orelse return false;

        // clamp position so window stays on-screen / within work area
        w.* = @max(1, w.*);
        h.* = @max(1, h.*);
        if (interact) {
            if (x.* > dwm.screen_width) x.* = dwm.screen_width - self.getWidth();
            if (y.* > dwm.screen_height) y.* = dwm.screen_height - self.getHeight();
            if (x.* + w.* + 2 * self.border_width < 0) x.* = 0;
            if (y.* + h.* + 2 * self.border_width < 0) y.* = 0;
        } else {
            if (x.* >= m.window_x + m.window_w) x.* = m.window_x + m.window_w - self.getWidth();
            if (y.* >= m.window_y + m.window_h) y.* = m.window_y + m.window_h - self.getHeight();
            if (x.* + w.* + 2 * self.border_width <= m.window_x) x.* = m.window_x;
            if (y.* + h.* + 2 * self.border_width <= m.window_y) y.* = m.window_y;
        }
        if (h.* < bar.bar_height) h.* = bar.bar_height;
        if (w.* < bar.bar_height) w.* = bar.bar_height;

        if (resizehints or self.isfloating or (self.monitor != null and self.monitor.?.layout.arrange == null)) {
            self.size_hints.apply(w, h);
        }
        return x.* != self.x or y.* != self.y or w.* != self.w or h.* != self.h;
    }

    /// Reads ICCCM WM_NORMAL_HINTS (size hints) from the X server and stores
    /// them in this Client's embedded SizeHints. Also sets isfixed (whether
    /// min == max, meaning the window can't be resized).
    pub fn updateSizeHints(self: *Client) void {
        self.isfixed = self.size_hints.update(self.window);
    }

    /// Applies size hints and calls applyGeometry only if the geometry actually
    /// changed. This avoids unnecessary X server round-trips when the layout
    /// re-arranges but nothing actually moved.
    pub fn resize(self: *Client, x: c_int, y: c_int, w: c_int, h: c_int, interact: bool) void {
        var xv = x;
        var yv = y;
        var wv = w;
        var hv = h;
        if (self.applySizeHints(&xv, &yv, &wv, &hv, interact)) self.applyGeometry(xv, yv, wv, hv);
    }

    /// Low-level resize: saves old geometry, applies new geometry to the Client
    /// struct and the X window in one XConfigureWindow call, then sends a synthetic
    /// ConfigureNotify so the client knows its final size. XSync ensures the
    /// server processes it before we continue.
    pub fn applyGeometry(self: *Client, x: c_int, y: c_int, w: c_int, h: c_int) void {
        const d = dwm.dpy orelse return;
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        self.oldx = self.x;
        self.x = x;
        wc.x = x;
        self.oldy = self.y;
        self.y = y;
        wc.y = y;
        self.oldw = self.w;
        self.w = w;
        wc.width = w;
        self.oldh = self.h;
        self.h = h;
        wc.height = h;
        wc.border_width = self.border_width;
        _ = c.XConfigureWindow(d, self.window, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWBorderWidth, &wc);
        self.sendConfigure();
        _ = c.XSync(d, x11.False);
    }

    /// Stops managing this client: removes it from the client and focus lists,
    /// restores its original border width, and frees the Client struct. If the
    /// window wasn't already destroyed (e.g. it's being withdrawn rather than
    /// killed), we restore its state gracefully. After unmanaging, we update
    /// the EWMH client list and re-arrange the layout to fill the gap.
    pub fn unmanage(self: *Client, destroyed: bool) void {
        const d = dwm.dpy orelse return;
        const m = self.monitor;
        self.detach();
        self.detachStack();
        if (!destroyed) {
            var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
            wc.border_width = self.old_border_width;
            _ = c.XGrabServer(d);
            _ = c.XSetErrorHandler(&xerror.dummy);
            _ = c.XConfigureWindow(d, self.window, x11.CWBorderWidth, &wc);
            _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, self.window);
            self.setClientState(x11.WithdrawnState);
            _ = c.XSync(d, x11.False);
            _ = c.XSetErrorHandler(&xerror.handler);
            _ = c.XUngrabServer(d);
        }
        alloc.destroy(self);
        dwm.focus(null);
        updateClientList();
        layout.arrange(m);
    }

    /// Toggles this client in/out of fullscreen mode. Going fullscreen saves
    /// the old geometry and border, removes the border, sets floating, and
    /// resizes to cover the entire monitor. Leaving fullscreen restores
    /// everything. Updates _NET_WM_STATE so EWMH-aware tools know the state.
    pub fn setFullscreen(self: *Client, fullscreen: bool) void {
        const d = dwm.dpy orelse return;
        if (fullscreen and !self.isfullscreen) {
            _ = c.XChangeProperty(d, self.window, dwm.netatom[dwm.NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&dwm.netatom[dwm.NetWMFullscreen]), 1);
            self.isfullscreen = true;
            self.was_floating = self.isfloating;
            self.old_border_width = self.border_width;
            self.border_width = 0;
            self.isfloating = true;
            if (self.monitor) |m| self.applyGeometry(m.monitor_x, m.monitor_y, m.monitor_w, m.monitor_h);
            _ = c.XRaiseWindow(d, self.window);
        } else if (!fullscreen and self.isfullscreen) {
            _ = c.XChangeProperty(d, self.window, dwm.netatom[dwm.NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, null, 0);
            self.isfullscreen = false;
            self.isfloating = self.was_floating;
            self.border_width = self.old_border_width;
            self.x = self.oldx;
            self.y = self.oldy;
            self.w = self.oldw;
            self.h = self.oldh;
            self.applyGeometry(self.x, self.y, self.w, self.h);
            layout.arrange(self.monitor);
        }
    }

    /// Reads the client's title from _NET_WM_NAME (UTF-8) or falls back to
    /// WM_NAME (Latin-1). Sets a "broken" placeholder if both are empty.
    pub fn updateTitle(self: *Client) void {
        if (!dwm.gettextprop(self.window, dwm.netatom[dwm.NetWMName], &self.name)) {
            _ = dwm.gettextprop(self.window, x11.XA_WM_NAME, &self.name);
        }
        if (self.name[0] == 0) {
            const b = std.mem.span(broken);
            @memcpy(self.name[0..b.len], b);
            self.name[b.len] = 0;
        }
    }

    /// Checks _NET_WM_WINDOW_TYPE and _NET_WM_STATE for this client. Dialogs
    /// are auto-floated (they're meant to be popup-sized), and fullscreen state
    /// is applied if the window was already fullscreen before we managed it.
    pub fn updateWindowType(self: *Client) void {
        const state = dwm.getatomprop(self, dwm.netatom[dwm.NetWMState]);
        const wtype = dwm.getatomprop(self, dwm.netatom[dwm.NetWMWindowType]);
        if (state == dwm.netatom[dwm.NetWMFullscreen]) self.setFullscreen(true);
        if (wtype == dwm.netatom[dwm.NetWMWindowTypeDialog]) self.isfloating = true;
    }

    /// Reads WM_HINTS to check urgency and input focus preferences. If the
    /// focused client sets urgency, we clear it (it already has attention).
    /// The InputHint flag tells us if the client wants XSetInputFocus calls —
    /// some clients (like certain Java apps) set this to false, so we track
    /// it as `neverfocus`.
    pub fn updateWmHints(self: *Client) void {
        const d = dwm.dpy orelse return;
        const wmh = c.XGetWMHints(d, self.window) orelse return;
        if (dwm.selmon) |sm| {
            if (self == sm.sel and wmh.*.flags & x11.XUrgencyHint != 0) {
                wmh.*.flags &= ~@as(c_long, x11.XUrgencyHint);
                _ = c.XSetWMHints(d, self.window, wmh);
            } else {
                self.isurgent = (wmh.*.flags & x11.XUrgencyHint) != 0;
            }
        }
        if (wmh.*.flags & x11.InputHint != 0) {
            self.neverfocus = wmh.*.input == 0;
        } else {
            self.neverfocus = false;
        }
        _ = c.XFree(wmh);
    }
};

// ── Module functions ────────────────────────────────────────────────────────

/// Looks up a Client by its X window ID across all monitors. Returns null if
/// the window isn't managed (e.g. it's a bar, root, or unmanaged window).
pub fn fromWindow(w: x11.Window) ?*Client {
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) {
        var cl_it = mon.clients;
        while (cl_it) |cl_c| : (cl_it = cl_c.next) {
            if (cl_c.window == w) return cl_c;
        }
    }
    return null;
}

/// Takes ownership of a new window: creates a Client, reads its properties
/// (title, size hints, transient-for, window type), applies rules, sets the
/// border, subscribes to events, and inserts it into the appropriate monitor's
/// client/stack lists. This is the main entry point for every new window the
/// WM decides to manage. The window is initially placed off-screen then mapped
/// and arranged, which avoids a visible "jump" to its final position.
pub fn manage(w: x11.Window, wa: *x11.XWindowAttributes) void {
    const d = dwm.dpy orelse return;
    const s = dwm.scheme orelse return;
    const cl = alloc.create(Client) catch return;
    cl.* = Client{};
    cl.window = w;
    cl.x = wa.x;
    cl.oldx = wa.x;
    cl.y = wa.y;
    cl.oldy = wa.y;
    cl.w = wa.width;
    cl.oldw = wa.width;
    cl.h = wa.height;
    cl.oldh = wa.height;
    cl.old_border_width = wa.border_width;

    cl.updateTitle();
    var trans: x11.Window = x11.None;
    if (c.XGetTransientForHint(d, w, &trans) != 0) {
        if (fromWindow(trans)) |t| {
            cl.monitor = t.monitor;
            cl.tag = t.tag;
        } else {
            cl.monitor = dwm.selmon;
            applyRules(cl);
        }
    } else {
        cl.monitor = dwm.selmon;
        applyRules(cl);
    }

    const m = cl.monitor orelse {
        alloc.destroy(cl);
        return;
    };
    if (cl.x + cl.getWidth() > m.monitor_x + m.monitor_w) cl.x = m.monitor_x + m.monitor_w - cl.getWidth();
    if (cl.y + cl.getHeight() > m.monitor_y + m.monitor_h) cl.y = m.monitor_y + m.monitor_h - cl.getHeight();
    cl.x = @max(cl.x, m.monitor_x);
    if (m.bar_y == m.monitor_y and cl.x + @divTrunc(cl.w, 2) >= m.window_x and cl.x + @divTrunc(cl.w, 2) < m.window_x + m.window_w) {
        cl.y = @max(cl.y, bar.bar_height);
    } else {
        cl.y = @max(cl.y, m.monitor_y);
    }
    cl.border_width = @intCast(borderpx);

    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.border_width = cl.border_width;
    _ = c.XConfigureWindow(d, w, x11.CWBorderWidth, &wc);
    _ = c.XSetWindowBorder(d, w, s[dwm.SchemeNorm][drw.ColBorder].pixel);
    cl.sendConfigure();
    cl.updateWindowType();
    cl.updateSizeHints();
    cl.updateWmHints();
    _ = c.XSelectInput(d, w, x11.EnterWindowMask | x11.FocusChangeMask | x11.PropertyChangeMask | x11.StructureNotifyMask);
    dwm.grabbuttons(cl, false);
    if (!cl.isfloating) {
        cl.isfloating = (trans != x11.None or cl.isfixed);
        cl.was_floating = cl.isfloating;
    }
    if (cl.isfloating) _ = c.XRaiseWindow(d, cl.window);
    cl.attach();
    cl.attachStack();
    _ = c.XChangeProperty(d, dwm.root, dwm.netatom[dwm.NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl.window), 1);
    _ = c.XMoveResizeWindow(d, cl.window, cl.x + 2 * dwm.screen_width, cl.y, @intCast(cl.w), @intCast(cl.h));
    cl.setClientState(x11.NormalState);
    if (cl.monitor == dwm.selmon) {
        if (dwm.selmon) |sm| dwm.unfocus(sm.sel, false);
    }
    m.sel = cl;
    layout.arrange(m);
    _ = c.XMapWindow(d, cl.window);
    dwm.focus(null);
}

/// Matches a newly managed client against the user-defined rules in events.zig.
/// This is how windows automatically get assigned to specific tags, monitors, or
/// floating state based on their WM_CLASS / title — without it, every new window
/// would just land on the current tag of the focused monitor.
fn applyRules(cl: *Client) void {
    const d = dwm.dpy orelse return;
    cl.isfloating = false;
    var rule_tag: ?u5 = null;

    var ch: x11.XClassHint = .{ .res_name = null, .res_class = null };
    _ = c.XGetClassHint(d, cl.window, &ch);

    const class_str: [*:0]const u8 = if (ch.res_class) |cls| cls else broken;
    const instance_str: [*:0]const u8 = if (ch.res_name) |name| name else broken;

    for (&rules) |*r| {
        if (r.title == null or containsSubstring(&cl.name, r.title.?)) {
            if (r.class == null or containsSubstring(class_str, r.class.?)) {
                if (r.instance == null or containsSubstring(instance_str, r.instance.?)) {
                    cl.isfloating = r.isfloating;
                    if (r.tag) |t| rule_tag = t;
                    var m_it = dwm.mons;
                    while (m_it) |mon| : (m_it = mon.next) {
                        if (mon.num == r.monitor) {
                            cl.monitor = mon;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (ch.res_class) |cls| _ = c.XFree(cls);
    if (ch.res_name) |name| _ = c.XFree(name);

    const m = cl.monitor orelse return;
    cl.tag = rule_tag orelse m.tag;
}

/// Checks whether `haystack` contains `needle` as a substring.
/// Used by applyRules to match window class/instance/title against rule patterns.
fn containsSubstring(haystack: [*:0]const u8, needle: [*:0]const u8) bool {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return true;
    if (h.len < n.len) return false;
    return std.mem.indexOf(u8, h, n) != null;
}

/// Rebuilds the _NET_CLIENT_LIST property on the root window by iterating
/// all clients across all monitors. EWMH pagers and taskbars use this to
/// know which windows exist. Called after manage/unmanage.
pub fn updateClientList() void {
    const d = dwm.dpy orelse return;
    _ = c.XDeleteProperty(d, dwm.root, dwm.netatom[dwm.NetClientList]);
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) {
        var cl_it = mon.clients;
        while (cl_it) |cl_c| : (cl_it = cl_c.next) {
            _ = c.XChangeProperty(d, dwm.root, dwm.netatom[dwm.NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl_c.window), 1);
        }
    }
}
