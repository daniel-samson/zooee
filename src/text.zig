//! Text layout (#115): turn a string + a width + a style into positioned
//! lines, with caret hit-testing. Builds on the glyph metrics from #10 and
//! feeds the layout engine (#3), labels/paragraphs, and editable text (#16/#19).
//!
//! Measurement is abstracted behind `Measurer` (a `measure(slice) -> width`
//! callback) so this whole module is pure and unit-tested with a deterministic
//! fake metric; at runtime the raster/GPU backends supply `measureText`.
//!
//! This first pass covers wrapping (greedy word-break, with a hard break for
//! words longer than the line), explicit newlines, horizontal alignment,
//! line-height, and point↔caret hit-testing. Justify, ellipsis, and
//! underline/strikethrough geometry are follow-ups noted on #115.

const std = @import("std");
const geometry = @import("geometry.zig");

const Point = geometry.Point;
const Rect = geometry.Rect;

pub const Align = enum { left, center, right };

/// A width-measuring callback over a UTF-8 slice. `ctx` is the backend (or a
/// test fake); `measure_fn` returns the advance width of `text` at the caller's
/// font/size. Prefix widths must be additive enough for caret math — i.e.
/// measuring a prefix gives that prefix's left-to-caret distance.
pub const Measurer = struct {
    ctx: *const anyopaque,
    measure_fn: *const fn (ctx: *const anyopaque, text: []const u8) f32,

    pub fn measure(self: Measurer, text: []const u8) f32 {
        return self.measure_fn(self.ctx, text);
    }
};

pub const Options = struct {
    /// Wrap width in pixels. Lines are broken to fit; `null` disables wrapping
    /// (only explicit newlines split lines).
    max_width: ?f32 = null,
    @"align": Align = .left,
    /// Baseline-to-baseline distance. Also the height contributed per line.
    line_height: f32 = 16,
};

/// One laid-out line: a byte range into the source string plus its placement.
/// `x` already accounts for alignment; `y` is the line's top.
pub const Line = struct {
    start: usize,
    end: usize,
    x: f32,
    y: f32,
    width: f32,

    pub fn slice(self: Line, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// The result of a layout pass. Owns the `lines` slice.
pub const Layout = struct {
    lines: []Line,
    /// Width of the widest line.
    width: f32,
    /// Total height (line count × line_height).
    height: f32,
    line_height: f32,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
    }
};

/// Lay out `text` into positioned lines. The source string is borrowed; lines
/// reference byte ranges into it, so it must outlive the `Layout`.
pub fn layout(gpa: std.mem.Allocator, text: []const u8, m: Measurer, opts: Options) !Layout {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    errdefer lines.deinit(gpa);

    // First split on explicit newlines, then word-wrap each paragraph.
    var para_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (at_end or text[i] == '\n') {
            try wrapParagraph(gpa, text, para_start, i, m, opts, &lines);
            para_start = i + 1;
            if (at_end) break;
        }
    }

    // Assign y and alignment x now that the full set of lines is known.
    var max_w: f32 = 0;
    for (lines.items) |ln| max_w = @max(max_w, ln.width);
    const align_w = opts.max_width orelse max_w;
    for (lines.items, 0..) |*ln, idx| {
        ln.y = @as(f32, @floatFromInt(idx)) * opts.line_height;
        ln.x = switch (opts.@"align") {
            .left => 0,
            .center => @max(0, (align_w - ln.width) * 0.5),
            .right => @max(0, align_w - ln.width),
        };
    }

    const count = lines.items.len;
    return .{
        .lines = try lines.toOwnedSlice(gpa),
        .width = max_w,
        .height = @as(f32, @floatFromInt(count)) * opts.line_height,
        .line_height = opts.line_height,
    };
}

