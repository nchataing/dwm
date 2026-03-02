// events.zig — X11 event dispatch and handlers.
//
// Contains the event dispatch table, the main event loop (run), and all X11
// event handler functions. The dispatch table maps X11 event type codes to
// handler functions; the main loop in run() reads events and dispatches them.
//
// Extracted from dwm.zig. Imports dwm.zig for shared global state.

const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const actions = @import("actions.zig");
const systray = @import("systray.zig");
const monitor = @import("monitor.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const client = @import("client.zig");
const focus_mod = @import("focus.zig");
const dwm = @import("dwm.zig");
const colors = @import("colors.zig");
const status = @import("status.zig");
const c = x11.c;

const Client = dwm.Client;
const Monitor = dwm.Monitor;

const focus = focus_mod.focus;
const unfocus = focus_mod.unfocus;

// ── Input config ────────────────────────────────────────────────────────────

// MODKEY is the modifier key used for all dwm keybindings (Mod4 = Super/Win key).
pub const MODKEY = x11.Mod4Mask;

/// Tagged union for passing different argument types to keybinding/button callbacks.
pub const Arg = union {
    i: c_int,
    ui: c_uint,
    f: f32,
    v: ?*const anyopaque,
};

pub const Key = struct {
    mod: c_uint,
    keysym: x11.KeySym,
    func: *const fn (*const Arg) void,
    arg: Arg,
};

pub const Button = struct {
    click: c_uint,
    mask: c_uint,
    button: c_uint,
    func: *const fn (*const Arg) void,
    arg: Arg,
};

// ── Commands ────────────────────────────────────────────────────────────────
// Null-terminated argv arrays passed to spawn(). The dmenu command receives
// monitor number and color scheme args so it matches dwm's appearance.
pub const dmenucmd = [_:null]?[*:0]const u8{
    "dmenu_run",
    "-m",
    &dwm.dmenumon_buf,
    "-fn",
    dwm.dmenufont,
    "-nb",
    colors.gray1,
    "-nf",
    colors.gray3,
    "-sb",
    colors.cyan,
    "-sf",
    colors.gray4,
};
pub const termcmd = [_:null]?[*:0]const u8{ "kitty", null };
pub const screenswitchcmd = [_:null]?[*:0]const u8{ "/home/nchataing/perso/utils/screen.sh", null };

/// Generate the two standard per-tag keybindings for a given key:
///   Mod+key       → view tag          (switch to that tag)
///   Mod+Shift+key → tag client        (move focused client to that tag)
fn tagkeys(comptime key: x11.KeySym, comptime tag_idx: u5) [2]Key {
    return .{
        .{ .mod = MODKEY, .keysym = key, .func = &actions.view, .arg = .{ .ui = tag_idx } },
        .{ .mod = MODKEY | x11.ShiftMask, .keysym = key, .func = &actions.tag, .arg = .{ .ui = tag_idx } },
    };
}

// Keybindings. Keys are for a BEPO keyboard layout — the number row produces
// «»()@+−/ rather than 1-9, so tagkeys use those keysyms instead of XK_1..XK_9.
pub const keys = [_]Key{
    .{ .mod = MODKEY, .keysym = x11.XK_p, .func = &actions.spawn, .arg = .{ .v = @ptrCast(&dmenucmd) } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_Return, .func = &actions.spawn, .arg = .{ .v = @ptrCast(&termcmd) } },
    .{ .mod = MODKEY, .keysym = x11.XK_s, .func = &actions.spawn, .arg = .{ .v = @ptrCast(&screenswitchcmd) } },
    .{ .mod = MODKEY, .keysym = x11.XK_b, .func = &actions.toggleBar, .arg = .{ .i = 0 } },
    .{ .mod = MODKEY, .keysym = x11.XK_j, .func = &actions.focusStack, .arg = .{ .i = 1 } },
    .{ .mod = MODKEY, .keysym = x11.XK_k, .func = &actions.focusStack, .arg = .{ .i = -1 } },
    .{ .mod = MODKEY, .keysym = x11.XK_Tab, .func = &actions.focusStack, .arg = .{ .i = 1 } },
    .{ .mod = MODKEY, .keysym = x11.XK_h, .func = &actions.setMasterFactor, .arg = .{ .f = -0.05 } },
    .{ .mod = MODKEY, .keysym = x11.XK_l, .func = &actions.setMasterFactor, .arg = .{ .f = 0.05 } },
    .{ .mod = MODKEY, .keysym = x11.XK_Return, .func = &actions.zoom, .arg = .{ .i = 0 } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_q, .func = &actions.killClient, .arg = .{ .i = 0 } },
    .{ .mod = MODKEY, .keysym = x11.XK_t, .func = &actions.setLayout, .arg = .{ .v = @ptrCast(&layout.layouts[0]) } },
    .{ .mod = MODKEY, .keysym = x11.XK_f, .func = &actions.setLayout, .arg = .{ .v = @ptrCast(&layout.layouts[1]) } },
    .{ .mod = MODKEY, .keysym = x11.XK_m, .func = &actions.setLayout, .arg = .{ .v = @ptrCast(&layout.layouts[2]) } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_space, .func = &actions.toggleFloating, .arg = .{ .i = 0 } },
    .{ .mod = MODKEY, .keysym = x11.XK_comma, .func = &actions.focusMonitor, .arg = .{ .i = -1 } },
    .{ .mod = MODKEY, .keysym = x11.XK_period, .func = &actions.focusMonitor, .arg = .{ .i = 1 } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_comma, .func = &actions.tagMonitor, .arg = .{ .i = -1 } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_period, .func = &actions.tagMonitor, .arg = .{ .i = 1 } },
    .{ .mod = MODKEY | x11.ShiftMask, .keysym = x11.XK_e, .func = &actions.quit, .arg = .{ .i = 0 } },
    .{ .mod = MODKEY, .keysym = x11.XK_F1, .func = &actions.f1SwitchFocus, .arg = .{ .i = 0 } },
} //
    ++ tagkeys(x11.XK_quotedbl, 0) //
    ++ tagkeys(x11.XK_guillemotleft, 1) //
    ++ tagkeys(x11.XK_guillemotright, 2) //
    ++ tagkeys(x11.XK_parenleft, 3) //
    ++ tagkeys(x11.XK_parenright, 4) //
    ++ tagkeys(x11.XK_at, 5) //
    ++ tagkeys(x11.XK_plus, 6) //
    ++ tagkeys(x11.XK_minus, 7) //
    ++ tagkeys(x11.XK_slash, 8);

// ── Click areas ─────────────────────────────────────────────────────────────
// Identifiers for regions of the bar/screen that can receive mouse clicks.
// Used by the button bindings below to distinguish where a click occurred.
pub const ClkTagBar = 0;
pub const ClkLtSymbol = 1;
pub const ClkStatusText = 2;
pub const ClkWinTitle = 3;
pub const ClkClientWin = 4;
pub const ClkRootWin = 5;
pub const ClkLast = 6;

// Mouse button bindings: associate clicks in specific areas with actions.
pub const buttons = [_]Button{
    .{ .click = ClkTagBar, .mask = MODKEY, .button = x11.Button1, .func = &actions.tag, .arg = .{ .i = 0 } },
    .{ .click = ClkWinTitle, .mask = 0, .button = x11.Button2, .func = &actions.zoom, .arg = .{ .i = 0 } },
    .{ .click = ClkStatusText, .mask = 0, .button = x11.Button2, .func = &actions.spawn, .arg = .{ .v = @ptrCast(&termcmd) } },
    .{ .click = ClkClientWin, .mask = MODKEY, .button = x11.Button1, .func = &actions.moveMouse, .arg = .{ .i = 0 } },
    .{ .click = ClkClientWin, .mask = MODKEY, .button = x11.Button2, .func = &actions.toggleFloating, .arg = .{ .i = 0 } },
    .{ .click = ClkClientWin, .mask = MODKEY, .button = x11.Button3, .func = &actions.resizeMouse, .arg = .{ .i = 0 } },
    .{ .click = ClkTagBar, .mask = 0, .button = x11.Button1, .func = &actions.view, .arg = .{ .i = 0 } },
};

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Strip NumLock and CapsLock from a modifier mask so keybindings work
/// regardless of whether those locks are active.
fn CLEANMASK(mask: c_uint) c_uint {
    return mask & ~(dwm.numlockmask | x11.LockMask) &
        (x11.ShiftMask | x11.ControlMask | x11.Mod1Mask | x11.Mod2Mask | x11.Mod3Mask | x11.Mod4Mask | x11.Mod5Mask);
}

// ── Event dispatch table ────────────────────────────────────────────────────

const HandlerFn = *const fn (*x11.XEvent) void;
pub var handler: [x11.LASTEvent]?HandlerFn = initHandler();

fn initHandler() [x11.LASTEvent]?HandlerFn {
    var h = [_]?HandlerFn{null} ** x11.LASTEvent;
    h[x11.ButtonPress] = &buttonpress;
    h[x11.ClientMessage] = &clientmessage;
    h[x11.ConfigureRequest] = &configurerequest;
    h[x11.ConfigureNotify] = &configurenotify;
    h[x11.DestroyNotify] = &destroynotify;
    h[x11.EnterNotify] = &enternotify;
    h[x11.Expose] = &expose;
    h[x11.FocusIn] = &focus_mod.focusin;
    h[x11.KeyPress] = &keypress;
    h[x11.MappingNotify] = &mappingnotify;
    h[x11.MapRequest] = &maprequest;
    h[x11.MotionNotify] = &motionnotify;
    h[x11.PropertyNotify] = &propertynotify;
    h[x11.ResizeRequest] = &resizerequest;
    h[x11.UnmapNotify] = &unmapnotify;
    return h;
}

// ── Main event loop ─────────────────────────────────────────────────────────

/// The main event loop. Uses poll() to multiplex the X11 connection fd and the
/// status timer fd. When the timer fires, we update the embedded status bar.
/// When X11 events arrive, we drain them all via XPending/XNextEvent.
pub fn run() void {
    const d = dwm.dpy orelse return;
    var ev: x11.XEvent = undefined;
    _ = c.XSync(d, x11.False);

    status.init();
    defer status.deinit();

    // Do an initial status update immediately.
    status.update();
    bar.drawbars();

    const x11_fd = c.XConnectionNumber(d);
    const timer = status.fd();

    const linux = std.os.linux;
    const POLLIN: i16 = linux.POLL.IN;

    var fds = [_]std.posix.pollfd{
        .{ .fd = x11_fd, .events = POLLIN, .revents = 0 },
        .{ .fd = timer, .events = POLLIN, .revents = 0 },
    };
    const nfds: std.posix.nfds_t = if (timer >= 0) 2 else 1;

    while (dwm.running) {
        // Flush any pending outgoing X requests before blocking.
        _ = c.XFlush(d);

        _ = std.posix.poll(fds[0..nfds], -1) catch continue;

        // Timer fired — update the status bar.
        if (nfds > 1 and fds[1].revents & POLLIN != 0) {
            status.acknowledge();
            status.update();
            if (dwm.selmon) |sm| bar.drawbar(sm);
        }

        // Drain all pending X11 events.
        while (c.XPending(d) > 0) {
            _ = c.XNextEvent(d, &ev);
            if (handler[@intCast(ev.type)]) |h| h(&ev);
        }
    }
}

// ── Key/button grabbing ─────────────────────────────────────────────────────

/// Registers all keybindings from keys as passive grabs on the root
/// window. This is how the WM intercepts hotkeys before any client sees them.
/// Each key is grabbed with all modifier variants (NumLock, CapsLock combos)
/// so the bindings work regardless of lock-key state.
pub fn grabkeys() void {
    const d = dwm.dpy orelse return;
    dwm.updatenumlockmask();
    const modifiers = [_]c_uint{ 0, x11.LockMask, dwm.numlockmask, dwm.numlockmask | x11.LockMask };
    _ = c.XUngrabKey(d, x11.AnyKey, x11.AnyModifier, dwm.root);
    for (&keys) |*key| {
        const code = c.XKeysymToKeycode(d, key.keysym);
        if (code != 0) {
            for (modifiers) |mod| {
                _ = c.XGrabKey(d, code, key.mod | mod, dwm.root, x11.True, x11.GrabModeAsync, x11.GrabModeAsync);
            }
        }
    }
}

// ── Event handler implementations ───────────────────────────────────────────

/// X11 ButtonPress event handler. Determines which region of the bar was clicked
/// (tag label, layout symbol, window title, status text) or whether a client
/// window was clicked, then dispatches the matching action from buttons.
/// This is how mouse bindings work — clicking a tag switches to it, clicking
/// the layout symbol cycles layouts, etc.
fn buttonpress(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xbutton;
    var click: c_uint = ClkRootWin;
    var arg = Arg{ .i = 0 };

    // focus monitor if necessary
    if (monitor.fromWindow(ev.window)) |m| {
        if (m != dwm.selmon) {
            if (dwm.selmon) |sm| unfocus(sm.sel, true);
            dwm.selmon = m;
            focus(null);
        }
    }

    const sm = dwm.selmon orelse return;
    if (ev.window == sm.barwin) {
        var i: usize = 0;
        var x: c_int = 0;
        while (true) {
            x += bar.textWidth(bar.tags[i]);
            if (ev.x < x or i + 1 >= bar.tags.len) break;
            i += 1;
        }
        if (i < bar.tags.len and ev.x < x) {
            click = ClkTagBar;
            arg = .{ .ui = @intCast(i) };
        } else if (ev.x < x + bar.layout_label_width) {
            click = ClkLtSymbol;
        } else if (ev.x > sm.window_w - bar.statusWidth() - @as(c_int, @intCast(systray.getsystraywidth()))) {
            click = ClkStatusText;
        } else {
            click = ClkWinTitle;
        }
    } else if (dwm.wintoclient(ev.window)) |cl| {
        focus(cl);
        dwm.restack(sm);
        _ = c.XAllowEvents(d, x11.ReplayPointer, x11.CurrentTime);
        click = ClkClientWin;
    }

    for (&buttons) |*btn| {
        if (click == btn.click and btn.button == ev.button and
            CLEANMASK(btn.mask) == CLEANMASK(ev.state))
        {
            if (click == ClkTagBar and btn.arg.i == 0)
                btn.func(&arg)
            else
                btn.func(&btn.arg);
        }
    }
}

/// Handles X11 ClientMessage events, which are how clients (and the system tray)
/// communicate EWMH/XEMBED requests to the WM. Covers three main cases:
/// 1. System tray dock requests — an applet wants to embed in the tray
/// 2. _NET_WM_STATE changes — typically fullscreen toggle requests
/// 3. _NET_ACTIVE_WINDOW — another app asking us to activate a window (we just
///    mark it urgent rather than stealing focus, which is less disruptive)
fn clientmessage(e: *x11.XEvent) void {
    if (dwm.dpy == null) return;
    const cme = &e.xclient;
    const cl = dwm.wintoclient(cme.window);

    if (systray.ptr) |st| {
        if (cme.window == st.win and cme.message_type == dwm.netatom[dwm.NetSystemTrayOP]) {
            if (cme.data.l[1] == systray.SYSTEM_TRAY_REQUEST_DOCK) {
                systray.handleDockRequest(cme.data.l[2]);
            }
            return;
        }
    }

    if (cl == null) return;
    const managed = cl.?;
    if (cme.message_type == dwm.netatom[dwm.NetWMState]) {
        if (cme.data.l[1] == dwm.netatom[dwm.NetWMFullscreen] or cme.data.l[2] == dwm.netatom[dwm.NetWMFullscreen]) {
            managed.setFullscreen(cme.data.l[0] == 1 or (cme.data.l[0] == 2 and !managed.isfullscreen));
        }
    } else if (cme.message_type == dwm.netatom[dwm.NetActiveWindow]) {
        if (dwm.selmon) |sm_local| {
            if (managed != sm_local.sel and !managed.isurgent) managed.setUrgent(true);
        }
    }
}

/// Handles root window ConfigureNotify events, which fire when the screen
/// resolution changes (e.g. xrandr). We update the global screen dimensions,
/// resize the drawing buffer, recreate bars, and resize any fullscreen clients
/// to match the new geometry. Without this, the WM would be stuck at the old resolution.
fn configurenotify(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xconfigure;
    if (ev.window == dwm.root) {
        const dirty = (dwm.screen_width != ev.width or dwm.screen_height != ev.height);
        dwm.screen_width = ev.width;
        dwm.screen_height = ev.height;
        if (monitor.updateGeometry() or dirty) {
            if (dwm.draw) |dr| dr.resize(@intCast(dwm.screen_width), @intCast(bar.bar_height));
            bar.updateBars();
            var m = dwm.mons;
            while (m) |mon| : (m = mon.next) {
                var cl_it = mon.clients;
                while (cl_it) |cl_c| : (cl_it = cl_c.next) {
                    if (cl_c.isfullscreen) cl_c.applyGeometry(mon.monitor_x, mon.monitor_y, mon.monitor_w, mon.monitor_h);
                }
                systray.resizebarwin(mon);
            }
            focus(null);
            layout.arrange(null);
        }
    }
    _ = d;
}

/// Handles ConfigureRequest events — a client asking to change its own geometry
/// or stacking order. For managed clients, we only honor the request if the client
/// is floating (tiled clients get their position from the layout). For unmanaged
/// windows (not yet in our client list), we pass the request through unchanged.
fn configurerequest(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xconfigurerequest;

    if (dwm.wintoclient(ev.window)) |cl| {
        if (ev.value_mask & x11.CWBorderWidth != 0) {
            cl.border_width = ev.border_width;
        } else if (cl.isfloating or (dwm.selmon != null and dwm.selmon.?.layout.arrange == null)) {
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

/// Handles DestroyNotify — a window was destroyed by its owner. We unmanage
/// the client (or remove the systray icon) so the WM stops tracking it.
fn destroynotify(e: *x11.XEvent) void {
    const ev = &e.xdestroywindow;
    if (dwm.wintoclient(ev.window)) |cl| {
        cl.unmanage(true);
    } else if (systray.wintosystrayicon(ev.window)) |icon| {
        systray.removesystrayicon(icon);
        if (dwm.selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }
}

/// Handles EnterNotify — the pointer crossed into a window. This implements
/// sloppy focus (focus-follows-mouse): moving the cursor into a window focuses
/// it. We also switch the active monitor if the pointer enters a window on
/// a different screen. Events from grabs or inferior windows are ignored to
/// prevent spurious focus changes during resize/move operations.
fn enternotify(e: *x11.XEvent) void {
    const ev = &e.xcrossing;
    if ((ev.mode != x11.NotifyNormal or ev.detail == x11.NotifyInferior) and ev.window != dwm.root) return;
    const cl = dwm.wintoclient(ev.window);
    const m = if (cl) |c_cl| c_cl.monitor else monitor.fromWindow(ev.window);
    const mon = m orelse return;
    if (mon != dwm.selmon) {
        if (dwm.selmon) |sm| unfocus(sm.sel, true);
        dwm.selmon = mon;
    } else if (cl == null or cl == (dwm.selmon orelse return).sel) {
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
            bar.drawbar(m);
            if (m == dwm.selmon) systray.update();
        }
    }
}

/// X11 KeyPress event handler. Translates the hardware keycode to a keysym,
/// then searches keys for a matching keysym+modifier combo and calls
/// the associated action function.
fn keypress(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xkey;
    const keysym = c.XkbKeycodeToKeysym(d, @intCast(ev.keycode), 0, 0);
    for (&keys) |*key| {
        if (keysym == key.keysym and CLEANMASK(key.mod) == CLEANMASK(ev.state)) {
            key.func(&key.arg);
        }
    }
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
    const d = dwm.dpy orelse return;
    const ev = &e.xmaprequest;

    if (systray.wintosystrayicon(ev.window)) |icon| {
        if (systray.ptr) |st| {
            _ = dwm.sendevent(icon.window, dwm.netatom[dwm.XembedAtom], x11.StructureNotifyMask, x11.CurrentTime, systray.XEMBED_WINDOW_ACTIVATE, 0, @intCast(st.win), systray.XEMBED_EMBEDDED_VERSION);
        }
        if (dwm.selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }

    var wa: x11.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(d, ev.window, &wa) == 0) return;
    if (wa.override_redirect != 0) return;
    if (dwm.wintoclient(ev.window) == null) client.manage(ev.window, &wa);
}

/// Handles MotionNotify on the root window — tracks which monitor the pointer
/// is on and switches the active monitor accordingly. Uses a static variable
/// to avoid redundant focus changes when the pointer stays on the same monitor.
fn motionnotify(e: *x11.XEvent) void {
    const S = struct {
        var mon: ?*Monitor = null;
    };
    const ev = &e.xmotion;
    if (ev.window != dwm.root) return;
    const m = monitor.fromRect(ev.x_root, ev.y_root, 1, 1);
    if (m != S.mon and S.mon != null) {
        if (dwm.selmon) |sm| unfocus(sm.sel, true);
        dwm.selmon = m;
        focus(null);
    }
    S.mon = m;
}

/// Handles PropertyNotify events — a window property changed. This is how we
/// stay in sync with clients: re-read titles on WM_NAME changes, update
/// floating state on WM_TRANSIENT_FOR changes, refresh size hints, and handle
/// urgency flags from WM_HINTS. Also handles systray icon property changes.
/// (Status text is now driven by the embedded status timer, not root WM_NAME.)
fn propertynotify(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xproperty;

    if (systray.wintosystrayicon(ev.window)) |icon| {
        if (ev.atom == x11.XA_WM_NORMAL_HINTS) {
            icon.updateSizeHints();
            systray.updatesystrayicongeom(icon, icon.w, icon.h);
        } else {
            systray.updatesystrayiconstate(icon, ev);
        }
        if (dwm.selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }

    if (ev.state == x11.PropertyDelete) {
        return;
    } else if (dwm.wintoclient(ev.window)) |cl| {
        switch (ev.atom) {
            x11.XA_WM_TRANSIENT_FOR => {
                var trans: x11.Window = undefined;
                if (!cl.isfloating and c.XGetTransientForHint(d, cl.window, &trans) != 0) {
                    cl.isfloating = dwm.wintoclient(trans) != null;
                    if (cl.isfloating) layout.arrange(cl.monitor);
                }
            },
            x11.XA_WM_NORMAL_HINTS => cl.updateSizeHints(),
            x11.XA_WM_HINTS => {
                cl.updateWmHints();
                bar.drawbars();
            },
            else => {},
        }
        if (ev.atom == x11.XA_WM_NAME or ev.atom == dwm.netatom[dwm.NetWMName]) {
            cl.updateTitle();
            if (cl.monitor) |mon| {
                if (cl == mon.sel) bar.drawbar(mon);
            }
        }
        if (ev.atom == dwm.netatom[dwm.NetWMWindowType]) cl.updateWindowType();
    }
}

/// Handles ResizeRequest events from systray icons. The tray icons can't resize
/// themselves (they're embedded), so we update their geometry and refresh the tray.
fn resizerequest(e: *x11.XEvent) void {
    const ev = &e.xresizerequest;
    if (systray.wintosystrayicon(ev.window)) |icon| {
        systray.updatesystrayicongeom(icon, ev.width, ev.height);
        if (dwm.selmon) |sm| systray.resizebarwin(sm);
        systray.update();
    }
}

/// Handles UnmapNotify — a window was unmapped. If it was a send_event (the
/// client deliberately withdrew itself), we mark it as withdrawn. Otherwise
/// we unmanage it. For systray icons, we re-map them raised (they may have
/// been temporarily unmapped by the app) and refresh the tray.
fn unmapnotify(e: *x11.XEvent) void {
    const ev = &e.xunmap;
    if (dwm.wintoclient(ev.window)) |cl| {
        if (ev.send_event != 0) {
            cl.setClientState(x11.WithdrawnState);
        } else {
            cl.unmanage(false);
        }
    } else if (systray.wintosystrayicon(ev.window)) |icon| {
        _ = c.XMapRaised(dwm.dpy.?, icon.window);
        systray.update();
    }
}
