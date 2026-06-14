//! A set of font faces (#114): a primary family with regular/bold/italic/
//! bold-italic variants, plus a fallback chain of extra fonts for codepoints
//! the primary lacks. Per character, `resolve` picks the right face — so bold
//! and italic render real faces (not the regular one), and a glyph missing
//! from the primary falls through to a font that has it instead of a `.notdef`
//! box.
//!
//! Faces borrow their file bytes (loaded by `font/system.zig`), which must
//! outlive the set. `face_id` is a small stable index used to key glyph caches/
//! atlases so the same glyph index from two different faces doesn't collide.

const std = @import("std");
const ttf = @import("ttf.zig");

pub const Style = struct { bold: bool = false, italic: bool = false };

/// A resolved glyph: which face to rasterize from (and key the cache by) and
/// the glyph index within that face.
pub const Glyph = struct { face_id: u8, glyph: u16 };

/// Shaping iterator (#201): turns a UTF-8 string into a sequence of output
/// glyphs, applying GSUB standard ligatures (e.g. f+i → fi). Each `next()`
/// yields one resolved glyph — usually one per codepoint, but a ligature
/// collapses several. Pure/allocation-free: it resolves codepoints lazily into
/// a small lookahead buffer and substitutes at the head. Ligatures only span a
/// contiguous run from the same face (cross-face fallback breaks the run).
/// `measure` and every backend's drawText drive this so they agree.
pub const Shaper = struct {
    set: *const FontSet,
    style: Style,
    it: std.unicode.Utf8Iterator,
    buf: [max_lookahead]Glyph = undefined,
    len: usize = 0,

    /// Bounds the longest ligature (component count) and the lookahead.
    const max_lookahead = 16;

    pub fn init(set: *const FontSet, style: Style, text: []const u8) Shaper {
        return .{ .set = set, .style = style, .it = std.unicode.Utf8View.initUnchecked(text).iterator() };
    }

    fn fill(self: *Shaper) void {
        while (self.len < max_lookahead) {
            const cp = self.it.nextCodepoint() orelse break;
            self.buf[self.len] = self.set.resolve(cp, self.style);
            self.len += 1;
        }
    }

    fn shift(self: *Shaper, n: usize) void {
        var i: usize = 0;
        while (i + n < self.len) : (i += 1) self.buf[i] = self.buf[i + n];
        self.len -= n;
    }

    /// The next output glyph, or null at end of text.
    pub fn next(self: *Shaper) ?Glyph {
        self.fill();
        if (self.len == 0) return null;
        const head = self.buf[0];
        // Contiguous same-face run available for ligature matching.
        var run: usize = 1;
        while (run < self.len and self.buf[run].face_id == head.face_id) : (run += 1) {}
        var gids: [max_lookahead]u16 = undefined;
        var i: usize = 0;
        while (i < run) : (i += 1) gids[i] = self.buf[i].glyph;
        const face = self.set.face(head.face_id);
        if (face.ligature(gids[0..run])) |r| {
            self.shift(r.consumed);
            return .{ .face_id = head.face_id, .glyph = r.glyph };
        }
        self.shift(1);
        return head;
    }
};

