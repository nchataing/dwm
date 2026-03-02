// dwm - dynamic window manager - Zig rewrite
// See LICENSE file for copyright and license details.
//
// This is the core of the window manager. It handles all X11 events, manages
// client windows across monitors, draws the status bar, and implements the
// tiling/floating/monocle layouts. Most functions here correspond 1:1 with
// the original dwm.c from suckless.
const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const config = @import("config.zig");
const systray = @import("systray.zig");
const xerror = @import("xerror.zig");
const monitor = @import("monitor.zig");
const c = x11.c;

const VERSION = "6.3";

// --- Cursor indices into the global cursor array ---
const CurNormal = 0; // default pointer (arrow)
const CurResize = 1; // shown while resizing a window
const CurMove = 2; // shown while moving a window
const CurLast = 3; // total count (used to size the array)

// --- Color scheme indices (into the scheme array) ---
pub const SchemeNorm = 0; // unfocused / normal windows
pub const SchemeSel = 1; // focused / selected window

// --- EWMH (_NET_*) atom indices ---
// These atoms let other programs (panels, pagers, taskbars) communicate
// with the window manager via the Extended Window Manager Hints protocol.
pub const NetSupported = 0;
pub const NetWMName = 1;
pub const NetWMState = 2;
pub const NetWMCheck = 3;
pub const NetSystemTray = 4;
pub const NetSystemTrayOP = 5;
pub const NetSystemTrayOrientation = 6;
pub const NetSystemTrayOrientationHorz = 7;
pub const NetWMFullscreen = 8;
pub const NetActiveWindow = 9;
pub const NetWMWindowType = 10;
pub const NetWMWindowTypeDialog = 11;
pub const NetClientList = 12;
pub const NetLast = 13;

// --- XEMBED atom indices (used for system tray embedding) ---
pub const XembedManager = 0;
pub const XembedAtom = 1;
pub const XembedInfo = 2;
pub const XLast = 3;

// --- ICCCM WM atom indices ---
// Core window manager protocol atoms defined by the ICCCM spec.
const WMProtocols = 0;
const WMDelete = 1; // WM_DELETE_WINDOW — ask a client to close gracefully
const WMState = 2; // WM_STATE — track normal/iconic/withdrawn state
const WMTakeFocus = 3; // WM_TAKE_FOCUS — give keyboard focus to a client
const WMLast = 4;

// XEMBED visibility state for system tray icons.
// Replaces the old hack of (ab)using Client.tag as a boolean (0=hidden, 1=visible).
pub const EmbedState = enum { inactive, active };

// A Client represents a single managed window (X11 toplevel).
// Also reused for system tray icons (which are embedded windows).
pub const Client = struct {
    name: [256:0]u8 = [_:0]u8{0} ** 256, // window title (WM_NAME)

    // ICCCM size-hint aspect ratios (min_aspect, max_aspect)
    min_aspect: f32 = 0,
    max_aspect: f32 = 0,

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

    // ICCCM size hints (see XSizeHints): base, increment, min, max dimensions
    base_width: c_int = 0,
    base_height: c_int = 0,
    inc_width: c_int = 0, // resize step (e.g. terminal character width)
    inc_height: c_int = 0, // resize step (e.g. terminal character height)
    max_width: c_int = 0,
    max_height: c_int = 0,
    min_width: c_int = 0,
    min_height: c_int = 0,

    border_width: c_int = 0, // current border thickness
    old_border_width: c_int = 0, // saved before fullscreen (which sets border to 0)

    tag: u5 = 0, // tag index this client is shown on (0..8)
    isfixed: bool = false, // true if min==max size (cannot be resized)
    isfloating: bool = false, // true if exempt from tiling layout
    isurgent: bool = false, // true if demands attention (flashing tag)
    neverfocus: bool = false, // true if client told us not to give it input focus
    was_floating: bool = false, // floating state before entering fullscreen
    isfullscreen: bool = false,
    embed_state: EmbedState = .inactive, // XEMBED mapped state (only used for systray icons)

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
        const d = dpy orelse return;
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
        const d = dpy orelse return;
        const data = [2]c_long{ state, x11.None };
        _ = c.XChangeProperty(d, self.window, wmatom[WMState], wmatom[WMState], 32, x11.PropModeReplace, @ptrCast(&data), 2);
    }

    /// Sets or clears the urgency flag on this client and updates the X11 WM_HINTS
    /// accordingly. Urgent windows get highlighted in the bar's tag indicators
    /// so the user notices they need attention.
    pub fn setUrgent(self: *Client, urg: bool) void {
        const d = dpy orelse return;
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

        // set minimum possible
        w.* = @max(1, w.*);
        h.* = @max(1, h.*);
        if (interact) {
            if (x.* > screen_width) x.* = screen_width - self.getWidth();
            if (y.* > screen_height) y.* = screen_height - self.getHeight();
            if (x.* + w.* + 2 * self.border_width < 0) x.* = 0;
            if (y.* + h.* + 2 * self.border_width < 0) y.* = 0;
        } else {
            if (x.* >= m.window_x + m.window_w) x.* = m.window_x + m.window_w - self.getWidth();
            if (y.* >= m.window_y + m.window_h) y.* = m.window_y + m.window_h - self.getHeight();
            if (x.* + w.* + 2 * self.border_width <= m.window_x) x.* = m.window_x;
            if (y.* + h.* + 2 * self.border_width <= m.window_y) y.* = m.window_y;
        }
        if (h.* < bar_height) h.* = bar_height;
        if (w.* < bar_height) w.* = bar_height;

        if (config.resizehints or self.isfloating or (self.monitor != null and self.monitor.?.lt[self.monitor.?.selected_layout].arrange == null)) {
            // ICCCM 4.1.2.3
            const baseismin = self.base_width == self.min_width and self.base_height == self.min_height;
            if (!baseismin) {
                w.* -= self.base_width;
                h.* -= self.base_height;
            }
            // adjust for aspect limits
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
            // adjust for increment value
            if (self.inc_width != 0) w.* -= @mod(w.*, self.inc_width);
            if (self.inc_height != 0) h.* -= @mod(h.*, self.inc_height);
            // restore base dimensions
            w.* = @max(w.* + self.base_width, self.min_width);
            h.* = @max(h.* + self.base_height, self.min_height);
            if (self.max_width != 0) w.* = @min(w.*, self.max_width);
            if (self.max_height != 0) h.* = @min(h.*, self.max_height);
        }
        return x.* != self.x or y.* != self.y or w.* != self.w or h.* != self.h;
    }

    /// Reads ICCCM WM_NORMAL_HINTS (size hints) from the X server and stores
    /// them in this Client struct. These hints define min/max size, aspect ratio,
    /// resize increments, and base size — all used by applySizeHints to constrain
    /// geometry. Also computes isfixed (whether min == max, meaning the window
    /// can't be resized).
    pub fn updateSizeHints(self: *Client) void {
        const d = dpy orelse return;
        var msize: c_long = undefined;
        var size: x11.XSizeHints = std.mem.zeroes(x11.XSizeHints);
        if (c.XGetWMNormalHints(d, self.window, &size, &msize) == 0) {
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
        self.isfixed = (self.max_width != 0 and self.max_height != 0 and self.max_width == self.min_width and self.max_height == self.min_height);
    }
};

pub const Monitor = monitor.Monitor;

// --- Global state ---
// These mirror the globals from the original dwm.c. They are set once during
// setup() and then read/written throughout the event loop.
const broken: [*:0]const u8 = "broken"; // fallback window title when WM_NAME is empty
pub var status_text: [256:0]u8 = [_:0]u8{0} ** 256; // root window name, shown in the bar's status area
pub var screen: c_int = 0; // default X screen number
pub var screen_width: c_int = 0; // total screen width in pixels
pub var screen_height: c_int = 0; // total screen height in pixels
pub var bar_height: c_int = 0; // height of the status bar (font height + 2)
var layout_label_width: c_int = 0; // width of the layout symbol text in the bar
pub var text_lr_pad: c_int = 0; // left+right padding for text drawn in the bar
var numlockmask: c_uint = 0; // dynamically determined NumLock modifier mask
pub var wmatom: [WMLast]x11.Atom = [_]x11.Atom{0} ** WMLast; // ICCCM atoms
pub var netatom: [NetLast]x11.Atom = [_]x11.Atom{0} ** NetLast; // EWMH atoms
pub var xatom: [XLast]x11.Atom = [_]x11.Atom{0} ** XLast; // XEMBED atoms
pub var running: bool = true; // main event loop flag — set to false by quit()
pub var cursor: [CurLast]?*drw.CursorHandle = [_]?*drw.CursorHandle{null} ** CurLast; // cursor handles (normal, resize, move)
pub var scheme: ?[][*]drw.Color = null; // array of color schemes (SchemeNorm, SchemeSel)
pub var dpy: ?*x11.Display = null; // the X display connection (set in main.zig)
pub var draw: ?*drw.DrawContext = null; // drawing context used for the bar
pub var mons: ?*Monitor = null; // head of the linked list of all monitors
pub var selmon: ?*Monitor = null; // the currently selected (focused) monitor
pub var root: x11.Window = 0; // the root window of the default screen
var wmcheckwin: x11.Window = 0; // small helper window required by EWMH _NET_SUPPORTING_WM_CHECK
pub var dmenumon_buf: [2:0]u8 = .{ '0', 0 }; // single-digit monitor number string passed to dmenu

const alloc = std.heap.c_allocator;

// --- Helper functions ---
// These replace the C preprocessor macros from the original dwm.c.
// They are kept as UPPERCASE to signal their macro-like origin.

/// Event mask for grabbing mouse button press and release events.
fn BUTTONMASK() c_long {
    return x11.ButtonPressMask | x11.ButtonReleaseMask;
}

/// Strip NumLock and CapsLock from a modifier mask so keybindings work
/// regardless of whether those locks are active.
fn CLEANMASK(mask: c_uint) c_uint {
    return mask & ~(numlockmask | x11.LockMask) &
        (x11.ShiftMask | x11.ControlMask | x11.Mod1Mask | x11.Mod2Mask | x11.Mod3Mask | x11.Mod4Mask | x11.Mod5Mask);
}

/// Event mask for grabbing mouse motion (used during move/resize drag operations).
fn MOUSEMASK() c_long {
    return BUTTONMASK() | x11.PointerMotionMask;
}

/// Measure the pixel width of a text string, including left+right padding.
pub fn TEXTW(x: [*:0]const u8) c_int {
    if (draw) |d| {
        return @as(c_int, @intCast(d.fontsetGetWidth(x))) + text_lr_pad;
    }
    return 0;
}

// --- Event handler dispatch table ---
// Maps X11 event type codes to handler functions. The main event loop in run()
// indexes into this array with the event type to dispatch it.
const HandlerFn = *const fn (*x11.XEvent) void;
var handler: [x11.LASTEvent]?HandlerFn = init_handler();

