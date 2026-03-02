//! Color definitions for the window manager and status bar.
//!
//! Centralises all color name strings so that appearance can be tuned in one
//! place. The WM schemes (SchemeNorm, SchemeSel) reference these, and status
//! segments define their own palettes here as well.

// ── Base palette ────────────────────────────────────────────────────────────
pub const gray1: [*:0]const u8 = "#222222";
pub const gray2: [*:0]const u8 = "#444444";
pub const gray3: [*:0]const u8 = "#bbbbbb";
pub const gray4: [*:0]const u8 = "#eeeeee";
pub const cyan: [*:0]const u8 = "#005577";

// ── WM color schemes (fg, bg, border) ───────────────────────────────────────
pub const schemes = [_][3][*:0]const u8{
    .{ gray3, gray1, gray2 }, // SchemeNorm
    .{ gray4, cyan, cyan }, // SchemeSel
};

// ── Status segment colors ───────────────────────────────────────────────────
pub const status_bg: [*:0]const u8 = gray1;

pub const bat_normal: [*:0]const u8 = "#a6e3a1"; // green — battery ok
pub const bat_warning: [*:0]const u8 = "#f9e2af"; // yellow — battery low
pub const bat_critical: [*:0]const u8 = "#f38ba8"; // red — battery critical
pub const bat_charging: [*:0]const u8 = "#89b4fa"; // blue — charging

pub const brightness_fg: [*:0]const u8 = gray3; // same as time

pub const time_fg: [*:0]const u8 = gray3;
