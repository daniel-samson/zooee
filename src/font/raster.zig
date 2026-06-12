//! Glyph rasterizer (#10, slice 2): TTF outlines → anti-aliased alpha
//! bitmaps. Scanline non-zero-winding fill with vertical oversampling
//! and exact fractional horizontal coverage — compact and dependency-
//! free (the FreeType-replacement core).

const std = @import("std");
const ttf = @import("ttf.zig");

/// Vertical samples per pixel row. 4 gives smooth diagonals at text
/// sizes; horizontal AA is exact (fractional span endpoints).
const oversample = 4;

pub const Bitmap = struct {
    /// Alpha coverage, row-major, top-down.
    alpha: []u8,
    width: usize,
    height: usize,
    /// Offset from the pen position to the bitmap's top-left, in pixels:
    /// x right, y down from the baseline (negative y_off = above it).
    x_off: i32,
    y_off: i32,

    pub fn deinit(self: *Bitmap, gpa: std.mem.Allocator) void {
        gpa.free(self.alpha);
    }
};

const Edge = struct {
    // Pixel space, y-down. dir = +1 if the edge points downward.
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    dir: i2,
};

/// Rasterize a glyph outline at `pixels_per_em`.
pub fn rasterize(
    gpa: std.mem.Allocator,
    font: *const ttf.Font,
    outline: ttf.Font.Outline,
    pixels_per_em: f32,
) !Bitmap {
    const scale = pixels_per_em / @as(f32, @floatFromInt(font.units_per_em));

    // Bitmap bounds in pixel space (y flips: font y-up → bitmap y-down).
    const fx_min = @as(f32, @floatFromInt(outline.x_min)) * scale;
    const fy_max = @as(f32, @floatFromInt(outline.y_max)) * scale;
    const x_off = @floor(fx_min);
    const y_top = @floor(-fy_max); // distance below baseline of the top edge
    const width: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(outline.x_max)) * scale) - x_off + 1);
    const height: usize = @intFromFloat(@ceil(-@as(f32, @floatFromInt(outline.y_min)) * scale) - y_top + 1);

    // Flatten quadratic contours into edges in bitmap space.
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var start: usize = 0;
    for (outline.contour_ends) |end_idx| {
        const contour = outline.points[start .. @as(usize, end_idx) + 1];
        try flattenContour(gpa, &edges, contour, scale, x_off, y_top);
        start = @as(usize, end_idx) + 1;
    }

    const alpha = try gpa.alloc(u8, width * height);
    @memset(alpha, 0);
    errdefer gpa.free(alpha);

    // Coverage accumulator for one pixel row.
    const acc = try gpa.alloc(f32, width);
    defer gpa.free(acc);
    var xs_buf = try gpa.alloc(struct { x: f32, dir: i2 }, edges.items.len);
    defer gpa.free(xs_buf);

    var row: usize = 0;
    while (row < height) : (row += 1) {
        @memset(acc, 0);
        var s: usize = 0;
        while (s < oversample) : (s += 1) {
            const sy = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(s)) + 0.5) / oversample;
            // Collect crossings.
            var n: usize = 0;
            for (edges.items) |e| {
                const top = @min(e.y0, e.y1);
                const bot = @max(e.y0, e.y1);
                if (sy < top or sy >= bot) continue;
                const t = (sy - e.y0) / (e.y1 - e.y0);
                xs_buf[n] = .{ .x = e.x0 + t * (e.x1 - e.x0), .dir = e.dir };
                n += 1;
            }
            const xs = xs_buf[0..n];
            std.mem.sort(@TypeOf(xs_buf[0]), xs, {}, struct {
                fn lt(_: void, a: @TypeOf(xs_buf[0]), b: @TypeOf(xs_buf[0])) bool {
                    return a.x < b.x;
                }
            }.lt);
            // Non-zero winding spans.
            var winding: i32 = 0;
            var span_start: f32 = 0;
            for (xs) |c| {
                if (winding != 0) {
                    addSpan(acc, span_start, c.x, 1.0 / @as(f32, oversample));
                }
                if (winding == 0) span_start = c.x;
                winding += c.dir;
                if (winding != 0 and winding - c.dir == 0) span_start = c.x;
            }
        }
        for (acc, 0..) |a, x| {
            alpha[row * width + x] = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
        }
    }

    return .{
        .alpha = alpha,
        .width = width,
        .height = height,
        .x_off = @intFromFloat(x_off),
        .y_off = @intFromFloat(y_top),
    };
}

/// Add a horizontal span [x0,x1) with the given weight, fractional ends.
fn addSpan(acc: []f32, x0: f32, x1: f32, weight: f32) void {
    if (x1 <= x0) return;
    const w: f32 = @floatFromInt(acc.len);
    const a = std.math.clamp(x0, 0, w);
    const b = std.math.clamp(x1, 0, w);
    if (b <= a) return;
    const first: usize = @intFromFloat(@floor(a));
    const last: usize = @intFromFloat(@ceil(b));
    var x = first;
    while (x < last and x < acc.len) : (x += 1) {
        const px0: f32 = @floatFromInt(x);
        const cover = @min(b, px0 + 1) - @max(a, px0);
        if (cover > 0) acc[x] += cover * weight;
    }
}

