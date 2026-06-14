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
const text_mod = @import("text.zig");
const cursor_mod = @import("cursor.zig");
const bidi = @import("bidi.zig");

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
    /// CSS `text-wrap` mode (#192): how text wraps to the content-box width.
    /// `.nowrap` (default) = single line (only explicit newlines split);
    /// `.wrap`/`.balance`/`.pretty` wrap to the width. Honors `text_align`.
    text_wrap: text_mod.TextWrap = .nowrap,
    text_align: text_mod.Align = .left,

    // Filled path (#120): a closed polygon in the element's LOCAL coords
    // (relative to its border-box origin), filled with `path_color` (even-odd).
    path: ?[]const geometry.Point = null,
    path_color: style.Color = .black,
    // Stroked polyline (#120), local coords; round caps/joins.
    stroke: ?[]const geometry.Point = null,
    stroke_color: style.Color = .black,
    stroke_width: f32 = 1,
    stroke_closed: bool = false,

    // Image fill (#122): raw RGBA pixels (`image_w`×`image_h`) drawn into the
    // element's border-box with `image_fit`. The texture is created and freed
    // per frame in `renderNode` (which holds the backend); view() can't.
    image_rgba: ?[]const u8 = null,
    image_w: u32 = 0,
    image_h: u32 = 0,
    image_fit: Backend.ImageFit = .stretch,
    image_sampling: Backend.Sampling = .nearest,
    /// When set, the image is drawn 9-slice (#122) with these source-pixel
    /// border insets instead of `image_fit` — for resizable button/panel art.
    image_nine: ?Backend.NineSlice = null,

    // Effects (#117/#121): wrap this element's subtree when set.
    /// Group opacity 0..1: the subtree renders into an isolated layer
    /// composited back at this alpha (#121).
    opacity: ?f32 = null,
    /// Clip this element's subtree to a rounded rect with these per-corner
    /// radii (#117); the element's border-box is the clip rect.
    clip_radius: ?style.CornerRadius = null,
    /// Scroll viewport (#96): clip the subtree to this element's border-box and
    /// translate its children by `(-scroll_x, -scroll_y)`, so content taller or
    /// wider than the box pans within it. Children lay out at their natural
    /// positions; the offset just shifts what's visible.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// True if this element is a scroll viewport (enables the clip+translate
    /// even at offset 0, and marks it for hit-testing/wheel routing).
    scroll: bool = false,

    // Interaction messages (#4): dispatched by the app loop when the
    // pointer hits this element. Values are app-defined (enum ints).
    on_click: ?u32 = null,
    on_hover: ?u32 = null,
    /// Cursor shape (#123) shown while the pointer is over this element's
    /// border-box. null = inherit (the app resolves the topmost region that
    /// sets one, defaulting to `.default`). Set `.pointer` on clickables,
    /// `.text` over text inputs, `.ew_resize` on splitters, etc.
    cursor: ?cursor_mod.Cursor = null,
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
    if (el.path) |pts| {
        // Offset local path points by the element's border-box origin.
        var buf: [64]geometry.Point = undefined;
        const n = @min(pts.len, buf.len);
        for (0..n) |k| buf[k] = .{ .x = p.rect.x + pts[k].x, .y = p.rect.y + pts[k].y };
        b.fillPath(buf[0..n], el.path_color);
    }
    if (el.stroke) |pts| {
        var buf: [64]geometry.Point = undefined;
        const n = @min(pts.len, buf.len);
        for (0..n) |k| buf[k] = .{ .x = p.rect.x + pts[k].x, .y = p.rect.y + pts[k].y };
        b.strokePath(buf[0..n], el.stroke_width, el.stroke_color, el.stroke_closed);
    }
    if (el.image_rgba) |rgba| {
        if (b.createTexture(el.image_w, el.image_h, rgba)) |tex| {
            defer b.destroyTexture(tex);
            if (el.image_nine) |ins| {
                b.drawImageNine(p.rect, tex, @floatFromInt(el.image_w), @floatFromInt(el.image_h), ins);
            } else {
                b.drawImageFit(p.rect, tex, @floatFromInt(el.image_w), @floatFromInt(el.image_h), el.image_fit, el.image_sampling);
            }
        } else |_| {}
    }
    if (el.text) |t| {
        const inner = contentBox(el, p.rect);
        if (el.text_wrap != .nowrap or hasNewline(t)) {
            drawWrappedText(b, el, t, inner);
        } else {
            var vbuf: [2048]u8 = undefined;
            b.drawText(inner.origin(), bidi.reorderUtf8(t, &vbuf), el.text_style); // #203
        }
    }

    // Scroll viewport (#96): clip children to the content box and pan them by
    // the scroll offset. The element's own frame above is drawn unscrolled.
    const scrolling = el.scroll or el.scroll_x != 0 or el.scroll_y != 0;
    if (scrolling) {
        b.pushClip(contentBox(el, p.rect));
        b.pushTranslate(-el.scroll_x, -el.scroll_y);
    }
    for (el.children) |_| renderNode(b, placements, i);
    if (scrolling) {
        b.popTranslate();
        b.popClip();
    }

    if (clipped) b.popClip();
    if (layered) b.popLayer();
}

