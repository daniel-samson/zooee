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

/// A GPOS ValueRecord stores one i16 per set bit in its ValueFormat mask.
fn valueRecordSize(fmt: u16) usize {
    return @as(usize, @popCount(fmt)) * 2;
}

/// Byte offset of the X_ADVANCE field (0x0004) within a ValueRecord, or null
/// when the format omits it. Fields are ordered by ascending bit, so the
/// offset is the size of the lower-bit fields (X/Y placement) that precede it.
fn xAdvanceOffset(fmt: u16) ?usize {
    if (fmt & 0x0004 == 0) return null;
    return @as(usize, @popCount(fmt & 0x0003)) * 2;
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
    /// GPOS PairPos (kerning) subtable offsets for the `kern` feature (#116),
    /// resolved once at parse. Empty when the font has no GPOS kerning (e.g.
    /// only a legacy `kern` table, or none). Capped — fonts with more PairPos
    /// subtables than this just kern from the first few (rare).
    kern_subtables: [16]u32 = [_]u32{0} ** 16,
    kern_count: usize = 0,
    /// Legacy `kern` table format-0 horizontal subtable (#116): byte offset of
    /// the first pair and the pair count. Many fonts (and most system fonts on
    /// Windows) keep kerning here rather than in GPOS. 0 = absent.
    kern_legacy_pairs: u32 = 0,
    kern_legacy_count: u16 = 0,

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
        var gpos: ?usize = null;
        var kern_tbl: ?usize = null;

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
            if (std.mem.eql(u8, tag, "GPOS")) gpos = off;
            if (std.mem.eql(u8, tag, "kern")) kern_tbl = off;
        }
        const head_off = head orelse return error.MissingTable;
        const maxp_off = maxp orelse return error.MissingTable;
        const hhea_off = hhea orelse return error.MissingTable;

        const cmap_off = cmap orelse return error.MissingTable;
        const subtable = try findCmapFormat4(data, cmap_off);

        var font: Font = .{
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
        if (gpos) |g| font.collectKernSubtables(g);
        if (kern_tbl) |k| font.parseLegacyKern(k);
        return font;
    }

    /// Parse the legacy `kern` table (#116), recording the first format-0
    /// horizontal subtable's pair array. Format 0 is a sorted list of
    /// (left,right)→FUnit pairs — looked up by binary search in `kern()`.
    fn parseLegacyKern(self: *Font, kern_off: usize) void {
        const d = self.data;
        if (kern_off + 4 > d.len) return;
        const n_tables = readU16(d, kern_off + 2);
        var off = kern_off + 4;
        var t: usize = 0;
        while (t < n_tables) : (t += 1) {
            if (off + 6 > d.len) return;
            const length = readU16(d, off + 2);
            const coverage = readU16(d, off + 4);
            // Format 0 (high byte of coverage) + horizontal (bit 0) + not
            // minimum/cross-stream (bits 1-2 clear).
            const format = coverage >> 8;
            const horizontal = coverage & 0x0001 != 0;
            if (format == 0 and horizontal) {
                const n_pairs = readU16(d, off + 6);
                const pairs = off + 14; // skip nPairs + searchRange/entrySel/rangeShift
                if (pairs + @as(usize, n_pairs) * 6 <= d.len) {
                    self.kern_legacy_pairs = @intCast(pairs);
                    self.kern_legacy_count = n_pairs;
                    return; // first usable subtable wins
                }
            }
            if (length == 0) return; // guard against a zero-length loop
            off += length;
        }
    }

    /// Walk GPOS (#116) to find the `kern` feature's PairPos (lookup type 2)
    /// subtables and record their offsets, so `kern()` can look up pair
    /// adjustments without re-walking the whole table per glyph pair. Best-
    /// effort and fully bounds-checked: any malformed offset just yields no
    /// kerning rather than a crash.
    fn collectKernSubtables(self: *Font, gpos: usize) void {
        const d = self.data;
        if (gpos + 10 > d.len) return;
        const feature_list = gpos + readU16(d, gpos + 6);
        const lookup_list = gpos + readU16(d, gpos + 8);
        if (feature_list + 2 > d.len or lookup_list + 2 > d.len) return;

        const feature_count = readU16(d, feature_list);
        var fi: usize = 0;
        while (fi < feature_count) : (fi += 1) {
            const rec = feature_list + 2 + fi * 6;
            if (rec + 6 > d.len) return;
            if (!std.mem.eql(u8, d[rec .. rec + 4], "kern")) continue;
            const feature = feature_list + readU16(d, rec + 4);
            if (feature + 4 > d.len) continue;
            const idx_count = readU16(d, feature + 2);
            var li: usize = 0;
            while (li < idx_count) : (li += 1) {
                const lookup_idx = readU16(d, feature + 4 + li * 2);
                self.collectLookupSubtables(lookup_list, lookup_idx);
            }
        }
    }

    fn collectLookupSubtables(self: *Font, lookup_list: usize, lookup_idx: u16) void {
        const d = self.data;
        const lookup_count = readU16(d, lookup_list);
        if (lookup_idx >= lookup_count) return;
        const lookup = lookup_list + readU16(d, lookup_list + 2 + @as(usize, lookup_idx) * 2);
        if (lookup + 6 > d.len) return;
        const lookup_type = readU16(d, lookup);
        const sub_count = readU16(d, lookup + 4);
        var si: usize = 0;
        while (si < sub_count) : (si += 1) {
            const sub = lookup + readU16(d, lookup + 6 + si * 2);
            // Type 9 = extension: redirect to the real subtable/type.
            if (lookup_type == 9) {
                if (sub + 8 > d.len) continue;
                const ext_type = readU16(d, sub + 2);
                const real = sub + readU32(d, sub + 4);
                if (ext_type == 2) self.pushKernSubtable(real);
            } else if (lookup_type == 2) {
                self.pushKernSubtable(sub);
            }
        }
    }

    fn pushKernSubtable(self: *Font, off: usize) void {
        if (self.kern_count >= self.kern_subtables.len) return;
        if (off + 2 > self.data.len) return;
        self.kern_subtables[self.kern_count] = @intCast(off);
        self.kern_count += 1;
    }

    /// Horizontal kerning adjustment (font units) to apply to `left`'s advance
    /// when followed by `right`, from GPOS PairPos (#116). 0 when the pair is
    /// uncovered or the font has no GPOS kerning. The first subtable that covers
    /// `left` decides (OpenType lookup order).
    pub fn kern(self: *const Font, left: u16, right: u16) i16 {
        var k: usize = 0;
        while (k < self.kern_count) : (k += 1) {
            if (self.pairPosAdjust(self.kern_subtables[k], left, right)) |adj| return adj;
        }
        if (self.kern_legacy_count > 0) return self.legacyKern(left, right);
        return 0;
    }

    /// Binary search the legacy `kern` format-0 pair array (sorted by the
    /// 32-bit key left<<16|right).
    fn legacyKern(self: *const Font, left: u16, right: u16) i16 {
        const d = self.data;
        const key = (@as(u32, left) << 16) | right;
        var lo: usize = 0;
        var hi: usize = self.kern_legacy_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = self.kern_legacy_pairs + mid * 6;
            const k = (@as(u32, readU16(d, rec)) << 16) | readU16(d, rec + 2);
            if (k == key) return readI16(d, rec + 4);
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return 0;
    }

    /// XAdvance adjustment for (left,right) from one PairPos subtable, or null
    /// if `left` isn't in its coverage (so the caller tries the next subtable).
    fn pairPosAdjust(self: *const Font, sub: usize, left: u16, right: u16) ?i16 {
        const d = self.data;
        if (sub + 4 > d.len) return null;
        const format = readU16(d, sub);
        const cov_index = self.coverageIndex(sub + readU16(d, sub + 2), left) orelse return null;
        const vf1 = readU16(d, sub + 4);
        const x_adv_off = xAdvanceOffset(vf1) orelse return 0; // covered, but no XAdvance field
        const v1_size = valueRecordSize(vf1);

        if (format == 1) {
            const vf2 = readU16(d, sub + 6);
            const v2_size = valueRecordSize(vf2);
            const pair_set_count = readU16(d, sub + 8);
            if (cov_index >= pair_set_count) return 0;
            const pair_set = sub + readU16(d, sub + 10 + @as(usize, cov_index) * 2);
            if (pair_set + 2 > d.len) return 0;
            const pair_count = readU16(d, pair_set);
            const rec_size = 2 + v1_size + v2_size;
            var p: usize = 0;
            while (p < pair_count) : (p += 1) {
                const rec = pair_set + 2 + p * rec_size;
                if (rec + 2 > d.len) return 0;
                if (readU16(d, rec) == right) {
                    if (rec + 2 + x_adv_off + 2 > d.len) return 0;
                    return readI16(d, rec + 2 + x_adv_off);
                }
            }
            return 0; // left covered, this right not paired
        } else if (format == 2) {
            const vf2 = readU16(d, sub + 6);
            const v2_size = valueRecordSize(vf2);
            const class_def1 = sub + readU16(d, sub + 8);
            const class_def2 = sub + readU16(d, sub + 10);
            const class1_count = readU16(d, sub + 12);
            const class2_count = readU16(d, sub + 14);
            const c1 = self.classOf(class_def1, left);
            const c2 = self.classOf(class_def2, right);
            if (c1 >= class1_count or c2 >= class2_count) return 0;
            const rec_size = v1_size + v2_size;
            const records = sub + 16;
            const rec = records + (@as(usize, c1) * class2_count + c2) * rec_size;
            if (rec + x_adv_off + 2 > d.len) return 0;
            return readI16(d, rec + x_adv_off);
        }
        return null;
    }

    /// Coverage-table lookup: glyph → coverage index, or null if not covered.
    fn coverageIndex(self: *const Font, cov: usize, glyph: u16) ?u16 {
        const d = self.data;
        if (cov + 4 > d.len) return null;
        const format = readU16(d, cov);
        if (format == 1) {
            const count = readU16(d, cov + 2);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (readU16(d, cov + 4 + i * 2) == glyph) return @intCast(i);
            }
            return null;
        } else if (format == 2) {
            const count = readU16(d, cov + 2);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const rec = cov + 4 + i * 6;
                const start = readU16(d, rec);
                const end = readU16(d, rec + 2);
                if (glyph >= start and glyph <= end) {
                    return readU16(d, rec + 4) + (glyph - start);
                }
            }
            return null;
        }
        return null;
    }

    /// ClassDef lookup: glyph → class (0 = default/unlisted).
    fn classOf(self: *const Font, cd: usize, glyph: u16) u16 {
        const d = self.data;
        if (cd + 2 > d.len) return 0;
        const format = readU16(d, cd);
        if (format == 1) {
            const start = readU16(d, cd + 2);
            const count = readU16(d, cd + 4);
            if (glyph < start or glyph >= start + count) return 0;
            return readU16(d, cd + 6 + @as(usize, glyph - start) * 2);
        } else if (format == 2) {
            const count = readU16(d, cd + 2);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const rec = cd + 4 + i * 6;
                const s = readU16(d, rec);
                const e = readU16(d, rec + 2);
                if (glyph >= s and glyph <= e) return readU16(d, rec + 4);
            }
            return 0;
        }
        return 0;
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
const poppins = @embedFile("poppins");

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

