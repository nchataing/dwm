const std = @import("std");
const x11 = @import("x11.zig");
const dwm = @import("dwm.zig");

const c = x11.c;

const VERSION = "6.3";

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

fn die(msg: []const u8) noreturn {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}
