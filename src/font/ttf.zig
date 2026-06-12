//! TTF parser (#10, slice 1): the in-house font pipeline — no FreeType,
//! no HarfBuzz (2MB budget, #14).
//!
//! v1 scope: TrueType outlines (glyf/loca), cmap format 4 (BMP),
//! horizontal metrics. Glyph outlines come out as quadratic bezier
//! contours in font units for the rasterizer (slice 2). Deferred per
//! the issue: hinting, GPOS/kern, complex shaping, variable fonts,
//! CFF/OpenType outlines.

const std = @import("std");

pub const Error = error{
    NotATtf,
    MissingTable,
    Malformed,
    UnsupportedCmap,
    OutOfMemory,
};

fn readU16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

fn readI16(data: []const u8, off: usize) i16 {
    return std.mem.readInt(i16, data[off..][0..2], .big);
}

fn readU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    long_hor_metrics: u16,
    index_to_loc_long: bool,
    cmap_subtable: usize, // offset of the format-4 subtable
    loca: usize,
    glyf: usize,
    hmtx: usize,

    /// Parse a TTF from bytes (borrowed; the Font reads from it lazily).
    pub fn parse(data: []const u8) Error!Font {
        if (data.len < 12) return error.NotATtf;
        const version = readU32(data, 0);
        if (version != 0x00010000 and version != 0x74727565) return error.NotATtf; // 1.0 or 'true'

        const num_tables = readU16(data, 4);
        var head: ?usize = null;
        var maxp: ?usize = null;
        var hhea: ?usize = null;
        var hmtx: ?usize = null;
        var loca: ?usize = null;
        var glyf: ?usize = null;
        var cmap: ?usize = null;

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.Malformed;
            const tag = data[rec .. rec + 4];
            const off = readU32(data, rec + 8);
            if (off >= data.len) return error.Malformed;
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = off;
            if (std.mem.eql(u8, tag, "loca")) loca = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap = off;
        }
        const head_off = head orelse return error.MissingTable;
        const maxp_off = maxp orelse return error.MissingTable;
        const hhea_off = hhea orelse return error.MissingTable;

        const cmap_off = cmap orelse return error.MissingTable;
        const subtable = try findCmapFormat4(data, cmap_off);

        return .{
            .data = data,
            .units_per_em = readU16(data, head_off + 18),
            .index_to_loc_long = readI16(data, head_off + 50) != 0,
            .num_glyphs = readU16(data, maxp_off + 4),
            .ascent = readI16(data, hhea_off + 4),
            .descent = readI16(data, hhea_off + 6),
            .line_gap = readI16(data, hhea_off + 8),
            .long_hor_metrics = readU16(data, hhea_off + 34),
            .cmap_subtable = subtable,
            .loca = loca orelse return error.MissingTable,
            .glyf = glyf orelse return error.MissingTable,
            .hmtx = hmtx orelse return error.MissingTable,
        };
    }

    fn findCmapFormat4(data: []const u8, cmap_off: usize) Error!usize {
        const n = readU16(data, cmap_off + 2);
        var best: ?usize = null;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = cmap_off + 4 + i * 8;
            const platform = readU16(data, rec);
            const encoding = readU16(data, rec + 2);
            const off = cmap_off + readU32(data, rec + 4);
            if (off + 2 > data.len) continue;
            const format = readU16(data, off);
            // Windows BMP (3,1) or Unicode (0,*) in format 4.
            if (format == 4 and ((platform == 3 and encoding == 1) or platform == 0)) {
                best = off;
            }
        }
        return best orelse error.UnsupportedCmap;
    }

    /// Codepoint → glyph index (0 = .notdef).
    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        if (cp > 0xFFFF) return 0; // BMP only in format 4
        const c: u16 = @intCast(cp);
        const t = self.cmap_subtable;
        const d = self.data;
        const seg_count_x2 = readU16(d, t + 6);
        const seg_count = seg_count_x2 / 2;
        const end_codes = t + 14;
        const start_codes = end_codes + seg_count_x2 + 2;
        const id_deltas = start_codes + seg_count_x2;
        const id_ranges = id_deltas + seg_count_x2;

        var i: usize = 0;
        while (i < seg_count) : (i += 1) {
            const end = readU16(d, end_codes + i * 2);
            if (c > end) continue;
            const start = readU16(d, start_codes + i * 2);
            if (c < start) return 0;
            const delta = readU16(d, id_deltas + i * 2);
            const range_off = readU16(d, id_ranges + i * 2);
            if (range_off == 0) {
                return c +% delta;
            }
            const glyph_addr = id_ranges + i * 2 + range_off + (@as(usize, c - start)) * 2;
            if (glyph_addr + 2 > d.len) return 0;
            const g = readU16(d, glyph_addr);
            return if (g == 0) 0 else g +% delta;
        }
        return 0;
    }

    pub const HMetrics = struct { advance: u16, lsb: i16 };

    pub fn hMetrics(self: *const Font, glyph: u16) HMetrics {
        const d = self.data;
        if (glyph < self.long_hor_metrics) {
            const off = self.hmtx + @as(usize, glyph) * 4;
            return .{ .advance = readU16(d, off), .lsb = readI16(d, off + 2) };
        }
        // Monospace tail: last advance repeats.
        const last = self.hmtx + (@as(usize, self.long_hor_metrics) - 1) * 4;
        return .{ .advance = readU16(d, last), .lsb = 0 };
    }

    fn glyphRange(self: *const Font, glyph: u16) ?struct { start: usize, end: usize } {
        const d = self.data;
        const g: usize = glyph;
        var start: usize = 0;
        var end: usize = 0;
        if (self.index_to_loc_long) {
            start = readU32(d, self.loca + g * 4);
            end = readU32(d, self.loca + g * 4 + 4);
        } else {
            start = @as(usize, readU16(d, self.loca + g * 2)) * 2;
            end = @as(usize, readU16(d, self.loca + g * 2 + 2)) * 2;
        }
        if (end <= start) return null; // empty glyph (space)
        return .{ .start = self.glyf + start, .end = self.glyf + end };
    }

    pub const Point = struct { x: f32, y: f32, on_curve: bool };

    pub const Outline = struct {
        /// All contour points, quadratic on/off-curve, font units, y-up.
        points: []Point,
        /// Index of each contour's last point.
        contour_ends: []u16,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,

        pub fn deinit(self: *Outline, gpa: std.mem.Allocator) void {
            gpa.free(self.points);
            gpa.free(self.contour_ends);
        }
    };

    /// Decode a simple glyph's outline. Composite glyphs resolve their
    /// components recursively (translation-only v1; scaling components
    /// are rare in text fonts).
    pub fn outline(self: *const Font, gpa: std.mem.Allocator, glyph: u16) Error!?Outline {
        var points: std.ArrayList(Point) = .empty;
        errdefer points.deinit(gpa);
        var ends: std.ArrayList(u16) = .empty;
        errdefer ends.deinit(gpa);

        var bounds: [4]i16 = .{ 0, 0, 0, 0 };
        try self.outlineInto(gpa, glyph, 0, 0, &points, &ends, &bounds, 0);
        if (points.items.len == 0) {
            points.deinit(gpa);
            ends.deinit(gpa);
            return null;
        }
        return .{
            .points = try points.toOwnedSlice(gpa),
            .contour_ends = try ends.toOwnedSlice(gpa),
            .x_min = bounds[0],
            .y_min = bounds[1],
            .x_max = bounds[2],
            .y_max = bounds[3],
        };
    }

    fn outlineInto(
        self: *const Font,
        gpa: std.mem.Allocator,
        glyph: u16,
        dx: f32,
        dy: f32,
        points: *std.ArrayList(Point),
        ends: *std.ArrayList(u16),
        bounds: *[4]i16,
        depth: u8,
    ) Error!void {
        if (depth > 4) return; // composite recursion guard
        const range = self.glyphRange(glyph) orelse return;
        const d = self.data;
        const off = range.start;
        if (off + 10 > d.len) return error.Malformed;
        const n_contours = readI16(d, off);
        bounds[0] = @min(bounds[0], readI16(d, off + 2));
        bounds[1] = @min(bounds[1], readI16(d, off + 4));
        bounds[2] = @max(bounds[2], readI16(d, off + 6));
        bounds[3] = @max(bounds[3], readI16(d, off + 8));

        if (n_contours < 0) {
            // Composite glyph.
            var p = off + 10;
            while (true) {
                const flags = readU16(d, p);
                const comp_glyph = readU16(d, p + 2);
                p += 4;
                var cdx: f32 = 0;
                var cdy: f32 = 0;
                if (flags & 0x0001 != 0) { // words
                    if (flags & 0x0002 != 0) { // xy values
                        cdx = @floatFromInt(readI16(d, p));
                        cdy = @floatFromInt(readI16(d, p + 2));
                    }
                    p += 4;
                } else {
                    if (flags & 0x0002 != 0) {
                        cdx = @floatFromInt(@as(i8, @bitCast(d[p])));
                        cdy = @floatFromInt(@as(i8, @bitCast(d[p + 1])));
                    }
                    p += 2;
                }
                // Skip scale variants (v1 translates only).
                if (flags & 0x0008 != 0) p += 2;
                if (flags & 0x0040 != 0) p += 4;
                if (flags & 0x0080 != 0) p += 8;

                try self.outlineInto(gpa, comp_glyph, dx + cdx, dy + cdy, points, ends, bounds, depth + 1);
                if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
            }
            return;
        }

        const nc: usize = @intCast(n_contours);
        const base_point: usize = points.items.len;
        var p = off + 10;
        var n_points: usize = 0;
        var i: usize = 0;
        while (i < nc) : (i += 1) {
            const end = readU16(d, p + i * 2);
            try ends.append(gpa, @intCast(base_point + end));
            n_points = end + 1;
        }
        p += nc * 2;
        const instr_len = readU16(d, p);
        p += 2 + instr_len;

        // Flags (run-length encoded).
        var flags: std.ArrayList(u8) = .empty;
        defer flags.deinit(gpa);
        while (flags.items.len < n_points) {
            if (p >= d.len) return error.Malformed;
            const f = d[p];
            p += 1;
            try flags.append(gpa, f);
            if (f & 0x08 != 0) { // repeat
                if (p >= d.len) return error.Malformed;
                const rep = d[p];
                p += 1;
                var r: usize = 0;
                while (r < rep) : (r += 1) try flags.append(gpa, f);
            }
        }

        // X coordinates (deltas).
        var xs: std.ArrayList(f32) = .empty;
        defer xs.deinit(gpa);
        var x: i32 = 0;
        for (flags.items) |f| {
            if (f & 0x02 != 0) {
                const v: i32 = d[p];
                p += 1;
                x += if (f & 0x10 != 0) v else -v;
            } else if (f & 0x10 == 0) {
                x += readI16(d, p);
                p += 2;
            }
            try xs.append(gpa, @floatFromInt(x));
        }
        // Y coordinates (deltas).
        var y: i32 = 0;
        for (flags.items, 0..) |f, j| {
            if (f & 0x04 != 0) {
                const v: i32 = d[p];
                p += 1;
                y += if (f & 0x20 != 0) v else -v;
            } else if (f & 0x20 == 0) {
                y += readI16(d, p);
                p += 2;
            }
            try points.append(gpa, .{
                .x = xs.items[j] + dx,
                .y = @as(f32, @floatFromInt(y)) + dy,
                .on_curve = f & 0x01 != 0,
            });
        }
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;
const poppins = @embedFile("../../testdata/fonts/Poppins-Regular.ttf");

test "parses Poppins header tables" {
    const font = try Font.parse(poppins);
    try testing.expect(font.num_glyphs > 100);
    try testing.expect(font.units_per_em == 1000 or font.units_per_em == 2048);
    try testing.expect(font.ascent > 0);
    try testing.expect(font.descent < 0);
}

test "cmap maps ASCII to nonzero glyphs" {
    const font = try Font.parse(poppins);
    const a = font.glyphIndex('A');
    const z = font.glyphIndex('z');
    const zero = font.glyphIndex('0');
    try testing.expect(a != 0);
    try testing.expect(z != 0);
    try testing.expect(zero != 0);
    try testing.expect(a != z);
    // Unmapped codepoint → .notdef
    try testing.expectEqual(@as(u16, 0), font.glyphIndex(0xE123));
}

test "metrics: advances positive, space has no outline" {
    const font = try Font.parse(poppins);
    const m = font.hMetrics(font.glyphIndex('M'));
    try testing.expect(m.advance > 0);

    const space = font.glyphIndex(' ');
    var out = try font.outline(testing.allocator, space);
    try testing.expect(out == null);
    if (out) |*o| o.deinit(testing.allocator);
}

test "outline of 'A': contours with plausible geometry" {
    const font = try Font.parse(poppins);
    var out = (try font.outline(testing.allocator, font.glyphIndex('A'))) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);
    // 'A' has 2 contours (outer + counter) in most fonts.
    try testing.expect(out.contour_ends.len >= 1 and out.contour_ends.len <= 3);
    try testing.expect(out.points.len > 10);
    try testing.expect(out.y_max > out.y_min);
    // All points inside declared bounds (allow off-curve overshoot of 0).
    for (out.points) |pt| {
        try testing.expect(pt.x >= @as(f32, @floatFromInt(out.x_min)) - 1);
        try testing.expect(pt.x <= @as(f32, @floatFromInt(out.x_max)) + 1);
    }
}

test "composite glyph resolves (é)" {
    const font = try Font.parse(poppins);
    const g = font.glyphIndex(0xE9); // é — typically composite (e + acute)
    if (g == 0) return; // font subset without it: skip
    var out = (try font.outline(testing.allocator, g)) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);
    try testing.expect(out.points.len > 10);
}
