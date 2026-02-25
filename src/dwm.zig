// dwm - dynamic window manager - Zig rewrite
// See LICENSE file for copyright and license details.
const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const config = @import("config.zig");
const c = x11.c;

const VERSION = "6.3";

// XEMBED constants
const SYSTEM_TRAY_REQUEST_DOCK = 0;
const XEMBED_EMBEDDED_NOTIFY = 0;
const XEMBED_WINDOW_ACTIVATE = 1;
const XEMBED_WINDOW_DEACTIVATE = 2;
const XEMBED_FOCUS_IN = 4;
const XEMBED_MODALITY_ON = 10;
const XEMBED_MAPPED = (1 << 0);
const XEMBED_EMBEDDED_VERSION = 0;

// Enums
const CurNormal = 0;
const CurResize = 1;
const CurMove = 2;
const CurLast = 3;

pub const SchemeNorm = 0;
pub const SchemeSel = 1;

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

const XembedManager = 0;
const XembedAtom = 1;
const XembedInfo = 2;
const XLast = 3;

const WMProtocols = 0;
const WMDelete = 1;
const WMState = 2;
const WMTakeFocus = 3;
const WMLast = 4;

// Client structure
pub const Client = struct {
    name: [256:0]u8 = [_:0]u8{0} ** 256,
    mina: f32 = 0,
    maxa: f32 = 0,
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,
    oldx: c_int = 0,
    oldy: c_int = 0,
    oldw: c_int = 0,
    oldh: c_int = 0,
    basew: c_int = 0,
    baseh: c_int = 0,
    incw: c_int = 0,
    inch: c_int = 0,
    maxw: c_int = 0,
    maxh: c_int = 0,
    minw: c_int = 0,
    minh: c_int = 0,
    bw: c_int = 0,
    oldbw: c_int = 0,
    tags: c_uint = 0,
    isfixed: bool = false,
    isfloating: bool = false,
    isurgent: bool = false,
    neverfocus: bool = false,
    oldstate: bool = false,
    isfullscreen: bool = false,
    next: ?*Client = null,
    snext: ?*Client = null,
    mon: ?*Monitor = null,
    win: x11.Window = 0,
};

// Monitor structure
pub const Monitor = struct {
    ltsymbol: [16:0]u8 = [_:0]u8{0} ** 16,
    mfact: f32 = 0,
    nmaster: c_int = 0,
    num: c_int = 0,
    by: c_int = 0,
    mx: c_int = 0,
    my: c_int = 0,
    mw: c_int = 0,
    mh: c_int = 0,
    wx: c_int = 0,
    wy: c_int = 0,
    ww: c_int = 0,
    wh: c_int = 0,
    seltags: c_uint = 0,
    sellt: c_uint = 0,
    tagset: [2]c_uint = .{ 1, 1 },
    showbar: bool = true,
    topbar: bool = true,
    clients: ?*Client = null,
    sel: ?*Client = null,
    stack: ?*Client = null,
    next: ?*Monitor = null,
    barwin: x11.Window = 0,
    lt: [2]*const config.Layout = undefined,
};

// Systray
const Systray = struct {
    win: x11.Window = 0,
    icons: ?*Client = null,
};

// Global state
var systray_ptr: ?*Systray = null;
const broken: [*:0]const u8 = "broken";
var stext: [256:0]u8 = [_:0]u8{0} ** 256;
var screen: c_int = 0;
var sw: c_int = 0;
var sh: c_int = 0;
var bh: c_int = 0;
var blw: c_int = 0;
var lrpad: c_int = 0;
var xerrorxlib: ?*const fn (?*x11.Display, ?*x11.XErrorEvent) callconv(.c) c_int = null;
var numlockmask: c_uint = 0;
var wmatom: [WMLast]x11.Atom = [_]x11.Atom{0} ** WMLast;
var netatom: [NetLast]x11.Atom = [_]x11.Atom{0} ** NetLast;
var xatom: [XLast]x11.Atom = [_]x11.Atom{0} ** XLast;
pub var running: bool = true;
var cursor: [CurLast]?*drw.Cur = [_]?*drw.Cur{null} ** CurLast;
var scheme: ?[][*]drw.Clr = null;
pub var dpy: ?*x11.Display = null;
var draw: ?*drw.Drw = null;
var mons: ?*Monitor = null;
pub var selmon: ?*Monitor = null;
var root: x11.Window = 0;
var wmcheckwin: x11.Window = 0;
pub var dmenumon_buf: [2:0]u8 = .{ '0', 0 };

const alloc = std.heap.c_allocator;

// Helper macros as functions
fn BUTTONMASK() c_long {
    return x11.ButtonPressMask | x11.ButtonReleaseMask;
}

fn CLEANMASK(mask: c_uint) c_uint {
    return mask & ~(numlockmask | x11.LockMask) &
        (x11.ShiftMask | x11.ControlMask | x11.Mod1Mask | x11.Mod2Mask | x11.Mod3Mask | x11.Mod4Mask | x11.Mod5Mask);
}

fn ISVISIBLE(cl: *Client) bool {
    const m = cl.mon orelse return false;
    return (cl.tags & m.tagset[m.seltags]) != 0;
}

fn MOUSEMASK() c_long {
    return BUTTONMASK() | x11.PointerMotionMask;
}