pub const FontSet = struct {
    /// Slot layout: 0=regular, 1=bold, 2=italic, 3=bold-italic, 4..=fallbacks.
    faces: [max_faces]?ttf.Font = .{null} ** max_faces,
    /// One past the highest used slot (for iterating the fallback chain).
    count: u8 = 0,

    pub const max_faces = 12;
    pub const regular: u8 = 0;
    pub const bold_slot: u8 = 1;
    pub const italic_slot: u8 = 2;
    pub const bold_italic_slot: u8 = 3;
    pub const fallback_start: u8 = 4;

    /// Set a primary variant face (regular/bold/italic/bold-italic).
    pub fn setFace(self: *FontSet, slot: u8, font: ttf.Font) void {
        self.faces[slot] = font;
        if (slot + 1 > self.count) self.count = slot + 1;
    }

    /// Append a fallback face; ignored if the chain is full.
    pub fn addFallback(self: *FontSet, font: ttf.Font) void {
        const i: u8 = @max(self.count, fallback_start);
        if (i >= max_faces) return;
        self.faces[i] = font;
        self.count = i + 1;
    }

    /// The slot to use for `style`, falling back to regular if the variant
    /// isn't loaded.
    fn styleSlot(self: *const FontSet, style: Style) u8 {
        const want: u8 = if (style.bold and style.italic)
            bold_italic_slot
        else if (style.bold)
            bold_slot
        else if (style.italic)
            italic_slot
        else
            regular;
        return if (self.faces[want] != null) want else regular;
    }

    /// Resolve a codepoint to a face + glyph: the styled face first, then
    /// regular, then the fallback chain. Returns the regular face's `.notdef`
    /// (glyph 0) when nothing covers it.
    pub fn resolve(self: *const FontSet, cp: u21, style: Style) Glyph {
        const primary_slot = self.styleSlot(style);
        if (self.faces[primary_slot]) |f| {
            const g = f.glyphIndex(cp);
            if (g != 0) return .{ .face_id = primary_slot, .glyph = g };
        }
        if (primary_slot != regular) {
            if (self.faces[regular]) |f| {
                const g = f.glyphIndex(cp);
                if (g != 0) return .{ .face_id = regular, .glyph = g };
            }
        }
        var i: u8 = fallback_start;
        while (i < self.count) : (i += 1) {
            if (self.faces[i]) |f| {
                const g = f.glyphIndex(cp);
                if (g != 0) return .{ .face_id = i, .glyph = g };
            }
        }
        return .{ .face_id = regular, .glyph = 0 };
    }

    pub fn face(self: *const FontSet, id: u8) *const ttf.Font {
        return &(self.faces[id].?);
    }

    /// The primary regular face — the source of line metrics (ascent/descent/
    /// line-gap) so wrapped/mixed-face text shares one baseline grid.
    pub fn primary(self: *const FontSet) *const ttf.Font {
        return self.face(regular);
    }

    pub fn hasAny(self: *const FontSet) bool {
        return self.faces[regular] != null;
    }

    pub const Metrics = struct { width: f32, height: f32 };

    /// Advance width + line height of `text` at `size`, resolving each codepoint
    /// through the face set (bold/italic/fallback). Line height comes from the
    /// primary face so mixed-face runs share one grid. Shared by every backend's
    /// measureText so they agree (#114).
    pub fn measure(self: *const FontSet, text: []const u8, size: f32, style: Style) Metrics {
        var width: f32 = 0;
        var prev: ?Glyph = null;
        // Shape (#201 ligatures) then measure the output glyphs, so width matches
        // what the backends render.
        var sh = Shaper.init(self, style, text);
        while (sh.next()) |g| {
            const f = self.face(g.face_id);
            const scale = size / @as(f32, @floatFromInt(f.units_per_em));
            // Kerning (#116): same-face pairs only (cross-face fallback pairs
            // have no shared kern data).
            if (prev) |pg| if (pg.face_id == g.face_id) {
                width += @as(f32, @floatFromInt(f.kern(pg.glyph, g.glyph))) * scale;
            };
            width += @as(f32, @floatFromInt(f.hMetrics(g.glyph).advance)) * scale;
            prev = g;
        }
        const p = self.primary();
        const line = @as(f32, @floatFromInt(p.ascent - p.descent + p.line_gap)) * (size / @as(f32, @floatFromInt(p.units_per_em)));
        return .{ .width = width, .height = line };
    }
};

// === Tests ==================================================================

const testing = std.testing;
const test_ttf = @embedFile("poppins");

test "shaper yields one glyph per codepoint when the font has no ligatures" {
    const f = try ttf.Font.parse(test_ttf); // Poppins has no `liga`
    var set: FontSet = .{};
    set.setFace(FontSet.regular, f);
    var sh = Shaper.init(&set, .{}, "fi");
    const g1 = sh.next() orelse return error.TestUnexpectedResult;
    const g2 = sh.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?Glyph, null), sh.next());
    // Identity: each output glyph equals the per-codepoint resolution.
    try testing.expectEqual(set.resolve('f', .{}).glyph, g1.glyph);
    try testing.expectEqual(set.resolve('i', .{}).glyph, g2.glyph);
}

test "resolve falls back through the chain and to .notdef" {
    const f = try ttf.Font.parse(test_ttf);
    var set: FontSet = .{};
    set.setFace(FontSet.regular, f);

    // A glyph the font has → regular face, non-zero glyph.
    const a = set.resolve('A', .{});
    try testing.expectEqual(@as(u8, FontSet.regular), a.face_id);
    try testing.expect(a.glyph != 0);

    // Bold requested but no bold face loaded → falls back to regular slot.
    const b = set.resolve('A', .{ .bold = true });
    try testing.expectEqual(@as(u8, FontSet.regular), b.face_id);

    // A codepoint no loaded face covers → regular face, glyph 0 (.notdef).
    const miss = set.resolve(0x1F600, .{}); // emoji, not in Poppins
    try testing.expectEqual(@as(u16, 0), miss.glyph);
}

test "bold face is selected when loaded" {
    const f = try ttf.Font.parse(test_ttf);
    var set: FontSet = .{};
    set.setFace(FontSet.regular, f);
    set.setFace(FontSet.bold_slot, f); // reuse same bytes as a stand-in
    const b = set.resolve('A', .{ .bold = true });
    try testing.expectEqual(@as(u8, FontSet.bold_slot), b.face_id);
}