fn init_handler() [x11.LASTEvent]?HandlerFn {
    var h = [_]?HandlerFn{null} ** x11.LASTEvent;
    h[x11.ButtonPress] = &buttonpress;
    h[x11.ClientMessage] = &clientmessage;
    h[x11.ConfigureRequest] = &configurerequest;
    h[x11.ConfigureNotify] = &configurenotify;
    h[x11.DestroyNotify] = &destroynotify;
    h[x11.EnterNotify] = &enternotify;
    h[x11.Expose] = &expose;
    h[x11.FocusIn] = &focusin;
    h[x11.KeyPress] = &keypress;
    h[x11.MappingNotify] = &mappingnotify;
    h[x11.MapRequest] = &maprequest;
    h[x11.MotionNotify] = &motionnotify;
    h[x11.PropertyNotify] = &propertynotify;
    h[x11.ResizeRequest] = &resizerequest;
    h[x11.UnmapNotify] = &unmapnotify;
    return h;
}

// --- Function implementations ---

/// Matches a newly managed client against the user-defined rules in config.zig.
/// This is how windows automatically get assigned to specific tags, monitors, or
/// floating state based on their WM_CLASS / title — without it, every new window
/// would just land on the current tag of the focused monitor.
fn applyrules(cl: *Client) void {
    const d = dpy orelse return;
    cl.isfloating = false;
    var rule_tag: ?u5 = null;

    var ch: x11.XClassHint = .{ .res_name = null, .res_class = null };
    _ = c.XGetClassHint(d, cl.window, &ch);

    const class_str: [*:0]const u8 = if (ch.res_class) |cls| cls else broken;
    const instance_str: [*:0]const u8 = if (ch.res_name) |name| name else broken;

    for (&config.rules) |*r| {
        if (r.title == null or cstrstr(&cl.name, r.title.?)) {
            if (r.class == null or cstrstr(class_str, r.class.?)) {
                if (r.instance == null or cstrstr(instance_str, r.instance.?)) {
                    cl.isfloating = r.isfloating;
                    if (r.tag) |t| rule_tag = t;
                    var m = mons;
                    while (m) |mon| : (m = mon.next) {
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

/// Substring search for C-style null-terminated strings.
/// Used by applyrules to match window class/instance/title against rule patterns.
fn cstrstr(haystack: [*:0]const u8, needle: [*:0]const u8) bool {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return true;
    if (h.len < n.len) return false;
    return std.mem.indexOf(u8, h, n) != null;
}

/// Triggers a full layout recalculation. If a specific monitor is given, only that
/// monitor is re-laid-out; if null, all monitors are updated. This is the main
/// entry point called after any state change that affects window positions (tag
/// switches, client add/remove, layout changes, etc.).
fn arrange(m: ?*Monitor) void {
    if (m) |mon| {
        showhide(mon.stack);
    } else {
        var it = mons;
        while (it) |mon| : (it = mon.next) showhide(mon.stack);
    }
    if (m) |mon| {
        mon.applyLayout();
        restack(mon);
    } else {
        var it = mons;
        while (it) |mon| : (it = mon.next) mon.applyLayout();
    }
}

/// X11 ButtonPress event handler. Determines which region of the bar was clicked
/// (tag label, layout symbol, window title, status text) or whether a client
/// window was clicked, then dispatches the matching action from config.buttons.
/// This is how mouse bindings work — clicking a tag switches to it, clicking
/// the layout symbol cycles layouts, etc.
fn buttonpress(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xbutton;
    var click: c_uint = config.ClkRootWin;
    var arg = config.Arg{ .i = 0 };

    // focus monitor if necessary
    if (monitor.fromWindow(ev.window)) |m| {
        if (m != selmon) {
            if (selmon) |sm| unfocus(sm.sel, true);
            selmon = m;
            focus(null);
        }
    }

    const sm = selmon orelse return;
    if (ev.window == sm.barwin) {
        var i: usize = 0;
        var x: c_int = 0;
        while (true) {
            x += TEXTW(config.tags[i]);
            if (ev.x < x or i + 1 >= config.tags.len) break;
            i += 1;
        }
        if (i < config.tags.len and ev.x < x) {
            click = config.ClkTagBar;
            arg = .{ .ui = @intCast(i) };
        } else if (ev.x < x + layout_label_width) {
            click = config.ClkLtSymbol;
        } else if (ev.x > sm.window_w - TEXTW(&status_text) - @as(c_int, @intCast(systray.getsystraywidth()))) {
            click = config.ClkStatusText;
        } else {
            click = config.ClkWinTitle;
        }
    } else if (wintoclient(ev.window)) |cl| {
        focus(cl);
        restack(sm);
        _ = c.XAllowEvents(d, x11.ReplayPointer, x11.CurrentTime);
        click = config.ClkClientWin;
    }

    for (&config.buttons) |*btn| {
        if (click == btn.click and btn.button == ev.button and
            CLEANMASK(btn.mask) == CLEANMASK(ev.state))
        {
            if (click == config.ClkTagBar and btn.arg.i == 0)
                btn.func(&arg)
            else
                btn.func(&btn.arg);
        }
    }
}

/// Detects if another window manager is already running by trying to select
/// SubstructureRedirect on the root window. X11 only allows one client to do
/// this, so if our temporary error handler fires, we know to abort. This must
/// run before setup() to avoid corrupting an existing WM session.
pub fn checkotherwm() void {
    const d = dpy orelse return;
    xerror.xlib = c.XSetErrorHandler(&xerror.startup);
    _ = c.XSelectInput(d, c.DefaultRootWindow(d), x11.SubstructureRedirectMask);
    _ = c.XSync(d, x11.False);
    _ = c.XSetErrorHandler(&xerror.handler);
    _ = c.XSync(d, x11.False);
}

/// Tears down all WM state before exit: shows all windows on all tags (so nothing
/// is left hidden), unmanages every client (restoring their original border widths),
/// destroys the system tray, frees cursors/colors/drawing context, and resets
/// input focus to the root. This ensures a clean handoff if another WM starts.
pub fn cleanup() void {
    const d = dpy orelse return;
    const a = config.Arg{ .ui = @as(c_uint, @bitCast(@as(c_int, -1))) };
    view(&a);
    if (selmon) |sm| sm.lt[sm.selected_layout] = &config.Layout{ .symbol = "", .arrange = null };
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        while (mon.stack) |s| unmanage(s, false);
    }
    _ = c.XUngrabKey(d, x11.AnyKey, x11.AnyModifier, root);
    while (mons != null) mons.?.destroy();

    systray.cleanup();

    for (0..CurLast) |i| {
        if (cursor[i]) |cur| {
            if (draw) |dr| dr.curFree(cur);
        }
    }
    if (scheme) |s| alloc.free(s);
    _ = c.XDestroyWindow(d, wmcheckwin);
    if (draw) |dr| dr.free();
    _ = c.XSync(d, x11.False);
    _ = c.XSetInputFocus(d, x11.PointerRoot, x11.RevertToPointerRoot, x11.CurrentTime);
    _ = c.XDeleteProperty(d, root, netatom[NetActiveWindow]);
}

/// Handles X11 ClientMessage events, which are how clients (and the system tray)
/// communicate EWMH/XEMBED requests to the WM. Covers three main cases:
/// 1. System tray dock requests — an applet wants to embed in the tray
/// 2. _NET_WM_STATE changes — typically fullscreen toggle requests
/// 3. _NET_ACTIVE_WINDOW — another app asking us to activate a window (we just
///    mark it urgent rather than stealing focus, which is less disruptive)
fn clientmessage(e: *x11.XEvent) void {
    if (dpy == null) return;
    const cme = &e.xclient;
    const cl = wintoclient(cme.window);

    if (systray.ptr) |st| {
        if (cme.window == st.win and cme.message_type == netatom[NetSystemTrayOP]) {
            if (cme.data.l[1] == systray.SYSTEM_TRAY_REQUEST_DOCK) {
                systray.handleDockRequest(cme.data.l[2]);
            }
            return;
        }
    }

    if (cl == null) return;
    const client = cl.?;
    if (cme.message_type == netatom[NetWMState]) {
        if (cme.data.l[1] == netatom[NetWMFullscreen] or cme.data.l[2] == netatom[NetWMFullscreen]) {
            setfullscreen(client, cme.data.l[0] == 1 or (cme.data.l[0] == 2 and !client.isfullscreen));
        }
    } else if (cme.message_type == netatom[NetActiveWindow]) {
        if (selmon) |sm| {
            if (client != sm.sel and !client.isurgent) client.setUrgent(true);
        }
    }
}

/// Handles root window ConfigureNotify events, which fire when the screen
/// resolution changes (e.g. xrandr). We update the global screen dimensions,
/// resize the drawing buffer, recreate bars, and resize any fullscreen clients
/// to match the new geometry. Without this, the WM would be stuck at the old resolution.
fn configurenotify(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xconfigure;
    if (ev.window == root) {
        const dirty = (screen_width != ev.width or screen_height != ev.height);
        screen_width = ev.width;
        screen_height = ev.height;
        if (monitor.updateGeometry() or dirty) {
            if (draw) |dr| dr.resize(@intCast(screen_width), @intCast(bar_height));
            updatebars();
            var m = mons;
            while (m) |mon| : (m = mon.next) {
                var cl_it = mon.clients;
                while (cl_it) |cl_c| : (cl_it = cl_c.next) {
                    if (cl_c.isfullscreen) resizeclient(cl_c, mon.monitor_x, mon.monitor_y, mon.monitor_w, mon.monitor_h);
                }
                systray.resizebarwin(mon);
            }
            focus(null);
            arrange(null);
        }
    }
    _ = d;
}

/// Handles ConfigureRequest events — a client asking to change its own geometry
/// or stacking order. For managed clients, we only honor the request if the client
/// is floating (tiled clients get their position from the layout). For unmanaged
/// windows (not yet in our client list), we pass the request through unchanged.
fn configurerequest(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xconfigurerequest;

    if (wintoclient(ev.window)) |cl| {
        if (ev.value_mask & x11.CWBorderWidth != 0) {
            cl.border_width = ev.border_width;
        } else if (cl.isfloating or (selmon != null and selmon.?.lt[selmon.?.selected_layout].arrange == null)) {
            const m = cl.monitor orelse return;
            if (ev.value_mask & x11.CWX != 0) {
                cl.oldx = cl.x;
                cl.x = m.monitor_x + ev.x;
            }
            if (ev.value_mask & x11.CWY != 0) {
                cl.oldy = cl.y;
                cl.y = m.monitor_y + ev.y;
            }
            if (ev.value_mask & x11.CWWidth != 0) {
                cl.oldw = cl.w;
                cl.w = ev.width;
            }
            if (ev.value_mask & x11.CWHeight != 0) {
                cl.oldh = cl.h;
                cl.h = ev.height;
            }
            if ((cl.x + cl.w) > m.monitor_x + m.monitor_w and cl.isfloating)
                cl.x = m.monitor_x + @divTrunc(m.monitor_w, 2) - @divTrunc(cl.getWidth(), 2);
            if ((cl.y + cl.h) > m.monitor_y + m.monitor_h and cl.isfloating)
                cl.y = m.monitor_y + @divTrunc(m.monitor_h, 2) - @divTrunc(cl.getHeight(), 2);
            if ((ev.value_mask & (x11.CWX | x11.CWY) != 0) and (ev.value_mask & (x11.CWWidth | x11.CWHeight) == 0))
                cl.sendConfigure();
            if (cl.isVisible())
                _ = c.XMoveResizeWindow(d, cl.window, cl.x, cl.y, @intCast(cl.w), @intCast(cl.h));
        } else {
            cl.sendConfigure();
        }
    } else {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.x = ev.x;
        wc.y = ev.y;
        wc.width = ev.width;
        wc.height = ev.height;
        wc.border_width = ev.border_width;
        wc.sibling = ev.above;
        wc.stack_mode = ev.detail;
        _ = c.XConfigureWindow(d, ev.window, @intCast(ev.value_mask), &wc);
    }
    _ = c.XSync(d, x11.False);
}

/// Allocates and initializes a new Monitor with defaults from config.zig.
/// Handles DestroyNotify — a window was destroyed by its owner. We unmanage
/// the client (or remove the systray icon) so the WM stops tracking it.
fn destroynotify(e: *x11.XEvent) void {
    const ev = &e.xdestroywindow;
    if (wintoclient(ev.window)) |cl| {
        unmanage(cl, true);
    } else if (systray.wintosystrayicon(ev.window)) |icon| {
        systray.removesystrayicon(icon);
        if (selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }
}

/// Renders the entire status bar for one monitor: tag indicators (with
/// occupancy dots and urgency highlighting), the layout symbol, the focused
/// window's title, and the root window name as status text. The bar is drawn
/// to an off-screen pixmap first, then blitted to the bar window to avoid flicker.
fn drawbar(m: *Monitor) void {
    const d = draw orelse return;
    const s = scheme orelse return;
    if (!m.showbar) return;

    var stw: c_uint = 0;
    if (systray.systraytomon(m) == m and !config.systrayonleft)
        stw = systray.getsystraywidth();

    // draw status first
    var tw: c_int = 0;
    if (selmon == m) {
        d.setScheme(s[SchemeNorm]);
        tw = TEXTW(&status_text) - @divTrunc(text_lr_pad, 2) + 2;
        _ = d.text(m.window_w - tw - @as(c_int, @intCast(stw)), 0, @intCast(tw), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2) - 2), &status_text, false);
    }

    systray.resizebarwin(m);

    var occ = [_]bool{false} ** config.tags.len; // which tags have clients
    var urg = [_]bool{false} ** config.tags.len; // which tags have urgent clients
    var cl_it = m.clients;
    while (cl_it) |cl_c| : (cl_it = cl_c.next) {
        occ[cl_c.tag] = true;
        if (cl_c.isurgent) urg[cl_c.tag] = true;
    }

    var x: c_int = 0;
    const boxs = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 9);
    const boxw = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 6) + 2;

    for (0..config.tags.len) |i| {
        const w = TEXTW(config.tags[i]);
        d.setScheme(if (m.tag == i) s[SchemeSel] else s[SchemeNorm]);
        _ = d.text(x, 0, @intCast(w), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), config.tags[i], urg[i]);
        if (occ[i]) {
            d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), m == selmon and m.sel != null and m.sel.?.tag == i, urg[i]);
        }
        x += w;
    }

    const ltw = TEXTW(&m.layout_symbol);
    layout_label_width = ltw;
    d.setScheme(s[SchemeNorm]);
    x = d.text(x, 0, @intCast(ltw), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), &m.layout_symbol, false);

    const w_remaining = m.window_w - tw - @as(c_int, @intCast(stw)) - x;
    if (w_remaining > bar_height) {
        if (m.sel) |sel_cl| {
            d.setScheme(if (m == selmon) s[SchemeSel] else s[SchemeNorm]);
            _ = d.text(x, 0, @intCast(w_remaining), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), &sel_cl.name, false);
            if (sel_cl.isfloating) d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), sel_cl.isfixed, false);
        } else {
            d.setScheme(s[SchemeNorm]);
            d.rect(x, 0, @intCast(w_remaining), @intCast(bar_height), true, true);
        }
    }
    d.map(m.barwin, 0, 0, @intCast(m.window_w - @as(c_int, @intCast(stw))), @intCast(bar_height));
}

