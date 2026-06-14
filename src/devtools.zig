//! Developer tools (#26): you can't printf-debug a TUI — stdout *is* the UI.
//! These help inspect the retained tree and resolved layout, and draw a debug
//! overlay through the same primitive interface so it works on every backend.
//!
//! v1 scope: tree/layout text dumps (for bug reports + test debugging) and a
//! widget-bounds overlay. Deferred (same issue): the std.log debug console
//! over a socket, damage-region + draw-call counters, and build-flag gating so
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

// === Tests ==================================================================

const testing = std.testing;

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
