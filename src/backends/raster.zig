//! CPU raster backend: renders the draw-primitive interface into an RGBA
//! framebuffer in software. Deterministic by construction — it is the
//! reference renderer for the golden-image harness (#13): GPU backends
//! (#11, #12, #15) are later verified against its output within a
//! perceptual tolerance.
//!
//! v1 fidelity:
//! - Rect fill + uniform border, hard-edged rounded corners (no AA yet)
//! - Clip stack
//! - Images: nearest-neighbor scaling
//! - Text: placeholder block per codepoint — real glyphs arrive with the
//!   TTF rasterizer (#10)
//!
//! Units are logical pixels, snapped to whole pixels.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend = @import("../backend.zig");

const Backend = backend.Backend;
const Color = style.Color;
const Rect = geometry.Rect;

pub const RasterBackend = struct {
    gpa: std.mem.Allocator,
    width: usize = 0,
    height: usize = 0,
    /// RGBA8, row-major.
    pixels: []u8 = &.{},
    clip_stack: std.ArrayList(IRect) = .empty,
    textures: std.AutoHashMapUnmanaged(u32, TextureData) = .empty,
    next_texture_id: u32 = 1,
    in_frame: bool = false,
    clear_color: Color = .white,
    char_width: f32 = 8,
    line_height: f32 = 16,

    const TextureData = struct {
        width: u32,
        height: u32,
        rgba: []u8,
    };

    const IRect = struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,

        fn fromRect(r: Rect) IRect {
            return .{
                .x0 = @intFromFloat(@round(r.x)),
                .y0 = @intFromFloat(@round(r.y)),
                .x1 = @intFromFloat(@round(r.x + r.width)),
                .y1 = @intFromFloat(@round(r.y + r.height)),
            };
        }

        fn intersect(a: IRect, b: IRect) IRect {
            return .{
                .x0 = @max(a.x0, b.x0),
                .y0 = @max(a.y0, b.y0),
                .x1 = @min(a.x1, b.x1),
                .y1 = @min(a.y1, b.y1),
            };
        }

        fn isEmpty(self: IRect) bool {
            return self.x1 <= self.x0 or self.y1 <= self.y0;
        }
    };

    pub fn init(gpa: std.mem.Allocator) RasterBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RasterBackend) void {
        self.gpa.free(self.pixels);
        self.clip_stack.deinit(self.gpa);
        var it = self.textures.valueIterator();
        while (it.next()) |tex| self.gpa.free(tex.rgba);
        self.textures.deinit(self.gpa);
    }

    pub fn interface(self: *RasterBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .begin_frame = beginFrame,
        .end_frame = endFrame,
        .draw_rect = drawRect,
        .draw_text = drawText,
        .draw_image = drawImage,
        .push_clip = pushClip,
        .pop_clip = popClip,
        .create_texture = createTexture,
        .destroy_texture = destroyTexture,
        .measure_text = measureText,
        .snap = snap,
    };

    fn self_(ptr: *anyopaque) *RasterBackend {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn pixelAt(self: *const RasterBackend, x: usize, y: usize) Color {
        const i = (y * self.width + x) * 4;
        return .{ .r = self.pixels[i], .g = self.pixels[i + 1], .b = self.pixels[i + 2], .a = self.pixels[i + 3] };
    }

    fn setPixel(self: *RasterBackend, x: i32, y: i32, color: Color) void {
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        if (color.a == 255) {
            self.pixels[i + 0] = color.r;
            self.pixels[i + 1] = color.g;
            self.pixels[i + 2] = color.b;
            self.pixels[i + 3] = 255;
        } else {
            // Source-over blend.
            const sa: u32 = color.a;
            const da: u32 = 255 - sa;
            self.pixels[i + 0] = @intCast((sa * color.r + da * self.pixels[i + 0]) / 255);
            self.pixels[i + 1] = @intCast((sa * color.g + da * self.pixels[i + 1]) / 255);
            self.pixels[i + 2] = @intCast((sa * color.b + da * self.pixels[i + 2]) / 255);
            self.pixels[i + 3] = @intCast(@min(255, sa + (da * self.pixels[i + 3]) / 255));
        }
    }

    fn screenRect(self: *const RasterBackend) IRect {
        return .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
    }

    fn currentClip(self: *const RasterBackend) IRect {
        var clip = self.screenRect();
        for (self.clip_stack.items) |c| clip = clip.intersect(c);
        return clip;
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(!self.in_frame);
        const w: usize = @intFromFloat(@max(0, @round(viewport.width)));
        const h: usize = @intFromFloat(@max(0, @round(viewport.height)));
        if (w != self.width or h != self.height) {
            self.gpa.free(self.pixels);
            self.pixels = self.gpa.alloc(u8, w * h * 4) catch return error.OutOfMemory;
            self.width = w;
            self.height = h;
        }
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = self.clear_color.r;
            self.pixels[i + 1] = self.clear_color.g;
            self.pixels[i + 2] = self.clear_color.b;
            self.pixels[i + 3] = 255;
        }
        self.in_frame = true;
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(self.in_frame);
        std.debug.assert(self.clip_stack.items.len == 0);
        self.in_frame = false;
    }

    /// Is pixel center (px, py) inside the rect with per-corner radii?
    fn insideRounded(r: Rect, radius: style.CornerRadius, px: f32, py: f32) bool {
        if (px < r.x or px >= r.x + r.width or py < r.y or py >= r.y + r.height) return false;
        const max_rad = @min(r.width, r.height) / 2;
        const corners = [4]struct { rad: f32, cx: f32, cy: f32 }{
            .{ .rad = radius.top_left, .cx = r.x + radius.top_left, .cy = r.y + radius.top_left },
            .{ .rad = radius.top_right, .cx = r.x + r.width - radius.top_right, .cy = r.y + radius.top_right },
            .{ .rad = radius.bottom_right, .cx = r.x + r.width - radius.bottom_right, .cy = r.y + r.height - radius.bottom_right },
            .{ .rad = radius.bottom_left, .cx = r.x + radius.bottom_left, .cy = r.y + r.height - radius.bottom_left },
        };
        for (corners) |c| {
            const rad = @min(c.rad, max_rad);
            if (rad <= 0) continue;
            // Only test points in this corner's square.
            const in_x = if (c.cx <= r.x + r.width / 2) px < c.cx else px > c.cx;
            const in_y = if (c.cy <= r.y + r.height / 2) py < c.cy else py > c.cy;
            if (in_x and in_y) {
                const dx = px - c.cx;
                const dy = py - c.cy;
                if (dx * dx + dy * dy > rad * rad) return false;
            }
        }
        return true;
    }

    fn drawRect(ptr: *anyopaque, rect: Rect, rect_style: style.RectStyle) void {
        const self = self_(ptr);
        const bounds = IRect.fromRect(rect).intersect(self.currentClip());
        if (bounds.isEmpty()) return;

        const b = rect_style.border;
        const has_border = !b.isNone();
        const inner: Rect = .{
            .x = rect.x + b.left.width,
            .y = rect.y + b.top.width,
            .width = @max(0, rect.width - b.left.width - b.right.width),
            .height = @max(0, rect.height - b.top.width - b.bottom.width),
        };
        // Inner radii shrink by the widths of the sides meeting each corner.
        const inner_radius: style.CornerRadius = .{
            .top_left = @max(0, rect_style.corner_radius.top_left - @max(b.top.width, b.left.width)),
            .top_right = @max(0, rect_style.corner_radius.top_right - @max(b.top.width, b.right.width)),
            .bottom_right = @max(0, rect_style.corner_radius.bottom_right - @max(b.bottom.width, b.right.width)),
            .bottom_left = @max(0, rect_style.corner_radius.bottom_left - @max(b.bottom.width, b.left.width)),
        };

        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (!insideRounded(rect, rect_style.corner_radius, px, py)) continue;
                const in_inner = insideRounded(inner, inner_radius, px, py);
                if (has_border and !in_inner) {
                    self.setPixel(x, y, borderColorAt(rect, rect_style, inner, px, py));
                } else if (rect_style.background) |bg| {
                    self.setPixel(x, y, bg);
                }
            }
        }
    }

    /// Side attribution for a border pixel. Pixels in a rounded corner's
    /// square belong to that corner: the horizontal side's color wins if
    /// present, else the vertical side's. Elsewhere, band logic applies.
    fn borderColorAt(rect: Rect, rect_style: style.RectStyle, inner: Rect, px: f32, py: f32) Color {
        const b = rect_style.border;
        const rad = rect_style.corner_radius;
        if (px < rect.x + rad.top_left and py < rect.y + rad.top_left)
            return if (b.top.width > 0) b.top.color else b.left.color;
        if (px >= rect.x + rect.width - rad.top_right and py < rect.y + rad.top_right)
            return if (b.top.width > 0) b.top.color else b.right.color;
        if (px >= rect.x + rect.width - rad.bottom_right and py >= rect.y + rect.height - rad.bottom_right)
            return if (b.bottom.width > 0) b.bottom.color else b.right.color;
        if (px < rect.x + rad.bottom_left and py >= rect.y + rect.height - rad.bottom_left)
            return if (b.bottom.width > 0) b.bottom.color else b.left.color;
        if (py < inner.y) return b.top.color;
        if (py >= inner.y + inner.height) return b.bottom.color;
        if (px < inner.x) return b.left.color;
        return b.right.color;
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, text_style: style.TextStyle) void {
        const self = self_(ptr);
        // Placeholder glyphs (#10): one solid block per codepoint, inset
        // 1px, so layout and color are golden-testable before real fonts.
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const block: Rect = .{
                .x = origin.x + @as(f32, @floatFromInt(i)) * self.char_width + 1,
                .y = origin.y + 1,
                .width = self.char_width - 2,
                .height = self.line_height - 2,
            };
            const bounds = IRect.fromRect(block).intersect(self.currentClip());
            if (bounds.isEmpty()) continue;
            var y = bounds.y0;
            while (y < bounds.y1) : (y += 1) {
                var x = bounds.x0;
                while (x < bounds.x1) : (x += 1) {
                    self.setPixel(x, y, text_style.color);
                }
            }
        }
    }

    fn drawImage(ptr: *anyopaque, rect: Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const tex = self.textures.get(@intCast(@intFromPtr(texture))) orelse unreachable;
        const bounds = IRect.fromRect(rect).intersect(self.currentClip());
        if (bounds.isEmpty()) return;

        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const u = (@as(f32, @floatFromInt(x)) + 0.5 - rect.x) / rect.width;
                const v = (@as(f32, @floatFromInt(y)) + 0.5 - rect.y) / rect.height;
                const tx: u32 = @intFromFloat(std.math.clamp(u * @as(f32, @floatFromInt(tex.width)), 0, @as(f32, @floatFromInt(tex.width - 1))));
                const ty: u32 = @intFromFloat(std.math.clamp(v * @as(f32, @floatFromInt(tex.height)), 0, @as(f32, @floatFromInt(tex.height - 1))));
                const ti = (@as(usize, ty) * tex.width + tx) * 4;
                self.setPixel(x, y, .{
                    .r = tex.rgba[ti + 0],
                    .g = tex.rgba[ti + 1],
                    .b = tex.rgba[ti + 2],
                    .a = tex.rgba[ti + 3],
                });
            }
        }
    }

    fn pushClip(ptr: *anyopaque, rect: Rect) void {
        const self = self_(ptr);
        self.clip_stack.append(self.gpa, IRect.fromRect(rect)) catch {};
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        std.debug.assert(self.clip_stack.items.len > 0);
        _ = self.clip_stack.pop();
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Backend.Error!*Backend.Texture {
        const self = self_(ptr);
        const copy = self.gpa.dupe(u8, rgba) catch return error.OutOfMemory;
        errdefer self.gpa.free(copy);
        const id = self.next_texture_id;
        self.next_texture_id += 1;
        self.textures.put(self.gpa, id, .{ .width = width, .height = height, .rgba = copy }) catch return error.OutOfMemory;
        return @ptrFromInt(id);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const id: u32 = @intCast(@intFromPtr(texture));
        const tex = self.textures.get(id) orelse unreachable;
        self.gpa.free(tex.rgba);
        std.debug.assert(self.textures.remove(id));
    }

    fn measureText(ptr: *anyopaque, text: []const u8, text_style: style.TextStyle) geometry.Size {
        const self = self_(ptr);
        _ = text_style;
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return .{
            .width = @as(f32, @floatFromInt(n)) * self.char_width,
            .height = self.line_height,
        };
    }

    fn snap(ptr: *anyopaque, value: f32, axis: geometry.Axis) f32 {
        _ = ptr;
        _ = axis;
        return @round(value);
    }

    /// Write the framebuffer as binary PPM (P6) — the golden-image and CI
    /// failure-artifact format (#13); convertible to PNG by any tool.
    pub fn writePpm(self: *const RasterBackend, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("P6\n{d} {d}\n255\n", .{ self.width, self.height });
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            try writer.writeAll(self.pixels[i .. i + 3]);
        }
    }
};

