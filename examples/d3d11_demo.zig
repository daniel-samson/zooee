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

    // Slice 3: native rect geometry. Render left-half red / right-half blue
    // via the rect shader into a fresh target; check the halves, like
    // gl_demo's slice 3.
    const rw: u32 = 40;
    const rh: u32 = 24;
    var d3d3 = try d3d11.D3dOffscreen.create(rw, rh);
    defer d3d3.destroy();
    var rects = try d3d11.D3dRectRenderer.init(d3d3.device, d3d3.context, false);
    defer rects.deinit();
    const vw: f32 = @floatFromInt(rw);
    const vh: f32 = @floatFromInt(rh);
    try rects.fillRect(d3d3.rtv, vw, vh, 0, 0, vw / 2, vh, .{ 1, 0, 0, 1 }); // left red
    try rects.fillRect(d3d3.rtv, vw, vh, vw / 2, 0, vw / 2, vh, .{ 0, 0, 1, 1 }); // right blue
    const rpx = try d3d3.readPixels(gpa);
    const li = ((rh / 2) * rw + rw / 4) * 4; // left quarter
    const ri = ((rh / 2) * rw + (rw * 3) / 4) * 4; // right quarter
    const rect_ok = approx(rpx[li], 255) and approx(rpx[li + 1], 0) and approx(rpx[li + 2], 0) and
        approx(rpx[ri], 0) and approx(rpx[ri + 1], 0) and approx(rpx[ri + 2], 255);
    try out.print("D3D11 native rects: left=({d},{d},{d}) right=({d},{d},{d}) {s}\n", .{ rpx[li], rpx[li + 1], rpx[li + 2], rpx[ri], rpx[ri + 1], rpx[ri + 2], if (rect_ok) "PASS" else "FAIL" });

    // Slice 4: SDF rounded rect + border. White rounded card, blue border, on
    // black. center=white(bg), mid-left edge=blue(border), corner=cut(black),
    // like gl_demo slice 4.
    const sw: u32 = 40;
    const sh: u32 = 32;
    var d3d4 = try d3d11.D3dOffscreen.create(sw, sh);
    defer d3d4.destroy();
    d3d4.clear(0, 0, 0, 1); // black background
    var rounded = try d3d11.D3dRoundedRectRenderer.init(d3d4.device, d3d4.context, false);
    defer rounded.deinit();
    try rounded.draw(d3d4.rtv, @floatFromInt(sw), @floatFromInt(sh), 4, 4, 32, 24, 6, 3, .{ 1, 1, 1, 1 }, .{ 0, 0.47, 1, 1 });
    const spx = try d3d4.readPixels(gpa);
    const ci = ((sh / 2) * sw + sw / 2) * 4; // center → bg white
    const ei = ((sh / 2) * sw + 5) * 4; // mid-left edge → border blue
    const corner = (5 * sw + 5) * 4; // near top-left corner → cut (black)
    const round_ok = approx(spx[ci], 255) and approx(spx[ci + 1], 255) and approx(spx[ci + 2], 255) and
        spx[ei] < 40 and spx[ei + 2] > 200 and
        spx[corner] < 40 and spx[corner + 2] < 70;
    try out.print("D3D11 rounded+border: center=({d},{d},{d}) edge=({d},{d},{d}) corner=({d},{d},{d}) {s}\n", .{ spx[ci], spx[ci + 1], spx[ci + 2], spx[ei], spx[ei + 1], spx[ei + 2], spx[corner], spx[corner + 1], spx[corner + 2], if (round_ok) "PASS" else "FAIL" });

    // Slice 5: glyph atlas text. Render white "Hi zooee" on black via the
    // atlas; assert ink exists in the text band and the far-right margin is
    // empty, like gl_demo slice 5.
    const gw: u32 = 300;
    const gh: u32 = 64;
    var d3d5 = try d3d11.D3dOffscreen.create(gw, gh);
    defer d3d5.destroy();
    d3d5.clear(0, 0, 0, 1);
    const font = try zooee.font.ttf.Font.parse(zooee.test_font_ttf);
    var glyphs = try d3d11.D3dGlyphRenderer.init(gpa, d3d5.device, d3d5.context, &font, 48, false);
    defer glyphs.deinit();
    try glyphs.drawText(gpa, d3d5.rtv, @floatFromInt(gw), @floatFromInt(gh), 6, 6, "Hi zooee", .{ 1, 1, 1, 1 });
    const gpx = try d3d5.readPixels(gpa);
    var ink: usize = 0;
    var right_ink: usize = 0;
    for (0..gh) |yy| for (0..gw) |xx| {
        const lum = gpx[(yy * gw + xx) * 4];
        if (lum > 128) {
            ink += 1;
            if (xx > gw - 20) right_ink += 1; // far-right margin should be empty
        }
    };
    const glyph_ok = ink > 60 and right_ink == 0;
    try out.print("D3D11 glyph text: ink_px={d} right_margin_ink={d} {s}\n", .{ ink, right_ink, if (glyph_ok) "PASS" else "FAIL" });

    // Slice 6: D3dBackend vtable. Render the shared fixtures through the
    // D3D11 Backend AND the raster backend; compare with tolerance, proving
    // D3dBackend matches the raster reference via the real interface. Like
    // gl_demo, but only the fixtures the current renderers reproduce exactly
    // (hard rects + scissor + textured image + text). Per-side borders /
    // per-corner radii (sides/card/layout_card) need an exact renderer — a
    // later slice, mirroring GL slice 7.
    var backend_ok = true;
    {
        var db = d3d11.D3dBackend.initOffscreen(gpa) catch |err| {
            try out.print("D3D-BACKEND-INIT-FAILED: {t}\n", .{err});
            try out.flush();
            std.process.exit(1);
        };
        defer db.deinit();
        try db.setFont(zooee.test_font_ttf);
        const text_scenes = [_][]const u8{ "hello_text", "card", "layout_card" };
        for ([_][]const u8{ "overlap", "nested_clip", "sides", "image", "hello_text", "card", "layout_card" }) |name| {
            const scene = findScene(name) orelse continue;
            try zooee.fixtures.run(scene, db.interface(), 8);
            const dpx = try db.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(dpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = dpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            var is_text = false;
            for (text_scenes) |t| {
                if (std.mem.eql(u8, name, t)) is_text = true;
            }
            const scene_ok = frac < if (is_text) @as(f32, 0.05) else 0.03;
            if (!scene_ok) backend_ok = false;
            try out.print("D3D11 Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Non-ASCII (#114): café — déjà via the dynamic glyph atlas, vs raster.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "unicode_text", .width = 20, .height = 4, .draw = zooee.fixtures.drawUnicode };
            try zooee.fixtures.run(scene, db.interface(), 8);
            const dpx = try db.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(dpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = dpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("D3D11 Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Group opacity (#121): a 50% layer composited over the backdrop, vs raster.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "group_opacity", .width = 10, .height = 8, .draw = zooee.fixtures.drawGroupOpacity };
            try zooee.fixtures.run(scene, db.interface(), 8);
            const dpx = try db.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(dpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = dpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("D3D11 Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
            // DIAG: sample blue-over-red (36,30), blue-over-white (60,30), red-only (16,30).
            const W = 80;
            inline for ([_][2]usize{ .{ 36, 30 }, .{ 60, 30 }, .{ 16, 30 } }) |pt| {
                const di = (pt[1] * W + pt[0]) * 4;
                try out.print("  DIAG ({d},{d}) d3d=({d},{d},{d}) raster=({d},{d},{d})\n", .{ pt[0], pt[1], dpx[di], dpx[di + 1], dpx[di + 2], ras.pixels[di], ras.pixels[di + 1], ras.pixels[di + 2] });
            }
        }
        // Gradients (#118): linear fills via the gradient pipeline, vs raster.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "gradient", .width = 10, .height = 11, .draw = zooee.fixtures.drawGradient };
            try zooee.fixtures.run(scene, db.interface(), 8);
            const dpx = try db.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(dpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = dpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("D3D11 Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
    }

    try out.flush();
    if (!okc or !quad_ok or !rect_ok or !round_ok or !glyph_ok or !backend_ok) std.process.exit(1);
}

fn findScene(name: []const u8) ?@import("zooee").fixtures.Scene {
    for (@import("zooee").fixtures.all) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}
