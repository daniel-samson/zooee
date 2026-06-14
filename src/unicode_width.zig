//! Terminal display width (#18): how many cells a codepoint occupies in a
//! fixed-cell grid. Wide East Asian characters take 2 cells, combining marks /
//! zero-width controls take 0, everything else takes 1.
//!
//! v1 scope: a compact hand-curated range table covering the load-bearing
//! blocks (CJK/Hangul/Kana, fullwidth forms, common emoji, combining marks).
//! Deferred: full grapheme-cluster segmentation (ZWJ emoji, skin-tone
//! modifiers measured as one unit), generated Unicode tables, and a
//! configurable East Asian *ambiguous*-width policy (we default ambiguous to
//! narrow, the common terminal default). Shared by `terminal.measureText`.

const std = @import("std");

/// Cells occupied by `cp`: 0 (combining / zero-width), 1 (normal), or 2 (wide).
pub fn charWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    // C0/C1 control characters render as nothing in a cell grid.
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (isZeroWidth(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// Total display width of a UTF-8 string in cells (#18).
pub fn measureWidth(text: []const u8) usize {
    var w: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| w += charWidth(cp);
    return w;
}

fn inRange(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

fn isZeroWidth(cp: u21) bool {
    return inRange(cp, 0x0300, 0x036F) or // combining diacritical marks
        inRange(cp, 0x0483, 0x0489) or // Cyrillic combining
        inRange(cp, 0x0591, 0x05BD) or // Hebrew points
        inRange(cp, 0x0610, 0x061A) or // Arabic marks
        inRange(cp, 0x064B, 0x065F) or // Arabic marks
        inRange(cp, 0x0670, 0x0670) or
        inRange(cp, 0x06D6, 0x06DC) or
        inRange(cp, 0x0E31, 0x0E31) or
        inRange(cp, 0x0E34, 0x0E3A) or // Thai combining
        inRange(cp, 0x1160, 0x11FF) or // Hangul Jamo medial/final (combining)
        cp == 0x200B or // zero-width space
        inRange(cp, 0x200C, 0x200F) or // ZWNJ/ZWJ/marks
        inRange(cp, 0x202A, 0x202E) or // bidi controls
        cp == 0x2060 or // word joiner
        inRange(cp, 0x20D0, 0x20FF) or // combining marks for symbols
        inRange(cp, 0xFE00, 0xFE0F) or // variation selectors
        inRange(cp, 0xFE20, 0xFE2F) or // combining half marks
        cp == 0xFEFF or // BOM / zero-width no-break space
        inRange(cp, 0x1AB0, 0x1AFF) or
        inRange(cp, 0x1DC0, 0x1DFF) or
        inRange(cp, 0xE0100, 0xE01EF); // variation selectors supplement
}

fn isWide(cp: u21) bool {
    return inRange(cp, 0x1100, 0x115F) or // Hangul Jamo (leading)
        inRange(cp, 0x2329, 0x232A) or // angle brackets
        inRange(cp, 0x2E80, 0x303E) or // CJK radicals, Kangxi, symbols
        inRange(cp, 0x3041, 0x33FF) or // Hiragana..CJK compatibility
        inRange(cp, 0x3400, 0x4DBF) or // CJK ext A
        inRange(cp, 0x4E00, 0x9FFF) or // CJK unified
        inRange(cp, 0xA000, 0xA4CF) or // Yi
        inRange(cp, 0xAC00, 0xD7A3) or // Hangul syllables
        inRange(cp, 0xF900, 0xFAFF) or // CJK compatibility ideographs
        inRange(cp, 0xFE10, 0xFE19) or // vertical forms
        inRange(cp, 0xFE30, 0xFE6F) or // CJK compatibility forms / small forms
        inRange(cp, 0xFF00, 0xFF60) or // fullwidth forms
        inRange(cp, 0xFFE0, 0xFFE6) or // fullwidth signs
        inRange(cp, 0x1F300, 0x1F64F) or // emoji: symbols + emoticons
        inRange(cp, 0x1F900, 0x1F9FF) or // emoji: supplemental symbols
        inRange(cp, 0x1FA70, 0x1FAFF) or // emoji: symbols extended-A
        inRange(cp, 0x20000, 0x3FFFD); // CJK ext B+ (supplementary ideographic)
}

// === Tests ==================================================================

const testing = std.testing;

test "ascii and latin are width 1" {
    try testing.expectEqual(@as(u2, 1), charWidth('A'));
    try testing.expectEqual(@as(u2, 1), charWidth('z'));
    try testing.expectEqual(@as(u2, 1), charWidth(0xE9)); // é
}

test "CJK / fullwidth / kana / hangul are width 2" {
    try testing.expectEqual(@as(u2, 2), charWidth('中'));
    try testing.expectEqual(@as(u2, 2), charWidth('あ')); // Hiragana
    try testing.expectEqual(@as(u2, 2), charWidth('한')); // Hangul syllable
    try testing.expectEqual(@as(u2, 2), charWidth('Ａ')); // fullwidth A
}

test "combining marks and zero-width controls are width 0" {
    try testing.expectEqual(@as(u2, 0), charWidth(0x0301)); // combining acute
    try testing.expectEqual(@as(u2, 0), charWidth(0x200D)); // ZWJ
    try testing.expectEqual(@as(u2, 0), charWidth(0xFE0F)); // variation selector
    try testing.expectEqual(@as(u2, 0), charWidth(0)); // NUL
    try testing.expectEqual(@as(u2, 0), charWidth('\n'));
}

test "measureWidth sums cells across a mixed string" {
    try testing.expectEqual(@as(usize, 5), measureWidth("hello"));
    try testing.expectEqual(@as(usize, 4), measureWidth("中文")); // 2 wide = 4 cells
    try testing.expectEqual(@as(usize, 6), measureWidth("hi 中a")); // 1+1+1+2+1
    // "e" + combining acute = 1 cell (the mark adds 0).
    try testing.expectEqual(@as(usize, 1), measureWidth("e\u{0301}"));
}