// ---------------------------------------------------------------------------
// Pixel-exact tests: the raster backend is deterministic, so tests assert
// exact pixel values. Cross-backend golden comparison builds on this (#13).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectPixel(r: *const RasterBackend, x: usize, y: usize, expected: Color) !void {
    const actual = r.pixelAt(x, y);
    try testing.expectEqual(expected.r, actual.r);
    try testing.expectEqual(expected.g, actual.g);
    try testing.expectEqual(expected.b, actual.b);
}

test "background fill and clear color" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 16, .height = 16 });
    b.drawRect(.{ .x = 4, .y = 4, .width = 8, .height = 8 }, .{ .background = Color.rgb(255, 0, 0) });
    try b.endFrame();

    try expectPixel(&raster, 8, 8, Color.rgb(255, 0, 0)); // inside
    try expectPixel(&raster, 1, 1, Color.white); // clear color
    try expectPixel(&raster, 12, 12, Color.white); // just outside (exclusive edge)
    try expectPixel(&raster, 11, 11, Color.rgb(255, 0, 0)); // last inside pixel
}

test "border surrounds background" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 20, .height = 20 });
    b.drawRect(
        .{ .x = 2, .y = 2, .width = 16, .height = 16 },
        .{ .background = Color.rgb(0, 0, 255), .border = .all(2, Color.black) },
    );
    try b.endFrame();

    try expectPixel(&raster, 2, 10, Color.black); // left border
    try expectPixel(&raster, 3, 10, Color.black); // still border (width 2)
    try expectPixel(&raster, 4, 10, Color.rgb(0, 0, 255)); // interior
    try expectPixel(&raster, 10, 2, Color.black); // top border
}

