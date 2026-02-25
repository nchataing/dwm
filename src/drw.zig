// Drawing library - Zig port of drw.c/drw.h
const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;

const UTF_INVALID: u21 = 0xFFFD;
const UTF_SIZ: usize = 4;

// Font abstraction
pub const Fnt = struct {
    dpy: *x11.Display,
    h: c_uint,
    xfont: *x11.XftFont,
    pattern: ?*x11.FcPattern,
    next: ?*Fnt,
};

// Cursor abstraction
pub const Cur = struct {
    cursor: x11.Cursor,
};

// Color scheme index
pub const ColFg = 0;
pub const ColBg = 1;
pub const ColBorder = 2;

pub const Clr = x11.XftColor;

// Drawing context
pub const Drw = struct {
    w: c_uint,
    h: c_uint,
    dpy: *x11.Display,
    screen: c_int,
    root: x11.Window,
    drawable: x11.Drawable,
    gc: x11.GC,
    scheme: ?[*]Clr,
    fonts: ?*Fnt,

    pub fn create(dpy: *x11.Display, screen: c_int, root: x11.Window, w: c_uint, h: c_uint) !*Drw {
        const alloc = std.heap.c_allocator;
        const drw = try alloc.create(Drw);
        drw.* = .{
            .dpy = dpy,
            .screen = screen,
            .root = root,
            .w = w,
            .h = h,
            .drawable = c.XCreatePixmap(dpy, root, w, h, @intCast(c.DefaultDepth(dpy, screen))),
            .gc = c.XCreateGC(dpy, root, 0, null),
            .scheme = null,
            .fonts = null,
        };
        _ = c.XSetLineAttributes(dpy, drw.gc, 1, x11.LineSolid, x11.CapButt, x11.JoinMiter);
        return drw;
    }

    pub fn resize(self: *Drw, w: c_uint, h: c_uint) void {
        self.w = w;
        self.h = h;
        if (self.drawable != 0) {
            _ = c.XFreePixmap(self.dpy, self.drawable);
        }
        self.drawable = c.XCreatePixmap(self.dpy, self.root, w, h, @intCast(c.DefaultDepth(self.dpy, self.screen)));
    }

    pub fn free(self: *Drw) void {
        _ = c.XFreePixmap(self.dpy, self.drawable);
        _ = c.XFreeGC(self.dpy, self.gc);
        fontsetFree(self.fonts);
        std.heap.c_allocator.destroy(self);
    }

    pub fn fontsetCreate(self: *Drw, font_names: []const [*:0]const u8) ?*Fnt {
        var ret: ?*Fnt = null;
        var i: usize = font_names.len;
        while (i > 0) {
            i -= 1;
            const cur = xfontCreate(self, font_names[i], null) orelse continue;
            cur.next = ret;
            ret = cur;
        }
        self.fonts = ret;
        return ret;
    }

    pub fn fontsetGetwidth(self: *Drw, txt: [*:0]const u8) c_uint {
        if (self.fonts == null) return 0;
        return @intCast(self.text(0, 0, 0, 0, 0, txt, false));
    }

    pub fn clrCreate(self: *Drw, dest: *Clr, clrname: [*:0]const u8) void {
        if (c.XftColorAllocName(
            self.dpy,
            c.DefaultVisual(self.dpy, self.screen),
            c.DefaultColormap(self.dpy, self.screen),
            clrname,
            dest,
        ) == 0) {
            std.debug.panic("error, cannot allocate color '{s}'", .{clrname});
        }
    }

    pub fn scmCreate(self: *Drw, clrnames: []const [*:0]const u8) ?[*]Clr {
        if (clrnames.len < 2) return null;
        const alloc = std.heap.c_allocator;
        const ret = alloc.alloc(Clr, clrnames.len) catch return null;
        for (clrnames, 0..) |name, i| {
            self.clrCreate(&ret[i], name);
        }
        return ret.ptr;
    }

    pub fn setFontset(self: *Drw, set: ?*Fnt) void {
        self.fonts = set;
    }

    pub fn setScheme(self: *Drw, scm: ?[*]Clr) void {
        self.scheme = scm;
    }

    pub fn rect(self: *Drw, x: c_int, y: c_int, w: c_uint, h: c_uint, filled: bool, invert: bool) void {
        const scheme_ptr = self.scheme orelse return;
        _ = c.XSetForeground(self.dpy, self.gc, if (invert) scheme_ptr[ColBg].pixel else scheme_ptr[ColFg].pixel);
        if (filled) {
            _ = c.XFillRectangle(self.dpy, self.drawable, self.gc, x, y, w, h);
        } else {
            _ = c.XDrawRectangle(self.dpy, self.drawable, self.gc, x, y, w -| 1, h -| 1);
        }
    }

    pub fn text(self: *Drw, x_arg: c_int, y_arg: c_int, w_arg: c_uint, h_arg: c_uint, lpad: c_uint, text_str: [*:0]const u8, invert: bool) c_int {
        var buf: [1024]u8 = undefined;
        var ew: c_uint = 0;
        var d: ?*x11.XftDraw = null;
        var usedfont: *Fnt = undefined;
        var nextfont: ?*Fnt = null;

        const scheme_ptr = self.scheme orelse return 0;
        const fonts_ptr = self.fonts orelse return 0;
        const render = x_arg != 0 or y_arg != 0 or w_arg != 0 or h_arg != 0;
        if (!render and text_str[0] == 0) return 0;

        var x = x_arg;
        var w: c_uint = w_arg;

        if (!render) {
            w = ~w;
        } else {
            _ = c.XSetForeground(self.dpy, self.gc, if (invert) scheme_ptr[ColFg].pixel else scheme_ptr[ColBg].pixel);
            _ = c.XFillRectangle(self.dpy, self.drawable, self.gc, x_arg, y_arg, w_arg, h_arg);
            d = c.XftDrawCreate(
                self.dpy,
                self.drawable,
                c.DefaultVisual(self.dpy, self.screen),
                c.DefaultColormap(self.dpy, self.screen),
            );
            x += @intCast(lpad);
            w -= lpad;
        }

        usedfont = fonts_ptr;
        var cur_text: [*]const u8 = text_str;
        while (true) {
            var utf8strlen: usize = 0;
            const utf8str = cur_text;
            nextfont = null;
            var charexists: bool = false;

            while (cur_text[0] != 0) {
                var utf8codepoint: u21 = 0;
                const utf8charlen = utf8Decode(cur_text, &utf8codepoint);
                var found = false;

                var curfont_it: ?*Fnt = self.fonts;
                while (curfont_it) |cf| : (curfont_it = cf.next) {
                    if (c.XftCharExists(self.dpy, cf.xfont, utf8codepoint) != 0) {
                        charexists = true;
                        if (cf == usedfont) {
                            utf8strlen += utf8charlen;
                            cur_text += utf8charlen;
                        } else {
                            nextfont = cf;
                        }
                        found = true;
                        break;
                    }
                }

                if (!found or nextfont != null) break;
                charexists = false;
            }

            if (utf8strlen > 0) {
                fontGetexts(usedfont, utf8str, @intCast(utf8strlen), &ew, null);
                const max_len = @min(utf8strlen, buf.len - 1);
                var len = max_len;
                while (len > 0 and ew > w) {
                    len -= 1;
                    fontGetexts(usedfont, utf8str, @intCast(len), &ew, null);
                }

                if (len > 0) {
                    @memcpy(buf[0..len], utf8str[0..len]);
                    buf[len] = 0;
                    if (len < utf8strlen) {
                        // Add ellipsis
                        var ei = len;
                        while (ei > 0 and ei > len -| 3) {
                            ei -= 1;
                            buf[ei] = '.';
                        }
                    }

                    if (render) {
                        const ty = y_arg + @divTrunc(@as(c_int, @intCast(h_arg)) - @as(c_int, @intCast(usedfont.h)), 2) + @as(c_int, @intCast(usedfont.xfont.*.ascent));
                        c.XftDrawStringUtf8(
                            d,
                            &scheme_ptr[if (invert) ColBg else ColFg],
                            usedfont.xfont,
                            x,
                            ty,
                            &buf,
                            @intCast(len),
                        );
                    }
                    x += @intCast(ew);
                    w -= ew;
                }
            }

            if (cur_text[0] == 0) {
                break;
            } else if (nextfont) |nf| {
                usedfont = nf;
            } else {
                // Try to find a fallback font

                var utf8codepoint: u21 = 0;
                _ = utf8Decode(cur_text, &utf8codepoint);

                const fccharset = c.FcCharSetCreate();
                _ = c.FcCharSetAddChar(fccharset, utf8codepoint);

                if (self.fonts) |f| {
                    if (f.pattern) |pattern| {
                        const fcpattern = c.FcPatternDuplicate(pattern);
                        _ = c.FcPatternAddCharSet(fcpattern, x11.FC_CHARSET, fccharset);
                        _ = c.FcPatternAddBool(fcpattern, x11.FC_SCALABLE, x11.FcTrue);
                        _ = c.FcPatternAddBool(fcpattern, x11.FC_COLOR, x11.FcFalse);

                        _ = c.FcConfigSubstitute(null, fcpattern, x11.FcMatchPattern);
                        c.FcDefaultSubstitute(fcpattern);
                        var result: x11.FcResult = undefined;
                        const match = c.XftFontMatch(self.dpy, self.screen, fcpattern, &result);

                        c.FcCharSetDestroy(fccharset);
                        c.FcPatternDestroy(fcpattern);

                        if (match) |m| {
                            if (xfontCreate(self, null, m)) |new_font| {
                                if (c.XftCharExists(self.dpy, new_font.xfont, utf8codepoint) != 0) {
                                    // Append to font list
                                    var last: *Fnt = f;
                                    while (last.next) |n| last = n;
                                    last.next = new_font;
                                    usedfont = new_font;
                                } else {
                                    xfontFree(new_font);
                                    usedfont = f;
                                }
                            } else {
                                usedfont = f;
                            }
                        }
                    } else {
                        c.FcCharSetDestroy(fccharset);
                        std.debug.panic("the first font in the cache must be loaded from a font string.", .{});
                    }
                } else {
                    c.FcCharSetDestroy(fccharset);
                }
            }
        }

        if (d) |draw| c.XftDrawDestroy(draw);
        return x + (if (render) @as(c_int, @intCast(w)) else 0);
    }

    pub fn map(self: *Drw, win: x11.Window, x: c_int, y: c_int, w: c_uint, h: c_uint) void {
        _ = c.XCopyArea(self.dpy, self.drawable, win, self.gc, x, y, w, h, x, y);
        _ = c.XSync(self.dpy, x11.False);
    }

    pub fn curCreate(self: *Drw, shape: c_int) !*Cur {
        const alloc = std.heap.c_allocator;
        const cur = try alloc.create(Cur);
        cur.* = .{
            .cursor = c.XCreateFontCursor(self.dpy, @intCast(shape)),
        };
        return cur;
    }

    pub fn curFree(self: *Drw, cur: *Cur) void {
        _ = c.XFreeCursor(self.dpy, cur.cursor);
        std.heap.c_allocator.destroy(cur);
    }
};