/// Greedy word-wrap one paragraph (text[start..end], no newlines) into `lines`.
fn wrapParagraph(
    gpa: std.mem.Allocator,
    text: []const u8,
    start: usize,
    end: usize,
    m: Measurer,
    opts: Options,
    lines: *std.ArrayListUnmanaged(Line),
) !void {
    if (start >= end) {
        // An empty paragraph (blank line) still occupies a line.
        try lines.append(gpa, .{ .start = start, .end = start, .x = 0, .y = 0, .width = 0 });
        return;
    }
    const max_w = opts.max_width;
    var line_start = start;
    // Scan word by word; a "word" is a run of non-space plus trailing spaces.
    var cursor = start;
    var last_break = start; // byte offset where the current line could break
    while (cursor < end) {
        // Advance over one word: spaces then non-spaces (so the break point sits
        // before the next word's leading run).
        var w = cursor;
        while (w < end and text[w] == ' ') w += 1;
        while (w < end and text[w] != ' ') w += 1;
        const candidate = text[line_start..w];
        const fits = max_w == null or m.measure(trimTrailingSpaces(candidate)) <= max_w.?;
        if (!fits and last_break > line_start) {
            // Commit the line up to the last good break, start a new one after
            // its trailing spaces.
            try appendLine(gpa, text, line_start, last_break, m, lines);
            line_start = skipSpaces(text, last_break, end);
            last_break = line_start;
            cursor = line_start;
            continue;
        }
        if (!fits and last_break == line_start) {
            // A single word longer than the line: hard-break it to fit.
            const broken = hardBreak(text, line_start, w, m, max_w.?);
            try appendLine(gpa, text, line_start, broken, m, lines);
            line_start = broken;
            last_break = broken;
            cursor = broken;
            continue;
        }
        last_break = w;
        cursor = w;
    }
    if (line_start < end) try appendLine(gpa, text, line_start, end, m, lines);
}

fn appendLine(gpa: std.mem.Allocator, text: []const u8, start: usize, end: usize, m: Measurer, lines: *std.ArrayListUnmanaged(Line)) !void {
    const trimmed_end = trimEnd(text, start, end);
    try lines.append(gpa, .{
        .start = start,
        .end = trimmed_end,
        .x = 0,
        .y = 0,
        .width = m.measure(text[start..trimmed_end]),
    });
}

/// Find the byte offset that splits an over-long word so the prefix fits
/// `max_w`. Always advances at least one codepoint to guarantee progress.
fn hardBreak(text: []const u8, start: usize, end: usize, m: Measurer, max_w: f32) usize {
    var last: usize = nextCodepoint(text, start, end);
    var probe = last;
    while (probe < end) {
        const next = nextCodepoint(text, probe, end);
        if (m.measure(text[start..next]) > max_w) break;
        last = next;
        probe = next;
    }
    return last;
}

fn nextCodepoint(text: []const u8, i: usize, end: usize) usize {
    if (i >= end) return end;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    return @min(i + len, end);
}

fn skipSpaces(text: []const u8, i: usize, end: usize) usize {
    var j = i;
    while (j < end and text[j] == ' ') j += 1;
    return j;
}

fn trimEnd(text: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start and text[e - 1] == ' ') e -= 1;
    return e;
}

fn trimTrailingSpaces(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0 and s[e - 1] == ' ') e -= 1;
    return s[0..e];
}

// === Hit-testing ============================================================

/// The top-left point of the caret at byte index `caret` (clamped into range).
/// Caret sits at the start of the line containing it, offset by the measured
/// prefix; a caret past a line's end pins to that line's right edge.
pub fn caretToPoint(self: Layout, source: []const u8, m: Measurer, caret: usize) Point {
    const c = @min(caret, source.len);
    for (self.lines) |ln| {
        if (c >= ln.start and c <= ln.end) {
            const prefix = m.measure(source[ln.start..c]);
            return .{ .x = ln.x + prefix, .y = ln.y };
        }
    }
    // Past the last line's end (e.g. caret in trailing trimmed spaces): pin to
    // the last line's end.
    if (self.lines.len > 0) {
        const ln = self.lines[self.lines.len - 1];
        return .{ .x = ln.x + ln.width, .y = ln.y };
    }
    return .{ .x = 0, .y = 0 };
}