// A bare Font over a crafted `data` buffer, for testing the table parsers in
// isolation (no full TTF needed). Only the fields a given test reads matter.
fn bareFont(data: []const u8) Font {
    return .{
        .data = data,
        .units_per_em = 1000,
        .num_glyphs = 0,
        .ascent = 0,
        .descent = 0,
        .line_gap = 0,
        .long_hor_metrics = 0,
        .index_to_loc_long = false,
        .cmap_subtable = 0,
        .loca = 0,
        .glyf = 0,
        .hmtx = 0,
    };
}

fn wU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .big);
}
fn wI16(buf: []u8, off: usize, v: i16) void {
    std.mem.writeInt(i16, buf[off..][0..2], v, .big);
}

test "GPOS PairPos format 1 kerning" {
    var buf = [_]u8{0} ** 24;
    wU16(&buf, 0, 1); // posFormat
    wU16(&buf, 2, 12); // coverageOffset
    wU16(&buf, 4, 0x0004); // valueFormat1 = XAdvance only
    wU16(&buf, 6, 0); // valueFormat2
    wU16(&buf, 8, 1); // pairSetCount
    wU16(&buf, 10, 18); // pairSetOffset[0]
    // Coverage (format 1) @12: covers left glyph 10.
    wU16(&buf, 12, 1); // coverageFormat
    wU16(&buf, 14, 1); // glyphCount
    wU16(&buf, 16, 10); // glyph[0]
    // PairSet @18: one pair (right=20 → XAdvance -50).
    wU16(&buf, 18, 1); // pairValueCount
    wU16(&buf, 20, 20); // secondGlyph
    wI16(&buf, 22, -50); // value1.xAdvance

    var font = bareFont(&buf);
    font.kern_subtables[0] = 0;
    font.kern_count = 1;
    try testing.expectEqual(@as(i16, -50), font.kern(10, 20));
    try testing.expectEqual(@as(i16, 0), font.kern(10, 21)); // right not paired
    try testing.expectEqual(@as(i16, 0), font.kern(11, 20)); // left not covered
}

