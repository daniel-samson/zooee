//! Native GUI demo as an interactive Model (#4/#9/#10): the SAME
//! model/view/update/onEvent contract the terminal demo uses, driven by
//! zooee.app.runWindow — layout → raster → native blit, with mouse and
//! keyboard wired through the shared event dispatch. macOS ships as two
//! .app bundles (Zooee GL / Zooee Raster); Windows as a GUI-subsystem exe.
//! Text uses the OS font.

const std = @import("std");
const zooee = @import("zooee");
const L = zooee.layout;
const Color = zooee.Color;

/// Renderer baked in at build time (build.zig supplies it): the GL/D3D app
/// builds with this false (GPU-present), the raster app with it true.
const force_software = @import("build_options").force_software;

const items = [_][]const u8{ "Terminal backend", "Raster backend", "Native windowing", "Layout engine", "Text + input" };

const Msg = enum(u32) {
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
    checked: [items.len]bool = .{ true, true, true, true, true },

    pub fn view(self: *Demo, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        const rows = try arena.alloc(L.Element, items.len);
        const row_ptrs = try arena.alloc(*const L.Element, items.len);
        for (items, 0..) |item, i| {
            const mark: []const u8 = if (self.checked[i]) "[x]  " else "[ ]  ";
            rows[i] = .{
                .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ mark, item }),
                .text_style = if (self.selected == i)
                    .{ .color = .{ .r = 0, .g = 120, .b = 255 }, .size = 16 * scale }
                else
                    .{ .color = Color.rgb(40, 40, 40), .size = 16 * scale },
                .margin = .{ .bottom = 6 * scale },
                .padding = .symmetric(6 * scale, 3 * scale),
                .rect_style = if (self.selected == i)
                    .{ .background = Color.rgb(232, 240, 254), .corner_radius = .all(6 * scale) }
                else
                    .{},
                .on_click = Msg.click(i),
                .on_hover = Msg.hover(i),
            };
            row_ptrs[i] = &rows[i];
        }

        const title = try arena.create(L.Element);
        title.* = .{
            .text = "zooee — click or hover a row",
            .text_style = .{ .color = Color.black, .bold = true, .size = 22 * scale },
            .margin = .{ .bottom = 12 * scale },
        };
        const list = try arena.create(L.Element);
        list.* = .{
            .direction = .column,
            .padding = .all(12 * scale),
            .rect_style = .{
                .background = Color.white,
                .border = .all(2 * scale, Color.rgb(0, 120, 255)),
                .corner_radius = .all(10 * scale),
            },
            .children = row_ptrs,
        };
        const root = try arena.create(L.Element);
        root.* = .{
            .direction = .column,
            .padding = .all(16 * scale),
            .rect_style = .{ .background = Color.rgb(238, 240, 245) },
            .children = try arena.dupe(*const L.Element, &.{ title, list }),
        };
        return root;
    }

    pub fn update(self: *Demo, msg: Msg) zooee.app.Command {
        const raw: u32 = @intFromEnum(msg);
        const index: usize = raw & 0xff;
        if (index >= items.len) return .none;
        if (raw & 0x100 != 0) {
            if (self.selected == index) return .none;
            self.selected = index;
        } else {
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
            .text => |t| if (t.codepoint == 'q') return .quit,
            else => {},
        }
        return .none;
    }
};

pub fn main(init: std.process.Init) !void {
    var demo: Demo = .{};
    const title: [:0]const u8 = if (force_software) "zooee - raster" else "zooee - GPU";
    try zooee.app.runWindow(Demo, Msg, &demo, init, .{ .title = title, .width = 520, .height = 320, .force_software = force_software });
}
