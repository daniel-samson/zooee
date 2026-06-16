//! Component gallery / living-docs app (#266/#268/#24): a master→detail shell
//! built on the widget layer (#4 `viewUi`). The sidebar (master) lists Welcome
//! + each component; the detail pane shows that page. This is the Phase-2 demo
//! that doubles as the documentation. Look/theme is provisional and tuned in QA
//! (per-OS sidebar styling, custom titlebar, etc. land with #21/#268).

const std = @import("std");
const zooee = @import("zooee");
const ui = zooee.ui;
const Widget = ui.Widget;
const Color = zooee.Color;

const force_software = @import("build_options").force_software;

const Page = struct { name: []const u8, body: []const u8, icon: ui.IconName };
const pages = [_]Page{
    .{ .name = "Welcome", .icon = .star, .body = "Welcome to zooee — a native, cross-platform UI in Zig.\n\nThis app is the component gallery: pick an item on the left to see it, with variants and examples. The look adapts per OS (macOS / WinUI / Linux) and is still being tuned." },
    .{ .name = "Layout", .icon = .square, .body = "Flex containers (row / column) with gap, padding, grow, and CSS-style justify-content / align-items. `spacer()` fills free space; `divider()` draws a 1px rule across the cross axis." },
    .{ .name = "Button", .icon = .circle, .body = "Buttons trigger actions. Variants: primary, secondary, danger. (Live examples land as the Button component is built, #271.)" },
    .{ .name = "Icon", .icon = .star, .body = "Vector icons drawn with the path renderer. They tint with the current role and dim when disabled. Starter set: plus, check, play, chevron." },
    .{ .name = "Text", .icon = .doc, .body = "Text and labels: titles, headings, body, captions — with the shaping pipeline (Latin, Arabic, BiDi). (#270)" },
    .{ .name = "List", .icon = .square, .body = "A selectable list — the master/nav pattern. Each row dispatches on click; the selected row is highlighted. (The sidebar on the left is itself a List.) Virtualization (#29) and keyboard nav (#16) are follow-ups." },
    .{ .name = "Scroll", .icon = .circle, .body = "A scroll viewport: a fixed-size box that clips its content and pans it on wheel/trackpad. Offsets are clamped to the content extent. Scroll inside the box below." },
    .{ .name = "Card", .icon = .doc, .body = "Surfaces / panels: a background, rounded corners, an optional border, and an elevation shadow. The building block for content blocks." },
    .{ .name = "Selection", .icon = .check, .body = "Checkbox, toggle/switch, and radio group — boolean and single-choice selection. Click any control to change it. Checked state is prop-driven; clicks dispatch on_change." },
};

/// Message ids for the Selection page's interactive controls.
const sel_check: u32 = 2000;
const sel_toggle: u32 = 2001;
const sel_radio_base: u32 = 2010; // +0/+1/+2 for the three radio options

/// Live examples for the Selection page (#277): checkbox, toggle, radio group.
fn selectionExamples(u: *ui.Ui, check_on: bool, toggle_on: bool, radio: usize) !Widget {
    const opts = [_][]const u8{ "Small", "Medium", "Large" };
    const radios = try u.arena.alloc(Widget, opts.len);
    for (opts, 0..) |name, i| radios[i] = try u.radio(.{
        .checked = (radio == i),
        .label = name,
        .on_change = sel_radio_base + @as(u32, @intCast(i)),
    });
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "checkbox", try u.checkbox(.{ .checked = check_on, .label = "I agree to the terms", .on_change = sel_check })),
        try example(u, "toggle / switch", try u.toggle(.{ .checked = toggle_on, .label = "Wi-Fi", .on_change = sel_toggle })),
        try example(u, "radio group (single choice)", try u.column(.{ .gap = 8 }, radios)),
        try example(u, "disabled states", try u.row(.{ .gap = 20 }, &.{
            try u.checkbox(.{ .checked = true, .label = "Checked", .disabled = true }),
            try u.toggle(.{ .checked = true, .label = "On", .disabled = true }),
        })),
    });
}

/// Live examples for the Card page (#275): elevation levels + a bordered card.
fn cardExamples(u: *ui.Ui) !Widget {
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "elevation (none / low / medium / high)", try u.row(.{ .gap = 18 }, &.{
            try u.card(.{ .elevation = .none, .width = 120, .height = 70 }, &.{u.text("none", .{ .role = .secondary })}),
            try u.card(.{ .elevation = .low, .width = 120, .height = 70 }, &.{u.text("low", .{ .role = .secondary })}),
            try u.card(.{ .elevation = .medium, .width = 120, .height = 70 }, &.{u.text("medium", .{ .role = .secondary })}),
            try u.card(.{ .elevation = .high, .width = 120, .height = 70 }, &.{u.text("high", .{ .role = .secondary })}),
        })),
        try example(u, "a bordered card with content", try u.card(.{ .border_width = 1, .elevation = .low, .width = 280, .gap = 8 }, &.{
            u.text("Card title", .{ .variant = .heading }),
            u.text("Cards group related content on a raised surface.", .{ .variant = .body }),
        })),
    });
}

