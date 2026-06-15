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

const Page = struct { name: []const u8, body: []const u8 };
const pages = [_]Page{
    .{ .name = "Welcome", .body = "Welcome to zooee — a native, cross-platform UI in Zig.\n\nThis app is the component gallery: pick an item on the left to see it, with variants and examples. The look adapts per OS (macOS / WinUI / Linux) and is still being tuned." },
    .{ .name = "Layout", .body = "Flex containers (row / column) with gap, padding, and grow. `spacer()` fills free space to push siblings apart; `divider()` draws a 1px rule across the cross axis." },
    .{ .name = "Button", .body = "Buttons trigger actions. Variants: primary, secondary, danger. (Live examples land as the Button component is built, #271.)" },
    .{ .name = "Icon", .body = "Vector icons drawn with the path renderer. They tint with the current role and dim when disabled. Starter set: plus, check, play, chevron." },
    .{ .name = "Text", .body = "Text and labels: titles, headings, body, captions — with the shaping pipeline (Latin, Arabic, BiDi). (#270)" },
    .{ .name = "List", .body = "A selectable list — the master/nav pattern. Each row dispatches on click; the selected row is highlighted. (The sidebar on the left is itself a List.) Virtualization (#29) and keyboard nav (#16) are follow-ups." },
    .{ .name = "Card", .body = "Surfaces/cards: background, border, corner radius, elevation — the detail content blocks. (#275)" },
};

/// A labelled example block: a caption above a bordered demo surface.
fn example(u: *ui.Ui, caption: []const u8, demo: Widget) !Widget {
    return u.column(.{ .gap = 6 }, &.{
        u.text(caption, .{ .variant = .caption, .role = .secondary }),
        try u.column(.{
            .padding = .all(16),
            .background = Color.rgb(32, 32, 38),
            .corner_radius = 8,
        }, &.{demo}),
    });
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
    });
}

const Msg = enum(u32) { _ };

const Docs = struct {
    selected: usize = 0,
    list_demo: usize = 1, // selected row on the List page's demo

    pub fn viewUi(self: *Docs, u: *ui.Ui) !Widget {
        // Master: a selectable list of pages — dogfooding the List widget (#273).
        const rows = try u.arena.alloc(ui.ListRow, pages.len);
        for (pages, 0..) |p, i| rows[i] = .{ .label = p.name, .on_click = @intCast(i) };
        const sidebar = try u.column(.{
            .width = 210,
            .padding = .all(12),
            .background = Color.rgb(28, 28, 32),
        }, &.{
            try u.list(.{ .selected = self.selected, .width = 186 }, rows),
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
        }
        const detail = try u.column(.{ .grow = 1, .padding = .all(28), .gap = 14 }, blocks.items);

        return u.row(.{}, &.{ sidebar, detail });
    }

    pub fn update(self: *Docs, msg: Msg) zooee.app.Command {
        const raw: u32 = @intFromEnum(msg);
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

    pub fn onEvent(self: *Docs, ev: zooee.event.Event) zooee.app.Command {
        _ = self;
        switch (ev) {
            .text => |t| if (t.codepoint == 'q') return .quit,
            else => {},
        }
        return .none;
    }

    pub fn background(self: *Docs) Color {
        _ = self;
        return Color.rgb(20, 20, 24); // provisional dark backdrop
    }
};

pub fn main(init: std.process.Init) !void {
    var docs: Docs = .{};
    try zooee.app.runWindow(Docs, Msg, &docs, init, .{
        .title = "Zooee Docs",
        .width = 900,
        .height = 600,
        .force_software = force_software,
        // Native titlebar for now; the per-OS custom titlebar (#64/#268) is a QA-phase tweak.
        .titlebar = .native,
    });
}
