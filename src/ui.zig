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
const theme_mod = @import("theme.zig");
const gen_icons = @import("generated_icons.zig");
const edit_state = @import("edit_state.zig");

const Element = layout.Element;
const Color = style.Color;
pub const Theme = theme_mod.Theme;
// Layout enums re-exported so apps can name them on Box/model fields (#303).
pub const Direction = layout.Direction;
pub const Justify = layout.Justify;
pub const AlignItems = layout.AlignItems;
pub const FlexWrap = layout.FlexWrap;
pub const Overflow = layout.Overflow;

/// Semantic style intent (#265): widgets carry a role, the theme resolves it to
/// concrete styling per platform. Provisional palette here until #21.
pub const Role = enum { normal, primary, secondary, danger };

/// A semantic widget. Host variants lower directly to `Element`; `composite`
/// expands to more widgets first.
pub const Widget = union(enum) {
    box: Box,
    text: Text,
    text_input: TextInput,
    button: Button,
    icon: Icon,
    icon_data: IconRaw,
    list: List,
    scroll: ScrollView,
    card: Card,
    split: Split,
    composite: Composite,
};

/// The shared box-model surface (#330). Every host widget that paints a box
/// carries these knobs so styling is uniform across the library — the way every
/// CSS element has margin/border/padding/background. Widgets either embed this
/// directly or declare the same fields flat (when they need per-widget defaults)
/// and feed them through `borderFrom` + `scaleInsets` at lowering time.
///
/// All values are authored in logical units and DPI-scaled when lowered. A null
/// `border_color` with a non-zero `border_width` falls back to the theme border.
pub const BoxStyle = struct {
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    border_color: ?Color = null,
};

/// Layout container (host). Maps to a flex `Element`.
pub const Box = struct {
    direction: layout.Direction = .column,
    gap: f32 = 0,
    /// Main-axis distribution (#268) and cross-axis placement of children.
    justify: layout.Justify = .start,
    align_items: layout.AlignItems = .stretch,
    /// Flow children onto new lines when they overflow the main axis (#308).
    wrap: layout.FlexWrap = .nowrap,
    /// Per-axis overflow handling (#309): visible spills, hidden clips,
    /// scroll/auto clip + pan to scroll_x/scroll_y.
    overflow_x: layout.Overflow = .visible,
    overflow_y: layout.Overflow = .visible,
    /// Scroll offset applied when an axis clips (scroll/auto); clamped to content.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    grow: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    background: ?Color = null,
    corner_radius: f32 = 0,
    /// Box-model border (#330). null `border_color` falls back to the theme border.
    border_width: f32 = 0,
    border_color: ?Color = null,
    /// Make the whole box clickable (dispatches this message id, shows a pointer).
    on_click: ?u32 = null,
    /// Mark this box as a scroll target: scroll input is only delivered to the
    /// model (via onEvent) while the pointer is over it (#309). Pair with
    /// overflow scroll/auto + scroll_x/scroll_y.
    on_scroll: ?u32 = null,
    /// Join the keyboard Tab order (#310); Enter activates `on_click`.
    focusable: bool = false,
    /// Messages dispatched when this box gains / loses keyboard focus (#310).
    on_focus: ?u32 = null,
    on_blur: ?u32 = null,
    /// Roving-tabindex group id (#310): focusable boxes sharing a non-null id are
    /// one tab stop, navigated internally with arrows (radio group / toolbar).
    tab_group: ?u32 = null,
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
    /// Wrap to the available content width, like a browser (#192/#304). Default
    /// on; set false for single-line text (e.g. labels you want to truncate).
    /// Text only wraps when an ancestor constrains its width — unconstrained
    /// text stays a single line at its intrinsic width, matching CSS.
    wrap: bool = true,
    /// Allow the user to drag-select this text and copy it (#318). Off by
    /// default — opt in on body copy / paragraphs the user may want to lift.
    selectable: bool = false,

    // Box model (#330) — lets text act as a badge/chip/pill (padded, filled,
    // rounded, bordered). All neutral by default so plain text is unchanged.
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    border_color: ?Color = null,
};

/// Editable single-line text field (#319). Browser-like: the framework owns the
/// live buffer/caret/selection (keyed by `id`), routes typing + Cut/Copy/Paste/
/// Select-All into it, and draws the text/caret/selection. The app seeds the
/// initial text with `value` (used the first time `id` is seen) and reads the
/// current contents with `zooee.app.textInputValue(id)`; `on_change` is
/// dispatched whenever the buffer changes.
pub const TextInput = struct {
    /// Stable field id — the edit state is keyed by this across frames.
    id: u32,
    /// Seed text, applied only the first time this `id` appears.
    value: []const u8 = "",
    placeholder: []const u8 = "",
    on_change: ?u32 = null,
    width: ?f32 = 200,
    disabled: bool = false,

    // Box model (#330). Defaults reproduce the stock field look; override to
    // restyle. `background`/`border_color` null falls back to the theme.
    padding: layout.EdgeInsets = .symmetric(8, 6),
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 6,
    border_width: f32 = 1,
    border_color: ?Color = null,
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

    // Box model (#330), layered over the size/role defaults. `padding` null = the
    // size preset; `background` null = the role fill; `border_color` null = theme.
    margin: layout.EdgeInsets = .{},
    padding: ?layout.EdgeInsets = null,
    background: ?Color = null,
    corner_radius: f32 = 6,
    border_width: f32 = 0,
    border_color: ?Color = null,
};

