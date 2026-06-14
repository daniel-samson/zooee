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
const geometry = @import("../geometry.zig");
const text = @import("../text.zig");

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

/// Image fit modes (#122): a wide 4×2 image drawn COVER (crops to fill a
/// square) and CONTAIN (letterboxed in a square), nearest sampling. Not in
/// `all`; the GPU checks compare vs the raster reference.
pub fn drawImageFit(b: Backend, s: f32) !void {
    const px = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255, // r g b y
        0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 128, 128, 128, 255, // c m w grey
    };
    const tex = try b.createTexture(4, 2, &px);
    defer b.destroyTexture(tex);
    b.drawImageFit(.{ .x = 1 * s, .y = 1 * s, .width = 6 * s, .height = 6 * s }, tex, 4, 2, .cover, .nearest);
    b.drawImageFit(.{ .x = 8 * s, .y = 1 * s, .width = 6 * s, .height = 6 * s }, tex, 4, 2, .contain, .nearest);
}

/// Bilinear sampling (#122): a tiny 2×2 image upscaled into a large rect with
/// LINEAR filtering — smooth color gradients between the 4 texels. CPU and GPU
/// agree only within a small edge tolerance (the classic non-exact case), so
/// the GPU checks allow ~0.06. Not in `all`.
pub fn drawImageBilinear(b: Backend, s: f32) !void {
    const px = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255, // red,  green
        0, 0, 255, 255, 255, 255, 0, 255, // blue, yellow
    };
    const tex = try b.createTexture(2, 2, &px);
    defer b.destroyTexture(tex);
    b.drawImageUv(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 8 * s }, tex, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .linear);
}

/// 9-slice scaling (#122): an 8×8 texture with a 2px border ring is stretched
/// into a wide "button" rect — corners stay 2px and sharp, edges stretch along
/// one axis, the center fills the rest. All 9 patches use nearest sampling, so
/// it's pixel-exact across backends. Not in `all`.
pub fn drawNineSlice(b: Backend, s: f32) !void {
    // Build an 8×8 RGBA texture: a 2px dark-blue border around a light fill.
    var px: [8 * 8 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            const border = i < 2 or i >= 6 or j < 2 or j >= 6;
            const o = (i * 8 + j) * 4;
            if (border) {
                px[o + 0] = 40;
                px[o + 1] = 60;
                px[o + 2] = 160;
            } else {
                px[o + 0] = 200;
                px[o + 1] = 220;
                px[o + 2] = 255;
            }
            px[o + 3] = 255;
        }
    }
    const tex = try b.createTexture(8, 8, &px);
    defer b.destroyTexture(tex);
    b.drawImageNine(.{ .x = 1 * s, .y = 1 * s, .width = 12 * s, .height = 5 * s }, tex, 8, 8, .{ .l = 2, .t = 2, .r = 2, .b = 2 });
}

/// Scroll viewport (#96): a tall list of colored rows inside a short clipped
/// window, panned by a scroll offset. The clip cuts the rows that fall outside
/// the viewport (including partially-visible top/bottom rows); the translate
/// pans the content. Exercises clip+translate composition. Not in `all`.
pub fn drawScroll(b: Backend, s: f32) !void {
    const colors = [_]Color{
        Color.rgb(220, 60, 60),  Color.rgb(220, 150, 40), Color.rgb(220, 210, 40),
        Color.rgb(60, 190, 80),  Color.rgb(40, 160, 210), Color.rgb(70, 80, 220),
        Color.rgb(160, 70, 200), Color.rgb(210, 70, 150),
    };
    // Viewport: a 10×6 window with a 1px frame, scrolled down by 3 units.
    const vp: geometry.Rect = .{ .x = 1 * s, .y = 1 * s, .width = 10 * s, .height = 6 * s };
    b.drawRect(vp, .{ .border = .all(1, Color.rgb(80, 80, 80)) });
    b.pushClip(.{ .x = 1 * s + s, .y = 1 * s + s, .width = 10 * s - 2 * s, .height = 6 * s - 2 * s });
    b.pushTranslate(0, -3 * s);
    var i: usize = 0;
    while (i < colors.len) : (i += 1) {
        const y = 1 * s + s + @as(f32, @floatFromInt(i)) * (2 * s);
        b.drawRect(.{ .x = 1 * s + s, .y = y, .width = 8 * s, .height = 1.6 * s }, .{ .background = colors[i] });
    }
    b.popTranslate();
    b.popClip();
}

