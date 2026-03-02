//! Monitor management.
//!
//! A Monitor corresponds to a physical screen (via Xinerama). Each monitor
//! has its own client list, focus stack, tag state, and bar window. This module
//! owns the Monitor type and functions that operate on the monitor list.

const std = @import("std");
const x11 = @import("x11.zig");
const config = @import("config.zig");
const dwm = @import("dwm.zig");
const c = x11.c;

const alloc = std.heap.c_allocator;

// A Monitor corresponds to a physical screen (via Xinerama).
// Each monitor has its own client list, focus stack, tag state, and bar window.
pub const Monitor = struct {
    layout_symbol: [16:0]u8 = [_:0]u8{0} ** 16, // text shown in the bar for current layout (e.g. "[]=")
    master_factor: f32 = 0, // fraction of screen width given to master area [0.05..0.95]
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

    tag: u5 = 0, // index of the currently viewed tag (0..8)
    selected_layout: c_uint = 0, // index (0 or 1) into lt[] for the active layout
    showbar: bool = true,
    topbar: bool = true,

    clients: ?*dwm.Client = null, // head of the client linked list (creation order)
    sel: ?*dwm.Client = null, // currently focused client on this monitor
    stack: ?*dwm.Client = null, // head of the focus-stack linked list (MRU order)
    next: ?*Monitor = null, // next monitor in the global linked list

    barwin: x11.Window = 0, // the X11 window used for the status bar
    lt: [2]*const config.Layout = undefined, // two remembered layouts (toggle with setlayout)

    /// Allocates and initializes a new Monitor with config defaults.
    pub fn create() ?*Monitor {
        const m = alloc.create(Monitor) catch return null;
        m.* = Monitor{};
        m.master_factor = config.master_factor;
        m.showbar = config.showbar;
        m.topbar = config.topbar;
        m.lt[0] = &config.layouts[0];
        m.lt[1] = &config.layouts[1 % config.layouts.len];
        const sym = std.mem.span(config.layouts[0].symbol);
        @memcpy(m.layout_symbol[0..sym.len], sym);
        return m;
    }

    /// Removes this monitor from the global list, destroys its bar window, and frees it.
    pub fn destroy(self: *Monitor) void {
        const d = dwm.dpy orelse return;
        if (self == dwm.mons) {
            dwm.mons = dwm.mons.?.next;
        } else {
            var m = dwm.mons;
            while (m) |mm| : (m = mm.next) {
                if (mm.next == self) {
                    mm.next = self.next;
                    break;
                }
            }
        }
        _ = c.XUnmapWindow(d, self.barwin);
        _ = c.XDestroyWindow(d, self.barwin);
        alloc.destroy(self);
    }

    /// Calculates bar Y position and adjusts the usable window area to exclude the bar.
    pub fn updateBarPos(self: *Monitor) void {
        self.window_y = self.monitor_y;
        self.window_h = self.monitor_h;
        if (self.showbar) {
            self.window_h -= dwm.bar_height;
            self.bar_y = if (self.topbar) self.window_y else self.window_y + self.window_h;
            self.window_y = if (self.topbar) self.window_y + dwm.bar_height else self.window_y;
        } else {
            self.bar_y = -dwm.bar_height;
        }
    }

    /// Returns the area of intersection between a rectangle and this monitor's window area.
    pub fn intersect(self: *Monitor, x: c_int, y: c_int, w: c_int, h: c_int) c_int {
        return @max(0, @min(x + w, self.window_x + self.window_w) - @max(x, self.window_x)) *
            @max(0, @min(y + h, self.window_y + self.window_h) - @max(y, self.window_y));
    }

    /// Updates the layout symbol and invokes the current layout's arrange function.
    pub fn applyLayout(self: *Monitor) void {
        const sym = std.mem.span(self.lt[self.selected_layout].symbol);
        @memcpy(self.layout_symbol[0..sym.len], sym);
        if (sym.len < self.layout_symbol.len) self.layout_symbol[sym.len] = 0;
        if (self.lt[self.selected_layout].arrange) |arrange_fn| arrange_fn(self);
    }
};

// --- Module-level functions ---

/// Returns the next or previous monitor relative to selmon, wrapping around.
/// Used by focusmon/tagmon keybindings to cycle through monitors.
pub fn adjacent(dir: c_int) ?*Monitor {
    const sm = dwm.selmon orelse return null;
    if (dir > 0) {
        return sm.next orelse dwm.mons;
    } else {
        if (sm == dwm.mons) {
            var m = dwm.mons;
            while (m) |mm| {
                if (mm.next == null) return mm;
                m = mm.next;
            }
            return null;
        } else {
            var m = dwm.mons;
            while (m) |mm| : (m = mm.next) {
                if (mm.next == sm) return mm;
            }
            return null;
        }
    }
}

