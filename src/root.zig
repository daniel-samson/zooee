//! Zooee — a cross-platform UI framework with pluggable rendering
//! backends (terminal, DirectX, OpenGL, web).

const std = @import("std");

pub const geometry = @import("geometry.zig");
pub const style = @import("style.zig");
pub const backend = @import("backend.zig");
pub const backends = struct {
    pub const record = @import("backends/record.zig");
};

pub const Backend = backend.Backend;
pub const Color = style.Color;
pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Size = geometry.Size;

test {
    std.testing.refAllDecls(@This());
}