/// Shared options for the selection controls (checkbox / toggle / radio, #277).
/// `checked` is prop-driven (the app owns the state); clicking dispatches
/// `on_change`. Look is provisional until the theme system (#21).
pub const Selection = struct {
    checked: bool = false,
    label: []const u8 = "",
    disabled: bool = false,
    on_change: ?u32 = null,
    /// Roving-tabindex group (#310): give the radios of one group the same id
    /// (e.g. via `u.nextGroup()`) so they form a single Tab stop with arrow nav.
    tab_group: ?u32 = null,

    // Box model (#330) applied to the control+label row.
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    border_color: ?Color = null,
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

/// Vector icon (host, #272). Lowers to an Element carrying the baked subpaths
/// for `name` (stroked or filled), scaled to a `size`×`size` box and tinted by
/// `role`/`disabled`. The set is generated at build time from real SVGs in
/// icons/ (Lucide) — see tools/svg2icons.zig and src/generated_icons.zig.
pub const IconName = gen_icons.Name;

pub const Icon = struct {
    name: IconName,
    size: f32 = 16,
    role: Role = .normal,
    disabled: bool = false,
    /// Box-model margin (#330) — outer spacing around the icon's size box.
    margin: layout.EdgeInsets = .{},
};

/// Like `Icon`, but carries already-baked geometry rather than a name from the
/// curated set — lets callers render any generated icon module (e.g. the full
/// `lucide` set) without growing `IconName`. See `Ui.iconData`.
pub const IconRaw = struct {
    data: geometry.IconData,
    size: f32 = 16,
    role: Role = .normal,
    disabled: bool = false,
    /// Box-model margin (#330) — outer spacing around the icon's size box.
    margin: layout.EdgeInsets = .{},
};

/// Selectable list (host, #273): a vertical stack of clickable rows with a
/// highlighted selection. Row click dispatches `on_click`. Virtualization (#29)
/// and keyboard navigation (#16) are follow-ups; row styling is provisional (#21).
pub const ListRow = struct {
    label: []const u8,
    on_click: ?u32 = null,
    /// Optional leading icon (source-list style, #268).
    icon: ?IconName = null,
    /// A non-interactive group header (gray caption, extra top space) rather than
    /// a selectable row — for sectioned source lists.
    header: bool = false,

    // Box model — a ListRow lowers to a flex box, so it carries the same
    // padding/margin/background/border/corner-radius knobs as `Box`. Defaults
    // reproduce the stock row look; override per row to restyle. The selection
    // highlight (when the row is `selected`) overrides `background`.
    padding: layout.EdgeInsets = .symmetric(8, 6),
    margin: layout.EdgeInsets = .{},
    /// Resting fill (selection still wins). null = transparent.
    background: ?Color = null,
    corner_radius: f32 = 6,
    border_width: f32 = 0,
    /// null with a non-zero `border_width` falls back to the theme separator.
    border_color: ?Color = null,
};

pub const List = struct {
    rows: []const ListRow = &.{},
    selected: ?usize = null,
    width: ?f32 = null,
    /// Inter-row spacing (#330). Defaults to the stock 2px stack.
    gap: f32 = 2,
    // Box model (#330) for the list container itself.
    padding: layout.EdgeInsets = .{},
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 0,
    border_width: f32 = 0,
    border_color: ?Color = null,
};

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
    margin: layout.EdgeInsets = .{},
    background: ?Color = null,
    corner_radius: f32 = 0,
    /// Box-model border (#330). null `border_color` falls back to the theme border.
    border_width: f32 = 0,
    border_color: ?Color = null,
    /// Scroll-target id so the wheel routes here even amid other scroll regions
    /// (#309/#312); read it back in onEvent via app.scrollTarget().
    on_scroll: ?u32 = null,
    children: []const Widget = &.{},
};

/// Surface / Card / Panel (host, #275): a content container with a background,
/// rounded corners, an optional border, and an elevation shadow (#119). Used for
/// the detail blocks. Colors/elevation are provisional until the theme (#21).
pub const Elevation = enum { none, low, medium, high };

pub const Card = struct {
    direction: layout.Direction = .column,
    gap: f32 = 0,
    padding: layout.EdgeInsets = layout.EdgeInsets.all(16),
    width: ?f32 = null,
    height: ?f32 = null,
    margin: layout.EdgeInsets = .{},
    /// null = the theme surface color (#21).
    background: ?Color = null,
    corner_radius: f32 = 10,
    border_width: f32 = 0,
    /// null with a non-zero `border_width` falls back to the theme border (#330).
    border_color: ?Color = null,
    elevation: Elevation = .low,
    children: []const Widget = &.{},
};

/// Elevation → drop shadow (#119). Higher = larger offset + blur. The shadow's
/// corner radius is set from the card's at lowering time.
fn elevationShadow(e: Elevation) ?style.BoxShadow {
    const shade = Color{ .r = 0, .g = 0, .b = 0, .a = 90 };
    return switch (e) {
        .none => null,
        .low => .{ .color = shade, .dy = 1, .blur = 4 },
        .medium => .{ .color = shade, .dy = 3, .blur = 10 },
        .high => .{ .color = shade, .dy = 6, .blur = 20 },
    };
}

/// Two-pane split with a divider (host, #268). `.row` = side-by-side panes with
/// a vertical divider (ew-resize); `.column` = stacked panes with a horizontal
/// divider (ns-resize). The leading pane is `leading_size` along the split axis
/// (bind it to model state); the trailing pane fills the rest. Dragging the
/// divider is wired by the app from pointer events (the divider just carries the
/// resize cursor); element-level drag handlers are a follow-up (#5).
pub const Split = struct {
    axis: layout.Direction = .row,
    /// Size (logical px) of the leading pane along the split axis.
    leading_size: f32 = 240,
    divider: f32 = 1,
    panes: []const Widget = &.{}, // exactly two: leading, trailing
};

