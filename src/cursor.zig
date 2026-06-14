//! Pointer cursor shapes (#123). A region (`layout.Element.cursor`) requests a
//! shape; the app loop hit-tests the pointer each move and asks the window to
//! apply it. The set mirrors the CSS `cursor` keywords so the web backend (#15)
//! maps 1:1, and each native platform maps to its own system cursor (macOS
//! `NSCursor`, Windows `IDC_*`, X11 cursor font).
//!
//! Core *decides* the shape (hit-test); the window *applies* the OS cursor —
//! the same decide/render split the backends follow.

const std = @import("std");

/// A pointer cursor shape. Names follow the CSS `cursor` property. Platforms
/// without an exact match fall back to the nearest system cursor (documented
/// per-platform at the `setCursor` call sites).
pub const Cursor = enum {
    /// The platform default arrow.
    default,
    /// Clickable affordance — the hand/pointing cursor (CSS `pointer`).
    pointer,
    /// Text selection I-beam.
    text,
    /// Precision crosshair.
    crosshair,
    /// Action not allowed (no-drop circle/slash).
    not_allowed,
    /// Something grabbable (open hand).
    grab,
    /// Something being grabbed (closed hand).
    grabbing,
    /// Horizontal resize (↔), e.g. a vertical splitter / column edge.
    ew_resize,
    /// Vertical resize (↕), e.g. a horizontal splitter / row edge.
    ns_resize,
    /// Diagonal resize (⤡), top-left ⇄ bottom-right corner.
    nwse_resize,
    /// Diagonal resize (⤢), top-right ⇄ bottom-left corner.
    nesw_resize,
    /// Busy/wait.
    wait,

    /// The CSS keyword for this shape — the web backend (#15) emits this.
    pub fn cssName(self: Cursor) []const u8 {
        return switch (self) {
            .default => "default",
            .pointer => "pointer",
            .text => "text",
            .crosshair => "crosshair",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
            .ew_resize => "ew-resize",
            .ns_resize => "ns-resize",
            .nwse_resize => "nwse-resize",
            .nesw_resize => "nesw-resize",
            .wait => "wait",
        };
    }
};

test "every cursor maps to a CSS keyword" {
    inline for (std.meta.fields(Cursor)) |f| {
        const c: Cursor = @enumFromInt(f.value);
        try std.testing.expect(c.cssName().len > 0);
    }
    try std.testing.expectEqualStrings("not-allowed", Cursor.not_allowed.cssName());
    try std.testing.expectEqualStrings("ew-resize", Cursor.ew_resize.cssName());
}