/// A labelled example block: a caption above a bordered demo surface.
fn example(u: *ui.Ui, caption: []const u8, demo: Widget) !Widget {
    return u.column(.{ .gap = 6 }, &.{
        u.text(caption, .{ .variant = .caption, .role = .secondary }),
        try u.column(.{
            .padding = .all(16),
            .background = u.theme.surface,
            .corner_radius = 8,
        }, &.{demo}),
    });
}

/// Live example for the Scroll page (#274): a tall content column in a viewport.
fn scrollExamples(u: *ui.Ui, offset: f32) !Widget {
    const lines = try u.arena.alloc(Widget, 24);
    for (0..24) |i| lines[i] = u.text(u.fmt("Line {d} — scroll to see more", .{i + 1}), .{});
    return example(u, "wheel/trackpad scrolls the content within the box", try u.scroll(.{
        .width = 320,
        .height = 180,
        .gap = 6,
        .padding = .all(12),
        .scroll_y = offset,
        .background = u.theme.background,
    }, lines));
}

/// Base message id for the List page's demo rows (kept clear of page indices).
const list_demo_base: u32 = 1000;

/// Live examples for the List page (#273): a selectable list with live selection.
fn listExamples(u: *ui.Ui, selected: usize) !Widget {
    const fruit = [_][]const u8{ "Apple", "Banana", "Cherry", "Date", "Elderberry" };
    const rows = try u.arena.alloc(ui.ListRow, fruit.len);
    for (fruit, 0..) |name, i| rows[i] = .{ .label = name, .on_click = list_demo_base + @as(u32, @intCast(i)) };
    return example(u, "click a row to select it", try u.column(.{ .width = 240 }, &.{
        try u.list(.{ .selected = selected, .width = 240 }, rows),
    }));
}

/// Live examples for the Icon page (#272): the starter set, tints, sizes.
fn iconExamples(u: *ui.Ui) !Widget {
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "the starter set", try u.row(.{ .gap = 16 }, &.{
            u.icon(.{ .name = .plus, .size = 24 }),
            u.icon(.{ .name = .check, .size = 24 }),
            u.icon(.{ .name = .play, .size = 24 }),
            u.icon(.{ .name = .chevron_right, .size = 24 }),
        })),
        try example(u, "role tints", try u.row(.{ .gap = 16 }, &.{
            u.icon(.{ .name = .check, .size = 24, .role = .primary }),
            u.icon(.{ .name = .check, .size = 24, .role = .secondary }),
            u.icon(.{ .name = .check, .size = 24, .role = .danger }),
            u.icon(.{ .name = .check, .size = 24, .disabled = true }),
        })),
        try example(u, "sizes", try u.row(.{ .gap = 16 }, &.{
            u.icon(.{ .name = .play, .size = 16 }),
            u.icon(.{ .name = .play, .size = 24 }),
            u.icon(.{ .name = .play, .size = 40 }),
        })),
    });
}

/// Live examples for the Button page (#271): role variants, sizes, disabled.
fn buttonExamples(u: *ui.Ui) !Widget {
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "role variants", try u.row(.{ .gap = 10 }, &.{
            u.button(.{ .label = "Primary", .role = .primary }),
            u.button(.{ .label = "Secondary", .role = .secondary }),
            u.button(.{ .label = "Normal", .role = .normal }),
            u.button(.{ .label = "Danger", .role = .danger }),
        })),
        try example(u, "sizes", try u.row(.{ .gap = 10 }, &.{
            u.button(.{ .label = "Small", .role = .primary, .size = .small }),
            u.button(.{ .label = "Medium", .role = .primary, .size = .medium }),
            u.button(.{ .label = "Large", .role = .primary, .size = .large }),
        })),
        try example(u, "disabled (dimmed, dispatches nothing)", try u.row(.{ .gap = 10 }, &.{
            u.button(.{ .label = "Enabled", .role = .primary }),
            u.button(.{ .label = "Disabled", .role = .primary, .disabled = true }),
        })),
    });
}

