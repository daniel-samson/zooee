//! Terminal backend (#7): renders the draw-primitive interface into a
//! grid of character cells.
//!
//! Fidelity rules (per the design record on #2):
//! - 1 unit = 1 cell; `snap` rounds to whole cells.
//! - Any `Border.width > 0` renders as one cell of box-drawing characters;
//!   `corner_radius > 0` degrades to rounded corners (╭─╮ ╰─╯).
//! - Text places one codepoint per cell. Wide/zero-width handling is #18.
//! - Images fill their rect with a placeholder shade; half-block
//!   rendering is a follow-up on #7.
//!
//! The cell buffer is the testable unit (#8): `renderToText` dumps the
//! screen as plain text for snapshot tests, no TTY involved. `present`
//! emits ANSI escapes for a full redraw to any `std.Io.Writer`;
//! diff-based presentation is a follow-up on #7.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend = @import("../backend.zig");

const Backend = backend.Backend;
const Color = style.Color;
const Rect = geometry.Rect;

/// Prepare the hosting console for zooee output. On Windows this switches
/// the console output codepage to UTF-8 — without it, legacy conhost
/// renders box-drawing characters as OEM-codepage mojibake. No-op
/// elsewhere. Call once at startup before presenting.
pub fn setupConsole() void {
    if (@import("builtin").os.tag == .windows) {
        const CP_UTF8: u32 = 65001;
        _ = (struct {
            extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) std.os.windows.BOOL;
        }).SetConsoleOutputCP(CP_UTF8);
    }
}

pub const Cell = struct {
    cp: u21 = ' ',
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,

    pub const blank: Cell = .{};
};

/// Integer cell-space rectangle, the result of quantizing a draw rect.
const CellRect = struct {
    x0: i32,
    y0: i32,
    x1: i32, // exclusive
    y1: i32, // exclusive

    fn fromRect(r: Rect) CellRect {
        return .{
            .x0 = @intFromFloat(@round(r.x)),
            .y0 = @intFromFloat(@round(r.y)),
            .x1 = @intFromFloat(@round(r.x + r.width)),
            .y1 = @intFromFloat(@round(r.y + r.height)),
        };
    }

    fn intersect(self: CellRect, other: CellRect) CellRect {
        return .{
            .x0 = @max(self.x0, other.x0),
            .y0 = @max(self.y0, other.y0),
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
        };
    }

    fn isEmpty(self: CellRect) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }
};