test "rounded corners cut the corner pixel" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 16, .height = 16 });
    b.drawRect(
        .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        .{ .background = Color.rgb(255, 0, 0), .corner_radius = .all(6) },
    );
    try b.endFrame();

    try expectPixel(&raster, 0, 0, Color.white); // corner cut away
    try expectPixel(&raster, 8, 0, Color.rgb(255, 0, 0)); // top edge midpoint kept
    try expectPixel(&raster, 8, 8, Color.rgb(255, 0, 0)); // center
    try expectPixel(&raster, 15, 15, Color.white); // opposite corner cut
}

test "clip stack restricts drawing" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 16, .height = 16 });
    b.pushClip(.{ .x = 0, .y = 0, .width = 8, .height = 16 });
    b.drawRect(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .background = Color.black });
    b.popClip();
    try b.endFrame();

    try expectPixel(&raster, 4, 8, Color.black); // inside clip
    try expectPixel(&raster, 12, 8, Color.white); // outside clip untouched
}

test "image draws with nearest-neighbor scaling" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    // 2x1 texture: red | green, scaled to 8x4.
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const tex = try b.createTexture(2, 1, &px);
    try b.beginFrame(.{ .width = 8, .height = 4 });
    b.drawImage(.{ .x = 0, .y = 0, .width = 8, .height = 4 }, tex);
    try b.endFrame();
    b.destroyTexture(tex);

    try expectPixel(&raster, 1, 1, Color.rgb(255, 0, 0)); // left half
    try expectPixel(&raster, 6, 1, Color.rgb(0, 255, 0)); // right half
}

test "alpha blending source-over" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 4, .height = 4 });
    // 50%-alpha black over white clear → mid gray.
    b.drawRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ .background = .{ .r = 0, .g = 0, .b = 0, .a = 128 } });
    try b.endFrame();

    const p = raster.pixelAt(2, 2);
    try testing.expect(p.r > 120 and p.r < 132); // ~127
}

test "writePpm emits valid header and size" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 3, .height = 2 });
    try b.endFrame();

    var buf: [128]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try raster.writePpm(&fixed);
    const out = fixed.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "P6\n3 2\n255\n"));
    try testing.expectEqual("P6\n3 2\n255\n".len + 3 * 2 * 3, out.len);
}