/// Width (logical px) of the divider's invisible grab/cursor gutter. The visible
/// separator is a hairline on the leading pane; this is just the hit zone.
const split_grab: f32 = 8;

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
    /// Active theme (#21): widget lowering resolves roles/surfaces from this, and
    /// apps can read it to build matching surfaces. Defaults to dark.
    theme: Theme = Theme.dark,
    /// Monotonic counter for roving-tabindex group ids (#310): each list / radio
    /// group / segmented control claims one so its items form a single tab stop.
    /// Frame-local — ids only need to be distinct within one built tree.
    group_seq: u32 = 0,

    /// Claim a fresh roving-tabindex group id (#310).
    pub fn nextGroup(self: *Ui) u32 {
        self.group_seq += 1;
        return self.group_seq;
    }

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

    /// Checkbox (#277): a checkable box + label. `checked`/`disabled` come from
    /// props; clicking dispatches `on_change`. Composed from box + check icon.
    pub fn checkbox(self: *Ui, opts: Selection) !Widget {
        const dim = opts.disabled;
        const fill: ?Color = if (opts.checked) (if (dim) self.theme.surface_variant else self.theme.accent) else null;
        const mark = try self.column(.{
            .width = 18,
            .height = 18,
            .corner_radius = 4,
            .padding = .all(2),
            .background = fill orelse self.theme.surface_variant,
        }, if (opts.checked) &.{self.icon(.{ .name = .check, .size = 14, .role = .normal, .disabled = dim })} else &.{});
        return self.controlRow(opts, mark);
    }

    /// Toggle / switch (#277): a pill track with a knob that sits left (off) or
    /// right (on). macOS-switch flavour; the WinUI variant is a theme tweak (#21).
    pub fn toggle(self: *Ui, opts: Selection) !Widget {
        const knob = try self.column(.{ .width = 18, .height = 18, .corner_radius = 9, .background = Color.white }, &.{});
        const track_children: []const Widget = if (opts.checked)
            &.{ self.spacer(), knob }
        else
            &.{ knob, self.spacer() };
        const track = try self.row(.{
            .width = 42,
            .height = 22,
            .corner_radius = 11,
            .padding = .all(2),
            .background = if (opts.checked) (if (opts.disabled) self.theme.surface_variant else self.theme.accent) else self.theme.surface_variant,
        }, track_children);
        return self.controlRow(opts, track);
    }

    /// Radio button (#277): a ring with a filled dot when selected. Group by
    /// giving each option a distinct `on_change` message.
    pub fn radio(self: *Ui, opts: Selection) !Widget {
        const dot: []const Widget = if (opts.checked)
            &.{try self.column(.{ .width = 10, .height = 10, .corner_radius = 5, .background = if (opts.disabled) self.theme.text_muted else self.theme.accent }, &.{})}
        else
            &.{};
        const ring = try self.column(.{
            .width = 18,
            .height = 18,
            .corner_radius = 9,
            // Center the dot in the ring so the border/padding don't shift it off
            // axis (the engine is border-box: content = size − border − padding).
            .justify = .center,
            .align_items = .center,
            .background = self.theme.surface_variant,
            .border_width = 1,
            .border_color = if (opts.disabled) self.theme.border else self.theme.accent,
        }, dot);
        return self.controlRow(opts, ring);
    }

    /// Shared layout for a selection control: the indicator + an optional label,
    /// the whole row clickable (unless disabled).
    fn controlRow(self: *Ui, opts: Selection, indicator: Widget) !Widget {
        const children: []const Widget = if (opts.label.len > 0)
            &.{ indicator, self.text(opts.label, .{ .role = if (opts.disabled) .secondary else .normal }) }
        else
            &.{indicator};
        return self.row(.{
            .gap = 8,
            .on_click = if (opts.disabled) null else opts.on_change,
            .focusable = !opts.disabled, // joins the Tab order (#310)
            .tab_group = opts.tab_group, // optional roving group (radios) (#310)
            .padding = opts.padding,
            .margin = opts.margin,
            .background = opts.background,
            .corner_radius = opts.corner_radius,
            .border_width = opts.border_width,
            .border_color = opts.border_color,
        }, children);
    }

    /// Flexible empty space that pushes siblings apart (grow=1, no paint).
    pub fn spacer(self: *Ui) Widget {
        _ = self;
        return .{ .box = .{ .grow = 1 } };
    }

    /// A 1px separator line. Lays out across the parent's cross axis: full width
    /// in a column, full height in a row. Color is provisional until the theme (#21).
    pub fn divider(self: *Ui, direction: layout.Direction) Widget {
        // A column stacks vertically → the divider is a horizontal rule (tall=1);
        // a row lays out horizontally → a vertical rule (wide=1).
        return switch (direction) {
            .column => .{ .box = .{ .height = 1, .background = self.theme.border } },
            .row => .{ .box = .{ .width = 1, .background = self.theme.border } },
        };
    }

    pub fn icon(self: *Ui, opts: Icon) Widget {
        _ = self;
        return .{ .icon = opts };
    }

    /// Render pre-baked icon geometry (any generated set, e.g. `lucide.get(...)`).
    pub fn iconData(self: *Ui, opts: IconRaw) Widget {
        _ = self;
        return .{ .icon_data = opts };
    }

    /// Editable text field (#319). Seeds the framework edit state for `opts.id`
    /// with `opts.value` on first use; thereafter the field owns its buffer.
    pub fn textInput(self: *Ui, opts: TextInput) Widget {
        _ = self;
        edit_state.ensure(opts.id, opts.value);
        return .{ .text_input = opts };
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

    /// Surface / card. `children` is copied into the arena (like the containers).
    pub fn card(self: *Ui, opts: Card, children: []const Widget) !Widget {
        var c = opts;
        c.children = try self.arena.dupe(Widget, children);
        return .{ .card = c };
    }

    /// Two-pane split. `leading`/`trailing` are copied into the arena.
    pub fn split(self: *Ui, opts: Split, leading: Widget, trailing: Widget) !Widget {
        var sp = opts;
        sp.panes = try self.arena.dupe(Widget, &.{ leading, trailing });
        return .{ .split = sp };
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
    /// Shared icon lowering: scale normalized subpaths to a `size`×`size` pixel
    /// box and tint by role. Used by both `.icon` (curated set) and `.icon_data`
    /// (arbitrary baked geometry).
    fn lowerIcon(self: *Ui, el: *Element, s: f32, d: geometry.IconData, size: f32, role: Role, disabled: bool) !void {
        const px = size * s;
        const sps = try self.arena.alloc(layout.IconSubPath, d.subpaths.len);
        for (d.subpaths, 0..) |sp, k| {
            const pts = try self.arena.alloc(geometry.Point, sp.pts.len);
            for (sp.pts, 0..) |p, j| pts[j] = .{ .x = p.x * px, .y = p.y * px };
            sps[k] = .{ .pts = pts, .closed = sp.closed };
        }
        el.* = .{
            .width = px,
            .height = px,
            .icon_paths = sps,
            .icon_stroke = d.stroke,
            // Stroke width scales with the icon (Lucide authors at 24px);
            // floor at ~1px so small icons stay visible.
            .stroke_width = @max(1, d.stroke_width * px),
            .path_color = if (disabled) self.theme.text_muted else iconTint(self.theme, role),
        };
    }

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
                    .justify = b.justify,
                    .align_items = b.align_items,
                    .wrap = b.wrap,
                    .overflow_x = b.overflow_x,
                    .overflow_y = b.overflow_y,
                    .scroll_x = b.scroll_x * s,
                    .scroll_y = b.scroll_y * s,
                    .padding = scaleInsets(b.padding, s),
                    .margin = scaleInsets(b.margin, s),
                    .grow = b.grow,
                    .width = if (b.width) |x| x * s else null,
                    .height = if (b.height) |x| x * s else null,
                    .on_click = b.on_click,
                    .on_scroll = b.on_scroll,
                    .focusable = b.focusable,
                    .on_focus = b.on_focus,
                    .on_blur = b.on_blur,
                    .tab_group = b.tab_group,
                    .cursor = if (b.on_click != null) .pointer else null,
                    .children = kids,
                    .rect_style = .{
                        .background = b.background,
                        .corner_radius = if (b.corner_radius > 0) .all(b.corner_radius * s) else .none,
                        .border = borderFrom(b.border_width, b.border_color, self.theme, s),
                    },
                };
            },
            .text => |t| el.* = .{
                .text = t.text,
                .text_wrap = if (t.wrap) .wrap else .nowrap,
                .text_selectable = t.selectable,
                .cursor = if (t.selectable) .text else null, // I-beam affordance (#318)
                .padding = scaleInsets(t.padding, s),
                .margin = scaleInsets(t.margin, s),
                .text_style = .{
                    .size = (t.size orelse variantSize(t.variant)) * s,
                    .bold = t.bold orelse variantBold(t.variant),
                    .color = roleTextColor(self.theme, t.role),
                },
                .rect_style = .{
                    .background = t.background,
                    .corner_radius = if (t.corner_radius > 0) .all(t.corner_radius * s) else .none,
                    .border = borderFrom(t.border_width, t.border_color, self.theme, s),
                },
            },
            .text_input => |ti| {
                // A focusable bordered box whose text IS the live edit buffer, so
                // normal layout draws it; the framework overlays the caret +
                // selection on the focused field in a render pass (#319).
                const fsize = 15 * s;
                const pad = scaleInsets(ti.padding, s);
                const buf = edit_state.value(ti.id);
                const show_ph = buf.len == 0;
                el.* = .{
                    .edit_field = ti.id,
                    .edit_on_change = ti.on_change,
                    .edit_placeholder = ti.placeholder,
                    .text = if (show_ph) ti.placeholder else buf,
                    .text_wrap = .nowrap, // single-line
                    .focusable = !ti.disabled,
                    .cursor = if (ti.disabled) null else .text,
                    .width = if (ti.width) |iw| iw * s else null,
                    .height = fsize * 1.35 + pad.top + pad.bottom,
                    .padding = pad,
                    .margin = scaleInsets(ti.margin, s),
                    .text_style = .{
                        .size = fsize,
                        .color = if (ti.disabled) self.theme.text_muted else if (show_ph) self.theme.text_muted else self.theme.text,
                    },
                    .rect_style = .{
                        .background = ti.background orelse self.theme.surface,
                        .border = borderFrom(ti.border_width, ti.border_color, self.theme, s),
                        .corner_radius = if (ti.corner_radius > 0) .all(ti.corner_radius * s) else .none,
                    },
                };
            },
            .button => |bt| {
                const pad = buttonPad(bt.size);
                el.* = .{
                    .text = bt.label,
                    // Disabled: dispatch nothing, no pointer affordance.
                    .on_click = if (bt.disabled) null else bt.on_click,
                    .focusable = !bt.disabled, // joins the Tab order (#310)
                    .cursor = if (bt.disabled) null else .pointer,
                    .padding = if (bt.padding) |p| scaleInsets(p, s) else .symmetric(pad.x * s, pad.y * s),
                    .margin = scaleInsets(bt.margin, s),
                    .text_style = .{
                        .size = buttonTextSize(bt.size) * s,
                        .color = if (bt.disabled) self.theme.text_muted else onRoleFill(self.theme, bt.role),
                    },
                    .rect_style = .{
                        .background = if (bt.disabled) self.theme.surface_variant else (bt.background orelse roleFill(self.theme, bt.role)),
                        .corner_radius = if (bt.corner_radius > 0) .all(bt.corner_radius * s) else .none,
                        .border = borderFrom(bt.border_width, bt.border_color, self.theme, s),
                    },
                };
            },
            .icon => |ic| {
                try self.lowerIcon(el, s, gen_icons.get(ic.name), ic.size, ic.role, ic.disabled);
                el.margin = scaleInsets(ic.margin, s);
            },
            .icon_data => |ic| {
                try self.lowerIcon(el, s, ic.data, ic.size, ic.role, ic.disabled);
                el.margin = scaleInsets(ic.margin, s);
            },
            .list => |l| {
                // One roving-tabindex group for the whole list (#310/#16): the
                // list is a single Tab stop, arrows move between its rows.
                const gid = self.nextGroup();
                const rows = try self.arena.alloc(*const Element, l.rows.len);
                for (l.rows, 0..) |r, i| {
                    const row_el = try self.arena.create(Element);
                    const sel = l.selected != null and l.selected.? == i;
                    if (r.header) {
                        // Group header: a muted caption with extra top space.
                        row_el.* = .{
                            .text = r.label,
                            .padding = .{ .top = 14 * s, .bottom = 4 * s, .left = 8 * s, .right = 8 * s },
                            .text_style = .{ .size = 11 * s, .bold = true, .color = self.theme.text_muted },
                        };
                    } else {
                        const fg = if (sel) self.theme.on_accent else self.theme.text;
                        const label_el = try self.arena.create(Element);
                        label_el.* = .{ .text = r.label, .text_style = .{ .size = 15 * s, .color = fg } };
                        // Optional leading icon, tinted to match the row state.
                        var kids: []const *const Element = undefined;
                        if (r.icon) |name| {
                            const icon_el = @constCast(try self.lower(self.icon(.{ .name = name, .size = 15 })));
                            icon_el.path_color = if (sel) self.theme.on_accent else self.theme.text_muted;
                            const pair = try self.arena.alloc(*const Element, 2);
                            pair[0] = icon_el;
                            pair[1] = label_el;
                            kids = pair;
                        } else {
                            const one = try self.arena.alloc(*const Element, 1);
                            one[0] = label_el;
                            kids = one;
                        }
                        const border = borderFrom(r.border_width, r.border_color, self.theme, s);
                        row_el.* = .{
                            .direction = .row,
                            .align_items = .center,
                            .gap = 8 * s,
                            .on_click = r.on_click,
                            .focusable = r.on_click != null, // arrow/Tab nav (#310/#16)
                            .tab_group = if (r.on_click != null) gid else null, // one tab stop
                            .cursor = if (r.on_click != null) .pointer else null,
                            .padding = scaleInsets(r.padding, s),
                            .margin = scaleInsets(r.margin, s),
                            .children = kids,
                            .rect_style = .{
                                .background = if (sel) self.theme.accent else r.background,
                                .corner_radius = .all(r.corner_radius * s),
                                .border = border,
                            },
                        };
                    }
                    rows[i] = row_el;
                }
                el.* = .{
                    .direction = .column,
                    .gap = l.gap * s,
                    .width = if (l.width) |lw| lw * s else null,
                    .padding = scaleInsets(l.padding, s),
                    .margin = scaleInsets(l.margin, s),
                    .children = rows,
                    .rect_style = .{
                        .background = l.background,
                        .corner_radius = if (l.corner_radius > 0) .all(l.corner_radius * s) else .none,
                        .border = borderFrom(l.border_width, l.border_color, self.theme, s),
                    },
                };
            },
            .scroll => |sv| {
                const kids = try self.arena.alloc(*const Element, sv.children.len);
                for (sv.children, 0..) |c, i| kids[i] = try self.lower(c);
                el.* = .{
                    .direction = sv.direction,
                    .gap = sv.gap * s,
                    .padding = scaleInsets(sv.padding, s),
                    .margin = scaleInsets(sv.margin, s),
                    .width = if (sv.width) |x| x * s else null,
                    .height = if (sv.height) |x| x * s else null,
                    .scroll = true,
                    .scroll_x = sv.scroll_x * s,
                    .scroll_y = sv.scroll_y * s,
                    .on_scroll = sv.on_scroll,
                    .children = kids,
                    .rect_style = .{
                        .background = sv.background,
                        .corner_radius = if (sv.corner_radius > 0) .all(sv.corner_radius * s) else .none,
                        .border = borderFrom(sv.border_width, sv.border_color, self.theme, s),
                    },
                };
            },
            .card => |cd| {
                const kids = try self.arena.alloc(*const Element, cd.children.len);
                for (cd.children, 0..) |c, i| kids[i] = try self.lower(c);
                var shadow = elevationShadow(cd.elevation);
                if (shadow) |*sh| {
                    sh.corner_radius = cd.corner_radius * s;
                    sh.dx *= s;
                    sh.dy *= s;
                    sh.blur *= s;
                }
                el.* = .{
                    .direction = cd.direction,
                    .gap = cd.gap * s,
                    .padding = scaleInsets(cd.padding, s),
                    .margin = scaleInsets(cd.margin, s),
                    .width = if (cd.width) |x| x * s else null,
                    .height = if (cd.height) |x| x * s else null,
                    .children = kids,
                    .rect_style = .{
                        .background = cd.background orelse self.theme.surface,
                        .corner_radius = .all(cd.corner_radius * s),
                        .border = borderFrom(cd.border_width, cd.border_color, self.theme, s),
                        .shadow = shadow,
                    },
                };
            },
            .split => |sp| {
                const row_axis = sp.axis == .row;
                // Lower the panes, then impose the split's sizing on each outer
                // box (arena memory we own — safe to write through the const ptr).
                const lead = @constCast(try self.lower(sp.panes[0]));
                const trail = @constCast(try self.lower(sp.panes[1]));
                // The visible separator is a hairline drawn on the leading pane's
                // trailing edge; the divider element itself is a wide *invisible*
                // grab gutter that carries the resize cursor (a 1px element is
                // unhittable). The gutter shows the backdrop, so it reads as a
                // hairline + an easy grab zone — the macOS / JetBrains split feel.
                const line: style.BorderSide = .{ .width = sp.divider * s, .color = self.theme.border };
                if (row_axis) {
                    lead.width = sp.leading_size * s;
                    lead.grow = 0;
                    lead.rect_style.border.right = line;
                    trail.grow = 1;
                    trail.width = null;
                } else {
                    lead.height = sp.leading_size * s;
                    lead.grow = 0;
                    lead.rect_style.border.bottom = line;
                    trail.grow = 1;
                    trail.height = null;
                }
                const div = try self.arena.create(Element);
                div.* = .{
                    .width = if (row_axis) split_grab * s else null,
                    .height = if (row_axis) null else split_grab * s,
                    .cursor = if (row_axis) .ew_resize else .ns_resize,
                };
                const kids = try self.arena.alloc(*const Element, 3);
                kids[0] = lead;
                kids[1] = div;
                kids[2] = trail;
                el.* = .{ .direction = sp.axis, .children = kids };
            },
            .composite => |c| return self.lower(try c.expand(c.ctx, self)),
        }
        return el;
    }
};

