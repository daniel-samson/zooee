//! Widget layer (#4, architecture #265): the developer-facing **semantic widget
//! tree**. Widgets are value structs with defaults; they **lower** to the
//! layout `Element` tree (the native adapter), so the existing layout + render +
//! backends realize them. The same tree will drive a DOM adapter on web.
//!
//! Two kinds (#265):
//! - **host** widgets (`box`, `text`, `button`, …) — the small fixed set an
//!   adapter knows how to realize.
//! - **composite** widgets — user/library structs with a `view(ui) !Widget`
//!   method that only *compose* other widgets; portable for free.
//!
//! v1 scope: the runtime + lowering for box/text/button + composites. Theming
//! (#21), framework-resolved interaction state (#5), and more host widgets
//! (#269–#277) build on this. Button styling here is **provisional** — the
//! theme system replaces it.

const std = @import("std");
const layout = @import("layout.zig");
const style = @import("style.zig");
const geometry = @import("geometry.zig");

const Element = layout.Element;
const Color = style.Color;

/// Semantic style intent (#265): widgets carry a role, the theme resolves it to
/// concrete styling per platform. Provisional palette here until #21.
pub const Role = enum { normal, primary, secondary, danger };

/// Provisional separator color (replaced by a theme token in #21).
const divider_color = Color.rgb(60, 60, 66);

/// A semantic widget. Host variants lower directly to `Element`; `composite`
/// expands to more widgets first.
pub const Widget = union(enum) {
    box: Box,
    text: Text,
    button: Button,
    icon: Icon,
    list: List,
    scroll: ScrollView,
    composite: Composite,
};

/// Layout container (host). Maps to a flex `Element`.
pub const Box = struct {
    direction: layout.Direction = .column,
    gap: f32 = 0,
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    grow: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    background: ?Color = null,
    corner_radius: f32 = 0,
    children: []const Widget = &.{},
};

/// Semantic text role in the type scale (#270). Picks a default size + weight;
/// `Text.size`/`Text.bold` override per instance. Concrete values are
/// provisional until the theme system (#21).
pub const TextVariant = enum { title, heading, body, caption };

/// Text leaf (host).
pub const Text = struct {
    text: []const u8 = "", // filled by the `text` builder from its `str` arg
    role: Role = .normal,
    variant: TextVariant = .body,
    /// Override the variant's default size / weight. Null = use the variant.
    size: ?f32 = null,
    bold: ?bool = null,
    /// Wrap to the content width instead of a single truncated line (#192).
    wrap: bool = false,
};

fn variantSize(v: TextVariant) f32 {
    return switch (v) {
        .title => 28,
        .heading => 20,
        .body => 15,
        .caption => 13,
    };
}
fn variantBold(v: TextVariant) bool {
    return switch (v) {
        .title, .heading => true,
        .body, .caption => false,
    };
}

/// Button (host). `on_click` is an app message id (MVU). Look is provisional
/// until the theme system (#21); interaction state (hover/press) arrives with #5.
pub const ButtonSize = enum { small, medium, large };

pub const Button = struct {
    label: []const u8,
    role: Role = .normal,
    size: ButtonSize = .medium,
    /// Disabled buttons are dimmed and dispatch nothing (interaction state
    /// hover/press/focus arrives with the framework's InteractionState, #5).
    disabled: bool = false,
    on_click: ?u32 = null,
};

fn buttonPad(sz: ButtonSize) struct { x: f32, y: f32 } {
    return switch (sz) {
        .small => .{ .x = 8, .y = 4 },
        .medium => .{ .x = 12, .y = 6 },
        .large => .{ .x = 18, .y = 10 },
    };
}
fn buttonTextSize(sz: ButtonSize) f32 {
    return switch (sz) {
        .small => 13,
        .medium => 15,
        .large => 18,
    };
}

/// Vector icon (host, #272). Lowers to an Element with a filled polygon path
/// (reusing the path renderer, #120) sized to a `size`×`size` box. The starter
/// set is normalized to a 0..1 unit square. Tint follows `role`/`disabled`.
pub const IconName = enum { plus, check, play, chevron_right };

pub const Icon = struct {
    name: IconName,
    size: f32 = 16,
    role: Role = .normal,
    disabled: bool = false,
};

