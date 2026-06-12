//! Native GUI demo. macOS: ships as Zooee Demo.app (zig build assembles
//! it). Opens a real window and pumps events until closed; the client
//! area stays unpainted until the raster blit lands (next #9 slice).

const std = @import("std");
const builtin = @import("builtin");
const zooee = @import("zooee");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const platform = switch (builtin.os.tag) {
        .macos => zooee.platform.macos,
        .windows => zooee.platform.win32,
        else => @compileError("gui demo: unsupported OS (X11 is #9 follow-up)"),
    };

    const w = try platform.Window.create(gpa, .{ .title = "zooee — native window" });
    defer w.destroy();

    outer: while (true) {
        for (w.pumpEvents()) |ev| switch (ev) {
            .close_requested => break :outer,
            else => {},
        };
        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
