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
    /// Interactive accent (selection, focus, primary action).
    accent: Color,
    /// Text/icon drawn on top of `accent`.
    on_accent: Color,
    /// Hairlines and container outlines.
    border: Color,

    /// The default light theme — matches the historical demo palette so it's a
    /// drop-in for the previously hard-coded literals.
    pub const light: Theme = .{
        .background = Color.rgb(238, 240, 245),
        .surface = Color.rgb(255, 255, 255),
        .surface_variant = Color.rgb(235, 237, 242),
        .text = Color.rgb(30, 30, 40),
        .text_muted = Color.rgb(110, 110, 130),
        .accent = Color.rgb(0, 120, 255),
        .on_accent = Color.rgb(255, 255, 255),
        .border = Color.rgb(120, 120, 130),
    };

    /// A dark counterpart with matched roles.
    pub const dark: Theme = .{
        .background = Color.rgb(24, 26, 32),
        .surface = Color.rgb(36, 38, 46),
        .surface_variant = Color.rgb(44, 47, 56),
        .text = Color.rgb(232, 234, 240),
        .text_muted = Color.rgb(150, 154, 168),
        .accent = Color.rgb(70, 150, 250),
        .on_accent = Color.rgb(255, 255, 255),
        .border = Color.rgb(70, 74, 86),
    };

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
    try testing.expectApproxEqAbs(@as(f32, 238.0 / 255.0), c[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 245.0 / 255.0), c[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), c[3], 1e-4);
}
