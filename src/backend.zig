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

        // Filled arbitrary path (#120): fill the closed polygon `points` with
        // `color` using the even-odd rule (geometry.pointInPolygon). Optional —
        // backends that can't (terminal) leave it null and `fillPath` no-ops.
        fill_path: ?*const fn (ptr: *anyopaque, points: []const Point, color: style.Color) void = null,

        push_clip: *const fn (ptr: *anyopaque, rect: Rect) void,
        pop_clip: *const fn (ptr: *anyopaque) void,

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

    /// Fill a closed polygon (#120) with `color`, even-odd rule. Backends
    /// without path support (terminal) no-op.
    pub fn fillPath(self: Backend, points: []const Point, color: style.Color) void {
        if (self.vtable.fill_path) |f| f(self.ptr, points, color);
    }

    pub fn pushClip(self: Backend, rect: Rect) void {
        self.vtable.push_clip(self.ptr, rect);
    }

    pub fn popClip(self: Backend) void {
        self.vtable.pop_clip(self.ptr);
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
