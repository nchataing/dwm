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
const config = @import("config.zig");
const systray = @import("systray.zig");
const monitor = @import("monitor.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const client = @import("client.zig");
const focus_mod = @import("focus.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const Client = dwm.Client;
const Monitor = dwm.Monitor;

const focus = focus_mod.focus;
const unfocus = focus_mod.unfocus;

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

/// The main event loop. Flushes pending requests, then blocks on XNextEvent
/// and dispatches each event through the handler table until `running` is
/// set to false (by quit() or a signal).
pub fn run() void {
    const d = dwm.dpy orelse return;
    var ev: x11.XEvent = undefined;
    _ = c.XSync(d, x11.False);
    while (dwm.running and c.XNextEvent(d, &ev) == 0) {
        if (handler[@intCast(ev.type)]) |h| h(&ev);
    }
}

// ── Key/button grabbing ─────────────────────────────────────────────────────

/// Registers all keybindings from config.keys as passive grabs on the root
/// window. This is how the WM intercepts hotkeys before any client sees them.
/// Each key is grabbed with all modifier variants (NumLock, CapsLock combos)
/// so the bindings work regardless of lock-key state.
pub fn grabkeys() void {
    const d = dwm.dpy orelse return;
    dwm.updatenumlockmask();
    const modifiers = [_]c_uint{ 0, x11.LockMask, dwm.numlockmask, dwm.numlockmask | x11.LockMask };
    _ = c.XUngrabKey(d, x11.AnyKey, x11.AnyModifier, dwm.root);
    for (&config.keys) |*key| {
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
/// window was clicked, then dispatches the matching action from config.buttons.
/// This is how mouse bindings work — clicking a tag switches to it, clicking
/// the layout symbol cycles layouts, etc.
fn buttonpress(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xbutton;
    var click: c_uint = config.ClkRootWin;
    var arg = config.Arg{ .i = 0 };

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
            x += bar.textWidth(config.tags[i]);
            if (ev.x < x or i + 1 >= config.tags.len) break;
            i += 1;
        }
        if (i < config.tags.len and ev.x < x) {
            click = config.ClkTagBar;
            arg = .{ .ui = @intCast(i) };
        } else if (ev.x < x + bar.layout_label_width) {
            click = config.ClkLtSymbol;
        } else if (ev.x > sm.window_w - bar.textWidth(&bar.status_text) - @as(c_int, @intCast(systray.getsystraywidth()))) {
            click = config.ClkStatusText;
        } else {
            click = config.ClkWinTitle;
        }
    } else if (dwm.wintoclient(ev.window)) |cl| {
        focus(cl);
        dwm.restack(sm);
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
/// then searches config.keys for a matching keysym+modifier combo and calls
/// the associated action function.
fn keypress(e: *x11.XEvent) void {
    const d = dwm.dpy orelse return;
    const ev = &e.xkey;
    const keysym = c.XkbKeycodeToKeysym(d, @intCast(ev.keycode), 0, 0);
    for (&config.keys) |*key| {
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
/// stay in sync with clients: we update the status text when the root window
/// name changes (set by xsetroot/slstatus), re-read titles on WM_NAME changes,
/// update floating state on WM_TRANSIENT_FOR changes, refresh size hints, and
/// handle urgency flags from WM_HINTS. Also handles systray icon property changes.
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

    if (ev.window == dwm.root and ev.atom == x11.XA_WM_NAME) {
        bar.updateStatus();
    } else if (ev.state == x11.PropertyDelete) {
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
