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
const c = x11.c;

const VERSION = "6.3";

// --- XEMBED protocol constants (see freedesktop XEMBED spec) ---
// These are used by the system tray to embed applet windows into the bar.
const SYSTEM_TRAY_REQUEST_DOCK = 0;
const XEMBED_EMBEDDED_NOTIFY = 0;
const XEMBED_WINDOW_ACTIVATE = 1;
const XEMBED_WINDOW_DEACTIVATE = 2;
const XEMBED_FOCUS_IN = 4;
const XEMBED_MODALITY_ON = 10;
const XEMBED_MAPPED = (1 << 0);
const XEMBED_EMBEDDED_VERSION = 0;

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
const NetSupported = 0;
const NetWMName = 1;
const NetWMState = 2;
const NetWMCheck = 3;
const NetSystemTray = 4;
const NetSystemTrayOP = 5;
const NetSystemTrayOrientation = 6;
const NetSystemTrayOrientationHorz = 7;
const NetWMFullscreen = 8;
const NetActiveWindow = 9;
const NetWMWindowType = 10;
const NetWMWindowTypeDialog = 11;
const NetClientList = 12;
const NetLast = 13;

// --- XEMBED atom indices (used for system tray embedding) ---
const XembedManager = 0;
const XembedAtom = 1;
const XembedInfo = 2;
const XLast = 3;

// --- ICCCM WM atom indices ---
// Core window manager protocol atoms defined by the ICCCM spec.
const WMProtocols = 0;
const WMDelete = 1; // WM_DELETE_WINDOW — ask a client to close gracefully
const WMState = 2; // WM_STATE — track normal/iconic/withdrawn state
const WMTakeFocus = 3; // WM_TAKE_FOCUS — give keyboard focus to a client
const WMLast = 4;

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

    tags: c_uint = 0, // bitmask of tags this client is shown on
    isfixed: bool = false, // true if min==max size (cannot be resized)
    isfloating: bool = false, // true if exempt from tiling layout
    isurgent: bool = false, // true if demands attention (flashing tag)
    neverfocus: bool = false, // true if client told us not to give it input focus
    was_floating: bool = false, // floating state before entering fullscreen
    isfullscreen: bool = false,

    next: ?*Client = null, // next in the per-monitor client list (creation order)
    snext: ?*Client = null, // next in the per-monitor focus stack (most-recently-focused order)
    mon: ?*Monitor = null, // the monitor this client belongs to
    win: x11.Window = 0, // the underlying X11 window id
};

// A Monitor corresponds to a physical screen (via Xinerama).
// Each monitor has its own client list, focus stack, tag state, and bar window.
pub const Monitor = struct {
    layout_symbol: [16:0]u8 = [_:0]u8{0} ** 16, // text shown in the bar for current layout (e.g. "[]=")
    master_factor: f32 = 0, // fraction of screen width given to master area [0.05..0.95]
    num_masters: c_int = 0, // number of windows in the master area
    num: c_int = 0, // monitor index (0-based, matches Xinerama order)
    bar_y: c_int = 0, // y position of the bar window

    // Full monitor geometry (used for fullscreen)
    monitor_x: c_int = 0,
    monitor_y: c_int = 0,
    monitor_w: c_int = 0,
    monitor_h: c_int = 0,

    // Usable "window area" geometry (excludes bar)
    window_x: c_int = 0,
    window_y: c_int = 0,
    window_w: c_int = 0,
    window_h: c_int = 0,

    // Tag state — we keep two slots so `view` can toggle between current and previous
    selected_tags: c_uint = 0, // index (0 or 1) into tagset[] for the active tag set
    selected_layout: c_uint = 0, // index (0 or 1) into lt[] for the active layout
    tagset: [2]c_uint = .{ 1, 1 }, // two remembered tag bitmasks
    showbar: bool = true,
    topbar: bool = true,

    clients: ?*Client = null, // head of the client linked list (creation order)
    sel: ?*Client = null, // currently focused client on this monitor
    stack: ?*Client = null, // head of the focus-stack linked list (MRU order)
    next: ?*Monitor = null, // next monitor in the global linked list

    barwin: x11.Window = 0, // the X11 window used for the status bar
    lt: [2]*const config.Layout = undefined, // two remembered layouts (toggle with setlayout)
};

// The system tray — an area in the bar that embeds external applet windows
// (e.g. volume, network, bluetooth indicators) via the XEMBED protocol.
const Systray = struct {
    win: x11.Window = 0, // the container window that holds all tray icons
    icons: ?*Client = null, // linked list of embedded icon "clients"
};

// --- Global state ---
// These mirror the globals from the original dwm.c. They are set once during
// setup() and then read/written throughout the event loop.
var systray_ptr: ?*Systray = null;
const broken: [*:0]const u8 = "broken"; // fallback window title when WM_NAME is empty
var status_text: [256:0]u8 = [_:0]u8{0} ** 256; // root window name, shown in the bar's status area
var screen: c_int = 0; // default X screen number
var screen_width: c_int = 0; // total screen width in pixels
var screen_height: c_int = 0; // total screen height in pixels
var bar_height: c_int = 0; // height of the status bar (font height + 2)
var layout_label_width: c_int = 0; // width of the layout symbol text in the bar
var text_lr_pad: c_int = 0; // left+right padding for text drawn in the bar
var xerrorxlib: ?*const fn (?*x11.Display, ?*x11.XErrorEvent) callconv(.c) c_int = null; // Xlib's default error handler (saved so we can restore it)
var numlockmask: c_uint = 0; // dynamically determined NumLock modifier mask
var wmatom: [WMLast]x11.Atom = [_]x11.Atom{0} ** WMLast; // ICCCM atoms
var netatom: [NetLast]x11.Atom = [_]x11.Atom{0} ** NetLast; // EWMH atoms
var xatom: [XLast]x11.Atom = [_]x11.Atom{0} ** XLast; // XEMBED atoms
pub var running: bool = true; // main event loop flag — set to false by quit()
var cursor: [CurLast]?*drw.CursorHandle = [_]?*drw.CursorHandle{null} ** CurLast; // cursor handles (normal, resize, move)
var scheme: ?[][*]drw.Color = null; // array of color schemes (SchemeNorm, SchemeSel)
pub var dpy: ?*x11.Display = null; // the X display connection (set in main.zig)
var draw: ?*drw.DrawContext = null; // drawing context used for the bar
var mons: ?*Monitor = null; // head of the linked list of all monitors
pub var selmon: ?*Monitor = null; // the currently selected (focused) monitor
var root: x11.Window = 0; // the root window of the default screen
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

/// A client is visible if any of its tags overlap with the monitor's active tagset.
fn ISVISIBLE(cl: *Client) bool {
    const m = cl.mon orelse return false;
    return (cl.tags & m.tagset[m.selected_tags]) != 0;
}

/// Event mask for grabbing mouse motion (used during move/resize drag operations).
fn MOUSEMASK() c_long {
    return BUTTONMASK() | x11.PointerMotionMask;
}

/// Total width of a client window including its borders on both sides.
fn WIDTH(cl: *Client) c_int {
    return cl.w + 2 * cl.border_width;
}

/// Total height of a client window including its borders on top and bottom.
fn HEIGHT(cl: *Client) c_int {
    return cl.h + 2 * cl.border_width;
}

/// Measure the pixel width of a text string, including left+right padding.
fn TEXTW(x: [*:0]const u8) c_int {
    if (draw) |d| {
        return @as(c_int, @intCast(d.fontsetGetWidth(x))) + text_lr_pad;
    }
    return 0;
}

