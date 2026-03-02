/// Drawing library — provides font rendering, color management, and off-screen pixmap compositing
/// for the window manager's bar and other UI elements. Zig port of suckless drw.c/drw.h.
///
/// Uses Xft/fontconfig for text rendering with automatic font fallback: if the primary font
/// lacks a glyph, fontconfig searches for a suitable substitute and caches it in the font chain.
/// All drawing happens to an off-screen Pixmap, then `map()` blits it to a window in one
/// XCopyArea call to avoid flicker.
const std = @import("std");
const x11 = @import("x11.zig");
const c = x11.c;

/// Unicode replacement character, returned when a byte sequence is not valid UTF-8.
const UTF_INVALID: u21 = 0xFFFD;
/// Maximum number of bytes in a single UTF-8 encoded codepoint.
const UTF_SIZ: usize = 4;

/// A loaded Xft font with its metrics. Fonts form a singly-linked list so that text rendering
/// can walk the chain to find fallback glyphs when the primary font lacks a character.
pub const Font = struct {
    dpy: *x11.Display,
    h: c_uint, // height (ascent + descent) in pixels
    xfont: *x11.XftFont,
    pattern: ?*x11.FcPattern, // only non-null for fonts loaded by name (needed for fallback queries)
    next: ?*Font, // next fallback font in the chain
};

/// Wrapper around an X11 cursor handle, so the WM can manage cursor lifetimes uniformly.
pub const CursorHandle = struct {
    cursor: x11.Cursor,
};

/// Indices into a color scheme array — every scheme has at least foreground, background, and border.
pub const ColFg = 0;
pub const ColBg = 1;
pub const ColBorder = 2;

/// Alias for XftColor; each Color holds both an Xft rendering color and its X pixel value.
pub const Color = x11.XftColor;