fn scaleInsets(e: layout.EdgeInsets, s: f32) layout.EdgeInsets {
    return .{ .top = e.top * s, .right = e.right * s, .bottom = e.bottom * s, .left = e.left * s };
}

/// Shared box-model border lowering (#330): a uniform DPI-scaled border, or
/// `.none` when `width <= 0`. A null `color` falls back to the theme border.
fn borderFrom(width: f32, color: ?Color, theme: Theme, s: f32) style.Border {
    return if (width > 0) .all(width * s, color orelse theme.border) else .none;
}

// Role → concrete colors, resolved from the active theme (#21).
fn roleFill(t: Theme, role: Role) Color {
    return switch (role) {
        .normal, .secondary => t.surface_variant,
        .primary => t.accent,
        .danger => t.danger,
    };
}
/// Text/icon color drawn on a `roleFill` background.
fn onRoleFill(t: Theme, role: Role) Color {
    return switch (role) {
        .normal, .secondary => t.text, // grey fill → primary text
        .primary, .danger => t.on_accent, // accent/red fill → on-accent
    };
}
fn iconTint(t: Theme, role: Role) Color {
    return switch (role) {
        .normal => t.text,
        .primary => t.accent,
        .secondary => t.text_muted,
        .danger => t.danger,
    };
}
fn roleTextColor(t: Theme, role: Role) ?Color {
    return switch (role) {
        .normal => t.text,
        .secondary => t.text_muted,
        .primary => t.accent,
        .danger => t.danger,
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

test "lower: box carries a border (#321)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const el = try ui.lower(try ui.column(.{ .border_width = 2, .border_color = Color.rgb(1, 2, 3) }, &.{}));
    try testing.expect(!el.rect_style.border.isNone());
    try testing.expectEqual(@as(f32, 2), el.rect_style.border.top.width);
    // No border by default.
    const plain = try ui.lower(try ui.column(.{}, &.{}));
    try testing.expect(plain.rect_style.border.isNone());
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

test "lower: box model on Button / Selection / Text / Icon (#326 #327 #328 #329)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    // Button (#326): margin + padding/background/border overrides over role/size.
    const btn = try ui.lower(ui.button(.{
        .label = "Go",
        .on_click = 1,
        .margin = .all(3),
        .padding = .all(20),
        .background = Color.rgb(1, 1, 1),
        .border_width = 1,
    }));
    try testing.expectEqual(@as(f32, 3), btn.margin.top);
    try testing.expectEqual(@as(f32, 20), btn.padding.left); // override, not the size preset
    try testing.expectEqual(Color.rgb(1, 1, 1), btn.rect_style.background.?);
    try testing.expect(!btn.rect_style.border.isNone());

    // Selection (#327): the control row carries the box model.
    const sel = try ui.lower(try ui.checkbox(.{ .label = "A", .on_change = 2, .margin = .all(5), .background = Color.rgb(2, 2, 2), .corner_radius = 8 }));
    try testing.expectEqual(@as(f32, 5), sel.margin.top);
    try testing.expect(sel.rect_style.background != null);
    try testing.expectEqual(@as(f32, 8), sel.rect_style.corner_radius.top_left);

    // Text (#328): badge/chip surface; plain text stays neutral.
    const badge = try ui.lower(ui.text("NEW", .{ .padding = .all(4), .margin = .{ .right = 6 }, .background = Color.rgb(3, 3, 3), .corner_radius = 4, .border_width = 1 }));
    try testing.expectEqual(@as(f32, 4), badge.padding.left);
    try testing.expectEqual(@as(f32, 6), badge.margin.right);
    try testing.expect(badge.rect_style.background != null);
    try testing.expect(!badge.rect_style.border.isNone());
    const plain = try ui.lower(ui.text("hi", .{}));
    try testing.expect(plain.rect_style.background == null);
    try testing.expectEqual(@as(f32, 0), plain.padding.left);

    // Icon (#329): margin around the size box.
    const ic = try ui.lower(ui.icon(.{ .name = .plus, .size = 16, .margin = .all(7) }));
    try testing.expectEqual(@as(f32, 7), ic.margin.top);
    try testing.expectEqual(@as(?f32, 16), ic.width); // size box unchanged
}

test "generated icon: a relative-moveto subpath after another element is positioned absolutely (#272)" {
    // square-check = <rect rx=2> then <path d="m9 12 2 2 4-4">. The check's
    // leading relative moveto must start from the origin, NOT where the rect
    // ended — guards the svg2icons per-element current-point reset.
    const d = gen_icons.get(.square_check);
    try testing.expectEqual(@as(usize, 2), d.subpaths.len);
    const check = d.subpaths[1]; // the checkmark, not the rect
    try testing.expectEqual(@as(usize, 3), check.pts.len);
    // First vertex is (9,12) in the 24-unit viewBox → 0.375, 0.5 normalized.
    try testing.expectApproxEqAbs(@as(f32, 0.375), check.pts[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), check.pts[0].y, 0.001);
}

test "lower: icon → sized filled path; disabled dims the tint (#272)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(ui.icon(.{ .name = .plus, .size = 24 }));
    try testing.expectEqual(@as(?f32, 24), el.width);
    try testing.expectEqual(@as(?f32, 24), el.height);
    try testing.expect(el.icon_paths != null);
    try testing.expect(el.icon_paths.?.len >= 1); // baked Lucide plus = 2 strokes
    try testing.expect(el.icon_stroke); // Lucide icons are stroked
    // Points are scaled into the 24px box (normalized 0..1 × size).
    for (el.icon_paths.?) |sp| for (sp.pts) |pt| {
        try testing.expect(pt.x >= 0 and pt.x <= 24 and pt.y >= 0 and pt.y <= 24);
    };

    // Disabled tint differs from the enabled role tint.
    const on = try ui.lower(ui.icon(.{ .name = .check, .role = .primary }));
    const off = try ui.lower(ui.icon(.{ .name = .check, .role = .primary, .disabled = true }));
    try testing.expect(!std.meta.eql(on.path_color, off.path_color));
}

