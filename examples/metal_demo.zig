//! Metal bring-up verification (#101 slice 1): create a Metal device +
//! offscreen render target, clear it to a known color, read it back, and
//! assert the GPU produced that color. Self-checking — prints PASS/FAIL and
//! exits nonzero on mismatch, so CI can run it headless.

const std = @import("std");
const builtin = @import("builtin");
const metal = @import("zooee").backends.metal;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &fw.interface;

    var off = metal.MetalOffscreen.create(40, 24) catch |err| {
        try out.print("METAL-CREATE-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer off.destroy();

    // Distinctive teal so a stray clear can't accidentally pass.
    const r: f32 = 0.10;
    const g: f32 = 0.60;
    const b: f32 = 0.70;
    off.clear(r, g, b, 1.0);

    const px = try off.readPixels(gpa);
    defer gpa.free(px);
    const i = ((off.height / 2) * off.width + off.width / 2) * 4;
    const got = .{ px[i], px[i + 1], px[i + 2] };
    const want = .{
        @as(u8, @intFromFloat(r * 255 + 0.5)),
        @as(u8, @intFromFloat(g * 255 + 0.5)),
        @as(u8, @intFromFloat(b * 255 + 0.5)),
    };
    // Allow ±2 for any colorspace/rounding wobble.
    const ok = approx(got[0], want[0]) and approx(got[1], want[1]) and approx(got[2], want[2]);
    try out.print("Metal clear: center=({d},{d},{d}) want=({d},{d},{d}) {s}\n", .{ got[0], got[1], got[2], want[0], want[1], want[2], if (ok) "PASS" else "FAIL" });

    try out.flush();
    if (!ok) std.process.exit(1);
}

fn approx(a: u8, b: u8) bool {
    return (if (a > b) a - b else b - a) <= 2;
}