fn WIDTH(cl: *Client) c_int {
    return cl.w + 2 * cl.bw;
}

fn HEIGHT(cl: *Client) c_int {
    return cl.h + 2 * cl.bw;
}

fn TEXTW(x: [*:0]const u8) c_int {
    if (draw) |d| {
        return @as(c_int, @intCast(d.fontsetGetwidth(x))) + lrpad;
    }
    return 0;
}

fn INTERSECT(x: c_int, y: c_int, w: c_int, h: c_int, m: *Monitor) c_int {
    return @max(0, @min(x + w, m.wx + m.ww) - @max(x, m.wx)) *
        @max(0, @min(y + h, m.wy + m.wh) - @max(y, m.wy));
}

// Event handler dispatch table
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
    cl.tags = if (cl.tags & config.TAGMASK != 0) cl.tags & config.TAGMASK else m.tagset[m.seltags];
}

fn cstrstr(haystack: [*:0]const u8, needle: [*:0]const u8) bool {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return true;
    if (h.len < n.len) return false;
    return std.mem.indexOf(u8, h, n) != null;
}

fn applysizehints(cl: *Client, x: *c_int, y: *c_int, w: *c_int, h: *c_int, interact: bool) bool {
    const m = cl.mon orelse return false;

    // set minimum possible
    w.* = @max(1, w.*);
    h.* = @max(1, h.*);
    if (interact) {
        if (x.* > sw) x.* = sw - WIDTH(cl);
        if (y.* > sh) y.* = sh - HEIGHT(cl);
        if (x.* + w.* + 2 * cl.bw < 0) x.* = 0;
        if (y.* + h.* + 2 * cl.bw < 0) y.* = 0;
    } else {
        if (x.* >= m.wx + m.ww) x.* = m.wx + m.ww - WIDTH(cl);
        if (y.* >= m.wy + m.wh) y.* = m.wy + m.wh - HEIGHT(cl);
        if (x.* + w.* + 2 * cl.bw <= m.wx) x.* = m.wx;
        if (y.* + h.* + 2 * cl.bw <= m.wy) y.* = m.wy;
    }
    if (h.* < bh) h.* = bh;
    if (w.* < bh) w.* = bh;

    if (config.resizehints or cl.isfloating or (cl.mon != null and cl.mon.?.lt[cl.mon.?.sellt].arrange == null)) {
        // ICCCM 4.1.2.3
        const baseismin = cl.basew == cl.minw and cl.baseh == cl.minh;
        if (!baseismin) {
            w.* -= cl.basew;
            h.* -= cl.baseh;
        }
        // adjust for aspect limits
        if (cl.mina > 0 and cl.maxa > 0) {
            if (cl.maxa < @as(f32, @floatFromInt(w.*)) / @as(f32, @floatFromInt(h.*))) {
                w.* = @intFromFloat(@as(f32, @floatFromInt(h.*)) * cl.maxa + 0.5);
            } else if (cl.mina < @as(f32, @floatFromInt(h.*)) / @as(f32, @floatFromInt(w.*))) {
                h.* = @intFromFloat(@as(f32, @floatFromInt(w.*)) * cl.mina + 0.5);
            }
        }
        if (baseismin) {
            w.* -= cl.basew;
            h.* -= cl.baseh;
        }
        // adjust for increment value
        if (cl.incw != 0) w.* -= @mod(w.*, cl.incw);
        if (cl.inch != 0) h.* -= @mod(h.*, cl.inch);
        // restore base dimensions
        w.* = @max(w.* + cl.basew, cl.minw);
        h.* = @max(h.* + cl.baseh, cl.minh);
        if (cl.maxw != 0) w.* = @min(w.*, cl.maxw);
        if (cl.maxh != 0) h.* = @min(h.*, cl.maxh);
    }
    return x.* != cl.x or y.* != cl.y or w.* != cl.w or h.* != cl.h;
}

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

fn arrangemon(m: *Monitor) void {
    const sym = std.mem.span(m.lt[m.sellt].symbol);
    @memcpy(m.ltsymbol[0..sym.len], sym);
    if (sym.len < m.ltsymbol.len) m.ltsymbol[sym.len] = 0;
    if (m.lt[m.sellt].arrange) |arrange_fn| arrange_fn(m);
}

fn attach(cl: *Client) void {
    const m = cl.mon orelse return;
    cl.next = m.clients;
    m.clients = cl;
}