test "lower: text input defaults to the field look and honors box-model overrides (#322)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    // Default field look: surface fill, 1px border, 6px radius, symmetric pad.
    const def = try ui.lower(ui.textInput(.{ .id = 7701 }));
    try testing.expectEqual(@as(?u32, 7701), def.edit_field);
    try testing.expect(def.rect_style.background != null);
    try testing.expect(!def.rect_style.border.isNone());
    try testing.expectEqual(@as(f32, 6), def.rect_style.corner_radius.top_left);
    try testing.expectEqual(@as(f32, 8), def.padding.left);

    // Overrides flow through.
    const styled = try ui.lower(ui.textInput(.{
        .id = 7702,
        .padding = .all(12),
        .margin = .{ .bottom = 4 },
        .background = Color.rgb(7, 7, 7),
        .corner_radius = 16,
        .border_width = 0,
    }));
    try testing.expectEqual(@as(f32, 12), styled.padding.left);
    try testing.expectEqual(@as(f32, 4), styled.margin.bottom);
    try testing.expectEqual(Color.rgb(7, 7, 7), styled.rect_style.background.?);
    try testing.expectEqual(@as(f32, 16), styled.rect_style.corner_radius.top_left);
    try testing.expect(styled.rect_style.border.isNone()); // border_width 0 → none
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
    // Each row is a container holding the label (and optional icon).
    try testing.expectEqualStrings("Alpha", el.children[0].children[0].text.?);
    try testing.expectEqual(@as(?u32, 102), el.children[2].on_click);
    try testing.expectEqual(cursorPointer(), el.children[0].cursor.?);
    // Only the selected row paints a background.
    try testing.expect(el.children[0].rect_style.background == null);
    try testing.expect(el.children[1].rect_style.background != null);
}