/// Live examples for the Text page (#270): the semantic type scale + wrapping.
fn textExamples(u: *ui.Ui) !Widget {
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "the type scale (title / heading / body / caption)", try u.column(.{ .gap = 6 }, &.{
            u.text("Title", .{ .variant = .title }),
            u.text("Heading", .{ .variant = .heading }),
            u.text("Body text — the default paragraph style.", .{ .variant = .body }),
            u.text("Caption — secondary, smaller.", .{ .variant = .caption, .role = .secondary }),
        })),
        try example(u, "wrapping body text in a fixed-width column", try u.column(.{ .width = 360 }, &.{
            u.text("This is a longer run of body text that wraps to the content width instead of overflowing on a single line, exercising the shaping + wrap pipeline.", .{ .wrap = true }),
        })),
    });
}

/// Live examples for the Layout page (#269): row/spacer/divider in action.
fn layoutExamples(u: *ui.Ui) !Widget {
    return u.column(.{ .gap = 18 }, &.{
        try example(u, "row with a spacer pushing the ends apart", try u.row(.{}, &.{
            u.text("start", .{}),
            u.spacer(),
            u.text("end", .{}),
        })),
        try example(u, "items separated by vertical dividers", try u.row(.{ .gap = 12 }, &.{
            u.text("one", .{}),
            u.divider(.row),
            u.text("two", .{}),
            u.divider(.row),
            u.text("three", .{}),
        })),
        try example(u, "a horizontal divider between stacked rows", try u.column(.{ .gap = 10 }, &.{
            u.text("above", .{}),
            u.divider(.column),
            u.text("below", .{}),
        })),
        try example(u, "justify-content: space-between / center / end", try u.column(.{ .gap = 8 }, &.{
            try u.row(.{ .justify = .space_between }, &.{ u.text("L", .{}), u.text("R", .{}) }),
            try u.row(.{ .justify = .center }, &.{u.text("centered", .{})}),
            try u.row(.{ .justify = .end }, &.{u.text("right", .{})}),
        })),
        try example(u, "align-items: center — icon + label share a baseline", try u.row(.{ .gap = 8, .align_items = .center }, &.{
            u.icon(.{ .name = .check, .size = 28, .role = .primary }),
            u.text("vertically centered against the taller icon", .{}),
        })),
    });
}

const Msg = enum(u32) { _ };

