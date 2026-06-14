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
    /// Wheel-driven scroll offset for the showcase list viewport (#96/#126).
    scroll_y: f32 = 40,
    /// Pointer-inside state (#127): the panel border brightens while the
    /// cursor is over the window (driven by pointer_enter/leave).
    pointer_inside: bool = false,

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
        // Box shadow (#119): an elevated card on a soft, ROUNDED-corner shadow
        // that matches the card's rounding (Wallace rounded-box-shadow).
        const card = try arena.create(L.Element);
        card.* = .{
            .width = 200 * scale,
            .height = 36 * scale,
            .rect_style = .{
                .background = Color.white,
                .corner_radius = .all(8 * scale),
                .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 90 }, .dy = 3 * scale, .blur = 8 * scale, .corner_radius = 8 * scale },
            },
        };
        // Inset shadow (#119): a pressed "well" — shadow hugs the inner edges.
        const well = try arena.create(L.Element);
        well.* = .{
            .width = 200 * scale,
            .height = 28 * scale,
            .rect_style = .{
                .background = Color.rgb(225, 228, 232),
                .corner_radius = .all(7 * scale),
                .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 110 }, .dy = 1 * scale, .blur = 5 * scale, .corner_radius = 7 * scale, .inset = true },
            },
        };
        const card_wrap = try arena.create(L.Element);
        card_wrap.* = .{ .direction = .column, .gap = 10 * scale, .margin = .{ .bottom = 12 * scale }, .children = try arena.dupe(*const L.Element, &.{ card, well }) };
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
        // Image fit (#122): a wide 4×2 swatch drawn COVER into a square tile —
        // the texture is uploaded/drawn per frame in layout.renderNode.
        const img_px = try arena.dupe(u8, &.{
            255, 0,   0,   255, 0,   255, 0,   255, 0,   0,   255, 255, 255, 255, 0,   255,
            0,   255, 255, 255, 255, 0,   255, 255, 255, 255, 255, 255, 128, 128, 128, 255,
        });
        const img = try arena.create(L.Element);
        img.* = .{
            .width = 40 * scale,
            .height = 40 * scale,
            .image_rgba = img_px,
            .image_w = 4,
            .image_h = 2,
            .image_fit = .cover,
            .clip_radius = .all(6 * scale),
        };
        // Bilinear upscale (#122): the same swatch sampled LINEAR — smooth
        // color blends between texels instead of hard nearest-neighbor blocks.
        const img_smooth = try arena.create(L.Element);
        img_smooth.* = .{
            .width = 40 * scale,
            .height = 40 * scale,
            .image_rgba = img_px,
            .image_w = 4,
            .image_h = 2,
            .image_fit = .cover,
            .image_sampling = .linear,
            .clip_radius = .all(6 * scale),
        };
        const icons = try arena.create(L.Element);
        icons.* = .{
            .direction = .row,
            .gap = 12 * scale,
            .margin = .{ .bottom = 12 * scale },
            .children = try arena.dupe(*const L.Element, &.{ star, check, img, img_smooth }),
        };
        // 9-slice (#122): an 8×8 bordered texture stretched into a wide button
        // background — corners stay sharp, edges/center stretch.
        const btn_px = try arena.alloc(u8, 8 * 8 * 4);
        {
            var bi: usize = 0;
            while (bi < 8) : (bi += 1) {
                var bj: usize = 0;
                while (bj < 8) : (bj += 1) {
                    const is_border = bi < 2 or bi >= 6 or bj < 2 or bj >= 6;
                    const o = (bi * 8 + bj) * 4;
                    btn_px[o + 0] = if (is_border) 60 else 90;
                    btn_px[o + 1] = if (is_border) 90 else 150;
                    btn_px[o + 2] = if (is_border) 200 else 240;
                    btn_px[o + 3] = 255;
                }
            }
        }
        const button = try arena.create(L.Element);
        button.* = .{
            .width = 180 * scale,
            .height = 32 * scale,
            .margin = .{ .bottom = 12 * scale },
            .image_rgba = btn_px,
            .image_w = 8,
            .image_h = 8,
            .image_nine = .{ .l = 2, .t = 2, .r = 2, .b = 2 },
        };
        // Scroll viewport (#96): a tall column of rows clipped to a short box
        // and panned down — content above the fold is clipped, the rest visible.
        const row_count = 8;
        const scroll_rows = try arena.alloc(L.Element, row_count);
        const scroll_row_ptrs = try arena.alloc(*const L.Element, row_count);
        const row_colors = [_]Color{
            Color.rgb(230, 120, 120), Color.rgb(230, 175, 110), Color.rgb(220, 215, 110),
            Color.rgb(130, 205, 130), Color.rgb(110, 185, 220), Color.rgb(140, 140, 225),
            Color.rgb(190, 130, 215), Color.rgb(225, 130, 180),
        };
        for (0..row_count) |ri| {
            scroll_rows[ri] = .{
                .height = 22 * scale,
                .margin = .{ .bottom = 4 * scale },
                .rect_style = .{ .background = row_colors[ri], .corner_radius = .all(4 * scale) },
            };
            scroll_row_ptrs[ri] = &scroll_rows[ri];
        }
        const scroll_content = try arena.create(L.Element);
        scroll_content.* = .{
            .direction = .column,
            .children = scroll_row_ptrs,
        };
        const scroller = try arena.create(L.Element);
        scroller.* = .{
            .height = 70 * scale,
            .padding = .all(4 * scale),
            .margin = .{ .bottom = 12 * scale },
            .rect_style = .{ .background = Color.rgb(245, 245, 248), .border = .all(1 * scale, Color.rgb(150, 150, 160)), .corner_radius = .all(6 * scale) },
            .scroll = true,
            .scroll_y = self.scroll_y * scale,
            .children = try arena.dupe(*const L.Element, &.{scroll_content}),
        };
        // Text layout (#115): a wrapped, centered paragraph in a fixed-width box.
        const paragraph = try arena.create(L.Element);
        paragraph.* = .{
            .width = 240 * scale,
            .margin = .{ .bottom = 10 * scale },
            .text = "zooee lays out wrapped, aligned paragraphs across every backend — pixel for pixel.",
            .text_style = .{ .color = Color.rgb(60, 60, 70), .size = 15 * scale },
            .text_wrap = true,
            .text_align = .center,
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
                // Border brightens to blue while the pointer is inside (#127).
                .border = .all(2 * scale, if (self.pointer_inside) Color.rgb(0, 120, 255) else Color.rgb(120, 120, 130)),
                .corner_radius = .all(10 * scale),
            },
            .children = try arena.dupe(*const L.Element, &.{ grad_bar, swatches, card_wrap, icons, button, scroller, paragraph, uni }),
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
            .scroll => |s| {
                // Wheel/trackpad scrolls the showcase list viewport (#126).
                // Content is ~8 rows × 26px ≈ 200px tall in a 70px box.
                const step: f32 = if (s.unit == .pixel) s.dy else s.dy * 12;
                self.scroll_y = @max(0, @min(140, self.scroll_y + step));
                return .redraw;
            },
            // Pointer enter/leave drive the panel-border highlight (#127). Live
            // emission needs the per-platform tracking-area/grab wiring (on-device).
            .pointer_enter => {
                self.pointer_inside = true;
                return .redraw;
            },
            .pointer_leave => {
                self.pointer_inside = false;
                return .redraw;
            },
            else => {},
        }
        return .none;
    }
};

pub fn main(init: std.process.Init) !void {
    var demo: Demo = .{};
    const title: [:0]const u8 = if (force_software) "zooee - raster" else "zooee - GPU";
    try zooee.app.runWindow(Demo, Msg, &demo, init, .{ .title = title, .width = 760, .height = 560, .force_software = force_software });
}
