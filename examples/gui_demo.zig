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

        const showcase = try self.buildShowcase(arena, scale);

        const columns = try arena.create(L.Element);
        columns.* = .{
            .direction = .row,
            .gap = 16 * scale,
            .children = try arena.dupe(*const L.Element, &.{ list, showcase }),
        };

        const root = try arena.create(L.Element);
        root.* = .{
            .direction = .column,
            .padding = .all(16 * scale),
            .rect_style = .{ .background = Color.rgb(238, 240, 245) },
            .children = try arena.dupe(*const L.Element, &.{ title, columns }),
        };
        return root;
    }

    /// A panel showcasing the paint primitives so they can be eyeballed on the
    /// live GPU window: a linear gradient (#118), a square fill rounded-clipped
    /// (#117), a half-opacity group (#121), and a Unicode string (#114).
    fn buildShowcase(self: *Demo, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        _ = self;
        // Gradient bar (#118): a 4-stop rainbow (multi-stop linear).
        var rainbow: zooee.style.Gradient = .{ .axis = .horizontal, .stop_count = 4 };
        rainbow.stops[0] = .{ .offset = 0.0, .color = Color.rgb(220, 40, 40) };
        rainbow.stops[1] = .{ .offset = 0.33, .color = Color.rgb(230, 200, 40) };
        rainbow.stops[2] = .{ .offset = 0.66, .color = Color.rgb(40, 180, 80) };
        rainbow.stops[3] = .{ .offset = 1.0, .color = Color.rgb(40, 60, 220) };
        const grad_bar = try arena.create(L.Element);
        grad_bar.* = .{
            .width = 200 * scale,
            .height = 28 * scale,
            .rect_style = .{ .gradient = rainbow },
        };
        // Rounded clip (#117): a SQUARE green fill clipped to round corners —
        // the corners are cut by the clip, not by a rounded-rect draw.
        const clip_fill = try arena.create(L.Element);
        clip_fill.* = .{ .grow = 1, .rect_style = .{ .background = Color.rgb(40, 180, 90) } };
        const clip_box = try arena.create(L.Element);
        clip_box.* = .{
            .width = 92 * scale,
            .height = 56 * scale,
            .clip_radius = .all(18 * scale),
            .children = try arena.dupe(*const L.Element, &.{clip_fill}),
        };
        // Group opacity (#121): a purple fill composited at 40%.
        const op_fill = try arena.create(L.Element);
        op_fill.* = .{ .grow = 1, .rect_style = .{ .background = Color.rgb(150, 40, 200) } };
        const op_group = try arena.create(L.Element);
        op_group.* = .{
            .width = 92 * scale,
            .height = 56 * scale,
            .opacity = 0.4,
            .children = try arena.dupe(*const L.Element, &.{op_fill}),
        };
        // Radial gradient (#118) clipped to a circle (#117): a glowing orb.
        var glow: zooee.style.Gradient = .{ .kind = .radial, .cx = 0.5, .cy = 0.5, .radius = 0.5, .stop_count = 2 };
        glow.stops[0] = .{ .offset = 0, .color = Color.white };
        glow.stops[1] = .{ .offset = 1, .color = Color.rgb(40, 60, 220) };
        const orb_fill = try arena.create(L.Element);
        orb_fill.* = .{ .grow = 1, .rect_style = .{ .gradient = glow } };
        const orb = try arena.create(L.Element);
        orb.* = .{
            .width = 56 * scale,
            .height = 56 * scale,
            .clip_radius = .all(28 * scale),
            .children = try arena.dupe(*const L.Element, &.{orb_fill}),
        };
        const swatches = try arena.create(L.Element);
        swatches.* = .{
            .direction = .row,
            .gap = 16 * scale,
            .margin = .{ .top = 12 * scale, .bottom = 12 * scale },
            .children = try arena.dupe(*const L.Element, &.{ clip_box, op_group, orb }),
        };
        // Box shadow (#119): an elevated card floating on a soft blurred shadow.
        const card = try arena.create(L.Element);
        card.* = .{
            .width = 200 * scale,
            .height = 36 * scale,
            .rect_style = .{
                .background = Color.white,
                .corner_radius = .all(8 * scale),
                .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 90 }, .dy = 3 * scale, .blur = 8 * scale },
            },
        };
        const card_wrap = try arena.create(L.Element);
        card_wrap.* = .{ .margin = .{ .bottom = 12 * scale }, .children = try arena.dupe(*const L.Element, &.{card}) };
        // Filled path (#120): a gold star icon (concave, even-odd fill).
        const star_pts = try arena.alloc(zooee.Point, 10);
        {
            const cx = 20 * scale;
            const cy = 20 * scale;
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                const fi: f32 = @floatFromInt(i);
                const ao = -std.math.pi / 2.0 + fi * (2.0 * std.math.pi / 5.0);
                const ai = ao + std.math.pi / 5.0;
                star_pts[i * 2] = .{ .x = cx + 18 * scale * @cos(ao), .y = cy + 18 * scale * @sin(ao) };
                star_pts[i * 2 + 1] = .{ .x = cx + 7 * scale * @cos(ai), .y = cy + 7 * scale * @sin(ai) };
            }
        }
        const star = try arena.create(L.Element);
        star.* = .{
            .width = 40 * scale,
            .height = 40 * scale,
            .path = star_pts,
            .path_color = Color.rgb(230, 170, 30),
        };
        // Stroked polyline (#120): a green checkmark next to the star.
        const check_pts = try arena.dupe(zooee.Point, &.{
            .{ .x = 4 * scale, .y = 20 * scale },
            .{ .x = 15 * scale, .y = 32 * scale },
            .{ .x = 36 * scale, .y = 6 * scale },
        });
        const check = try arena.create(L.Element);
        check.* = .{
            .width = 40 * scale,
            .height = 40 * scale,
            .stroke = check_pts,
            .stroke_color = Color.rgb(40, 170, 70),
            .stroke_width = 5 * scale,
        };
        const icons = try arena.create(L.Element);
        icons.* = .{
            .direction = .row,
            .gap = 12 * scale,
            .margin = .{ .bottom = 12 * scale },
            .children = try arena.dupe(*const L.Element, &.{ star, check }),
        };
        // Unicode (#114): accents + em-dash exercise the dynamic glyph atlas.
        const uni = try arena.create(L.Element);
        uni.* = .{
            .text = "café — déjà vu",
            .text_style = .{ .color = Color.rgb(40, 40, 40), .size = 16 * scale },
        };

        const panel = try arena.create(L.Element);
        panel.* = .{
            .direction = .column,
            .padding = .all(12 * scale),
            .rect_style = .{
                .background = Color.white,
                .border = .all(2 * scale, Color.rgb(120, 120, 130)),
                .corner_radius = .all(10 * scale),
            },
            .children = try arena.dupe(*const L.Element, &.{ grad_bar, swatches, card_wrap, icons, uni }),
        };
        return panel;
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
    try zooee.app.runWindow(Demo, Msg, &demo, init, .{ .title = title, .width = 760, .height = 400, .force_software = force_software });
}