/// Redraws the bar on every monitor. Called after global state changes like
/// focus changes or urgency updates that could affect any monitor's bar.
fn drawbars() void {
    var m = mons;
    while (m) |mon| : (m = mon.next) drawbar(mon);
}

/// Handles EnterNotify — the pointer crossed into a window. This implements
/// sloppy focus (focus-follows-mouse): moving the cursor into a window focuses
/// it. We also switch the active monitor if the pointer enters a window on
/// a different screen. Events from grabs or inferior windows are ignored to
/// prevent spurious focus changes during resize/move operations.
fn enternotify(e: *x11.XEvent) void {
    const ev = &e.xcrossing;
    if ((ev.mode != x11.NotifyNormal or ev.detail == x11.NotifyInferior) and ev.window != root) return;
    const cl = wintoclient(ev.window);
    const m = if (cl) |c_cl| c_cl.monitor else monitor.fromWindow(ev.window);
    const mon = m orelse return;
    if (mon != selmon) {
        if (selmon) |sm| unfocus(sm.sel, true);
        selmon = mon;
    } else if (cl == null or cl == (selmon orelse return).sel) {
        return;
    }
    focus(cl);
}

/// Handles Expose events — redraws the bar when it's been uncovered. Also
/// updates the system tray on the selected monitor since tray icons need
/// repainting after exposure too.
fn expose(e: *x11.XEvent) void {
    const ev = &e.xexpose;
    if (ev.count == 0) {
        if (monitor.fromWindow(ev.window)) |m| {
            drawbar(m);
            if (m == selmon) systray.update();
        }
    }
}

/// Sets keyboard focus to a client (or to root if null). This is the central focus
/// management function: it unfocuses the previous selection, moves the new client
/// to the top of the focus stack, updates the window border color (highlighted for
/// focused, normal for unfocused), sets X input focus, and updates _NET_ACTIVE_WINDOW.
/// If the requested client is not visible, it falls back to the first visible
/// client in the focus stack.
fn focus(cl: ?*Client) void {
    const d = dpy orelse return;
    const s = scheme orelse return;
    var c_focus = cl;
    if (c_focus == null or !c_focus.?.isVisible()) {
        const sm = selmon orelse return;
        c_focus = sm.stack;
        while (c_focus) |cf| {
            if (cf.isVisible()) break;
            c_focus = cf.snext;
        }
    }
    if (selmon) |sm| {
        if (sm.sel != null and sm.sel != c_focus) unfocus(sm.sel.?, false);
    }
    if (c_focus) |cf| {
        if (cf.monitor != selmon) selmon = cf.monitor;
        if (cf.isurgent) cf.setUrgent(false);
        cf.detachStack();
        cf.attachStack();
        grabbuttons(cf, true);
        _ = c.XSetWindowBorder(d, cf.window, s[SchemeSel][drw.ColBorder].pixel);
        setfocus(cf);
    } else {
        _ = c.XSetInputFocus(d, root, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XDeleteProperty(d, root, netatom[NetActiveWindow]);
    }
    if (selmon) |sm| sm.sel = c_focus;
    drawbars();
}

/// Handles FocusIn events — ensures the selected client keeps X input focus.
/// Some clients (e.g. those using XEmbed) can steal focus, so this reasserts
/// focus on our selected window whenever a rogue FocusIn is detected.
fn focusin(e: *x11.XEvent) void {
    const ev = &e.xfocus;
    if (selmon) |sm| {
        if (sm.sel) |sel| {
            if (ev.window != sel.window) setfocus(sel);
        }
    }
}

/// Keybinding action: switches focus to the next/previous monitor.
/// Unfocuses the current selection first so the border color updates correctly.
pub fn focusmon(arg: *const config.Arg) void {
    if (mons == null or mons.?.next == null) return;
    const m = monitor.adjacent(arg.i) orelse return;
    if (m == selmon) return;
    if (selmon) |sm| unfocus(sm.sel, false);
    selmon = m;
    focus(null);
}

/// Keybinding action: cycles focus to the next (arg.i > 0) or previous
/// (arg.i < 0) visible client in the tiling order. Wraps around at the
/// ends of the client list. Respects lockfullscreen — if the focused
/// client is fullscreen, focus stays put to prevent accidental switches.
pub fn focusstack(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    if (sel.isfullscreen and config.lockfullscreen) return;

    var found: ?*Client = null;
    if (arg.i > 0) {
        found = sel.next;
        while (found) |f| {
            if (f.isVisible()) break;
            found = f.next;
        }
        if (found == null) {
            found = sm.clients;
            while (found) |f| {
                if (f.isVisible()) break;
                found = f.next;
            }
        }
    } else {
        var i = sm.clients;
        while (i != null and i != sm.sel) {
            if (i.?.isVisible()) found = i;
            i = i.?.next;
        }
        if (found == null) {
            while (i != null) {
                if (i.?.isVisible()) found = i;
                i = i.?.next;
            }
        }
    }
    if (found) |f| {
        focus(f);
        restack(sm);
    }
}

/// Reads an Atom-typed property from a client's window. Used to query EWMH
/// properties like _NET_WM_STATE and XEMBED_INFO. The special-case for
/// XembedInfo reads the second atom in the pair (the flags field), which
/// tells us whether the systray icon should be mapped or hidden.
pub fn getatomprop(cl: *Client, prop: x11.Atom) x11.Atom {
    const d = dpy orelse return x11.None;
    var di: c_int = undefined;
    var dl: c_ulong = undefined;
    var dl2: c_ulong = undefined;
    var p: ?[*]u8 = null;
    var da: x11.Atom = undefined;
    var atom: x11.Atom = x11.None;

    var req: x11.Atom = x11.XA_ATOM;
    if (prop == xatom[XembedInfo]) req = xatom[XembedInfo];

    if (c.XGetWindowProperty(d, cl.window, prop, 0, @sizeOf(x11.Atom), x11.False, req, &da, &di, &dl, &dl2, @ptrCast(&p)) == x11.Success and p != null) {
        atom = @as(*x11.Atom, @ptrCast(@alignCast(p.?))).*;
        if (da == xatom[XembedInfo] and dl == 2) atom = @as([*]x11.Atom, @ptrCast(@alignCast(p.?)))[1];
        _ = c.XFree(p);
    }
    return atom;
}

/// Queries the current pointer position relative to the root window.
/// Used by movemouse/resizemouse to get the starting cursor position, and
/// by motionnotify/monitor.fromWindow to determine which monitor the cursor is on.
pub fn getrootptr(x: *c_int, y: *c_int) bool {
    const d = dpy orelse return false;
    var di: c_int = undefined;
    var dui: c_uint = undefined;
    var dummy: x11.Window = undefined;
    return c.XQueryPointer(d, root, &dummy, &dummy, x, y, &di, &di, &dui) != 0;
}

/// Reads the WM_STATE property from a window to determine if it's in
/// NormalState, IconicState, or WithdrawnState. Used during scan() to
/// decide whether pre-existing windows should be managed at startup.
fn getstate(w: x11.Window) c_long {
    const d = dpy orelse return -1;
    var format: c_int = undefined;
    var result: c_long = -1;
    var p: ?[*]u8 = null;
    var n: c_ulong = undefined;
    var extra: c_ulong = undefined;
    var real: x11.Atom = undefined;

    if (c.XGetWindowProperty(d, w, wmatom[WMState], 0, 2, x11.False, wmatom[WMState], &real, &format, &n, &extra, @ptrCast(&p)) != x11.Success)
        return -1;
    if (n != 0 and p != null) result = p.?[0];
    if (p) |pp| _ = c.XFree(pp);
    return result;
}

/// Reads a text property (like WM_NAME) from a window into a buffer.
/// Handles both plain STRING and compound text encodings (the latter via
/// XmbTextPropertyToTextList). Used to fetch window titles and the root
/// window name (which external status programs set as the status text).
fn gettextprop(w: x11.Window, atom: x11.Atom, text_buf: []u8) bool {
    const d = dpy orelse return false;
    if (text_buf.len == 0) return false;
    text_buf[0] = 0;
    var name: x11.XTextProperty = undefined;
    if (c.XGetTextProperty(d, w, &name, atom) == 0 or name.nitems == 0) return false;
    if (name.encoding == x11.XA_STRING) {
        const src = std.mem.span(@as([*:0]const u8, @ptrCast(name.value)));
        const copy_len = @min(src.len, text_buf.len - 1);
        @memcpy(text_buf[0..copy_len], src[0..copy_len]);
        text_buf[copy_len] = 0;
    } else {
        var list: ?[*]?[*:0]u8 = null;
        var n: c_int = undefined;
        if (c.XmbTextPropertyToTextList(d, &name, @ptrCast(&list), &n) >= x11.Success and n > 0 and list != null) {
            if (list.?[0]) |first| {
                const src = std.mem.span(first);
                const copy_len = @min(src.len, text_buf.len - 1);
                @memcpy(text_buf[0..copy_len], src[0..copy_len]);
                text_buf[copy_len] = 0;
            }
            c.XFreeStringList(@ptrCast(list));
        }
    }
    _ = c.XFree(name.value);
    return true;
}

/// Sets up X button grabs on a client window. When unfocused, we grab all
/// buttons so clicking anywhere on the window first focuses it. When focused,
/// we only grab the specific modifier+button combos from config.buttons,
/// letting normal clicks pass through to the application. Modifier variants
/// (with NumLock, CapsLock) are grabbed to handle all lock-key states.
fn grabbuttons(cl: *Client, focused: bool) void {
    const d = dpy orelse return;
    updatenumlockmask();
    const modifiers = [_]c_uint{ 0, x11.LockMask, numlockmask, numlockmask | x11.LockMask };
    _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, cl.window);
    if (!focused) {
        _ = c.XGrabButton(d, x11.AnyButton, x11.AnyModifier, cl.window, x11.False, @intCast(BUTTONMASK()), x11.GrabModeSync, x11.GrabModeSync, x11.None, x11.None);
    }
    for (&config.buttons) |*btn| {
        if (btn.click == config.ClkClientWin) {
            for (modifiers) |mod| {
                _ = c.XGrabButton(d, @intCast(btn.button), btn.mask | mod, cl.window, x11.False, @intCast(BUTTONMASK()), x11.GrabModeAsync, x11.GrabModeSync, x11.None, x11.None);
            }
        }
    }
}

