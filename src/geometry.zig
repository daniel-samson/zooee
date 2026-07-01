//! Geometric primitives shared by layout and backends.
//!
//! All values are in the owning backend's native units (terminal cells,
//! logical pixels, …). The layout engine snaps values through
//! `Backend.snap` as it commits them, so by the time geometry reaches a
//! backend's draw calls it is already on that backend's grid (#3).

const std = @import("std");

pub const Axis = enum { horizontal, vertical };

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// Baked vector-icon geometry (#272): the build-time output shape of
/// tools/svg2icons.zig. Subpath points live in a normalized 0..1 unit square;
/// the widget layer scales them to the target pixel box. Defined here so every
/// generated icon module shares one nominal type — the baked Lucide set
/// (src/lucide.zig) and any future generated set are then interchangeable
/// through `Ui.iconData`.
pub const IconSubPath = struct { pts: []const Point, closed: bool };
pub const IconData = struct { subpaths: []const IconSubPath, stroke_width: f32, stroke: bool };

/// Even-odd point-in-polygon test (#120): a horizontal ray to the right of
/// (px,py) toggles `inside` at each crossed edge. This is THE canonical
/// definition of a filled path's interior — every backend (raster reference +
/// each shader) must replicate this exact logic so fills match pixel-exact.
/// Concave shapes and self-intersections resolve by even-odd parity.
/// Squared distance from (px,py) to segment a→b. Division is by the segment
/// length² (never near-zero for real segments), so it's numerically stable and
/// matches across CPU/GPU.
fn segDist2(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const vv = vx * vx + vy * vy;
    const t = if (vv > 0) @max(0.0, @min(1.0, (wx * vx + wy * vy) / vv)) else 0.0;
    const dx = ax + t * vx - px;
    const dy = ay + t * vy - py;
    return dx * dx + dy * dy;
}

/// Is (px,py) within `hw` (half stroke width) of the polyline through `pts`?
/// `closed` adds the segment from the last point back to the first. Compared
/// as squared distances (no sqrt), so the canonical stroke test (#120) matches
/// pixel-exact across every backend. Round caps/joins (distance to the line).
pub fn pointNearPolyline(pts: []const Point, closed: bool, hw: f32, px: f32, py: f32) bool {
    if (pts.len < 2) return false;
    const hw2 = hw * hw;
    const last = if (closed) pts.len else pts.len - 1;
    var i: usize = 0;
    while (i < last) : (i += 1) {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        if (segDist2(a.x, a.y, b.x, b.y, px, py) <= hw2) return true;
    }
    return false;
}

/// Min Euclidean distance from (px,py) to the nearest polyline/polygon edge
/// (#316). Stroke AA (`hw + 0.5 − d`) and fill AA (signed by pointInPolygon,
/// `0.5 ± d`) turn this into ~1px box-filter coverage. The GPU shaders mirror
/// this exactly so GPU == raster holds.
pub fn distToPolyline(pts: []const Point, closed: bool, px: f32, py: f32) f32 {
    if (pts.len < 2) return std.math.inf(f32);
    const last = if (closed) pts.len else pts.len - 1;
    var best: f32 = std.math.inf(f32);
    var i: usize = 0;
    while (i < last) : (i += 1) {
        const a = pts[i];
        const b = pts[(i + 1) % pts.len];
        best = @min(best, segDist2(a.x, a.y, b.x, b.y, px, py));
    }
    return @sqrt(best);
}

pub fn pointInPolygon(pts: []const Point, px: f32, py: f32) bool {
    if (pts.len < 3) return false;
    var inside = false;
    var j: usize = pts.len - 1;
    for (pts, 0..) |b, i| {
        const a = pts[j];
        if ((b.y > py) != (a.y > py)) {
            // px < x-intersection, division-free (cross-multiply by a.y-b.y,
            // flipping the comparison by its sign). Both products are computed
            // identically on CPU and GPU, so the fill matches pixel-exact —
            // unlike the float division it replaces.
            const lhs = (a.x - b.x) * (py - b.y);
            const rhs = (px - b.x) * (a.y - b.y);
            const left = if (a.y > b.y) rhs < lhs else rhs > lhs;
            if (left) inside = !inside;
        }
        j = i;
    }
    return inside;
}

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn origin(self: Rect) Point {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn size(self: Rect) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width <= 0 or self.height <= 0;
    }

    /// Intersection of two rects; empty result has zero width/height.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.width, other.x + other.width);
        const y1 = @min(self.y + self.height, other.y + other.height);
        return .{
            .x = x0,
            .y = y0,
            .width = @max(0, x1 - x0),
            .height = @max(0, y1 - y0),
        };
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.x + self.width and
            p.y >= self.y and p.y < self.y + self.height;
    }
};

test "rect intersection" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const i = a.intersect(b);
    try std.testing.expectEqual(@as(f32, 5), i.x);
    try std.testing.expectEqual(@as(f32, 5), i.width);
}

test "disjoint rects intersect to empty" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 };
    const b: Rect = .{ .x = 10, .y = 10, .width = 4, .height = 4 };
    try std.testing.expect(a.intersect(b).isEmpty());
}

test "even-odd point-in-polygon handles concavity" {
    // An L-shape: bottom bar y[0,2]×x[0,6] plus left bar x[0,2]×y[0,6]. The
    // top-right quadrant is the concave notch (outside).
    const l = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 }, .{ .x = 6, .y = 2 },
        .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 }, .{ .x = 0, .y = 6 },
    };
    try std.testing.expect(pointInPolygon(&l, 1, 4)); // left bar → inside
    try std.testing.expect(pointInPolygon(&l, 4, 1)); // bottom bar → inside
    try std.testing.expect(!pointInPolygon(&l, 4, 4)); // notch → outside
    try std.testing.expect(!pointInPolygon(&l, 10, 10)); // far → outside
}

test "stroke proximity to a polyline" {
    // A horizontal segment from (0,10) to (20,10), half-width 2.
    const line = [_]Point{ .{ .x = 0, .y = 10 }, .{ .x = 20, .y = 10 } };
    try std.testing.expect(pointNearPolyline(&line, false, 2, 10, 10)); // on the line
    try std.testing.expect(pointNearPolyline(&line, false, 2, 10, 11.5)); // within half-width
    try std.testing.expect(!pointNearPolyline(&line, false, 2, 10, 13)); // beyond
    try std.testing.expect(pointNearPolyline(&line, false, 2, 0, 9)); // near an endpoint (round cap)
    try std.testing.expect(!pointNearPolyline(&line, false, 2, 25, 10)); // past the end
}