fn attachstack(cl: *Client) void {
    const m = cl.mon orelse return;
    cl.snext = m.stack;
    m.stack = cl;
}

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
        } else if (ev.x < x + blw) {
            click = config.ClkLtSymbol;
        } else if (ev.x > sm.ww - TEXTW(&stext) - @as(c_int, @intCast(getsystraywidth()))) {
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

pub fn checkotherwm() void {
    const d = dpy orelse return;
    xerrorxlib = c.XSetErrorHandler(&xerrorstart);
    _ = c.XSelectInput(d, c.DefaultRootWindow(d), x11.SubstructureRedirectMask);
    _ = c.XSync(d, x11.False);
    _ = c.XSetErrorHandler(&xerror);
    _ = c.XSync(d, x11.False);
}

pub fn cleanup() void {
    const d = dpy orelse return;
    const a = config.Arg{ .ui = @as(c_uint, @bitCast(@as(c_int, -1))) };
    view(&a);
    if (selmon) |sm| sm.lt[sm.sellt] = &config.Layout{ .symbol = "", .arrange = null };
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
                        wa.width = @intCast(bh);
                        wa.height = @intCast(bh);
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
                    icon.oldbw = wa.border_width;
                    icon.bw = 0;
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
    ce.border_width = cl.bw;
    ce.above = x11.None;
    ce.override_redirect = x11.False;
    _ = c.XSendEvent(d, cl.win, x11.False, x11.StructureNotifyMask, @ptrCast(&ce));
}

fn configurenotify(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xconfigure;
    if (ev.window == root) {
        const dirty = (sw != ev.width or sh != ev.height);
        sw = ev.width;
        sh = ev.height;
        if (updategeom() or dirty) {
            if (draw) |dr| dr.resize(@intCast(sw), @intCast(bh));
            updatebars();
            var m = mons;
            while (m) |mon| : (m = mon.next) {
                var cl_it = mon.clients;
                while (cl_it) |cl_c| : (cl_it = cl_c.next) {
                    if (cl_c.isfullscreen) resizeclient(cl_c, mon.mx, mon.my, mon.mw, mon.mh);
                }
                resizebarwin(mon);
            }
            focus(null);
            arrange(null);
        }
    }
    _ = d;
}

fn configurerequest(e: *x11.XEvent) void {
    const d = dpy orelse return;
    const ev = &e.xconfigurerequest;

    if (wintoclient(ev.window)) |cl| {
        if (ev.value_mask & x11.CWBorderWidth != 0) {
            cl.bw = ev.border_width;
        } else if (cl.isfloating or (selmon != null and selmon.?.lt[selmon.?.sellt].arrange == null)) {
            const m = cl.mon orelse return;
            if (ev.value_mask & x11.CWX != 0) {
                cl.oldx = cl.x;
                cl.x = m.mx + ev.x;
            }
            if (ev.value_mask & x11.CWY != 0) {
                cl.oldy = cl.y;
                cl.y = m.my + ev.y;
            }
            if (ev.value_mask & x11.CWWidth != 0) {
                cl.oldw = cl.w;
                cl.w = ev.width;
            }
            if (ev.value_mask & x11.CWHeight != 0) {
                cl.oldh = cl.h;
                cl.h = ev.height;
            }
            if ((cl.x + cl.w) > m.mx + m.mw and cl.isfloating)
                cl.x = m.mx + @divTrunc(m.mw, 2) - @divTrunc(WIDTH(cl), 2);
            if ((cl.y + cl.h) > m.my + m.mh and cl.isfloating)
                cl.y = m.my + @divTrunc(m.mh, 2) - @divTrunc(HEIGHT(cl), 2);
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

fn createmon() ?*Monitor {
    const m = alloc.create(Monitor) catch return null;
    m.* = Monitor{};
    m.tagset = .{ 1, 1 };
    m.mfact = config.mfact;
    m.nmaster = config.nmaster;
    m.showbar = config.showbar;
    m.topbar = config.topbar;
    m.lt[0] = &config.layouts[0];
    m.lt[1] = &config.layouts[1 % config.layouts.len];
    const sym = std.mem.span(config.layouts[0].symbol);
    @memcpy(m.ltsymbol[0..sym.len], sym);
    return m;
}

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
        tw = TEXTW(&stext) - @divTrunc(lrpad, 2) + 2;
        _ = d.text(m.ww - tw - @as(c_int, @intCast(stw)), 0, @intCast(tw), @intCast(bh), @intCast(@divTrunc(lrpad, 2) - 2), &stext, false);
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
        d.setScheme(if (m.tagset[m.seltags] & (@as(c_uint, 1) << @intCast(i)) != 0) s[SchemeSel] else s[SchemeNorm]);
        _ = d.text(x, 0, @intCast(w), @intCast(bh), @intCast(@divTrunc(lrpad, 2)), config.tags[i], urg & (@as(c_uint, 1) << @intCast(i)) != 0);
        if (occ & (@as(c_uint, 1) << @intCast(i)) != 0) {
            d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), m == selmon and m.sel != null and (m.sel.?.tags & (@as(c_uint, 1) << @intCast(i))) != 0, urg & (@as(c_uint, 1) << @intCast(i)) != 0);
        }
        x += w;
    }

    const ltw = TEXTW(&m.ltsymbol);
    blw = ltw;
    d.setScheme(s[SchemeNorm]);
    x = d.text(x, 0, @intCast(ltw), @intCast(bh), @intCast(@divTrunc(lrpad, 2)), &m.ltsymbol, false);

    const w_remaining = m.ww - tw - @as(c_int, @intCast(stw)) - x;
    if (w_remaining > bh) {
        if (m.sel) |sel_cl| {
            d.setScheme(if (m == selmon) s[SchemeSel] else s[SchemeNorm]);
            _ = d.text(x, 0, @intCast(w_remaining), @intCast(bh), @intCast(@divTrunc(lrpad, 2)), &sel_cl.name, false);
            if (sel_cl.isfloating) d.rect(x + boxs, boxs, @intCast(boxw), @intCast(boxw), sel_cl.isfixed, false);
        } else {
            d.setScheme(s[SchemeNorm]);
            d.rect(x, 0, @intCast(w_remaining), @intCast(bh), true, true);
        }
    }
    d.map(m.barwin, 0, 0, @intCast(m.ww - @as(c_int, @intCast(stw))), @intCast(bh));
}

