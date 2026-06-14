//! Paint styles carried by draw primitives.
//!
//! Styles express *intent*; backends own fidelity and may quantize
//! (e.g. the terminal renders any rounded corner with box-drawing
//! characters and any border side with one cell of thickness). See #2.
//!
//! Border and corner radius are per-side/per-corner, CSS-style, with
//! uniform shorthands as the ergonomic default.

const geometry = @import("geometry.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// The color as a 0..1 RGBA quad — the form the GPU clear paths want.
    pub fn rgbaF(self: Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }
};

pub const BorderSide = struct {
    width: f32 = 0,
    color: Color = .black,

    pub const none: BorderSide = .{};
};

pub const Border = struct {
    top: BorderSide = .none,
    right: BorderSide = .none,
    bottom: BorderSide = .none,
    left: BorderSide = .none,

    pub const none: Border = .{};

    /// Uniform border: same width and color on all four sides.
    pub fn all(width: f32, color: Color) Border {
        const side: BorderSide = .{ .width = width, .color = color };
        return .{ .top = side, .right = side, .bottom = side, .left = side };
    }

    pub fn isNone(self: Border) bool {
        return self.top.width <= 0 and self.right.width <= 0 and
            self.bottom.width <= 0 and self.left.width <= 0;
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub const none: CornerRadius = .{};

    /// Uniform radius on all four corners.
    pub fn all(radius: f32) CornerRadius {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }

    pub fn isNone(self: CornerRadius) bool {
        return self.top_left <= 0 and self.top_right <= 0 and
            self.bottom_right <= 0 and self.bottom_left <= 0;
    }
};

/// A gradient fill (#118): linear (axis-aligned) or radial, with N color stops
/// (straight-RGB interpolation, pixel centers). The 2-stop `from`/`to` form is
/// kept for back-compat; when `stop_count >= 2` the explicit `stops` win. When
/// set on a RectStyle it fills the rect interior in place of `background`.
pub const Gradient = struct {
    pub const Axis = enum { horizontal, vertical };
    pub const Kind = enum(u8) { linear = 0, radial = 1 };
    pub const Stop = struct { offset: f32, color: Color };
    pub const max_stops = 8;

    kind: Kind = .linear,
    axis: Axis = .horizontal,
    /// Radial center + radius as fractions of the rect: cx/cy in [0,1] of
    /// width/height, radius as a fraction of max(width,height).
    cx: f32 = 0.5,
    cy: f32 = 0.5,
    radius: f32 = 0.5,
    stops: [max_stops]Stop = [_]Stop{.{ .offset = 0, .color = .black }} ** max_stops,
    stop_count: u8 = 0,
    /// Back-compat two-stop endpoints (used when stop_count < 2).
    from: Color = .black,
    to: Color = .white,

    /// Resolve to an explicit stop list (≥2): the `stops`, or {0:from, 1:to}.
    /// Takes `self` by pointer so the returned slice (for the multi-stop case)
    /// references the caller's gradient, not a by-value copy's dead stack.
    pub fn resolved(self: *const Gradient, out: *[max_stops]Stop) []const Stop {
        if (self.stop_count >= 2) {
            const n = @min(self.stop_count, max_stops);
            return self.stops[0..n];
        }
        out[0] = .{ .offset = 0, .color = self.from };
        out[1] = .{ .offset = 1, .color = self.to };
        return out[0..2];
    }

    /// The gradient parameter t (0..1, unclamped) at pixel (px,py).
    pub fn paramAt(self: Gradient, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) f32 {
        return switch (self.kind) {
            .linear => switch (self.axis) {
                .horizontal => if (rect_w > 0) (px - rect_x) / rect_w else 0,
                .vertical => if (rect_h > 0) (py - rect_y) / rect_h else 0,
            },
            .radial => blk: {
                const ccx = rect_x + self.cx * rect_w;
                const ccy = rect_y + self.cy * rect_h;
                const rr = self.radius * @max(rect_w, rect_h);
                const dx = px - ccx;
                const dy = py - ccy;
                break :blk if (rr > 0) @sqrt(dx * dx + dy * dy) / rr else 0;
            },
        };
    }

    /// The interpolated color at pixel (px,py) within the rect (pixel centers).
    pub fn colorAt(self: Gradient, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) Color {
        var buf: [max_stops]Stop = undefined;
        const ss = self.resolved(&buf);
        const t = @max(0, @min(1, self.paramAt(rect_x, rect_y, rect_w, rect_h, px, py)));
        if (t <= ss[0].offset) return ss[0].color;
        var i: usize = 1;
        while (i < ss.len) : (i += 1) {
            if (t <= ss[i].offset) {
                const lo = ss[i - 1];
                const hi = ss[i];
                const span = hi.offset - lo.offset;
                const f = if (span > 0) (t - lo.offset) / span else 0;
                return .{
                    .r = lerp8(lo.color.r, hi.color.r, f),
                    .g = lerp8(lo.color.g, hi.color.g, f),
                    .b = lerp8(lo.color.b, hi.color.b, f),
                    .a = lerp8(lo.color.a, hi.color.a, f),
                };
            }
        }
        return ss[ss.len - 1].color;
    }

    fn lerp8(a: u8, b: u8, t: f32) u8 {
        const fa: f32 = @floatFromInt(a);
        const fb: f32 = @floatFromInt(b);
        return @intFromFloat(@round(fa + (fb - fa) * t));
    }
};

/// A box shadow (#119): a Gaussian-blurred rectangle painted *behind* the
/// element, offset by (dx,dy), grown by `spread`, in `color`. Coverage is
/// computed analytically as a product of 1D Gaussian-box integrals (erf), so
/// the CPU reference and every GPU shader evaluate the SAME closed form and
/// match pixel-exact — no CPU-blur-vs-GPU-SDF divergence. Rounded-corner and
/// inset shadows are follow-ups (slice 1 = axis-aligned outer box).
pub const BoxShadow = struct {
    color: Color,
    dx: f32 = 0,
    dy: f32 = 0,
    /// Blur radius; the Gaussian sigma is blur/2 (≈ the CSS convention).
    blur: f32 = 0,
    spread: f32 = 0,
    /// Corner radius of the shadowed box (#119): >0 uses the rounded-shadow
    /// integral; 0 uses the fast closed-form erf product.
    corner_radius: f32 = 0,
    /// Inset shadow (#119): the shadow is cast inward from the rect edges
    /// (a pressed "well") instead of outward behind the rect.
    inset: bool = false,

    /// Abramowitz-Stegun 7.1.26 erf approximation (max abs error ~1.5e-7).
    /// Backends MUST replicate this exact polynomial so results match.
    fn erf(x: f32) f32 {
        const t = 1.0 / (1.0 + 0.3275911 * @abs(x));
        const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-x * x);
        return if (x < 0) -y else y;
    }

    /// 1D coverage of the blurred interval [lo,hi] at p, sigma s.
    fn band(p: f32, lo: f32, hi: f32, s: f32) f32 {
        const inv = 1.0 / (s * 1.4142135623730951);
        return 0.5 * (erf((hi - p) * inv) - erf((lo - p) * inv));
    }

    /// Wallace's vec-form erf approximation, used ONLY by the rounded path so
    /// the CPU and every shader integrate the identical curve.
    fn werf(x: f32) f32 {
        const s: f32 = if (x < 0) -1 else 1;
        const a = @abs(x);
        var v = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
        v *= v;
        return s - s / (v * v);
    }

    fn gaussian(x: f32, sigma: f32) f32 {
        return @exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746310002 * sigma); // sqrt(2π)
    }

    /// Horizontal extent of the rounded box at row `y` (box-center coords),
    /// blurred (Evan Wallace, madebyevan.com fast-rounded-rectangle-shadows).
    fn roundedX(x: f32, y: f32, sigma: f32, corner: f32, hx: f32, hy: f32) f32 {
        const delta = @min(hy - corner - @abs(y), 0.0);
        const curved = hx - corner + @sqrt(@max(0.0, corner * corner - delta * delta));
        const inv = 0.7071067811865476 / sigma; // sqrt(0.5)/sigma
        const lo = 0.5 + 0.5 * werf((x - curved) * inv);
        const hi = 0.5 + 0.5 * werf((x + curved) * inv);
        return hi - lo;
    }

    /// Gaussian coverage [0,1] of the (optionally rounded) box [x0,y0,x1,y1] at
    /// (px,py), sigma `s`. The shared kernel for outer and inset shadows; every
    /// backend replicates it.
    pub fn boxCoverage(x0: f32, y0: f32, x1: f32, y1: f32, corner: f32, s: f32, px: f32, py: f32) f32 {
        if (s <= 0) {
            return if (px >= x0 and px < x1 and py >= y0 and py < y1) 1 else 0;
        }
        if (corner <= 0) {
            return @max(0, @min(1, band(px, x0, x1, s) * band(py, y0, y1, s)));
        }
        const cx = (x0 + x1) * 0.5;
        const cy = (y0 + y1) * 0.5;
        const hx = (x1 - x0) * 0.5;
        const hy = (y1 - y0) * 0.5;
        const cr = @min(corner, @min(hx, hy));
        const ptx = px - cx;
        const pty = py - cy;
        const low = pty - hy;
        const high = pty + hy;
        const start = @max(low, @min(high, -3.0 * s));
        const end = @max(low, @min(high, 3.0 * s));
        const step = (end - start) / 4.0;
        var y = start + step * 0.5;
        var value: f32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            value += roundedX(ptx, pty - y, s, cr, hx, hy) * gaussian(y, s) * step;
            y += step;
        }
        return @max(0, @min(1, value));
    }

    /// Outer shadow coverage [0,1] at (px,py): the box grown by `spread`.
    pub fn coverage(self: BoxShadow, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) f32 {
        const x0 = rect_x + self.dx - self.spread;
        const y0 = rect_y + self.dy - self.spread;
        const x1 = rect_x + rect_w + self.dx + self.spread;
        const y1 = rect_y + rect_h + self.dy + self.spread;
        return boxCoverage(x0, y0, x1, y1, self.corner_radius, self.blur * 0.5, px, py);
    }

    /// Inset shadow coverage [0,1] at (px,py): 1 − coverage of the inner
    /// (offset + spread-shrunk) box, so the shadow hugs the inner edges. Paint
    /// only inside the rect (the caller clips to the rect's rounded shape).
    pub fn insetCoverage(self: BoxShadow, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) f32 {
        const x0 = rect_x + self.dx + self.spread;
        const y0 = rect_y + self.dy + self.spread;
        const x1 = rect_x + rect_w + self.dx - self.spread;
        const y1 = rect_y + rect_h + self.dy - self.spread;
        return @max(0, @min(1, 1.0 - boxCoverage(x0, y0, x1, y1, self.corner_radius, self.blur * 0.5, px, py)));
    }
};

