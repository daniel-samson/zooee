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
const ttf = @import("../font/ttf.zig");
const glyph_raster = @import("../font/raster.zig");
const fontset = @import("../font/fontset.zig");

const Backend = backend.Backend;
const Color = style.Color;
const Rect = geometry.Rect;

pub const RasterBackend = struct {
    gpa: std.mem.Allocator,
    width: usize = 0,
    height: usize = 0,
    /// RGBA8, row-major.
    pixels: []u8 = &.{},
    clip_stack: std.ArrayList(Clip) = .empty,
    /// Accumulated content translation for scroll viewports (#96). Pushed clips
    /// are stored device-absolute (offset by this); setPixel adds it; iteration
    /// clips are returned in local space (currentClip subtracts it).
    translate: geometry.Point = .{ .x = 0, .y = 0 },
    translate_stack: std.ArrayList(geometry.Point) = .empty,
    /// Count of clip entries with a corner radius (#117); the per-pixel rounded
    /// test in setPixel is skipped entirely when zero.
    rounded_clips: usize = 0,
    /// Active group-opacity layers (#121). Each entry holds the parent target
    /// `self.pixels` was redirected from, plus the opacity to composite at.
    layers: std.ArrayList(Layer) = .empty,
    textures: std.AutoHashMapUnmanaged(u32, TextureData) = .empty,
    next_texture_id: u32 = 1,
    in_frame: bool = false,
    clear_color: Color = .white,
    char_width: f32 = 8,
    line_height: f32 = 16,
    /// Real text when set (setFont/setFontSet); placeholder blocks otherwise.
    /// A FontSet so bold/italic and Unicode fallback pick the right face (#114).
    fonts: ?fontset.FontSet = null,
    /// Keyed by (face_id<<32 | glyph<<16 | size) so the same glyph index from
    /// two different faces doesn't collide (#114).
    glyph_cache: std.AutoHashMapUnmanaged(u64, glyph_raster.Bitmap) = .empty,

    const TextureData = struct {
        width: u32,
        height: u32,
        rgba: []u8,
    };

    const Layer = struct {
        /// The buffer draws were going to before this layer was pushed.
        parent: []u8,
        opacity: f32,
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

        fn offset(self: IRect, dx: i32, dy: i32) IRect {
            return .{ .x0 = self.x0 + dx, .y0 = self.y0 + dy, .x1 = self.x1 + dx, .y1 = self.y1 + dy };
        }
    };

    /// A clip-stack entry: an integer bounds rect plus, for rounded clips
    /// (#117), the float rect + per-corner radii its pixels are tested against.
    const Clip = struct {
        bounds: IRect,
        round: ?struct { rect: Rect, radius: style.CornerRadius } = null,
    };

    pub fn init(gpa: std.mem.Allocator) RasterBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RasterBackend) void {
        self.gpa.free(self.pixels);
        for (self.layers.items) |layer| self.gpa.free(layer.parent);
        self.layers.deinit(self.gpa);
        self.clip_stack.deinit(self.gpa);
        self.translate_stack.deinit(self.gpa);
        var it = self.textures.valueIterator();
        while (it.next()) |tex| self.gpa.free(tex.rgba);
        self.textures.deinit(self.gpa);
        var git = self.glyph_cache.valueIterator();
        while (git.next()) |bmp| bmp.deinit(self.gpa);
        self.glyph_cache.deinit(self.gpa);
    }

    /// Use a single TTF for text — sets it as the regular face (borrowed bytes
    /// must outlive the backend). For bold/italic + Unicode fallback, use
    /// `setFontSet`.
    pub fn setFont(self: *RasterBackend, data: []const u8) !void {
        var set: fontset.FontSet = .{};
        set.setFace(fontset.FontSet.regular, try ttf.Font.parse(data));
        self.fonts = set;
    }

    /// Use a full face set: bold/italic variants + a Unicode fallback chain.
    pub fn setFontSet(self: *RasterBackend, set: fontset.FontSet) void {
        self.fonts = set;
    }

    fn cachedGlyph(self: *RasterBackend, face_id: u8, face: *const ttf.Font, glyph: u16, size_px: u16) ?*glyph_raster.Bitmap {
        const key: u64 = (@as(u64, face_id) << 32) | (@as(u64, glyph) << 16) | size_px;
        if (self.glyph_cache.getPtr(key)) |bmp| return bmp;
        const outline = (face.outline(self.gpa, glyph) catch return null) orelse return null;
        var o = outline;
        defer o.deinit(self.gpa);
        const bmp = glyph_raster.rasterize(self.gpa, face, o, @floatFromInt(size_px)) catch return null;
        self.glyph_cache.put(self.gpa, key, bmp) catch return null;
        return self.glyph_cache.getPtr(key);
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
        .draw_image_uv = drawImageUv,
        .fill_path = fillPath,
        .stroke_path = strokePath,
        .push_clip = pushClip,
        .pop_clip = popClip,
        .push_translate = pushTranslate,
        .pop_translate = popTranslate,
        .push_clip_rounded = pushClipRounded,
        .push_layer = pushLayer,
        .pop_layer = popLayer,
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

    /// Integer content translation (#96): scroll offsets are pixel-snapped.
    fn transX(self: *const RasterBackend) i32 {
        return @intFromFloat(@round(self.translate.x));
    }
    fn transY(self: *const RasterBackend) i32 {
        return @intFromFloat(@round(self.translate.y));
    }

    fn setPixel(self: *RasterBackend, lx: i32, ly: i32, color: Color) void {
        // Local → device: shift by the accumulated content translation.
        const x = lx + self.transX();
        const y = ly + self.transY();
        if (self.rounded_clips > 0) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            for (self.clip_stack.items) |c| {
                if (c.round) |r| {
                    if (!insideRounded(r.rect, r.radius, px, py)) return;
                }
            }
        }
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

    /// The active clip in LOCAL coordinates: the device-absolute clip stack
    /// (intersected with the screen) shifted back by the content translation,
    /// so primitives can iterate in their own coordinate space (#96).
    fn currentClip(self: *const RasterBackend) IRect {
        var clip = self.screenRect();
        for (self.clip_stack.items) |c| clip = clip.intersect(c.bounds);
        return clip.offset(-self.transX(), -self.transY());
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
        std.debug.assert(self.translate_stack.items.len == 0);
        std.debug.assert(self.layers.items.len == 0);
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

    /// Paint a box shadow (#119) behind the rect: analytic Gaussian coverage
    /// (style.BoxShadow.coverage) blended as the shadow color, over the
    /// expanded bounds that capture the blur tail.
    fn drawShadow(self: *RasterBackend, rect: Rect, sh: style.BoxShadow) void {
        const margin = sh.blur * 2 + @abs(sh.spread) + 2;
        const sx0 = rect.x + sh.dx - sh.spread - margin;
        const sy0 = rect.y + sh.dy - sh.spread - margin;
        const sw = rect.width + 2 * (sh.spread + margin);
        const shh = rect.height + 2 * (sh.spread + margin);
        const bounds = IRect.fromRect(.{ .x = sx0, .y = sy0, .width = sw, .height = shh }).intersect(self.currentClip());
        if (bounds.isEmpty()) return;
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const cov = sh.coverage(rect.x, rect.y, rect.width, rect.height, px, py);
                if (cov <= 0) continue;
                const a: u8 = @intFromFloat(@round(cov * @as(f32, @floatFromInt(sh.color.a))));
                if (a == 0) continue;
                self.setPixel(x, y, .{ .r = sh.color.r, .g = sh.color.g, .b = sh.color.b, .a = a });
            }
        }
    }

    /// Paint an inset shadow (#119) on top of the rect, clipped to its rounded
    /// shape: 1 − coverage of the inner box (style.BoxShadow.insetCoverage).
    fn drawInsetShadow(self: *RasterBackend, rect: Rect, sh: style.BoxShadow, corner: style.CornerRadius) void {
        const bounds = IRect.fromRect(rect).intersect(self.currentClip());
        if (bounds.isEmpty()) return;
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (!insideRounded(rect, corner, px, py)) continue;
                const cov = sh.insetCoverage(rect.x, rect.y, rect.width, rect.height, px, py);
                const a: u8 = @intFromFloat(@round(cov * @as(f32, @floatFromInt(sh.color.a))));
                if (a == 0) continue;
                self.setPixel(x, y, .{ .r = sh.color.r, .g = sh.color.g, .b = sh.color.b, .a = a });
            }
        }
    }

    fn drawRect(ptr: *anyopaque, rect: Rect, rect_style: style.RectStyle) void {
        const self = self_(ptr);
        if (rect_style.shadow) |sh| if (!sh.inset) self.drawShadow(rect, sh);
        const bounds = IRect.fromRect(rect).intersect(self.currentClip());
        if (bounds.isEmpty()) {
            // Even with no fill bounds, an inset shadow may still apply.
            if (rect_style.shadow) |sh| if (sh.inset) self.drawInsetShadow(rect, sh, rect_style.corner_radius);
            return;
        }

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
                } else if (rect_style.gradient) |g| {
                    self.setPixel(x, y, g.colorAt(rect.x, rect.y, rect.width, rect.height, px, py));
                } else if (rect_style.background) |bg| {
                    self.setPixel(x, y, bg);
                }
            }
        }
        // Inset shadow paints on top of the fill, clipped to the rounded shape.
        if (rect_style.shadow) |sh| if (sh.inset) self.drawInsetShadow(rect, sh, rect_style.corner_radius);
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
        if (self.fonts != null) {
            self.drawTextGlyphs(origin, text, text_style);
            return;
        }
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
                    self.setPixel(x, y, text_style.color orelse Color.black);
                }
            }
        }
    }

    fn drawTextGlyphs(self: *RasterBackend, origin: geometry.Point, text: []const u8, text_style: style.TextStyle) void {
        const set = &(self.fonts.?);
        const size_px: u16 = @intFromFloat(@max(4, text_style.size));
        // Baseline comes from the primary face so mixed-face runs share a grid.
        const primary = set.primary();
        const ascent = @as(f32, @floatFromInt(primary.ascent)) * (@as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(primary.units_per_em)));
        const fstyle: fontset.Style = .{ .bold = text_style.bold, .italic = text_style.italic };
        const color = text_style.color orelse Color.black;
        const clip = self.currentClip();

        var pen_x = origin.x;
        const baseline = origin.y + ascent;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const r = set.resolve(cp, fstyle);
            const face = set.face(r.face_id);
            const fscale = @as(f32, @floatFromInt(size_px)) / @as(f32, @floatFromInt(face.units_per_em));
            const metrics = face.hMetrics(r.glyph);
            if (self.cachedGlyph(r.face_id, face, r.glyph, size_px)) |bmp| {
                const gx: i32 = @as(i32, @intFromFloat(@round(pen_x))) + bmp.x_off;
                const gy: i32 = @as(i32, @intFromFloat(@round(baseline))) + bmp.y_off;
                var y: usize = 0;
                while (y < bmp.height) : (y += 1) {
                    const py = gy + @as(i32, @intCast(y));
                    if (py < clip.y0 or py >= clip.y1) continue;
                    var x: usize = 0;
                    while (x < bmp.width) : (x += 1) {
                        const px = gx + @as(i32, @intCast(x));
                        if (px < clip.x0 or px >= clip.x1) continue;
                        const a = bmp.alpha[y * bmp.width + x];
                        if (a == 0) continue;
                        self.setPixel(px, py, .{ .r = color.r, .g = color.g, .b = color.b, .a = @intCast((@as(u16, a) * color.a) / 255) });
                    }
                }
            }
            pen_x += @as(f32, @floatFromInt(metrics.advance)) * fscale;
        }

        // Text decorations (#191): a filled line across the run, positioned by
        // the shared formula so GPU backends match.
        if (text_style.underline or text_style.strikethrough) {
            const run_w = pen_x - origin.x;
            if (text_style.underline) self.fillRunRect(style.TextDecoration.underlineRect(origin.x, baseline, run_w, text_style.size), color, clip);
            if (text_style.strikethrough) self.fillRunRect(style.TextDecoration.strikeRect(origin.x, baseline, run_w, text_style.size), color, clip);
        }
    }

    /// Fill a decoration line rect (local coords) within `clip`, via setPixel so
    /// it honors the content translation + rounded clip (#191).
    fn fillRunRect(self: *RasterBackend, rect: Rect, color: Color, clip: IRect) void {
        const r = IRect.fromRect(rect).intersect(clip);
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            var x = r.x0;
            while (x < r.x1) : (x += 1) self.setPixel(x, y, color);
        }
    }

    /// Fill a closed polygon (#120) with the even-odd rule
    /// (geometry.pointInPolygon, the shared reference) over its bounding box.
    fn fillPath(ptr: *anyopaque, points: []const geometry.Point, color: Color) void {
        const self = self_(ptr);
        if (points.len < 3) return;
        var minx: f32 = points[0].x;
        var miny: f32 = points[0].y;
        var maxx: f32 = points[0].x;
        var maxy: f32 = points[0].y;
        for (points[1..]) |p| {
            minx = @min(minx, p.x);
            miny = @min(miny, p.y);
            maxx = @max(maxx, p.x);
            maxy = @max(maxy, p.y);
        }
        const bounds = IRect.fromRect(.{ .x = minx, .y = miny, .width = maxx - minx, .height = maxy - miny }).intersect(self.currentClip());
        if (bounds.isEmpty()) return;
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (geometry.pointInPolygon(points, px, py)) self.setPixel(x, y, color);
            }
        }
    }

    /// Stroke a polyline (#120): fill pixels within half-width of any segment
    /// (geometry.pointNearPolyline — round caps/joins), over the expanded bbox.
    fn strokePath(ptr: *anyopaque, points: []const geometry.Point, width: f32, color: Color, closed: bool) void {
        const self = self_(ptr);
        if (points.len < 2) return;
        const hw = width * 0.5;
        var minx: f32 = points[0].x;
        var miny: f32 = points[0].y;
        var maxx: f32 = points[0].x;
        var maxy: f32 = points[0].y;
        for (points[1..]) |p| {
            minx = @min(minx, p.x);
            miny = @min(miny, p.y);
            maxx = @max(maxx, p.x);
            maxy = @max(maxy, p.y);
        }
        const bounds = IRect.fromRect(.{ .x = minx - hw, .y = miny - hw, .width = (maxx - minx) + width, .height = (maxy - miny) + width }).intersect(self.currentClip());
        if (bounds.isEmpty()) return;
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                if (geometry.pointNearPolyline(points, closed, hw, px, py)) self.setPixel(x, y, color);
            }
        }
    }

    fn drawImage(ptr: *anyopaque, rect: Rect, texture: *Backend.Texture) void {
        drawImageUv(ptr, rect, texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .nearest);
    }

    /// Draw the `src` UV sub-rect of the texture into `dst`. `nearest` snaps to
    /// the covering texel; `linear` is a bilinear lerp of the 4 neighbors with
    /// clamp-to-edge — the same math a GPU linear sampler runs, so the GPU
    /// backends match this reference within a small edge tolerance (#122).
    fn drawImageUv(ptr: *anyopaque, dst: Rect, texture: *Backend.Texture, src: Rect, sampling: Backend.Sampling) void {
        const self = self_(ptr);
        const tex = self.textures.get(@intCast(@intFromPtr(texture))) orelse unreachable;
        const bounds = IRect.fromRect(dst).intersect(self.currentClip());
        if (bounds.isEmpty()) return;
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        const maxx: i32 = @intCast(tex.width - 1);
        const maxy: i32 = @intCast(tex.height - 1);
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                const fx = (@as(f32, @floatFromInt(x)) + 0.5 - dst.x) / dst.width;
                const fy = (@as(f32, @floatFromInt(y)) + 0.5 - dst.y) / dst.height;
                const u = src.x + fx * src.width;
                const v = src.y + fy * src.height;
                const px = switch (sampling) {
                    .nearest => blk: {
                        const tx: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(u * tw))), 0, maxx);
                        const ty: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(v * th))), 0, maxy);
                        break :blk texel(tex, tx, ty);
                    },
                    .linear => blk: {
                        // Sample point in texel space; texel centers at +0.5.
                        const sx = u * tw - 0.5;
                        const sy = v * th - 0.5;
                        const x0: i32 = @intFromFloat(@floor(sx));
                        const y0: i32 = @intFromFloat(@floor(sy));
                        const fxr = sx - @floor(sx);
                        const fyr = sy - @floor(sy);
                        const cx0 = std.math.clamp(x0, 0, maxx);
                        const cx1 = std.math.clamp(x0 + 1, 0, maxx);
                        const cy0 = std.math.clamp(y0, 0, maxy);
                        const cy1 = std.math.clamp(y0 + 1, 0, maxy);
                        const c00 = texel(tex, cx0, cy0);
                        const c10 = texel(tex, cx1, cy0);
                        const c01 = texel(tex, cx0, cy1);
                        const c11 = texel(tex, cx1, cy1);
                        break :blk lerp2(c00, c10, c01, c11, fxr, fyr);
                    },
                };
                self.setPixel(x, y, px);
            }
        }
    }

    fn texel(tex: anytype, x: i32, y: i32) Color {
        const ti = (@as(usize, @intCast(y)) * tex.width + @as(usize, @intCast(x))) * 4;
        return .{ .r = tex.rgba[ti + 0], .g = tex.rgba[ti + 1], .b = tex.rgba[ti + 2], .a = tex.rgba[ti + 3] };
    }

    fn lerp2(c00: Color, c10: Color, c01: Color, c11: Color, fx: f32, fy: f32) Color {
        return .{
            .r = bilerp(c00.r, c10.r, c01.r, c11.r, fx, fy),
            .g = bilerp(c00.g, c10.g, c01.g, c11.g, fx, fy),
            .b = bilerp(c00.b, c10.b, c01.b, c11.b, fx, fy),
            .a = bilerp(c00.a, c10.a, c01.a, c11.a, fx, fy),
        };
    }

    fn bilerp(a: u8, b: u8, c: u8, d: u8, fx: f32, fy: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        const cf: f32 = @floatFromInt(c);
        const df: f32 = @floatFromInt(d);
        const top = af + (bf - af) * fx;
        const bot = cf + (df - cf) * fx;
        return @intFromFloat(@round(top + (bot - top) * fy));
    }

    /// Shift a local rect into device space by the content translation (#96).
    fn deviceRect(self: *const RasterBackend, rect: Rect) Rect {
        return .{ .x = rect.x + self.translate.x, .y = rect.y + self.translate.y, .width = rect.width, .height = rect.height };
    }

    fn pushClip(ptr: *anyopaque, rect: Rect) void {
        const self = self_(ptr);
        self.clip_stack.append(self.gpa, .{ .bounds = IRect.fromRect(self.deviceRect(rect)) }) catch {};
    }

    /// Rounded clip (#117): the bounds rect still bounds iteration; the
    /// per-corner radii are enforced per-pixel in setPixel. Stored device-
    /// absolute so it composes with the content translation (#96).
    fn pushClipRounded(ptr: *anyopaque, rect: Rect, radius: style.CornerRadius) void {
        const self = self_(ptr);
        if (radius.isNone()) return pushClip(ptr, rect);
        const dr = self.deviceRect(rect);
        self.clip_stack.append(self.gpa, .{
            .bounds = IRect.fromRect(dr),
            .round = .{ .rect = dr, .radius = radius },
        }) catch return;
        self.rounded_clips += 1;
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        std.debug.assert(self.clip_stack.items.len > 0);
        const c = self.clip_stack.pop().?;
        if (c.round != null) self.rounded_clips -= 1;
    }

    fn pushTranslate(ptr: *anyopaque, dx: f32, dy: f32) void {
        const self = self_(ptr);
        self.translate_stack.append(self.gpa, self.translate) catch return;
        self.translate.x += dx;
        self.translate.y += dy;
    }

    fn popTranslate(ptr: *anyopaque) void {
        const self = self_(ptr);
        std.debug.assert(self.translate_stack.items.len > 0);
        self.translate = self.translate_stack.pop().?;
    }

    /// Redirect draws into a fresh transparent buffer (#121). The buffer is
    /// the same size as the target so coordinates and the clip stack carry
    /// over unchanged.
    fn pushLayer(ptr: *anyopaque, opacity: f32) Backend.Error!void {
        const self = self_(ptr);
        const buf = self.gpa.alloc(u8, self.pixels.len) catch return error.OutOfMemory;
        @memset(buf, 0); // transparent
        self.layers.append(self.gpa, .{ .parent = self.pixels, .opacity = opacity }) catch {
            self.gpa.free(buf);
            return error.OutOfMemory;
        };
        self.pixels = buf;
    }

    /// Composite the layer's isolated buffer over its parent with straight-
    /// alpha source-over, scaling each source pixel's alpha by the layer
    /// opacity — the reference semantics GPU backends match.
    fn popLayer(ptr: *anyopaque) void {
        const self = self_(ptr);
        const layer = self.layers.pop().?;
        const src = self.pixels;
        const dst = layer.parent;
        const op: u32 = @intFromFloat(@round(std.math.clamp(layer.opacity, 0, 1) * 255));
        var i: usize = 0;
        while (i < src.len) : (i += 4) {
            const ea: u32 = (@as(u32, src[i + 3]) * op) / 255;
            if (ea == 0) continue;
            const da: u32 = 255 - ea;
            dst[i + 0] = @intCast((ea * src[i + 0] + da * dst[i + 0]) / 255);
            dst[i + 1] = @intCast((ea * src[i + 1] + da * dst[i + 1]) / 255);
            dst[i + 2] = @intCast((ea * src[i + 2] + da * dst[i + 2]) / 255);
            dst[i + 3] = @intCast(@min(255, ea + (da * dst[i + 3]) / 255));
        }
        self.gpa.free(src);
        self.pixels = dst;
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
        if (self.fonts) |*set| {
            const fstyle: fontset.Style = .{ .bold = text_style.bold, .italic = text_style.italic };
            var width: f32 = 0;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepoint()) |cp| {
                const r = set.resolve(cp, fstyle);
                const face = set.face(r.face_id);
                width += @as(f32, @floatFromInt(face.hMetrics(r.glyph).advance)) * (text_style.size / @as(f32, @floatFromInt(face.units_per_em)));
            }
            // Line height from the primary face's vertical metrics.
            const primary = set.primary();
            const line = @as(f32, @floatFromInt(primary.ascent - primary.descent + primary.line_gap)) * (text_style.size / @as(f32, @floatFromInt(primary.units_per_em)));
            return .{ .width = width, .height = line };
        }
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

