//! D3D11 bring-up verification (#12 slice 1): make a D3D11 device + an
//! offscreen render-target texture, clear it to a known color, read it
//! back, and assert the GPU rendered that color. Self-checking — prints
//! PASS/FAIL and exits nonzero on mismatch, mirroring examples/gl_demo.zig's
//! slice 1. Offscreen (no swapchain) so it runs headless (over SSH / in CI).

const std = @import("std");
const zooee = @import("zooee");
const d3d11 = zooee.backends.d3d11;

fn approx(a: u8, b: u8) bool {
    return (if (a > b) a - b else b - a) <= 2;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [256]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &fw.interface;

    const w: u32 = 200;
    const h: u32 = 150;
    var d3d = d3d11.D3dOffscreen.create(w, h) catch |err| {
        try out.print("D3D-CREATE-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer d3d.destroy();

    // Distinctive teal so a stray clear can't accidentally pass.
    const r: f32 = 0.10;
    const g: f32 = 0.60;
    const b: f32 = 0.70;
    d3d.clear(r, g, b, 1.0);

    const px = try d3d.readPixels(gpa);
    const i = ((h / 2) * w + w / 2) * 4;
    const got = .{ px[i], px[i + 1], px[i + 2] };
    const want = .{
        @as(u8, @intFromFloat(r * 255 + 0.5)),
        @as(u8, @intFromFloat(g * 255 + 0.5)),
        @as(u8, @intFromFloat(b * 255 + 0.5)),
    };
    const okc = approx(got[0], want[0]) and approx(got[1], want[1]) and approx(got[2], want[2]);
    try out.print("D3D11 clear: center=({d},{d},{d}) want=({d},{d},{d}) {s}\n", .{ got[0], got[1], got[2], want[0], want[1], want[2], if (okc) "PASS" else "FAIL" });

    // Slice 2: textured-quad → render-target round-trip. Upload a known
    // image, draw it 1:1 through the HLSL shader pipeline, read it back, and
    // check it matches (point sampling, same size → near-exact).
    const tw: u32 = 16;
    const th: u32 = 16;
    const srcimg = try gpa.alloc(u8, tw * th * 4);
    for (0..th) |yy| for (0..tw) |xx| {
        const k = (yy * tw + xx) * 4;
        srcimg[k + 0] = if (xx < tw / 2) 200 else 40; // left red-ish / right dark
        srcimg[k + 1] = if (yy < th / 2) 180 else 30; // top green-ish
        srcimg[k + 2] = 90;
        srcimg[k + 3] = 255;
    };
    var d3d2 = try d3d11.D3dOffscreen.create(tw, th);
    defer d3d2.destroy();
    try d3d2.drawTexture(srcimg, tw, th);
    const back = try d3d2.readPixels(gpa);
    var max_diff: u8 = 0;
    for (srcimg, back) |sv, bv| {
        const d = if (sv > bv) sv - bv else bv - sv;
        if (d > max_diff) max_diff = d;
    }
    const quad_ok = max_diff <= 4;
    try out.print("D3D11 quad round-trip: max channel diff {d} {s}\n", .{ max_diff, if (quad_ok) "PASS" else "FAIL" });

    try out.flush();
    if (!okc or !quad_ok) std.process.exit(1);
}