/// Registers all keybindings from config.keys as passive grabs on the root
/// window. This is how the WM intercepts hotkeys before any client sees them.
/// Each key is grabbed with all modifier variants (NumLock, CapsLock combos)
/// so the bindings work regardless of lock-key state.
fn grabkeys() void {
    const d = dpy orelse return;
    updatenumlockmask();
    const modifiers = [_]c_uint{ 0, x11.LockMask, numlockmask, numlockmask | x11.LockMask };
    _ = c.XUngrabKey(d, x11.AnyKey, x11.AnyModifier, root);
    for (&config.keys) |*key| {
        const code = c.XKeysymToKeycode(d, key.keysym);
        if (code != 0) {
            for (modifiers) |mod| {
                _ = c.XGrabKey(d, code, key.mod | mod, root, x11.True, x11.GrabModeAsync, x11.GrabModeAsync);
            }
        }
    }
}

/// X11 KeyPress event handler. Translates the hardware keycode to a keysym,
/// then searches config.keys for a matching keysym+modifier combo and calls
/// the associated action function.
fn keypress(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xkey;
    const keysym = c.XkbKeycodeToKeysym(d, @intCast(ev.keycode), 0, 0);
    for (&config.keys) |*key| {
        if (keysym == key.keysym and CLEANMASK(key.mod) == CLEANMASK(ev.state)) {
            key.func(&key.arg);
        }
    }
}

/// Keybinding action: gracefully closes the focused window. First tries
/// WM_DELETE_WINDOW (the polite ICCCM way that lets the app save state);
/// if the client doesn't support that protocol, forcefully kills it with
/// XKillClient as a last resort.
pub fn killclient(_: *const config.Arg) void {
    const d = dpy orelse return;
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;

    if (!sendevent(sel.window, wmatom[WMDelete], x11.NoEventMask, @intCast(wmatom[WMDelete]), x11.CurrentTime, 0, 0, 0)) {
        _ = c.XGrabServer(d);
        _ = c.XSetErrorHandler(&xerror.dummy);
        _ = c.XSetCloseDownMode(d, x11.DestroyAll);
        _ = c.XKillClient(d, sel.window);
        _ = c.XSync(d, x11.False);
        _ = c.XSetErrorHandler(&xerror.handler);
        _ = c.XUngrabServer(d);
    }
}

/// Takes ownership of a new window: creates a Client, reads its properties
/// (title, size hints, transient-for, window type), applies rules, sets the
/// border, subscribes to events, and inserts it into the appropriate monitor's
/// client/stack lists. This is the main entry point for every new window the
/// WM decides to manage. The window is initially placed off-screen then mapped
/// and arranged, which avoids a visible "jump" to its final position.
fn manage(w: x11.Window, wa: *x11.XWindowAttributes) void {
    const d = dpy orelse return;
    const s = scheme orelse return;
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

    updatetitle(cl);
    var trans: x11.Window = x11.None;
    if (c.XGetTransientForHint(d, w, &trans) != 0) {
        if (wintoclient(trans)) |t| {
            cl.monitor = t.monitor;
            cl.tag = t.tag;
        } else {
            cl.monitor = selmon;
            applyrules(cl);
        }
    } else {
        cl.monitor = selmon;
        applyrules(cl);
    }

    const m = cl.monitor orelse {
        alloc.destroy(cl);
        return;
    };
    if (cl.x + cl.getWidth() > m.monitor_x + m.monitor_w) cl.x = m.monitor_x + m.monitor_w - cl.getWidth();
    if (cl.y + cl.getHeight() > m.monitor_y + m.monitor_h) cl.y = m.monitor_y + m.monitor_h - cl.getHeight();
    cl.x = @max(cl.x, m.monitor_x);
    if (m.bar_y == m.monitor_y and cl.x + @divTrunc(cl.w, 2) >= m.window_x and cl.x + @divTrunc(cl.w, 2) < m.window_x + m.window_w) {
        cl.y = @max(cl.y, bar_height);
    } else {
        cl.y = @max(cl.y, m.monitor_y);
    }
    cl.border_width = @intCast(config.borderpx);

    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.border_width = cl.border_width;
    _ = c.XConfigureWindow(d, w, x11.CWBorderWidth, &wc);
    _ = c.XSetWindowBorder(d, w, s[SchemeNorm][drw.ColBorder].pixel);
    cl.sendConfigure();
    updatewindowtype(cl);
    cl.updateSizeHints();
    updatewmhints(cl);
    _ = c.XSelectInput(d, w, x11.EnterWindowMask | x11.FocusChangeMask | x11.PropertyChangeMask | x11.StructureNotifyMask);
    grabbuttons(cl, false);
    if (!cl.isfloating) {
        cl.isfloating = (trans != x11.None or cl.isfixed);
        cl.was_floating = cl.isfloating;
    }
    if (cl.isfloating) _ = c.XRaiseWindow(d, cl.window);
    cl.attach();
    cl.attachStack();
    _ = c.XChangeProperty(d, root, netatom[NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl.window), 1);
    _ = c.XMoveResizeWindow(d, cl.window, cl.x + 2 * screen_width, cl.y, @intCast(cl.w), @intCast(cl.h));
    cl.setClientState(x11.NormalState);
    if (cl.monitor == selmon) {
        if (selmon) |sm| unfocus(sm.sel, false);
    }
    m.sel = cl;
    arrange(m);
    _ = c.XMapWindow(d, cl.window);
    focus(null);
}

/// Handles MappingNotify — the keyboard mapping changed (new layout, remapped
/// keys). We refresh Xlib's internal keycode tables and re-grab our keybindings
/// so they still work with the new mapping.
fn mappingnotify(e: *x11.XEvent) void {
    var ev = &e.xmapping;
    _ = c.XRefreshKeyboardMapping(ev);
    if (ev.request == x11.MappingKeyboard) grabkeys();
}

/// Handles MapRequest — a window is asking to be shown. For systray icons we
/// re-activate the XEMBED embedding. For regular windows, we check if it's
/// already managed (ignore if so) and verify it's not override-redirect (those
/// manage themselves, e.g. menus/tooltips), then call manage() to start tracking it.
fn maprequest(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xmaprequest;

    if (systray.wintosystrayicon(ev.window)) |icon| {
        if (systray.ptr) |st| {
            _ = sendevent(icon.window, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, systray.XEMBED_WINDOW_ACTIVATE, 0, @intCast(st.win), systray.XEMBED_EMBEDDED_VERSION);
        }
        if (selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }

    var wa: x11.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(d, ev.window, &wa) == 0) return;
    if (wa.override_redirect != 0) return;
    if (wintoclient(ev.window) == null) manage(ev.window, &wa);
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
    var c_it = nexttiled(m.clients);
    while (c_it) |cl_c| : (c_it = nexttiled(cl_c.next)) {
        resize(cl_c, m.window_x, m.window_y, m.window_w - 2 * cl_c.border_width, m.window_h - 2 * cl_c.border_width, false);
    }
}