const TextMeasureCtx = struct {
    b: Backend,
    style: style.TextStyle,
    fn measure(ctx: *const anyopaque, str: []const u8) f32 {
        const self: *const TextMeasureCtx = @ptrCast(@alignCast(ctx));
        return self.b.measureText(str, self.style).width;
    }
};

/// Text layout (#115): a paragraph word-wrapped to a width, plus a
/// right-aligned line below it — exercises the wrap + alignment pass through
/// each backend's glyph renderer. Wrapping uses measureText, identical across
/// backends, so the GPU output matches raster within the text AA tolerance.
pub fn drawTextLayout(b: Backend, s: f32) !void {
    const ts: style.TextStyle = .{ .size = 2.2 * s, .color = Color.rgb(30, 30, 40) };
    var ctx: TextMeasureCtx = .{ .b = b, .style = ts };
    const m: text.Measurer = .{ .ctx = &ctx, .measure_fn = TextMeasureCtx.measure };
    const para = "the quick brown fox jumps over the lazy dog";
    const line_h = b.measureText("Ag", ts).height;
    var buf: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var lay = try text.layout(fba.allocator(), para, m, .{ .max_width = 20 * s, .@"align" = .left, .line_height = line_h });
    defer lay.deinit(fba.allocator());
    const ox = 1 * s;
    const oy = 1 * s;
    for (lay.lines) |ln| {
        b.drawText(.{ .x = ox + ln.x, .y = oy + ln.y }, ln.slice(para), ts);
    }
    // A right-aligned short line under the paragraph.
    var lay2 = try text.layout(fba.allocator(), "end.", m, .{ .max_width = 20 * s, .@"align" = .right, .line_height = line_h });
    defer lay2.deinit(fba.allocator());
    const oy2 = oy + lay.height + line_h;
    for (lay2.lines) |ln| {
        b.drawText(.{ .x = ox + ln.x, .y = oy2 + ln.y }, ln.slice("end."), ts);
    }
}

/// Text decorations (#191): underlined and struck-through text. The glyphs are
/// AA; the decoration lines are hard-edged rects positioned by the shared
/// formula, so the GPU backends match the raster reference within the text
/// tolerance. Not in `all`.
pub fn drawTextDecoration(b: Backend, s: f32) !void {
    b.drawText(.{ .x = 1 * s, .y = 1 * s }, "Under", .{ .size = 2.5 * s, .underline = true, .color = Color.rgb(30, 30, 40) });
    b.drawText(.{ .x = 1 * s, .y = 5 * s }, "Strike", .{ .size = 2.5 * s, .strikethrough = true, .color = Color.rgb(180, 40, 40) });
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

/// Multi-stop linear gradient (#118): a 4-stop red→yellow→green→blue band.
pub fn drawGradientStops(b: Backend, s: f32) !void {
    var g: style.Gradient = .{ .kind = .linear, .axis = .horizontal, .stop_count = 4 };
    g.stops[0] = .{ .offset = 0.0, .color = Color.rgb(220, 40, 40) };
    g.stops[1] = .{ .offset = 0.33, .color = Color.rgb(230, 200, 40) };
    g.stops[2] = .{ .offset = 0.66, .color = Color.rgb(40, 180, 80) };
    g.stops[3] = .{ .offset = 1.0, .color = Color.rgb(40, 60, 220) };
    b.drawRect(.{ .x = 1 * s, .y = 1 * s, .width = 8 * s, .height = 4 * s }, .{ .gradient = g });
}

/// Radial gradient (#118): white center → blue edge, centered in the rect.
pub fn drawRadialGradient(b: Backend, s: f32) !void {
    var g: style.Gradient = .{ .kind = .radial, .cx = 0.5, .cy = 0.5, .radius = 0.5, .stop_count = 2 };
    g.stops[0] = .{ .offset = 0, .color = Color.white };
    g.stops[1] = .{ .offset = 1, .color = Color.rgb(40, 60, 220) };
    b.drawRect(.{ .x = 1 * s, .y = 1 * s, .width = 7 * s, .height = 7 * s }, .{ .gradient = g });
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

/// Build a 5-point star centered at (cx,cy), outer radius R, inner r — a
/// concave self-overlap-free polygon that exercises the even-odd fill (#120).
pub fn star(cx: f32, cy: f32, R: f32, r: f32) [10]geometry.Point {
    var pts: [10]geometry.Point = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const ao = -std.math.pi / 2.0 + fi * (2.0 * std.math.pi / 5.0);
        const ai = ao + std.math.pi / 5.0;
        pts[i * 2] = .{ .x = cx + R * @cos(ao), .y = cy + R * @sin(ao) };
        pts[i * 2 + 1] = .{ .x = cx + r * @cos(ai), .y = cy + r * @sin(ai) };
    }
    return pts;
}

/// Filled arbitrary path (#120): a concave 5-point star, even-odd fill. Not in
/// `all` (cross-harness goldens); the GPU checks compare vs the raster reference.
pub fn drawPath(b: Backend, s: f32) !void {
    const pts = star(5 * s, 5 * s, 4 * s, 1.7 * s);
    b.fillPath(&pts, Color.rgb(230, 170, 30));
}

/// Stroked polyline (#120): an open checkmark plus a closed triangle ring,
/// exercising round caps/joins and the closed flag. Not in `all`.
pub fn drawStroke(b: Backend, s: f32) !void {
    const check = [_]geometry.Point{ .{ .x = 1.5 * s, .y = 5 * s }, .{ .x = 3.5 * s, .y = 7 * s }, .{ .x = 7.5 * s, .y = 2.5 * s } };
    b.strokePath(&check, 1.3 * s, Color.rgb(40, 160, 70), false);
    const tri = [_]geometry.Point{ .{ .x = 5 * s, .y = 8 * s }, .{ .x = 9 * s, .y = 8 * s }, .{ .x = 7 * s, .y = 9.5 * s } };
    b.strokePath(&tri, 1.0 * s, Color.rgb(60, 90, 220), true);
}

/// Box shadow (#119): a filled rect with an offset, blurred shadow behind it.
/// Not in `all` (cross-harness goldens); the GPU checks build a local Scene and
/// compare the analytic shadow coverage vs the raster reference.
pub fn drawBoxShadow(b: Backend, s: f32) !void {
    b.drawRect(.{ .x = 3 * s, .y = 3 * s, .width = 5 * s, .height = 5 * s }, .{
        .background = Color.rgb(60, 130, 240),
        .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 160 }, .dx = 1 * s, .dy = 1.5 * s, .blur = 2 * s },
    });
}

