//! Paint styles carried by draw primitives.
//!
//! Styles express *intent*; backends own fidelity and may quantize
//! (e.g. the terminal renders any rounded corner with box-drawing
//! characters and any border side with one cell of thickness). See #2.
//!
//! Border and corner radius are per-side/per-corner, CSS-style, with
//! uniform shorthands as the ergonomic default.

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

/// A two-stop linear gradient fill (#118). Slice 1: axis-aligned (horizontal
/// or vertical), straight-RGB interpolation. Multi-stop, diagonal, radial, and
/// sRGB-correct interpolation are follow-ups. When set on a RectStyle it fills
/// the rect interior in place of `background`.
pub const Gradient = struct {
    pub const Axis = enum { horizontal, vertical };
    axis: Axis = .horizontal,
    from: Color,
    to: Color,

    /// The interpolated color at pixel (px,py) within a rect (pixel centers).
    pub fn colorAt(self: Gradient, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) Color {
        const t = switch (self.axis) {
            .horizontal => if (rect_w > 0) (px - rect_x) / rect_w else 0,
            .vertical => if (rect_h > 0) (py - rect_y) / rect_h else 0,
        };
        const tc = @max(0, @min(1, t));
        return .{
            .r = lerp8(self.from.r, self.to.r, tc),
            .g = lerp8(self.from.g, self.to.g, tc),
            .b = lerp8(self.from.b, self.to.b, tc),
            .a = lerp8(self.from.a, self.to.a, tc),
        };
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

    /// Shadow coverage [0,1] at pixel center (px,py) for the rect at
    /// (rect_x,rect_y) sized rect_w×rect_h.
    pub fn coverage(self: BoxShadow, rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, px: f32, py: f32) f32 {
        const x0 = rect_x + self.dx - self.spread;
        const y0 = rect_y + self.dy - self.spread;
        const x1 = rect_x + rect_w + self.dx + self.spread;
        const y1 = rect_y + rect_h + self.dy + self.spread;
        if (self.blur <= 0) {
            return if (px >= x0 and px < x1 and py >= y0 and py < y1) 1 else 0;
        }
        const s = self.blur * 0.5;
        const c = band(px, x0, x1, s) * band(py, y0, y1, s);
        return @max(0, @min(1, c));
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
};