fn drawbars() void {
    var m = mons;
    while (m) |mon| : (m = mon.next) drawbar(mon);
}

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

fn expose(e: *x11.XEvent) void {
    const ev = &e.xexpose;
    if (ev.count == 0) {
        if (wintomon(ev.window)) |m| {
            drawbar(m);
            if (m == selmon) updatesystray();
        }
    }
}

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

fn focusin(e: *x11.XEvent) void {
    const ev = &e.xfocus;
    if (selmon) |sm| {
        if (sm.sel) |sel| {
            if (ev.window != sel.win) setfocus(sel);
        }
    }
}

pub fn focusmon(arg: *const config.Arg) void {
    if (mons == null or mons.?.next == null) return;
    const m = dirtomon(arg.i) orelse return;
    if (m == selmon) return;
    if (selmon) |sm| unfocus(sm.sel, false);
    selmon = m;
    focus(null);
}

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

fn getrootptr(x: *c_int, y: *c_int) bool {
    const d = dpy orelse return false;
    var di: c_int = undefined;
    var dui: c_uint = undefined;
    var dummy: x11.Window = undefined;
    return c.XQueryPointer(d, root, &dummy, &dummy, x, y, &di, &di, &dui) != 0;
}

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

pub fn incnmaster(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    sm.nmaster = @max(sm.nmaster + arg.i, 0);
    arrange(sm);
}

fn isuniquegeom(unique: [*]x11.XineramaScreenInfo, n: usize, info: *allowzero x11.XineramaScreenInfo) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (unique[i].x_org == info.x_org and unique[i].y_org == info.y_org and
            unique[i].width == info.width and unique[i].height == info.height)
            return false;
    }
    return true;
}

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
    cl.oldbw = wa.border_width;

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
    if (cl.x + WIDTH(cl) > m.mx + m.mw) cl.x = m.mx + m.mw - WIDTH(cl);
    if (cl.y + HEIGHT(cl) > m.my + m.mh) cl.y = m.my + m.mh - HEIGHT(cl);
    cl.x = @max(cl.x, m.mx);
    if (m.by == m.my and cl.x + @divTrunc(cl.w, 2) >= m.wx and cl.x + @divTrunc(cl.w, 2) < m.wx + m.ww) {
        cl.y = @max(cl.y, bh);
    } else {
        cl.y = @max(cl.y, m.my);
    }
    cl.bw = @intCast(config.borderpx);

    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.border_width = cl.bw;
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
        cl.oldstate = cl.isfloating;
    }
    if (cl.isfloating) _ = c.XRaiseWindow(d, cl.win);
    attach(cl);
    attachstack(cl);
    _ = c.XChangeProperty(d, root, netatom[NetClientList], x11.XA_WINDOW, 32, x11.PropModeAppend, @ptrCast(&cl.win), 1);
    _ = c.XMoveResizeWindow(d, cl.win, cl.x + 2 * sw, cl.y, @intCast(cl.w), @intCast(cl.h));
    setclientstate(cl, x11.NormalState);
    if (cl.mon == selmon) {
        if (selmon) |sm| unfocus(sm.sel, false);
    }
    m.sel = cl;
    arrange(m);
    _ = c.XMapWindow(d, cl.win);
    focus(null);
}

fn mappingnotify(e: *x11.XEvent) void {
    var ev = &e.xmapping;
    _ = c.XRefreshKeyboardMapping(ev);
    if (ev.request == x11.MappingKeyboard) grabkeys();
}

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

pub fn monocle(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = m.clients;
    while (cl_it) |cl_c| : (cl_it = cl_c.next) {
        if (ISVISIBLE(cl_c)) n += 1;
    }
    if (n > 0) {
        _ = std.fmt.bufPrint(&m.ltsymbol, "[{d}]", .{n}) catch {};
    }
    var c_it = nexttiled(m.clients);
    while (c_it) |cl_c| : (c_it = nexttiled(cl_c.next)) {
        resize(cl_c, m.wx, m.wy, m.ww - 2 * cl_c.bw, m.wh - 2 * cl_c.bw, false);
    }
}

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
                if (@abs(sm.wx - nx) < config.snap) {
                    nx = sm.wx;
                } else if (@abs((sm.wx + sm.ww) - (nx + WIDTH(cl))) < config.snap) {
                    nx = sm.wx + sm.ww - WIDTH(cl);
                }
                if (@abs(sm.wy - ny) < config.snap) {
                    ny = sm.wy;
                } else if (@abs((sm.wy + sm.wh) - (ny + HEIGHT(cl))) < config.snap) {
                    ny = sm.wy + sm.wh - HEIGHT(cl);
                }
                if (!cl.isfloating and sm.lt[sm.sellt].arrange != null and
                    (@abs(nx - cl.x) > @as(c_int, config.snap) or @abs(ny - cl.y) > @as(c_int, config.snap)))
                {
                    togglefloating(&config.Arg{ .i = 0 });
                }
                if (sm.lt[sm.sellt].arrange == null or cl.isfloating)
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

