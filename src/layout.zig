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
const arabic = @import("arabic.zig");
const indic = @import("indic.zig");

/// Shape a line for display (#202/#203): Arabic contextual joining → Indic
/// pre-base matra reordering → BiDi visual reorder, all on the logical string.
/// `abuf`/`vbuf` are caller scratch (the forms are 3-byte UTF-8, so size
/// generously); every stage no-ops for plain LTR/ASCII text. The buffers are
/// ping-ponged: each stage fully decodes its input before writing its output,
/// so reusing `abuf` for the final stage's output is safe even when it aliases.
fn shapeForDisplay(t: []const u8, abuf: []u8, vbuf: []u8) []const u8 {
    const joined = arabic.shapeUtf8(t, abuf);
    const reordered = indic.reorderUtf8(joined, vbuf);
    return bidi.reorderUtf8(reordered, abuf);
}

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

/// Main-axis distribution of free space (CSS `justify-content`), applied only
/// when no child consumes the slack via `grow` (#268). `space_between` puts the
/// extra between items; the others shift the whole run.
pub const Justify = enum { start, center, end, space_between };

/// Cross-axis placement of each child (CSS `align-items`, #268). `stretch`
/// (default) fills the cross extent; the others size the child to its content
/// and place it at the start/center/end.
pub const AlignItems = enum { stretch, start, center, end };

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
    /// Main-axis free-space distribution (#268). Default `.start` (pack from the
    /// leading edge) — the historical behavior.
    justify: Justify = .start,
    /// Cross-axis child placement (#268). Default `.stretch` — the historical
    /// behavior (children fill the cross extent unless they set an explicit size).
    align_items: AlignItems = .stretch,
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
            var abuf: [3072]u8 = undefined;
            var vbuf: [3072]u8 = undefined;
            b.drawText(inner.origin(), shapeForDisplay(t, &abuf, &vbuf), el.text_style); // #202/#203
        }
    }

    // Scroll viewport (#96): clip children to the content box and pan them by
    // the scroll offset. The element's own frame above is drawn unscrolled.
    const scrolling = el.scroll or el.scroll_x != 0 or el.scroll_y != 0;
    if (scrolling) {
        const cbox = contentBox(el, p.rect);
        // Clamp the scroll offset to the content extent so the viewport can't
        // pan past its content into empty space (#96).
        const ext = contentExtent(b, el);
        const sx = std.math.clamp(el.scroll_x, 0, @max(0, ext.width - cbox.width));
        const sy = std.math.clamp(el.scroll_y, 0, @max(0, ext.height - cbox.height));
        b.pushClip(cbox);
        b.pushTranslate(-sx, -sy);
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
        var abuf: [3072]u8 = undefined;
        var vbuf: [3072]u8 = undefined;
        b.drawText(inner.origin(), shapeForDisplay(t, &abuf, &vbuf), el.text_style);
        return;
    };
    defer lay.deinit(fba.allocator());
    var abuf: [3072]u8 = undefined;
    var vbuf: [3072]u8 = undefined;
    for (lay.lines) |ln| {
        // Arabic joining + BiDi reorder per line for display (#202/#203).
        const vis = shapeForDisplay(ln.slice(t), &abuf, &vbuf);
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

/// Natural size of an element's children laid out in its direction, ignoring
/// the element's own fixed width/height. Used to clamp scroll offsets to the
/// content extent (#96), so a scroll viewport can't pan past its content into
/// empty space.
fn contentExtent(b: Backend, el: *const Element) Size {
    var main: f32 = 0;
    var cross: f32 = 0;
    for (el.children, 0..) |child, i| {
        const cs = measure(b, child);
        main += mainOf(el.direction, cs) + marginMain(el.direction, child.margin);
        if (i != 0) main += el.gap;
        cross = @max(cross, crossOf(el.direction, cs) + marginCross(el.direction, child.margin));
    }
    return sizeFrom(el.direction, main, cross);
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

    // justify-content (#268): with no grow child to absorb it, distribute the
    // free main-axis space — shift the run (center/end) or space items apart.
    var lead_extra: f32 = 0;
    var between_extra: f32 = 0;
    if (grow_sum == 0 and free_main > 0) switch (el.justify) {
        .start => {},
        .center => lead_extra = free_main / 2,
        .end => lead_extra = free_main,
        .space_between => if (el.children.len > 1) {
            between_extra = free_main / @as(f32, @floatFromInt(el.children.len - 1));
        },
    };

    // Walk children, snapping each edge as we commit it. The last
    // flexible child absorbs the rounding remainder: its end edge is the
    // container's end edge, not an accumulated sum.
    var cursor: f32 = mainStart(dir, inner) + lead_extra;
    var last_grow_index: ?usize = null;
    for (el.children, 0..) |child, i| {
        if (child.grow > 0) last_grow_index = i;
    }

    for (el.children, 0..) |child, i| {
        if (i != 0) cursor += el.gap + between_extra;
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

        // Cross axis: explicit size and text leaves keep their measured size;
        // otherwise `align_items` decides — stretch fills the cross extent
        // (default), while start/center/end size to content and place it (#268).
        const cross_start = crossStart(dir, inner) + marginCrossStart(dir, child.margin);
        const has_explicit_cross = if (dir == .row) child.height != null else child.width != null;
        const avail_cross = crossOf(dir, inner.size()) - marginCross(dir, child.margin);
        const stretch = el.align_items == .stretch and !has_explicit_cross and child.text == null;
        const child_cross = if (stretch) avail_cross else crossOf(dir, child_size);
        const align_off: f32 = switch (el.align_items) {
            .start, .stretch => 0,
            .center => (avail_cross - child_cross) / 2,
            .end => avail_cross - child_cross,
        };
        const child_slot = rectFrom(dir, cursor, cross_start + align_off, child_main, child_cross);
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
const raster = @import("backends/raster.zig");

fn layoutWith(rec: *record.RecordBackend, root: *const Element, w: f32, h: f32) !LayoutResult {
    return layout(testing.allocator, rec.interface(), root, .{ .width = w, .height = h });
}

test "scroll viewport clamps the offset to content, never panning into empty space (#96)" {
    var rb = raster.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    const b = rb.interface();

    // A 10px-tall scroll box holding three stacked 10px rows (30px content).
    const r0: Element = .{ .height = 10, .rect_style = .{ .background = style.Color.rgb(255, 0, 0) } };
    const r1: Element = .{ .height = 10, .rect_style = .{ .background = style.Color.rgb(0, 255, 0) } };
    const r2: Element = .{ .height = 10, .rect_style = .{ .background = style.Color.rgb(0, 0, 255) } };
    const content: Element = .{ .direction = .column, .children = &.{ &r0, &r1, &r2 } };
    // A wildly-too-large scroll offset must clamp to (30 − 10) = 20, showing the
    // last row — not pan past it into the cleared (white) background.
    const box: Element = .{ .width = 10, .height = 10, .scroll = true, .scroll_y = 1000, .children = &.{&content} };

    try b.beginFrame(.{ .width = 10, .height = 10 });
    var result = try layout(testing.allocator, b, &box, .{ .width = 10, .height = 10 });
    defer result.deinit(testing.allocator);
    render(b, result);
    try b.endFrame();

    // Clamped: the box shows the third (blue) row, not empty white.
    try testing.expectEqual(style.Color.rgb(0, 0, 255), rb.pixelAt(5, 5));
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

test "justify-content distributes free main-axis space (#268)" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();
    const a: Element = .{ .width = 4, .height = 4 };
    const c: Element = .{ .width = 4, .height = 4 };
    // 20 wide, two 4-wide items → 12 free.
    {
        const root: Element = .{ .direction = .row, .justify = .center, .children = &.{ &a, &c } };
        var res = try layoutWith(&rec, &root, 20, 10);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 6), res.placements[1].rect.x); // 12/2
        try testing.expectEqual(@as(f32, 10), res.placements[2].rect.x);
    }
    {
        const root: Element = .{ .direction = .row, .justify = .end, .children = &.{ &a, &c } };
        var res = try layoutWith(&rec, &root, 20, 10);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 12), res.placements[1].rect.x);
    }
    {
        const root: Element = .{ .direction = .row, .justify = .space_between, .children = &.{ &a, &c } };
        var res = try layoutWith(&rec, &root, 20, 10);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 0), res.placements[1].rect.x);
        try testing.expectEqual(@as(f32, 16), res.placements[2].rect.x); // 4 + 12 gap
    }
}

