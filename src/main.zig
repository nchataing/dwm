/// Entry point for dwm — handles argument parsing, locale setup, X display connection,
/// and then delegates to dwm's init/run/cleanup lifecycle.
///
/// The startup sequence is:
///   1. Parse CLI args (only -v for version is supported)
///   2. Set locale so Xlib can handle multibyte text input
///   3. Open the X display connection
///   4. checkotherwm() — verify no other WM is running (only one can SubstructureRedirect root)
///   5. setup() — register atoms, allocate colors/cursors, create bars, select events on root
///   6. scan() — adopt already-existing windows so a WM restart doesn't lose clients
///   7. run() — main event loop (blocks until quit)
///   8. cleanup() + XCloseDisplay — tear down all resources and disconnect from X
const std = @import("std");
const x11 = @import("x11.zig");
const dwm = @import("dwm.zig");
const config = @import("config");

const c = x11.c;

const VERSION = config.version;

pub fn main(init: std.process.Init.Minimal) void {
    // Parse arguments
    var args = init.args.iterate();
    _ = args.next(); // skip argv[0]
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            die("dwm-" ++ VERSION);
        } else {
            die("usage: dwm [-v]");
        }
    }

    // Set locale
    if (c.setlocale(c.LC_CTYPE, "") == null or c.XSupportsLocale() == 0) {
        std.debug.print("warning: no locale support\n", .{});
    }

    // Open display
    dwm.dpy = c.XOpenDisplay(null);
    if (dwm.dpy == null) {
        die("dwm: cannot open display");
    }

    dwm.checkotherwm();
    dwm.setup();
    dwm.scan();
    dwm.run();
    dwm.cleanup();

    _ = c.XCloseDisplay(dwm.dpy.?);
}

/// Print a fatal message to stderr and exit. Used for unrecoverable errors
/// (bad args, unable to open display) where there's nothing to clean up yet.
fn die(msg: []const u8) noreturn {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
