//! Interactive layout playground (#306 / #303): on-screen controls to tweak the
//! box-model properties live (direction, justify, align, gap, padding, child
//! count, text wrap, overflow) with a single preview container that draws the
//! resulting text-filled boxes. A tool for dialing in / verifying layout
//! behaviour on-device, and a test bed for wrap (#304) / flex-wrap (#308) /
//! overflow (#309). Controls + state are deterministically
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
    overflow_cycle = 14,
    overflowx_cycle = 15,
    scroll_region = 16,
    _,
};

/// Distinct fills so each preview box is visible.
const palette = [_]Color{
    Color.rgb(10, 132, 255), Color.rgb(255, 69, 58),  Color.rgb(48, 209, 88),
    Color.rgb(255, 159, 10), Color.rgb(191, 90, 242), Color.rgb(100, 210, 255),
};

/// Filler copy for each box: long enough that "wrap text" visibly reflows it
/// and a few boxes overflow the container (so overflow/scroll is exercised).
const sample_text = "The quick brown fox jumps over the lazy dog near the riverbank.";

const Play = struct {
    dir: ui.Direction = .row,
    justify: ui.Justify = .start,
    align_items: ui.AlignItems = .stretch,
    wrap: bool = false,
    box_wrap: bool = false,
    // Default to scroll so the container visibly clips + pans on open; cycle the
    // overflow controls to visible to see content spill (CSS default).
    overflow_x: ui.Overflow = .scroll,
    overflow_y: ui.Overflow = .scroll,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    // Device scale captured from the Ui each frame, so the scroll handler can
    // convert the engine's device-px scroll range back to the logical offsets
    // this model stores.
    last_scale: f32 = 1,
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
        self.last_scale = u.scale;
        // --- controls panel -------------------------------------------------
        const controls = try u.column(.{ .width = 280, .padding = .all(16), .gap = 10, .background = u.theme.surface }, &.{
            u.text("Layout", .{ .variant = .heading }),
            try cycleRow(u, "direction", @tagName(self.dir), @intFromEnum(Msg.dir_toggle)),
            try cycleRow(u, "justify", @tagName(self.justify), @intFromEnum(Msg.justify_cycle)),
            try cycleRow(u, "align", @tagName(self.align_items), @intFromEnum(Msg.align_cycle)),
            try cycleRow(u, "overflow-x", @tagName(self.overflow_x), @intFromEnum(Msg.overflowx_cycle)),
            try cycleRow(u, "overflow-y", @tagName(self.overflow_y), @intFromEnum(Msg.overflow_cycle)),
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
        // One test surface: a fixed-size flex container (surface_variant fill, so
        // its edges read against the background) holding text-filled boxes. It
        // exercises every box-model knob at once —
        // direction / justify / align / gap / padding / flex-wrap on the layout,
        // text wrap inside each box, and overflow (clip + wheel-scroll) when the
        // boxes exceed the container.
        const boxes = try u.arena.alloc(Widget, self.count);
        for (0..self.count) |i| {
            boxes[i] = try u.column(.{
                .width = 150,
                .padding = .all(10),
                .gap = 6,
                .corner_radius = 6,
                .background = palette[i % palette.len],
            }, &.{
                u.text(u.fmt("Box {d}", .{i + 1}), .{ .bold = true }),
                u.text(sample_text, .{ .wrap = self.wrap }),
            });
        }
        const cfg: ui.Box = .{
            .direction = self.dir,
            .width = 460,
            .height = 360,
            .gap = self.gap,
            .padding = .all(self.pad),
            .justify = self.justify,
            .align_items = self.align_items,
            .wrap = if (self.box_wrap) .wrap else .nowrap,
            .overflow_x = self.overflow_x,
            .overflow_y = self.overflow_y,
            .scroll_x = self.scroll_x,
            .scroll_y = self.scroll_y,
            .background = u.theme.surface_variant,
            .corner_radius = 8,
            // Only react to the wheel while the pointer is over this container,
            // so scrolling the controls panel doesn't pan the preview (#309).
            .on_scroll = @intFromEnum(Msg.scroll_region),
        };
        const configured = if (self.dir == .row) try u.row(cfg, boxes) else try u.column(cfg, boxes);

        const preview = try u.column(.{ .grow = 1, .padding = .all(16), .gap = 12 }, &.{
            u.text("preview — scroll with the wheel; toggles + overflow controls on the left", .{ .variant = .caption, .role = .secondary }),
            configured,
        });

        return u.row(.{ .grow = 1 }, &.{ controls, preview });
    }

    pub fn update(self: *Play, msg: Msg) zooee.app.Command {
        switch (msg) {
            .dir_toggle => {
                self.dir = if (self.dir == .row) .column else .row;
                // Reset the offset: the old scroll position is meaningless once
                // the main axis flips, and a stale offset can leave the viewport
                // scrolled into empty space (looks like "boxes disappeared").
                self.scroll_x = 0;
                self.scroll_y = 0;
            },
            .justify_cycle => self.justify = nextJustify(self.justify),
            .align_cycle => self.align_items = nextAlign(self.align_items),
            .wrap_toggle => self.wrap = !self.wrap,
            .boxwrap_toggle => self.box_wrap = !self.box_wrap,
            .overflow_cycle => self.overflow_y = nextOverflow(self.overflow_y),
            .overflowx_cycle => self.overflow_x = nextOverflow(self.overflow_x),
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
            .scroll_region => return .none, // handled in onEvent, never via update
            _ => return .none,
        }
        return .redraw;
    }

    /// The current control values as one line.
    fn configLine(self: *Play, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "direction={s} justify={s} align={s} text-wrap={} flex-wrap={} overflow=({s},{s}) scroll=({d:.0},{d:.0}) gap={d:.0} padding={d:.0} boxes={d}", .{
            @tagName(self.dir),       @tagName(self.justify),    @tagName(self.align_items),
            self.wrap,                self.box_wrap,             @tagName(self.overflow_x),
            @tagName(self.overflow_y), self.scroll_x,            self.scroll_y,
            self.gap,                 self.pad,                  self.count,
        }) catch "(config too long)";
    }

    fn printConfig(self: *Play) void {
        var buf: [384]u8 = undefined;
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
        var cbuf: [384]u8 = undefined;
        var dbuf: [400]u8 = undefined;
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
        switch (ev) {
            .text => |t| if (t.codepoint == 'q') return .quit,
            .scroll => |s| {
                // Wheel pans the container. Lines → ~20px each; pixels 1:1. The
                // engine clamps the offset to content at render; we keep a
                // generous local clamp so the stored value can't run away.
                // Our ScrollEvent dy/dx already reflects the OS natural-scroll
                // setting (AppKit pre-inverts scrollingDelta), so add it to the
                // offset directly — a downward swipe reveals later content.
                const step: f32 = if (s.unit == .line) 20 else 1;
                // Clamp to the engine's real scrollable range (device px → logical)
                // so the offset can't over-scroll into dead range: once at the end,
                // scrolling back responds immediately instead of unwinding phantom
                // distance. Falls back to a generous bound before the first render.
                const sc = if (self.last_scale > 0) self.last_scale else 1;
                const rng = zooee.layout.lastScrollMax();
                const max_x = if (rng.width > 0) rng.width / sc else 4000;
                const max_y = if (rng.height > 0) rng.height / sc else 4000;
                self.scroll_y = std.math.clamp(self.scroll_y + s.dy * step, 0, max_y);
                self.scroll_x = std.math.clamp(self.scroll_x + s.dx * step, 0, max_x);
                return .redraw;
            },
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
fn nextOverflow(o: ui.Overflow) ui.Overflow {
    return switch (o) {
        .visible => .hidden,
        .hidden => .scroll,
        .scroll => .auto,
        .auto => .visible,
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

/// Apply a `ZOOEE_PLAY` override string so a single config can be rendered
/// headlessly (with ZOOEE_CAPTURE) for self-verification — no clicking needed.
/// Format: comma-separated `key=value`, e.g.
///   ZOOEE_PLAY="dir=column,oy=scroll,sy=80,count=6,wrap=1"
/// Keys: dir(row|column) justify align ox oy(visible|hidden|scroll|auto)
///       sx sy gap pad (floats) count(int) wrap boxwrap(0|1).
fn applyEnv(self: *Play, spec: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        const ovf = struct {
            fn parse(s: []const u8) ?ui.Overflow {
                return std.meta.stringToEnum(ui.Overflow, s);
            }
        };
        if (std.mem.eql(u8, k, "dir")) {
            self.dir = std.meta.stringToEnum(ui.Direction, v) orelse self.dir;
        } else if (std.mem.eql(u8, k, "justify")) {
            self.justify = std.meta.stringToEnum(ui.Justify, v) orelse self.justify;
        } else if (std.mem.eql(u8, k, "align")) {
            self.align_items = std.meta.stringToEnum(ui.AlignItems, v) orelse self.align_items;
        } else if (std.mem.eql(u8, k, "ox")) {
            self.overflow_x = ovf.parse(v) orelse self.overflow_x;
        } else if (std.mem.eql(u8, k, "oy")) {
            self.overflow_y = ovf.parse(v) orelse self.overflow_y;
        } else if (std.mem.eql(u8, k, "sx")) {
            self.scroll_x = std.fmt.parseFloat(f32, v) catch self.scroll_x;
        } else if (std.mem.eql(u8, k, "sy")) {
            self.scroll_y = std.fmt.parseFloat(f32, v) catch self.scroll_y;
        } else if (std.mem.eql(u8, k, "gap")) {
            self.gap = std.fmt.parseFloat(f32, v) catch self.gap;
        } else if (std.mem.eql(u8, k, "pad")) {
            self.pad = std.fmt.parseFloat(f32, v) catch self.pad;
        } else if (std.mem.eql(u8, k, "count")) {
            self.count = std.fmt.parseInt(usize, v, 10) catch self.count;
        } else if (std.mem.eql(u8, k, "wrap")) {
            self.wrap = !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "boxwrap")) {
            self.box_wrap = !std.mem.eql(u8, v, "0");
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var play: Play = .{ .gpa = init.arena.allocator(), .io = init.io };
    if (init.environ_map.get("ZOOEE_PLAY")) |spec| applyEnv(&play, spec);
    try zooee.app.runWindow(Play, Msg, &play, init, .{
        .title = "Zooee Layout Playground",
        .width = 960,
        .height = 600,
        .force_software = force_software,
        .titlebar = .native,
    });
}
