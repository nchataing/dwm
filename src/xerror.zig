//! X11 error handlers.
//!
//! X11 is asynchronous — requests are buffered and errors arrive later. The WM
//! must install a custom error handler to silence harmless errors (e.g. BadWindow
//! when a client destroys its window between our request and the server's reply)
//! while still catching fatal ones.
//!
//! Three handlers are used:
//!   - `handler`  — The normal handler, installed for the WM's lifetime.
//!   - `dummy`    — A no-op handler, installed temporarily around operations that
//!                  may trigger ignorable errors (unmanage, killclient).
//!   - `startup`  — Installed briefly during checkotherwm() to detect if another
//!                  WM is already running (any error = abort).

const std = @import("std");
const x11 = @import("x11.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

/// Xlib's default error handler, saved at startup so we can forward fatal errors to it.
pub var xlib: ?*const fn (?*x11.Display, ?*x11.XErrorEvent) callconv(.c) c_int = null;

/// Main error handler installed for the WM's lifetime. Silences known-harmless
/// X errors (BadWindow from race conditions, BadDrawable from stale draws,
/// BadMatch from focus/configure on destroyed windows, BadAccess from button/key
/// grab conflicts). Fatal errors are logged and forwarded to the default handler.
pub fn handler(_: ?*x11.Display, ee: ?*x11.XErrorEvent) callconv(.c) c_int {
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
    if (xlib) |handler_fn| return handler_fn(dwm.dpy, ee);
    return 0;
}

/// No-op error handler used temporarily during operations that may trigger
/// X errors we want to ignore (e.g. restoring a dead client's border width
/// during unmanage, or force-killing a client).
pub fn dummy(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    return 0;
}

/// Temporary error handler installed during checkotherwm(). If any X error
/// fires while we try to select SubstructureRedirect on root, it means
/// another WM is already running. We abort with a clear error message.
pub fn startup(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) c_int {
    dwm.die("dwm: another window manager is already running");
    return -1;
}