pub const TerminalBackend = struct {
    gpa: std.mem.Allocator,
    width: usize = 0,
    height: usize = 0,
    cells: []Cell = &.{},
    clip_stack: std.ArrayList(CellRect) = .empty,
    textures: std.AutoHashMapUnmanaged(u32, void) = .empty,
    next_texture_id: u32 = 1,
    in_frame: bool = false,
    /// Default cell background (theming): empty cells paint this so the theme
    /// backdrop fills the whole TUI, not just where rects draw. Null = the
    /// terminal's own background (the historical behavior).
    clear_color: ?Color = null,

    pub fn init(gpa: std.mem.Allocator) TerminalBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TerminalBackend) void {
        self.gpa.free(self.cells);
        self.clip_stack.deinit(self.gpa);
        self.textures.deinit(self.gpa);
    }

    pub fn interface(self: *TerminalBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .begin_frame = beginFrame,
        .end_frame = endFrame,
        .draw_rect = drawRect,
        .draw_text = drawText,
        .draw_image = drawImage,
        .push_clip = pushClip,
        .pop_clip = popClip,
        .create_texture = createTexture,
        .destroy_texture = destroyTexture,
        .measure_text = measureText,
        .snap = snap,
    };

    fn self_(ptr: *anyopaque) *TerminalBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn screenRect(self: *const TerminalBackend) CellRect {
        return .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
    }

    /// Current effective clip: screen ∩ all pushed clips.
    fn currentClip(self: *const TerminalBackend) CellRect {
        var clip = self.screenRect();
        for (self.clip_stack.items) |c| clip = clip.intersect(c);
        return clip;
    }

    fn cellAt(self: *TerminalBackend, x: i32, y: i32) *Cell {
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        return &self.cells[uy * self.width + ux];
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(!self.in_frame);
        const w: usize = @intFromFloat(@max(0, @round(viewport.width)));
        const h: usize = @intFromFloat(@max(0, @round(viewport.height)));
        if (w != self.width or h != self.height) {
            self.gpa.free(self.cells);
            self.cells = self.gpa.alloc(Cell, w * h) catch return error.OutOfMemory;
            self.width = w;
            self.height = h;
        }
        const fill: Cell = if (self.clear_color) |c| .{ .cp = ' ', .bg = c } else Cell.blank;
        @memset(self.cells, fill);
        self.in_frame = true;
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(self.in_frame);
        std.debug.assert(self.clip_stack.items.len == 0);
        self.in_frame = false;
    }

    fn drawRect(ptr: *anyopaque, rect: Rect, rect_style: style.RectStyle) void {
        const self = self_(ptr);
        const r = CellRect.fromRect(rect);
        const clip = self.currentClip();
        const visible = r.intersect(clip);
        if (visible.isEmpty()) return;

        if (rect_style.background) |bg| {
            var y = visible.y0;
            while (y < visible.y1) : (y += 1) {
                var x = visible.x0;
                while (x < visible.x1) : (x += 1) {
                    const cell = self.cellAt(x, y);
                    cell.* = .{ .cp = ' ', .bg = bg };
                }
            }
        }

        if (!rect_style.border.isNone() and r.x1 - r.x0 >= 2 and r.y1 - r.y0 >= 2) {
            self.drawBorder(r, clip, rect_style);
        }
    }

    fn drawBorder(self: *TerminalBackend, r: CellRect, clip: CellRect, rect_style: style.RectStyle) void {
        const b = rect_style.border;
        const radius = rect_style.corner_radius;
        const bg = rect_style.background;

        const put = struct {
            fn put(s: *TerminalBackend, c: CellRect, x: i32, y: i32, cp: u21, fg_: Color, bg_: ?Color) void {
                if (x < c.x0 or x >= c.x1 or y < c.y0 or y >= c.y1) return;
                s.cellAt(x, y).* = .{ .cp = cp, .fg = fg_, .bg = bg_ };
            }
        }.put;

        // Sides: a side with width 0 simply isn't drawn (terminal
        // quantizes any positive width to one cell).
        var x = r.x0 + 1;
        while (x < r.x1 - 1) : (x += 1) {
            if (b.top.width > 0) put(self, clip, x, r.y0, '─', b.top.color, bg);
            if (b.bottom.width > 0) put(self, clip, x, r.y1 - 1, '─', b.bottom.color, bg);
        }
        var y = r.y0 + 1;
        while (y < r.y1 - 1) : (y += 1) {
            if (b.left.width > 0) put(self, clip, r.x0, y, '│', b.left.color, bg);
            if (b.right.width > 0) put(self, clip, r.x1 - 1, y, '│', b.right.color, bg);
        }

        // Corners: drawn where both adjacent sides exist; rounded per
        // corner; color precedence: the horizontal (top/bottom) side wins.
        if (b.top.width > 0 and b.left.width > 0)
            put(self, clip, r.x0, r.y0, if (radius.top_left > 0) '╭' else '┌', b.top.color, bg);
        if (b.top.width > 0 and b.right.width > 0)
            put(self, clip, r.x1 - 1, r.y0, if (radius.top_right > 0) '╮' else '┐', b.top.color, bg);
        if (b.bottom.width > 0 and b.left.width > 0)
            put(self, clip, r.x0, r.y1 - 1, if (radius.bottom_left > 0) '╰' else '└', b.bottom.color, bg);
        if (b.bottom.width > 0 and b.right.width > 0)
            put(self, clip, r.x1 - 1, r.y1 - 1, if (radius.bottom_right > 0) '╯' else '┘', b.bottom.color, bg);
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, text_style: style.TextStyle) void {
        const self = self_(ptr);
        const clip = self.currentClip();
        const y: i32 = @intFromFloat(@round(origin.y));
        if (y < clip.y0 or y >= clip.y1) return;

        var x: i32 = @intFromFloat(@round(origin.x));
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| : (x += 1) {
            if (x < clip.x0) continue;
            if (x >= clip.x1) break;
            const cell = self.cellAt(x, y);
            cell.cp = cp;
            cell.fg = text_style.color; // null = terminal default fg
            cell.bold = text_style.bold;
        }
    }

    fn drawImage(ptr: *anyopaque, rect: Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const id: u32 = @intCast(@intFromPtr(texture));
        std.debug.assert(self.textures.contains(id));
        // Placeholder fidelity; half-block image rendering is a #7 follow-up.
        const visible = CellRect.fromRect(rect).intersect(self.currentClip());
        if (visible.isEmpty()) return;
        var y = visible.y0;
        while (y < visible.y1) : (y += 1) {
            var x = visible.x0;
            while (x < visible.x1) : (x += 1) {
                self.cellAt(x, y).* = .{ .cp = '▒' };
            }
        }
    }

    fn pushClip(ptr: *anyopaque, rect: Rect) void {
        const self = self_(ptr);
        self.clip_stack.append(self.gpa, CellRect.fromRect(rect)) catch {};
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        std.debug.assert(self.clip_stack.items.len > 0);
        _ = self.clip_stack.pop();
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Backend.Error!*Backend.Texture {
        const self = self_(ptr);
        _ = width;
        _ = height;
        _ = rgba;
        const id = self.next_texture_id;
        self.next_texture_id += 1;
        self.textures.put(self.gpa, id, {}) catch return error.OutOfMemory;
        return @ptrFromInt(id);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        const self = self_(ptr);
        std.debug.assert(self.textures.remove(@intCast(@intFromPtr(texture))));
    }

    fn measureText(ptr: *anyopaque, text: []const u8, text_style: style.TextStyle) geometry.Size {
        _ = ptr;
        _ = text_style;
        // Codepoint count; East Asian width and grapheme clusters are #18.
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return .{ .width = @floatFromInt(n), .height = 1 };
    }

    fn snap(ptr: *anyopaque, value: f32, axis: geometry.Axis) f32 {
        _ = ptr;
        _ = axis;
        return @round(value);
    }

    /// Dump the cell buffer as plain text (one line per row, no trailing
    /// spaces) — the snapshot-test surface (#8).
    pub fn renderToText(self: *const TerminalBackend, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var line_end: usize = 0;
            for (self.cells[y * self.width ..][0..self.width], 0..) |cell, i| {
                if (cell.cp != ' ') line_end = i + 1;
            }
            for (self.cells[y * self.width ..][0..line_end]) |cell| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..n]);
            }
            try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }

    /// Emit a full-redraw of the cell buffer as ANSI escapes (truecolor).
    /// Diff-based presentation replaces this on #7.
    pub fn present(self: *const TerminalBackend, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b[H");
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            if (y != 0) try writer.writeAll("\r\n");
            var last_fg: ?Color = null;
            var last_bg: ?Color = null;
            var first = true;
            for (self.cells[y * self.width ..][0..self.width]) |cell| {
                const fg_changed = !colorEq(cell.fg, last_fg);
                const bg_changed = !colorEq(cell.bg, last_bg);
                if (first or fg_changed or bg_changed) {
                    try writer.writeAll("\x1b[0m");
                    if (cell.fg) |c| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
                    if (cell.bg) |c| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
                    last_fg = cell.fg;
                    last_bg = cell.bg;
                    first = false;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch unreachable;
                try writer.writeAll(buf[0..n]);
            }
        }
        try writer.writeAll("\x1b[0m");
    }

    fn colorEq(a: ?Color, b: ?Color) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.meta.eql(a.?, b.?);
    }
};

