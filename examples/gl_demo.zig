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
    try out.print("GL clear: center=({d},{d},{d}) want=({d},{d},{d}) {s}\n", .{ got[0], got[1], got[2], want[0], want[1], want[2], if (ok) "PASS" else "FAIL" });

    // Slice 2: textured-quad → FBO → readback round-trip. Upload a known
    // image, render it 1:1 through the shader/texture/FBO pipeline, and
    // check it comes back (NEAREST, same size → near-exact).
    var qr = gl.QuadRenderer.init() catch |err| {
        try out.print("GL-QUAD-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    const tw: u32 = 16;
    const th: u32 = 16;
    const src = try gpa.alloc(u8, tw * th * 4);
    for (0..th) |yy| for (0..tw) |xx| {
        const k = (yy * tw + xx) * 4;
        src[k + 0] = if (xx < tw / 2) 200 else 40; // left red-ish / right dark
        src[k + 1] = if (yy < th / 2) 180 else 30; // top green-ish
        src[k + 2] = 90;
        src[k + 3] = 255;
    };
    const back = try qr.renderOffscreen(gpa, src, tw, th);
    var max_diff: u8 = 0;
    for (src, back) |sv, bv| {
        const d = if (sv > bv) sv - bv else bv - sv;
        if (d > max_diff) max_diff = d;
    }
    const quad_ok = max_diff <= 4;
    try out.print("GL quad round-trip: max channel diff {d} {s}\n", .{ max_diff, if (quad_ok) "PASS" else "FAIL" });

    // Slice 3: native rect geometry. Render left-half red / right-half
    // blue via the rect shader to an FBO; check the halves came out.
    var rr = gl.RectRenderer.init() catch |err| {
        try out.print("GL-RECT-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    const rw: u32 = 40;
    const rh: u32 = 24;
    const rpx = try gl.renderRectsOffscreen(gpa, &rr, rw, rh, .{ 0, 0, 0, 1 }, &rectScene);
    const li = ((rh / 2) * rw + rw / 4) * 4; // left quarter
    const ri = ((rh / 2) * rw + (rw * 3) / 4) * 4; // right quarter
    const rect_ok = approx(rpx[li], 255) and approx(rpx[li + 1], 0) and approx(rpx[li + 2], 0) and
        approx(rpx[ri], 0) and approx(rpx[ri + 1], 0) and approx(rpx[ri + 2], 255);
    try out.print("GL native rects: left=({d},{d},{d}) right=({d},{d},{d}) {s}\n", .{ rpx[li], rpx[li + 1], rpx[li + 2], rpx[ri], rpx[ri + 1], rpx[ri + 2], if (rect_ok) "PASS" else "FAIL" });

    // Slice 4: SDF rounded rect + border. White rounded card, blue border,
    // on black. center=white(bg), mid-left edge=blue(border), corner=cut.
    var rrr = gl.RoundedRectRenderer.init() catch |err| {
        try out.print("GL-ROUND-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    const sw: u32 = 40;
    const sh: u32 = 32;
    const spx = try gl.renderRoundedOffscreen(gpa, &rrr, sw, sh, .{ 0, 0, 0, 1 }, &roundedScene);
    const ci = ((sh / 2) * sw + sw / 2) * 4; // center → bg white
    const ei = ((sh / 2) * sw + 5) * 4; // mid-left edge → border blue
    const corner = (5 * sw + 5) * 4; // near top-left corner → cut (black)
    const round_ok = approx(spx[ci], 255) and approx(spx[ci + 1], 255) and approx(spx[ci + 2], 255) and
        spx[ei] < 40 and spx[ei + 2] > 200 and
        spx[corner] < 40 and spx[corner + 2] < 70;
    try out.print("GL rounded+border: center=({d},{d},{d}) edge=({d},{d},{d}) corner=({d},{d},{d}) {s}\n", .{ spx[ci], spx[ci + 1], spx[ci + 2], spx[ei], spx[ei + 1], spx[ei + 2], spx[corner], spx[corner + 1], spx[corner + 2], if (round_ok) "PASS" else "FAIL" });
    try out.flush();
    if (!ok or !quad_ok or !rect_ok or !round_ok) std.process.exit(1);
}

fn rectScene(rr: *gl.RectRenderer) void {
    rr.fillRect(0, 0, rr.vw / 2, rr.vh, .{ 1, 0, 0, 1 }); // left half red
    rr.fillRect(rr.vw / 2, 0, rr.vw / 2, rr.vh, .{ 0, 0, 1, 1 }); // right half blue
}

fn roundedScene(rr: *gl.RoundedRectRenderer) void {
    rr.draw(4, 4, 32, 24, 6, 3, .{ 1, 1, 1, 1 }, .{ 0, 0.47, 1, 1 });
}

fn approx(a: u8, b: u8) bool {
    return (if (a > b) a - b else b - a) <= 2;
}