/// Inset box shadow (#119): a light-grey rounded rect with an inset shadow —
/// a pressed "well", shadow hugging the inner edges, clipped to the rounding.
pub fn drawInsetShadow(b: Backend, s: f32) !void {
    b.drawRect(.{ .x = 2 * s, .y = 2 * s, .width = 7 * s, .height = 6 * s }, .{
        .background = Color.rgb(225, 228, 232),
        .corner_radius = .all(1.5 * s),
        .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 130 }, .dy = 0.5 * s, .blur = 2 * s, .corner_radius = 1.5 * s, .inset = true },
    });
}

/// Rounded box shadow (#119): a rounded card on a blurred, rounded-corner
/// shadow (Wallace integral). Not in `all`.
pub fn drawRoundedShadow(b: Backend, s: f32) !void {
    b.drawRect(.{ .x = 3 * s, .y = 2.5 * s, .width = 6 * s, .height = 6 * s }, .{
        .background = Color.white,
        .corner_radius = .all(1.6 * s),
        .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 150 }, .dy = 1 * s, .blur = 2.2 * s, .corner_radius = 1.6 * s },
    });
}

/// Layout-integrated effects (#117/#121/#118): a column of three leaves built
/// through the layout engine — a gradient header, a rounded-clipped fill, and
/// a half-opacity group — exercising Element.gradient/clip_radius/opacity and
/// their balanced push/pop in render(). Verifies the layout path matches
/// raster pixel-exact, not just the imperative primitive checks. Not in `all`.
pub fn drawLayoutEffects(b: Backend, s: f32) !void {
    const header: layout.Element = .{
        .width = 12 * s,
        .height = 3 * s,
        .rect_style = .{ .gradient = .{ .axis = .horizontal, .from = Color.rgb(220, 40, 40), .to = Color.rgb(40, 60, 220) } },
    };
    const clipbox: layout.Element = .{
        .width = 8 * s,
        .height = 5 * s,
        .clip_radius = .all(2 * s),
        .rect_style = .{ .background = Color.rgb(40, 180, 90) },
    };
    const opacity_group: layout.Element = .{
        .width = 12 * s,
        .height = 3 * s,
        .opacity = 0.5,
        .rect_style = .{ .background = Color.rgb(40, 60, 220) },
    };
    const root: layout.Element = .{
        .direction = .column,
        .padding = .all(1 * s),
        .gap = 1 * s,
        .children = &.{ &header, &clipbox, &opacity_group },
    };
    const gpa = std.heap.page_allocator;
    var result = try layout.layout(gpa, b, &root, .{ .width = 14 * s, .height = 15 * s });
    defer result.deinit(gpa);
    layout.render(b, result);
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
