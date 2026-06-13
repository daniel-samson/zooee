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

    // Establish a current GL context: a hidden GLX window (Linux-only — macOS
    // uses Metal #101, Windows D3D11 #12).
    var win = gl.GlWindow.create("zooee gl", 200, 150) catch |err| {
        try out.print("GL-CREATE-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer win.destroy();

    var ok = true;
    {
        // Distinctive teal so a stray clear can't accidentally pass.
        const r: f32 = 0.10;
        const g: f32 = 0.60;
        const b: f32 = 0.70;
        win.clearAndPresent(r, g, b, 1.0);

        const px = try win.readPixels(gpa);
        const i = ((win.height / 2) * win.width + win.width / 2) * 4;
        const got = .{ px[i], px[i + 1], px[i + 2] };
        const want = .{
            @as(u8, @intFromFloat(r * 255 + 0.5)),
            @as(u8, @intFromFloat(g * 255 + 0.5)),
            @as(u8, @intFromFloat(b * 255 + 0.5)),
        };
        // Allow ±2 for any colorspace/rounding wobble across GL implementations.
        ok = approx(got[0], want[0]) and approx(got[1], want[1]) and approx(got[2], want[2]);
        try out.print("GL clear: center=({d},{d},{d}) want=({d},{d},{d}) {s}\n", .{ got[0], got[1], got[2], want[0], want[1], want[2], if (ok) "PASS" else "FAIL" });
    }

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

    // Slice 5: glyph atlas text. Render white "Hi" on black via the GL
    // glyph atlas; assert ink exists in the text band and the far-right
    // region is empty. Also dump a PPM for visual inspection.
    const zooee = @import("zooee");
    const font = try zooee.font.ttf.Font.parse(zooee.test_font_ttf);
    var gr = gl.GlyphRenderer.init(gpa, &font, 48) catch |err| {
        try out.print("GL-GLYPH-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    const gw: u32 = 300;
    const gh: u32 = 64;
    const gpx = try gl.renderTextOffscreen(gpa, &gr, gw, gh, .{ 0, 0, 0, 1 }, 6, 6, "Hi zooee", .{ 1, 1, 1, 1 });
    var ink: usize = 0;
    var right_ink: usize = 0;
    for (0..gh) |yy| for (0..gw) |xx| {
        const lum = gpx[(yy * gw + xx) * 4];
        if (lum > 128) {
            ink += 1;
            if (xx > gw - 20) right_ink += 1; // far right margin should be empty
        }
    };
    const glyph_ok = ink > 60 and right_ink == 0;
    try out.print("GL glyph text: ink_px={d} right_margin_ink={d} {s}\n", .{ ink, right_ink, if (glyph_ok) "PASS" else "FAIL" });
    // Slice 6: GlBackend vtable. Render rect-based fixtures through the
    // GL Backend AND the raster backend; compare with tolerance (proves
    // the GL Backend matches the raster reference via the real interface).
    var backend_ok = true;
    {
        var glb = gl.GlBackend.initOffscreen(gpa) catch |err| {
            try out.print("GL-BACKEND-INIT-FAILED: {t}\n", .{err});
            try out.flush();
            std.process.exit(1);
        };
        defer glb.deinit();
        try glb.setFont(zooee.test_font_ttf);
        // hello_text proves GL TEXT through the Backend matches raster
        // (both use the same Poppins rasterizer → near-exact). overlap/
        // nested_clip/sides are pixel-exact (hard rects + scissor); `sides`
        // exercises per-side border colors + a single rounded corner via the
        // exact renderer. card/layout_card mix border + text.
        const text_scenes = [_][]const u8{ "hello_text", "card", "layout_card" };
        for ([_][]const u8{ "overlap", "nested_clip", "sides", "image", "hello_text", "card", "layout_card" }) |name| {
            const scene = findScene(name) orelse continue;
            try zooee.fixtures.run(scene, glb.interface(), 8);
            const glpx = try glb.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            // Compare (both top-down RGBA, same dims).
            var bad: usize = 0;
            const n = @min(glpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = glpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            // Text edges can sample 1px differently; allow a small frac.
            var is_text = false;
            for (text_scenes) |t| {
                if (std.mem.eql(u8, name, t)) is_text = true;
            }
            const scene_ok = frac < if (is_text) @as(f32, 0.05) else 0.03;
            if (!scene_ok) backend_ok = false;
            try out.print("GL Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Non-ASCII (#114): café — déjà via the dynamic glyph atlas, vs raster.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "unicode_text", .width = 20, .height = 4, .draw = zooee.fixtures.drawUnicode };
            try zooee.fixtures.run(scene, glb.interface(), 8);
            const glpx = try glb.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(glpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = glpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("GL Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Gradients (#118): linear fills via the gradient pipeline, vs raster.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "gradient", .width = 10, .height = 11, .draw = zooee.fixtures.drawGradient };
            try zooee.fixtures.run(scene, glb.interface(), 8);
            const glpx = try glb.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(glpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = glpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("GL Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Group opacity (#121): a 50% layer composited via FBO + LayerCompositor
        // must match raster's straight-alpha popLayer.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "group_opacity", .width = 10, .height = 8, .draw = zooee.fixtures.drawGroupOpacity };
            try zooee.fixtures.run(scene, glb.interface(), 8);
            const glpx = try glb.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(glpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = glpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("GL Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
        // Rounded clip (#117): content masked to a rounded rect via FBO +
        // RoundClipCompositor must match raster's hard-edged per-pixel clip.
        {
            const scene: zooee.fixtures.Scene = .{ .name = "rounded_clip", .width = 10, .height = 10, .draw = zooee.fixtures.drawRoundedClip };
            try zooee.fixtures.run(scene, glb.interface(), 8);
            const glpx = try glb.readPixels();
            var ras = zooee.backends.raster.RasterBackend.init(gpa);
            defer ras.deinit();
            try ras.setFont(zooee.test_font_ttf);
            try zooee.fixtures.run(scene, ras.interface(), 8);
            var bad: usize = 0;
            const n = @min(glpx.len, ras.pixels.len) / 4;
            for (0..n) |p| {
                var md: u8 = 0;
                for (0..3) |ch| {
                    const a = glpx[p * 4 + ch];
                    const bch = ras.pixels[p * 4 + ch];
                    const d = if (a > bch) a - bch else bch - a;
                    if (d > md) md = d;
                }
                if (md > 32) bad += 1;
            }
            const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
            const scene_ok = frac < 0.05;
            if (!scene_ok) backend_ok = false;
            try out.print("GL Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
        }
    }

    try out.flush();
    if (!ok or !quad_ok or !rect_ok or !round_ok or !glyph_ok or !backend_ok) std.process.exit(1);
}

fn findScene(name: []const u8) ?@import("zooee").fixtures.Scene {
    for (@import("zooee").fixtures.all) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
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