pub const RectStyle = struct {
    /// null = no fill.
    background: ?Color = null,
    /// Gradient fill for the rect interior; overrides `background` when set.
    gradient: ?Gradient = null,
    border: Border = .none,
    corner_radius: CornerRadius = .none,
    /// Box shadow painted behind the rect (#119).
    shadow: ?BoxShadow = null,
};

pub const TextStyle = struct {
    /// null = the backend default (terminal theme foreground; black on raster).
    color: ?Color = null,
    /// Font size in the backend's native units. Terminal backends ignore it
    /// (glyphs are cell-sized); GPU backends select/rasterize accordingly.
    size: f32 = 16,
    bold: bool = false,
    italic: bool = false,
    /// Text decorations (#191), rendered per backend: terminal applies the
    /// native SGR attribute (underline/strike); GPU/raster draw a line.
    underline: bool = false,
    strikethrough: bool = false,
};

/// Decoration line rects (#191), shared so every backend draws the underline /
/// strikethrough in the same place at pixel-exact agreement. `baseline` is the
/// text baseline (origin.y + ascent); the line spans `x..x+width`.
pub const TextDecoration = struct {
    pub fn thickness(size: f32) f32 {
        return @max(1, @round(size * 0.06));
    }
    pub fn underlineRect(x: f32, baseline: f32, width: f32, size: f32) geometry.Rect {
        const t = thickness(size);
        return .{ .x = x, .y = @round(baseline + size * 0.12), .width = width, .height = t };
    }
    pub fn strikeRect(x: f32, baseline: f32, width: f32, size: f32) geometry.Rect {
        const t = thickness(size);
        return .{ .x = x, .y = @round(baseline - size * 0.28), .width = width, .height = t };
    }
};