fn hasNewline(t: []const u8) bool {
    return std.mem.indexOfScalar(u8, t, '\n') != null;
}

/// Measurement bridge: a `text.Measurer` backed by `Backend.measureText` at a
/// fixed style, for the wrapping/alignment pass (#115).
const MeasureCtx = struct {
    b: Backend,
    style: style.TextStyle,
    fn measure(ctx: *const anyopaque, s: []const u8) f32 {
        const self: *const MeasureCtx = @ptrCast(@alignCast(ctx));
        return self.b.measureText(s, self.style).width;
    }
};

/// Measure wrapped/multiline text: the block width and total height for the
/// given content width (#115). `wrap_w` null = only explicit newlines split.
fn measureWrapped(b: Backend, el: *const Element, t: []const u8, wrap_w: ?f32) Size {
    var buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ctx: MeasureCtx = .{ .b = b, .style = el.text_style };
    const m: text_mod.Measurer = .{ .ctx = &ctx, .measure_fn = MeasureCtx.measure };
    const line_h = b.measureText("Ag", el.text_style).height;
    var lay = text_mod.layout(fba.allocator(), t, m, .{
        .max_width = wrap_w,
        .@"align" = el.text_align,
        .line_height = line_h,
        .wrap = el.text_wrap,
    }) catch return b.measureText(t, el.text_style);
    defer lay.deinit(fba.allocator());
    return .{ .width = lay.width, .height = lay.height };
}

/// Lay out `t` into wrapped/aligned lines within `inner` and draw each line.
/// Uses a stack buffer for the line list (no per-frame heap); very long
/// paragraphs beyond the buffer fall back to a single drawText.
fn drawWrappedText(b: Backend, el: *const Element, t: []const u8, inner: Rect) void {
    var buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var ctx: MeasureCtx = .{ .b = b, .style = el.text_style };
    const m: text_mod.Measurer = .{ .ctx = &ctx, .measure_fn = MeasureCtx.measure };
    const line_h = b.measureText("Ag", el.text_style).height;
    var lay = text_mod.layout(fba.allocator(), t, m, .{
        .max_width = if (el.text_wrap != .nowrap) inner.width else null,
        .@"align" = el.text_align,
        .line_height = line_h,
        .wrap = el.text_wrap,
    }) catch {
        var vbuf: [2048]u8 = undefined;
        b.drawText(inner.origin(), bidi.reorderUtf8(t, &vbuf), el.text_style);
        return;
    };
    defer lay.deinit(fba.allocator());
    var vbuf: [2048]u8 = undefined;
    for (lay.lines) |ln| {
        // BiDi (#203): reorder each line into visual order for display.
        const vis = bidi.reorderUtf8(ln.slice(t), &vbuf);
        b.drawText(.{ .x = inner.x + ln.x, .y = inner.y + ln.y }, vis, el.text_style);
    }
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
        if ((el.text_wrap != .nowrap and el.width != null) or hasNewline(t)) {
            // Wrapped/multiline text reserves the full block height so siblings
            // flow below it (#115).
            const wrap_w: ?f32 = if (el.text_wrap != .nowrap and el.width != null) el.width.? - chrome_w else null;
            content = measureWrapped(b, el, t, wrap_w);
        } else {
            content = b.measureText(t, el.text_style);
        }
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
