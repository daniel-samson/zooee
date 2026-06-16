//! Interactive layout playground (#306 / #303): on-screen controls to tweak the
//! box-model properties live (direction, justify, align, gap, padding, child
//! count, text wrap) with a preview that draws the resulting boxes + a wrapping
//! paragraph. A tool for dialing in / verifying layout behavior on-device, and a
//! test bed for the wrapping work (#304). Controls + state are deterministically
//! Driver-testable; the visual is author-judged.

const std = @import("std");
const zooee = @import("zooee");
const ui = zooee.ui;
const Widget = ui.Widget;
const Color = zooee.Color;

const force_software = @import("build_options").force_software;

const Msg = enum(u32) {
    dir_toggle = 1,
    justify_cycle = 2,
    align_cycle = 3,
    wrap_toggle = 4,
    gap_dec = 5,
    gap_inc = 6,
    pad_dec = 7,
    pad_inc = 8,
    count_dec = 9,
    count_inc = 10,
    dump = 11,
    snapshot = 12,
    boxwrap_toggle = 13,
    _,
};

/// Distinct fills so each preview box is visible.
const palette = [_]Color{
    Color.rgb(10, 132, 255), Color.rgb(255, 69, 58),  Color.rgb(48, 209, 88),
    Color.rgb(255, 159, 10), Color.rgb(191, 90, 242), Color.rgb(100, 210, 255),
};

const Play = struct {
    dir: ui.Direction = .row,
    justify: ui.Justify = .start,
    align_items: ui.AlignItems = .stretch,
    wrap: bool = false,
    box_wrap: bool = false,
    gap: f32 = 8,
    pad: f32 = 12,
    count: usize = 3,
    // Debug-export plumbing (set in main): write paired screenshot + config to
    // ./zooee-debug/ so issues can be handed back as data, not a live window.
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    pub fn theme(self: *Play) ui.Theme {
        _ = self;
        return ui.Theme.dark;
    }
    pub fn background(self: *Play) Color {
        return self.theme().background;
    }

    pub fn viewUi(self: *Play, u: *ui.Ui) !Widget {
        // --- controls panel -------------------------------------------------
        const controls = try u.column(.{ .width = 280, .padding = .all(16), .gap = 10, .background = u.theme.surface }, &.{
            u.text("Layout", .{ .variant = .heading }),
            try cycleRow(u, "direction", @tagName(self.dir), @intFromEnum(Msg.dir_toggle)),
            try cycleRow(u, "justify", @tagName(self.justify), @intFromEnum(Msg.justify_cycle)),
            try cycleRow(u, "align", @tagName(self.align_items), @intFromEnum(Msg.align_cycle)),
            try stepRow(u, "gap", u.fmt("{d:.0}", .{self.gap}), @intFromEnum(Msg.gap_dec), @intFromEnum(Msg.gap_inc)),
            try stepRow(u, "padding", u.fmt("{d:.0}", .{self.pad}), @intFromEnum(Msg.pad_dec), @intFromEnum(Msg.pad_inc)),
            try stepRow(u, "boxes", u.fmt("{d}", .{self.count}), @intFromEnum(Msg.count_dec), @intFromEnum(Msg.count_inc)),
            try u.row(.{ .align_items = .center, .gap = 8 }, &.{
                try u.toggle(.{ .checked = self.box_wrap, .on_change = @intFromEnum(Msg.boxwrap_toggle) }),
                u.text("wrap boxes (flex-wrap)", .{}),
            }),
            try u.row(.{ .align_items = .center, .gap = 8 }, &.{
                try u.toggle(.{ .checked = self.wrap, .on_change = @intFromEnum(Msg.wrap_toggle) }),
                u.text("wrap text", .{}),
            }),
            u.spacer(),
            u.divider(.column),
            u.text("debug export → ./zooee-debug/", .{ .variant = .caption, .role = .secondary }),
            try u.row(.{ .gap = 8 }, &.{
                u.button(.{ .label = "Dump", .role = .secondary, .size = .small, .on_click = @intFromEnum(Msg.dump) }),
                u.button(.{ .label = "Screenshot", .role = .primary, .size = .small, .on_click = @intFromEnum(Msg.snapshot) }),
            }),
        });

        // --- preview --------------------------------------------------------
        const boxes = try u.arena.alloc(Widget, self.count);
        for (0..self.count) |i| {
            boxes[i] = try u.column(.{
                .width = 70,
                .height = 48,
                .corner_radius = 6,
                .justify = .center,
                .align_items = .center,
                .background = palette[i % palette.len],
            }, &.{u.text(u.fmt("{d}", .{i + 1}), .{ .bold = true })});
        }
        const cfg: ui.Box = .{
            .direction = self.dir,
            .grow = 1,
            .gap = self.gap,
            .padding = .all(self.pad),
            .justify = self.justify,
            .align_items = self.align_items,
            .wrap = if (self.box_wrap) .wrap else .nowrap,
            .background = u.theme.surface_variant,
            .corner_radius = 8,
        };
        const configured = if (self.dir == .row) try u.row(cfg, boxes) else try u.column(cfg, boxes);

        const wrap_demo = try u.column(.{ .width = 360, .padding = .all(12), .background = u.theme.surface, .corner_radius = 8 }, &.{
            u.text("This paragraph wraps to the box width when wrap is on; otherwise it stays a single line and overflows. Toggle it on the left.", .{ .wrap = self.wrap }),
        });

        const preview = try u.column(.{ .grow = 1, .padding = .all(16), .gap = 16 }, &.{
            u.text("preview", .{ .variant = .caption, .role = .secondary }),
            configured,
            wrap_demo,
        });

        return u.row(.{ .grow = 1 }, &.{ controls, preview });
    }

    pub fn update(self: *Play, msg: Msg) zooee.app.Command {
        switch (msg) {
            .dir_toggle => self.dir = if (self.dir == .row) .column else .row,
            .justify_cycle => self.justify = nextJustify(self.justify),
            .align_cycle => self.align_items = nextAlign(self.align_items),
            .wrap_toggle => self.wrap = !self.wrap,
            .boxwrap_toggle => self.box_wrap = !self.box_wrap,
            .gap_dec => self.gap = @max(0, self.gap - 4),
            .gap_inc => self.gap = @min(64, self.gap + 4),
            .pad_dec => self.pad = @max(0, self.pad - 4),
            .pad_inc => self.pad = @min(64, self.pad + 4),
            .count_dec => self.count = if (self.count > 1) self.count - 1 else 1,
            .count_inc => self.count = @min(palette.len, self.count + 1),
            .dump => {
                self.printConfig();
                return .none;
            },
            .snapshot => {
                self.exportSnapshot();
                return .none;
            },
            _ => return .none,
        }
        return .redraw;
    }

    /// The current control values as one line.
    fn configLine(self: *Play, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "direction={s} justify={s} align={s} wrap={} gap={d:.0} padding={d:.0} boxes={d}", .{
            @tagName(self.dir), @tagName(self.justify), @tagName(self.align_items),
            self.wrap,          self.gap,               self.pad,
            self.count,
        }) catch "(config too long)";
    }

    fn printConfig(self: *Play) void {
        var buf: [256]u8 = undefined;
        std.debug.print("[playground] {s}\n", .{self.configLine(&buf)});
    }

    /// Write a paired screenshot (shot-N.png via `screencapture`) + the config
    /// that produced it (state-N.txt) into ./zooee-debug/ for hand-back.
    fn exportSnapshot(self: *Play) void {
        std.Io.Dir.cwd().createDirPath(self.io, "zooee-debug") catch {};
        // Monotonic ns stamp: strictly increasing → unique across runs (no
        // overwrite) and sorts by recency; shot + state share it so they pair.
        const stamp = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        var nbuf: [64]u8 = undefined;
        var pbuf: [64]u8 = undefined;
        var cbuf: [256]u8 = undefined;
        var dbuf: [300]u8 = undefined;
        const cfg = self.configLine(&cbuf);
        const state_path = std.fmt.bufPrint(&nbuf, "zooee-debug/state-{d}.txt", .{stamp}) catch return;
        const data = std.fmt.bufPrint(&dbuf, "{s}\n", .{cfg}) catch cfg;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = state_path, .data = data }) catch {};
        std.debug.print("[playground] snapshot {d}: {s}\n", .{ stamp, cfg });
        // Window-only PNG via `screencapture -l<windowID>` (-o omits the drop
        // shadow). Falls back to full-screen if the key window id is unavailable.
        // Needs Screen Recording permission.
        const shot_path = std.fmt.bufPrint(&pbuf, "zooee-debug/shot-{d}.png", .{stamp}) catch return;
        var idbuf: [24]u8 = undefined;
        const result = if (zooee.app.keyWindowId()) |wid|
            std.process.run(self.gpa, self.io, .{ .argv = &.{ "screencapture", "-o", "-x", "-l", std.fmt.bufPrint(&idbuf, "{d}", .{wid}) catch return, shot_path } })
        else
            std.process.run(self.gpa, self.io, .{ .argv = &.{ "screencapture", "-x", shot_path } });
        if (result) |r| {
            self.gpa.free(r.stdout);
            self.gpa.free(r.stderr);
        } else |_| {}
    }

    pub fn onEvent(self: *Play, ev: zooee.event.Event) zooee.app.Command {
        _ = self;
        switch (ev) {
            .text => |t| if (t.codepoint == 'q') return .quit,
            else => {},
        }
        return .none;
    }
};

