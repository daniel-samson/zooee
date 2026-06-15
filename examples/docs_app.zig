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
    .{ .name = "Button", .body = "Buttons trigger actions. Variants: primary, secondary, danger. (Live examples land as the Button component is built, #271.)" },
    .{ .name = "Text", .body = "Text and labels: titles, headings, body, captions — with the shaping pipeline (Latin, Arabic, BiDi). (#270)" },
    .{ .name = "List", .body = "A virtualized list: the master/nav pattern, only visible rows built. (#273)" },
    .{ .name = "Card", .body = "Surfaces/cards: background, border, corner radius, elevation — the detail content blocks. (#275)" },
};

const Msg = enum(u32) { _ };

const Docs = struct {
    selected: usize = 0,

    pub fn viewUi(self: *Docs, u: *ui.Ui) !Widget {
        // Master: a sidebar of nav buttons (the selected one highlighted).
        const items = try u.arena.alloc(Widget, pages.len);
        for (pages, 0..) |p, i| {
            items[i] = u.button(.{
                .label = p.name,
                .role = if (i == self.selected) .primary else .secondary,
                .on_click = @intCast(i),
            });
        }
        const sidebar = try u.column(.{
            .width = 210,
            .padding = .all(12),
            .gap = 6,
            .background = Color.rgb(28, 28, 32),
        }, items);

        // Detail: the selected page.
        const page = pages[self.selected];
        const detail = try u.column(.{ .grow = 1, .padding = .all(28), .gap = 14 }, &.{
            u.text(page.name, .{ .size = 28, .bold = true }),
            u.text(page.body, .{ .size = 15 }),
        });

        return u.row(.{}, &.{ sidebar, detail });
    }

    pub fn update(self: *Docs, msg: Msg) zooee.app.Command {
        const i: usize = @intFromEnum(msg);
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