/// Central drawing context. Owns an off-screen Pixmap and a GC; all rendering (text, rectangles)
/// goes to the Pixmap first, then `map()` copies the result to a visible window in one
/// XCopyArea, eliminating flicker.
pub const DrawContext = struct {
    w: c_uint, // pixmap width
    h: c_uint, // pixmap height
    dpy: *x11.Display,
    screen: c_int,
    root: x11.Window,
    drawable: x11.Drawable, // off-screen pixmap we composite into
    gc: x11.GC,
    scheme: ?[*]Color, // currently active color scheme (fg, bg, border)
    fonts: ?*Font, // head of the font fallback chain

    /// Allocate a new drawing context with an off-screen Pixmap of the given dimensions.
    /// The Pixmap serves as a double-buffer: we draw into it, then blit to the target window.
    pub fn create(dpy: *x11.Display, screen: c_int, root: x11.Window, w: c_uint, h: c_uint) !*DrawContext {
        const alloc = std.heap.c_allocator;
        const drw = try alloc.create(DrawContext);
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

    /// Recreate the off-screen Pixmap at a new size (e.g. after a screen resolution change).
    pub fn resize(self: *DrawContext, w: c_uint, h: c_uint) void {
        self.w = w;
        self.h = h;
        if (self.drawable != 0) {
            _ = c.XFreePixmap(self.dpy, self.drawable);
        }
        self.drawable = c.XCreatePixmap(self.dpy, self.root, w, h, @intCast(c.DefaultDepth(self.dpy, self.screen)));
    }

    /// Release all X resources (Pixmap, GC) and free the font chain, then deallocate self.
    pub fn free(self: *DrawContext) void {
        _ = c.XFreePixmap(self.dpy, self.drawable);
        _ = c.XFreeGC(self.dpy, self.gc);
        fontsetFree(self.fonts);
        std.heap.c_allocator.destroy(self);
    }

    /// Load a list of fonts by name and chain them together for fallback rendering.
    /// Fonts are linked in the order given so the first font in the array is tried first.
    pub fn fontsetCreate(self: *DrawContext, font_names: []const [*:0]const u8) ?*Font {
        var ret: ?*Font = null;
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

    /// Measure the pixel width a string would occupy without actually drawing it.
    /// Used by the bar to compute layout positions before rendering.
    pub fn fontsetGetWidth(self: *DrawContext, txt: [*:0]const u8) c_uint {
        if (self.fonts == null) return 0;
        return @intCast(self.text(0, 0, 0, 0, 0, txt, false));
    }

    /// Allocate a single named X color via Xft. Panics if the color name is invalid,
    /// since an unresolvable color in the config is a fatal misconfiguration.
    pub fn colorCreate(self: *DrawContext, dest: *Color, color_name: [*:0]const u8) void {
        if (c.XftColorAllocName(
            self.dpy,
            c.DefaultVisual(self.dpy, self.screen),
            c.DefaultColormap(self.dpy, self.screen),
            color_name,
            dest,
        ) == 0) {
            std.debug.panic("error, cannot allocate color '{s}'", .{color_name});
        }
    }

    /// Create a complete color scheme (fg, bg, border, ...) from an array of color name strings.
    /// Returns a pointer to the allocated Color array, indexed by ColFg/ColBg/ColBorder.
    pub fn schemeCreate(self: *DrawContext, color_names: []const [*:0]const u8) ?[*]Color {
        if (color_names.len < 2) return null;
        const alloc = std.heap.c_allocator;
        const ret = alloc.alloc(Color, color_names.len) catch return null;
        for (color_names, 0..) |name, i| {
            self.colorCreate(&ret[i], name);
        }
        return ret.ptr;
    }

    /// Switch the active font chain. Allows the WM to temporarily use a different font set.
    pub fn setFontset(self: *DrawContext, set: ?*Font) void {
        self.fonts = set;
    }

    /// Switch the active color scheme used by subsequent `text()` and `rect()` calls.
    pub fn setScheme(self: *DrawContext, color_scheme: ?[*]Color) void {
        self.scheme = color_scheme;
    }

    /// Draw a rectangle on the off-screen Pixmap. Used for tag indicators and status separators.
    pub fn rect(self: *DrawContext, x: c_int, y: c_int, w: c_uint, h: c_uint, filled: bool, invert: bool) void {
        const scheme_ptr = self.scheme orelse return;
        _ = c.XSetForeground(self.dpy, self.gc, if (invert) scheme_ptr[ColBg].pixel else scheme_ptr[ColFg].pixel);
        if (filled) {
            _ = c.XFillRectangle(self.dpy, self.drawable, self.gc, x, y, w, h);
        } else {
            _ = c.XDrawRectangle(self.dpy, self.drawable, self.gc, x, y, w -| 1, h -| 1);
        }
    }

    /// Render a UTF-8 string onto the off-screen Pixmap with font fallback, or measure its width
    /// without rendering. This is the core text routine: it walks the font chain per-codepoint,
    /// discovers missing glyphs, queries fontconfig for substitutes, and appends them to the chain
    /// for future reuse. When the text is too wide for the available space, it truncates with "...".
    ///
    /// If all positional args (x, y, w, h) are zero the function measures only and returns the
    /// total pixel width; otherwise it draws and returns x + remaining_width.
    pub fn text(self: *DrawContext, x_arg: c_int, y_arg: c_int, w_arg: c_uint, h_arg: c_uint, lpad: c_uint, text_str: [*:0]const u8, invert: bool) c_int {
        var buf: [1024]u8 = undefined;
        var extent_width: c_uint = 0;
        var xft_draw: ?*x11.XftDraw = null;
        var usedfont: *Font = undefined;
        var nextfont: ?*Font = null;

        const scheme_ptr = self.scheme orelse return 0;
        const fonts_ptr = self.fonts orelse return 0;
        const render = x_arg != 0 or y_arg != 0 or w_arg != 0 or h_arg != 0;
        if (!render and text_str[0] == 0) return 0;

        var x = x_arg;
        var w: c_uint = w_arg;

        if (!render) {
            w = ~w; // set w to max value so measurement is unconstrained
        } else {
            _ = c.XSetForeground(self.dpy, self.gc, if (invert) scheme_ptr[ColFg].pixel else scheme_ptr[ColBg].pixel);
            _ = c.XFillRectangle(self.dpy, self.drawable, self.gc, x_arg, y_arg, w_arg, h_arg);
            xft_draw = c.XftDrawCreate(
                self.dpy,
                self.drawable,
                c.DefaultVisual(self.dpy, self.screen),
                c.DefaultColormap(self.dpy, self.screen),
            );
            x += @intCast(lpad);
            w -= lpad;
        }

        // Main rendering loop: consume text in runs of characters that share the same font,
        // then render each run. When a glyph isn't found in any loaded font, ask fontconfig
        // for a fallback and append it to the font chain for future reuse.
        usedfont = fonts_ptr;
        var cur_text: [*]const u8 = text_str;
        while (true) {
            var utf8strlen: usize = 0;
            const utf8str = cur_text; // start of current same-font run
            nextfont = null;
            var charexists: bool = false;

            while (cur_text[0] != 0) {
                var utf8codepoint: u21 = 0;
                const utf8charlen = utf8Decode(cur_text, &utf8codepoint);
                var found = false;

                var curfont_it: ?*Font = self.fonts;
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
                fontGetExtents(usedfont, utf8str, @intCast(utf8strlen), &extent_width, null);
                const max_len = @min(utf8strlen, buf.len - 1);
                var len = max_len;
                while (len > 0 and extent_width > w) {
                    len -= 1;
                    fontGetExtents(usedfont, utf8str, @intCast(len), &extent_width, null);
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
                            xft_draw,
                            &scheme_ptr[if (invert) ColBg else ColFg],
                            usedfont.xfont,
                            x,
                            ty,
                            &buf,
                            @intCast(len),
                        );
                    }
                    x += @intCast(extent_width);
                    w -= extent_width;
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
                                    var last: *Font = f;
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

        if (xft_draw) |draw| c.XftDrawDestroy(draw);
        return x + (if (render) @as(c_int, @intCast(w)) else 0);
    }

    /// Copy a region of the off-screen Pixmap to a visible window. This is the final
    /// "present" step that makes drawing visible, and is what gives us flicker-free updates.
    pub fn map(self: *DrawContext, win: x11.Window, x: c_int, y: c_int, w: c_uint, h: c_uint) void {
        _ = c.XCopyArea(self.dpy, self.drawable, win, self.gc, x, y, w, h, x, y);
        _ = c.XSync(self.dpy, x11.False);
    }

    /// Create a standard X cursor from a font glyph shape (e.g. left_ptr, sizing, fleur).
    pub fn curCreate(self: *DrawContext, shape: c_int) !*CursorHandle {
        const alloc = std.heap.c_allocator;
        const cur = try alloc.create(CursorHandle);
        cur.* = .{
            .cursor = c.XCreateFontCursor(self.dpy, @intCast(shape)),
        };
        return cur;
    }

    /// Free an X cursor and its wrapper allocation.
    pub fn curFree(self: *DrawContext, cur: *CursorHandle) void {
        _ = c.XFreeCursor(self.dpy, cur.cursor);
        std.heap.c_allocator.destroy(cur);
    }
};

/// Load a single Xft font either by name or from a pre-matched fontconfig pattern.
/// Rejects color (emoji) fonts since they render poorly at bar-height sizes and can
/// cause visual artifacts in the status area.
fn xfontCreate(drw: *DrawContext, fontname: ?[*:0]const u8, fontpattern: ?*x11.FcPattern) ?*Font {
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

    // Reject color fonts (e.g. emoji) — they render poorly at small bar sizes
    var is_color: c.FcBool = undefined;
    if (c.FcPatternGetBool(xfont.?.*.pattern, x11.FC_COLOR, 0, &is_color) == x11.FcResultMatch and is_color != 0) {
        c.XftFontClose(drw.dpy, xfont);
        return null;
    }

    const font = alloc.create(Font) catch return null;
    font.* = .{
        .xfont = xfont.?,
        .pattern = pattern,
        .h = @intCast(xfont.?.*.ascent + xfont.?.*.descent),
        .dpy = drw.dpy,
        .next = null,
    };
    return font;
}

/// Close an Xft font and free its fontconfig pattern and Font allocation.
fn xfontFree(font: ?*Font) void {
    const f = font orelse return;
    if (f.pattern) |p| c.FcPatternDestroy(p);
    c.XftFontClose(f.dpy, f.xfont);
    std.heap.c_allocator.destroy(f);
}

/// Recursively free an entire font fallback chain (tail-first so each font is valid
/// while its successors are being freed).
pub fn fontsetFree(font: ?*Font) void {
    const f = font orelse return;
    fontsetFree(f.next);
    xfontFree(f);
}

/// Query the pixel extents (width and/or height) of a UTF-8 string rendered in the given font.
/// This is a thin wrapper around XftTextExtentsUtf8 that returns values through optional out-params.
pub fn fontGetExtents(font: *Font, text_ptr: [*]const u8, len: c_uint, w: ?*c_uint, h: ?*c_uint) void {
    var ext: x11.XGlyphInfo = undefined;
    c.XftTextExtentsUtf8(font.dpy, font.xfont, text_ptr, @intCast(len), &ext);
    if (w) |wp| wp.* = @intCast(ext.xOff);
    if (h) |hp| hp.* = font.h;
}

/// Decode one UTF-8 codepoint from a byte stream, returning the number of bytes consumed.
/// Invalid sequences yield UTF_INVALID (U+FFFD) and consume one byte, so the caller always
/// makes forward progress. This manual decoder exists because we pass raw `[*]const u8`
/// pointers from C strings that Zig's stdlib UTF-8 iterators cannot consume directly.
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
