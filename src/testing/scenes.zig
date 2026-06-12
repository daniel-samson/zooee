//! Shared scene fixtures (#13, #24): named scenes drawn through the
//! primitive interface, consumed by every backend's test harness so all
//! backends are verified against identical content — terminal snapshots
//! assert characters, raster goldens assert pixels, and GPU backends
//! (#11, #12, #15) will be compared against the raster output.
//!
//! Scenes use cell-scale coordinates (a terminal cell = 1 unit); the
//! raster harness multiplies through a scale factor. Once the layout
//! engine (#3) lands, scenes become widget trees instead of raw draws.

const std = @import("std");
const backend = @import("../backend.zig");
const style = @import("../style.zig");

const Backend = backend.Backend;
const Color = style.Color;

pub const Scene = struct {
    name: []const u8,
    /// Viewport in cell-scale units.
    width: f32,
    height: f32,
    draw: *const fn (b: Backend, scale: f32) anyerror!void,
};

pub const all = [_]Scene{
    .{ .name = "card", .width = 24, .height = 7, .draw = drawCard },
    .{ .name = "nested_clip", .width = 20, .height = 5, .draw = drawNestedClip },
    .{ .name = "overlap", .width = 16, .height = 6, .draw = drawOverlap },
};

/// A bordered, rounded "card" with a title — the hello-world scene.
fn drawCard(b: Backend, s: f32) !void {
    b.drawRect(
        .{ .x = 1 * s, .y = 1 * s, .width = 22 * s, .height = 5 * s },
        .{ .background = Color.white, .border = .{ .width = 1 }, .corner_radius = 2 * s },
    );
    b.drawText(.{ .x = 3 * s, .y = 3 * s }, "zooee", .{ .color = Color.black });
}

/// Two nested clips; inner content must be cut by both.
fn drawNestedClip(b: Backend, s: f32) !void {
    b.pushClip(.{ .x = 0, .y = 0, .width = 12 * s, .height = 5 * s });
    b.pushClip(.{ .x = 0, .y = 0, .width = 20 * s, .height = 2 * s });
    b.drawRect(
        .{ .x = 0, .y = 0, .width = 20 * s, .height = 5 * s },
        .{ .background = Color.rgb(0, 128, 255) },
    );
    b.popClip();
    b.popClip();
}

/// Overlapping rects: paint order must hold on every backend.
fn drawOverlap(b: Backend, s: f32) !void {
    b.drawRect(
        .{ .x = 1 * s, .y = 1 * s, .width = 9 * s, .height = 4 * s },
        .{ .background = Color.rgb(255, 0, 0) },
    );
    b.drawRect(
        .{ .x = 6 * s, .y = 2 * s, .width = 9 * s, .height = 4 * s },
        .{ .background = Color.rgb(0, 255, 0) },
    );
}

/// Drive one scene through a backend at the given scale.
pub fn run(scene: Scene, b: Backend, scale: f32) !void {
    try b.beginFrame(.{ .width = scene.width * scale, .height = scene.height * scale });
    try scene.draw(b, scale);
    try b.endFrame();
}
