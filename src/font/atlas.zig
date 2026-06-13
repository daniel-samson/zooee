//! Dynamic glyph atlas (#114): rasterize + shelf-pack glyphs on demand into
//! one RGBA texture (rgb=255, a=coverage, top-down), keyed by font glyph index
//! at a fixed pixel size. Replaces the pre-baked ASCII-only atlas so GPU
//! backends render arbitrary Unicode — matching the raster reference, which
//! already rasterizes any codepoint on the fly.
//!
//! One atlas per (face, size). The backend owns the GPU texture and re-uploads
//! from `pixels` whenever `dirty` is set (a new glyph was packed this frame);
//! after warm-up `dirty` stays false, so steady-state has no uploads.
//!
//! Slice 1: fixed-size atlas filled on demand (no repack/eviction). Generous
//! dimensions cover Latin + accents + punctuation; growth/LRU is a follow-up.

const std = @import("std");
const ttf = @import("ttf.zig");
const grast = @import("raster.zig");

/// A packed glyph: normalized atlas UVs, pixel size, baseline offsets, advance.
/// `w == 0` for blank glyphs (space) or any that failed to pack — the caller
/// still advances the pen by `advance`.
pub const Glyph = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 0,
    v1: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    x_off: f32 = 0,
    y_off: f32 = 0,
    advance: f32 = 0,
};

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    font: *const ttf.Font,
    size_px: f32,
    fscale: f32,
    ascent: f32,
    width: u32,
    height: u32,
    /// RGBA, row-major, top-down. Backends upload this to a GPU texture.
    pixels: []u8,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    // Shelf-pack cursor.
    cx: u32 = 1,
    cy: u32 = 1,
    row_h: u32 = 0,
    /// Set when a glyph was packed since the last upload; backend clears it.
    dirty: bool = true,

    pub fn init(gpa: std.mem.Allocator, font: *const ttf.Font, size_px: f32, width: u32, height: u32) !Atlas {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
        @memset(pixels, 0);
        const fscale = size_px / @as(f32, @floatFromInt(font.units_per_em));
        return .{
            .gpa = gpa,
            .font = font,
            .size_px = size_px,
            .fscale = fscale,
            .ascent = @as(f32, @floatFromInt(font.ascent)) * fscale,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Atlas) void {
        self.glyphs.deinit(self.gpa);
        self.gpa.free(self.pixels);
    }

    /// The atlas entry for a font glyph index, rasterizing + packing it on
    /// first use. Always returns a valid `advance`; `w == 0` if blank/unpacked.
    pub fn glyph(self: *Atlas, gi: u16) Glyph {
        if (self.glyphs.get(gi)) |g| return g;

        var e: Glyph = .{ .advance = @as(f32, @floatFromInt(self.font.hMetrics(gi).advance)) * self.fscale };
        if (self.font.outline(self.gpa, gi) catch null) |outline_| {
            var outline = outline_;
            defer outline.deinit(self.gpa);
            if (grast.rasterize(self.gpa, self.font, outline, self.size_px) catch null) |bmp_| {
                var bmp = bmp_;
                defer bmp.deinit(self.gpa);
                const bw: u32 = @intCast(bmp.width);
                const bh: u32 = @intCast(bmp.height);
                if (bw > 0 and bh > 0 and bw + 2 <= self.width) {
                    if (self.cx + bw + 1 > self.width) {
                        self.cx = 1;
                        self.cy += self.row_h + 1;
                        self.row_h = 0;
                    }
                    if (self.cy + bh + 1 <= self.height) {
                        const ax = self.cx;
                        const ay = self.cy;
                        var yy: u32 = 0;
                        while (yy < bh) : (yy += 1) {
                            var xx: u32 = 0;
                            while (xx < bw) : (xx += 1) {
                                const a = bmp.alpha[yy * bw + xx];
                                const k = ((ay + yy) * self.width + (ax + xx)) * 4;
                                self.pixels[k + 0] = 255;
                                self.pixels[k + 1] = 255;
                                self.pixels[k + 2] = 255;
                                self.pixels[k + 3] = a;
                            }
                        }
                        const fw: f32 = @floatFromInt(self.width);
                        const fh: f32 = @floatFromInt(self.height);
                        e.w = @floatFromInt(bw);
                        e.h = @floatFromInt(bh);
                        e.x_off = @floatFromInt(bmp.x_off);
                        e.y_off = @floatFromInt(bmp.y_off);
                        e.u0 = @as(f32, @floatFromInt(ax)) / fw;
                        e.v0 = @as(f32, @floatFromInt(ay)) / fh;
                        e.u1 = @as(f32, @floatFromInt(ax + bw)) / fw;
                        e.v1 = @as(f32, @floatFromInt(ay + bh)) / fh;
                        self.cx += bw + 1;
                        self.row_h = @max(self.row_h, bh);
                        self.dirty = true;
                    }
                }
            }
        }
        self.glyphs.put(self.gpa, gi, e) catch {};
        return e;
    }
};