/// Normalized (0..1, y-down) closed polygon for each icon in the starter set.
fn iconPath(name: IconName) []const geometry.Point {
    const P = geometry.Point;
    return switch (name) {
        .plus => &.{
            .{ .x = 0.4, .y = 0 }, .{ .x = 0.6, .y = 0 }, .{ .x = 0.6, .y = 0.4 },
            .{ .x = 1, .y = 0.4 }, .{ .x = 1, .y = 0.6 }, .{ .x = 0.6, .y = 0.6 },
            .{ .x = 0.6, .y = 1 }, .{ .x = 0.4, .y = 1 }, .{ .x = 0.4, .y = 0.6 },
            .{ .x = 0, .y = 0.6 }, .{ .x = 0, .y = 0.4 }, .{ .x = 0.4, .y = 0.4 },
        },
        .check => &.{
            .{ .x = 0.4, .y = 0.78 }, .{ .x = 0.05, .y = 0.45 }, .{ .x = 0.18, .y = 0.32 },
            .{ .x = 0.4, .y = 0.52 }, .{ .x = 0.82, .y = 0.12 }, .{ .x = 0.95, .y = 0.25 },
        },
        .play => &.{ P{ .x = 0.2, .y = 0.1 }, P{ .x = 0.85, .y = 0.5 }, P{ .x = 0.2, .y = 0.9 } },
        .chevron_right => &.{
            .{ .x = 0.3, .y = 0.12 },  .{ .x = 0.48, .y = 0.12 }, .{ .x = 0.82, .y = 0.5 },
            .{ .x = 0.48, .y = 0.88 }, .{ .x = 0.3, .y = 0.88 },  .{ .x = 0.6, .y = 0.5 },
        },
    };
}

/// Selectable list (host, #273): a vertical stack of clickable rows with a
/// highlighted selection. Row click dispatches `on_click`. Virtualization (#29)
/// and keyboard navigation (#16) are follow-ups; row styling is provisional (#21).
pub const ListRow = struct {
    label: []const u8,
    on_click: ?u32 = null,
};

pub const List = struct {
    rows: []const ListRow = &.{},
    selected: ?usize = null,
    width: ?f32 = null,
};

/// Provisional selected-row highlight (replaced by a theme token in #21).
const list_selected_bg = Color.rgb(60, 120, 240);

/// Scroll viewport (host, #274): a fixed-size box that clips its content and
/// pans it by `(scroll_x, scroll_y)` — the offsets are content-clamped by the
/// layout engine (#96). Bind the offsets to model state and update them from
/// scroll events (the loop routes wheel/trackpad to `onEvent`). Scrollbar
/// visuals are a follow-up (#21 theme).
pub const ScrollView = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    direction: layout.Direction = .column,
    gap: f32 = 0,
    padding: layout.EdgeInsets = .{},
    background: ?Color = null,
    children: []const Widget = &.{},
};

/// A composite widget: an arena-stored value + a generated expander that calls
/// its `view(ui) !Widget`. Created via `Ui.widget`.
pub const Composite = struct {
    ctx: *const anyopaque,
    expand: *const fn (ctx: *const anyopaque, ui: *Ui) anyerror!Widget,
};

