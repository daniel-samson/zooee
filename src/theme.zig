//! Theme tokens (#170 follow-up / theming): one source of truth for the
//! framework's semantic colors, so the default window background, surfaces,
//! text, and accents are consistent instead of hard-coded per backend or per
//! app. The framework drives each backend's clear color from `background`, and
//! apps build their UI from the same tokens, so the backdrop, the exposed area
//! during a resize-grow, and the content all agree.
//!
//! Text only covers color for now; spacing/typography tokens and per-widget
//! roles can extend this without reshaping callers.

const Color = @import("style.zig").Color;

/// Semantic color roles. Build UI from these, not raw literals, so a theme
/// swap (light ⇆ dark) recolors everything coherently.
pub const Theme = struct {
    /// Window / app backdrop — also the backend clear color, so newly-exposed
    /// regions during a resize match the content.
    background: Color,
    /// Raised containers: cards, panels, sheets.
    surface: Color,
    /// Subtle fills on a surface: inputs, tracks, wells.
    surface_variant: Color,
    /// Primary body text.
    text: Color,
    /// Secondary / de-emphasized text.
    text_muted: Color,
    /// Interactive accent (focus, primary action) — ideally the OS accent.
    accent: Color,
    /// Text/icon drawn on top of `accent`.
    on_accent: Color,
    /// Text-selection highlight — a lighter tint of the accent.
    selection: Color,
    /// Color of text drawn inside a selection highlight.
    selection_text: Color,
    /// Hairlines and container outlines.
    border: Color,
    /// Destructive / error accent.
    danger: Color,

    /// The default light theme. Apple-ish system palette (systemBlue / labels).
    pub const light: Theme = .{
        .background = Color.rgb(242, 242, 247),
        .surface = Color.rgb(255, 255, 255),
        .surface_variant = Color.rgb(229, 229, 234),
        .text = Color.rgb(0, 0, 0),
        .text_muted = Color.rgb(110, 110, 118),
        .accent = Color.rgb(0, 122, 255),
        .on_accent = Color.rgb(255, 255, 255),
        .selection = Color.rgb(179, 212, 252), // accent lightened (pale blue)
        .selection_text = Color.rgb(0, 0, 0),
        .border = Color.rgb(198, 198, 200),
        .danger = Color.rgb(255, 59, 48),
    };

    /// The dark theme — tuned to the macOS dark system palette (the reference).
    pub const dark: Theme = .{
        .background = Color.rgb(28, 28, 30), // windowBackground
        .surface = Color.rgb(44, 44, 46), // secondarySystemBackground (cards)
        .surface_variant = Color.rgb(58, 58, 60), // tertiary fill (tracks/wells)
        .text = Color.rgb(255, 255, 255), // label
        .text_muted = Color.rgb(152, 152, 157), // secondaryLabel
        .accent = Color.rgb(10, 132, 255), // systemBlue (dark)
        .on_accent = Color.rgb(255, 255, 255),
        .selection = Color.rgb(48, 90, 150), // muted accent for dark backdrops
        .selection_text = Color.rgb(255, 255, 255),
        .border = Color.rgb(64, 64, 67), // separator
        .danger = Color.rgb(255, 69, 58), // systemRed (dark)
    };

    /// Lighten a color toward white by `t` (0 = unchanged, 1 = white) — used to
    /// derive the selection tint from the accent.
    pub fn lighten(c: Color, t: f32) Color {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c.r)) + (255 - @as(f32, @floatFromInt(c.r))) * t),
            .g = @intFromFloat(@as(f32, @floatFromInt(c.g)) + (255 - @as(f32, @floatFromInt(c.g))) * t),
            .b = @intFromFloat(@as(f32, @floatFromInt(c.b)) + (255 - @as(f32, @floatFromInt(c.b))) * t),
            .a = c.a,
        };
    }

    /// Derive a copy of `self` using the OS accent color: sets `accent` and a
    /// lightened `selection`, so the app picks up the user's system accent
    /// (#318). `selection_text` keeps the theme's value (readable on the tint).
    pub fn withAccent(self: Theme, accent_color: Color) Theme {
        var t = self;
        t.accent = accent_color;
        // Light themes want a pale selection; dark themes a muted-darker one.
        const is_light = @as(u32, self.background.r) + self.background.g + self.background.b > 384;
        t.selection = if (is_light) lighten(accent_color, 0.62) else mixToward(accent_color, self.background, 0.45);
        return t;
    }

    /// Blend `c` toward `dst` by `t`.
    fn mixToward(c: Color, dst: Color, t: f32) Color {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c.r)) + (@as(f32, @floatFromInt(dst.r)) - @as(f32, @floatFromInt(c.r))) * t),
            .g = @intFromFloat(@as(f32, @floatFromInt(c.g)) + (@as(f32, @floatFromInt(dst.g)) - @as(f32, @floatFromInt(c.g))) * t),
            .b = @intFromFloat(@as(f32, @floatFromInt(c.b)) + (@as(f32, @floatFromInt(dst.b)) - @as(f32, @floatFromInt(c.b))) * t),
            .a = c.a,
        };
    }

    /// The background as a premultiplied-free RGBA float quad — the form the GPU
    /// backends' clear paths want.
    pub fn clearRgba(self: Theme) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.background.r)) / 255.0,
            @as(f32, @floatFromInt(self.background.g)) / 255.0,
            @as(f32, @floatFromInt(self.background.b)) / 255.0,
            1.0,
        };
    }
};

// === Tests ==================================================================

const std = @import("std");
const testing = std.testing;

test "light and dark are distinct across every role" {
    const l = Theme.light;
    const d = Theme.dark;
    inline for (std.meta.fields(Theme)) |f| {
        if (f.type != Color) continue;
        const lc = @field(l, f.name);
        const dc = @field(d, f.name);
        // on_accent is intentionally shared (white-on-accent in both).
        if (comptime std.mem.eql(u8, f.name, "on_accent")) continue;
        try testing.expect(lc.r != dc.r or lc.g != dc.g or lc.b != dc.b);
    }
}

test "clearRgba mirrors the background token" {
    const c = Theme.light.clearRgba();
    try testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(Theme.light.background.r)) / 255.0), c[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(Theme.light.background.b)) / 255.0), c[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), c[3], 1e-4);
}
