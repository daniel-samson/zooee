//! Paint styles carried by draw primitives.
//!
//! Styles express *intent*; backends own fidelity and may quantize
//! (e.g. the terminal renders any `corner_radius > 0` with box-drawing
//! rounded corners and any `Border.width > 0` as one cell). See #2.

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

pub const Border = struct {
    width: f32 = 0,
    color: Color = .black,
};

pub const RectStyle = struct {
    /// null = no fill.
    background: ?Color = null,
    border: Border = .{},
    corner_radius: f32 = 0,
};

pub const TextStyle = struct {
    color: Color = .black,
    /// Font size in the backend's native units. Terminal backends ignore it
    /// (glyphs are cell-sized); GPU backends select/rasterize accordingly.
    size: f32 = 16,
    bold: bool = false,
    italic: bool = false,
};
