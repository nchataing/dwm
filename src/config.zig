/// User configuration for dwm — Zig port of suckless config.h.
/// Edit this file to customize appearance, keybindings, rules, and layouts.
/// After changes, rebuild with `zig build` and restart dwm (Mod+Shift+E).
const x11 = @import("x11.zig");
const dwm = @import("dwm.zig");
const actions = @import("actions.zig");
const layout = @import("layout.zig");

// ── Appearance ──────────────────────────────────────────────────────────────
pub const borderpx: c_uint = 1; // border pixel of windows
pub const snap: c_uint = 32; // snap pixel: proximity threshold for edge snapping during mouse moves

// ── Systray ─────────────────────────────────────────────────────────────────
pub const systraypinning: c_uint = 0; // 0: sloppy systray follows selected monitor, >0: pin systray to monitor X
pub const systrayonleft: bool = false; // false: systray in the right corner, true: systray on left of status text
pub const systrayspacing: c_uint = 2; // pixel gap between systray icons
pub const systraypinningfailfirst: bool = true; // if pinning fails, fall back to the first monitor

// ── Bar ─────────────────────────────────────────────────────────────────────
pub const showbar: bool = true; // false means no bar
pub const topbar: bool = true; // false means bottom bar

// ── Fonts ───────────────────────────────────────────────────────────────────
pub const fonts = [_][*:0]const u8{"monospace:size=10"};
pub const dmenufont: [*:0]const u8 = "monospace:size=10";

// ── Colors ──────────────────────────────────────────────────────────────────
pub const col_gray1: [*:0]const u8 = "#222222";
pub const col_gray2: [*:0]const u8 = "#444444";
pub const col_gray3: [*:0]const u8 = "#bbbbbb";
pub const col_gray4: [*:0]const u8 = "#eeeeee";
pub const col_cyan: [*:0]const u8 = "#005577";

// Color schemes: [fg, bg, border] — indexed by SchemeNorm (0) and SchemeSel (1) in dwm.zig
pub const colors = [_][3][*:0]const u8{
    .{ col_gray3, col_gray1, col_gray2 }, // SchemeNorm: unfocused windows / default bar
    .{ col_gray4, col_cyan, col_cyan }, // SchemeSel:  focused window / selected tag
};

// ── Tagging ─────────────────────────────────────────────────────────────────
// Tags are displayed in the bar; each window belongs to exactly one tag (index 0..8).
pub const tags = [_][*:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };

// ── Rules ───────────────────────────────────────────────────────────────────
// Rules match newly-mapped windows by class/instance/title and override their default
// tag assignment, floating state, and target monitor. -1 for monitor means "current".
pub const Rule = struct {
    class: ?[*:0]const u8,
    instance: ?[*:0]const u8,
    title: ?[*:0]const u8,
    tag: ?u5, // null = inherit monitor's current tag
    isfloating: bool,
    monitor: i32,
};

pub const rules = [_]Rule{
    .{ .class = "Gimp", .instance = null, .title = null, .tag = null, .isfloating = true, .monitor = -1 },
    .{ .class = "Firefox", .instance = null, .title = null, .tag = 8, .isfloating = false, .monitor = -1 },
};

// ── Layout ──────────────────────────────────────────────────────────────────
pub const master_factor: f32 = 0.6; // fraction of screen width given to master area [0.05..0.95]
pub const resizehints: bool = false; // true means respect size hints in tiled resizals (can cause gaps)
pub const lockfullscreen: bool = true; // true will force focus on the fullscreen window

// ── Key definitions ─────────────────────────────────────────────────────────
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
    dmenufont,
    "-nb",
    col_gray1,
    "-nf",
    col_gray3,
    "-sb",
    col_cyan,
    "-sf",
    col_gray4,
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