/// Checks whether a Xinerama screen info entry is geometrically unique among
/// those already seen. Xinerama can report the same physical screen multiple
/// times (e.g. mirrored displays); we only want one Monitor per unique geometry.
fn isUniqueGeom(unique: [*]x11.XineramaScreenInfo, n: usize, info: *allowzero x11.XineramaScreenInfo) bool {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (unique[i].x_org == info.x_org and unique[i].y_org == info.y_org and
            unique[i].width == info.width and unique[i].height == info.height)
            return false;
    }
    return true;
}

/// Finds which monitor a rectangle overlaps with most, by comparing intersection
/// areas. Used by mouse operations to determine which monitor a moved/resized
/// window belongs to, and to figure out which monitor the root window cursor is on.
pub fn fromRect(x: c_int, y: c_int, w: c_int, h: c_int) ?*Monitor {
    var r = dwm.selmon;
    var area: c_int = 0;
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) {
        const a = mon.intersect(x, y, w, h);
        if (a > area) {
            area = a;
            r = mon;
        }
    }
    return r;
}

/// Determines which monitor a given X window belongs to. Checks whether it's root
/// (uses pointer position), a bar window (returns that monitor), or a client
/// (returns client's monitor). Falls back to selmon for unknown windows.
pub fn fromWindow(w: x11.Window) ?*Monitor {
    var x: c_int = 0;
    var y: c_int = 0;
    if (w == dwm.root and dwm.getrootptr(&x, &y)) return fromRect(x, y, 1, 1);
    var m = dwm.mons;
    while (m) |mon| : (m = mon.next) {
        if (w == mon.barwin) return mon;
    }
    if (dwm.wintoclient(w)) |cl| return cl.monitor;
    return dwm.selmon;
}

/// Syncs the monitor list to the current Xinerama screen layout. Creates monitors
/// for new screens, updates geometries for changed screens, and migrates clients
/// from removed monitors to the first monitor. Returns true if anything changed
/// (triggers bar/focus updates).
pub fn updateGeometry() bool {
    const d = dwm.dpy orelse return false;
    var dirty: bool = false;

    if (c.XineramaIsActive(d) != 0) {
        var nn: c_int = undefined;
        const info = c.XineramaQueryScreens(d, &nn);
        var n: c_int = 0;
        {
            var m = dwm.mons;
            while (m) |mon| : (m = mon.next) n += 1;
        }

        const raw_ptr: ?[*]align(@alignOf(x11.XineramaScreenInfo)) u8 = @ptrCast(@alignCast(std.c.calloc(@intCast(nn), @sizeOf(x11.XineramaScreenInfo))));
        const unique_ptr: [*]x11.XineramaScreenInfo = @ptrCast(raw_ptr orelse return false);
        var j: usize = 0;
        var i: c_int = 0;
        while (i < nn) : (i += 1) {
            if (isUniqueGeom(unique_ptr, j, &info[@intCast(i)])) {
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
                var m = dwm.mons;
                while (m != null and m.?.next != null) m = m.?.next;
                if (m) |mm| {
                    mm.next = Monitor.create();
                } else {
                    dwm.mons = Monitor.create();
                }
            }
            i = 0;
            var m = dwm.mons;
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
                    mm.updateBarPos();
                }
            }
        } else {
            // less monitors available
            i = nn;
            while (i < n) : (i += 1) {
                var m = dwm.mons;
                while (m != null and m.?.next != null) m = m.?.next;
                if (m) |mm| {
                    while (mm.clients) |cl_c| {
                        dirty = true;
                        mm.clients = cl_c.next;
                        cl_c.detachStack();
                        cl_c.monitor = dwm.mons;
                        if (dwm.mons) |first| {
                            _ = first;
                            cl_c.attach();
                            cl_c.attachStack();
                        }
                    }
                    if (mm == dwm.selmon) dwm.selmon = dwm.mons;
                    mm.destroy();
                }
            }
        }
        std.c.free(unique_ptr);
    } else {
        // default monitor setup
        if (dwm.mons == null) dwm.mons = Monitor.create();
        if (dwm.mons) |m| {
            if (m.monitor_w != dwm.screen_width or m.monitor_h != dwm.screen_height) {
                dirty = true;
                m.monitor_w = dwm.screen_width;
                m.window_w = dwm.screen_width;
                m.monitor_h = dwm.screen_height;
                m.window_h = dwm.screen_height;
                m.updateBarPos();
            }
        }
    }
    if (dirty) {
        dwm.selmon = dwm.mons;
        dwm.selmon = fromWindow(dwm.root);
    }
    return dirty;
}
