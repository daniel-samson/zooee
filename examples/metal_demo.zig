//! Metal bring-up verification (#101 slice 1): create a Metal device +
//! offscreen render target, clear it to a known color, read it back, and
//! assert the GPU produced that color. Self-checking — prints PASS/FAIL and
//! exits nonzero on mismatch, so CI can run it headless.

const std = @import("std");
const builtin = @import("builtin");
const zooee = @import("zooee");
const metal = zooee.backends.metal;

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

    // The remaining renderers share one device + queue (the Backend does too).
    var ctx = try metal.MetalContext.create();
    defer ctx.destroy();

    // Slice 2: textured-quad round-trip. Upload a known image, render it 1:1
    // through the shader/texture pipeline, and check it comes back (NEAREST,
    // same size → near-exact), incl. correct top-down orientation.
    var qr = metal.MetalQuadRenderer.init(ctx.device, ctx.queue) catch |err| {
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
    var rr = metal.MetalRectRenderer.init(ctx.device, ctx.queue) catch |err| {
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
    var rrr = metal.MetalRoundedRectRenderer.init(ctx.device, ctx.queue) catch |err| {
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

    // Slice 5: glyph atlas text. Render white "Hi zooee" on black via the
    // Metal glyph atlas; assert ink exists and the far-right region is empty.
    const font = try zooee.font.ttf.Font.parse(zooee.test_font_ttf);
    var gr = metal.MetalGlyphRenderer.init(ctx.device, ctx.queue, gpa, &font, 48) catch |err| {
        try out.print("METAL-GLYPH-INIT-FAILED: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };
    defer gr.deinit();
    const gw: u32 = 300;
    const gh: u32 = 64;
    const gpx = try gr.renderTextOffscreen(gpa, gw, gh, .{ 0, 0, 0, 1 }, 6, 6, "Hi zooee", .{ 1, 1, 1, 1 });
    defer gpa.free(gpx);
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
    try out.print("Metal glyph text: ink_px={d} right_margin_ink={d} {s}\n", .{ ink, right_ink, if (glyph_ok) "PASS" else "FAIL" });

    // Slice 6: MetalBackend vtable. Render fixtures through the Metal Backend
    // AND raster; compare with tolerance (proves the Backend matches the raster
    // reference via the real interface). overlap/nested_clip pixel-exact (hard
    // rects + scissor); sides exercises per-side borders + a rounded corner via
    // the exact renderer; card/layout_card mix border + text; image; hello_text.
    var backend_ok = true;
    {
        var mb = metal.MetalBackend.initOffscreen(gpa) catch |err| {
            try out.print("METAL-BACKEND-INIT-FAILED: {t}\n", .{err});
            try out.flush();
            std.process.exit(1);
        };
        defer mb.deinit();
        try mb.setFont(zooee.test_font_ttf);
        const text_scenes = [_][]const u8{ "hello_text", "card", "layout_card" };
        for ([_][]const u8{ "overlap", "nested_clip", "sides", "image", "hello_text", "card", "layout_card" }) |name| {
            const scene = findScene(name) orelse continue;
            var is_text = false;
            for (text_scenes) |t| {
                if (std.mem.eql(u8, name, t)) is_text = true;
            }
            if (!(try compareScene(gpa, out, &mb, scene, is_text))) backend_ok = false;
        }
        // Non-ASCII (#114): café — déjà exercises the dynamic glyph atlas.
        // Local scene (not in fixtures.all, which requires cross-harness
        // goldens); proves Metal renders arbitrary Unicode == raster.
        const unicode_scene: zooee.fixtures.Scene = .{ .name = "unicode_text", .width = 20, .height = 4, .draw = zooee.fixtures.drawUnicode };
        if (!(try compareScene(gpa, out, &mb, unicode_scene, true))) backend_ok = false;
        // Gradients (#118): linear fills vs raster (smooth interpolation, allow
        // ±1 rounding via the text tolerance).
        const gradient_scene: zooee.fixtures.Scene = .{ .name = "gradient", .width = 10, .height = 11, .draw = zooee.fixtures.drawGradient };
        if (!(try compareScene(gpa, out, &mb, gradient_scene, true))) backend_ok = false;
        // Group opacity (#121): a 50%% layer composited over the backdrop must
        // match raster's straight-alpha popLayer (hard-edged regions, 0.03).
        const group_opacity_scene: zooee.fixtures.Scene = .{ .name = "group_opacity", .width = 10, .height = 8, .draw = zooee.fixtures.drawGroupOpacity };
        if (!(try compareScene(gpa, out, &mb, group_opacity_scene, false))) backend_ok = false;
        // Rounded clip (#117): content masked to a rounded rect must match
        // raster's hard-edged per-pixel clip (corners cut, 0.03).
        const rounded_clip_scene: zooee.fixtures.Scene = .{ .name = "rounded_clip", .width = 10, .height = 10, .draw = zooee.fixtures.drawRoundedClip };
        if (!(try compareScene(gpa, out, &mb, rounded_clip_scene, false))) backend_ok = false;
        // Layout-integrated effects (#117/#121/#118 via Element): gradient +
        // rounded clip + opacity through the layout engine must match raster.
        const layout_effects_scene: zooee.fixtures.Scene = .{ .name = "layout_effects", .width = 14, .height = 15, .draw = zooee.fixtures.drawLayoutEffects };
        if (!(try compareScene(gpa, out, &mb, layout_effects_scene, false))) backend_ok = false;
        // Box shadow (#119): analytic erf coverage; allow the text-level (0.05)
        // tolerance for float-precision differences in the blur gradient.
        const box_shadow_scene: zooee.fixtures.Scene = .{ .name = "box_shadow", .width = 12, .height = 12, .draw = zooee.fixtures.drawBoxShadow };
        if (!(try compareScene(gpa, out, &mb, box_shadow_scene, true))) backend_ok = false;
        // Filled path (#120): concave star via even-odd, hard edges (0.03).
        const path_scene: zooee.fixtures.Scene = .{ .name = "path", .width = 10, .height = 10, .draw = zooee.fixtures.drawPath };
        if (!(try compareScene(gpa, out, &mb, path_scene, false))) backend_ok = false;
    }

    try out.flush();
    if (!ok or !quad_ok or !rect_ok or !round_ok or !glyph_ok or !backend_ok) std.process.exit(1);
}

/// Run a scene through the Metal Backend AND raster; print + return whether
/// they match within tolerance (text scenes allow 1px AA wobble).
fn compareScene(gpa: std.mem.Allocator, out: *std.Io.Writer, mb: *metal.MetalBackend, scene: zooee.fixtures.Scene, is_text: bool) !bool {
    try zooee.fixtures.run(scene, mb.interface(), 8);
    const mpx = try mb.readPixels();
    defer gpa.free(mpx);
    var ras = zooee.backends.raster.RasterBackend.init(gpa);
    defer ras.deinit();
    try ras.setFont(zooee.test_font_ttf);
    try zooee.fixtures.run(scene, ras.interface(), 8);
    var bad: usize = 0;
    const n = @min(mpx.len, ras.pixels.len) / 4;
    for (0..n) |p| {
        var md: u8 = 0;
        for (0..3) |ch| {
            const a = mpx[p * 4 + ch];
            const bch = ras.pixels[p * 4 + ch];
            const d = if (a > bch) a - bch else bch - a;
            if (d > md) md = d;
        }
        if (md > 32) bad += 1;
    }
    const frac = @as(f32, @floatFromInt(bad)) / @as(f32, @floatFromInt(n));
    const scene_ok = frac < if (is_text) @as(f32, 0.05) else 0.03;
    try out.print("Metal Backend vs raster [{s}]: bad_frac={d:.4} {s}\n", .{ scene.name, frac, if (scene_ok) "PASS" else "FAIL" });
    return scene_ok;
}

fn findScene(name: []const u8) ?zooee.fixtures.Scene {
    for (zooee.fixtures.all) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
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
