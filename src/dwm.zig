// dwm - dynamic window manager - Zig rewrite
// See LICENSE file for copyright and license details.
//
// Core orchestration module: global state, constants, atom/property helpers,
// setup/cleanup/scan lifecycle, and re-exports from submodules. Event handling
// lives in events.zig, focus management in focus.zig, client lifecycle in
// client.zig, layout in layout.zig, bar rendering in bar.zig, keybinding
// actions in actions.zig, monitor management in monitor.zig, system tray in
// systray.zig, and X error handling in xerror.zig.
const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const config = @import("config.zig");
const systray = @import("systray.zig");
const xerror = @import("xerror.zig");
const monitor = @import("monitor.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const actions = @import("actions.zig");
const client = @import("client.zig");
const focus_mod = @import("focus.zig");
const events = @import("events.zig");
const c = x11.c;

pub const VERSION = "6.3";

// --- Cursor indices into the global cursor array ---
pub const CurNormal = 0; // default pointer (arrow)
pub const CurResize = 1; // shown while resizing a window
pub const CurMove = 2; // shown while moving a window
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
pub const WMDelete = 1; // WM_DELETE_WINDOW — ask a client to close gracefully
pub const WMState = 2; // WM_STATE — track normal/iconic/withdrawn state
pub const WMTakeFocus = 3; // WM_TAKE_FOCUS — give keyboard focus to a client
const WMLast = 4;

pub const Client = client.Client;

pub const Monitor = monitor.Monitor;
pub const Layout = layout.Layout;

// --- Global state ---
// These mirror the globals from the original dwm.c. They are set once during
// setup() and then read/written throughout the event loop.
pub var screen: c_int = 0; // default X screen number
pub var screen_width: c_int = 0; // total screen width in pixels
pub var screen_height: c_int = 0; // total screen height in pixels
pub var numlockmask: c_uint = 0; // dynamically determined NumLock modifier mask
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
pub fn BUTTONMASK() c_long {
    return x11.ButtonPressMask | x11.ButtonReleaseMask;
}

/// Event mask for grabbing mouse motion (used during move/resize drag operations).
pub fn MOUSEMASK() c_long {
    return BUTTONMASK() | x11.PointerMotionMask;
}

// --- Event dispatch (re-exported from events.zig) ---
pub var handler = &events.handler;
pub const run = events.run;
pub const grabkeys = events.grabkeys;

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
    actions.view(&a);
    if (selmon) |sm| sm.layout = &layout.Layout{ .symbol = "", .arrange = null };
    var m = mons;
    while (m) |mon| : (m = mon.next) {
        while (mon.stack) |s| s.unmanage(false);
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

pub const focus = focus_mod.focus;

pub const focusin = focus_mod.focusin;

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
pub fn gettextprop(w: x11.Window, atom: x11.Atom, text_buf: []u8) bool {
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

pub const grabbuttons = focus_mod.grabbuttons;

/// Moves a client to the head of the client list (making it the new master
/// in tiled layout), focuses it, and re-arranges. Used by zoom() to promote
/// a window to the master area.
pub fn pop(cl: *Client) void {
    cl.detach();
    cl.attach();
    focus(cl);
    layout.arrange(cl.monitor);
}

/// Fixes the X window stacking order after focus or layout changes. Floating
/// and focused windows are raised above tiled ones; tiled windows are stacked
/// below the bar window in focus order. Also drains any pending EnterNotify
/// events to prevent spurious focus changes from the restacking itself.
pub fn restack(m: *Monitor) void {
    const d = dpy orelse return;
    bar.drawbar(m);
    const sel = m.sel orelse return;
    if (sel.isfloating or m.layout.arrange == null)
        _ = c.XRaiseWindow(d, sel.window);
    if (m.layout.arrange != null) {
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
                    client.manage(w[i], &wa);
            }
            // now the transients
            i = 0;
            while (i < num) : (i += 1) {
                var wa: x11.XWindowAttributes = undefined;
                if (c.XGetWindowAttributes(d, w[i], &wa) == 0) continue;
                if (c.XGetTransientForHint(d, w[i], &d1) != 0 and
                    (wa.map_state == x11.IsViewable or getstate(w[i]) == x11.IconicState))
                    client.manage(w[i], &wa);
            }
            _ = c.XFree(wins);
        }
    }
}

/// Transfers a client from its current monitor to a different one. Updates the
/// client's tags to match the destination monitor's active tags so it becomes
/// immediately visible there. Re-arranges both monitors.
pub fn sendmon(cl: *Client, m: *Monitor) void {
    if (cl.monitor == m) return;
    unfocus(cl, true);
    cl.detach();
    cl.detachStack();
    cl.monitor = m;
    cl.tag = m.tag;
    cl.attach();
    cl.attachStack();
    focus(null);
    layout.arrange(null);
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
    bar.text_lr_pad = @intCast(dr.fonts.?.h);
    bar.bar_height = @as(c_int, @intCast(dr.fonts.?.h)) + 2;
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
    bar.updateBars();
    bar.updateStatus();

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

pub const unfocus = focus_mod.unfocus;

/// Discovers which modifier bit corresponds to Num Lock by scanning the
/// modifier map for XK_Num_Lock. This varies by system, so we re-detect
/// it before grabbing keys/buttons to ensure our modifier masks are correct.
pub fn updatenumlockmask() void {
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

pub const wintoclient = client.fromWindow;

/// Prints an error message and exits immediately. Used for unrecoverable
/// errors like allocation failures or detecting another WM is running.
pub fn die(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