/// Handles MotionNotify on the root window — tracks which monitor the pointer
/// is on and switches the active monitor accordingly. Uses a static variable
/// to avoid redundant focus changes when the pointer stays on the same monitor.
fn motionnotify(e: *x11.XEvent) void {
    const S = struct {
        var mon: ?*Monitor = null;
    };
    const ev = &e.xmotion;
    if (ev.window != root) return;
    const m = monitor.fromRect(ev.x_root, ev.y_root, 1, 1);
    if (m != S.mon and S.mon != null) {
        if (selmon) |sm| unfocus(sm.sel, true);
        selmon = m;
        focus(null);
    }
    S.mon = m;
}

/// Keybinding action: interactive window move via mouse drag. Grabs the pointer,
/// enters a local event loop tracking mouse motion, and moves the window in
/// real-time. Snaps to monitor edges when within `config.snap` pixels. If the
/// window was tiled, dragging it beyond the snap threshold auto-floats it.
/// On release, if the window landed on a different monitor, it's sent there.
pub fn movemouse(_: *const config.Arg) void {
    const d = dpy orelse return;
    const sm = selmon orelse return;
    const cl = sm.sel orelse return;
    if (cl.isfullscreen) return;
    restack(sm);
    const ocx = cl.x;
    const ocy = cl.y;
    if (c.XGrabPointer(d, root, x11.False, @intCast(MOUSEMASK()), x11.GrabModeAsync, x11.GrabModeAsync, x11.None, cursor[CurMove].?.cursor, x11.CurrentTime) != x11.GrabSuccess)
        return;
    var x: c_int = 0;
    var y: c_int = 0;
    if (!getrootptr(&x, &y)) return;
    var lasttime: x11.Time = 0;
    var ev: x11.XEvent = undefined;
    while (true) {
        _ = c.XMaskEvent(d, @intCast(MOUSEMASK() | x11.ExposureMask | x11.SubstructureRedirectMask), &ev);
        switch (ev.type) {
            x11.ConfigureRequest, x11.Expose, x11.MapRequest => {
                if (handler[@intCast(ev.type)]) |h| h(&ev);
            },
            x11.MotionNotify => {
                if ((ev.xmotion.time - lasttime) <= (1000 / 60)) continue;
                lasttime = ev.xmotion.time;
                var nx = ocx + (ev.xmotion.x - x);
                var ny = ocy + (ev.xmotion.y - y);
                if (@abs(sm.window_x - nx) < config.snap) {
                    nx = sm.window_x;
                } else if (@abs((sm.window_x + sm.window_w) - (nx + cl.getWidth())) < config.snap) {
                    nx = sm.window_x + sm.window_w - cl.getWidth();
                }
                if (@abs(sm.window_y - ny) < config.snap) {
                    ny = sm.window_y;
                } else if (@abs((sm.window_y + sm.window_h) - (ny + cl.getHeight())) < config.snap) {
                    ny = sm.window_y + sm.window_h - cl.getHeight();
                }
                if (!cl.isfloating and sm.lt[sm.selected_layout].arrange != null and
                    (@abs(nx - cl.x) > @as(c_int, config.snap) or @abs(ny - cl.y) > @as(c_int, config.snap)))
                {
                    togglefloating(&config.Arg{ .i = 0 });
                }
                if (sm.lt[sm.selected_layout].arrange == null or cl.isfloating)
                    resize(cl, nx, ny, cl.w, cl.h, true);
            },
            x11.ButtonRelease => break,
            else => {},
        }
    }
    _ = c.XUngrabPointer(d, x11.CurrentTime);
    if (monitor.fromRect(cl.x, cl.y, cl.w, cl.h)) |m| {
        if (m != selmon) {
            sendmon(cl, m);
            selmon = m;
            focus(null);
        }
    }
}

/// Skips floating and invisible clients in the client list, returning the next
/// tiled (non-floating, visible) client. Used by tile/monocle layouts to iterate
/// only over clients that participate in the layout.
fn nexttiled(cl: ?*Client) ?*Client {
    var c_it = cl;
    while (c_it) |cc| : (c_it = cc.next) {
        if (!cc.isfloating and cc.isVisible()) return cc;
    }
    return null;
}

/// Moves a client to the head of the client list (making it the new master
/// in tiled layout), focuses it, and re-arranges. Used by zoom() to promote
/// a window to the master area.
fn pop(cl: *Client) void {
    cl.detach();
    cl.attach();
    focus(cl);
    arrange(cl.monitor);
}

