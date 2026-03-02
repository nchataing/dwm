// focus.zig — Focus management.
//
// Handles setting, removing, and reasserting keyboard focus. These functions
// are deeply coupled to the client, bar, and X11 input subsystems: focusing
// a client means updating borders, reordering the focus stack, grabbing
// buttons, and informing X of the active window.
//
// Extracted from dwm.zig. Imports dwm.zig for shared global state.

const std = @import("std");
const x11 = @import("x11.zig");
const drw = @import("drw.zig");
const events = @import("events.zig");
const bar = @import("bar.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const Client = dwm.Client;

// ── Focus functions ─────────────────────────────────────────────────────────

/// Sets keyboard focus to a client (or to root if null). This is the central focus
/// management function: it unfocuses the previous selection, moves the new client
/// to the top of the focus stack, updates the window border color (highlighted for
/// focused, normal for unfocused), sets X input focus, and updates _NET_ACTIVE_WINDOW.
/// If the requested client is not visible, it falls back to the first visible
/// client in the focus stack.
pub fn focus(cl: ?*Client) void {
    const d = dwm.dpy orelse return;
    const s = dwm.scheme orelse return;
    var c_focus = cl;
    if (c_focus == null or !c_focus.?.isVisible()) {
        const sm = dwm.selmon orelse return;
        c_focus = sm.stack;
        while (c_focus) |cf| {
            if (cf.isVisible()) break;
            c_focus = cf.snext;
        }
    }
    if (dwm.selmon) |sm| {
        if (sm.sel != null and sm.sel != c_focus) unfocus(sm.sel.?, false);
    }
    if (c_focus) |cf| {
        if (cf.monitor != dwm.selmon) dwm.selmon = cf.monitor;
        if (cf.isurgent) cf.setUrgent(false);
        cf.detachStack();
        cf.attachStack();
        grabbuttons(cf, true);
        _ = c.XSetWindowBorder(d, cf.window, s[dwm.SchemeSel][drw.ColBorder].pixel);
        setfocus(cf);
    } else {
        _ = c.XSetInputFocus(d, dwm.root, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XDeleteProperty(d, dwm.root, dwm.netatom[dwm.NetActiveWindow]);
    }
    if (dwm.selmon) |sm| sm.sel = c_focus;
    bar.drawbars();
}

/// Removes focus decorations from a client: resets the border color to normal
/// and re-grabs all buttons (so clicking it will re-focus). Optionally clears
/// X input focus to root. Called before focusing a different client.
pub fn unfocus(cl: ?*Client, set_focus: bool) void {
    const d = dwm.dpy orelse return;
    const s = dwm.scheme orelse return;
    const cl_c = cl orelse return;
    grabbuttons(cl_c, false);
    _ = c.XSetWindowBorder(d, cl_c.window, s[dwm.SchemeNorm][drw.ColBorder].pixel);
    if (set_focus) {
        _ = c.XSetInputFocus(d, dwm.root, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XDeleteProperty(d, dwm.root, dwm.netatom[dwm.NetActiveWindow]);
    }
}

/// Gives X input focus to a client and updates _NET_ACTIVE_WINDOW. Also sends
/// WM_TAKE_FOCUS for clients that support it. Skips XSetInputFocus for clients
/// with neverfocus set (those that explicitly don't want keyboard input).
fn setfocus(cl: *Client) void {
    const d = dwm.dpy orelse return;
    if (!cl.neverfocus) {
        _ = c.XSetInputFocus(d, cl.window, x11.RevertToPointerRoot, x11.CurrentTime);
        _ = c.XChangeProperty(d, dwm.root, dwm.netatom[dwm.NetActiveWindow], x11.XA_WINDOW, 32, x11.PropModeReplace, @ptrCast(&cl.window), 1);
    }
    _ = dwm.sendevent(cl.window, dwm.wmatom[dwm.WMTakeFocus], x11.NoEventMask, @intCast(dwm.wmatom[dwm.WMTakeFocus]), x11.CurrentTime, 0, 0, 0);
}

/// Handles FocusIn events — ensures the selected client keeps X input focus.
/// Some clients (e.g. those using XEmbed) can steal focus, so this reasserts
/// focus on our selected window whenever a rogue FocusIn is detected.
pub fn focusin(e: *x11.XEvent) void {
    const ev = &e.xfocus;
    if (dwm.selmon) |sm| {
        if (sm.sel) |sel| {
            if (ev.window != sel.window) setfocus(sel);
        }
    }
}

/// Sets up X button grabs on a client window. When unfocused, we grab all
/// buttons so clicking anywhere on the window first focuses it. When focused,
/// we only grab the specific modifier+button combos from events.buttons,
/// letting normal clicks pass through to the application. Modifier variants
/// (with NumLock, CapsLock) are grabbed to handle all lock-key states.
pub fn grabbuttons(cl: *Client, focused: bool) void {
    const d = dwm.dpy orelse return;
    dwm.updatenumlockmask();
    const modifiers = [_]c_uint{ 0, x11.LockMask, dwm.numlockmask, dwm.numlockmask | x11.LockMask };
    _ = c.XUngrabButton(d, x11.AnyButton, x11.AnyModifier, cl.window);
    if (!focused) {
        _ = c.XGrabButton(d, x11.AnyButton, x11.AnyModifier, cl.window, x11.False, @intCast(dwm.BUTTONMASK()), x11.GrabModeSync, x11.GrabModeSync, x11.None, x11.None);
    }
    for (&events.buttons) |*btn| {
        if (btn.click == events.ClkClientWin) {
            for (modifiers) |mod| {
                _ = c.XGrabButton(d, @intCast(btn.button), btn.mask | mod, cl.window, x11.False, @intCast(dwm.BUTTONMASK()), x11.GrabModeAsync, x11.GrabModeSync, x11.None, x11.None);
            }
        }
    }
}