/// Per-frame UI context: the build arena (later also the keyed state table,
/// theme, and platform — #5/#21). Threaded into `view` and the builders.
pub const Ui = struct {
    arena: std.mem.Allocator,
    /// Device-pixel scale (DPI). Widgets author in logical units; the value is
    /// available for sizing decisions. (Auto-scaling lowering is a follow-up.)
    scale: f32 = 1,

    pub fn init(arena: std.mem.Allocator) Ui {
        return .{ .arena = arena };
    }

    // --- builders -----------------------------------------------------------
    // Container builders copy `children` into the arena: the caller passes an
    // anonymous `&.{ … }` slice whose backing array would otherwise dangle once
    // the expression ends.

    pub fn column(self: *Ui, opts: Box, children: []const Widget) !Widget {
        var b = opts;
        b.direction = .column;
        b.children = try self.arena.dupe(Widget, children);
        return .{ .box = b };
    }

    pub fn row(self: *Ui, opts: Box, children: []const Widget) !Widget {
        var b = opts;
        b.direction = .row;
        b.children = try self.arena.dupe(Widget, children);
        return .{ .box = b };
    }

    pub fn text(self: *Ui, str: []const u8, opts: Text) Widget {
        _ = self;
        var t = opts;
        t.text = str;
        return .{ .text = t };
    }

    pub fn button(self: *Ui, opts: Button) Widget {
        _ = self;
        return .{ .button = opts };
    }

    /// Flexible empty space that pushes siblings apart (grow=1, no paint).
    pub fn spacer(self: *Ui) Widget {
        _ = self;
        return .{ .box = .{ .grow = 1 } };
    }

    /// A 1px separator line. Lays out across the parent's cross axis: full width
    /// in a column, full height in a row. Color is provisional until the theme (#21).
    pub fn divider(self: *Ui, direction: layout.Direction) Widget {
        _ = self;
        // A column stacks vertically → the divider is a horizontal rule (tall=1);
        // a row lays out horizontally → a vertical rule (wide=1).
        return switch (direction) {
            .column => .{ .box = .{ .height = 1, .background = divider_color } },
            .row => .{ .box = .{ .width = 1, .background = divider_color } },
        };
    }

    pub fn icon(self: *Ui, opts: Icon) Widget {
        _ = self;
        return .{ .icon = opts };
    }

    /// Selectable list. `rows` is copied into the arena (same dangling-slice
    /// reason as the container builders).
    pub fn list(self: *Ui, opts: List, rows: []const ListRow) !Widget {
        var l = opts;
        l.rows = try self.arena.dupe(ListRow, rows);
        return .{ .list = l };
    }

    /// Scroll viewport. `children` is copied into the arena (like the containers).
    pub fn scroll(self: *Ui, opts: ScrollView, children: []const Widget) !Widget {
        var sv = opts;
        sv.children = try self.arena.dupe(Widget, children);
        return .{ .scroll = sv };
    }

    /// Format text into the arena (for dynamic labels) — caller-owned for the frame.
    pub fn fmt(self: *Ui, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, f, args) catch "";
    }

    /// Wrap a composite widget value (a struct with `pub fn view(self, ui) !Widget`).
    /// The value is copied into the arena so its `view` can be expanded later.
    pub fn widget(self: *Ui, value: anytype) !Widget {
        const T = @TypeOf(value);
        const stored = try self.arena.create(T);
        stored.* = value;
        const Gen = struct {
            fn expand(ctx: *const anyopaque, ui: *Ui) anyerror!Widget {
                const v: *const T = @ptrCast(@alignCast(ctx));
                return v.view(ui);
            }
        };
        return .{ .composite = .{ .ctx = stored, .expand = Gen.expand } };
    }

    // --- lowering -----------------------------------------------------------

    /// Lower a widget to an `Element` tree (expanding composites). Arena-owned;
    /// hand the result to `layout.layout`/`render`. Widgets author in **logical
    /// units**; lowering multiplies sizes by `scale` so the device-pixel layout
    /// renders at the right physical size on HiDPI.
    pub fn lower(self: *Ui, w: Widget) !*const Element {
        const s = self.scale;
        const el = try self.arena.create(Element);
        switch (w) {
            .box => |b| {
                const kids = try self.arena.alloc(*const Element, b.children.len);
                for (b.children, 0..) |c, i| kids[i] = try self.lower(c);
                el.* = .{
                    .direction = b.direction,
                    .gap = b.gap * s,
                    .padding = scaleInsets(b.padding, s),
                    .margin = scaleInsets(b.margin, s),
                    .grow = b.grow,
                    .width = if (b.width) |x| x * s else null,
                    .height = if (b.height) |x| x * s else null,
                    .children = kids,
                    .rect_style = .{
                        .background = b.background,
                        .corner_radius = if (b.corner_radius > 0) .all(b.corner_radius * s) else .none,
                    },
                };
            },
            .text => |t| el.* = .{
                .text = t.text,
                .text_wrap = if (t.wrap) .wrap else .nowrap,
                .text_style = .{
                    .size = (t.size orelse variantSize(t.variant)) * s,
                    .bold = t.bold orelse variantBold(t.variant),
                    .color = roleTextColor(t.role),
                },
            },
            .button => |bt| {
                const pad = buttonPad(bt.size);
                el.* = .{
                    .text = bt.label,
                    // Disabled: dispatch nothing, no pointer affordance.
                    .on_click = if (bt.disabled) null else bt.on_click,
                    .cursor = if (bt.disabled) null else .pointer,
                    .padding = .symmetric(pad.x * s, pad.y * s),
                    .text_style = .{
                        .size = buttonTextSize(bt.size) * s,
                        .color = if (bt.disabled) Color.rgb(170, 170, 175) else Color.white,
                    },
                    // Provisional fill — replaced by the per-OS theme (#21).
                    .rect_style = .{
                        .background = if (bt.disabled) Color.rgb(70, 70, 76) else roleFill(bt.role),
                        .corner_radius = .all(6 * s),
                    },
                };
            },
            .icon => |ic| {
                const px = ic.size * s;
                const unit = iconPath(ic.name);
                const pts = try self.arena.alloc(geometry.Point, unit.len);
                for (unit, 0..) |p, i| pts[i] = .{ .x = p.x * px, .y = p.y * px };
                el.* = .{
                    .width = px,
                    .height = px,
                    .path = pts,
                    .path_color = if (ic.disabled) Color.rgb(170, 170, 175) else iconTint(ic.role),
                };
            },
            .list => |l| {
                const rows = try self.arena.alloc(*const Element, l.rows.len);
                for (l.rows, 0..) |r, i| {
                    const row_el = try self.arena.create(Element);
                    const sel = l.selected != null and l.selected.? == i;
                    row_el.* = .{
                        .text = r.label,
                        .on_click = r.on_click,
                        .cursor = if (r.on_click != null) .pointer else null,
                        .padding = .symmetric(10 * s, 7 * s),
                        .text_style = .{ .size = 15 * s, .color = if (sel) Color.white else null },
                        .rect_style = .{
                            .background = if (sel) list_selected_bg else null,
                            .corner_radius = .all(5 * s),
                        },
                    };
                    rows[i] = row_el;
                }
                el.* = .{
                    .direction = .column,
                    .gap = 2 * s,
                    .width = if (l.width) |lw| lw * s else null,
                    .children = rows,
                };
            },
            .scroll => |sv| {
                const kids = try self.arena.alloc(*const Element, sv.children.len);
                for (sv.children, 0..) |c, i| kids[i] = try self.lower(c);
                el.* = .{
                    .direction = sv.direction,
                    .gap = sv.gap * s,
                    .padding = scaleInsets(sv.padding, s),
                    .width = if (sv.width) |x| x * s else null,
                    .height = if (sv.height) |x| x * s else null,
                    .scroll = true,
                    .scroll_x = sv.scroll_x * s,
                    .scroll_y = sv.scroll_y * s,
                    .children = kids,
                    .rect_style = .{ .background = sv.background },
                };
            },
            .composite => |c| return self.lower(try c.expand(c.ctx, self)),
        }
        return el;
    }
};

