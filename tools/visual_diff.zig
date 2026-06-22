//! visual-diff: compare two images within a perceptual tolerance (#13).
//!
//! Usage: visual-diff [<golden>|--expect-solid R,G,B|--reject-solid R,G,B] <actual>
//!        [--max-avg-diff N] [--max-pixel-frac F]
//!
//! `--reject-solid R,G,B` passes only if the image has content (is NOT
//! uniformly that color) — the on-screen window e2e: a rendered UI isn't
//! solid white, a blank window is.
//!
//! Supports uncompressed 24/32-bit BMP (what the Windows capture script
//! emits) and binary PPM P6 (what RasterBackend.writePpm emits). Images
//! must match in size. Exit 0 = match within tolerance, 1 = mismatch,
//! 2 = usage/decode error.
//!
//! Tolerances exist because GPU/driver/font AA differ legitimately:
//! `--max-avg-diff` bounds the mean absolute per-channel difference
//! (default 2), `--max-pixel-frac` bounds the fraction of pixels whose
//! max channel difference exceeds 32 (default 0.01).

const std = @import("std");

const Image = struct {
    width: u32,
    height: u32,
    /// RGB8, row-major, top-down.
    rgb: []u8,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("visual-diff: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseRgb(s: []const u8) [3]u8 {
    var it = std.mem.splitScalar(u8, s, ',');
    var rgb: [3]u8 = undefined;
    for (0..3) |ch| {
        rgb[ch] = std.fmt.parseInt(u8, it.next() orelse fail("color wants R,G,B", .{}), 10) catch
            fail("color wants R,G,B", .{});
    }
    return rgb;
}

fn loadImage(gpa: std.mem.Allocator, path: []const u8, io: std.Io) Image {
    const file_data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err|
        fail("cannot read {s}: {t}", .{ path, err });
    if (std.mem.startsWith(u8, file_data, "P6")) return parsePpm(gpa, file_data, path);
    if (std.mem.startsWith(u8, file_data, "BM")) return parseBmp(gpa, file_data, path);
    fail("{s}: unsupported format (need PPM P6 or BMP)", .{path});
}

fn parsePpm(gpa: std.mem.Allocator, data: []const u8, path: []const u8) Image {
    var it = std.mem.tokenizeAny(u8, data[2..], " \t\r\n");
    const w = std.fmt.parseInt(u32, it.next() orelse fail("{s}: truncated PPM", .{path}), 10) catch
        fail("{s}: bad PPM width", .{path});
    const h = std.fmt.parseInt(u32, it.next() orelse fail("{s}: truncated PPM", .{path}), 10) catch
        fail("{s}: bad PPM height", .{path});
    const maxval = it.next() orelse fail("{s}: truncated PPM", .{path});
    _ = maxval;
    // Pixel data begins after the single whitespace following maxval.
    const header_len = (@intFromPtr(it.rest().ptr) - @intFromPtr(data.ptr));
    const pixels = data[header_len..];
    const expected: usize = @as(usize, w) * h * 3;
    if (pixels.len < expected) fail("{s}: PPM pixel data short ({d} < {d})", .{ path, pixels.len, expected });
    const rgb = gpa.dupe(u8, pixels[0..expected]) catch fail("oom", .{});
    return .{ .width = w, .height = h, .rgb = rgb };
}

fn parseBmp(gpa: std.mem.Allocator, data: []const u8, path: []const u8) Image {
    if (data.len < 54) fail("{s}: BMP too small", .{path});
    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const header_size = std.mem.readInt(u32, data[14..18], .little);
    if (header_size < 40) fail("{s}: unsupported BMP header", .{path});
    const w: u32 = @bitCast(std.mem.readInt(i32, data[18..22], .little));
    const h_signed = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);
    const compression = std.mem.readInt(u32, data[30..34], .little);
    if (compression != 0 and compression != 3) fail("{s}: compressed BMP unsupported", .{path});
    if (bpp != 24 and bpp != 32) fail("{s}: only 24/32-bit BMP supported (got {d})", .{ path, bpp });

    const top_down = h_signed < 0;
    const h: u32 = @intCast(if (top_down) -h_signed else h_signed);
    const bytes_pp: usize = bpp / 8;
    const stride = (w * bytes_pp + 3) & ~@as(usize, 3);

    const rgb = gpa.alloc(u8, @as(usize, w) * h * 3) catch fail("oom", .{});
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_row = if (top_down) y else h - 1 - y;
        const row = data[pixel_offset + src_row * stride ..];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const p = row[x * bytes_pp ..];
            const di = (@as(usize, y) * w + x) * 3;
            rgb[di + 0] = p[2]; // BMP is BGR(A)
            rgb[di + 1] = p[1];
            rgb[di + 2] = p[0];
        }
    }
    return .{ .width = w, .height = h, .rgb = rgb };
}

