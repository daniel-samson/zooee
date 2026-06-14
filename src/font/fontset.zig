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
};

// === Tests ==================================================================

const testing = std.testing;
const test_ttf = @embedFile("poppins");

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
