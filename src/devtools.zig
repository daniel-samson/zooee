//! Developer tools (#26): you can't printf-debug a TUI — stdout *is* the UI.
//! These help inspect the retained tree and resolved layout, and draw a debug
//! overlay through the same primitive interface so it works on every backend.
//!
//! Scope: tree/layout text dumps (for bug reports + test debugging), a
//! widget-bounds overlay, and a debug console — a std.log handler (`logFn`)
//! that echoes to stderr AND keeps the recent lines in an in-app ring
//! (`recentLogs`) the overlay can show. Deferred (same issue): a live socket
//! console, damage-region + draw-call counters, and build-flag gating so
//! release binaries pay zero size cost.

const std = @import("std");
const layout = @import("layout.zig");
const style = @import("style.zig");
const backend_mod = @import("backend.zig");

const Element = layout.Element;
const Placement = layout.Placement;
const Backend = backend_mod.Backend;

/// One-line summary of an element (no children) for a tree dump.
fn summarize(writer: anytype, el: *const Element) !void {
    if (el.text) |t| {
        try writer.print("text \"{s}\"", .{t});
    } else {
        try writer.print("box dir={s} children={d}", .{ @tagName(el.direction), el.children.len });
    }
    if (el.width) |w| try writer.print(" w={d}", .{w});
    if (el.height) |h| try writer.print(" h={d}", .{h});
}

/// Serialize the retained widget tree (indented) to `writer`. Pure — for bug
/// reports and test debugging.
pub fn dumpTree(writer: anytype, root: *const Element) !void {
    try dumpNode(writer, root, 0);
}

fn dumpNode(writer: anytype, el: *const Element, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
    try summarize(writer, el);
    try writer.writeByte('\n');
    for (el.children) |child| try dumpNode(writer, child, depth + 1);
}

/// Serialize the resolved layout (one border-box rect per placement) to
/// `writer`, in render order.
pub fn dumpLayout(writer: anytype, placements: []const Placement) !void {
    for (placements) |pl| {
        try writer.print("[{d},{d} {d}x{d}] ", .{ pl.rect.x, pl.rect.y, pl.rect.width, pl.rect.height });
        try summarize(writer, pl.element);
        try writer.writeByte('\n');
    }
}

/// Draw each placement's border-box as a 1px outline in `color`, over the
/// rendered frame — the "inspect widget bounds" overlay. Goes through the
/// normal draw-rect primitive, so it works on every backend (#26).
pub fn drawBounds(b: Backend, placements: []const Placement, color: style.Color) void {
    for (placements) |pl| {
        b.drawRect(pl.rect, .{ .border = style.Border.all(1, color) });
    }
}

// --- Debug console (#26): an in-app std.log ring buffer -----------------------
// `logFn` is a ready-to-use std.log handler — wire it via std_options to both
// echo logs to stderr (redirect to a second terminal: `2>console.log`) AND keep
// the last N lines in a ring the debug overlay can display in-app. Zero cost
// when not installed.

const ring_lines = 64;
const ring_line_len = 200;

var ring: [ring_lines][ring_line_len]u8 = undefined;
var ring_used: [ring_lines]usize = [_]usize{0} ** ring_lines;
var ring_head: usize = 0; // next slot to write
var ring_count: usize = 0; // total lines captured (saturates the ring)

/// A std.log handler (#26): formats `[level scope] msg` into the in-app ring
/// and echoes to stderr. Install with `std_options = .{ .logFn = ... }`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ " " ++ @tagName(scope) ++ "] ";
    std.debug.print(prefix ++ format ++ "\n", args); // echo to stderr
    const line = std.fmt.bufPrint(&ring[ring_head], prefix ++ format, args) catch blk: {
        // Message longer than a ring line → keep the truncated prefix.
        break :blk ring[ring_head][0..@min(ring_line_len, prefix.len)];
    };
    ring_used[ring_head] = line.len;
    ring_head = (ring_head + 1) % ring_lines;
    ring_count += 1;
}

/// Copy the recent log lines (oldest→newest) into `out` slices; returns the
/// count written (≤ out.len, ≤ ring capacity). For the debug overlay.
pub fn recentLogs(out: [][]const u8) usize {
    const n = @min(@min(ring_count, ring_lines), out.len);
    if (n == 0) return 0;
    // The oldest of the last `min(count,ring_lines)` lines.
    const total = @min(ring_count, ring_lines);
    const start = (ring_head + ring_lines - total) % ring_lines;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (start + (total - n) + i) % ring_lines;
        out[i] = ring[idx][0..ring_used[idx]];
    }
    return n;
}

// === Tests ==================================================================

const testing = std.testing;

test "console ring captures recent log lines (#26)" {
    ring_head = 0;
    ring_count = 0;
    logFn(.info, .demo, "hello {d}", .{7});
    logFn(.warn, .demo, "world", .{});
    var buf: [4][]const u8 = undefined;
    const n = recentLogs(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("[info demo] hello 7", buf[0]);
    try testing.expectEqualStrings("[warning demo] world", buf[1]);
}

test "console ring keeps only the most recent lines" {
    ring_head = 0;
    ring_count = 0;
    var k: usize = 0;
    while (k < ring_lines + 5) : (k += 1) logFn(.info, .demo, "n={d}", .{k});
    var buf: [ring_lines][]const u8 = undefined;
    const n = recentLogs(&buf);
    try testing.expectEqual(@as(usize, ring_lines), n); // saturated
    // Newest line is the last logged.
    try testing.expectEqualStrings("[info demo] n=68", buf[ring_lines - 1]); // 64+5-1
}

test "dumpTree indents the retained tree" {
    const leaf: Element = .{ .text = "hi", .width = 20 };
    const child_ptrs = [_]*const Element{&leaf};
    const root: Element = .{ .direction = .row, .children = &child_ptrs };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dumpTree(&aw.writer, &root);
    try testing.expectEqualStrings(
        "box dir=row children=1\n  text \"hi\" w=20\n",
        aw.written(),
    );
}

test "dumpLayout lists placement rects" {
    const el: Element = .{ .text = "x" };
    const placements = [_]Placement{
        .{ .element = &el, .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 } },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try dumpLayout(&aw.writer, &placements);
    try testing.expectEqualStrings("[1,2 3x4] text \"x\"\n", aw.written());
}
