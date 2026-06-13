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
const layout = @import("../layout.zig");

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
    .{ .name = "sides", .width = 14, .height = 6, .draw = drawSides },
    .{ .name = "layout_card", .width = 24, .height = 8, .draw = drawLayoutCard },
    .{ .name = "hello_text", .width = 20, .height = 4, .draw = drawHelloText },
    .{ .name = "image", .width = 10, .height = 6, .draw = drawImage },
};

/// A bordered, rounded "card" with a title — the hello-world scene.
fn drawCard(b: Backend, s: f32) !void {
    b.drawRect(
        .{ .x = 1 * s, .y = 1 * s, .width = 22 * s, .height = 5 * s },
        .{ .background = Color.white, .border = .all(1, .black), .corner_radius = .all(2 * s) },
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

/// Per-side borders (CSS-style): distinct colors per side, no bottom
/// border at all, only the top-left corner rounded.
fn drawSides(b: Backend, s: f32) !void {
    b.drawRect(
        .{ .x = 1 * s, .y = 1 * s, .width = 12 * s, .height = 4 * s },
        .{
            .border = .{
                .top = .{ .width = 1, .color = Color.rgb(255, 0, 0) },
                .right = .{ .width = 1, .color = Color.rgb(0, 255, 0) },
                .bottom = .none,
                .left = .{ .width = 1, .color = Color.rgb(0, 0, 255) },
            },
            .corner_radius = .{ .top_left = 2 * s },
        },
    );
}

/// Texture upload + drawImage (#11/#13): a 2×2 RGBA image (top-left red,
/// top-right green, bottom-left blue, bottom-right yellow) sampled
/// nearest-neighbor into a rect. Verifies texture upload, orientation
/// (row 0 = top), and nearest sampling identically across backends.
fn drawImage(b: Backend, s: f32) !void {
    const px = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255, // row 0: red,  green
        0, 0, 255, 255, 255, 255, 0, 255, // row 1: blue, yellow
    };
    const tex = try b.createTexture(2, 2, &px);
    defer b.destroyTexture(tex);
    b.drawImage(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 4 * s }, tex);
}

/// Real text rendering (#10): glyphs on raster (font set by the
/// harness), plain characters on the terminal.
fn drawHelloText(b: Backend, s: f32) !void {
    b.drawText(.{ .x = 1 * s, .y = 1 * s }, "Zooee 1.0!", .{ .size = 2.5 * s });
}

/// Non-ASCII text (#114): accents + em-dash exercise the dynamic glyph atlas.
/// Not in `all` (which requires cross-harness goldens); the GPU self-checks
/// build a local Scene from it and compare against the raster reference, which
/// rasterizes any codepoint on demand.
pub fn drawUnicode(b: Backend, s: f32) !void {
    b.drawText(.{ .x = 1 * s, .y = 1 * s }, "café — déjà", .{ .size = 2.5 * s });
}

/// Linear gradient fill (#118): a horizontal red→blue and a vertical
/// green→white rect. Not in `all` (cross-harness goldens); the GPU checks
/// build local Scenes and compare vs the raster reference.
pub fn drawGradient(b: Backend, s: f32) !void {
    b.drawRect(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 4 * s }, .{
        .gradient = .{ .axis = .horizontal, .from = Color.rgb(220, 40, 40), .to = Color.rgb(40, 60, 220) },
    });
    b.drawRect(.{ .x = 1 * s, .y = 6 * s, .width = 8 * s, .height = 4 * s }, .{
        .gradient = .{ .axis = .vertical, .from = Color.rgb(40, 200, 80), .to = Color.white },
    });
}

/// Group opacity / offscreen layers (#121): an opaque red rect, then a
/// half-opacity layer painting an opaque blue rect across it and onto the
/// white backdrop. Not in `all` (cross-harness goldens); the GPU checks build
/// a local Scene and compare the composited result vs the raster reference.
pub fn drawGroupOpacity(b: Backend, s: f32) !void {
    b.drawRect(.{ .x = 1 * s, .y = 1 * s, .width = 5 * s, .height = 6 * s }, .{
        .background = Color.rgb(220, 40, 40),
    });
    try b.pushLayer(0.5);
    b.drawRect(.{ .x = 3 * s, .y = 1 * s, .width = 6 * s, .height = 6 * s }, .{
        .background = Color.rgb(40, 60, 220),
    });
    b.popLayer();
}

/// Rounded-rect clipping (#117): a solid fill clipped to a rounded rect, so
/// the four corners are cut. Not in `all` (cross-harness goldens); the GPU
/// checks build a local Scene and compare the clipped result vs raster.
pub fn drawRoundedClip(b: Backend, s: f32) !void {
    b.pushClipRounded(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 8 * s }, .all(3 * s));
    b.drawRect(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 8 * s }, .{
        .background = Color.rgb(40, 120, 220),
    });
    b.popClip();
}

/// Built via the layout engine (#3) rather than hand-placed draws: a
/// padded column holding a bordered text card and a row of two flex-grow
/// fills. Exercises box model, gap, text measurement, and remainder
/// distribution end-to-end on every backend.
fn drawLayoutCard(b: Backend, s: f32) !void {
    const red: layout.Element = .{ .grow = 1, .rect_style = .{ .background = Color.rgb(255, 0, 0) } };
    const green: layout.Element = .{ .grow = 1, .rect_style = .{ .background = Color.rgb(0, 255, 0) } };
    const row: layout.Element = .{
        .direction = .row,
        .gap = 1 * s,
        .grow = 1,
        .children = &.{ &red, &green },
    };
    const card: layout.Element = .{
        .rect_style = .{ .border = .all(1, .black) },
        .padding = .{ .left = 1 * s, .right = 1 * s },
        .text = "layout",
    };
    const root: layout.Element = .{
        .direction = .column,
        .padding = .all(1 * s),
        .gap = 1 * s,
        .children = &.{ &card, &row },
    };

    const gpa = std.heap.page_allocator;
    var result = try layout.layout(gpa, b, &root, .{ .width = 24 * s, .height = 8 * s });
    defer result.deinit(gpa);
    layout.render(b, result);
}

/// Drive one scene through a backend at the given scale.
pub fn run(scene: Scene, b: Backend, scale: f32) !void {
    try b.beginFrame(.{ .width = scene.width * scale, .height = scene.height * scale });
    try scene.draw(b, scale);
    try b.endFrame();
}