/// Mean of all RGB channel values (0..255) — a simple overall-brightness proxy.
fn meanBrightness(img: Image) f64 {
    var sum: u64 = 0;
    for (img.rgb) |b| sum += b;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(img.rgb.len));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    var golden_path: ?[]const u8 = null;
    var actual_path: ?[]const u8 = null;
    var solid: ?[3]u8 = null;
    var reject_solid: ?[3]u8 = null;
    var darker: ?struct { dark: []const u8, light: []const u8 } = null;
    var max_avg_diff: f64 = 2.0;
    var max_pixel_frac: f64 = 0.01;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--darker")) {
            // `--darker <dark> <light>`: pass only if the first image is
            // meaningfully darker than the second — for OS dark-mode e2e
            // (the app should render dark under a dark OS theme). #318.
            i += 1;
            const d = args[i];
            i += 1;
            darker = .{ .dark = d, .light = args[i] };
        } else if (std.mem.eql(u8, arg, "--max-avg-diff")) {
            i += 1;
            max_avg_diff = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--max-pixel-frac")) {
            i += 1;
            max_pixel_frac = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--expect-solid")) {
            // golden is a synthesized solid color at actual's size — for
            // e2e checks where the window size varies (DPI, theme).
            i += 1;
            solid = parseRgb(args[i]);
        } else if (std.mem.eql(u8, arg, "--reject-solid")) {
            // Pass only if the image is NOT uniformly this color — i.e.
            // something was painted. For the on-screen window e2e: a
            // rendered UI is not solid white; a blank window is.
            i += 1;
            reject_solid = parseRgb(args[i]);
        } else if (golden_path == null and solid == null and reject_solid == null) {
            golden_path = arg;
        } else if (actual_path == null) {
            actual_path = arg;
        } else fail("unexpected argument: {s}", .{arg});
    }
    // --darker: brightness-only comparison of two captures (OS dark-mode e2e).
    if (darker) |dl| {
        const margin: f64 = 40; // dark vs light themes differ by ~200; 40 is slack.
        const db = meanBrightness(loadImage(gpa, dl.dark, init.io));
        const lb = meanBrightness(loadImage(gpa, dl.light, init.io));
        std.debug.print("visual-diff: mean brightness dark={d:.1} light={d:.1} (need light-dark > {d:.0})\n", .{ db, lb, margin });
        if (lb - db < margin) {
            std.debug.print("visual-diff: NOT DARKER — app did not follow the OS dark theme\n", .{});
            std.process.exit(1);
        }
        std.debug.print("visual-diff: OK (dark capture is darker than light)\n", .{});
        return;
    }

    const ap = actual_path orelse fail("usage: visual-diff [<golden>|--expect-solid R,G,B|--reject-solid R,G,B|--darker DARK LIGHT] <actual>", .{});
    const actual = loadImage(gpa, ap, init.io);

    // --reject-solid: assert the capture has content (not a blank window).
    if (reject_solid) |rgb| {
        const n: usize = @as(usize, actual.width) * actual.height;
        var painted: u64 = 0;
        var p: usize = 0;
        while (p < n) : (p += 1) {
            var max_ch: u8 = 0;
            for (0..3) |ch| {
                const a = actual.rgb[p * 3 + ch];
                const d = if (a > rgb[ch]) a - rgb[ch] else rgb[ch] - a;
                max_ch = @max(max_ch, d);
            }
            if (max_ch > 32) painted += 1;
        }
        const frac = @as(f64, @floatFromInt(painted)) / @as(f64, @floatFromInt(n));
        std.debug.print("visual-diff: {d}x{d}, painted fraction {d:.4} (vs {d},{d},{d})\n", .{ actual.width, actual.height, frac, rgb[0], rgb[1], rgb[2] });
        if (frac < 0.01) {
            std.debug.print("visual-diff: BLANK (no content rendered)\n", .{});
            std.process.exit(1);
        }
        std.debug.print("visual-diff: OK (content present)\n", .{});
        return;
    }

    const golden: Image = if (solid) |rgb| blk: {
        const n: usize = @as(usize, actual.width) * actual.height * 3;
        const buf = gpa.alloc(u8, n) catch fail("oom", .{});
        var p: usize = 0;
        while (p < n) : (p += 3) {
            buf[p..][0..3].* = rgb;
        }
        break :blk .{ .width = actual.width, .height = actual.height, .rgb = buf };
    } else loadImage(gpa, golden_path orelse fail("usage: visual-diff [<golden>|--expect-solid R,G,B] <actual>", .{}), init.io);

    if (golden.width != actual.width or golden.height != actual.height) {
        std.debug.print(
            "visual-diff: size mismatch: golden {d}x{d} vs actual {d}x{d}\n",
            .{ golden.width, golden.height, actual.width, actual.height },
        );
        std.process.exit(1);
    }

    var total_diff: u64 = 0;
    var bad_pixels: u64 = 0;
    const n_px: usize = @as(usize, golden.width) * golden.height;
    var px: usize = 0;
    while (px < n_px) : (px += 1) {
        var max_ch: u8 = 0;
        var ch: usize = 0;
        while (ch < 3) : (ch += 1) {
            const a = golden.rgb[px * 3 + ch];
            const b = actual.rgb[px * 3 + ch];
            const d = if (a > b) a - b else b - a;
            total_diff += d;
            max_ch = @max(max_ch, d);
        }
        if (max_ch > 32) bad_pixels += 1;
    }

    const avg_diff = @as(f64, @floatFromInt(total_diff)) / @as(f64, @floatFromInt(n_px * 3));
    const pixel_frac = @as(f64, @floatFromInt(bad_pixels)) / @as(f64, @floatFromInt(n_px));

    std.debug.print(
        "visual-diff: {d}x{d}, avg channel diff {d:.3} (max {d:.1}), bad pixel fraction {d:.5} (max {d:.5})\n",
        .{ golden.width, golden.height, avg_diff, max_avg_diff, pixel_frac, max_pixel_frac },
    );

    if (avg_diff > max_avg_diff or pixel_frac > max_pixel_frac) {
        std.debug.print("visual-diff: MISMATCH\n", .{});
        std.process.exit(1);
    }
    std.debug.print("visual-diff: OK\n", .{});
}
