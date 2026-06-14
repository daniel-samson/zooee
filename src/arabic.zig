//! Arabic contextual joining (#202, complex-script shaping slice 1): Arabic
//! letters take one of four shapes — isolated / initial / medial / final —
//! depending on whether they connect to their neighbours. This resolves the
//! form for each letter from its joining context and maps it to the matching
//! Arabic Presentation Forms-B codepoint (U+FE70–FEFF), which the font renders.
//!
//! v1 scope: the joining algorithm + a presentation-forms table for the core
//! Arabic letters, in logical order. Deferred (same issue): the full letter
//! table, lam-alef ligatures, mandatory/optional ligatures via GSUB, and Indic
//! reordering. Works on the common case (Arabic words joining correctly).

const std = @import("std");

const JoiningType = enum { dual, right, transparent, none };

const Letter = struct {
    base: u21,
    jt: JoiningType,
    iso: u21,
    fin: u21,
    init: u21 = 0, // 0 = no initial/medial form (right-joining letters)
    med: u21 = 0,
};

// Curated table of the core Arabic letters → Presentation Forms-B. Dual-joining
// letters have all four forms; right-joining (alef, dal, reh, waw, …) only
// isolated + final.
const table = [_]Letter{
    .{ .base = 0x0627, .jt = .right, .iso = 0xFE8D, .fin = 0xFE8E }, // ALEF
    .{ .base = 0x0628, .jt = .dual, .iso = 0xFE8F, .fin = 0xFE90, .init = 0xFE91, .med = 0xFE92 }, // BEH
    .{ .base = 0x0629, .jt = .right, .iso = 0xFE93, .fin = 0xFE94 }, // TEH MARBUTA
    .{ .base = 0x062A, .jt = .dual, .iso = 0xFE95, .fin = 0xFE96, .init = 0xFE97, .med = 0xFE98 }, // TEH
    .{ .base = 0x062B, .jt = .dual, .iso = 0xFE99, .fin = 0xFE9A, .init = 0xFE9B, .med = 0xFE9C }, // THEH
    .{ .base = 0x062C, .jt = .dual, .iso = 0xFE9D, .fin = 0xFE9E, .init = 0xFE9F, .med = 0xFEA0 }, // JEEM
    .{ .base = 0x062D, .jt = .dual, .iso = 0xFEA1, .fin = 0xFEA2, .init = 0xFEA3, .med = 0xFEA4 }, // HAH
    .{ .base = 0x062E, .jt = .dual, .iso = 0xFEA5, .fin = 0xFEA6, .init = 0xFEA7, .med = 0xFEA8 }, // KHAH
    .{ .base = 0x062F, .jt = .right, .iso = 0xFEA9, .fin = 0xFEAA }, // DAL
    .{ .base = 0x0630, .jt = .right, .iso = 0xFEAB, .fin = 0xFEAC }, // THAL
    .{ .base = 0x0631, .jt = .right, .iso = 0xFEAD, .fin = 0xFEAE }, // REH
    .{ .base = 0x0632, .jt = .right, .iso = 0xFEAF, .fin = 0xFEB0 }, // ZAIN
    .{ .base = 0x0633, .jt = .dual, .iso = 0xFEB1, .fin = 0xFEB2, .init = 0xFEB3, .med = 0xFEB4 }, // SEEN
    .{ .base = 0x0634, .jt = .dual, .iso = 0xFEB5, .fin = 0xFEB6, .init = 0xFEB7, .med = 0xFEB8 }, // SHEEN
    .{ .base = 0x0635, .jt = .dual, .iso = 0xFEB9, .fin = 0xFEBA, .init = 0xFEBB, .med = 0xFEBC }, // SAD
    .{ .base = 0x0636, .jt = .dual, .iso = 0xFEBD, .fin = 0xFEBE, .init = 0xFEBF, .med = 0xFEC0 }, // DAD
    .{ .base = 0x0637, .jt = .dual, .iso = 0xFEC1, .fin = 0xFEC2, .init = 0xFEC3, .med = 0xFEC4 }, // TAH
    .{ .base = 0x0638, .jt = .dual, .iso = 0xFEC5, .fin = 0xFEC6, .init = 0xFEC7, .med = 0xFEC8 }, // ZAH
    .{ .base = 0x0639, .jt = .dual, .iso = 0xFEC9, .fin = 0xFECA, .init = 0xFECB, .med = 0xFECC }, // AIN
    .{ .base = 0x063A, .jt = .dual, .iso = 0xFECD, .fin = 0xFECE, .init = 0xFECF, .med = 0xFED0 }, // GHAIN
    .{ .base = 0x0641, .jt = .dual, .iso = 0xFED1, .fin = 0xFED2, .init = 0xFED3, .med = 0xFED4 }, // FEH
    .{ .base = 0x0642, .jt = .dual, .iso = 0xFED5, .fin = 0xFED6, .init = 0xFED7, .med = 0xFED8 }, // QAF
    .{ .base = 0x0643, .jt = .dual, .iso = 0xFED9, .fin = 0xFEDA, .init = 0xFEDB, .med = 0xFEDC }, // KAF
    .{ .base = 0x0644, .jt = .dual, .iso = 0xFEDD, .fin = 0xFEDE, .init = 0xFEDF, .med = 0xFEE0 }, // LAM
    .{ .base = 0x0645, .jt = .dual, .iso = 0xFEE1, .fin = 0xFEE2, .init = 0xFEE3, .med = 0xFEE4 }, // MEEM
    .{ .base = 0x0646, .jt = .dual, .iso = 0xFEE5, .fin = 0xFEE6, .init = 0xFEE7, .med = 0xFEE8 }, // NOON
    .{ .base = 0x0647, .jt = .dual, .iso = 0xFEE9, .fin = 0xFEEA, .init = 0xFEEB, .med = 0xFEEC }, // HEH
    .{ .base = 0x0648, .jt = .right, .iso = 0xFEED, .fin = 0xFEEE }, // WAW
    .{ .base = 0x0649, .jt = .right, .iso = 0xFEEF, .fin = 0xFEF0 }, // ALEF MAKSURA
    .{ .base = 0x064A, .jt = .dual, .iso = 0xFEF1, .fin = 0xFEF2, .init = 0xFEF3, .med = 0xFEF4 }, // YEH
};

