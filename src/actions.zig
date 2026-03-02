// actions.zig — Keybinding action functions.
// All functions here have the uniform signature `fn(*const config.Arg) void`
// (or are helpers called exclusively by such functions). They are wired up
// in config.zig's `keys` and `buttons` tables.
const std = @import("std");
const x11 = @import("x11.zig");
const config = @import("config.zig");
const dwm = @import("dwm.zig");
const xerror = @import("xerror.zig");
const monitor = @import("monitor.zig");
const layout = @import("layout.zig");
const bar = @import("bar.zig");
const systray = @import("systray.zig");
const c = x11.c;

// --- Keybinding actions ---

/// Switches focus to the next/previous monitor.
/// Unfocuses the current selection first so the border color updates correctly.
pub fn focusMonitor(arg: *const config.Arg) void {
    if (dwm.mons == null or dwm.mons.?.next == null) return;
    const m = monitor.adjacent(arg.i) orelse return;
    if (m == dwm.selmon) return;
    if (dwm.selmon) |sm| dwm.unfocus(sm.sel, false);
    dwm.selmon = m;
    dwm.focus(null);
}

/// Cycles focus to the next (arg.i > 0) or previous (arg.i < 0) visible
/// client in the tiling order. Wraps around at the ends of the client list.
/// Respects lockfullscreen — if the focused client is fullscreen, focus
/// stays put to prevent accidental switches.
pub fn focusStack(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    const sel = sm.sel orelse return;
    if (sel.isfullscreen and config.lockfullscreen) return;

    var found: ?*dwm.Client = null;
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
        dwm.focus(f);
        dwm.restack(sm);
    }
}

/// Interactive window move via mouse drag. Grabs the pointer, enters a local
/// event loop tracking mouse motion, and moves the window in real-time. Snaps
/// to monitor edges when within `config.snap` pixels. If the window was tiled,
/// dragging it beyond the snap threshold auto-floats it. On release, if the
/// window landed on a different monitor, it's sent there.
pub fn moveMouse(_: *const config.Arg) void {
    const d = dwm.dpy orelse return;
    const sm = dwm.selmon orelse return;
    const cl = sm.sel orelse return;
    if (cl.isfullscreen) return;
    dwm.restack(sm);
    const ocx = cl.x;
    const ocy = cl.y;
    if (c.XGrabPointer(d, dwm.root, x11.False, @intCast(dwm.MOUSEMASK()), x11.GrabModeAsync, x11.GrabModeAsync, x11.None, dwm.cursor[dwm.CurMove].?.cursor, x11.CurrentTime) != x11.GrabSuccess)
        return;
    var x: c_int = 0;
    var y: c_int = 0;
    if (!dwm.getrootptr(&x, &y)) return;
    var lasttime: x11.Time = 0;
    var ev: x11.XEvent = undefined;
    while (true) {
        _ = c.XMaskEvent(d, @intCast(dwm.MOUSEMASK() | x11.ExposureMask | x11.SubstructureRedirectMask), &ev);
        switch (ev.type) {
            x11.ConfigureRequest, x11.Expose, x11.MapRequest => {
                if (dwm.handler[@intCast(ev.type)]) |h| h(&ev);
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
                if (!cl.isfloating and sm.layout.arrange != null and
                    (@abs(nx - cl.x) > @as(c_int, config.snap) or @abs(ny - cl.y) > @as(c_int, config.snap)))
                {
                    toggleFloating(&config.Arg{ .i = 0 });
                }
                if (sm.layout.arrange == null or cl.isfloating)
                    cl.resize(nx, ny, cl.w, cl.h, true);
            },
            x11.ButtonRelease => break,
            else => {},
        }
    }
    _ = c.XUngrabPointer(d, x11.CurrentTime);
    if (monitor.fromRect(cl.x, cl.y, cl.w, cl.h)) |m| {
        if (m != dwm.selmon) {
            dwm.sendmon(cl, m);
            dwm.selmon = m;
            dwm.focus(null);
        }
    }
}