test "align-items places children on the cross axis (#268)" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();
    const a: Element = .{ .width = 4, .height = 4 }; // explicit cross (height)
    {
        const root: Element = .{ .direction = .row, .align_items = .center, .children = &.{&a} };
        var res = try layoutWith(&rec, &root, 20, 20);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 8), res.placements[1].rect.y); // (20-4)/2
        try testing.expectEqual(@as(f32, 4), res.placements[1].rect.height);
    }
    {
        const root: Element = .{ .direction = .row, .align_items = .end, .children = &.{&a} };
        var res = try layoutWith(&rec, &root, 20, 20);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 16), res.placements[1].rect.y); // 20-4
    }
    // Default stretch still fills the cross extent for a sizeless container child.
    {
        const child: Element = .{ .width = 4 };
        const root: Element = .{ .direction = .row, .align_items = .stretch, .children = &.{&child} };
        var res = try layoutWith(&rec, &root, 20, 20);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(f32, 0), res.placements[1].rect.y);
        try testing.expectEqual(@as(f32, 20), res.placements[1].rect.height);
    }
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

test "resize re-layouts, it doesn't scale (#99 stretch detection)" {
    var rec = record.RecordBackend.init(testing.allocator);
    defer rec.deinit();

    // A fixed-width sidebar + a growing pane in a row. On resize, reflow keeps
    // the fixed element constant and lets the grow pane absorb the delta — a
    // *scale* would multiply both by the width ratio. This is the regression
    // guard against stretching the stale frame (#170/#181/#182).
    const sidebar: Element = .{ .width = 100 };
    const pane: Element = .{ .grow = 1 };
    const root: Element = .{ .direction = .row, .children = &.{ &sidebar, &pane } };

    var narrow = try layoutWith(&rec, &root, 300, 200);
    defer narrow.deinit(testing.allocator);
    var wide = try layoutWith(&rec, &root, 600, 200);
    defer wide.deinit(testing.allocator);

    const sidebar_narrow = narrow.placements[1].rect; // [0]=root
    const sidebar_wide = wide.placements[1].rect;
    const pane_narrow = narrow.placements[2].rect;
    const pane_wide = wide.placements[2].rect;

    // Reflow: the fixed sidebar is identical at both widths (a scale would
    // double it to 200).
    try testing.expectEqual(@as(f32, 100), sidebar_narrow.width);
    try testing.expectEqual(@as(f32, 100), sidebar_wide.width);
    // The grow pane absorbs the entire +300 width delta (200 → 500).
    try testing.expectEqual(@as(f32, 200), pane_narrow.width);
    try testing.expectEqual(@as(f32, 500), pane_wide.width);
    // Height is unchanged by a horizontal resize (no vertical scaling).
    try testing.expectEqual(pane_narrow.height, pane_wide.height);
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