test "rounded clip cuts the corner of clipped content" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 16, .height = 16 });
    b.pushClipRounded(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, .all(6));
    // A full-viewport fill is clipped to the rounded region.
    b.drawRect(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .background = Color.rgb(255, 0, 0) });
    b.popClip();
    try b.endFrame();

    try expectPixel(&raster, 0, 0, Color.white); // corner cut by the clip
    try expectPixel(&raster, 8, 8, Color.rgb(255, 0, 0)); // center kept
    try expectPixel(&raster, 8, 0, Color.rgb(255, 0, 0)); // top edge midpoint kept
    try expectPixel(&raster, 15, 15, Color.white); // opposite corner cut
    try testing.expectEqual(@as(usize, 0), raster.rounded_clips); // balanced pop
}

test "box shadow paints a blurred halo behind the rect" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 40, .height = 40 });
    // Opaque black rect with a blurred black shadow, no offset.
    b.drawRect(.{ .x = 14, .y = 14, .width = 12, .height = 12 }, .{
        .background = Color.black,
        .shadow = .{ .color = Color.black, .blur = 8 },
    });
    try b.endFrame();

    // Rect interior stays solid black.
    try expectPixel(&raster, 20, 20, Color.black);
    // Just outside the rect: a gray shadow halo (between white and black).
    const halo = raster.pixelAt(28, 20);
    try testing.expect(halo.r > 20 and halo.r < 235);
    // Far away: untouched white.
    try expectPixel(&raster, 2, 2, Color.white);
}