/// Handles PropertyNotify events — a window property changed. This is how we
/// stay in sync with clients: we update the status text when the root window
/// name changes (set by xsetroot/slstatus), re-read titles on WM_NAME changes,
/// update floating state on WM_TRANSIENT_FOR changes, refresh size hints, and
/// handle urgency flags from WM_HINTS. Also handles systray icon property changes.
fn propertynotify(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xproperty;

    if (systray.wintosystrayicon(ev.window)) |icon| {
        if (ev.atom == x11.XA_WM_NORMAL_HINTS) {
            icon.updateSizeHints();
            systray.updatesystrayicongeom(icon, icon.w, icon.h);
        } else {
            systray.updatesystrayiconstate(icon, ev);
        }
        if (selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }

    if (ev.window == root and ev.atom == x11.XA_WM_NAME) {
        updatestatus();
    } else if (ev.state == x11.PropertyDelete) {
        return;
    } else if (wintoclient(ev.window)) |cl| {
        switch (ev.atom) {
            x11.XA_WM_TRANSIENT_FOR => {
                var trans: x11.Window = undefined;
                if (!cl.isfloating and c.XGetTransientForHint(d, cl.window, &trans) != 0) {
                    cl.isfloating = wintoclient(trans) != null;
                    if (cl.isfloating) arrange(cl.monitor);
                }
            },
            x11.XA_WM_NORMAL_HINTS => cl.updateSizeHints(),
            x11.XA_WM_HINTS => {
                updatewmhints(cl);
                drawbars();
            },
            else => {},
        }
        if (ev.atom == x11.XA_WM_NAME or ev.atom == netatom[NetWMName]) {
            updatetitle(cl);
            if (cl.monitor) |mon| {
                if (cl == mon.sel) drawbar(mon);
            }
        }
        if (ev.atom == netatom[NetWMWindowType]) updatewindowtype(cl);
    }
}

/// Keybinding action: sets running to false, which exits the main event loop
/// and triggers cleanup. This is the "quit dwm" action.
pub fn quit(_: *const config.Arg) void {
    running = false;
}

/// High-level resize: applies size hints to the requested geometry, then calls
/// resizeclient only if the geometry actually changed. This avoids unnecessary
/// X server round-trips when the layout re-arranges but nothing actually moved.
fn resize(cl: *Client, x: c_int, y: c_int, w: c_int, h: c_int, interact: bool) void {
    var xv = x;
    var yv = y;
    var wv = w;
    var hv = h;
    if (cl.applySizeHints(&xv, &yv, &wv, &hv, interact)) resizeclient(cl, xv, yv, wv, hv);
}

/// Low-level resize: saves old geometry, applies new geometry to the Client
/// struct and the X window in one XConfigureWindow call, then sends a synthetic
/// ConfigureNotify so the client knows its final size. XSync ensures the
/// server processes it before we continue.
fn resizeclient(cl: *Client, x: c_int, y: c_int, w: c_int, h: c_int) void {
    const d = dpy orelse return;
    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    cl.oldx = cl.x;
    cl.x = x;
    wc.x = x;
    cl.oldy = cl.y;
    cl.y = y;
    wc.y = y;
    cl.oldw = cl.w;
    cl.w = w;
    wc.width = w;
    cl.oldh = cl.h;
    cl.h = h;
    wc.height = h;
    wc.border_width = cl.border_width;
    _ = c.XConfigureWindow(d, cl.window, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWBorderWidth, &wc);
    cl.sendConfigure();
    _ = c.XSync(d, x11.False);
}

/// Keybinding action: interactive window resize via mouse drag. Similar to
/// movemouse but warps the cursor to the bottom-right corner and tracks
/// the delta as new width/height. Auto-floats tiled windows when dragged
/// beyond the snap threshold. On release, sends the window to whichever
/// monitor it overlaps most.
pub fn resizemouse(_: *const config.Arg) void {
    const d = dpy orelse return;
    const sm = selmon orelse return;
    const cl = sm.sel orelse return;
    if (cl.isfullscreen) return;
    restack(sm);
    const ocx = cl.x;
    const ocy = cl.y;
    if (c.XGrabPointer(d, root, x11.False, @intCast(MOUSEMASK()), x11.GrabModeAsync, x11.GrabModeAsync, x11.None, cursor[CurResize].?.cursor, x11.CurrentTime) != x11.GrabSuccess)
        return;
    _ = c.XWarpPointer(d, x11.None, cl.window, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
    var lasttime: x11.Time = 0;
    var ev: x11.XEvent = undefined;
    while (true) {
        _ = c.XMaskEvent(d, @intCast(MOUSEMASK() | x11.ExposureMask | x11.SubstructureRedirectMask), &ev);
        switch (ev.type) {
            x11.ConfigureRequest, x11.Expose, x11.MapRequest => {
                if (handler[@intCast(ev.type)]) |h| h(&ev);
            },
            x11.MotionNotify => {
                if ((ev.xmotion.time - lasttime) <= (1000 / 60)) continue;
                lasttime = ev.xmotion.time;
                const nw = @max(ev.xmotion.x - ocx - 2 * cl.border_width + 1, 1);
                const nh = @max(ev.xmotion.y - ocy - 2 * cl.border_width + 1, 1);
                if (cl.monitor.?.window_x + nw >= sm.window_x and cl.monitor.?.window_x + nw <= sm.window_x + sm.window_w and
                    cl.monitor.?.window_y + nh >= sm.window_y and cl.monitor.?.window_y + nh <= sm.window_y + sm.window_h)
                {
                    if (!cl.isfloating and sm.lt[sm.selected_layout].arrange != null and
                        (@abs(nw - cl.w) > @as(c_int, config.snap) or @abs(nh - cl.h) > @as(c_int, config.snap)))
                    {
                        togglefloating(&config.Arg{ .i = 0 });
                    }
                }
                if (sm.lt[sm.selected_layout].arrange == null or cl.isfloating)
                    resize(cl, cl.x, cl.y, nw, nh, true);
            },
            x11.ButtonRelease => break,
            else => {},
        }
    }
    _ = c.XWarpPointer(d, x11.None, cl.window, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
    _ = c.XUngrabPointer(d, x11.CurrentTime);
    while (c.XCheckMaskEvent(d, x11.EnterWindowMask, &ev) != 0) {}
    if (monitor.fromRect(cl.x, cl.y, cl.w, cl.h)) |m| {
        if (m != selmon) {
            sendmon(cl, m);
            selmon = m;
            focus(null);
        }
    }
}

/// Handles ResizeRequest events from systray icons. The tray icons can't resize
/// themselves (they're embedded), so we update their geometry and refresh the tray.
fn resizerequest(e: *x11.XEvent) void {
    const ev = &e.xresizerequest;
    if (systray.wintosystrayicon(ev.window)) |icon| {
        systray.updatesystrayicongeom(icon, ev.width, ev.height);
        if (selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }
}

/// Fixes the X window stacking order after focus or layout changes. Floating
/// and focused windows are raised above tiled ones; tiled windows are stacked
/// below the bar window in focus order. Also drains any pending EnterNotify
/// events to prevent spurious focus changes from the restacking itself.
fn restack(m: *Monitor) void {
    const d = dpy orelse return;
    drawbar(m);
    const sel = m.sel orelse return;
    if (sel.isfloating or m.lt[m.selected_layout].arrange == null)
        _ = c.XRaiseWindow(d, sel.window);
    if (m.lt[m.selected_layout].arrange != null) {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.stack_mode = x11.Below;
        wc.sibling = m.barwin;
        var cl_it = m.stack;
        while (cl_it) |cl_c| : (cl_it = cl_c.snext) {
            if (!cl_c.isfloating and cl_c.isVisible()) {
                _ = c.XConfigureWindow(d, cl_c.window, x11.CWSibling | x11.CWStackMode, &wc);
                wc.sibling = cl_c.window;
            }
        }
    }
    _ = c.XSync(d, x11.False);
    var ev: x11.XEvent = undefined;
    while (c.XCheckMaskEvent(d, x11.EnterWindowMask, &ev) != 0) {}
}

/// The main event loop. Flushes pending requests, then blocks on XNextEvent
/// and dispatches each event through the handler table until `running` is
/// set to false (by quit() or a signal).
pub fn run() void {
    const d = dpy orelse return;
    var ev: x11.XEvent = undefined;
    _ = c.XSync(d, x11.False);
    while (running and c.XNextEvent(d, &ev) == 0) {
        if (handler[@intCast(ev.type)]) |h| h(&ev);
    }
}

/// Scans for pre-existing windows at startup. Queries the root window's children
/// and manages any that are already visible or iconic. Processes normal windows
/// first, then transients in a second pass, so transient windows get correctly
/// associated with their parent's monitor and tags.
pub fn scan() void {
    const d = dpy orelse return;
    var num: c_uint = undefined;
    var d1: x11.Window = undefined;
    var d2: x11.Window = undefined;
    var wins: ?[*]x11.Window = null;

    if (c.XQueryTree(d, root, &d1, &d2, &wins, &num) != 0) {
        if (wins) |w| {
            var i: c_uint = 0;
            while (i < num) : (i += 1) {
                var wa: x11.XWindowAttributes = undefined;
                if (c.XGetWindowAttributes(d, w[i], &wa) == 0 or wa.override_redirect != 0 or
                    c.XGetTransientForHint(d, w[i], &d1) != 0)
                    continue;
                if (wa.map_state == x11.IsViewable or getstate(w[i]) == x11.IconicState)
                    manage(w[i], &wa);
            }
            // now the transients
            i = 0;
            while (i < num) : (i += 1) {
                var wa: x11.XWindowAttributes = undefined;
                if (c.XGetWindowAttributes(d, w[i], &wa) == 0) continue;
                if (c.XGetTransientForHint(d, w[i], &d1) != 0 and
                    (wa.map_state == x11.IsViewable or getstate(w[i]) == x11.IconicState))
                    manage(w[i], &wa);
            }
            _ = c.XFree(wins);
        }
    }
}

/// Transfers a client from its current monitor to a different one. Updates the
/// client's tags to match the destination monitor's active tags so it becomes
/// immediately visible there. Re-arranges both monitors.
fn sendmon(cl: *Client, m: *Monitor) void {
    if (cl.monitor == m) return;
    unfocus(cl, true);
    cl.detach();
    cl.detachStack();
    cl.monitor = m;
    cl.tag = m.tag;
    cl.attach();
    cl.attachStack();
    focus(null);
    arrange(null);
}

/// Sends a ClientMessage event to a window. For WM protocol messages (WMDelete,
/// WMTakeFocus) it first checks if the client actually advertises support for
/// that protocol — returns false if not, so the caller can fall back to a
/// forceful action. For XEMBED messages, it sends unconditionally.
pub fn sendevent(w: x11.Window, proto: x11.Atom, mask: c_int, d0: c_long, d1: c_long, d2: c_long, d3: c_long, d4: c_long) bool {
    const d = dpy orelse return false;
    var n: c_int = undefined;
    var protocols: ?[*]x11.Atom = null;
    var exists: bool = false;
    var mt: x11.Atom = undefined;

    if (proto == wmatom[WMTakeFocus] or proto == wmatom[WMDelete]) {
        mt = wmatom[WMProtocols];
        if (c.XGetWMProtocols(d, w, &protocols, &n) != 0) {
            while (n > 0) {
                n -= 1;
                if (protocols.?[@intCast(n)] == proto) {
                    exists = true;
                    break;
                }
            }
            if (protocols) |p| _ = c.XFree(p);
        }
    } else {
        exists = true;
        mt = proto;
    }

    if (exists) {
        var ev: x11.XEvent = std.mem.zeroes(x11.XEvent);
        ev.type = x11.ClientMessage;
        ev.xclient.window = w;
        ev.xclient.message_type = mt;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = d0;
        ev.xclient.data.l[1] = d1;
        ev.xclient.data.l[2] = d2;
        ev.xclient.data.l[3] = d3;
        ev.xclient.data.l[4] = d4;
        _ = c.XSendEvent(d, w, x11.False, mask, &ev);
    }
    return exists;
}

/// Gives X input focus to a client and updates _NET_ACTIVE_WINDOW. Also sends
/// WM_TAKE_FOCUS for clients that support it. Skips XSetInputFocus for clients
/// with neverfocus set (those that explicitly don't want keyboard input).
fn setfocus(cl: *Client) void {
    const d = dpy orelse return;
    if (!cl.neverfocus) {
        _ = c.XSetInputFocus(d, cl.window, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XChangeProperty(d, root, netatom[NetActiveWindow], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&cl.window), 1);
    }
    _ = sendevent(cl.window, wmatom[WMTakeFocus], x11.NoEventMask, @intCast(wmatom[WMTakeFocus]), x11.CurrentTime, 0, 0, 0);
}

/// Toggles a client in/out of fullscreen mode. Going fullscreen saves the old
/// geometry and border, removes the border, sets floating, and resizes to cover
/// the entire monitor. Leaving fullscreen restores everything. Updates the
/// _NET_WM_STATE property so EWMH-aware tools know the state.
fn setfullscreen(cl: *Client, fullscreen: bool) void {
    const d = dpy orelse return;
    if (fullscreen and !cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.window, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&netatom[NetWMFullscreen]), 1);
        cl.isfullscreen = true;
        cl.was_floating = cl.isfloating;
        cl.old_border_width = cl.border_width;
        cl.border_width = 0;
        cl.isfloating = true;
        if (cl.monitor) |m| resizeclient(cl, m.monitor_x, m.monitor_y, m.monitor_w, m.monitor_h);
        _ = c.XRaiseWindow(d, cl.window);
    } else if (!fullscreen and cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.window, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, null, 0);
        cl.isfullscreen = false;
        cl.isfloating = cl.was_floating;
        cl.border_width = cl.old_border_width;
        cl.x = cl.oldx;
        cl.y = cl.oldy;
        cl.w = cl.oldw;
        cl.h = cl.oldh;
        resizeclient(cl, cl.x, cl.y, cl.w, cl.h);
        arrange(cl.monitor);
    }
}

/// Keybinding action: switches the active layout. Uses the two-slot layout
/// toggle: if the requested layout is different from the current one, it swaps
/// to the alternate slot. If arg.v is null, it toggles between the two most
/// recent layouts (like Alt-Tab but for layouts).
pub fn setlayout(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if (arg.v == null or @as(?*const config.Layout, @ptrCast(@alignCast(arg.v))) != sm.lt[sm.selected_layout]) {
        sm.selected_layout ^= 1;
    }
    if (arg.v) |v| {
        sm.lt[sm.selected_layout] = @ptrCast(@alignCast(v));
    }
    const sym = std.mem.span(sm.lt[sm.selected_layout].symbol);
    @memcpy(sm.layout_symbol[0..sym.len], sym);
    if (sym.len < sm.layout_symbol.len) sm.layout_symbol[sym.len] = 0;
    if (sm.sel != null) {
        arrange(sm);
    } else {
        drawbar(sm);
    }
}

/// Keybinding action: adjusts the master area size ratio. If arg.f < 1.0, it's
/// treated as a relative delta added to the current factor; if >= 1.0, it's an
/// absolute value (minus 1.0). Clamped to [0.05, 0.95] so neither area disappears.
pub fn setmfact(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if (sm.lt[sm.selected_layout].arrange == null) return;
    const f = if (arg.f < 1.0) arg.f + sm.master_factor else arg.f - 1.0;
    if (f < 0.05 or f > 0.95) return;
    sm.master_factor = f;
    arrange(sm);
}

/// One-time initialization of the entire WM. Sets up the X connection, creates
/// the drawing context and fonts, interns all atoms (EWMH, ICCCM, XEMBED),
/// creates cursors, allocates color schemes, initializes the system tray and
/// bars, creates the NetWMCheck support window, advertises EWMH support,
/// registers for root window events, and grabs keybindings. Called once from main.
pub fn setup() void {
    const d = dpy orelse return;

    // clean up any zombies immediately
    sigchld(.CHLD);

    // init screen
    screen = c.DefaultScreen(d);
    screen_width = c.DisplayWidth(d, screen);
    screen_height = c.DisplayHeight(d, screen);
    root = c.RootWindow(d, screen);
    draw = drw.DrawContext.create(d, screen, root, @intCast(screen_width), @intCast(screen_height)) catch {
        die("cannot create drawing context");
        return;
    };
    const dr = draw.?;
    if (dr.fontsetCreate(&config.fonts) == null) {
        die("no fonts could be loaded.");
        return;
    }
    text_lr_pad = @intCast(dr.fonts.?.h);
    bar_height = @as(c_int, @intCast(dr.fonts.?.h)) + 2;
    _ = monitor.updateGeometry();

    // init atoms
    const utf8string = c.XInternAtom(d, "UTF8_STRING", x11.False);
    wmatom[WMProtocols] = c.XInternAtom(d, "WM_PROTOCOLS", x11.False);
    wmatom[WMDelete] = c.XInternAtom(d, "WM_DELETE_WINDOW", x11.False);
    wmatom[WMState] = c.XInternAtom(d, "WM_STATE", x11.False);
    wmatom[WMTakeFocus] = c.XInternAtom(d, "WM_TAKE_FOCUS", x11.False);
    netatom[NetActiveWindow] = c.XInternAtom(d, "_NET_ACTIVE_WINDOW", x11.False);
    netatom[NetSupported] = c.XInternAtom(d, "_NET_SUPPORTED", x11.False);
    netatom[NetSystemTray] = c.XInternAtom(d, "_NET_SYSTEM_TRAY_S0", x11.False);
    netatom[NetSystemTrayOP] = c.XInternAtom(d, "_NET_SYSTEM_TRAY_OPCODE", x11.False);
    netatom[NetSystemTrayOrientation] = c.XInternAtom(d, "_NET_SYSTEM_TRAY_ORIENTATION", x11.False);
    netatom[NetSystemTrayOrientationHorz] = c.XInternAtom(d, "_NET_SYSTEM_TRAY_ORIENTATION_HORZ", x11.False);
    netatom[NetWMName] = c.XInternAtom(d, "_NET_WM_NAME", x11.False);
    netatom[NetWMState] = c.XInternAtom(d, "_NET_WM_STATE", x11.False);
    netatom[NetWMCheck] = c.XInternAtom(d, "_NET_SUPPORTING_WM_CHECK", x11.False);
    netatom[NetWMFullscreen] = c.XInternAtom(d, "_NET_WM_STATE_FULLSCREEN", x11.False);
    netatom[NetWMWindowType] = c.XInternAtom(d, "_NET_WM_WINDOW_TYPE", x11.False);
    netatom[NetWMWindowTypeDialog] = c.XInternAtom(d, "_NET_WM_WINDOW_TYPE_DIALOG", x11.False);
    netatom[NetClientList] = c.XInternAtom(d, "_NET_CLIENT_LIST", x11.False);
    xatom[XembedManager] = c.XInternAtom(d, "MANAGER", x11.False);
    xatom[XembedAtom] = c.XInternAtom(d, "_XEMBED", x11.False);
    xatom[XembedInfo] = c.XInternAtom(d, "_XEMBED_INFO", x11.False);

    // init cursors
    cursor[CurNormal] = dr.curCreate(x11.XC_left_ptr) catch null;
    cursor[CurResize] = dr.curCreate(x11.XC_sizing) catch null;
    cursor[CurMove] = dr.curCreate(x11.XC_fleur) catch null;

    // init appearance
    scheme = alloc.alloc([*]drw.Color, config.colors.len) catch null;
    if (scheme) |s| {
        for (0..config.colors.len) |i| {
            s[i] = dr.schemeCreate(&config.colors[i]) orelse continue;
        }
    }

    // init system tray
    systray.update();
    // init bars
    updatebars();
    updatestatus();

    // supporting window for NetWMCheck
    wmcheckwin = c.XCreateSimpleWindow(d, root, 0, 0, 1, 1, 0, 0, 0);
    _ = c.XChangeProperty(d, wmcheckwin, netatom[NetWMCheck], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&wmcheckwin), 1);
    _ = c.XChangeProperty(d, wmcheckwin, netatom[NetWMName], utf8string, 8, x11.PropModeReplace, "dwm", 3);
    _ = c.XChangeProperty(d, root, netatom[NetWMCheck], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&wmcheckwin), 1);
    // EWMH support per view
    _ = c.XChangeProperty(d, root, netatom[NetSupported], x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&netatom), NetLast);
    _ = c.XDeleteProperty(d, root, netatom[NetClientList]);

    // select events
    var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
    wa.cursor = if (cursor[CurNormal]) |cur| cur.cursor else 0;
    wa.event_mask = x11.SubstructureRedirectMask | x11.SubstructureNotifyMask | x11.ButtonPressMask |
        x11.PointerMotionMask | x11.EnterWindowMask | x11.LeaveWindowMask | x11.StructureNotifyMask |
        x11.PropertyChangeMask;
    _ = c.XChangeWindowAttributes(d, root, x11.CWEventMask | x11.CWCursor, &wa);
    _ = c.XSelectInput(d, root, wa.event_mask);
    grabkeys();
    focus(null);
}

