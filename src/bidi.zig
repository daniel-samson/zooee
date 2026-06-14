//! Unicode Bidirectional Algorithm (#203, UAX #9) — resolves embedding levels
//! for mixed left-to-right / right-to-left text and yields the visual reorder.
//!
//! v1 scope: the implicit path (no explicit LRE/RLE/PDF/isolate controls — rare
//! in app UI), no bracket pairing (rule N0). It correctly handles the common
//! case: an LTR or RTL paragraph with embedded RTL/LTR word runs and numbers
//! (Hebrew/Arabic + Latin + digits). The text layout (#115) calls `reorder` to
//! draw runs in visual order. Explicit controls + bracket pairs are follow-ups.

const std = @import("std");

/// Bidi character types (the subset the implicit algorithm needs).
pub const Class = enum(u8) {
    L, // left-to-right (Latin, most scripts)
    R, // right-to-left (Hebrew, …)
    AL, // right-to-left Arabic
    EN, // European number
    ES, // European separator (+ -)
    ET, // European terminator (% $ …)
    AN, // Arabic number
    CS, // common separator (, . : …)
    NSM, // nonspacing mark
    B, // paragraph separator
    S, // segment separator (tab)
    WS, // whitespace
    ON, // other neutral
    BN, // boundary neutral (controls)
};

