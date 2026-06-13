//! GL context bring-up verification (#11 slice 1): create a GLX window,
//! clear to a known color, present, read pixels back, and assert the GPU
//! actually rendered that color. Self-checking — prints PASS/FAIL and
//! exits nonzero on mismatch, so it runs headless under Xvfb/llvmpipe in
//! CI without needing a screenshot.

const std = @import("std");
const gl = @import("zooee").backends.gl;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &fw.interface;

    var win = gl.GlWindow.create("zooee gl", 200, 150) catch |err| {
        try out.print("GL-CREATE-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer win.destroy();

    // Distinctive teal so a stray clear can't accidentally pass.
    const r: f32 = 0.10;
    const g: f32 = 0.60;
    const b: f32 = 0.70;
    win.clearAndPresent(r, g, b, 1.0);

    const px = try win.readPixels(gpa);
    // Center pixel.
    const i = ((win.height / 2) * win.width + win.width / 2) * 4;
    const got = .{ px[i], px[i + 1], px[i + 2] };
    const want = .{
        @as(u8, @intFromFloat(r * 255 + 0.5)),
        @as(u8, @intFromFloat(g * 255 + 0.5)),
        @as(u8, @intFromFloat(b * 255 + 0.5)),
    };
    // Allow ±2 for any colorspace/rounding wobble across GL implementations.
    const ok = approx(got[0], want[0]) and approx(got[1], want[1]) and approx(got[2], want[2]);
    try out.print("GL readback center=({d},{d},{d}) want=({d},{d},{d}) {s}\n", .{ got[0], got[1], got[2], want[0], want[1], want[2], if (ok) "PASS" else "FAIL" });
    try out.flush();
    if (!ok) std.process.exit(1);
}

fn approx(a: u8, b: u8) bool {
    return (if (a > b) a - b else b - a) <= 2;
}
