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
