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

    // Slice 2: textured-quad round-trip. Upload a known image, render it 1:1
    // through the shader/texture pipeline, and check it comes back (NEAREST,
    // same size → near-exact), incl. correct top-down orientation.
    var qr = metal.MetalQuadRenderer.init() catch |err| {
        try out.print("METAL-QUAD-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer qr.deinit();
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
    defer gpa.free(back);
    var max_diff: u8 = 0;
    for (src, back) |sv, bv| {
        const d = if (sv > bv) sv - bv else bv - sv;
        if (d > max_diff) max_diff = d;
    }
    const quad_ok = max_diff <= 4;
    try out.print("Metal quad round-trip: max channel diff {d} {s}\n", .{ max_diff, if (quad_ok) "PASS" else "FAIL" });

    // Slice 3: native rect geometry. Render left-half red / right-half blue
    // via the rect shader; check the halves came out.
    var rr = metal.MetalRectRenderer.init() catch |err| {
        try out.print("METAL-RECT-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer rr.deinit();
    const rw: u32 = 40;
    const rh: u32 = 24;
    const rpx = try rr.renderOffscreen(gpa, rw, rh, .{ 0, 0, 0, 1 }, &rectScene);
    defer gpa.free(rpx);
    const li = ((rh / 2) * rw + rw / 4) * 4; // left quarter
    const ri = ((rh / 2) * rw + (rw * 3) / 4) * 4; // right quarter
    const rect_ok = approx(rpx[li], 255) and approx(rpx[li + 1], 0) and approx(rpx[li + 2], 0) and
        approx(rpx[ri], 0) and approx(rpx[ri + 1], 0) and approx(rpx[ri + 2], 255);
    try out.print("Metal native rects: left=({d},{d},{d}) right=({d},{d},{d}) {s}\n", .{ rpx[li], rpx[li + 1], rpx[li + 2], rpx[ri], rpx[ri + 1], rpx[ri + 2], if (rect_ok) "PASS" else "FAIL" });

    // Slice 4: SDF rounded rect + border. White rounded card, blue border, on
    // black. center=white(bg), mid-left edge=blue(border), corner=cut(black).
    var rrr = metal.MetalRoundedRectRenderer.init() catch |err| {
        try out.print("METAL-ROUND-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer rrr.deinit();
    const sw: u32 = 40;
    const sh: u32 = 32;
    const spx = try rrr.renderOffscreen(gpa, sw, sh, .{ 0, 0, 0, 1 }, &roundedScene);
    defer gpa.free(spx);
    const ci = ((sh / 2) * sw + sw / 2) * 4; // center → bg white
    const ei = ((sh / 2) * sw + 5) * 4; // mid-left edge → border blue
    const corner = (5 * sw + 5) * 4; // near top-left corner → cut (black)
    const round_ok = approx(spx[ci], 255) and approx(spx[ci + 1], 255) and approx(spx[ci + 2], 255) and
        spx[ei] < 40 and spx[ei + 2] > 200 and
        spx[corner] < 40 and spx[corner + 2] < 70;
    try out.print("Metal rounded+border: center=({d},{d},{d}) edge=({d},{d},{d}) corner=({d},{d},{d}) {s}\n", .{ spx[ci], spx[ci + 1], spx[ci + 2], spx[ei], spx[ei + 1], spx[ei + 2], spx[corner], spx[corner + 1], spx[corner + 2], if (round_ok) "PASS" else "FAIL" });

    try out.flush();
    if (!ok or !quad_ok or !rect_ok or !round_ok) std.process.exit(1);
}

fn rectScene(rr: *metal.MetalRectRenderer) void {
    rr.fillRect(0, 0, rr.vw / 2, rr.vh, .{ 1, 0, 0, 1 }); // left half red
    rr.fillRect(rr.vw / 2, 0, rr.vw / 2, rr.vh, .{ 0, 0, 1, 1 }); // right half blue
}

fn roundedScene(rr: *metal.MetalRoundedRectRenderer) void {
    rr.draw(4, 4, 32, 24, 6, 3, .{ 1, 1, 1, 1 }, .{ 0, 0.47, 1, 1 });
}

fn approx(a: u8, b: u8) bool {
    return (if (a > b) a - b else b - a) <= 2;
}