fn xfontCreate(drw: *Drw, fontname: ?[*:0]const u8, fontpattern: ?*x11.FcPattern) ?*Fnt {
    const alloc = std.heap.c_allocator;
    var xfont: ?*x11.XftFont = null;
    var pattern: ?*x11.FcPattern = null;

    if (fontname) |name| {
        xfont = c.XftFontOpenName(drw.dpy, drw.screen, name);
        if (xfont == null) {
            std.debug.print("error, cannot load font from name: '{s}'\n", .{name});
            return null;
        }
        pattern = c.FcNameParse(name);
        if (pattern == null) {
            std.debug.print("error, cannot parse font name to pattern: '{s}'\n", .{name});
            c.XftFontClose(drw.dpy, xfont);
            return null;
        }
    } else if (fontpattern) |fp| {
        xfont = c.XftFontOpenPattern(drw.dpy, fp);
        if (xfont == null) {
            std.debug.print("error, cannot load font from pattern.\n", .{});
            return null;
        }
    } else {
        std.debug.panic("no font specified.", .{});
    }

    // Do not allow using color fonts
    var iscol: c.FcBool = undefined;
    if (c.FcPatternGetBool(xfont.?.*.pattern, x11.FC_COLOR, 0, &iscol) == x11.FcResultMatch and iscol != 0) {
        c.XftFontClose(drw.dpy, xfont);
        return null;
    }

    const font = alloc.create(Fnt) catch return null;
    font.* = .{
        .xfont = xfont.?,
        .pattern = pattern,
        .h = @intCast(xfont.?.*.ascent + xfont.?.*.descent),
        .dpy = drw.dpy,
        .next = null,
    };
    return font;
}