/// Compute the area (in pixels²) of the overlap between a rectangle and a monitor's
/// window area. Used by recttomon() to determine which monitor a window belongs to.
fn INTERSECT(x: c_int, y: c_int, w: c_int, h: c_int, m: *Monitor) c_int {
    return @max(0, @min(x + w, m.window_x + m.window_w) - @max(x, m.window_x)) *
        @max(0, @min(y + h, m.window_y + m.window_h) - @max(y, m.window_y));
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
    cl.tags = 0;

    var ch: x11.XClassHint = .{ .res_name = null, .res_class = null };
    _ = c.XGetClassHint(d, cl.win, &ch);

    const class_str: [*:0]const u8 = if (ch.res_class) |cls| cls else broken;
    const instance_str: [*:0]const u8 = if (ch.res_name) |name| name else broken;

    for (&config.rules) |*r| {
        if (r.title == null or cstrstr(&cl.name, r.title.?)) {
            if (r.class == null or cstrstr(class_str, r.class.?)) {
                if (r.instance == null or cstrstr(instance_str, r.instance.?)) {
                    cl.isfloating = r.isfloating;
                    cl.tags |= r.tags;
                    var m = mons;
                    while (m) |mon| : (m = mon.next) {
                        if (mon.num == r.monitor) {
                            cl.mon = mon;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (ch.res_class) |cls| _ = c.XFree(cls);
    if (ch.res_name) |name| _ = c.XFree(name);

    const m = cl.mon orelse return;
    cl.tags = if (cl.tags & config.TAGMASK != 0) cl.tags & config.TAGMASK else m.tagset[m.selected_tags];
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

/// Clamps a client's requested geometry to respect ICCCM size hints (min/max size,
/// aspect ratio, resize increments) and screen boundaries. Returns true if the
/// geometry actually changed — callers use this to avoid unnecessary X calls.
/// Without this, clients could request absurd sizes or escape the visible screen.
fn applysizehints(cl: *Client, x: *c_int, y: *c_int, w: *c_int, h: *c_int, interact: bool) bool {
    const m = cl.mon orelse return false;

    // set minimum possible
    w.* = @max(1, w.*);
    h.* = @max(1, h.*);
    if (interact) {
        if (x.* > screen_width) x.* = screen_width - WIDTH(cl);
        if (y.* > screen_height) y.* = screen_height - HEIGHT(cl);
        if (x.* + w.* + 2 * cl.border_width < 0) x.* = 0;
        if (y.* + h.* + 2 * cl.border_width < 0) y.* = 0;
    } else {
        if (x.* >= m.window_x + m.window_w) x.* = m.window_x + m.window_w - WIDTH(cl);
        if (y.* >= m.window_y + m.window_h) y.* = m.window_y + m.window_h - HEIGHT(cl);
        if (x.* + w.* + 2 * cl.border_width <= m.window_x) x.* = m.window_x;
        if (y.* + h.* + 2 * cl.border_width <= m.window_y) y.* = m.window_y;
    }
    if (h.* < bar_height) h.* = bar_height;
    if (w.* < bar_height) w.* = bar_height;

    if (config.resizehints or cl.isfloating or (cl.mon != null and cl.mon.?.lt[cl.mon.?.selected_layout].arrange == null)) {
        // ICCCM 4.1.2.3
        const baseismin = cl.base_width == cl.min_width and cl.base_height == cl.min_height;
        if (!baseismin) {
            w.* -= cl.base_width;
            h.* -= cl.base_height;
        }
        // adjust for aspect limits
        if (cl.min_aspect > 0 and cl.max_aspect > 0) {
            if (cl.max_aspect < @as(f32, @floatFromInt(w.*)) / @as(f32, @floatFromInt(h.*))) {
                w.* = @intFromFloat(@as(f32, @floatFromInt(h.*)) * cl.max_aspect + 0.5);
            } else if (cl.min_aspect < @as(f32, @floatFromInt(h.*)) / @as(f32, @floatFromInt(w.*))) {
                h.* = @intFromFloat(@as(f32, @floatFromInt(w.*)) * cl.min_aspect + 0.5);
            }
        }
        if (baseismin) {
            w.* -= cl.base_width;
            h.* -= cl.base_height;
        }
        // adjust for increment value
        if (cl.inc_width != 0) w.* -= @mod(w.*, cl.inc_width);
        if (cl.inc_height != 0) h.* -= @mod(h.*, cl.inc_height);
        // restore base dimensions
        w.* = @max(w.* + cl.base_width, cl.min_width);
        h.* = @max(h.* + cl.base_height, cl.min_height);
        if (cl.max_width != 0) w.* = @min(w.*, cl.max_width);
        if (cl.max_height != 0) h.* = @min(h.*, cl.max_height);
    }
    return x.* != cl.x or y.* != cl.y or w.* != cl.w or h.* != cl.h;
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
        arrangemon(mon);
        restack(mon);
    } else {
        var it = mons;
        while (it) |mon| : (it = mon.next) arrangemon(mon);
    }
}

/// Updates the layout symbol shown in the bar (e.g. "[]=", "[M]") and calls the
/// active layout's arrange function to position tiled clients on this monitor.
fn arrangemon(m: *Monitor) void {
    const sym = std.mem.span(m.lt[m.selected_layout].symbol);
    @memcpy(m.layout_symbol[0..sym.len], sym);
    if (sym.len < m.layout_symbol.len) m.layout_symbol[sym.len] = 0;
    if (m.lt[m.selected_layout].arrange) |arrange_fn| arrange_fn(m);
}

/// Inserts a client at the head of its monitor's client list.
/// New windows appear at the top of the master area because dwm uses a
/// stack-like insertion order — the most recently attached client tiles first.
fn attach(cl: *Client) void {
    const m = cl.mon orelse return;
    cl.next = m.clients;
    m.clients = cl;
}

/// Inserts a client at the head of its monitor's focus-order stack.
/// The stack list is separate from the client list and tracks focus history —
/// the most recently focused client is always first, which determines what
/// gets focused when the current selection is closed.
fn attachstack(cl: *Client) void {
    const m = cl.mon orelse return;
    cl.snext = m.stack;
    m.stack = cl;
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
    if (wintomon(ev.window)) |m| {
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
            arg = .{ .ui = @as(c_uint, 1) << @intCast(i) };
        } else if (ev.x < x + layout_label_width) {
            click = config.ClkLtSymbol;
        } else if (ev.x > sm.window_w - TEXTW(&status_text) - @as(c_int, @intCast(getsystraywidth()))) {
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
    xerrorxlib = c.XSetErrorHandler(&xerrorstart);
    _ = c.XSelectInput(d, c.DefaultRootWindow(d), x11.SubstructureRedirectMask);
    _ = c.XSync(d, x11.False);
    _ = c.XSetErrorHandler(&xerror);
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
    while (mons != null) cleanupmon(mons.?);

    if (config.showsystray) {
        if (systray_ptr) |st| {
            _ = c.XUnmapWindow(d, st.win);
            _ = c.XDestroyWindow(d, st.win);
            alloc.destroy(st);
            systray_ptr = null;
        }
    }

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

/// Removes a monitor from the linked list and destroys its bar window.
/// Called when Xinerama reports fewer screens than before, or during cleanup.
fn cleanupmon(mon: *Monitor) void {
    const d = dpy orelse return;
    if (mon == mons) {
        mons = mons.?.next;
    } else {
        var m = mons;
        while (m) |mm| : (m = mm.next) {
            if (mm.next == mon) {
                mm.next = mon.next;
                break;
            }
        }
    }
    _ = c.XUnmapWindow(d, mon.barwin);
    _ = c.XDestroyWindow(d, mon.barwin);
    alloc.destroy(mon);
}

/// Handles X11 ClientMessage events, which are how clients (and the system tray)
/// communicate EWMH/XEMBED requests to the WM. Covers three main cases:
/// 1. System tray dock requests — an applet wants to embed in the tray
/// 2. _NET_WM_STATE changes — typically fullscreen toggle requests
/// 3. _NET_ACTIVE_WINDOW — another app asking us to activate a window (we just
///    mark it urgent rather than stealing focus, which is less disruptive)
fn clientmessage(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const cme = &e.xclient;
    const cl = wintoclient(cme.window);

    if (config.showsystray) {
        if (systray_ptr) |st| {
            if (cme.window == st.win and cme.message_type == netatom[NetSystemTrayOP]) {
                if (cme.data.l[1] == SYSTEM_TRAY_REQUEST_DOCK) {
                    const icon = alloc.create(Client) catch {
                        die("fatal: could not allocate Client");
                        return;
                    };
                    icon.* = Client{};
                    icon.win = @intCast(cme.data.l[2]);
                    if (icon.win == 0) {
                        alloc.destroy(icon);
                        return;
                    }
                    icon.mon = selmon;
                    icon.next = st.icons;
                    st.icons = icon;

                    var wa: x11.XWindowAttributes = undefined;
                    if (c.XGetWindowAttributes(d, icon.win, &wa) == 0) {
                        wa.width = @intCast(bar_height);
                        wa.height = @intCast(bar_height);
                        wa.border_width = 0;
                    }
                    icon.x = 0;
                    icon.oldx = 0;
                    icon.y = 0;
                    icon.oldy = 0;
                    icon.w = wa.width;
                    icon.oldw = wa.width;
                    icon.h = wa.height;
                    icon.oldh = wa.height;
                    icon.old_border_width = wa.border_width;
                    icon.border_width = 0;
                    icon.isfloating = true;
                    icon.tags = 1;
                    updatesizehints(icon);
                    updatesystrayicongeom(icon, wa.width, wa.height);
                    _ = c.XAddToSaveSet(d, icon.win);
                    _ = c.XSelectInput(d, icon.win, x11.StructureNotifyMask | x11.PropertyChangeMask | x11.ResizeRedirectMask);
                    _ = c.XReparentWindow(d, icon.win, st.win, 0, 0);

                    if (scheme) |s| {
                        var swa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
                        swa.background_pixel = s[SchemeNorm][drw.ColBg].pixel;
                        _ = c.XChangeWindowAttributes(d, icon.win, x11.CWBackPixel, &swa);
                    }
                    _ = sendevent(icon.win, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_EMBEDDED_NOTIFY, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
                    _ = sendevent(icon.win, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_FOCUS_IN, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
                    _ = sendevent(icon.win, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_WINDOW_ACTIVATE, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
                    _ = sendevent(icon.win, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_MODALITY_ON, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
                    _ = c.XSync(d, x11.False);
                    if (selmon) |sm| resizebarwin(sm);
                    updatesystray();
                    setclientstate(icon, x11.NormalState);
                }
                return;
            }
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
            if (client != sm.sel and !client.isurgent) seturgent(client, true);
        }
    }
}

/// Sends a synthetic ConfigureNotify event to a client, informing it of its
/// current geometry. Required by ICCCM after we change a window's size/position
/// so the client knows where it actually ended up (the WM may have adjusted
/// what the client requested).
fn configure(cl: *Client) void {
    const d = dpy orelse return;
    var ce: x11.XConfigureEvent = std.mem.zeroes(x11.XConfigureEvent);
    ce.type = x11.ConfigureNotify;
    ce.display = d;
    ce.event = cl.win;
    ce.window = cl.win;
    ce.x = cl.x;
    ce.y = cl.y;
    ce.width = cl.w;
    ce.height = cl.h;
    ce.border_width = cl.border_width;
    ce.above = x11.None;
    ce.override_redirect = x11.False;
    _ = c.XSendEvent(d, cl.win, x11.False, x11.StructureNotifyMask, @ptrCast(&ce));
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
        if (updategeom() or dirty) {
            if (draw) |dr| dr.resize(@intCast(screen_width), @intCast(bar_height));
            updatebars();
            var m = mons;
            while (m) |mon| : (m = mon.next) {
                var cl_it = mon.clients;
                while (cl_it) |cl_c| : (cl_it = cl_c.next) {
                    if (cl_c.isfullscreen) resizeclient(cl_c, mon.monitor_x, mon.monitor_y, mon.monitor_w, mon.monitor_h);
                }
                resizebarwin(mon);
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
            const m = cl.mon orelse return;
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
                cl.x = m.monitor_x + @divTrunc(m.monitor_w, 2) - @divTrunc(WIDTH(cl), 2);
            if ((cl.y + cl.h) > m.monitor_y + m.monitor_h and cl.isfloating)
                cl.y = m.monitor_y + @divTrunc(m.monitor_h, 2) - @divTrunc(HEIGHT(cl), 2);
            if ((ev.value_mask & (x11.CWX | x11.CWY) != 0) and (ev.value_mask & (x11.CWWidth | x11.CWHeight) == 0))
                configure(cl);
            if (ISVISIBLE(cl))
                _ = c.XMoveResizeWindow(d, cl.win, cl.x, cl.y, @intCast(cl.w), @intCast(cl.h));
        } else {
            configure(cl);
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
/// Each monitor gets its own tagset, master_factor, layout pair, etc. —
/// this is what enables per-monitor configuration in multi-head setups.
fn createmon() ?*Monitor {
    const m = alloc.create(Monitor) catch return null;
    m.* = Monitor{};
    m.tagset = .{ 1, 1 };
    m.master_factor = config.master_factor;
    m.num_masters = config.num_masters;
    m.showbar = config.showbar;
    m.topbar = config.topbar;
    m.lt[0] = &config.layouts[0];
    m.lt[1] = &config.layouts[1 % config.layouts.len];
    const sym = std.mem.span(config.layouts[0].symbol);
    @memcpy(m.layout_symbol[0..sym.len], sym);
    return m;
}

/// Handles DestroyNotify — a window was destroyed by its owner. We unmanage
/// the client (or remove the systray icon) so the WM stops tracking it.
fn destroynotify(e: *x11.XEvent) void {
    const ev = &e.xdestroywindow;
    if (wintoclient(ev.window)) |cl| {
        unmanage(cl, true);
    } else if (wintosystrayicon(ev.window)) |icon| {
        removesystrayicon(icon);
        if (selmon) |sm| resizebarwin(sm);
        updatesystray();
    }
}

/// Removes a client from its monitor's tiling-order client list.
/// Used before re-attaching to a different position, or before destroying the client.
fn detach(cl: *Client) void {
    const m = cl.mon orelse return;
    var tc: *?*Client = &m.clients;
    while (tc.* != null) {
        if (tc.* == cl) {
            tc.* = cl.next;
            return;
        }
        tc = &tc.*.?.next;
    }
}

/// Removes a client from its monitor's focus-order stack. If the removed client
/// was the selected one, picks the next visible client in focus order as the
/// new selection — this is how focus "falls through" when a window is closed.
fn detachstack(cl: *Client) void {
    const m = cl.mon orelse return;
    var tc: *?*Client = &m.stack;
    while (tc.* != null) {
        if (tc.* == cl) {
            tc.* = cl.snext;
            break;
        }
        tc = &tc.*.?.snext;
    }

    if (cl == m.sel) {
        var t = m.stack;
        while (t) |tt| : (t = tt.snext) {
            if (ISVISIBLE(tt)) break;
        }
        m.sel = t;
    }
}

/// Returns the next or previous monitor relative to selmon, wrapping around.
/// Used by focusmon/tagmon keybindings to cycle through monitors.
fn dirtomon(dir: c_int) ?*Monitor {
    const sm = selmon orelse return null;
    if (dir > 0) {
        return sm.next orelse mons;
    } else {
        if (sm == mons) {
            var m = mons;
            while (m) |mm| {
                if (mm.next == null) return mm;
                m = mm.next;
            }
            return null;
        } else {
            var m = mons;
            while (m) |mm| : (m = mm.next) {
                if (mm.next == sm) return mm;
            }
            return null;
        }
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
    if (config.showsystray and systraytomon(m) == m and !config.systrayonleft)
        stw = getsystraywidth();

    // draw status first
    var tw: c_int = 0;
    if (selmon == m) {
        d.setScheme(s[SchemeNorm]);
        tw = TEXTW(&status_text) - @divTrunc(text_lr_pad, 2) + 2;
        _ = d.text(m.window_w - tw - @as(c_int, @intCast(stw)), 0, @intCast(tw), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2) - 2), &status_text, false);
    }

    resizebarwin(m);

    var occ: c_uint = 0;
    var urg: c_uint = 0;
    var cl_it = m.clients;
    while (cl_it) |cl_c| : (cl_it = cl_c.next) {
        occ |= cl_c.tags;
        if (cl_c.isurgent) urg |= cl_c.tags;
    }

    var x: c_int = 0;
    const boxs = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 9);
    const boxw = @divTrunc(@as(c_int, @intCast(d.fonts.?.h)), 6) + 2;

    for (0..config.tags.len) |i| {
        const w = TEXTW(config.tags[i]);
        d.setScheme(if (m.tagset[m.selected_tags] & (@as(c_uint, 1) << @intCast(i)) != 0) s[SchemeSel] else s[SchemeNorm]);
        _ = d.text(x, 0, @intCast(w), @intCast(bar_height), @intCast(@divTrunc(text_lr_pad, 2)), config.tags[i], urg & (@as(c_uint, 1) << @intCast(i)) != 0);
        if (occ & (@as(c_uint, 1) << @intCast(i)) != 0) {
            d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), m == selmon and m.sel != null and (m.sel.?.tags & (@as(c_uint, 1) << @intCast(i))) != 0, urg & (@as(c_uint, 1) << @intCast(i)) != 0);
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
    const m = if (cl) |c_cl| c_cl.mon else wintomon(ev.window);
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
        if (wintomon(ev.window)) |m| {
            drawbar(m);
            if (m == selmon) updatesystray();
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
    if (c_focus == null or !ISVISIBLE(c_focus.?)) {
        const sm = selmon orelse return;
        c_focus = sm.stack;
        while (c_focus) |cf| {
            if (ISVISIBLE(cf)) break;
            c_focus = cf.snext;
        }
    }
    if (selmon) |sm| {
        if (sm.sel != null and sm.sel != c_focus) unfocus(sm.sel.?, false);
    }
    if (c_focus) |cf| {
        if (cf.mon != selmon) selmon = cf.mon;
        if (cf.isurgent) seturgent(cf, false);
        detachstack(cf);
        attachstack(cf);
        grabbuttons(cf, true);
        _ = c.XSetWindowBorder(d, cf.win, s[SchemeSel][drw.ColBorder].pixel);
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
            if (ev.window != sel.win) setfocus(sel);
        }
    }
}

/// Keybinding action: switches focus to the next/previous monitor.
/// Unfocuses the current selection first so the border color updates correctly.
pub fn focusmon(arg: *const config.Arg) void {
    if (mons == null or mons.?.next == null) return;
    const m = dirtomon(arg.i) orelse return;
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
            if (ISVISIBLE(f)) break;
            found = f.next;
        }
        if (found == null) {
            found = sm.clients;
            while (found) |f| {
                if (ISVISIBLE(f)) break;
                found = f.next;
            }
        }
    } else {
        var i = sm.clients;
        while (i != null and i != sm.sel) {
            if (ISVISIBLE(i.?)) found = i;
            i = i.?.next;
        }
        if (found == null) {
            while (i != null) {
                if (ISVISIBLE(i.?)) found = i;
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
fn getatomprop(cl: *Client, prop: x11.Atom) x11.Atom {
    const d = dpy orelse return x11.None;
    var di: c_int = undefined;
    var dl: c_ulong = undefined;
    var dl2: c_ulong = undefined;
    var p: ?[*]u8 = null;
    var da: x11.Atom = undefined;
    var atom: x11.Atom = x11.None;

    var req: x11.Atom = x11.XA_ATOM;
    if (prop == xatom[XembedInfo]) req = xatom[XembedInfo];

    if (c.XGetWindowProperty(d, cl.win, prop, 0, @sizeOf(x11.Atom), x11.False, req, &da, &di, &dl, &dl2, @ptrCast(&p)) == x11.Success and p != null) {
        atom = @as(*x11.Atom, @ptrCast(@alignCast(p.?))).*;
        if (da == xatom[XembedInfo] and dl == 2) atom = @as([*]x11.Atom, @ptrCast(@alignCast(p.?)))[1];
        _ = c.XFree(p);
    }
    return atom;
}

/// Queries the current pointer position relative to the root window.
/// Used by movemouse/resizemouse to get the starting cursor position, and
/// by motionnotify/wintomon to determine which monitor the cursor is on.
fn getrootptr(x: *c_int, y: *c_int) bool {
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

/// Calculates the total pixel width of all system tray icons plus spacing.
/// The bar layout subtracts this from the available width so the status text
/// and tray don't overlap. Returns 1 (not 0) when empty so the tray window
/// always has a minimum size and stays mapped.
fn getsystraywidth() c_uint {
    var w: c_uint = 0;
    if (config.showsystray) {
        if (systray_ptr) |st| {
            var i = st.icons;
            while (i) |icon| : (i = icon.next) {
                w += @intCast(icon.w);
                w += config.systrayspacing;
            }
        }
    }
    return if (w != 0) w + config.systrayspacing else 1;
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
    _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, cl.win);
    if (!focused) {
        _ = c.XGrabButton(d, x11.AnyButton, x11.AnyModifier, cl.win, x11.False, @intCast(BUTTONMASK()), x11.GrabModeSync, x11.GrabModeSync, x11.None, x11.None);
    }
    for (&config.buttons) |*btn| {
        if (btn.click == config.ClkClientWin) {
            for (modifiers) |mod| {
                _ = c.XGrabButton(d, @intCast(btn.button), btn.mask | mod, cl.win, x11.False, @intCast(BUTTONMASK()), x11.GrabModeAsync, x11.GrabModeSync, x11.None, x11.None);
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

/// Keybinding action: adjusts the number of windows in the master area.
/// More masters means the layout splits the master column among more windows;
/// fewer means the stack area gets more. Clamped to >= 0.
pub fn incnmaster(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    sm.num_masters = @max(sm.num_masters + arg.i, 0);
    arrange(sm);
}

/// Deduplicates Xinerama screen geometries. Some configurations report the
/// same physical screen multiple times (e.g. mirrored displays); we only
/// want to create one Monitor per unique geometry.
fn isuniquegeom(unique: [*]x11.XineramaScreenInfo, n: usize, info: *allowzero x11.XineramaScreenInfo) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (unique[i].x_org == info.x_org and unique[i].y_org == info.y_org and
            unique[i].width == info.width and unique[i].height == info.height)
            return false;
    }
    return true;
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

    if (!sendevent(sel.win, wmatom[WMDelete], x11.NoEventMask, @intCast(wmatom[WMDelete]), x11.CurrentTime, 0, 0, 0)) {
        _ = c.XGrabServer(d);
        _ = c.XSetErrorHandler(&xerrordummy);
        _ = c.XSetCloseDownMode(d, x11.DestroyAll);
        _ = c.XKillClient(d, sel.win);
        _ = c.XSync(d, x11.False);
        _ = c.XSetErrorHandler(&xerror);
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
    cl.win = w;
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
            cl.mon = t.mon;
            cl.tags = t.tags;
        } else {
            cl.mon = selmon;
            applyrules(cl);
        }
    } else {
        cl.mon = selmon;
        applyrules(cl);
    }

    const m = cl.mon orelse {
        alloc.destroy(cl);
        return;
    };
    if (cl.x + WIDTH(cl) > m.monitor_x + m.monitor_w) cl.x = m.monitor_x + m.monitor_w - WIDTH(cl);
    if (cl.y + HEIGHT(cl) > m.monitor_y + m.monitor_h) cl.y = m.monitor_y + m.monitor_h - HEIGHT(cl);
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
    configure(cl);
    updatewindowtype(cl);
    updatesizehints(cl);
    updatewmhints(cl);
    _ = c.XSelectInput(d, w, x11.EnterWindowMask | x11.FocusChangeMask | x11.PropertyChangeMask | x11.StructureNotifyMask);
    grabbuttons(cl, false);
    if (!cl.isfloating) {
        cl.isfloating = (trans != x11.None or cl.isfixed);
        cl.was_floating = cl.isfloating;
    }
    if (cl.isfloating) _ = c.XRaiseWindow(d, cl.win);
    attach(cl);
    attachstack(cl);
    _ = c.XChangeProperty(d, root, netatom[NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl.win), 1);
    _ = c.XMoveResizeWindow(d, cl.win, cl.x + 2 * screen_width, cl.y, @intCast(cl.w), @intCast(cl.h));
    setclientstate(cl, x11.NormalState);
    if (cl.mon == selmon) {
        if (selmon) |sm| unfocus(sm.sel, false);
    }
    m.sel = cl;
    arrange(m);
    _ = c.XMapWindow(d, cl.win);
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

    if (wintosystrayicon(ev.window)) |icon| {
        if (systray_ptr) |st| {
            _ = sendevent(icon.win, netatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, XEMBED_WINDOW_ACTIVATE, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
        }
        if (selmon) |sm| resizebarwin(sm);
        updatesystray();
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
        if (ISVISIBLE(cl_c)) n += 1;
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
    const m = recttomon(ev.x_root, ev.y_root, 1, 1);
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
                } else if (@abs((sm.window_x + sm.window_w) - (nx + WIDTH(cl))) < config.snap) {
                    nx = sm.window_x + sm.window_w - WIDTH(cl);
                }
                if (@abs(sm.window_y - ny) < config.snap) {
                    ny = sm.window_y;
                } else if (@abs((sm.window_y + sm.window_h) - (ny + HEIGHT(cl))) < config.snap) {
                    ny = sm.window_y + sm.window_h - HEIGHT(cl);
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
    if (recttomon(cl.x, cl.y, cl.w, cl.h)) |m| {
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
        if (!cc.isfloating and ISVISIBLE(cc)) return cc;
    }
    return null;
}

/// Moves a client to the head of the client list (making it the new master
/// in tiled layout), focuses it, and re-arranges. Used by zoom() to promote
/// a window to the master area.
fn pop(cl: *Client) void {
    detach(cl);
    attach(cl);
    focus(cl);
    arrange(cl.mon);
}

/// Handles PropertyNotify events — a window property changed. This is how we
/// stay in sync with clients: we update the status text when the root window
/// name changes (set by xsetroot/slstatus), re-read titles on WM_NAME changes,
/// update floating state on WM_TRANSIENT_FOR changes, refresh size hints, and
/// handle urgency flags from WM_HINTS. Also handles systray icon property changes.
fn propertynotify(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xproperty;

    if (wintosystrayicon(ev.window)) |icon| {
        if (ev.atom == x11.XA_WM_NORMAL_HINTS) {
            updatesizehints(icon);
            updatesystrayicongeom(icon, icon.w, icon.h);
        } else {
            updatesystrayiconstate(icon, ev);
        }
        if (selmon) |sm| resizebarwin(sm);
        updatesystray();
    }

    if (ev.window == root and ev.atom == x11.XA_WM_NAME) {
        updatestatus();
    } else if (ev.state == x11.PropertyDelete) {
        return;
    } else if (wintoclient(ev.window)) |cl| {
        switch (ev.atom) {
            x11.XA_WM_TRANSIENT_FOR => {
                var trans: x11.Window = undefined;
                if (!cl.isfloating and c.XGetTransientForHint(d, cl.win, &trans) != 0) {
                    cl.isfloating = wintoclient(trans) != null;
                    if (cl.isfloating) arrange(cl.mon);
                }
            },
            x11.XA_WM_NORMAL_HINTS => updatesizehints(cl),
            x11.XA_WM_HINTS => {
                updatewmhints(cl);
                drawbars();
            },
            else => {},
        }
        if (ev.atom == x11.XA_WM_NAME or ev.atom == netatom[NetWMName]) {
            updatetitle(cl);
            if (cl.mon) |mon| {
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

/// Finds which monitor a rectangle overlaps with the most. Used after mouse
/// operations to determine which monitor a moved/resized window belongs to,
/// and to figure out which monitor the root window cursor is on.
fn recttomon(x: c_int, y: c_int, w: c_int, h: c_int) ?*Monitor {
    var r = selmon;
    var area: c_int = 0;
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        const a = INTERSECT(x, y, w, h, mon);
        if (a > area) {
            area = a;
            r = mon;
        }
    }
    return r;
}

/// Unlinks a systray icon from the icon list and frees its Client struct.
/// Called when a tray applet's window is destroyed or unmapped.
fn removesystrayicon(i: ?*Client) void {
    const icon = i orelse return;
    if (!config.showsystray) return;
    const st = systray_ptr orelse return;
    var ii: *?*Client = &st.icons;
    while (ii.* != null) {
        if (ii.* == icon) {
            ii.* = icon.next;
            break;
        }
        ii = &ii.*.?.next;
    }
    alloc.destroy(icon);
}

/// High-level resize: applies size hints to the requested geometry, then calls
/// resizeclient only if the geometry actually changed. This avoids unnecessary
/// X server round-trips when the layout re-arranges but nothing actually moved.
fn resize(cl: *Client, x: c_int, y: c_int, w: c_int, h: c_int, interact: bool) void {
    var xv = x;
    var yv = y;
    var wv = w;
    var hv = h;
    if (applysizehints(cl, &xv, &yv, &wv, &hv, interact)) resizeclient(cl, xv, yv, wv, hv);
}

/// Adjusts the bar window's width to account for the system tray, then
/// repositions it. Called whenever the tray width changes or the bar is toggled.
fn resizebarwin(m: *Monitor) void {
    const d = dpy orelse return;
    var w: c_uint = @intCast(m.window_w);
    if (config.showsystray and systraytomon(m) == m and !config.systrayonleft)
        w -= getsystraywidth();
    _ = c.XMoveResizeWindow(d, m.barwin, m.window_x, m.bar_y, w, @intCast(bar_height));
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
    _ = c.XConfigureWindow(d, cl.win, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWBorderWidth, &wc);
    configure(cl);
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
    _ = c.XWarpPointer(d, x11.None, cl.win, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
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
                if (cl.mon.?.window_x + nw >= sm.window_x and cl.mon.?.window_x + nw <= sm.window_x + sm.window_w and
                    cl.mon.?.window_y + nh >= sm.window_y and cl.mon.?.window_y + nh <= sm.window_y + sm.window_h)
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
    _ = c.XWarpPointer(d, x11.None, cl.win, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
    _ = c.XUngrabPointer(d, x11.CurrentTime);
    while (c.XCheckMaskEvent(d, x11.EnterWindowMask, &ev) != 0) {}
    if (recttomon(cl.x, cl.y, cl.w, cl.h)) |m| {
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
    if (wintosystrayicon(ev.window)) |icon| {
        updatesystrayicongeom(icon, ev.width, ev.height);
        if (selmon) |sm| resizebarwin(sm);
        updatesystray();
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
        _ = c.XRaiseWindow(d, sel.win);
    if (m.lt[m.selected_layout].arrange != null) {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.stack_mode = x11.Below;
        wc.sibling = m.barwin;
        var cl_it = m.stack;
        while (cl_it) |cl_c| : (cl_it = cl_c.snext) {
            if (!cl_c.isfloating and ISVISIBLE(cl_c)) {
                _ = c.XConfigureWindow(d, cl_c.win, x11.CWSibling | x11.CWStackMode, &wc);
                wc.sibling = cl_c.win;
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
/// client's tags to match the destination monitor's active tagset so it becomes
/// immediately visible there. Re-arranges both monitors.
fn sendmon(cl: *Client, m: *Monitor) void {
    if (cl.mon == m) return;
    unfocus(cl, true);
    detach(cl);
    detachstack(cl);
    cl.mon = m;
    cl.tags = m.tagset[m.selected_tags];
    attach(cl);
    attachstack(cl);
    focus(null);
    arrange(null);
}

/// Sets the WM_STATE property on a client window (NormalState, IconicState, or
/// WithdrawnState). Required by ICCCM so pagers and session managers can query
/// window state.
fn setclientstate(cl: *Client, state: c_long) void {
    const d = dpy orelse return;
    const data = [2]c_long{ state, x11.None };
    _ = c.XChangeProperty(d, cl.win, wmatom[WMState], wmatom[WMState], 32, x11.PropModeReplace, @ptrCast(&data), 2);
}

/// Sends a ClientMessage event to a window. For WM protocol messages (WMDelete,
/// WMTakeFocus) it first checks if the client actually advertises support for
/// that protocol — returns false if not, so the caller can fall back to a
/// forceful action. For XEMBED messages, it sends unconditionally.
fn sendevent(w: x11.Window, proto: x11.Atom, mask: c_int, d0: c_long, d1: c_long, d2: c_long, d3: c_long, d4: c_long) bool {
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
        _ = c.XSetInputFocus(d, cl.win, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XChangeProperty(d, root, netatom[NetActiveWindow], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&cl.win), 1);
    }
    _ = sendevent(cl.win, wmatom[WMTakeFocus], x11.NoEventMask, @intCast(wmatom[WMTakeFocus]), x11.CurrentTime, 0, 0, 0);
}

/// Toggles a client in/out of fullscreen mode. Going fullscreen saves the old
/// geometry and border, removes the border, sets floating, and resizes to cover
/// the entire monitor. Leaving fullscreen restores everything. Updates the
/// _NET_WM_STATE property so EWMH-aware tools know the state.
fn setfullscreen(cl: *Client, fullscreen: bool) void {
    const d = dpy orelse return;
    if (fullscreen and !cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.win, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&netatom[NetWMFullscreen]), 1);
        cl.isfullscreen = true;
        cl.was_floating = cl.isfloating;
        cl.old_border_width = cl.border_width;
        cl.border_width = 0;
        cl.isfloating = true;
        if (cl.mon) |m| resizeclient(cl, m.monitor_x, m.monitor_y, m.monitor_w, m.monitor_h);
        _ = c.XRaiseWindow(d, cl.win);
    } else if (!fullscreen and cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.win, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, null, 0);
        cl.isfullscreen = false;
        cl.isfloating = cl.was_floating;
        cl.border_width = cl.old_border_width;
        cl.x = cl.oldx;
        cl.y = cl.oldy;
        cl.w = cl.oldw;
        cl.h = cl.oldh;
        resizeclient(cl, cl.x, cl.y, cl.w, cl.h);
        arrange(cl.mon);
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
    _ = updategeom();

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
    updatesystray();
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

/// Sets or clears the urgency flag on a client and updates the X11 WM_HINTS
/// accordingly. Urgent windows get highlighted in the bar's tag indicators
/// so the user notices they need attention.
fn seturgent(cl: *Client, urg: bool) void {
    const d = dpy orelse return;
    cl.isurgent = urg;
    const wmh = c.XGetWMHints(d, cl.win) orelse return;
    if (urg) {
        wmh.*.flags |= x11.XUrgencyHint;
    } else {
        wmh.*.flags &= ~@as(c_long, x11.XUrgencyHint);
    }
    _ = c.XSetWMHints(d, cl.win, wmh);
    _ = c.XFree(wmh);
}

/// Recursively shows visible clients and hides invisible ones by walking the
/// focus stack. Visible clients are moved to their actual position; invisible
/// ones are moved off-screen (x = -2 * width). This is called before layout
/// arrange so that hidden windows don't interfere with tiling calculations.
/// Floating/non-fullscreen clients are also resized to enforce size hints.
fn showhide(cl: ?*Client) void {
    const d = dpy orelse return;
    const cl_c = cl orelse return;
    if (ISVISIBLE(cl_c)) {
        _ = c.XMoveWindow(d, cl_c.win, cl_c.x, cl_c.y);
        if ((cl_c.mon != null and cl_c.mon.?.lt[cl_c.mon.?.selected_layout].arrange == null or cl_c.isfloating) and !cl_c.isfullscreen)
            resize(cl_c, cl_c.x, cl_c.y, cl_c.w, cl_c.h, false);
        showhide(cl_c.snext);
    } else {
        showhide(cl_c.snext);
        _ = c.XMoveWindow(d, cl_c.win, WIDTH(cl_c) * -2, cl_c.y);
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

/// Keybinding action: moves the focused window to the tag(s) specified in arg.ui.
/// The window disappears from the current view if the target tag isn't visible.
pub fn tag(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    if (arg.ui & config.TAGMASK != 0) {
        sel.tags = arg.ui & config.TAGMASK;
        focus(null);
        arrange(sm);
    }
}

/// Keybinding action: sends the focused window to the next/previous monitor.
/// The window gets the destination monitor's active tags so it's visible there.
pub fn tagmon(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    _ = sel;
    if (mons == null or mons.?.next == null) return;
    if (dirtomon(arg.i)) |m| sendmon(sm.sel.?, m);
}

/// Master-stack tiling layout (the default "[]=" layout). Splits the monitor
/// into a left master area and right stack area based on master_factor. The
/// first num_masters clients fill the master area (split vertically); the
/// rest fill the stack area (also split vertically). This is dwm's signature
/// layout — efficient for coding with one main editor and several terminals.
pub fn tile(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) n += 1;
    if (n == 0) return;

    var mw: c_int = undefined;
    if (n > @as(c_uint, @intCast(m.num_masters))) {
        mw = if (m.num_masters != 0) @intFromFloat(@as(f32, @floatFromInt(m.window_w)) * m.master_factor) else 0;
    } else {
        mw = m.window_w;
    }

    var i: c_uint = 0;
    var my: c_int = 0;
    var ty: c_int = 0;
    cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) {
        if (i < @as(c_uint, @intCast(m.num_masters))) {
            const h = @divTrunc(m.window_h - my, @as(c_int, @intCast(@min(n, @as(c_uint, @intCast(m.num_masters))) - i)));
            resize(cl_c, m.window_x, m.window_y + my, mw - (2 * cl_c.border_width), h - (2 * cl_c.border_width), false);
            if (my + HEIGHT(cl_c) < m.window_h) my += HEIGHT(cl_c);
        } else {
            const h = @divTrunc(m.window_h - ty, @as(c_int, @intCast(n - i)));
            resize(cl_c, m.window_x + mw, m.window_y + ty, m.window_w - mw - (2 * cl_c.border_width), h - (2 * cl_c.border_width), false);
            if (ty + HEIGHT(cl_c) < m.window_h) ty += HEIGHT(cl_c);
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
    updatebarpos(sm);
    resizebarwin(sm);
    if (config.showsystray) {
        if (systray_ptr) |st| {
            var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
            if (!sm.showbar) {
                wc.y = -bar_height;
            } else {
                wc.y = 0;
                if (!sm.topbar) wc.y = sm.monitor_h - bar_height;
            }
            _ = c.XConfigureWindow(d, st.win, x11.CWY, &wc);
        }
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
/// This adds or removes the window from a tag without affecting other tags —
/// useful for making a window appear on multiple tags simultaneously.
/// Refuses to remove the last tag (would make the window invisible).
pub fn toggletag(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    const newtags = sel.tags ^ (arg.ui & config.TAGMASK);
    if (newtags != 0) {
        sel.tags = newtags;
        focus(null);
        arrange(sm);
    }
}

/// Keybinding action: XORs the monitor's visible tagset with the given tag.
/// This adds or removes a tag from the view — useful for viewing windows
/// from multiple tags at once. Refuses to hide all tags (would show nothing).
pub fn toggleview(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const newtagset = sm.tagset[sm.selected_tags] ^ (arg.ui & config.TAGMASK);
    if (newtagset != 0) {
        sm.tagset[sm.selected_tags] = newtagset;
        focus(null);
        arrange(sm);
    }
}

/// Removes focus decorations from a client: resets the border color to normal
/// and re-grabs all buttons (so clicking it will re-focus). Optionally clears
/// X input focus to root. Called before focusing a different client.
fn unfocus(cl: ?*Client, set_focus: bool) void {
    const d = dpy orelse return;
    const s = scheme orelse return;
    const cl_c = cl orelse return;
    grabbuttons(cl_c, false);
    _ = c.XSetWindowBorder(d, cl_c.win, s[SchemeNorm][drw.ColBorder].pixel);
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
    const m = cl.mon;
    detach(cl);
    detachstack(cl);
    if (!destroyed) {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.border_width = cl.old_border_width;
        _ = c.XGrabServer(d);
        _ = c.XSetErrorHandler(&xerrordummy);
        _ = c.XConfigureWindow(d, cl.win, x11.CWBorderWidth, &wc);
        _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, cl.win);
        setclientstate(cl, x11.WithdrawnState);
        _ = c.XSync(d, x11.False);
        _ = c.XSetErrorHandler(&xerror);
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
            setclientstate(cl, x11.WithdrawnState);
        } else {
            unmanage(cl, false);
        }
    } else if (wintosystrayicon(ev.window)) |icon| {
        _ = c.XMapRaised(dpy.?, icon.win);
        updatesystray();
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
        if (config.showsystray and systraytomon(mon) == mon) w -= getsystraywidth();
        mon.barwin = c.XCreateWindow(d, root, mon.window_x, mon.bar_y, w, @intCast(bar_height), 0, @intCast(c.DefaultDepth(d, screen)), x11.CopyFromParent, c.DefaultVisual(d, screen), x11.CWOverrideRedirect | x11.CWBackPixmap | x11.CWEventMask, &wa);
        if (cursor[CurNormal]) |cur| _ = c.XDefineCursor(d, mon.barwin, cur.cursor);
        if (config.showsystray and systraytomon(mon) == mon) {
            if (systray_ptr) |st| _ = c.XMapRaised(d, st.win);
        }
        _ = c.XMapRaised(d, mon.barwin);
        _ = c.XSetClassHint(d, mon.barwin, &ch);
    }
}

/// Calculates the bar's Y position and adjusts the usable window area on a
/// monitor. When the bar is visible, it subtracts bar_height from the window
/// area (from top or bottom depending on topbar). When hidden, the bar is
/// placed off-screen at -bar_height.
fn updatebarpos(m: *Monitor) void {
    m.window_y = m.monitor_y;
    m.window_h = m.monitor_h;
    if (m.showbar) {
        m.window_h -= bar_height;
        m.bar_y = if (m.topbar) m.window_y else m.window_y + m.window_h;
        m.window_y = if (m.topbar) m.window_y + bar_height else m.window_y;
    } else {
        m.bar_y = -bar_height;
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
            _ = c.XChangeProperty(d, root, netatom[NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl_c.win), 1);
        }
    }
}

/// Queries Xinerama for the current screen layout and syncs the monitor list
/// to match. Creates new monitors for newly detected screens, updates geometry
/// for changed screens, and migrates clients from removed monitors to the
/// first monitor. Returns true if anything changed (triggers bar/focus updates).
fn updategeom() bool {
    const d = dpy orelse return false;
    var dirty: bool = false;

    if (c.XineramaIsActive(d) != 0) {
        var nn: c_int = undefined;
        const info = c.XineramaQueryScreens(d, &nn);
        var n: c_int = 0;
        {
            var m = mons;
            while (m) |mon| : (m = mon.next) n += 1;
        }

        const raw_ptr: ?[*]align(@alignOf(x11.XineramaScreenInfo)) u8 = @ptrCast(@alignCast(std.c.calloc(@intCast(nn), @sizeOf(x11.XineramaScreenInfo))));
        const unique_ptr: [*]x11.XineramaScreenInfo = @ptrCast(raw_ptr orelse return false);
        var j: usize = 0;
        var i: c_int = 0;
        while (i < nn) : (i += 1) {
            if (isuniquegeom(unique_ptr, j, &info[@intCast(i)])) {
                unique_ptr[j] = info[@intCast(i)];
                j += 1;
            }
        }
        _ = c.XFree(info);
        nn = @intCast(j);

        if (n <= nn) {
            // new monitors available
            i = 0;
            while (i < nn - n) : (i += 1) {
                var m = mons;
                while (m != null and m.?.next != null) m = m.?.next;
                if (m) |mm| {
                    mm.next = createmon();
                } else {
                    mons = createmon();
                }
            }
            i = 0;
            var m = mons;
            while (i < nn and m != null) : ({
                i += 1;
                m = m.?.next;
            }) {
                const mm = m.?;
                const ui: usize = @intCast(i);
                if (i >= n or unique_ptr[ui].x_org != @as(c_short, @intCast(mm.monitor_x)) or unique_ptr[ui].y_org != @as(c_short, @intCast(mm.monitor_y)) or
                    unique_ptr[ui].width != @as(c_short, @intCast(mm.monitor_w)) or unique_ptr[ui].height != @as(c_short, @intCast(mm.monitor_h)))
                {
                    dirty = true;
                    mm.num = i;
                    mm.monitor_x = unique_ptr[ui].x_org;
                    mm.window_x = mm.monitor_x;
                    mm.monitor_y = unique_ptr[ui].y_org;
                    mm.window_y = mm.monitor_y;
                    mm.monitor_w = unique_ptr[ui].width;
                    mm.window_w = mm.monitor_w;
                    mm.monitor_h = unique_ptr[ui].height;
                    mm.window_h = mm.monitor_h;
                    updatebarpos(mm);
                }
            }
        } else {
            // less monitors available
            i = nn;
            while (i < n) : (i += 1) {
                var m = mons;
                while (m != null and m.?.next != null) m = m.?.next;
                if (m) |mm| {
                    while (mm.clients) |cl_c| {
                        dirty = true;
                        mm.clients = cl_c.next;
                        detachstack(cl_c);
                        cl_c.mon = mons;
                        if (mons) |first| {
                            _ = first;
                            attach(cl_c);
                            attachstack(cl_c);
                        }
                    }
                    if (mm == selmon) selmon = mons;
                    cleanupmon(mm);
                }
            }
        }
        std.c.free(unique_ptr);
    } else {
        // default monitor setup
        if (mons == null) mons = createmon();
        if (mons) |m| {
            if (m.monitor_w != screen_width or m.monitor_h != screen_height) {
                dirty = true;
                m.monitor_w = screen_width;
                m.window_w = screen_width;
                m.monitor_h = screen_height;
                m.window_h = screen_height;
                updatebarpos(m);
            }
        }
    }
    if (dirty) {
        selmon = mons;
        selmon = wintomon(root);
    }
    return dirty;
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

/// Reads ICCCM size hints (WM_NORMAL_HINTS) from a client's window and stores
/// them in the Client struct. These hints define min/max size, aspect ratio,
/// resize increments, and base size — all used by applysizehints to constrain
/// geometry. Also computes isfixed (whether min == max, meaning the window
/// can't be resized).
fn updatesizehints(cl: *Client) void {
    const d = dpy orelse return;
    var msize: c_long = undefined;
    var size: x11.XSizeHints = std.mem.zeroes(x11.XSizeHints);
    if (c.XGetWMNormalHints(d, cl.win, &size, &msize) == 0) {
        size.flags = x11.PSize;
    }
    if (size.flags & x11.PBaseSize != 0) {
        cl.base_width = @intCast(size.base_width);
        cl.base_height = @intCast(size.base_height);
    } else if (size.flags & x11.PMinSize != 0) {
        cl.base_width = @intCast(size.min_width);
        cl.base_height = @intCast(size.min_height);
    } else {
        cl.base_width = 0;
        cl.base_height = 0;
    }
    if (size.flags & x11.PResizeInc != 0) {
        cl.inc_width = @intCast(size.width_inc);
        cl.inc_height = @intCast(size.height_inc);
    } else {
        cl.inc_width = 0;
        cl.inc_height = 0;
    }
    if (size.flags & x11.PMaxSize != 0) {
        cl.max_width = @intCast(size.max_width);
        cl.max_height = @intCast(size.max_height);
    } else {
        cl.max_width = 0;
        cl.max_height = 0;
    }
    if (size.flags & x11.PMinSize != 0) {
        cl.min_width = @intCast(size.min_width);
        cl.min_height = @intCast(size.min_height);
    } else if (size.flags & x11.PBaseSize != 0) {
        cl.min_width = @intCast(size.base_width);
        cl.min_height = @intCast(size.base_height);
    } else {
        cl.min_width = 0;
        cl.min_height = 0;
    }
    if (size.flags & x11.PAspect != 0) {
        cl.min_aspect = @as(f32, @floatFromInt(size.min_aspect.y)) / @as(f32, @floatFromInt(size.min_aspect.x));
        cl.max_aspect = @as(f32, @floatFromInt(size.max_aspect.x)) / @as(f32, @floatFromInt(size.max_aspect.y));
    } else {
        cl.min_aspect = 0.0;
        cl.max_aspect = 0.0;
    }
    cl.isfixed = (cl.max_width != 0 and cl.max_height != 0 and cl.max_width == cl.min_width and cl.max_height == cl.min_height);
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
    updatesystray();
}

/// Scales a systray icon to fit the bar height, preserving aspect ratio.
/// Icons that are square get bar_height x bar_height; non-square icons are
/// scaled proportionally. Ensures no icon exceeds the bar height.
fn updatesystrayicongeom(icon: *Client, w: c_int, h: c_int) void {
    icon.h = bar_height;
    if (w == h) {
        icon.w = bar_height;
    } else if (h == bar_height) {
        icon.w = w;
    } else {
        icon.w = @intFromFloat(@as(f32, @floatFromInt(bar_height)) * (@as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h))));
    }
    _ = applysizehints(icon, &icon.x, &icon.y, &icon.w, &icon.h, false);
    if (icon.h > bar_height) {
        if (icon.w == icon.h) {
            icon.w = bar_height;
        } else {
            icon.w = @intFromFloat(@as(f32, @floatFromInt(bar_height)) * (@as(f32, @floatFromInt(icon.w)) / @as(f32, @floatFromInt(icon.h))));
        }
        icon.h = bar_height;
    }
}

/// Reacts to XEMBED_INFO property changes on a systray icon. Maps or unmaps
/// the icon based on the XEMBED_MAPPED flag, and sends the appropriate
/// XEMBED activate/deactivate message so the icon knows its visibility state.
fn updatesystrayiconstate(icon: *Client, ev: *x11.XPropertyEvent) void {
    if (!config.showsystray or ev.atom != xatom[XembedInfo]) return;
    const flags = getatomprop(icon, xatom[XembedInfo]);
    if (flags == 0) return;

    var code: c_long = 0;
    if (flags & XEMBED_MAPPED != 0 and icon.tags == 0) {
        icon.tags = 1;
        code = XEMBED_WINDOW_ACTIVATE;
        _ = c.XMapRaised(dpy.?, icon.win);
        setclientstate(icon, x11.NormalState);
    } else if (flags & XEMBED_MAPPED == 0 and icon.tags != 0) {
        icon.tags = 0;
        code = XEMBED_WINDOW_DEACTIVATE;
        _ = c.XUnmapWindow(dpy.?, icon.win);
        setclientstate(icon, x11.WithdrawnState);
    } else {
        return;
    }
    if (systray_ptr) |st| {
        _ = sendevent(icon.win, xatom[XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, code, 0, @intCast(st.win), XEMBED_EMBEDDED_VERSION);
    }
}

/// Creates (if first call) or repositions/redraws the system tray window. On
/// first call, creates a simple window, claims the _NET_SYSTEM_TRAY_S0 selection,
/// and advertises itself as the tray manager. On subsequent calls, repositions
/// all embedded icons in a horizontal row, resizes the tray window to fit,
/// and stacks it above the bar. This is the systray patch's main rendering function.
fn updatesystray() void {
    const d = dpy orelse return;
    const s = scheme orelse return;
    if (!config.showsystray) return;

    const m = systraytomon(null) orelse return;
    var x_pos: c_int = m.monitor_x + m.monitor_w;
    const status_w = TEXTW(&status_text) - text_lr_pad + @as(c_int, @intCast(config.systrayspacing));
    var w: c_uint = 1;

    if (config.systrayonleft) x_pos -= status_w + @divTrunc(text_lr_pad, 2);

    if (systray_ptr == null) {
        // init systray
        const st = alloc.create(Systray) catch {
            die("fatal: could not allocate Systray");
            return;
        };
        st.* = Systray{};
        systray_ptr = st;
        st.win = c.XCreateSimpleWindow(d, root, x_pos, m.bar_y, w, @intCast(bar_height), 0, 0, s[SchemeSel][drw.ColBg].pixel);
        var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
        wa.event_mask = x11.ButtonPressMask | x11.ExposureMask;
        wa.override_redirect = x11.True;
        wa.background_pixel = s[SchemeNorm][drw.ColBg].pixel;
        _ = c.XSelectInput(d, st.win, x11.SubstructureNotifyMask);
        _ = c.XChangeProperty(d, st.win, netatom[NetSystemTrayOrientation], x11.XA_CARDINAL, 32, x11.PropModeReplace, @ptrCast(&netatom[NetSystemTrayOrientationHorz]), 1);
        _ = c.XChangeWindowAttributes(d, st.win, x11.CWEventMask | x11.CWOverrideRedirect | x11.CWBackPixel, &wa);
        _ = c.XMapRaised(d, st.win);
        _ = c.XSetSelectionOwner(d, netatom[NetSystemTray], st.win, x11.CurrentTime);
        if (c.XGetSelectionOwner(d, netatom[NetSystemTray]) == st.win) {
            _ = sendevent(root, xatom[XembedManager], x11.StructureNotifyMask, x11.CurrentTime, @intCast(netatom[NetSystemTray]), @intCast(st.win), 0, 0);
            _ = c.XSync(d, x11.False);
        } else {
            std.debug.print("dwm: unable to obtain system tray.\n", .{});
            alloc.destroy(st);
            systray_ptr = null;
            return;
        }
    }

    const st = systray_ptr orelse return;
    w = 0;
    var icon = st.icons;
    while (icon) |i| : (icon = i.next) {
        var wa: x11.XSetWindowAttributes = std.mem.zeroes(x11.XSetWindowAttributes);
        wa.background_pixel = s[SchemeNorm][drw.ColBg].pixel;
        _ = c.XChangeWindowAttributes(d, i.win, x11.CWBackPixel, &wa);
        _ = c.XMapRaised(d, i.win);
        w += config.systrayspacing;
        i.x = @intCast(w);
        _ = c.XMoveResizeWindow(d, i.win, i.x, 0, @intCast(i.w), @intCast(i.h));
        w += @intCast(i.w);
        if (i.mon != m) i.mon = m;
    }
    w = if (w != 0) w + config.systrayspacing else 1;
    x_pos -= @intCast(w);
    _ = c.XMoveResizeWindow(d, st.win, x_pos, m.bar_y, w, @intCast(bar_height));
    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.x = x_pos;
    wc.y = m.bar_y;
    wc.width = @intCast(w);
    wc.height = bar_height;
    wc.stack_mode = x11.Above;
    wc.sibling = m.barwin;
    _ = c.XConfigureWindow(d, st.win, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWSibling | x11.CWStackMode, &wc);
    _ = c.XMapWindow(d, st.win);
    _ = c.XMapSubwindows(d, st.win);
    if (draw) |dr| {
        _ = c.XSetForeground(d, dr.gc, s[SchemeNorm][drw.ColBg].pixel);
        _ = c.XFillRectangle(d, st.win, dr.gc, 0, 0, w, @intCast(bar_height));
    }
    _ = c.XSync(d, x11.False);
}

/// Reads the client's title from _NET_WM_NAME (UTF-8) or falls back to
/// WM_NAME (Latin-1). Sets a "broken" placeholder if both are empty.
fn updatetitle(cl: *Client) void {
    if (!gettextprop(cl.win, netatom[NetWMName], &cl.name)) {
        _ = gettextprop(cl.win, x11.XA_WM_NAME, &cl.name);
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
    const wmh = c.XGetWMHints(d, cl.win) orelse return;
    if (selmon) |sm| {
        if (cl == sm.sel and wmh.*.flags & x11.XUrgencyHint != 0) {
            wmh.*.flags &= ~@as(c_long, x11.XUrgencyHint);
            _ = c.XSetWMHints(d, cl.win, wmh);
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

/// Keybinding action: switches the monitor's view to show the tag(s) in arg.ui.
/// Uses the two-slot tagset toggle — swaps selected_tags index first, so the
/// previous view is remembered and can be toggled back to (like the "previous
/// channel" button on a TV remote). If arg.ui is 0, it just toggles back.
pub fn view(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if ((arg.ui & config.TAGMASK) == sm.tagset[sm.selected_tags]) return;
    sm.selected_tags ^= 1;
    if (arg.ui & config.TAGMASK != 0) sm.tagset[sm.selected_tags] = arg.ui & config.TAGMASK;
    focus(null);
    arrange(sm);
}

/// Looks up a Client by its X window ID across all monitors. Returns null if
/// the window isn't managed (e.g. it's a bar, root, or unmanaged window).
fn wintoclient(w: x11.Window) ?*Client {
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        var cl_it = mon.clients;
        while (cl_it) |cl_c| : (cl_it = cl_c.next) {
            if (cl_c.win == w) return cl_c;
        }
    }
    return null;
}

/// Looks up a systray icon Client by its X window ID. Returns null if the
/// window isn't a systray icon or if systray is disabled.
fn wintosystrayicon(w: x11.Window) ?*Client {
    if (!config.showsystray or w == 0) return null;
    const st = systray_ptr orelse return null;
    var i = st.icons;
    while (i) |icon| : (i = icon.next) {
        if (icon.win == w) return icon;
    }
    return null;
}

/// Determines which monitor a window belongs to: checks if it's the root
/// (uses pointer position), a bar window (returns that monitor), or a client
/// (returns client's monitor). Falls back to selmon for unknown windows.
fn wintomon(w: x11.Window) ?*Monitor {
    var x: c_int = 0;
    var y: c_int = 0;
    if (w == root and getrootptr(&x, &y)) return recttomon(x, y, 1, 1);
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        if (w == mon.barwin) return mon;
    }
    if (wintoclient(w)) |cl| return cl.mon;
    return selmon;
}

/// The main X error handler. Silences known-harmless errors that occur during
/// normal WM operation (e.g. BadWindow from race conditions where a client
/// destroys its window before we process a pending event, BadAccess from
/// grab conflicts). Fatal errors are logged and forwarded to the default handler.
fn xerror(_: ?*x11.Display, ee: ?*x11.XErrorEvent) callconv(.c) c_int {
    const ev = ee orelse return 0;
    if (ev.error_code == x11.BadWindow or
        (ev.request_code == x11.X_SetInputFocus and ev.error_code == x11.BadMatch) or
        (ev.request_code == x11.X_PolyText8 and ev.error_code == x11.BadDrawable) or
        (ev.request_code == x11.X_PolyFillRectangle and ev.error_code == x11.BadDrawable) or
        (ev.request_code == x11.X_PolySegment and ev.error_code == x11.BadDrawable) or
        (ev.request_code == x11.X_ConfigureWindow and ev.error_code == x11.BadMatch) or
        (ev.request_code == x11.X_GrabButton and ev.error_code == x11.BadAccess) or
        (ev.request_code == x11.X_GrabKey and ev.error_code == x11.BadAccess) or
        (ev.request_code == x11.X_CopyArea and ev.error_code == x11.BadDrawable))
        return 0;
    std.debug.print("dwm: fatal error: request code={d}, error code={d}\n", .{ ev.request_code, ev.error_code });
    if (xerrorxlib) |handler_fn| return handler_fn(dpy, ee);
    return 0;
}

/// No-op error handler used temporarily during operations that may trigger
/// X errors we want to ignore (e.g. restoring a dead client's border width
/// during unmanage).
fn xerrordummy(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    return 0;
}

/// Temporary error handler installed during checkotherwm(). If any X error
/// fires while we try to select SubstructureRedirect on root, it means
/// another WM is already running. We abort with a clear error message.
fn xerrorstart(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    die("dwm: another window manager is already running");
    return -1;
}

/// Determines which monitor should host the system tray based on config.
/// If systraypinning is 0, the tray follows the selected monitor. Otherwise
/// it's pinned to a specific monitor number (with a fallback-to-first option).
fn systraytomon(m: ?*Monitor) ?*Monitor {
    if (config.systraypinning == 0) {
        if (m == null) return selmon;
        return if (m == selmon) m else null;
    }
    var n: c_int = 1;
    var t = mons;
    while (t != null and t.?.next != null) : ({
        n += 1;
        t = t.?.next;
    }) {}
    t = mons;
    var i: c_uint = 1;
    while (t != null and t.?.next != null and i < config.systraypinning) : ({
        i += 1;
        t = t.?.next;
    }) {}
    if (config.systraypinningfailfirst and n < @as(c_int, @intCast(config.systraypinning))) return mons;
    return t;
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
fn die(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