fn nextJustify(j: ui.Justify) ui.Justify {
    return switch (j) {
        .start => .center,
        .center => .end,
        .end => .space_between,
        .space_between => .start,
    };
}
fn nextAlign(a: ui.AlignItems) ui.AlignItems {
    return switch (a) {
        .stretch => .start,
        .start => .center,
        .center => .end,
        .end => .stretch,
    };
}

/// A labelled control whose value is a button that cycles on click.
fn cycleRow(u: *ui.Ui, label: []const u8, value: []const u8, msg: u32) !Widget {
    return u.row(.{ .align_items = .center, .gap = 8 }, &.{
        try u.column(.{ .width = 78 }, &.{u.text(label, .{ .role = .secondary })}),
        u.button(.{ .label = value, .role = .secondary, .size = .small, .on_click = msg }),
    });
}

/// A labelled −/value/+ stepper.
fn stepRow(u: *ui.Ui, label: []const u8, value: []const u8, dec: u32, inc: u32) !Widget {
    return u.row(.{ .align_items = .center, .gap = 8 }, &.{
        try u.column(.{ .width = 78 }, &.{u.text(label, .{ .role = .secondary })}),
        u.button(.{ .label = "-", .role = .secondary, .size = .small, .on_click = dec }),
        try u.column(.{ .width = 34, .align_items = .center }, &.{u.text(value, .{})}),
        u.button(.{ .label = "+", .role = .secondary, .size = .small, .on_click = inc }),
    });
}

pub fn main(init: std.process.Init) !void {
    var play: Play = .{ .gpa = init.arena.allocator(), .io = init.io };
    try zooee.app.runWindow(Play, Msg, &play, init, .{
        .title = "Zooee Layout Playground",
        .width = 960,
        .height = 600,
        .force_software = force_software,
        .titlebar = .native,
    });
}