test "GPOS PairPos format 2 class kerning" {
    // class1Count=2, class2Count=2; only (class1=1,class2=1) → XAdvance -40.
    // Layout: header 16B, then 2×2 records of size 2 (vf1=XAdvance only).
    var buf = [_]u8{0} ** 64;
    wU16(&buf, 0, 2); // posFormat
    wU16(&buf, 2, 24); // coverageOffset
    wU16(&buf, 4, 0x0004); // valueFormat1
    wU16(&buf, 6, 0); // valueFormat2
    wU16(&buf, 8, 34); // classDef1Offset
    wU16(&buf, 10, 46); // classDef2Offset
    wU16(&buf, 12, 2); // class1Count
    wU16(&buf, 14, 2); // class2Count
    // class1Records @16: [c1=0]{[c2=0]0,[c2=1]0} [c1=1]{[c2=0]0,[c2=1]-40}
    wI16(&buf, 16, 0);
    wI16(&buf, 18, 0);
    wI16(&buf, 20, 0);
    wI16(&buf, 22, -40);
    // Coverage @24 (format 1): glyphs 10 and 11 (left side).
    wU16(&buf, 24, 1);
    wU16(&buf, 26, 2);
    wU16(&buf, 28, 10);
    wU16(&buf, 30, 11);
    // ClassDef1 @34 (format 1): start=10, count=2 → glyph10:class0, glyph11:class1
    wU16(&buf, 34, 1);
    wU16(&buf, 36, 10);
    wU16(&buf, 38, 2);
    wU16(&buf, 40, 0);
    wU16(&buf, 42, 1);
    // ClassDef2 @46 (format 1): start=20, count=2 → glyph20:class0, glyph21:class1
    wU16(&buf, 46, 1);
    wU16(&buf, 48, 20);
    wU16(&buf, 50, 2);
    wU16(&buf, 52, 0);
    wU16(&buf, 54, 1);

    var font = bareFont(&buf);
    font.kern_subtables[0] = 0;
    font.kern_count = 1;
    try testing.expectEqual(@as(i16, -40), font.kern(11, 21)); // class1=1, class2=1
    try testing.expectEqual(@as(i16, 0), font.kern(10, 20)); // class 0/0
    try testing.expectEqual(@as(i16, 0), font.kern(10, 21)); // class 0/1
}