fn lookup(cp: u21) ?*const Letter {
    for (&table) |*l| if (l.base == cp) return l;
    return null;
}

/// Joining type of a codepoint (#202). Combining marks are transparent (they
/// don't break a join); non-Arabic / unknown codepoints are non-joining.
pub fn joiningType(cp: u21) JoiningType {
    if ((cp >= 0x0610 and cp <= 0x061A) or (cp >= 0x064B and cp <= 0x065F) or
        cp == 0x0670 or (cp >= 0x06D6 and cp <= 0x06DC)) return .transparent;
    if (lookup(cp)) |l| return l.jt;
    return .none;
}

fn joinsBack(t: JoiningType) bool { // can connect to the preceding (right) letter
    return t == .dual or t == .right;
}
fn joinsFwd(t: JoiningType) bool { // can connect to the following (left) letter
    return t == .dual;
}

/// Resolve an Arabic letter's presentation form from its connections; returns
/// `cp` unchanged if it isn't a shaped Arabic letter.
fn formOf(cp: u21, connect_prev: bool, connect_next: bool) u21 {
    const l = lookup(cp) orelse return cp;
    if (connect_prev and connect_next and l.med != 0) return l.med;
    if (connect_prev and l.fin != 0) return l.fin;
    if (connect_next and l.init != 0) return l.init;
    return l.iso;
}

/// Apply Arabic contextual joining to a codepoint run (logical order), writing
/// the shaped run to `out` (same length). Transparent marks pass through and
/// don't break joins. `out` and `cps` may not overlap.
pub fn shape(cps: []const u21, out: []u21) void {
    std.debug.assert(out.len == cps.len);
    const n = cps.len;
    for (cps, 0..) |cp, i| {
        const jt = joiningType(cp);
        if (jt == .transparent or jt == .none) {
            out[i] = cp;
            continue;
        }
        // Nearest non-transparent neighbours.
        var prev_jt: JoiningType = .none;
        var k: usize = i;
        while (k > 0) {
            k -= 1;
            const t = joiningType(cps[k]);
            if (t != .transparent) {
                prev_jt = t;
                break;
            }
        }
        var next_jt: JoiningType = .none;
        var j = i + 1;
        while (j < n) : (j += 1) {
            const t = joiningType(cps[j]);
            if (t != .transparent) {
                next_jt = t;
                break;
            }
        }
        const connect_prev = joinsFwd(prev_jt) and joinsBack(jt);
        const connect_next = joinsFwd(jt) and joinsBack(next_jt);
        out[i] = formOf(cp, connect_prev, connect_next);
    }
}