fn inRange(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

/// Bidi class of a codepoint (range-table approximation, #203).
pub fn classify(cp: u21) Class {
    // Strong RTL: Hebrew + related.
    if (inRange(cp, 0x0590, 0x05FF) or inRange(cp, 0x07C0, 0x089F) or
        inRange(cp, 0xFB1D, 0xFB4F)) return .R;
    // Strong RTL Arabic.
    if (inRange(cp, 0x0600, 0x06FF) or inRange(cp, 0x0750, 0x077F) or
        inRange(cp, 0x08A0, 0x08FF) or inRange(cp, 0xFB50, 0xFDFF) or
        inRange(cp, 0xFE70, 0xFEFF)) return .AL;
    if (inRange(cp, 0x0030, 0x0039)) return .EN;
    if (inRange(cp, 0x0660, 0x0669) or inRange(cp, 0x06F0, 0x06F9)) return .AN;
    if (cp == '+' or cp == '-') return .ES;
    if (cp == '%' or cp == '$' or cp == '#' or cp == 0x00A3 or cp == 0x00A5 or cp == 0x20AC) return .ET;
    if (cp == ',' or cp == '.' or cp == ':' or cp == 0x00A0 or cp == '/') return .CS;
    if (inRange(cp, 0x0300, 0x036F) or inRange(cp, 0x064B, 0x065F) or cp == 0x0670 or
        inRange(cp, 0x06D6, 0x06DC) or inRange(cp, 0xFE20, 0xFE2F)) return .NSM;
    if (cp == '\n' or cp == 0x2029) return .B;
    if (cp == '\t') return .S;
    if (cp == ' ' or cp == 0x000C or inRange(cp, 0x2000, 0x200A)) return .WS;
    if (cp < 0x20 or inRange(cp, 0x200B, 0x200F) or inRange(cp, 0x202A, 0x202E) or
        inRange(cp, 0x2066, 0x2069)) return .BN;
    if (inRange(cp, 0x0021, 0x002F) or inRange(cp, 0x003A, 0x0040) or
        inRange(cp, 0x005B, 0x0060) or inRange(cp, 0x007B, 0x007E)) return .ON;
    return .L;
}

fn dirIsR(level: u8) bool {
    return level & 1 == 1;
}

/// Paragraph embedding level (rules P2/P3): the first strong type — L → 0,
/// R/AL → 1; default 0 when there's no strong character.
pub fn paragraphLevel(types: []const Class) u8 {
    for (types) |t| switch (t) {
        .L => return 0,
        .R, .AL => return 1,
        else => {},
    };
    return 0;
}

fn isNeutral(t: Class) bool {
    return t == .B or t == .S or t == .WS or t == .ON;
}

/// Resolve a per-character embedding level for each codepoint (implicit path).
/// `types` is scratch (len == cps.len), reused for the resolved classes;
/// `levels` (len == cps.len) receives the result. Returns the paragraph level.
pub fn resolve(cps: []const u21, types: []Class, levels: []u8) u8 {
    std.debug.assert(types.len == cps.len and levels.len == cps.len);
    const n = cps.len;
    for (cps, 0..) |cp, i| types[i] = classify(cp);
    const base = paragraphLevel(types);
    const sos: Class = if (dirIsR(base)) .R else .L;
    const eos: Class = sos;

    // --- W rules (weak types) ---
    // W1: NSM takes the type of the previous char (sos at the start).
    {
        var prev: Class = sos;
        for (0..n) |i| {
            if (types[i] == .NSM) types[i] = prev;
            prev = types[i];
        }
    }
    // W2: EN → AN when the last strong type is AL.
    {
        var strong: Class = sos;
        for (0..n) |i| {
            switch (types[i]) {
                .L, .R, .AL => strong = types[i],
                .EN => if (strong == .AL) {
                    types[i] = .AN;
                },
                else => {},
            }
        }
    }
    // W3: AL → R.
    for (0..n) |i| if (types[i] == .AL) {
        types[i] = .R;
    };
    // W4: a single ES between two EN → EN; a single CS between two numbers of
    // the same type → that type.
    {
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) {
            if (types[i] == .ES and types[i - 1] == .EN and types[i + 1] == .EN) types[i] = .EN;
            if (types[i] == .CS and types[i - 1] == types[i + 1] and (types[i - 1] == .EN or types[i - 1] == .AN)) types[i] = types[i - 1];
        }
    }
    // W5: a run of ET adjacent to EN → EN.
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (types[i] != .ET) continue;
            var j = i;
            while (j < n and types[j] == .ET) j += 1;
            const before_en = i > 0 and types[i - 1] == .EN;
            const after_en = j < n and types[j] == .EN;
            if (before_en or after_en) {
                for (i..j) |k| types[k] = .EN;
            }
            i = j - 1;
        }
    }
    // W6: remaining ES/ET/CS → ON.
    for (0..n) |i| if (types[i] == .ES or types[i] == .ET or types[i] == .CS) {
        types[i] = .ON;
    };
    // W7: EN → L when the last strong type is L.
    {
        var strong: Class = sos;
        for (0..n) |i| {
            switch (types[i]) {
                .L, .R => strong = types[i],
                .EN => if (strong == .L) {
                    types[i] = .L;
                },
                else => {},
            }
        }
    }

    // --- N rules (neutrals) — EN/AN count as R for the boundary test. ---
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!isNeutral(types[i])) continue;
            var j = i;
            while (j < n and isNeutral(types[j])) j += 1;
            const left: Class = if (i == 0) sos else types[i - 1];
            const right: Class = if (j == n) eos else types[j];
            const ld: Class = if (left == .EN or left == .AN) .R else left;
            const rd: Class = if (right == .EN or right == .AN) .R else right;
            // N1: same-direction boundaries → that direction; N2: else embedding.
            const resolved: Class = if (ld == rd and (ld == .L or ld == .R)) ld else (if (dirIsR(base)) Class.R else Class.L);
            for (i..j) |k| types[k] = resolved;
            i = j - 1;
        }
    }

    // --- I rules (implicit levels) ---
    for (0..n) |i| {
        levels[i] = if (!dirIsR(base)) switch (types[i]) { // even base
            .L => base,
            .R => base + 1,
            .EN, .AN => base + 2,
            else => base,
        } else switch (types[i]) { // odd base
            .R => base,
            .L, .EN, .AN => base + 1,
            else => base,
        };
    }
    return base;
}

/// L2: reorder logical indices into visual order given per-char levels. Fills
/// `order` (len == levels.len) with the logical index to draw at each visual
/// position, left to right.
pub fn reorder(levels: []const u8, order: []usize) void {
    std.debug.assert(order.len == levels.len);
    const n = levels.len;
    for (0..n) |i| order[i] = i;
    if (n == 0) return;

    var max_level: u8 = 0;
    var min_odd: u8 = 255;
    for (levels) |lvl| {
        if (lvl > max_level) max_level = lvl;
        if (lvl & 1 == 1 and lvl < min_odd) min_odd = lvl;
    }
    if (min_odd == 255) return; // all even → already in order

    var lvl = max_level;
    while (lvl >= min_odd) : (lvl -= 1) {
        var i: usize = 0;
        while (i < n) {
            if (levels[i] < lvl) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < n and levels[j] >= lvl) j += 1;
            // reverse order[i..j]
            var a = i;
            var b = j - 1;
            while (a < b) {
                const tmp = order[a];
                order[a] = order[b];
                order[b] = tmp;
                a += 1;
                b -= 1;
            }
            i = j;
        }
        if (lvl == 0) break;
    }
}

