//! Interactive terminal demo, written against the app architecture (#4):
//! a Model with view/update/onEvent — the framework owns the loop,
//! hit-testing, rendering, and terminal session.
//!
//! Controls: ↑/↓ or hover moves · space/enter/click toggles · q quits.

const std = @import("std");
const builtin = @import("builtin");
const zooee = @import("zooee");
const L = zooee.layout;
const Color = zooee.Color;

pub const panic = std.debug.FullPanic(if (builtin.os.tag == .windows)
    zooee.platform.win32_console.panicRestore
else
    zooee.platform.posix_tty.panicRestore);

const items = [_][]const u8{ "Terminal backend", "Raster backend", "Win32 windowing", "Layout engine", "Event layer" };

const Msg = enum(u32) {
    // low bits: item index; bit 8: hover (select only) vs click (toggle)
    _,
    fn click(i: usize) u32 {
        return @intCast(i);
    }
    fn hover(i: usize) u32 {
        return @intCast(i | 0x100);
    }
};

const Demo = struct {
    selected: usize = 0,
    checked: [items.len]bool = .{ true, true, true, true, false },

    pub fn view(self: *Demo, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        _ = scale;
        const rows = try arena.alloc(L.Element, items.len);
        const row_ptrs = try arena.alloc(*const L.Element, items.len);
        for (items, 0..) |item, i| {
            const mark: []const u8 = if (self.checked[i]) "[x] " else "[ ] ";
            const cursor: []const u8 = if (self.selected == i) "> " else "  ";
            rows[i] = .{
                .text = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ cursor, mark, item }),
                .text_style = if (self.selected == i)
                    .{ .color = .{ .r = 0, .g = 120, .b = 255 }, .bold = true }
                else
                    .{},
                .on_click = Msg.click(i),
                .on_hover = Msg.hover(i),
            };
            row_ptrs[i] = &rows[i];
        }

        const title = try arena.create(L.Element);
        title.* = .{ .text = "zooee demo — ↑/↓/hover move · space/click toggle · q quit", .text_style = .{ .bold = true } };
        const list = try arena.create(L.Element);
        list.* = .{
            .direction = .column,
            .padding = .symmetric(2, 1),
            .rect_style = .{ .border = .all(1, Color.rgb(128, 128, 128)), .corner_radius = .all(1) },
            .children = row_ptrs,
        };
        const root = try arena.create(L.Element);
        root.* = .{
            .direction = .column,
            .padding = .all(1),
            .gap = 1,
            .children = try arena.dupe(*const L.Element, &.{ title, list }),
        };
        return root;
    }

    pub fn update(self: *Demo, msg: anytype) zooee.app.Command {
        const raw: u32 = @intFromEnum(msg);
        const index: usize = raw & 0xff;
        if (index >= items.len) return .none;
        if (raw & 0x100 != 0) {
            // hover: select only
            if (self.selected == index) return .none;
            self.selected = index;
        } else {
            // click: select and toggle
            self.selected = index;
            self.checked[index] = !self.checked[index];
        }
        return .redraw;
    }

    pub fn onEvent(self: *Demo, ev: zooee.event.Event) zooee.app.Command {
        switch (ev) {
            .key_down => |k| switch (k.key) {
                .up => {
                    self.selected = if (self.selected == 0) items.len - 1 else self.selected - 1;
                    return .redraw;
                },
                .down => {
                    self.selected = (self.selected + 1) % items.len;
                    return .redraw;
                },
                .enter => {
                    self.checked[self.selected] = !self.checked[self.selected];
                    return .redraw;
                },
                .escape => return .quit,
                else => {},
            },
            .text => |t| switch (t.codepoint) {
                'q' => return .quit,
                ' ' => {
                    self.checked[self.selected] = !self.checked[self.selected];
                    return .redraw;
                },
                else => {},
            },
            else => {},
        }
        return .none;
    }
};

pub fn main(init: std.process.Init) !void {
    var demo: Demo = .{};
    try zooee.app.run(Demo, Msg, &demo, init);
}