fn scaleInsets(e: layout.EdgeInsets, s: f32) layout.EdgeInsets {
    return .{ .top = e.top * s, .right = e.right * s, .bottom = e.bottom * s, .left = e.left * s };
}

// Provisional role palette (replaced by the theme system, #21).
fn roleFill(role: Role) Color {
    return switch (role) {
        .normal => Color.rgb(120, 120, 128),
        .primary => Color.rgb(60, 120, 240),
        .secondary => Color.rgb(120, 120, 128),
        .danger => Color.rgb(220, 70, 70),
    };
}
fn iconTint(role: Role) Color {
    return switch (role) {
        .normal => Color.rgb(220, 220, 225),
        .primary => Color.rgb(60, 120, 240),
        .secondary => Color.rgb(150, 150, 156),
        .danger => Color.rgb(220, 70, 70),
    };
}
fn roleTextColor(role: Role) ?Color {
    return switch (role) {
        .normal => null, // backend default
        else => null,
    };
}

// === Tests ==================================================================

const testing = std.testing;

test "lower: box → flex Element with lowered children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const tree = try ui.column(.{ .gap = 8 }, &.{
        ui.text("Title", .{ .size = 22, .bold = true }),
        ui.button(.{ .label = "Save", .role = .primary, .on_click = 1 }),
    });
    const el = try ui.lower(tree);

    try testing.expectEqual(layout.Direction.column, el.direction);
    try testing.expectEqual(@as(f32, 8), el.gap);
    try testing.expectEqual(@as(usize, 2), el.children.len);
    try testing.expectEqualStrings("Title", el.children[0].text.?);
    try testing.expect(el.children[0].text_style.bold);
    try testing.expectEqualStrings("Save", el.children[1].text.?);
    try testing.expectEqual(@as(?u32, 1), el.children[1].on_click);
    try testing.expectEqual(cursorPointer(), el.children[1].cursor.?);
}

fn cursorPointer() @import("cursor.zig").Cursor {
    return .pointer;
}

test "lower: composite expands via its view()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const Counter = struct {
        value: u32,
        pub fn view(self: *const @This(), u: *Ui) !Widget {
            return u.row(.{ .gap = 4 }, &.{
                u.button(.{ .label = "-", .on_click = 10 }),
                u.text(u.fmt("{d}", .{self.value}), .{}),
                u.button(.{ .label = "+", .on_click = 11 }),
            });
        }
    };

    const w = try ui.widget(Counter{ .value = 7 });
    const el = try ui.lower(w);

    try testing.expectEqual(layout.Direction.row, el.direction);
    try testing.expectEqual(@as(usize, 3), el.children.len);
    try testing.expectEqualStrings("7", el.children[1].text.?);
}