test "lower: list row carries the box model (padding/bg/border/radius)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const el = try ui.lower(try ui.list(.{}, &.{
        .{
            .label = "Styled",
            .on_click = 1,
            .padding = .all(12),
            .margin = .{ .bottom = 4 },
            .background = Color.rgb(10, 20, 30),
            .corner_radius = 14,
            .border_width = 2,
        },
    }));
    const row = el.children[0];
    try testing.expectEqual(@as(f32, 12), row.padding.left);
    try testing.expectEqual(@as(f32, 4), row.margin.bottom);
    try testing.expect(row.rect_style.background != null);
    try testing.expectEqual(@as(f32, 14), row.rect_style.corner_radius.top_left);
    try testing.expect(!row.rect_style.border.isNone());
}

test "lower: list row with icon + a header (#268)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const el = try ui.lower(try ui.list(.{ .selected = 1 }, &.{
        .{ .label = "Section", .header = true },
        .{ .label = "Item", .icon = .star, .on_click = 5 },
    }));
    // Header: a caption, no click, no fill.
    try testing.expect(el.children[0].on_click == null);
    try testing.expectEqualStrings("Section", el.children[0].text.?);
    // Icon row: [icon, label], centered, clickable.
    try testing.expectEqual(layout.AlignItems.center, el.children[1].align_items);
    try testing.expectEqual(@as(usize, 2), el.children[1].children.len);
    try testing.expect(el.children[1].children[0].icon_paths != null); // the icon
    try testing.expectEqualStrings("Item", el.children[1].children[1].text.?);
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

    // Box model (#324): margin + corner_radius + border.
    const styled = try ui.lower(try ui.scroll(.{ .margin = .all(6), .corner_radius = 8, .border_width = 1 }, &.{}));
    try testing.expectEqual(@as(f32, 6), styled.margin.left);
    try testing.expectEqual(@as(f32, 8), styled.rect_style.corner_radius.top_left);
    try testing.expect(!styled.rect_style.border.isNone());
}

