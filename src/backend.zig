//! The draw-primitive backend interface — the seam between the framework
//! core and every rendering backend (terminal, OpenGL, DirectX, web).
//!
//! Design record lives on issue #2:
//! - Primitives: rect, text, image, clip push/pop. Margin/padding never
//!   reach a backend; layout resolves the box model first.
//! - Coordinates are in the backend's native units; layout snaps through
//!   `snap` as it goes (#3), so draw calls receive on-grid geometry.
//! - Styles carry intent; backends may quantize (see style.zig).
//!
//! Runtime-dispatched vtable in the style of `std.Io.Writer`, so an app
//! can pick its backend from a CLI flag.

const std = @import("std");
const geometry = @import("geometry.zig");
const style = @import("style.zig");

const Axis = geometry.Axis;
const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const RectStyle = style.RectStyle;
const TextStyle = style.TextStyle;
const CornerRadius = style.CornerRadius;

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Backend-owned texture handle (#2: textures are opaque; pixel data
    /// is raw RGBA — image decoding lives outside the backend).
    pub const Texture = opaque {};

    pub const Error = error{
        OutOfMemory,
        BackendFailure,
    };

    pub const VTable = struct {
        begin_frame: *const fn (ptr: *anyopaque, viewport: Size) Error!void,
        end_frame: *const fn (ptr: *anyopaque) Error!void,

        draw_rect: *const fn (ptr: *anyopaque, rect: Rect, rect_style: RectStyle) void,
        draw_text: *const fn (ptr: *anyopaque, origin: Point, text: []const u8, text_style: TextStyle) void,
        draw_image: *const fn (ptr: *anyopaque, rect: Rect, texture: *Texture) void,

        // Image with an explicit source sub-rect in UV space (#122): samples
        // only `src` (uv 0..1) of the texture into `dst`, with `sampling`
        // (nearest or bilinear). Powers fit modes and 9-slice. Optional —
        // degrades to a full-texture `draw_image` (nearest).
        draw_image_uv: ?*const fn (ptr: *anyopaque, dst: Rect, texture: *Texture, src: Rect, sampling: Sampling) void = null,

        // Filled arbitrary path (#120): fill the closed polygon `points` with
        // `color` using the even-odd rule (geometry.pointInPolygon). Optional —
        // backends that can't (terminal) leave it null and `fillPath` no-ops.
        fill_path: ?*const fn (ptr: *anyopaque, points: []const Point, color: style.Color) void = null,

        // Stroked path / polyline (#120): stroke the polyline `points` with
        // `width` (round caps/joins) in `color`; `closed` joins last→first.
        // Optional — degrades to no-op (terminal).
        stroke_path: ?*const fn (ptr: *anyopaque, points: []const Point, width: f32, color: style.Color, closed: bool) void = null,

        push_clip: *const fn (ptr: *anyopaque, rect: Rect) void,
        pop_clip: *const fn (ptr: *anyopaque) void,

        // Content translation for scroll viewports (#96): shift all subsequent
        // draws (and pushed clips) by `(dx, dy)` until the matching
        // `pop_translate`. Offsets accumulate; a scroll region pushes a clip to
        // the viewport then translates content by (-scrollX, -scrollY).
        // Optional — backends without it leave them null and `pushTranslate`
        // degrades to no-op (content draws unscrolled, still clipped).
        push_translate: ?*const fn (ptr: *anyopaque, dx: f32, dy: f32) void = null,
        pop_translate: ?*const fn (ptr: *anyopaque) void = null,

        // Rounded-rect clipping (#117). A backend that can clip to per-corner
        // radii registers this; the rest leave it null and `pushClipRounded`
        // degrades to a rectangular `pushClip` (corners not cut). Paired with
        // the same `popClip` — it pushes one clip entry either way.
        push_clip_rounded: ?*const fn (ptr: *anyopaque, rect: Rect, radius: CornerRadius) void = null,

        // Group opacity / offscreen layers (#121). A backend that can
        // composite an isolated layer registers these; the rest leave them
        // null and `pushLayer`/`popLayer` degrade to passthrough (children
        // draw directly at full opacity). `opacity` is 0..1.
        push_layer: ?*const fn (ptr: *anyopaque, opacity: f32) Error!void = null,
        pop_layer: ?*const fn (ptr: *anyopaque) void = null,

        create_texture: *const fn (ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Error!*Texture,
        destroy_texture: *const fn (ptr: *anyopaque, texture: *Texture) void,

        // Metrics (#3): layout snaps every committed edge through the
        // backend so independently-rounded children still tile exactly.
        measure_text: *const fn (ptr: *anyopaque, text: []const u8, text_style: TextStyle) Size,
        snap: *const fn (ptr: *anyopaque, value: f32, axis: Axis) f32,
    };

    pub fn beginFrame(self: Backend, viewport: Size) Error!void {
        return self.vtable.begin_frame(self.ptr, viewport);
    }

    pub fn endFrame(self: Backend) Error!void {
        return self.vtable.end_frame(self.ptr);
    }

    pub fn drawRect(self: Backend, rect: Rect, rect_style: RectStyle) void {
        self.vtable.draw_rect(self.ptr, rect, rect_style);
    }

    pub fn drawText(self: Backend, origin: Point, text: []const u8, text_style: TextStyle) void {
        self.vtable.draw_text(self.ptr, origin, text, text_style);
    }

    pub fn drawImage(self: Backend, rect: Rect, texture: *Texture) void {
        self.vtable.draw_image(self.ptr, rect, texture);
    }

    /// How an image is scaled into its destination rect (#122).
    pub const ImageFit = enum {
        /// Fill the rect, ignoring aspect ratio (the legacy behaviour).
        stretch,
        /// Scale to fit inside, preserving aspect; letterboxed/centered.
        contain,
        /// Scale to fill, preserving aspect; the overflow is cropped.
        cover,
    };

    /// Texture filtering for image draws (#122). `linear` (bilinear) is the
    /// canonical smooth filter; CPU and GPU implementations agree only within
    /// a small tolerance at texel edges, never byte-exact.
    pub const Sampling = enum { nearest, linear };

    /// Draw `texture` into `dst`, sampling only its `src` UV sub-rect.
    pub fn drawImageUv(self: Backend, dst: Rect, texture: *Texture, src: Rect, sampling: Sampling) void {
        if (self.vtable.draw_image_uv) |f| f(self.ptr, dst, texture, src, sampling) else self.vtable.draw_image(self.ptr, dst, texture);
    }

    /// Draw a `src_w`×`src_h` image into `dst` honoring the `fit` mode (#122):
    /// `contain` shrinks the destination sub-rect, `cover` crops the source.
    pub fn drawImageFit(self: Backend, dst: Rect, texture: *Texture, src_w: f32, src_h: f32, fit: ImageFit, sampling: Sampling) void {
        switch (fit) {
            .stretch => self.drawImageUv(dst, texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, sampling),
            .contain => {
                const scale = @min(dst.width / src_w, dst.height / src_h);
                const dw = src_w * scale;
                const dh = src_h * scale;
                const inner: Rect = .{ .x = dst.x + (dst.width - dw) * 0.5, .y = dst.y + (dst.height - dh) * 0.5, .width = dw, .height = dh };
                self.drawImageUv(inner, texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, sampling);
            },
            .cover => {
                const scale = @max(dst.width / src_w, dst.height / src_h);
                const uw = dst.width / (src_w * scale); // visible fraction of u
                const vh = dst.height / (src_h * scale);
                self.drawImageUv(dst, texture, .{ .x = (1 - uw) * 0.5, .y = (1 - vh) * 0.5, .width = uw, .height = vh }, sampling);
            },
        }
    }

    /// Source-pixel insets for 9-slice scaling (#122): the border thickness
    /// that stays unscaled. `l`/`t`/`r`/`b` are measured from each edge.
    pub const NineSlice = struct { l: f32, t: f32, r: f32, b: f32 };

    /// 9-slice an `src_w`×`src_h` image into `dst` (#122): the 4 corners draw
    /// at their source pixel size, the 4 edges stretch along one axis, and the
    /// center stretches both — the canonical resizable-button/panel technique.
    /// Issues 9 `drawImageUv` calls (nearest), so it's pixel-exact everywhere.
    pub fn drawImageNine(self: Backend, dst: Rect, texture: *Texture, src_w: f32, src_h: f32, ins: NineSlice) void {
        // Destination column/row edges: corners keep their source size.
        const dx0 = dst.x;
        const dx1 = dst.x + ins.l;
        const dx2 = dst.x + dst.width - ins.r;
        const dx3 = dst.x + dst.width;
        const dy0 = dst.y;
        const dy1 = dst.y + ins.t;
        const dy2 = dst.y + dst.height - ins.b;
        const dy3 = dst.y + dst.height;
        // Source UV edges.
        const ux0: f32 = 0;
        const ux1 = ins.l / src_w;
        const ux2 = (src_w - ins.r) / src_w;
        const ux3: f32 = 1;
        const uy0: f32 = 0;
        const uy1 = ins.t / src_h;
        const uy2 = (src_h - ins.b) / src_h;
        const uy3: f32 = 1;
        const dxs = [4]f32{ dx0, dx1, dx2, dx3 };
        const dys = [4]f32{ dy0, dy1, dy2, dy3 };
        const uxs = [4]f32{ ux0, ux1, ux2, ux3 };
        const uys = [4]f32{ uy0, uy1, uy2, uy3 };
        var row: usize = 0;
        while (row < 3) : (row += 1) {
            var col: usize = 0;
            while (col < 3) : (col += 1) {
                const d: Rect = .{ .x = dxs[col], .y = dys[row], .width = dxs[col + 1] - dxs[col], .height = dys[row + 1] - dys[row] };
                if (d.width <= 0 or d.height <= 0) continue;
                const s: Rect = .{ .x = uxs[col], .y = uys[row], .width = uxs[col + 1] - uxs[col], .height = uys[row + 1] - uys[row] };
                self.drawImageUv(d, texture, s, .nearest);
            }
        }
    }

    /// Fill a closed polygon (#120) with `color`, even-odd rule. Backends
    /// without path support (terminal) no-op.
    pub fn fillPath(self: Backend, points: []const Point, color: style.Color) void {
        if (self.vtable.fill_path) |f| f(self.ptr, points, color);
    }

    /// Stroke a polyline (#120) with `width` (round caps/joins) in `color`;
    /// `closed` joins the last point back to the first. Backends without it no-op.
    pub fn strokePath(self: Backend, points: []const Point, width: f32, color: style.Color, closed: bool) void {
        if (self.vtable.stroke_path) |f| f(self.ptr, points, width, color, closed);
    }

    pub fn pushClip(self: Backend, rect: Rect) void {
        self.vtable.push_clip(self.ptr, rect);
    }

    pub fn popClip(self: Backend) void {
        self.vtable.pop_clip(self.ptr);
    }

    /// Translate subsequent draws and clips by `(dx, dy)` (#96). Pop with
    /// `popTranslate`. Backends without translation draw unscrolled (degraded
    /// but still clipped to any active viewport).
    pub fn pushTranslate(self: Backend, dx: f32, dy: f32) void {
        if (self.vtable.push_translate) |f| f(self.ptr, dx, dy);
    }

    pub fn popTranslate(self: Backend) void {
        if (self.vtable.pop_translate) |f| f(self.ptr);
    }

    /// Clip subsequent draws to a rounded rect (#117). Backends without
    /// rounded-clip support fall back to a rectangular clip (corners not cut).
    /// Pop with `popClip`, exactly like `pushClip`.
    pub fn pushClipRounded(self: Backend, rect: Rect, radius: CornerRadius) void {
        if (self.vtable.push_clip_rounded) |f| f(self.ptr, rect, radius) else self.vtable.push_clip(self.ptr, rect);
    }

    /// Begin an isolated layer: subsequent draws accumulate into an offscreen
    /// surface that is composited over the current target at `opacity` (0..1)
    /// on the matching `popLayer`. Backends without layer support draw the
    /// children directly at full opacity (degraded, structurally correct).
    pub fn pushLayer(self: Backend, opacity: f32) Error!void {
        if (self.vtable.push_layer) |f| return f(self.ptr, opacity);
    }

    pub fn popLayer(self: Backend) void {
        if (self.vtable.pop_layer) |f| f(self.ptr);
    }

    pub fn createTexture(self: Backend, width: u32, height: u32, rgba: []const u8) Error!*Texture {
        std.debug.assert(rgba.len == @as(usize, width) * height * 4);
        return self.vtable.create_texture(self.ptr, width, height, rgba);
    }

    pub fn destroyTexture(self: Backend, texture: *Texture) void {
        self.vtable.destroy_texture(self.ptr, texture);
    }

    pub fn measureText(self: Backend, text: []const u8, text_style: TextStyle) Size {
        return self.vtable.measure_text(self.ptr, text, text_style);
    }

    pub fn snap(self: Backend, value: f32, axis: Axis) f32 {
        return self.vtable.snap(self.ptr, value, axis);
    }
};
