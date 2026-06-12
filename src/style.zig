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

pub const RectStyle = struct {
    /// null = no fill.
    background: ?Color = null,
    border: Border = .none,
    corner_radius: CornerRadius = .none,
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
