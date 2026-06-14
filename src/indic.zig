//! Indic reordering (#202, complex-script shaping slice 2): Indic scripts store
//! text in logical (phonetic) order, but some vowel signs render in a different
//! position. The most common and visible case — handled here — is the
//! **pre-base (left-reordering) matra**: e.g. DEVANAGARI VOWEL SIGN I (U+093F)
//! is typed/stored *after* its consonant but draws to its *left*. Naive
//! left-to-right glyph rendering would place it on the wrong side; this moves
//! it before its consonant cluster so a non-shaping renderer draws it correctly.
//!
//! Pipeline position: this runs on the logical string, before BiDi visual
//! reordering (Indic is LTR; the matra move is within the run). See
//! `layout.shapeForDisplay`.
//!
//! v1 scope: Devanagari pre-base matra (U+093F) reordering to the front of its
//! consonant cluster (scanning back over consonant+virama pairs). Pure ASCII /
//! no-Devanagari input is returned untouched (byte-for-byte). Deferred (same
//! issue): reph (initial ra+virama) reordering, split/two-part matras
//! (U+094B/U+094C), other Indic scripts (Bengali, Tamil, …), and GPOS mark
//! positioning. A real shaper would also form half-forms via GSUB.

const std = @import("std");

/// DEVANAGARI VOWEL SIGN I — the canonical left-reordering (pre-base) matra:
/// stored after the consonant, rendered before it.
const dev_vowel_sign_i: u21 = 0x093F;

/// DEVANAGARI SIGN VIRAMA (halant) — joins consonants into a conjunct cluster.
const dev_virama: u21 = 0x094D;

/// Whether `cp` is a Devanagari consonant (the base of a syllable cluster).
/// Covers the main block KA..HA plus the nukta'd additions QA..YYA.
fn isDevConsonant(cp: u21) bool {
    return (cp >= 0x0915 and cp <= 0x0939) or (cp >= 0x0958 and cp <= 0x095F);
}

/// Reorder Devanagari pre-base matras in a UTF-8 string for non-shaping
/// rendering. Returns `text` unchanged when there is nothing to do (no high
/// bytes, no Devanagari, or no reordering needed) so Latin/ASCII stays
/// byte-for-byte identical. Otherwise writes the reordered UTF-8 into `out` and
/// returns that slice; falls back to `text` if `out` is too small.
pub fn reorderUtf8(text: []const u8, out: []u8) []const u8 {
    // Fast path: a pre-base matra requires a byte from the Devanagari block
    // (U+0900–U+097F → lead byte 0xE0, 0xA4/0xA5 continuation). Cheapest
    // sufficient probe: any byte ≥ 0x80 means "decode and check"; pure ASCII
    // can never contain U+093F.
    var has_high = false;
    for (text) |b| {
        if (b >= 0x80) {
            has_high = true;
            break;
        }
    }
    if (!has_high) return text;

    const cap = 512;
    var cps: [cap]u21 = undefined;
    var byte_len: [cap]u3 = undefined;
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var saw_matra = false;
    while (it.nextCodepoint()) |cp| {
        if (n >= cap) return text; // too long → leave logical
        cps[n] = cp;
        byte_len[n] = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (cp == dev_vowel_sign_i) saw_matra = true;
        n += 1;
    }
    if (!saw_matra) return text; // no left-matra anywhere → identity

    // Move each pre-base matra to the front of its consonant cluster. Walk
    // left-to-right; when a matra follows a consonant, find the cluster start
    // (back over [consonant virama] pairs) and rotate the matra before it.
    var changed = false;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (cps[i] != dev_vowel_sign_i) continue;
        if (!isDevConsonant(cps[i - 1])) continue; // stray matra → leave it
        var start = i - 1;
        // Extend the cluster backwards over conjunct joins: C virama C ...
        while (start >= 2 and cps[start - 1] == dev_virama and isDevConsonant(cps[start - 2])) {
            start -= 2;
        }
        // Rotate cps[start..i] right by one so the matra lands at `start`.
        const matra = cps[i];
        const matra_len = byte_len[i];
        var k: usize = i;
        while (k > start) : (k -= 1) {
            cps[k] = cps[k - 1];
            byte_len[k] = byte_len[k - 1];
        }
        cps[start] = matra;
        byte_len[start] = matra_len;
        changed = true;
    }
    if (!changed) return text;

    var w: usize = 0;
    for (cps[0..n], byte_len[0..n]) |cp, need| {
        if (w + need > out.len) return text;
        w += std.unicode.utf8Encode(cp, out[w..]) catch return text;
    }
    return out[0..w];
}

// === Tests ==================================================================

const testing = std.testing;

test "ASCII is returned untouched (no allocation, identity)" {
    var out: [64]u8 = undefined;
    const s = "hello world";
    try testing.expectEqualStrings(s, reorderUtf8(s, &out));
}

test "Devanagari without a left-matra is identity" {
    var out: [64]u8 = undefined;
    // क + ा (vowel sign AA, a RIGHT-side matra) — no reordering.
    const s = "\u{0915}\u{093E}";
    try testing.expectEqualStrings(s, reorderUtf8(s, &out));
}

test "pre-base matra moves before its consonant (कि → ि+क)" {
    var out: [64]u8 = undefined;
    // Logical: KA (U+0915) then VOWEL SIGN I (U+093F). Visual: I then KA.
    const logical = "\u{0915}\u{093F}";
    const expected = "\u{093F}\u{0915}";
    try testing.expectEqualStrings(expected, reorderUtf8(logical, &out));
}

test "pre-base matra moves before the whole conjunct cluster" {
    var out: [64]u8 = undefined;
    // KA virama TA + short-i: stored K-virama-T-i, the i renders before K.
    const logical = "\u{0915}\u{094D}\u{0924}\u{093F}";
    const expected = "\u{093F}\u{0915}\u{094D}\u{0924}";
    try testing.expectEqualStrings(expected, reorderUtf8(logical, &out));
}

test "matra reorder is local — surrounding text is preserved" {
    var out: [64]u8 = undefined;
    // "a" + कि + "b": only the कि pair reorders; the Latin stays put.
    const logical = "a\u{0915}\u{093F}b";
    const expected = "a\u{093F}\u{0915}b";
    try testing.expectEqualStrings(expected, reorderUtf8(logical, &out));
}

test "two independent syllables each reorder" {
    var out: [64]u8 = undefined;
    // कि गि → ि क ि ग
    const logical = "\u{0915}\u{093F}\u{0917}\u{093F}";
    const expected = "\u{093F}\u{0915}\u{093F}\u{0917}";
    try testing.expectEqualStrings(expected, reorderUtf8(logical, &out));
}

test "stray matra with no preceding consonant is left in place" {
    var out: [64]u8 = undefined;
    const s = "\u{093F}\u{0915}"; // already matra-first; consonant after
    try testing.expectEqualStrings(s, reorderUtf8(s, &out));
}