fn flattenContour(
    gpa: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    contour: []const ttf.Font.Point,
    scale: f32,
    x_off: f32,
    y_top: f32,
) !void {
    if (contour.len < 2) return;

    const Xform = struct {
        scale: f32,
        x_off: f32,
        y_top: f32,
        fn map(self: @This(), p: ttf.Font.Point) [2]f32 {
            return .{ p.x * self.scale - self.x_off, -p.y * self.scale - self.y_top };
        }
    };
    const xf: Xform = .{ .scale = scale, .x_off = x_off, .y_top = y_top };

    // Walk the quadratic contour emitting line segments. TrueType rule:
    // consecutive off-curve points imply an on-curve midpoint.
    var pts: std.ArrayList([3]f32) = .empty; // x, y, on(1/0)
    defer pts.deinit(gpa);
    for (contour) |p| {
        const m = xf.map(p);
        try pts.append(gpa, .{ m[0], m[1], if (p.on_curve) 1 else 0 });
    }
    // Rotate so we start on-curve (synthesize midpoint if none adjacent).
    if (pts.items[0][2] == 0) {
        const last = pts.items[pts.items.len - 1];
        if (last[2] == 1) {
            std.mem.rotate([3]f32, pts.items, pts.items.len - 1);
        } else {
            const mid: [3]f32 = .{ (pts.items[0][0] + last[0]) / 2, (pts.items[0][1] + last[1]) / 2, 1 };
            try pts.insert(gpa, 0, mid);
        }
    }

    const n = pts.items.len;
    var cur: [2]f32 = .{ pts.items[0][0], pts.items[0][1] };
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const p = pts.items[i % n];
        if (p[2] == 1) {
            try lineTo(gpa, edges, &cur, .{ p[0], p[1] });
        } else {
            // Quadratic: control = p, end = next on-curve (or implied mid).
            const next = pts.items[(i + 1) % n];
            var end: [2]f32 = .{ next[0], next[1] };
            if (next[2] == 0) {
                end = .{ (p[0] + next[0]) / 2, (p[1] + next[1]) / 2 };
            } else {
                i += 1; // consumed the on-curve endpoint too
            }
            try quadTo(gpa, edges, &cur, .{ p[0], p[1] }, end);
        }
    }
}

fn lineTo(gpa: std.mem.Allocator, edges: *std.ArrayList(Edge), cur: *[2]f32, to: [2]f32) !void {
    if (cur[1] != to[1]) { // horizontal edges never cross scanlines
        try edges.append(gpa, .{
            .x0 = cur[0],
            .y0 = cur[1],
            .x1 = to[0],
            .y1 = to[1],
            .dir = if (to[1] > cur[1]) 1 else -1,
        });
    }
    cur.* = to;
}

fn quadTo(gpa: std.mem.Allocator, edges: *std.ArrayList(Edge), cur: *[2]f32, ctrl: [2]f32, end: [2]f32) !void {
    // Flatness-adaptive subdivision: enough steps that error < ~0.2px.
    const dx = cur[0] - 2 * ctrl[0] + end[0];
    const dy = cur[1] - 2 * ctrl[1] + end[1];
    const dev = @sqrt(dx * dx + dy * dy);
    const steps: usize = @max(1, @min(32, @as(usize, @intFromFloat(@ceil(@sqrt(dev / 0.2))))));
    const start = cur.*;
    var k: usize = 1;
    while (k <= steps) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        const mt = 1 - t;
        const x = mt * mt * start[0] + 2 * mt * t * ctrl[0] + t * t * end[0];
        const y = mt * mt * start[1] + 2 * mt * t * ctrl[1] + t * t * end[1];
        try lineTo(gpa, edges, cur, .{ x, y });
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const poppins = @embedFile("poppins");

test "rasterized 'A' has plausible ink" {
    const font = try ttf.Font.parse(poppins);
    var out = (try font.outline(testing.allocator, font.glyphIndex('A'))).?;
    defer out.deinit(testing.allocator);
    var bmp = try rasterize(testing.allocator, &font, out, 64);
    defer bmp.deinit(testing.allocator);

    try testing.expect(bmp.width > 20 and bmp.width < 80);
    try testing.expect(bmp.height > 30 and bmp.height < 80);

    var ink: usize = 0;
    var full: usize = 0;
    for (bmp.alpha) |a| {
        if (a > 0) ink += 1;
        if (a == 255) full += 1;
    }
    const total = bmp.width * bmp.height;
    // 'A' covers a meaningful fraction but is mostly strokes + hole.
    try testing.expect(ink * 100 / total > 15);
    try testing.expect(ink * 100 / total < 70);
    try testing.expect(full > 0); // solid stroke interiors exist
}

test "rasterized 'o' has a hole (non-zero winding works)" {
    const font = try ttf.Font.parse(poppins);
    var out = (try font.outline(testing.allocator, font.glyphIndex('o'))).?;
    defer out.deinit(testing.allocator);
    var bmp = try rasterize(testing.allocator, &font, out, 64);
    defer bmp.deinit(testing.allocator);

    // Center pixel must be empty (the counter), mid-left edge solid.
    const cx = bmp.width / 2;
    const cy = bmp.height / 2;
    try testing.expectEqual(@as(u8, 0), bmp.alpha[cy * bmp.width + cx]);
    var has_solid_on_row = false;
    for (bmp.alpha[cy * bmp.width ..][0..bmp.width]) |a| {
        if (a == 255) has_solid_on_row = true;
    }
    try testing.expect(has_solid_on_row);
}

test "antialiasing produces intermediate coverage" {
    const font = try ttf.Font.parse(poppins);
    var out = (try font.outline(testing.allocator, font.glyphIndex('A'))).?;
    defer out.deinit(testing.allocator);
    var bmp = try rasterize(testing.allocator, &font, out, 32);
    defer bmp.deinit(testing.allocator);

    var mid: usize = 0;
    for (bmp.alpha) |a| {
        if (a > 32 and a < 224) mid += 1;
    }
    try testing.expect(mid > 10); // diagonal strokes must have AA ramps
}