const Docs = struct {
    selected: usize = 0,
    list_demo: usize = 1, // selected row on the List page's demo
    scroll_y: f32 = 0, // offset for the Scroll page's viewport
    sel_check: bool = false, // Selection page: checkbox
    sel_toggle: bool = true, // Selection page: toggle
    sel_radio: usize = 1, // Selection page: radio choice
    sidebar_w: f32 = 210, // resizable sidebar width (logical px)
    dragging: bool = false, // divider drag in progress
    drag_offset: f32 = 0, // pointer-to-divider gap at grab (device px), so the line tracks exactly
    scale: f32 = 1, // captured each frame so onEvent can map device px → logical

    pub fn viewUi(self: *Docs, u: *ui.Ui) !Widget {
        self.scale = u.scale; // for the divider-drag math in onEvent
        // Master: a macOS source-list — Welcome up top, then a "Components"
        // section of icon+label rows; the selected row is an accent pill. Top
        // padding clears the traffic lights under the integrated title bar.
        var rowlist: std.ArrayList(ui.ListRow) = .empty;
        var sel_row: ?usize = null;
        if (self.selected == 0) sel_row = rowlist.items.len;
        try rowlist.append(u.arena, .{ .label = pages[0].name, .icon = pages[0].icon, .on_click = 0 });
        try rowlist.append(u.arena, .{ .label = "Components", .header = true });
        for (pages[1..], 1..) |p, pi| {
            if (self.selected == pi) sel_row = rowlist.items.len;
            try rowlist.append(u.arena, .{ .label = p.name, .icon = p.icon, .on_click = @intCast(pi) });
        }
        const sidebar = try u.column(.{
            .grow = 1,
            .padding = .{ .top = 36, .left = 10, .right = 10, .bottom = 10 },
            .background = u.theme.background,
        }, &.{
            try u.list(.{ .selected = sel_row }, rowlist.items),
            u.spacer(), // pin the footer to the bottom
            u.divider(.column),
            try u.row(.{ .align_items = .center, .gap = 8, .padding = .all(6) }, &.{
                u.icon(.{ .name = .circle, .size = 16, .role = .secondary }),
                u.text("zooee", .{ .variant = .caption, .role = .secondary }),
            }),
        });

        // Detail: the selected page — heading, description, then live examples.
        const page = pages[self.selected];
        var blocks: std.ArrayList(Widget) = .empty;
        try blocks.append(u.arena, u.text(page.name, .{ .variant = .title }));
        try blocks.append(u.arena, u.text(page.body, .{ .variant = .body }));
        if (std.mem.eql(u8, page.name, "Layout")) {
            try blocks.append(u.arena, try layoutExamples(u));
        } else if (std.mem.eql(u8, page.name, "Text")) {
            try blocks.append(u.arena, try textExamples(u));
        } else if (std.mem.eql(u8, page.name, "Button")) {
            try blocks.append(u.arena, try buttonExamples(u));
        } else if (std.mem.eql(u8, page.name, "Icon")) {
            try blocks.append(u.arena, try iconExamples(u));
        } else if (std.mem.eql(u8, page.name, "List")) {
            try blocks.append(u.arena, try listExamples(u, self.list_demo));
        } else if (std.mem.eql(u8, page.name, "Scroll")) {
            try blocks.append(u.arena, try scrollExamples(u, self.scroll_y));
        } else if (std.mem.eql(u8, page.name, "Card")) {
            try blocks.append(u.arena, try cardExamples(u));
        } else if (std.mem.eql(u8, page.name, "Selection")) {
            try blocks.append(u.arena, try selectionExamples(u, self.sel_check, self.sel_toggle, self.sel_radio));
        }
        const detail = try u.column(.{ .grow = 1, .padding = .all(28), .gap = 14 }, blocks.items);

        // Resizable split: drag the divider → sidebar_w changes → relayout next frame.
        return u.split(.{ .leading_size = self.sidebar_w, .divider = 1 }, sidebar, detail);
    }

    pub fn update(self: *Docs, msg: Msg) zooee.app.Command {
        const raw: u32 = @intFromEnum(msg);
        // Selection-page controls (base 2000) — checked first (range overlaps list).
        if (raw == sel_check) {
            self.sel_check = !self.sel_check;
            return .redraw;
        } else if (raw == sel_toggle) {
            self.sel_toggle = !self.sel_toggle;
            return .redraw;
        } else if (raw >= sel_radio_base and raw < sel_radio_base + 3) {
            self.sel_radio = raw - sel_radio_base;
            return .redraw;
        }
        // List-page demo rows (base 1000) vs sidebar page selection.
        if (raw >= list_demo_base) {
            self.list_demo = raw - list_demo_base;
            return .redraw;
        }
        const i: usize = raw;
        if (i < pages.len and i != self.selected) {
            self.selected = i;
            return .redraw;
        }
        return .none;
    }

    // Sidebar resize limits (logical px).
    const sidebar_min: f32 = 150;
    const sidebar_max: f32 = 360;

    pub fn onEvent(self: *Docs, ev: zooee.event.Event) zooee.app.Command {
        switch (ev) {
            .text => |t| if (t.codepoint == 'q') return .quit,
            // Drive the Scroll page's viewport (engine clamps to content extent).
            .scroll => |s| {
                self.scroll_y = @max(0, self.scroll_y + s.dy * 12);
                return .redraw;
            },
            // Divider drag: grab near the sidebar's trailing edge, then track the
            // pointer. Pointer x is device px; sidebar_w is logical (÷ scale).
            .pointer_down => |p| {
                // Grab band covers the hairline + the divider's grab gutter (~8px).
                const edge = self.sidebar_w * self.scale;
                if (@abs(p.position.x - edge) <= 10 * self.scale) {
                    self.dragging = true;
                    self.drag_offset = p.position.x - edge; // keep the grabbed point under the cursor
                    return .redraw;
                }
            },
            .pointer_move => |p| {
                if (self.dragging) {
                    self.sidebar_w = std.math.clamp((p.position.x - self.drag_offset) / self.scale, sidebar_min, sidebar_max);
                    return .redraw;
                }
            },
            .pointer_up => {
                if (self.dragging) {
                    self.dragging = false;
                    return .redraw;
                }
            },
            else => {},
        }
        return .none;
    }

    /// The active theme (#21): widgets + the backdrop resolve from it.
    pub fn theme(self: *Docs) ui.Theme {
        _ = self;
        return ui.Theme.dark;
    }

    pub fn background(self: *Docs) Color {
        return self.theme().background; // backdrop matches the theme
    }

    /// Lock the resize cursor for the whole divider drag (#123): without this the
    /// pointer outruns the divider's hit rect and the cursor flips back.
    pub fn cursor(self: *Docs) ?zooee.Cursor {
        return if (self.dragging) .ew_resize else null;
    }
};

pub fn main(init: std.process.Init) !void {
    var docs: Docs = .{};
    try zooee.app.runWindow(Docs, Msg, &docs, init, .{
        .title = "Zooee Docs",
        .width = 900,
        .height = 600,
        .force_software = force_software,
        // Integrated: content runs under a transparent title bar (macOS source-list
        // look). The sidebar's top padding clears the traffic lights.
        .titlebar = .integrated,
    });
}