/// The byte index nearest point `p`: the line is chosen by `y`, then the caret
/// boundary within that line whose x is closest to `p.x`.
pub fn pointToCaret(self: Layout, source: []const u8, m: Measurer, p: Point) usize {
    if (self.lines.len == 0) return 0;
    // Pick the line whose vertical band contains p.y (clamp to first/last).
    var line = self.lines[0];
    for (self.lines) |ln| {
        if (p.y >= ln.y) line = ln;
    }
    // Walk codepoint boundaries, picking the closest x.
    var best = line.start;
    var best_dx = @abs(p.x - line.x);
    var i = line.start;
    while (i <= line.end) {
        const x = line.x + m.measure(source[line.start..i]);
        const dx = @abs(p.x - x);
        if (dx < best_dx) {
            best_dx = dx;
            best = i;
        }
        if (i == line.end) break;
        i = nextCodepoint(source, i, line.end);
    }
    return best;
}

// === Tests ==================================================================

const testing = std.testing;

/// Deterministic fake metric: every ASCII byte is 10px wide. Lets the layout
/// math be asserted exactly without loading a font.
fn fixedMeasure(_: *const anyopaque, text: []const u8) f32 {
    return @as(f32, @floatFromInt(text.len)) * 10;
}
const fixed: Measurer = .{ .ctx = undefined, .measure_fn = fixedMeasure };

test "no wrap: single line, full width" {
    var l = try layout(testing.allocator, "hello", fixed, .{});
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), l.lines.len);
    try testing.expectApproxEqAbs(@as(f32, 50), l.width, 1e-3);
    try testing.expectEqualStrings("hello", l.lines[0].slice("hello"));
}

test "explicit newlines split lines" {
    const s = "ab\ncd\nef";
    var l = try layout(testing.allocator, s, fixed, .{ .line_height = 20 });
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), l.lines.len);
    try testing.expectEqualStrings("cd", l.lines[1].slice(s));
    try testing.expectApproxEqAbs(@as(f32, 20), l.lines[1].y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 60), l.height, 1e-3);
}

test "greedy word wrap to width" {
    const s = "the quick brown fox"; // words: 3,5,5,3 chars (+spaces)
    // Width 100px = 10 chars. "the quick" = 9 chars (90px) fits; +" brown" won't.
    var l = try layout(testing.allocator, s, fixed, .{ .max_width = 100 });
    defer l.deinit(testing.allocator);
    try testing.expectEqualStrings("the quick", l.lines[0].slice(s));
    try testing.expectEqualStrings("brown fox", l.lines[1].slice(s));
    try testing.expectEqual(@as(usize, 2), l.lines.len);
}

test "long word hard-breaks to fit" {
    const s = "supercalifragilistic"; // 20 chars, width 50 = 5 chars/line
    var l = try layout(testing.allocator, s, fixed, .{ .max_width = 50 });
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), l.lines.len);
    try testing.expectEqualStrings("super", l.lines[0].slice(s));
    try testing.expectEqualStrings("istic", l.lines[3].slice(s));
}

test "center and right alignment offset x" {
    const s = "ab"; // 20px wide
    var c = try layout(testing.allocator, s, fixed, .{ .max_width = 100, .@"align" = .center });
    defer c.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 40), c.lines[0].x, 1e-3); // (100-20)/2
    var r = try layout(testing.allocator, s, fixed, .{ .max_width = 100, .@"align" = .right });
    defer r.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 80), r.lines[0].x, 1e-3); // 100-20
}

test "caret↔point round-trips on a wrapped layout" {
    const s = "the quick brown fox";
    var l = try layout(testing.allocator, s, fixed, .{ .max_width = 100, .line_height = 20 });
    defer l.deinit(testing.allocator);
    // Caret at index 4 ('q') is on line 0 at x=40.
    const p = caretToPoint(l, s, fixed, 4);
    try testing.expectApproxEqAbs(@as(f32, 40), p.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), p.y, 1e-3);
    // A point at x=45,y=0 snaps to the nearest boundary (index 4 or 5 → 4 wins).
    const c = pointToCaret(l, s, fixed, .{ .x = 43, .y = 0 });
    try testing.expectEqual(@as(usize, 4), c);
    // A point on the second line maps into "brown fox".
    const c2 = pointToCaret(l, s, fixed, .{ .x = 0, .y = 20 });
    try testing.expectEqual(@as(usize, 10), c2); // start of "brown"
}

test "blank line is preserved" {
    const s = "a\n\nb";
    var l = try layout(testing.allocator, s, fixed, .{});
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), l.lines.len);
    try testing.expectEqual(@as(usize, 0), l.lines[1].end - l.lines[1].start);
}