fn nexttiled(cl: ?*Client) ?*Client {
    var c_it = cl;
    while (c_it) |cc| : (c_it = cc.next) {
        if (!cc.isfloating and ISVISIBLE(cc)) return cc;
    }
    return null;
}

fn pop(cl: *Client) void {
    detach(cl);
    attach(cl);
    focus(cl);
    arrange(cl.mon);
}

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

pub fn quit(_: *const config.Arg) void {
    running = false;
}

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

fn resize(cl: *Client, x: c_int, y: c_int, w: c_int, h: c_int, interact: bool) void {
    var xv = x;
    var yv = y;
    var wv = w;
    var hv = h;
    if (applysizehints(cl, &xv, &yv, &wv, &hv, interact)) resizeclient(cl, xv, yv, wv, hv);
}

fn resizebarwin(m: *Monitor) void {
    const d = dpy orelse return;
    var w: c_uint = @intCast(m.ww);
    if (config.showsystray and systraytomon(m) == m and !config.systrayonleft)
        w -= getsystraywidth();
    _ = c.XMoveResizeWindow(d, m.barwin, m.wx, m.by, w, @intCast(bh));
}

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
    wc.border_width = cl.bw;
    _ = c.XConfigureWindow(d, cl.win, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWBorderWidth, &wc);
    configure(cl);
    _ = c.XSync(d, x11.False);
}

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
    _ = c.XWarpPointer(d, x11.None, cl.win, 0, 0, 0, 0, cl.w + cl.bw - 1, cl.h + cl.bw - 1);
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
                const nw = @max(ev.xmotion.x - ocx - 2 * cl.bw + 1, 1);
                const nh = @max(ev.xmotion.y - ocy - 2 * cl.bw + 1, 1);
                if (cl.mon.?.wx + nw >= sm.wx and cl.mon.?.wx + nw <= sm.wx + sm.ww and
                    cl.mon.?.wy + nh >= sm.wy and cl.mon.?.wy + nh <= sm.wy + sm.wh)
                {
                    if (!cl.isfloating and sm.lt[sm.sellt].arrange != null and
                        (@abs(nw - cl.w) > @as(c_int, config.snap) or @abs(nh - cl.h) > @as(c_int, config.snap)))
                    {
                        togglefloating(&config.Arg{ .i = 0 });
                    }
                }
                if (sm.lt[sm.sellt].arrange == null or cl.isfloating)
                    resize(cl, cl.x, cl.y, nw, nh, true);
            },
            x11.ButtonRelease => break,
            else => {},
        }
    }
    _ = c.XWarpPointer(d, x11.None, cl.win, 0, 0, 0, 0, cl.w + cl.bw - 1, cl.h + cl.bw - 1);
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

fn resizerequest(e: *x11.XEvent) void {
    const ev = &e.xresizerequest;
    if (wintosystrayicon(ev.window)) |icon| {
        updatesystrayicongeom(icon, ev.width, ev.height);
        if (selmon) |sm| resizebarwin(sm);
        updatesystray();
    }
}

fn restack(m: *Monitor) void {
    const d = dpy orelse return;
    drawbar(m);
    const sel = m.sel orelse return;
    if (sel.isfloating or m.lt[m.sellt].arrange == null)
        _ = c.XRaiseWindow(d, sel.win);
    if (m.lt[m.sellt].arrange != null) {
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

pub fn run() void {
    const d = dpy orelse return;
    var ev: x11.XEvent = undefined;
    _ = c.XSync(d, x11.False);
    while (running and c.XNextEvent(d, &ev) == 0) {
        if (handler[@intCast(ev.type)]) |h| h(&ev);
    }
}

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

fn sendmon(cl: *Client, m: *Monitor) void {
    if (cl.mon == m) return;
    unfocus(cl, true);
    detach(cl);
    detachstack(cl);
    cl.mon = m;
    cl.tags = m.tagset[m.seltags];
    attach(cl);
    attachstack(cl);
    focus(null);
    arrange(null);
}

fn setclientstate(cl: *Client, state: c_long) void {
    const d = dpy orelse return;
    const data = [2]c_long{ state, x11.None };
    _ = c.XChangeProperty(d, cl.win, wmatom[WMState], wmatom[WMState], 32, x11.PropModeReplace, @ptrCast(&data), 2);
}

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

fn setfocus(cl: *Client) void {
    const d = dpy orelse return;
    if (!cl.neverfocus) {
        _ = c.XSetInputFocus(d, cl.win, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XChangeProperty(d, root, netatom[NetActiveWindow], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&cl.win), 1);
    }
    _ = sendevent(cl.win, wmatom[WMTakeFocus], x11.NoEventMask, @intCast(wmatom[WMTakeFocus]), x11.CurrentTime, 0, 0, 0);
}

fn setfullscreen(cl: *Client, fullscreen: bool) void {
    const d = dpy orelse return;
    if (fullscreen and !cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.win, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&netatom[NetWMFullscreen]), 1);
        cl.isfullscreen = true;
        cl.oldstate = cl.isfloating;
        cl.oldbw = cl.bw;
        cl.bw = 0;
        cl.isfloating = true;
        if (cl.mon) |m| resizeclient(cl, m.mx, m.my, m.mw, m.mh);
        _ = c.XRaiseWindow(d, cl.win);
    } else if (!fullscreen and cl.isfullscreen) {
        _ = c.XChangeProperty(d, cl.win, netatom[NetWMState], x11.XA_ATOM, 32, x11.PropModeReplace, null, 0);
        cl.isfullscreen = false;
        cl.isfloating = cl.oldstate;
        cl.bw = cl.oldbw;
        cl.x = cl.oldx;
        cl.y = cl.oldy;
        cl.w = cl.oldw;
        cl.h = cl.oldh;
        resizeclient(cl, cl.x, cl.y, cl.w, cl.h);
        arrange(cl.mon);
    }
}