/// Apply Arabic joining to a UTF-8 string, writing the shaped result (with
/// letters replaced by their presentation forms) to `out`. Returns the shaped
/// slice — or `text` unchanged when it has no shapeable Arabic letters, or
/// doesn't fit the internal buffers. The text layout (#202) calls this per line
/// (before BiDi reorder, since joining is on logical order). Note the forms are
/// 3-byte UTF-8, so `out` should be ~1.5× `text`.
pub fn shapeUtf8(text: []const u8, out: []u8) []const u8 {
    var has_arabic = false;
    var probe = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (probe.nextCodepoint()) |cp| {
        const t = joiningType(cp);
        if (t == .dual or t == .right) {
            has_arabic = true;
            break;
        }
    }
    if (!has_arabic) return text;

    const cap = 512;
    var cps: [cap]u21 = undefined;
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= cap) return text;
        cps[n] = cp;
        n += 1;
    }
    var shaped: [cap]u21 = undefined;
    shape(cps[0..n], shaped[0..n]);
    var w: usize = 0;
    for (shaped[0..n]) |cp| {
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (w + len > out.len) return text;
        w += std.unicode.utf8Encode(cp, out[w..]) catch return text;
    }
    return out[0..w];
}

// === Tests ==================================================================

const testing = std.testing;

test "single Arabic letter takes its isolated form" {
    var out: [1]u21 = undefined;
    shape(&.{0x0628}, &out); // BEH alone
    try testing.expectEqual(@as(u21, 0xFE8F), out[0]); // BEH isolated
}

test "two dual-joining letters: initial + final" {
    var out: [2]u21 = undefined;
    shape(&.{ 0x0628, 0x0645 }, &out); // BEH + MEEM ("بم")
    try testing.expectEqual(@as(u21, 0xFE91), out[0]); // BEH initial
    try testing.expectEqual(@as(u21, 0xFEE2), out[1]); // MEEM final
}

test "three dual letters: initial + medial + final" {
    var out: [3]u21 = undefined;
    shape(&.{ 0x0628, 0x062A, 0x0645 }, &out); // BEH TEH MEEM
    try testing.expectEqual(@as(u21, 0xFE91), out[0]); // BEH initial
    try testing.expectEqual(@as(u21, 0xFE98), out[1]); // TEH medial
    try testing.expectEqual(@as(u21, 0xFEE2), out[2]); // MEEM final
}

test "right-joining letter never takes initial/medial" {
    var out: [2]u21 = undefined;
    // BEH + ALEF ("با"): ALEF joins back to BEH (final), but ALEF can't join
    // forward, so BEH is initial.
    shape(&.{ 0x0628, 0x0627 }, &out);
    try testing.expectEqual(@as(u21, 0xFE91), out[0]); // BEH initial
    try testing.expectEqual(@as(u21, 0xFE8E), out[1]); // ALEF final
    // REH after BEH: REH is right-joining → final; never medial even mid-word.
    var out2: [3]u21 = undefined;
    shape(&.{ 0x0628, 0x0631, 0x0628 }, &out2); // BEH REH BEH
    try testing.expectEqual(@as(u21, 0xFE91), out2[0]); // BEH initial
    try testing.expectEqual(@as(u21, 0xFEAE), out2[1]); // REH final (not medial)
    try testing.expectEqual(@as(u21, 0xFE8F), out2[2]); // BEH isolated (REH didn't join fwd)
}

test "combining mark is transparent to joining" {
    var out: [3]u21 = undefined;
    // BEH + fatha(064E, transparent) + MEEM: BEH still joins MEEM through the mark.
    shape(&.{ 0x0628, 0x064E, 0x0645 }, &out);
    try testing.expectEqual(@as(u21, 0xFE91), out[0]); // BEH initial
    try testing.expectEqual(@as(u21, 0x064E), out[1]); // mark unchanged
    try testing.expectEqual(@as(u21, 0xFEE2), out[2]); // MEEM final
}

test "non-Arabic text is unchanged" {
    var out: [3]u21 = undefined;
    shape(&.{ 'a', 'b', 'c' }, &out);
    try testing.expectEqualSlices(u21, &.{ 'a', 'b', 'c' }, &out);
}

test "shapeUtf8: ASCII unchanged, Arabic joined to presentation forms" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", shapeUtf8("hello", &buf)); // fast path, no copy
    // "بم" (BEH+MEEM) → initial BEH (FE91) + final MEEM (FEE2).
    const got = shapeUtf8("\u{0628}\u{0645}", &buf);
    try testing.expectEqualStrings("\u{FE91}\u{FEE2}", got);
}