test "legacy kern table format 0 binary search" {
    // Two sorted pairs: (10,20)→-30, (10,25)→+15.
    var buf = [_]u8{0} ** 12;
    wU16(&buf, 0, 10);
    wU16(&buf, 2, 20);
    wI16(&buf, 4, -30);
    wU16(&buf, 6, 10);
    wU16(&buf, 8, 25);
    wI16(&buf, 10, 15);

    var font = bareFont(&buf);
    font.kern_legacy_pairs = 0;
    font.kern_legacy_count = 2;
    try testing.expectEqual(@as(i16, -30), font.kern(10, 20));
    try testing.expectEqual(@as(i16, 15), font.kern(10, 25));
    try testing.expectEqual(@as(i16, 0), font.kern(10, 99));
    try testing.expectEqual(@as(i16, 0), font.kern(5, 20));
}

test "no kern data → zero, no crash" {
    const font = try Font.parse(poppins); // this build has neither GPOS kern nor a kern table
    try testing.expectEqual(@as(usize, 0), font.kern_count);
    try testing.expectEqual(@as(i16, 0), font.kern(font.glyphIndex('A'), font.glyphIndex('V')));
}

test "composite glyph resolves (é)" {
    const font = try Font.parse(poppins);
    const g = font.glyphIndex(0xE9); // é — typically composite (e + acute)
    if (g == 0) return; // font subset without it: skip
    var out = (try font.outline(testing.allocator, g)) orelse return error.TestUnexpectedResult;
    defer out.deinit(testing.allocator);
    try testing.expect(out.points.len > 10);
}