pub fn setlayout(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if (arg.v == null or @as(?*const config.Layout, @ptrCast(@alignCast(arg.v))) != sm.lt[sm.sellt]) {
        sm.sellt ^= 1;
    }
    if (arg.v) |v| {
        sm.lt[sm.sellt] = @ptrCast(@alignCast(v));
    }
    const sym = std.mem.span(sm.lt[sm.sellt].symbol);
    @memcpy(sm.ltsymbol[0..sym.len], sym);
    if (sym.len < sm.ltsymbol.len) sm.ltsymbol[sym.len] = 0;
    if (sm.sel != null) {
        arrange(sm);
    } else {
        drawbar(sm);
    }
}

pub fn setmfact(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if (sm.lt[sm.sellt].arrange == null) return;
    const f = if (arg.f < 1.0) arg.f + sm.mfact else arg.f - 1.0;
    if (f < 0.05 or f > 0.95) return;
    sm.mfact = f;
    arrange(sm);
}

pub fn setup() void {
    const d = dpy orelse return;

    // clean up any zombies immediately
    sigchld(.CHLD);

    // init screen
    screen = c.DefaultScreen(d);
    sw = c.DisplayWidth(d, screen);
    sh = c.DisplayHeight(d, screen);
    root = c.RootWindow(d, screen);
    draw = drw.Drw.create(d, screen, root, @intCast(sw), @intCast(sh)) catch {
        die("cannot create drawing context");
        return;
    };
    const dr = draw.?;
    if (dr.fontsetCreate(&config.fonts) == null) {
        die("no fonts could be loaded.");
        return;
    }
    lrpad = @intCast(dr.fonts.?.h);
    bh = @as(c_int, @intCast(dr.fonts.?.h)) + 2;
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
    scheme = alloc.alloc([*]drw.Clr, config.colors.len) catch null;
    if (scheme) |s| {
        for (0..config.colors.len) |i| {
            s[i] = dr.scmCreate(&config.colors[i]) orelse continue;
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

fn showhide(cl: ?*Client) void {
    const d = dpy orelse return;
    const cl_c = cl orelse return;
    if (ISVISIBLE(cl_c)) {
        _ = c.XMoveWindow(d, cl_c.win, cl_c.x, cl_c.y);
        if ((cl_c.mon != null and cl_c.mon.?.lt[cl_c.mon.?.sellt].arrange == null or cl_c.isfloating) and !cl_c.isfullscreen)
            resize(cl_c, cl_c.x, cl_c.y, cl_c.w, cl_c.h, false);
        showhide(cl_c.snext);
    } else {
        showhide(cl_c.snext);
        _ = c.XMoveWindow(d, cl_c.win, WIDTH(cl_c) * -2, cl_c.y);
    }
}

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

pub fn tag(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    if (arg.ui & config.TAGMASK != 0) {
        sel.tags = arg.ui & config.TAGMASK;
        focus(null);
        arrange(sm);
    }
}

pub fn tagmon(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    _ = sel;
    if (mons == null or mons.?.next == null) return;
    if (dirtomon(arg.i)) |m| sendmon(sm.sel.?, m);
}

pub fn tile(m: *Monitor) void {
    var n: c_uint = 0;
    var cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) n += 1;
    if (n == 0) return;

    var mw: c_int = undefined;
    if (n > @as(c_uint, @intCast(m.nmaster))) {
        mw = if (m.nmaster != 0) @intFromFloat(@as(f32, @floatFromInt(m.ww)) * m.mfact) else 0;
    } else {
        mw = m.ww;
    }

    var i: c_uint = 0;
    var my: c_int = 0;
    var ty: c_int = 0;
    cl_it = nexttiled(m.clients);
    while (cl_it) |cl_c| : (cl_it = nexttiled(cl_c.next)) {
        if (i < @as(c_uint, @intCast(m.nmaster))) {
            const h = @divTrunc(m.wh - my, @as(c_int, @intCast(@min(n, @as(c_uint, @intCast(m.nmaster))) - i)));
            resize(cl_c, m.wx, m.wy + my, mw - (2 * cl_c.bw), h - (2 * cl_c.bw), false);
            if (my + HEIGHT(cl_c) < m.wh) my += HEIGHT(cl_c);
        } else {
            const h = @divTrunc(m.wh - ty, @as(c_int, @intCast(n - i)));
            resize(cl_c, m.wx + mw, m.wy + ty, m.ww - mw - (2 * cl_c.bw), h - (2 * cl_c.bw), false);
            if (ty + HEIGHT(cl_c) < m.wh) ty += HEIGHT(cl_c);
        }
        i += 1;
    }
}

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
                wc.y = -bh;
            } else {
                wc.y = 0;
                if (!sm.topbar) wc.y = sm.mh - bh;
            }
            _ = c.XConfigureWindow(d, st.win, x11.CWY, &wc);
        }
    }
    arrange(sm);
}

