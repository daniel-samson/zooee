//! Layout engine (#3): CSS-like box model + flex containers.
//!
//! Design record (issue #3):
//! - Margin → border → padding → content, resolved here; backends only
//!   ever see the resolved border-box (margin/padding never reach them).
//! - Per-side margin/padding (Daniel's requirement), with shorthands.
//! - **Snap-during-layout**: every committed edge goes through
//!   `Backend.snap`, and flex remainders are distributed deliberately
//!   (leftover goes to the last flexible child) so independently-rounded
//!   children still tile the parent exactly — no rounding seams.
//! - Text measurement is a backend query (`measureText`); cells and
//!   pixels differ in kind.
//!
//! v1 scope: fixed and content-sized boxes, flex row/column with grow,
//! gap, per-side box model, text leaves. Wrapping, min/max constraints,
//! and virtualization (#29) are follow-ups.

const std = @import("std");
const geometry = @import("geometry.zig");
const style = @import("style.zig");
const backend_mod = @import("backend.zig");

const Backend = backend_mod.Backend;
const Rect = geometry.Rect;
const Size = geometry.Size;

/// Per-side lengths, CSS-style.
pub const EdgeInsets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub const zero: EdgeInsets = .{};

    pub fn all(v: f32) EdgeInsets {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) EdgeInsets {
        return .{ .top = vertical, .bottom = vertical, .left = horizontal, .right = horizontal };
    }

    pub fn horizontalSum(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    pub fn verticalSum(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

pub const Direction = enum { row, column };

/// A layout element. This is the layout engine's input tree; the widget
/// API (#4) will build these. Lifetime: caller-owned, layout never
/// mutates the element tree.
pub const Element = struct {
    // Box model.
    margin: EdgeInsets = .zero,
    padding: EdgeInsets = .zero,
    // Paint (border widths also participate in layout).
    rect_style: style.RectStyle = .{},
    // Sizing: null = derive from content.
    width: ?f32 = null,
    height: ?f32 = null,
    /// Flex grow factor along the parent's main axis (0 = content-sized).
    grow: f32 = 0,

    // Content: either children in a flex container, or a text leaf.
    direction: Direction = .column,
    gap: f32 = 0,
    children: []const *const Element = &.{},
    text: ?[]const u8 = null,
    text_style: style.TextStyle = .{},

    // Effects (#117/#121): wrap this element's subtree when set.
    /// Group opacity 0..1: the subtree renders into an isolated layer
    /// composited back at this alpha (#121).
    opacity: ?f32 = null,
    /// Clip this element's subtree to a rounded rect with these per-corner
    /// radii (#117); the element's border-box is the clip rect.
    clip_radius: ?style.CornerRadius = null,

    // Interaction messages (#4): dispatched by the app loop when the
    // pointer hits this element. Values are app-defined (enum ints).
    on_click: ?u32 = null,
    on_hover: ?u32 = null,
};

/// One positioned element, output of layout.
pub const Placement = struct {
    element: *const Element,
    /// Border-box rect, snapped to the backend grid.
    rect: Rect,
};

pub const LayoutResult = struct {
    placements: []Placement,

    pub fn deinit(self: *LayoutResult, gpa: std.mem.Allocator) void {
        gpa.free(self.placements);
    }
};

/// Lay out `root` filling `viewport`, then optionally draw via `render`.
pub fn layout(
    gpa: std.mem.Allocator,
    b: Backend,
    root: *const Element,
    viewport: Size,
) !LayoutResult {
    var placements: std.ArrayList(Placement) = .empty;
    errdefer placements.deinit(gpa);

    const outer: Rect = .{ .x = 0, .y = 0, .width = viewport.width, .height = viewport.height };
    try place(gpa, b, root, outer, &placements);
    return .{ .placements = try placements.toOwnedSlice(gpa) };
}

/// Draw a layout result through the backend, in tree order (the ordered
/// command stream from #2). Placements are pre-order DFS (see `place`), so we
/// recurse the tree consuming them sequentially — that lets per-element
/// effects (opacity #121, rounded clip #117) wrap a whole subtree with
/// balanced push/pop.
pub fn render(b: Backend, result: LayoutResult) void {
    var i: usize = 0;
    if (result.placements.len > 0) renderNode(b, result.placements, &i);
}

fn renderNode(b: Backend, placements: []const Placement, i: *usize) void {
    const p = placements[i.*];
    i.* += 1;
    const el = p.element;

    const layered = el.opacity != null;
    const clipped = el.clip_radius != null;
    if (layered) b.pushLayer(el.opacity.?) catch {};
    if (clipped) b.pushClipRounded(p.rect, el.clip_radius.?);

    const rs = el.rect_style;
    if (rs.background != null or rs.gradient != null or rs.shadow != null or !rs.border.isNone()) {
        b.drawRect(p.rect, rs);
    }
    if (el.text) |t| {
        const inner = contentBox(el, p.rect);
        b.drawText(inner.origin(), t, el.text_style);
    }
    for (el.children) |_| renderNode(b, placements, i);

    if (clipped) b.popClip();
    if (layered) b.popLayer();
}

/// The content box: border-box minus border widths and padding.
fn contentBox(el: *const Element, border_box: Rect) Rect {
    const bw = el.rect_style.border;
    return .{
        .x = border_box.x + bw.left.width + el.padding.left,
        .y = border_box.y + bw.top.width + el.padding.top,
        .width = @max(0, border_box.width - bw.left.width - bw.right.width - el.padding.horizontalSum()),
        .height = @max(0, border_box.height - bw.top.width - bw.bottom.width - el.padding.verticalSum()),
    };
}

/// Measure pass: the element's preferred border-box size (margin excluded).
fn measure(b: Backend, el: *const Element) Size {
    const bw = el.rect_style.border;
    const chrome_w = bw.left.width + bw.right.width + el.padding.horizontalSum();
    const chrome_h = bw.top.width + bw.bottom.width + el.padding.verticalSum();

    var content: Size = .{};
    if (el.text) |t| {
        content = b.measureText(t, el.text_style);
    } else if (el.children.len > 0) {
        var main: f32 = 0;
        var cross: f32 = 0;
        for (el.children, 0..) |child, i| {
            const cs = measure(b, child);
            const child_main = mainOf(el.direction, cs) + marginMain(el.direction, child.margin);
            const child_cross = crossOf(el.direction, cs) + marginCross(el.direction, child.margin);
            main += child_main;
            if (i != 0) main += el.gap;
            cross = @max(cross, child_cross);
        }
        content = sizeFrom(el.direction, main, cross);
    }

    return .{
        .width = el.width orelse (content.width + chrome_w),
        .height = el.height orelse (content.height + chrome_h),
    };
}

/// Place pass: position `el`'s border-box inside `slot` (already
/// margin-adjusted by the parent), snap it, recurse into children.
fn place(
    gpa: std.mem.Allocator,
    b: Backend,
    el: *const Element,
    slot: Rect,
    out: *std.ArrayList(Placement),
) !void {
    // Snap the border-box.
    const x0 = b.snap(slot.x, .horizontal);
    const y0 = b.snap(slot.y, .vertical);
    const x1 = b.snap(slot.x + slot.width, .horizontal);
    const y1 = b.snap(slot.y + slot.height, .vertical);
    const box: Rect = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };

    try out.append(gpa, .{ .element = el, .rect = box });
    if (el.children.len == 0) return;

    const inner = contentBox(el, box);
    const dir = el.direction;

    // How much main-axis space do fixed children + gaps need; sum grows.
    var fixed_main: f32 = 0;
    var grow_sum: f32 = 0;
    for (el.children, 0..) |child, i| {
        if (i != 0) fixed_main += el.gap;
        fixed_main += marginMain(dir, child.margin);
        if (child.grow > 0) {
            grow_sum += child.grow;
        } else {
            fixed_main += mainOf(dir, measure(b, child));
        }
    }
    const free_main = @max(0, mainOf(dir, inner.size()) - fixed_main);

    // Walk children, snapping each edge as we commit it. The last
    // flexible child absorbs the rounding remainder: its end edge is the
    // container's end edge, not an accumulated sum.
    var cursor: f32 = mainStart(dir, inner);
    var last_grow_index: ?usize = null;
    for (el.children, 0..) |child, i| {
        if (child.grow > 0) last_grow_index = i;
    }

    for (el.children, 0..) |child, i| {
        if (i != 0) cursor += el.gap;
        cursor += marginMainStart(dir, child.margin);

        const child_size = measure(b, child);
        var child_main = mainOf(dir, child_size);
        if (child.grow > 0) {
            child_main = free_main * (child.grow / grow_sum);
            if (last_grow_index == i) {
                // Remainder absorption: end exactly at the container edge
                // minus whatever fixed content follows.
                var trailing: f32 = 0;
                for (el.children[i + 1 ..], i + 1..) |after, j| {
                    trailing += el.gap;
                    _ = j;
                    trailing += marginMain(dir, after.margin);
                    if (after.grow == 0) trailing += mainOf(dir, measure(b, after));
                }
                child_main = (mainStart(dir, inner) + mainOf(dir, inner.size())) - trailing - cursor - marginMainEnd(dir, child.margin);
            }
        }

        // Cross axis (v1): explicit size wins; text leaves keep their
        // measured size; containers stretch to fill (minus margins).
        const cross_start = crossStart(dir, inner) + marginCrossStart(dir, child.margin);
        const has_explicit_cross = if (dir == .row) child.height != null else child.width != null;
        const child_cross = if (has_explicit_cross or child.text != null)
            crossOf(dir, child_size)
        else
            crossOf(dir, inner.size()) - marginCross(dir, child.margin);

        const child_slot = rectFrom(dir, cursor, cross_start, child_main, child_cross);
        try place(gpa, b, child, child_slot, out);

        cursor += child_main + marginMainEnd(dir, child.margin);
    }
}

// --- axis helpers -----------------------------------------------------------

fn mainOf(dir: Direction, s: Size) f32 {
    return if (dir == .row) s.width else s.height;
}

fn crossOf(dir: Direction, s: Size) f32 {
    return if (dir == .row) s.height else s.width;
}

fn sizeFrom(dir: Direction, main: f32, cross: f32) Size {
    return if (dir == .row) .{ .width = main, .height = cross } else .{ .width = cross, .height = main };
}

fn rectFrom(dir: Direction, main_pos: f32, cross_pos: f32, main_len: f32, cross_len: f32) Rect {
    return if (dir == .row)
        .{ .x = main_pos, .y = cross_pos, .width = main_len, .height = cross_len }
    else
        .{ .x = cross_pos, .y = main_pos, .width = cross_len, .height = main_len };
}

fn mainStart(dir: Direction, r: Rect) f32 {
    return if (dir == .row) r.x else r.y;
}

fn crossStart(dir: Direction, r: Rect) f32 {
    return if (dir == .row) r.y else r.x;
}

fn marginMain(dir: Direction, m: EdgeInsets) f32 {
    return if (dir == .row) m.horizontalSum() else m.verticalSum();
}

fn marginCross(dir: Direction, m: EdgeInsets) f32 {
    return if (dir == .row) m.verticalSum() else m.horizontalSum();
}

fn marginMainStart(dir: Direction, m: EdgeInsets) f32 {
    return if (dir == .row) m.left else m.top;
}

fn marginMainEnd(dir: Direction, m: EdgeInsets) f32 {
    return if (dir == .row) m.right else m.bottom;
}

fn marginCrossStart(dir: Direction, m: EdgeInsets) f32 {
    return if (dir == .row) m.top else m.left;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const record = @import("backends/record.zig");

fn layoutWith(rec: *record.RecordBackend, root: *const Element, w: f32, h: f32) !LayoutResult {
    return layout(testing.allocator, rec.interface(), root, .{ .width = w, .height = h });
}

test "fixed-size children stack in a column with gap" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    const a: Element = .{ .width = 10, .height = 3 };
    const c: Element = .{ .width = 10, .height = 5 };
    const root: Element = .{ .direction = .column, .gap = 2, .children = &.{ &a, &c } };

    var res = try layoutWith(&rec, &root, 20, 20);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(f32, 0), res.placements[1].rect.y);
    try testing.expectEqual(@as(f32, 3), res.placements[1].rect.height);
    try testing.expectEqual(@as(f32, 5), res.placements[2].rect.y); // 3 + gap 2
    try testing.expectEqual(@as(f32, 5), res.placements[2].rect.height);
}