/// Reorder a UTF-8 line into visual (display) order using the implicit BiDi
/// algorithm, writing into `out` (should be >= text.len). Returns the visual
/// slice — or `text` unchanged when it's pure-ASCII / all left-to-right, or
/// doesn't fit the internal buffers. The text layout (#203) calls this per line.
pub fn reorderUtf8(text: []const u8, out: []u8) []const u8 {
    // Fast path: pure ASCII is entirely L → identity order, no work (keeps
    // Latin rendering byte-for-byte identical).
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
    var byte_len: [cap]u3 = undefined; // UTF-8 length of each codepoint
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= cap) return text; // too long → leave logical
        cps[n] = cp;
        byte_len[n] = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        n += 1;
    }
    var types: [cap]Class = undefined;
    var levels: [cap]u8 = undefined;
    var order: [cap]usize = undefined;
    const base = resolve(cps[0..n], types[0..n], levels[0..n]);
    if (base == 0 and isAllEven(levels[0..n])) return text; // no RTL → identity
    reorder(levels[0..n], order[0..n]);

    var w: usize = 0;
    for (order[0..n]) |idx| {
        const need = byte_len[idx];
        if (w + need > out.len) return text;
        w += std.unicode.utf8Encode(cps[idx], out[w..]) catch return text;
    }
    return out[0..w];
}

fn isAllEven(levels: []const u8) bool {
    for (levels) |l| if (l & 1 == 1) return false;
    return true;
}

// === Tests ==================================================================

const testing = std.testing;

fn utf8(comptime s: []const u8) []const u21 {
    comptime {
        var arr: [s.len]u21 = undefined;
        var n: usize = 0;
        var it = std.unicode.Utf8View.initComptime(s).iterator();
        while (it.nextCodepoint()) |cp| {
            arr[n] = cp;
            n += 1;
        }
        const final = arr;
        return final[0..n];
    }
}

fn run(comptime s: []const u8) struct { base: u8, order: [utf8(s).len]usize } {
    const cps = comptime utf8(s);
    var types: [cps.len]Class = undefined;
    var levels: [cps.len]u8 = undefined;
    var order: [cps.len]usize = undefined;
    const base = resolve(cps, &types, &levels);
    reorder(&levels, &order);
    return .{ .base = base, .order = order };
}

test "reorderUtf8: ASCII unchanged, RTL reversed for display" {
    var buf: [64]u8 = undefined;
    // Pure ASCII → returns the input unchanged (fast path).
    try testing.expectEqualStrings("hello", reorderUtf8("hello", &buf));
    // Hebrew reverses to visual order (logical א ב ג → visual ג ב א).
    try testing.expectEqualStrings("\u{05D2}\u{05D1}\u{05D0}", reorderUtf8("\u{05D0}\u{05D1}\u{05D2}", &buf));
    // Latin with an accented char (non-ASCII but LTR) stays in order.
    try testing.expectEqualStrings("café", reorderUtf8("café", &buf));
}

test "pure LTR stays in logical order" {
    const r = run("abc");
    try testing.expectEqual(@as(u8, 0), r.base);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &r.order);
}

test "pure Hebrew is a level-1 paragraph, reversed for display" {
    const r = run("אבג"); // 3 Hebrew letters
    try testing.expectEqual(@as(u8, 1), r.base);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, &r.order);
}

test "RTL run inside an LTR paragraph reverses only that run" {
    // "a" + space + 3 Hebrew letters → indices 0..4; the Hebrew run (2,3,4)
    // reverses to 4,3,2 while the Latin prefix stays.
    const r = run("a אבג");
    try testing.expectEqual(@as(u8, 0), r.base); // LTR base (first strong is 'a')
    try testing.expectEqualSlices(usize, &.{ 0, 1, 4, 3, 2 }, &r.order);
}

test "European numbers stay LTR inside an RTL paragraph" {
    // Hebrew letter, space, two digits. Base is RTL (1). The digits (EN→level
    // base+2 = 3) keep their internal order, but the whole line is mirrored.
    const r = run("א 12");
    try testing.expectEqual(@as(u8, 1), r.base);
    // logical: [א, sp, 1, 2] → visual: 1,2 then space then א reading R-to-L.
    try testing.expectEqualSlices(usize, &.{ 2, 3, 1, 0 }, &r.order);
}