pub fn togglefloating(_: *const config.Arg) void {
    const sm = selmon orelse return;
    const sel = sm.sel orelse return;
    if (sel.isfullscreen) return;
    sel.isfloating = !sel.isfloating or sel.isfixed;
    if (sel.isfloating)
        resize(sel, sel.x, sel.y, sel.w, sel.h, false);
    arrange(sm);
}

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

pub fn toggleview(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    const newtagset = sm.tagset[sm.seltags] ^ (arg.ui & config.TAGMASK);
    if (newtagset != 0) {
        sm.tagset[sm.seltags] = newtagset;
        focus(null);
        arrange(sm);
    }
}

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

fn unmanage(cl: *Client, destroyed: bool) void {
    const d = dpy orelse return;
    const m = cl.mon;
    detach(cl);
    detachstack(cl);
    if (!destroyed) {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        wc.border_width = cl.oldbw;
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
        var w: c_uint = @intCast(mon.ww);
        if (config.showsystray and systraytomon(mon) == mon) w -= getsystraywidth();
        mon.barwin = c.XCreateWindow(d, root, mon.wx, mon.by, w, @intCast(bh), 0, @intCast(c.DefaultDepth(d, screen)), x11.CopyFromParent, c.DefaultVisual(d, screen), x11.CWOverrideRedirect | x11.CWBackPixmap | x11.CWEventMask, &wa);
        if (cursor[CurNormal]) |cur| _ = c.XDefineCursor(d, mon.barwin, cur.cursor);
        if (config.showsystray and systraytomon(mon) == mon) {
            if (systray_ptr) |st| _ = c.XMapRaised(d, st.win);
        }
        _ = c.XMapRaised(d, mon.barwin);
        _ = c.XSetClassHint(d, mon.barwin, &ch);
    }
}

fn updatebarpos(m: *Monitor) void {
    m.wy = m.my;
    m.wh = m.mh;
    if (m.showbar) {
        m.wh -= bh;
        m.by = if (m.topbar) m.wy else m.wy + m.wh;
        m.wy = if (m.topbar) m.wy + bh else m.wy;
    } else {
        m.by = -bh;
    }
}

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
                if (i >= n or unique_ptr[ui].x_org != @as(c_short, @intCast(mm.mx)) or unique_ptr[ui].y_org != @as(c_short, @intCast(mm.my)) or
                    unique_ptr[ui].width != @as(c_short, @intCast(mm.mw)) or unique_ptr[ui].height != @as(c_short, @intCast(mm.mh)))
                {
                    dirty = true;
                    mm.num = i;
                    mm.mx = unique_ptr[ui].x_org;
                    mm.wx = mm.mx;
                    mm.my = unique_ptr[ui].y_org;
                    mm.wy = mm.my;
                    mm.mw = unique_ptr[ui].width;
                    mm.ww = mm.mw;
                    mm.mh = unique_ptr[ui].height;
                    mm.wh = mm.mh;
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
            if (m.mw != sw or m.mh != sh) {
                dirty = true;
                m.mw = sw;
                m.ww = sw;
                m.mh = sh;
                m.wh = sh;
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

fn updatesizehints(cl: *Client) void {
    const d = dpy orelse return;
    var msize: c_long = undefined;
    var size: x11.XSizeHints = std.mem.zeroes(x11.XSizeHints);
    if (c.XGetWMNormalHints(d, cl.win, &size, &msize) == 0) {
        size.flags = x11.PSize;
    }
    if (size.flags & x11.PBaseSize != 0) {
        cl.basew = @intCast(size.base_width);
        cl.baseh = @intCast(size.base_height);
    } else if (size.flags & x11.PMinSize != 0) {
        cl.basew = @intCast(size.min_width);
        cl.baseh = @intCast(size.min_height);
    } else {
        cl.basew = 0;
        cl.baseh = 0;
    }
    if (size.flags & x11.PResizeInc != 0) {
        cl.incw = @intCast(size.width_inc);
        cl.inch = @intCast(size.height_inc);
    } else {
        cl.incw = 0;
        cl.inch = 0;
    }
    if (size.flags & x11.PMaxSize != 0) {
        cl.maxw = @intCast(size.max_width);
        cl.maxh = @intCast(size.max_height);
    } else {
        cl.maxw = 0;
        cl.maxh = 0;
    }
    if (size.flags & x11.PMinSize != 0) {
        cl.minw = @intCast(size.min_width);
        cl.minh = @intCast(size.min_height);
    } else if (size.flags & x11.PBaseSize != 0) {
        cl.minw = @intCast(size.base_width);
        cl.minh = @intCast(size.base_height);
    } else {
        cl.minw = 0;
        cl.minh = 0;
    }
    if (size.flags & x11.PAspect != 0) {
        cl.mina = @as(f32, @floatFromInt(size.min_aspect.y)) / @as(f32, @floatFromInt(size.min_aspect.x));
        cl.maxa = @as(f32, @floatFromInt(size.max_aspect.x)) / @as(f32, @floatFromInt(size.max_aspect.y));
    } else {
        cl.mina = 0.0;
        cl.maxa = 0.0;
    }
    cl.isfixed = (cl.maxw != 0 and cl.maxh != 0 and cl.maxw == cl.minw and cl.maxh == cl.minh);
}

fn updatestatus() void {
    if (!gettextprop(root, x11.XA_WM_NAME, &stext)) {
        const default_status = "dwm-" ++ VERSION;
        @memcpy(stext[0..default_status.len], default_status);
        stext[default_status.len] = 0;
    }
    if (selmon) |sm| drawbar(sm);
    updatesystray();
}

fn updatesystrayicongeom(icon: *Client, w: c_int, h: c_int) void {
    icon.h = bh;
    if (w == h) {
        icon.w = bh;
    } else if (h == bh) {
        icon.w = w;
    } else {
        icon.w = @intFromFloat(@as(f32, @floatFromInt(bh)) * (@as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h))));
    }
    _ = applysizehints(icon, &icon.x, &icon.y, &icon.w, &icon.h, false);
    if (icon.h > bh) {
        if (icon.w == icon.h) {
            icon.w = bh;
        } else {
            icon.w = @intFromFloat(@as(f32, @floatFromInt(bh)) * (@as(f32, @floatFromInt(icon.w)) / @as(f32, @floatFromInt(icon.h))));
        }
        icon.h = bh;
    }
}

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