/// Interactive window resize via mouse drag. Similar to moveMouse but warps
/// the cursor to the bottom-right corner and tracks the delta as new
/// width/height. Auto-floats tiled windows when dragged beyond the snap
/// threshold. On release, sends the window to whichever monitor it overlaps most.
pub fn resizeMouse(_: *const config.Arg) void {
    const d = dwm.dpy orelse return;
    const sm = dwm.selmon orelse return;
    const cl = sm.sel orelse return;
    if (cl.isfullscreen) return;
    dwm.restack(sm);
    const ocx = cl.x;
    const ocy = cl.y;
    if (c.XGrabPointer(d, dwm.root, x11.False, @intCast(dwm.MOUSEMASK()), x11.GrabModeAsync, x11.GrabModeAsync, x11.None, dwm.cursor[dwm.CurResize].?.cursor, x11.CurrentTime) != x11.GrabSuccess)
        return;
    _ = c.XWarpPointer(d, x11.None, cl.window, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
    var lasttime: x11.Time = 0;
    var ev: x11.XEvent = undefined;
    while (true) {
        _ = c.XMaskEvent(d, @intCast(dwm.MOUSEMASK() | x11.ExposureMask | x11.SubstructureRedirectMask), &ev);
        switch (ev.type) {
            x11.ConfigureRequest, x11.Expose, x11.MapRequest => {
                if (dwm.handler[@intCast(ev.type)]) |h| h(&ev);
            },
            x11.MotionNotify => {
                if ((ev.xmotion.time - lasttime) <= (1000 / 60)) continue;
                lasttime = ev.xmotion.time;
                const nw = @max(ev.xmotion.x - ocx - 2 * cl.border_width + 1, 1);
                const nh = @max(ev.xmotion.y - ocy - 2 * cl.border_width + 1, 1);
                if (cl.monitor.?.window_x + nw >= sm.window_x and cl.monitor.?.window_x + nw <= sm.window_x + sm.window_w and
                    cl.monitor.?.window_y + nh >= sm.window_y and cl.monitor.?.window_y + nh <= sm.window_y + sm.window_h)
                {
                    if (!cl.isfloating and sm.layout.arrange != null and
                        (@abs(nw - cl.w) > @as(c_int, config.snap) or @abs(nh - cl.h) > @as(c_int, config.snap)))
                    {
                        toggleFloating(&config.Arg{ .i = 0 });
                    }
                }
                if (sm.layout.arrange == null or cl.isfloating)
                    cl.resize(cl.x, cl.y, nw, nh, true);
            },
            x11.ButtonRelease => break,
            else => {},
        }
    }
    _ = c.XWarpPointer(d, x11.None, cl.window, 0, 0, 0, 0, cl.w + cl.border_width - 1, cl.h + cl.border_width - 1);
    _ = c.XUngrabPointer(d, x11.CurrentTime);
    while (c.XCheckMaskEvent(d, x11.EnterWindowMask, &ev) != 0) {}
    if (monitor.fromRect(cl.x, cl.y, cl.w, cl.h)) |m| {
        if (m != dwm.selmon) {
            dwm.sendmon(cl, m);
            dwm.selmon = m;
            dwm.focus(null);
        }
    }
}

/// Gracefully closes the focused window. First tries WM_DELETE_WINDOW (the
/// polite ICCCM way that lets the app save state); if the client doesn't
/// support that protocol, forcefully kills it with XKillClient as a last resort.
pub fn killClient(_: *const config.Arg) void {
    const d = dwm.dpy orelse return;
    const sm = dwm.selmon orelse return;
    const sel = sm.sel orelse return;

    if (!dwm.sendevent(sel.window, dwm.wmatom[dwm.WMDelete], x11.NoEventMask, @intCast(dwm.wmatom[dwm.WMDelete]), x11.CurrentTime, 0, 0, 0)) {
        _ = c.XGrabServer(d);
        _ = c.XSetErrorHandler(&xerror.dummy);
        _ = c.XSetCloseDownMode(d, x11.DestroyAll);
        _ = c.XKillClient(d, sel.window);
        _ = c.XSync(d, x11.False);
        _ = c.XSetErrorHandler(&xerror.handler);
        _ = c.XUngrabServer(d);
    }
}

/// Forks and execs an external command (e.g. terminal, dmenu). The child closes
/// the X display fd (inherited from parent) and starts a new session so it's not
/// tied to dwm's process group. If the command is dmenu, the monitor number is
/// patched into the argv so dmenu appears on the correct screen.
pub fn spawn(arg: *const config.Arg) void {
    const d = dwm.dpy orelse return;
    const v = arg.v orelse return;
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(@alignCast(v));

    // Update dmenumon if this is the dmenu command
    if (argv == @as([*:null]const ?[*:0]const u8, @ptrCast(&config.dmenucmd))) {
        if (dwm.selmon) |sm| {
            dwm.dmenumon_buf[0] = '0' + @as(u8, @intCast(sm.num));
        }
    }

    const pid = std.c.fork();
    if (pid == 0) {
        // child
        if (dwm.dpy) |dp| {
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

/// Moves the focused window to the tag specified in arg.ui. The window
/// disappears from the current view if the target tag isn't the active one.
pub fn tag(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    const sel = sm.sel orelse return;
    const new_tag: u5 = @intCast(arg.ui);
    sel.tag = new_tag;
    dwm.focus(null);
    layout.arrange(sm);
}

/// Sends the focused window to the next/previous monitor. The window gets
/// the destination monitor's active tags so it's visible there.
pub fn tagMonitor(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    const sel = sm.sel orelse return;
    _ = sel;
    if (dwm.mons == null or dwm.mons.?.next == null) return;
    if (monitor.adjacent(arg.i)) |m| dwm.sendmon(sm.sel.?, m);
}

/// Shows or hides the status bar. Updates the bar position, resizes the bar
/// window (and systray if present), and re-arranges so tiled windows expand
/// into the freed space (or shrink to make room for the bar).
pub fn toggleBar(_: *const config.Arg) void {
    const d = dwm.dpy orelse return;
    const sm = dwm.selmon orelse return;
    sm.showbar = !sm.showbar;
    sm.updateBarPos();
    systray.resizebarwin(sm);
    if (systray.ptr) |st| {
        var wc: x11.XWindowChanges = std.mem.zeroes(x11.XWindowChanges);
        if (!sm.showbar) {
            wc.y = -bar.bar_height;
        } else {
            wc.y = 0;
            if (!sm.topbar) wc.y = sm.monitor_h - bar.bar_height;
        }
        _ = c.XConfigureWindow(d, st.win, x11.CWY, &wc);
    }
    layout.arrange(sm);
}

/// Toggles the focused window between floating and tiled. Fixed-size windows
/// (equal min and max hints) are always forced to floating. Blocked while
/// fullscreen to prevent layout corruption.
pub fn toggleFloating(_: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    const sel = sm.sel orelse return;
    if (sel.isfullscreen) return;
    sel.isfloating = !sel.isfloating or sel.isfixed;
    if (sel.isfloating)
        sel.resize(sel.x, sel.y, sel.w, sel.h, false);
    layout.arrange(sm);
}

/// Switches the monitor's view to the tag in arg.ui.
pub fn view(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    const new_tag: u5 = @intCast(arg.ui);
    if (new_tag == sm.tag) return;
    sm.tag = new_tag;
    dwm.focus(null);
    layout.arrange(sm);
}

/// Switches the active layout to the one specified by arg.v.
pub fn setLayout(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    if (arg.v) |v| {
        sm.layout = @ptrCast(@alignCast(v));
    }
    const sym = std.mem.span(sm.layout.symbol);
    @memcpy(sm.layout_symbol[0..sym.len], sym);
    if (sym.len < sm.layout_symbol.len) sm.layout_symbol[sym.len] = 0;
    if (sm.sel != null) {
        layout.arrange(sm);
    } else {
        bar.drawbar(sm);
    }
}

/// Adjusts the master area size ratio. If arg.f < 1.0, it's treated as a
/// relative delta added to the current factor; if >= 1.0, it's an absolute
/// value (minus 1.0). Clamped to [0.05, 0.95] so neither area disappears.
pub fn setMasterFactor(arg: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    if (sm.layout.arrange == null) return;
    const f = if (arg.f < 1.0) arg.f + sm.master_factor else arg.f - 1.0;
    if (f < 0.05 or f > 0.95) return;
    sm.master_factor = f;
    layout.arrange(sm);
}

/// Promotes the focused window to the master area. If it's already the master
/// (first tiled client), promotes the second tiled client instead — effectively
/// swapping master and top-of-stack. No-op for floating clients or layouts
/// without a master area.
pub fn zoom(_: *const config.Arg) void {
    const sm = dwm.selmon orelse return;
    var cl = sm.sel orelse return;
    if (sm.layout.arrange == null or (sm.sel != null and sm.sel.?.isfloating)) return;
    if (cl == layout.nextTiled(sm.clients)) {
        cl = layout.nextTiled(cl.next) orelse return;
    }
    dwm.pop(cl);
}

/// Sets running to false, which exits the main event loop and triggers cleanup.
pub fn quit(_: *const config.Arg) void {
    dwm.running = false;
}

// --- Custom actions ---

/// Synthesizes a key press+release event and sends it to the window under the
/// pointer. Used by f1SwitchFocus to inject an F1 keypress into the focused
/// app before switching focus (e.g. to trigger a specific action in the app).
pub fn fakeKeyPress(keysym: x11.KeySym) void {
    const d = dwm.dpy orelse return;
    var event: x11.XEvent = std.mem.zeroes(x11.XEvent);
    event.xkey.keycode = c.XKeysymToKeycode(d, keysym);
    event.xkey.same_screen = x11.True;
    event.xkey.subwindow = dwm.root;
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
/// This is a user-specific workflow shortcut.
pub fn f1SwitchFocus(_: *const config.Arg) void {
    fakeKeyPress(x11.XK_F1);
    _ = c.usleep(10 * 1000); // 10ms
    const arg = config.Arg{ .i = 1 };
    focusStack(&arg);
}