/// Recursively shows visible clients and hides invisible ones by walking the
/// focus stack. Visible clients are moved to their actual position; invisible
/// ones are moved off-screen (x = -2 * width). This is called before layout
/// arrange so that hidden windows don't interfere with tiling calculations.
/// Floating/non-fullscreen clients are also resized to enforce size hints.
fn showhide(cl: ?*Client) void {
    const d = dpy orelse return;
    const cl_c = cl orelse return;
    if (cl_c.isVisible()) {
        _ = c.XMoveWindow(d, cl_c.window, cl_c.x, cl_c.y);
        if ((cl_c.monitor != null and cl_c.monitor.?.lt[cl_c.monitor.?.selected_layout].arrange == null or cl_c.isfloating) and !cl_c.isfullscreen)
            resize(cl_c, cl_c.x, cl_c.y, cl_c.w, cl_c.h, false);
        showhide(cl_c.snext);
    } else {
        showhide(cl_c.snext);
        _ = c.XMoveWindow(d, cl_c.window, cl_c.getWidth() * -2, cl_c.y);
    }
}

/// SIGCHLD handler: reaps zombie child processes. Spawned programs (dmenu,
/// terminal, etc.) become children of the WM process; without this handler,
/// they'd accumulate as zombies after exiting. Re-registers itself because
/// some systems reset the handler after delivery.
fn sigchld(_: std.os.linux.SIG) callconv(.c) void {
    const sa = std.os.linux.Sigaction{
        .handler = .{ .handler = &sigchld },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.CHLD, &sa, null);
    while (true) {
        if (std.c.waitpid(-1, null, 1) <= 0) break; // 1 = WNOHANG
    }
}

/// Keybinding action: forks and execs an external command (e.g. terminal,
/// dmenu). The child closes the X display fd (inherited from parent) and
/// starts a new session so it's not tied to dwm's process group. If the
/// command is dmenu, the monitor number is patched into the argv so dmenu
/// appears on the correct screen.
pub fn spawn(arg: *const config.Arg) void {
    const d = dpy orelse return;
    const v = arg.v orelse return;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(v));

    // Update dmenumon if this is the dmenu command
    if (argv == @as([*:null]const ?[*:0]const u8, @ptrCast(&config.dmenucmd))) {
        if (selmon) |sm| {
            dmenumon_buf[0] = '0' + @as(u8, @intCast(sm.num));
        }
    }

    const pid = std.c.fork();
    if (pid == 0) {
        // child
        if (dpy) |dp| {
            std.posix.close(@intCast(c.ConnectionNumber(dp)));
        }
        _ = std.c.setsid();
        const argv_c: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(v));
        _ = c.execvp(argv_c[0].?, @ptrCast(argv_c));
        std.debug.print("dwm: execvp failed\n", .{});
        std.process.exit(0);
    } else if (pid < 0) {
        return;
    }
    _ = d;
}

/// Keybinding action: moves the focused window to the tag specified in arg.ui.
/// The window disappears from the current view if the target tag isn't the active one.
pub fn tag(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    const new_tag: u5 = @intCast(arg.ui);
    sel.tag = new_tag;
    focus(null);
    arrange(sm);
}

/// Keybinding action: sends the focused window to the next/previous monitor.
/// The window gets the destination monitor's active tags so it's visible there.
pub fn tagmon(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    _ = sel;
    if (mons == null or mons.?.next == null) return;
    if (monitor.adjacent(arg.i)) |m| sendmon(sm.sel.?, m);
}

/// Master-stack tiling layout (the default "[]=" layout). Splits the monitor
/// into a left master area and right stack area based on master_factor. The
/// first client fills the master area; the rest fill the stack area (split
/// vertically). This is dwm's signature layout — efficient for coding with
/// one main editor and several terminals.
pub fn tile(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) n += 1;
    if (n == 0) return;

    const mw: c_int = if (n > 1)
        @intFromFloat(@as(f32, @floatFromInt(m.window_w)) * m.master_factor)
    else
        m.window_w;

    var i: c_uint = 0;
    var ty: c_int = 0;
    cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) {
        if (i == 0) {
            resize(cl_c, m.window_x, m.window_y, mw - (2 * cl_c.border_width), m.window_h - (2 * cl_c.border_width), false);
        } else {
            const h = @divTrunc(m.window_h - ty, @as(c_int, @intCast(n - i)));
            resize(cl_c, m.window_x + mw, m.window_y + ty, m.window_w - mw - (2 * cl_c.border_width), h - (2 * cl_c.border_width), false);
            if (ty + cl_c.getHeight() < m.window_h) ty += cl_c.getHeight();
        }
        i += 1;
    }
}

/// Keybinding action: shows or hides the status bar. Updates the bar position,
/// resizes the bar window (and systray if present), and re-arranges so tiled
/// windows expand into the freed space (or shrink to make room for the bar).
pub fn togglebar(_: *const config.Arg) void {
    const d = dpy orelse return;
    const sm = selmon orelse return;
    sm.showbar = !sm.showbar;
    sm.updateBarPos();
    systray.resizebarwin(sm);
    if (systray.ptr) |st| {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        if (!sm.showbar) {
            wc.y = -bar_height;
        } else {
            wc.y = 0;
            if (!sm.topbar) wc.y = sm.monitor_h - bar_height;
        }
        _ = c.XConfigureWindow(d, st.win, x11.CWY, &wc);
    }
    arrange(sm);
}

/// Keybinding action: toggles the focused window between floating and tiled.
/// Fixed-size windows (equal min and max hints) are always forced to floating.
/// Blocked while fullscreen to prevent layout corruption.
pub fn togglefloating(_: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    if (sel.isfullscreen) return;
    sel.isfloating = !sel.isfloating or sel.isfixed;
    if (sel.isfloating)
        resize(sel, sel.x, sel.y, sel.w, sel.h, false);
    arrange(sm);
}