fn updatesystray() void {
    const d = dpy orelse return;
    const s = scheme orelse return;
    if (!config.showsystray) return;

    const m = systraytomon(null) orelse return;
    var x_pos: c_int = m.mx + m.mw;
    const status_w = TEXTW(&stext) - lrpad + @as(c_int, @intCast(config.systrayspacing));
    var w: c_uint = 1;

    if (config.systrayonleft) x_pos -= status_w + @divTrunc(lrpad, 2);

    if (systray_ptr == null) {
        // init systray
        const st = alloc.create(Systray) catch {
            die("fatal: could not allocate Systray");
            return;
        };
        st.* = Systray{};
        systray_ptr = st;
        st.win = c.XCreateSimpleWindow(d, root, x_pos, m.by, w, @intCast(bh), 0, 0, s[SchemeSel][drw.ColBg].pixel);
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
    _ = c.XMoveResizeWindow(d, st.win, x_pos, m.by, w, @intCast(bh));
    var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
    wc.x = x_pos;
    wc.y = m.by;
    wc.width = @intCast(w);
    wc.height = bh;
    wc.stack_mode = x11.Above;
    wc.sibling = m.barwin;
    _ = c.XConfigureWindow(d, st.win, x11.CWX | x11.CWY | x11.CWWidth | x11.CWHeight | x11.CWSibling | x11.CWStackMode, &wc);
    _ = c.XMapWindow(d, st.win);
    _ = c.XMapSubwindows(d, st.win);
    if (draw) |dr| {
        _ = c.XSetForeground(d, dr.gc, s[SchemeNorm][drw.ColBg].pixel);
        _ = c.XFillRectangle(d, st.win, dr.gc, 0, 0, w, @intCast(bh));
    }
    _ = c.XSync(d, x11.False);
}

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

fn updatewindowtype(cl: *Client) void {
    const state = getatomprop(cl, netatom[NetWMState]);
    const wtype = getatomprop(cl, netatom[NetWMWindowType]);
    if (state == netatom[NetWMFullscreen]) setfullscreen(cl, true);
    if (wtype == netatom[NetWMWindowTypeDialog]) cl.isfloating = true;
}

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

pub fn view(arg: *const config.Arg) void {
    const sm = selmon orelse return;
    if ((arg.ui & config.TAGMASK) == sm.tagset[sm.seltags]) return;
    sm.seltags ^= 1;
    if (arg.ui & config.TAGMASK != 0) sm.tagset[sm.seltags] = arg.ui & config.TAGMASK;
    focus(null);
    arrange(sm);
}

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

fn wintosystrayicon(w: x11.Window) ?*Client {
    if (!config.showsystray or w == 0) return null;
    const st = systray_ptr orelse return null;
    var i = st.icons;
    while (i) |icon| : (i = icon.next) {
        if (icon.win == w) return icon;
    }
    return null;
}

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

fn xerrordummy(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    return 0;
}

fn xerrorstart(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    die("dwm: another window manager is already running");
    return -1;
}

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

pub fn zoom(_: *const config.Arg) void {
    const sm = selmon orelse return;
    var cl = sm.sel orelse return;
    if (sm.lt[sm.sellt].arrange == null or (sm.sel != null and sm.sel.?.isfloating)) return;
    if (cl == nexttiled(sm.clients)) {
        cl = nexttiled(cl.next) orelse return;
    }
    pop(cl);
}

// Custom functions

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

pub fn f1switchfocus(_: *const config.Arg) void {
    fakekeypress(x11.XK_F1);
    _ = c.usleep(10 * 1000); // 10ms
    const arg = config.Arg{ .i = 1 };
    focusstack(&arg);
}

fn die(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