fn xfontFree(font: ?*Fnt) void {
    const f = font orelse return;
    if (f.pattern) |p| c.FcPatternDestroy(p);
    c.XftFontClose(f.dpy, f.xfont);
    std.heap.c_allocator.destroy(f);
}

pub fn fontsetFree(font: ?*Fnt) void {
    const f = font orelse return;
    fontsetFree(f.next);
    xfontFree(f);
}

pub fn fontGetexts(font: *Fnt, text_ptr: [*]const u8, len: c_uint, w: ?*c_uint, h: ?*c_uint) void {
    var ext: x11.XGlyphInfo = undefined;
    c.XftTextExtentsUtf8(font.dpy, font.xfont, text_ptr, @intCast(len), &ext);
    if (w) |wp| wp.* = @intCast(ext.xOff);
    if (h) |hp| hp.* = font.h;
}

fn utf8Decode(text: [*]const u8, codepoint: *u21) usize {
    const byte0 = text[0];
    if (byte0 < 0x80) {
        codepoint.* = byte0;
        return 1;
    } else if (byte0 < 0xC0) {
        codepoint.* = UTF_INVALID;
        return 1;
    } else if (byte0 < 0xE0) {
        if ((text[1] & 0xC0) != 0x80) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        const cp: u21 = (@as(u21, byte0 & 0x1F) << 6) | @as(u21, text[1] & 0x3F);
        if (cp < 0x80) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        codepoint.* = cp;
        return 2;
    } else if (byte0 < 0xF0) {
        if ((text[1] & 0xC0) != 0x80 or (text[2] & 0xC0) != 0x80) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        const cp: u21 = (@as(u21, byte0 & 0x0F) << 12) | (@as(u21, text[1] & 0x3F) << 6) | @as(u21, text[2] & 0x3F);
        if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        codepoint.* = cp;
        return 3;
    } else if (byte0 < 0xF8) {
        if ((text[1] & 0xC0) != 0x80 or (text[2] & 0xC0) != 0x80 or (text[3] & 0xC0) != 0x80) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        const cp: u21 = (@as(u21, byte0 & 0x07) << 18) | (@as(u21, text[1] & 0x3F) << 12) | (@as(u21, text[2] & 0x3F) << 6) | @as(u21, text[3] & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) {
            codepoint.* = UTF_INVALID;
            return 1;
        }
        codepoint.* = cp;
        return 4;
    }
    codepoint.* = UTF_INVALID;
    return 1;
}