test "lower: spacer grows, divider is a 1px rule on the cross axis (#269)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const tree = try ui.row(.{}, &.{
        ui.text("left", .{}),
        ui.spacer(),
        ui.divider(.row),
        ui.text("right", .{}),
    });
    const el = try ui.lower(tree);

    // Spacer fills available space.
    try testing.expectEqual(@as(f32, 1), el.children[1].grow);
    // Vertical rule in a row: 1px wide, painted.
    try testing.expectEqual(@as(f32, 1), el.children[2].width.?);
    try testing.expect(el.children[2].rect_style.background != null);

    // Horizontal rule in a column: 1px tall.
    const hrule = try ui.lower(ui.divider(.column));
    try testing.expectEqual(@as(f32, 1), hrule.height.?);
}

test "lower: text variant picks size+weight; explicit fields override (#270)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    // Variant supplies defaults.
    const title = try ui.lower(ui.text("T", .{ .variant = .title }));
    try testing.expectEqual(@as(f32, 28), title.text_style.size);
    try testing.expect(title.text_style.bold);

    const caption = try ui.lower(ui.text("c", .{ .variant = .caption }));
    try testing.expectEqual(@as(f32, 13), caption.text_style.size);
    try testing.expect(!caption.text_style.bold);

    // Explicit size/bold override the variant; wrap maps to text_wrap.
    const custom = try ui.lower(ui.text("x", .{ .variant = .body, .size = 40, .bold = true, .wrap = true }));
    try testing.expectEqual(@as(f32, 40), custom.text_style.size);
    try testing.expect(custom.text_style.bold);
    try testing.expect(custom.text_wrap != .nowrap);
}

test "lower: button size scales padding/text; disabled drops click+cursor (#271)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const large = try ui.lower(ui.button(.{ .label = "Go", .size = .large, .on_click = 3 }));
    const small = try ui.lower(ui.button(.{ .label = "Go", .size = .small, .on_click = 3 }));
    try testing.expect(large.text_style.size > small.text_style.size);
    try testing.expect(large.padding.left > small.padding.left);
    try testing.expectEqual(@as(?u32, 3), large.on_click);

    const off = try ui.lower(ui.button(.{ .label = "Nope", .disabled = true, .on_click = 3 }));
    try testing.expectEqual(@as(?u32, null), off.on_click);
    try testing.expectEqual(@as(?@import("cursor.zig").Cursor, null), off.cursor);
}

test "lower: icon → sized filled path; disabled dims the tint (#272)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(ui.icon(.{ .name = .plus, .size = 24 }));
    try testing.expectEqual(@as(?f32, 24), el.width);
    try testing.expectEqual(@as(?f32, 24), el.height);
    try testing.expect(el.path != null);
    try testing.expectEqual(@as(usize, 12), el.path.?.len); // plus = 12-point cross
    // Points are scaled into the 24px box.
    try testing.expectEqual(@as(f32, 24), el.path.?[3].x);

    // Disabled tint differs from the enabled role tint.
    const on = try ui.lower(ui.icon(.{ .name = .check, .role = .primary }));
    const off = try ui.lower(ui.icon(.{ .name = .check, .role = .primary, .disabled = true }));
    try testing.expect(!std.meta.eql(on.path_color, off.path_color));
}

test "lower: list rows are clickable; selected row is highlighted (#273)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(try ui.list(.{ .selected = 1 }, &.{
        .{ .label = "Alpha", .on_click = 100 },
        .{ .label = "Beta", .on_click = 101 },
        .{ .label = "Gamma", .on_click = 102 },
    }));

    try testing.expectEqual(layout.Direction.column, el.direction);
    try testing.expectEqual(@as(usize, 3), el.children.len);
    try testing.expectEqualStrings("Alpha", el.children[0].text.?);
    try testing.expectEqual(@as(?u32, 102), el.children[2].on_click);
    try testing.expectEqual(cursorPointer(), el.children[0].cursor.?);
    // Only the selected row paints a background.
    try testing.expect(el.children[0].rect_style.background == null);
    try testing.expect(el.children[1].rect_style.background != null);
}

test "lower: scroll view is a clamped viewport with offset+children (#274)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(try ui.scroll(.{ .width = 200, .height = 150, .scroll_y = 40 }, &.{
        ui.text("a", .{}),
        ui.text("b", .{}),
    }));
    try testing.expect(el.scroll);
    try testing.expectEqual(@as(f32, 40), el.scroll_y);
    try testing.expectEqual(@as(?f32, 200), el.width);
    try testing.expectEqual(@as(?f32, 150), el.height);
    try testing.expectEqual(@as(usize, 2), el.children.len);
}

test "fmt allocates a frame-owned label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    try testing.expectEqualStrings("n=42", ui.fmt("n={d}", .{42}));
}