test "lower: list container carries the box model + gap (#325)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const el = try ui.lower(try ui.list(.{
        .gap = 10,
        .padding = .all(4),
        .margin = .{ .top = 2 },
        .background = Color.rgb(5, 5, 5),
        .corner_radius = 12,
        .border_width = 1,
    }, &.{.{ .label = "X", .on_click = 1 }}));
    try testing.expectEqual(@as(f32, 10), el.gap);
    try testing.expectEqual(@as(f32, 4), el.padding.left);
    try testing.expectEqual(@as(f32, 2), el.margin.top);
    try testing.expect(el.rect_style.background != null);
    try testing.expectEqual(@as(f32, 12), el.rect_style.corner_radius.top_left);
    try testing.expect(!el.rect_style.border.isNone());
}

test "lower: card has surface fill, rounded corners, border + elevation shadow (#275)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(try ui.card(.{ .border_width = 1, .elevation = .medium, .corner_radius = 12 }, &.{
        ui.text("title", .{ .variant = .heading }),
    }));
    try testing.expect(el.rect_style.background != null);
    try testing.expectEqual(@as(f32, 12), el.rect_style.corner_radius.top_left);
    try testing.expect(!el.rect_style.border.isNone());
    try testing.expect(el.rect_style.shadow != null);
    // Shadow inherits the card's corner radius so it rounds with the surface.
    try testing.expectEqual(@as(f32, 12), el.rect_style.shadow.?.corner_radius);
    try testing.expectEqual(@as(usize, 1), el.children.len);

    // elevation .none → no shadow.
    const flat = try ui.lower(try ui.card(.{ .elevation = .none }, &.{}));
    try testing.expect(flat.rect_style.shadow == null);

    // Box model (#323): margin + explicit border_color.
    const styled = try ui.lower(try ui.card(.{ .margin = .all(8), .border_width = 2, .border_color = Color.rgb(9, 9, 9) }, &.{}));
    try testing.expectEqual(@as(f32, 8), styled.margin.top);
    try testing.expectEqual(Color.rgb(9, 9, 9), styled.rect_style.border.top.color);
}