// ---------------------------------------------------------------------------
// Snapshot tests (#8): render a scene, assert the screen text.
// ---------------------------------------------------------------------------

fn expectScreen(term: *const TerminalBackend, expected: []const u8) !void {
    const actual = try term.renderToText(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "bordered rect with rounded corners" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 12, .height = 4 });
    b.drawRect(
        .{ .x = 1, .y = 0, .width = 8, .height = 4 },
        .{ .border = .all(1, .black), .corner_radius = .all(2) },
    );
    try b.endFrame();

    try expectScreen(&term,
        \\ ╭──────╮
        \\ │      │
        \\ │      │
        \\ ╰──────╯
        \\
    );
}

test "square corners when radius is zero" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 6, .height = 3 });
    b.drawRect(.{ .x = 0, .y = 0, .width = 5, .height = 3 }, .{ .border = .all(1, .black) });
    try b.endFrame();

    try expectScreen(&term,
        \\┌───┐
        \\│   │
        \\└───┘
        \\
    );
}

test "text inside a box" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 20, .height = 3 });
    b.drawRect(.{ .x = 0, .y = 0, .width = 11, .height = 3 }, .{ .border = .all(1, .black), .corner_radius = .all(1) });
    b.drawText(.{ .x = 2, .y = 1 }, "zooee", .{});
    try b.endFrame();

    try expectScreen(&term,
        \\╭─────────╮
        \\│ zooee   │
        \\╰─────────╯
        \\
    );
}

test "clipping truncates text" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 10, .height = 1 });
    b.pushClip(.{ .x = 0, .y = 0, .width = 4, .height = 1 });
    b.drawText(.{ .x = 0, .y = 0 }, "clipped!", .{});
    b.popClip();
    try b.endFrame();

    try expectScreen(&term, "clip\n");
}

test "text drawn outside viewport is discarded" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 5, .height = 2 });
    b.drawText(.{ .x = 0, .y = 5 }, "below", .{});
    b.drawText(.{ .x = -2, .y = 0 }, "edge", .{});
    try b.endFrame();

    try expectScreen(&term, "ge\n\n");
}

test "unicode text occupies one cell per codepoint" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 8, .height = 1 });
    b.drawText(.{ .x = 0, .y = 0 }, "héllo", .{});
    try b.endFrame();

    try expectScreen(&term, "héllo\n");
    const size = b.measureText("héllo", .{});
    try std.testing.expectEqual(@as(f32, 5), size.width);
}

test "present emits ANSI truecolor escapes" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 3, .height = 1 });
    b.drawRect(.{ .x = 0, .y = 0, .width = 3, .height = 1 }, .{ .background = Color.rgb(10, 20, 30) });
    try b.endFrame();

    var buf: [256]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try term.present(&fixed);
    const written = fixed.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[48;2;10;20;30m") != null);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b[H"));
}

test "clear_color paints the whole TUI backdrop (theming)" {
    var term = TerminalBackend.init(std.testing.allocator);
    defer term.deinit();
    term.clear_color = Color.rgb(24, 26, 32); // theme dark background
    const b = term.interface();

    // No draws at all — just the cleared frame.
    try b.beginFrame(.{ .width = 4, .height = 2 });
    try b.endFrame();

    var buf: [256]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try term.present(&fixed);
    // Every empty cell carries the backdrop, so its bg escape is emitted.
    try std.testing.expect(std.mem.indexOf(u8, fixed.buffered(), "\x1b[48;2;24;26;32m") != null);
}