/// Keybinding action: XORs the focused window's tag bitmask with the given tag.
/// Removes focus decorations from a client: resets the border color to normal
/// and re-grabs all buttons (so clicking it will re-focus). Optionally clears
/// X input focus to root. Called before focusing a different client.
fn unfocus(cl: ?*Client, set_focus: bool) void {
    const d = dpy orelse return;
    const s = scheme orelse return;
    const cl_c = cl orelse return;
    grabbuttons(cl_c, false);
    _ = c.XSetWindowBorder(d, cl_c.window, s[SchemeNorm][drw.ColBorder].pixel);
    if (set_focus) {
        _ = c.XSetInputFocus(d, root, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XDeleteProperty(d, root, netatom[NetActiveWindow]);
    }
}

/// Stops managing a client: removes it from the client and focus lists, restores
/// its original border width, and frees the Client struct. If the window wasn't
/// already destroyed (e.g. it's being withdrawn rather than killed), we restore
/// its state gracefully. After unmanaging, we update the EWMH client list and
/// re-arrange the layout to fill the gap.
fn unmanage(cl: *Client, destroyed: bool) void {
    const d = dpy orelse return;
    const m = cl.monitor;
    cl.detach();
    cl.detachStack();
    if (!destroyed) {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.border_width = cl.old_border_width;
        _ = c.XGrabServer(d);
        _ = c.XSetErrorHandler(&xerror.dummy);
        _ = c.XConfigureWindow(d, cl.window, x11.CWBorderWidth, &wc);
        _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, cl.window);
        cl.setClientState(x11.WithdrawnState);
        _ = c.XSync(d, x11.False);
        _ = c.XSetErrorHandler(&xerror.handler);
        _ = c.XUngrabServer(d);
    }
    alloc.destroy(cl);
    focus(null);
    updateclientlist();
    arrange(m);
}

/// Handles UnmapNotify — a window was unmapped. If it was a send_event (the
/// client deliberately withdrew itself), we mark it as withdrawn. Otherwise
/// we unmanage it. For systray icons, we re-map them raised (they may have
/// been temporarily unmapped by the app) and refresh the tray.
fn unmapnotify(e: *x11.XEvent) void {
    const ev = &e.xunmap;
    if (wintoclient(ev.window)) |cl| {
        if (ev.send_event != 0) {
            cl.setClientState(x11.WithdrawnState);
        } else {
            unmanage(cl, false);
        }
    } else if (systray.wintosystrayicon(ev.window)) |icon| {
        _ = c.XMapRaised(dpy.?, icon.window);
        systray.update();
    }
}

/// Creates the X bar window for any monitor that doesn't have one yet. Each
/// bar is an override-redirect window (so the WM doesn't try to manage it)
/// with ParentRelative background (inherits root pixmap for pseudo-transparency).
/// Also maps the systray window on the appropriate monitor.
fn updatebars() void {
    const d = dpy orelse return;
    var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
    wa.override_redirect = x11.True;
    wa.background_pixmap = x11.ParentRelative;
    wa.event_mask = x11.ButtonPressMask | x11.ExposureMask;
    var ch: x11.XClassHint = .{ .res_name = @constCast("dwm"), .res_class = @constCast("dwm") };
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        if (mon.barwin != 0) continue;
        var w: c_uint = @intCast(mon.window_w);
        if (systray.systraytomon(mon) == mon) w -= systray.getsystraywidth();
        mon.barwin = c.XCreateWindow(d, root, mon.window_x, mon.bar_y, w, @intCast(bar_height), 0, @intCast(c.DefaultDepth(d, screen)), x11.CopyFromParent, c.DefaultVisual(d, screen), x11.CWOverrideRedirect | x11.CWBackPixmap | x11.CWEventMask, &wa);
        if (cursor[CurNormal]) |cur| _ = c.XDefineCursor(d, mon.barwin, cur.cursor);
        if (systray.systraytomon(mon) == mon) {
            if (systray.ptr) |st| _ = c.XMapRaised(d, st.win);
        }
        _ = c.XMapRaised(d, mon.barwin);
        _ = c.XSetClassHint(d, mon.barwin, &ch);
    }
}

/// Rebuilds the _NET_CLIENT_LIST property on the root window by iterating
/// all clients across all monitors. EWMH pagers and taskbars use this to
/// know which windows exist. Called after manage/unmanage.
fn updateclientlist() void {
    const d = dpy orelse return;
    _ = c.XDeleteProperty(d, root, netatom[NetClientList]);
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        var cl_it = mon.clients;
        while (cl_it) |cl_c| : (cl_it = cl_c.next) {
            _ = c.XChangeProperty(d, root, netatom[NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl_c.window), 1);
        }
    }
}

/// Discovers which modifier bit corresponds to Num Lock by scanning the
/// modifier map for XK_Num_Lock. This varies by system, so we re-detect
/// it before grabbing keys/buttons to ensure our modifier masks are correct.
fn updatenumlockmask() void {
    const d = dpy orelse return;
    numlockmask = 0;
    const modmap = c.XGetModifierMapping(d) orelse return;
    defer _ = c.XFreeModifiermap(modmap);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var j: usize = 0;
        while (j < @as(usize, @intCast(modmap.*.max_keypermod))) : (j += 1) {
            if (modmap.*.modifiermap[i * @as(usize, @intCast(modmap.*.max_keypermod)) + j] == c.XKeysymToKeycode(d, x11.XK_Num_Lock))
                numlockmask = @as(c_uint, 1) << @intCast(i);
        }
    }
}

/// Reads the root window's WM_NAME property as the status bar text. External
/// tools like slstatus/xsetroot set this property, and we display it in the
/// bar's status area. Falls back to "dwm-VERSION" if no name is set.
fn updatestatus() void {
    if (!gettextprop(root, x11.XA_WM_NAME, &status_text)) {
        const default_status = "dwm-" ++ VERSION;
        @memcpy(status_text[0..default_status.len], default_status);
        status_text[default_status.len] = 0;
    }
    if (selmon) |sm| drawbar(sm);
    systray.update();
}

/// Reads the client's title from _NET_WM_NAME (UTF-8) or falls back to
/// WM_NAME (Latin-1). Sets a "broken" placeholder if both are empty.
fn updatetitle(cl: *Client) void {
    if (!gettextprop(cl.window, netatom[NetWMName], &cl.name)) {
        _ = gettextprop(cl.window, x11.XA_WM_NAME, &cl.name);
    }
    if (cl.name[0] == 0) {
        const b = std.mem.span(broken);
        @memcpy(cl.name[0..b.len], b);
        cl.name[b.len] = 0;
    }
}

/// Checks _NET_WM_WINDOW_TYPE and _NET_WM_STATE for a client. Dialogs are
/// auto-floated (they're meant to be popup-sized), and fullscreen state is
/// applied if the window was already fullscreen before we managed it.
fn updatewindowtype(cl: *Client) void {
    const state = getatomprop(cl, netatom[NetWMState]);
    const wtype = getatomprop(cl, netatom[NetWMWindowType]);
    if (state == netatom[NetWMFullscreen]) setfullscreen(cl, true);
    if (wtype == netatom[NetWMWindowTypeDialog]) cl.isfloating = true;
}

/// Reads WM_HINTS to check urgency and input focus preferences. If the focused
/// client sets urgency, we clear it (it already has attention). The InputHint
/// flag tells us if the client wants XSetInputFocus calls — some clients
/// (like certain Java apps) set this to false, so we track it as `neverfocus`.
fn updatewmhints(cl: *Client) void {
    const d = dpy orelse return;
    const wmh = c.XGetWMHints(d, cl.window) orelse return;
    if (selmon) |sm| {
        if (cl == sm.sel and wmh.*.flags & x11.XUrgencyHint != 0) {
            wmh.*.flags &= ~@as(c_long, x11.XUrgencyHint);
            _ = c.XSetWMHints(d, cl.window, wmh);
        } else {
            cl.isurgent = (wmh.*.flags & x11.XUrgencyHint) != 0;
        }
    }
    if (wmh.*.flags & x11.InputHint != 0) {
        cl.neverfocus = wmh.*.input == 0;
    } else {
        cl.neverfocus = false;
    }
    _ = c.XFree(wmh);
}

/// Keybinding action: switches the monitor's view to the tag in arg.ui.
pub fn view(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const new_tag: u5 = @intCast(arg.ui);
    if (new_tag == sm.tag) return;
    sm.tag = new_tag;
    focus(null);
    arrange(sm);
}

/// Looks up a Client by its X window ID across all monitors. Returns null if
/// the window isn't managed (e.g. it's a bar, root, or unmanaged window).
pub fn wintoclient(w: x11.Window) ?*Client {
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        var cl_it = mon.clients;
        while (cl_it) |cl_c| : (cl_it = cl_c.next) {
            if (cl_c.window == w) return cl_c;
        }
    }
    return null;
}

/// Keybinding action: promotes the focused window to the master area. If it's
/// already the master (first tiled client), promotes the second tiled client
/// instead — effectively swapping master and top-of-stack. No-op for floating
/// clients or layouts without a master area.
pub fn zoom(_: *const config.Arg) void {
    const sm = selmon orelse return;
    var cl = sm.sel orelse return;
    if (sm.lt[sm.selected_layout].arrange == null or (sm.sel != null and sm.sel.?.isfloating)) return;
    if (cl == nexttiled(sm.clients)) {
        cl = nexttiled(cl.next) orelse return;
    }
    pop(cl);
}

// Custom functions

/// Synthesizes a key press+release event and sends it to the window under the
/// pointer. Used by f1switchfocus to inject an F1 keypress into the focused
/// app before switching focus (e.g. to trigger a specific action in the app).
pub fn fakekeypress(keysym: x11.KeySym) void {
    const d = dpy orelse return;
    var event: x11.XEvent = std.mem.zeroes(x11.XEvent);
    event.xkey.keycode = c.XKeysymToKeycode(d, keysym);
    event.xkey.same_screen = x11.True;
    event.xkey.subwindow = root;
    while (event.xkey.subwindow != 0) {
        event.xkey.window = event.xkey.subwindow;
        _ = c.XQueryPointer(d, event.xkey.window, &event.xkey.root, &event.xkey.subwindow, &event.xkey.x_root, &event.xkey.y_root, &event.xkey.x, &event.xkey.y, &event.xkey.state);
    }
    event.type = x11.KeyPress;
    _ = c.XSendEvent(d, x11.PointerWindow, x11.True, x11.KeyPressMask, &event);
    _ = c.XFlush(d);
    _ = c.usleep(1000); // 1 millisecond
    event.type = x11.KeyRelease;
    _ = c.XSendEvent(d, x11.PointerWindow, x11.True, x11.ButtonReleaseMask, &event);
    _ = c.XFlush(d);
    _ = c.usleep(1000);
}

/// Custom keybinding action: sends an F1 keypress to the current window, waits
/// briefly for it to process, then moves focus to the next window in the stack.
/// This is a user-specific workflow shortcut (e.g. triggering help/action in one
/// app then switching to another).
pub fn f1switchfocus(_: *const config.Arg) void {
    fakekeypress(x11.XK_F1);
    _ = c.usleep(10 * 1000); // 10ms
    const arg = config.Arg{ .i = 1 };
    focusstack(&arg);
}

/// Prints an error message and exits immediately. Used for unrecoverable
/// errors like allocation failures or detecting another WM is running.
pub fn die(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
