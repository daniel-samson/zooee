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

const Element = layout.Element;
const Color = style.Color;

/// Semantic style intent (#265): widgets carry a role, the theme resolves it to
/// concrete styling per platform. Provisional palette here until #21.
pub const Role = enum { normal, primary, secondary, danger };

/// A semantic widget. Host variants lower directly to `Element`; `composite`
/// expands to more widgets first.
pub const Widget = union(enum) {
    box: Box,
    text: Text,
    button: Button,
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

/// Text leaf (host).
pub const Text = struct {
    text: []const u8 = "", // filled by the `text` builder from its `str` arg
    role: Role = .normal,
    size: f32 = 15,
    bold: bool = false,
};

/// Button (host). `on_click` is an app message id (MVU). Look is provisional
/// until the theme system (#21); interaction state (hover/press) arrives with #5.
pub const Button = struct {
    label: []const u8,
    role: Role = .normal,
    on_click: ?u32 = null,
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
                .text_style = .{ .size = t.size * s, .bold = t.bold, .color = roleTextColor(t.role) },
            },
            .button => |bt| el.* = .{
                .text = bt.label,
                .on_click = bt.on_click,
                .cursor = .pointer,
                .padding = .symmetric(12 * s, 6 * s),
                .text_style = .{ .size = 15 * s, .color = Color.white },
                // Provisional fill — replaced by the per-OS theme (#21).
                .rect_style = .{ .background = roleFill(bt.role), .corner_radius = .all(6 * s) },
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

test "fmt allocates a frame-owned label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    try testing.expectEqualStrings("n=42", ui.fmt("n={d}", .{42}));
}