test "grow children tile the parent exactly (no rounding seams)" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    // Three equal grows in a 10-wide row: 3.33... each; snapped children
    // must still sum to exactly 10 with the last absorbing the remainder.
    const a: Element = .{ .grow = 1 };
    const c: Element = .{ .grow = 1 };
    const d: Element = .{ .grow = 1 };
    const root: Element = .{ .direction = .row, .children = &.{ &a, &c, &d } };

    var res = try layoutWith(&rec, &root, 10, 4);
    defer res.deinit(testing.allocator);

    const r1 = res.placements[1].rect;
    const r2 = res.placements[2].rect;
    const r3 = res.placements[3].rect;
    try testing.expectEqual(@as(f32, 0), r1.x);
    try testing.expectEqual(r1.x + r1.width, r2.x); // no gap, no overlap
    try testing.expectEqual(r2.x + r2.width, r3.x);
    try testing.expectEqual(@as(f32, 10), r3.x + r3.width); // exact tiling
}

test "padding and border shrink the content box" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    const child: Element = .{ .grow = 1 };
    const root: Element = .{
        .padding = .all(2),
        .rect_style = .{ .border = .all(1, .black) },
        .children = &.{&child},
    };

    var res = try layoutWith(&rec, &root, 20, 10);
    defer res.deinit(testing.allocator);

    const inner = res.placements[1].rect;
    try testing.expectEqual(@as(f32, 3), inner.x); // border 1 + padding 2
    try testing.expectEqual(@as(f32, 3), inner.y);
    try testing.expectEqual(@as(f32, 14), inner.width); // 20 - 2*3
    try testing.expectEqual(@as(f32, 4), inner.height); // 10 - 2*3
}

test "per-side margin offsets a child asymmetrically" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    const child: Element = .{ .width = 5, .height = 2, .margin = .{ .left = 4, .top = 1 } };
    const root: Element = .{ .direction = .column, .children = &.{&child} };

    var res = try layoutWith(&rec, &root, 20, 10);
    defer res.deinit(testing.allocator);

    const r = res.placements[1].rect;
    try testing.expectEqual(@as(f32, 4), r.x);
    try testing.expectEqual(@as(f32, 1), r.y);
}

test "text leaf sizes from backend measurement" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    // RecordBackend: 8 units/char, 16 line height.
    const label: Element = .{ .text = "hello" };
    const root: Element = .{ .direction = .row, .children = &.{&label} };

    var res = try layoutWith(&rec, &root, 100, 50);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(f32, 40), res.placements[1].rect.width); // 5*8
    try testing.expectEqual(@as(f32, 16), res.placements[1].rect.height);
}