test "lower: selection controls are clickable and reflect checked state (#277)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    // Checkbox: row is clickable; checked → indicator has a check-icon child.
    const cb_on = try ui.lower(try ui.checkbox(.{ .checked = true, .label = "Agree", .on_change = 5 }));
    try testing.expectEqual(@as(?u32, 5), cb_on.on_click);
    try testing.expect(cb_on.children[0].children.len == 1); // the check icon
    const cb_off = try ui.lower(try ui.checkbox(.{ .checked = false, .on_change = 5 }));
    try testing.expect(cb_off.children[0].children.len == 0);

    // Disabled control does not dispatch.
    const cb_dis = try ui.lower(try ui.checkbox(.{ .checked = false, .disabled = true, .on_change = 5 }));
    try testing.expectEqual(@as(?u32, null), cb_dis.on_click);

    // Toggle: inside the track, knob order flips with state (on → spacer first).
    const tg_on = try ui.lower(try ui.toggle(.{ .checked = true, .on_change = 6 }));
    try testing.expect(tg_on.children[0].children[0].grow == 1); // leading spacer when on
    const tg_off = try ui.lower(try ui.toggle(.{ .checked = false, .on_change = 6 }));
    try testing.expect(tg_off.children[0].children[0].grow == 0); // knob leads when off

    // Radio: selected → ring has a dot child.
    const rb = try ui.lower(try ui.radio(.{ .checked = true, .on_change = 7 }));
    try testing.expect(rb.children[0].children.len == 1);
}

test "lower: split — fixed leading pane, resize-cursor divider, growing trailing (#268)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());

    const el = try ui.lower(try ui.split(
        .{ .axis = .row, .leading_size = 200, .divider = 2 },
        try ui.column(.{ .background = Color.rgb(28, 28, 32) }, &.{ui.text("nav", .{})}),
        try ui.column(.{}, &.{ui.text("content", .{})}),
    ));

    try testing.expectEqual(layout.Direction.row, el.direction);
    try testing.expectEqual(@as(usize, 3), el.children.len);
    // Leading: fixed width, not growing; trailing: grows, no fixed width.
    try testing.expectEqual(@as(?f32, 200), el.children[0].width);
    try testing.expectEqual(@as(f32, 0), el.children[0].grow);
    try testing.expectEqual(@as(f32, 1), el.children[2].grow);
    try testing.expect(el.children[2].width == null);
    // Visible separator is a hairline on the leading pane's trailing edge.
    try testing.expectEqual(@as(f32, 2), el.children[0].rect_style.border.right.width);
    // Divider element is a wide invisible grab gutter carrying the resize cursor.
    try testing.expectEqual(@as(?f32, split_grab), el.children[1].width);
    try testing.expect(el.children[1].rect_style.background == null);
    try testing.expectEqual(@as(?@import("cursor.zig").Cursor, .ew_resize), el.children[1].cursor);
}

test "fmt allocates a frame-owned label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    try testing.expectEqualStrings("n=42", ui.fmt("n={d}", .{42}));
}