test "group opacity composites layer over backdrop" {
    var raster = RasterBackend.init(testing.allocator);
    defer raster.deinit();
    const b = raster.interface();

    try b.beginFrame(.{ .width = 8, .height = 4 });
    // Opaque red backdrop across the left half; white clear elsewhere.
    b.drawRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, .{ .background = Color.rgb(255, 0, 0) });
    // A 50%-opacity layer drawing an opaque blue rect over the whole viewport.
    try b.pushLayer(0.5);
    b.drawRect(.{ .x = 0, .y = 0, .width = 8, .height = 4 }, .{ .background = Color.rgb(0, 0, 255) });
    b.popLayer();
    try b.endFrame();

    // Over red: 0.5*blue + 0.5*red → (127, 0, 127).
    const over_red = raster.pixelAt(2, 2);
    try testing.expect(over_red.r > 122 and over_red.r < 132);
    try testing.expectEqual(@as(u8, 0), over_red.g);
    try testing.expect(over_red.b > 122 and over_red.b < 132);
    // Over white: 0.5*blue + 0.5*white → (127, 127, 255).
    const over_white = raster.pixelAt(6, 2);
    try testing.expect(over_white.r > 122 and over_white.r < 132);
    try testing.expect(over_white.g > 122 and over_white.g < 132);
    try testing.expectEqual(@as(u8, 255), over_white.b);
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
