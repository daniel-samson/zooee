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
    /// Theme tokens drive the chrome (backdrop, surfaces, borders, body text)
    /// — and the same `theme.background` is the backend clear color, so the
    /// window backdrop and resize-exposed regions match. Swap to `.dark` here
    /// (and in `main`'s runWindow opts) to recolor the whole UI.
    theme: zooee.Theme = zooee.Theme.light,
    selected: usize = 0,
    checked: [items.len]bool = .{ true, true, true, true, true },
    /// Continuous-animation phase in radians (#170/#20): advanced by the
    /// frame-delta in `animate`, so motion is smooth and frame-rate-independent
    /// (same speed at 60 or 144 Hz).
    phase: f32 = 0,
    /// Fixed offset for the inner mini-scroller (#96) — left mid-scrolled to
    /// show clipping/panning statically now that the wheel drives the page.
    scroll_y: f32 = 40,
    /// Wheel-driven scroll offset for the whole showcase page, so every feature
    /// is reachable for QA regardless of window height.
    page_y: f32 = 0,
    /// Declarative transition (#125): the selection indicator eases to the
    /// selected row's position. `retarget(row)` on every selection change makes
    /// it slide — and re-base mid-flight if you move again before it settles.
    sel_indicator: zooee.declarative.Transition =
        zooee.declarative.Transition.init(0, 180 * std.time.ns_per_ms, .ease_out),
    /// Declarative keyframes (#125): an infinite alternating opacity pulse on the
    /// indicator, proving the timeline layer drives invalidation each tick.
    pulse: zooee.declarative.Keyframes = .{
        .stops = &.{ .{ .offset = 0, .value = 0.35 }, .{ .offset = 1, .value = 1.0 } },
        .duration = 700 * std.time.ns_per_ms,
        .iterations = zooee.declarative.Keyframes.infinite,
        .direction = .alternate,
        .easing = .ease_in_out,
    },
    /// Pointer-inside state (#127): the panel border brightens while the
    /// cursor is over the window (driven by pointer_enter/leave).
    pointer_inside: bool = false,
    /// Drag-and-drop state (#128): the drop zone highlights while a drag is
    /// over it and reports the last dropped item count.
    drag_over: bool = false,
    dropped: usize = 0,
    /// IME composition (#19): the current pre-edit string + committed text,
    /// shown live in a status label.
    preedit: [64]u8 = undefined,
    preedit_len: usize = 0,
    committed: [128]u8 = undefined,
    committed_len: usize = 0,
    /// Native context menu (#129): the last action chosen from the right-click
    /// menu, shown in a status label so the menu is visibly wired end-to-end.
    last_action: []const u8 = "right-click for a menu · Page↑/↓ to scroll the showcase",
    /// "Dev Inspect" toggles a debug frame on the live window.
    inspect: bool = false,
    /// Stable storage for the menu returned to the app loop (the popup borrows
    /// it across the call).
    menu_buf: [context_menu.len]zooee.menu.Item = context_menu,
    /// Set when the user picks File → Open…; drained by the loop, which then
    /// shows the native file dialog (#129).
    want_open: bool = false,
    /// Text queued for the system clipboard by Copy (#178); drained by the loop.
    clip_out: ?[]const u8 = null,
    /// Set by Paste; the loop reads the clipboard and calls onPaste (#178).
    want_paste: bool = false,
    /// Buffer backing `last_action` when it must hold a formatted string (the
    /// opened file path); literals are used otherwise.
    action_buf: [256]u8 = undefined,

    /// Menu item ids (#129). Shared by the right-click menu and the menu bar.
    const MenuId = enum(u32) { copy = 1, paste = 2, inspect = 3, open = 10, quit = 11, theme = 12 };
    const context_menu = [_]zooee.menu.Item{
        .{ .label = "Copy", .id = @intFromEnum(MenuId.copy), .accelerator = "Cmd+C" },
        .{ .label = "Paste", .id = @intFromEnum(MenuId.paste), .accelerator = "Cmd+V" },
        zooee.menu.separator,
        .{ .label = "Dev Inspect", .id = @intFromEnum(MenuId.inspect) },
    };
    /// Native app menu bar (#129): File / View, each a submenu. Installed once
    /// by the app loop; selections route through `onMenuCommand`.
    const menu_bar = [_]zooee.menu.Item{
        .{ .label = "File", .submenu = &.{
            .{ .label = "Open…", .id = @intFromEnum(MenuId.open), .accelerator = "Cmd+O" },
            zooee.menu.separator,
            .{ .label = "Quit", .id = @intFromEnum(MenuId.quit), .accelerator = "Cmd+Q" },
        } },
        .{ .label = "View", .submenu = &.{
            .{ .label = "Toggle Dev Inspect", .id = @intFromEnum(MenuId.inspect) },
            .{ .label = "Toggle Theme", .id = @intFromEnum(MenuId.theme) },
        } },
    };

    /// App-loop hook (#129): supply the native context menu for a right-click.
    pub fn contextMenu(self: *Demo) ?[]const zooee.menu.Item {
        // "Dev Inspect" shows its current state as a checkmark.
        self.menu_buf = context_menu;
        self.menu_buf[3].checked = self.inspect;
        return &self.menu_buf;
    }

    /// App-loop hook (#129): supply the native menu bar.
    pub fn menuBar(self: *Demo) []const zooee.menu.Item {
        _ = self;
        return &menu_bar;
    }

    /// App-loop hook (#129): handle a chosen menu item id (context or menu bar).
    pub fn onMenuCommand(self: *Demo, id: u32) zooee.app.Command {
        switch (@as(MenuId, @enumFromInt(id))) {
            .copy => {
                self.clip_out = items[self.selected]; // copy the selected row label
                self.last_action = std.fmt.bufPrint(&self.action_buf, "copied: {s}", .{items[self.selected]}) catch "copied";
            },
            .paste => self.want_paste = true, // loop reads the clipboard → onPaste
            .inspect => {
                self.inspect = !self.inspect;
                self.last_action = if (self.inspect) "dev inspect ON" else "dev inspect OFF";
            },
            .theme => {
                self.theme = if (self.theme.background.r > 128) zooee.Theme.dark else zooee.Theme.light;
                self.last_action = "toggled theme";
            },
            .open => {
                self.want_open = true; // loop shows the native dialog next frame
                self.last_action = "opening file…";
            },
            .quit => return .quit,
        }
        return .redraw;
    }

    /// App-loop hook (#129): drain a pending File → Open… request so the loop
    /// pops the native file dialog.
    pub fn takeOpenRequest(self: *Demo) bool {
        const r = self.want_open;
        self.want_open = false;
        return r;
    }

    /// App-loop hook (#129): the user picked a file in the native dialog (or it
    /// was cancelled, in which case this isn't called).
    pub fn onFileChosen(self: *Demo, path: []const u8) zooee.app.Command {
        const base = std.fs.path.basename(path);
        self.last_action = std.fmt.bufPrint(&self.action_buf, "opened: {s}", .{base}) catch "opened a file";
        return .redraw;
    }

    /// App-loop hook (#178): drain text queued by Copy for the system clipboard.
    pub fn takeClipboardWrite(self: *Demo) ?[]const u8 {
        const t = self.clip_out;
        self.clip_out = null;
        return t;
    }

    /// App-loop hook (#178): drain a pending Paste request.
    pub fn requestPaste(self: *Demo) bool {
        const r = self.want_paste;
        self.want_paste = false;
        return r;
    }

    /// App-loop hook (#178): the loop read this text from the system clipboard.
    pub fn onPaste(self: *Demo, text: []const u8) zooee.app.Command {
        const n = @min(text.len, 40);
        self.last_action = std.fmt.bufPrint(&self.action_buf, "pasted: {s}", .{text[0..n]}) catch "pasted";
        return .redraw;
    }

    pub fn view(self: *Demo, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        const rows = try arena.alloc(L.Element, items.len);
        const row_ptrs = try arena.alloc(*const L.Element, items.len);
        for (items, 0..) |item, i| {
            const mark: []const u8 = if (self.checked[i]) "[x]  " else "[ ]  ";
            rows[i] = .{
                .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ mark, item }),
                .text_style = if (self.selected == i)
                    .{ .color = self.theme.accent, .size = 16 * scale }
                else
                    .{ .color = self.theme.text, .size = 16 * scale },
                .margin = .{ .bottom = 6 * scale },
                .padding = .symmetric(6 * scale, 3 * scale),
                .rect_style = if (self.selected == i)
                    .{ .background = self.theme.surface_variant, .corner_radius = .all(6 * scale) }
                else
                    .{},
                .on_click = Msg.click(i),
                .on_hover = Msg.hover(i),
                // Clickable rows show the hand pointer (#123).
                .cursor = .pointer,
            };
            row_ptrs[i] = &rows[i];
        }

        const title = try arena.create(L.Element);
        title.* = .{
            .text = "zooee — click or hover a row",
            .text_style = .{ .color = self.theme.text, .bold = true, .size = 22 * scale },
            .margin = .{ .bottom = 4 * scale },
            // Heading reads as text → I-beam (#123); rows below show the hand.
            .cursor = .text,
        };
        // Native context-menu status (#129): updates when you right-click and
        // pick Copy / Paste / Dev Inspect.
        const status = try arena.create(L.Element);
        status.* = .{
            .text = self.last_action,
            .text_style = .{ .color = self.theme.text_muted, .size = 13 * scale },
            .margin = .{ .bottom = 12 * scale },
        };
        // Declarative-animation indicator (#125): a 4px accent bar that *slides*
        // to the selected row (Transition, eased) while *pulsing* its opacity
        // (Keyframes, infinite alternate). Row pitch = text 16 + pad 3·2 + margin
        // 6 ≈ 28px; +3 centers the 16px bar against the row's text baseline.
        const pitch = 28 * scale;
        const indicator = try arena.create(L.Element);
        indicator.* = .{
            .width = 4 * scale,
            .height = 16 * scale,
            .margin = .{ .top = self.sel_indicator.value() * pitch + 3 * scale },
            .rect_style = .{
                .background = .{
                    .r = self.theme.accent.r,
                    .g = self.theme.accent.g,
                    .b = self.theme.accent.b,
                    .a = @intFromFloat(@round(self.pulse.value() * 255)),
                },
                .corner_radius = .all(2 * scale),
            },
        };
        const indicator_col = try arena.create(L.Element);
        indicator_col.* = .{
            .direction = .column,
            .width = 4 * scale,
            .margin = .{ .right = 6 * scale },
            .children = try arena.dupe(*const L.Element, &.{indicator}),
        };
        const rows_col = try arena.create(L.Element);
        rows_col.* = .{ .direction = .column, .children = row_ptrs };
        const list = try arena.create(L.Element);
        list.* = .{
            .direction = .row,
            .padding = .all(12 * scale),
            .rect_style = .{
                .background = self.theme.surface,
                .border = .all(2 * scale, self.theme.accent),
                .corner_radius = .all(10 * scale),
            },
            .children = try arena.dupe(*const L.Element, &.{ indicator_col, rows_col }),
        };

        const showcase = try self.buildShowcase(arena, scale);

        const columns = try arena.create(L.Element);
        columns.* = .{
            .direction = .row,
            .gap = 16 * scale,
            .children = try arena.dupe(*const L.Element, &.{ list, showcase }),
        };
        // Page scroll viewport: the showcase is taller than the window, so wrap
        // it in a fixed-height scroller (panned by the wheel via `page_y`) so
        // every feature is reachable for QA by scrolling (#96). 640 logical
        // fits under the header in the default 760px window and clips the rest.
        const page = try arena.create(L.Element);
        page.* = .{
            .height = 640 * scale,
            .scroll = true,
            .scroll_y = self.page_y * scale,
            .children = try arena.dupe(*const L.Element, &.{columns}),
        };

        const root = try arena.create(L.Element);
        root.* = .{
            .direction = .column,
            .padding = .all(16 * scale),
            // "Dev Inspect" (#129 menu → #26 devtools): a magenta debug frame
            // makes the toggle visibly do something on the live window.
            .rect_style = if (self.inspect)
                .{ .background = self.theme.background, .border = .all(2 * scale, Color.rgb(230, 40, 200)) }
            else
                .{ .background = self.theme.background },
            .children = try arena.dupe(*const L.Element, &.{ title, status, page }),
        };
        return root;
    }

    /// Three overlapping circles (#95/#121). `alpha` is per-circle opacity;
    /// `group` wraps them in an offscreen layer composited at that opacity.
    /// Per-primitive alpha double-blends the overlaps (darker seams); group
    /// opacity fades the union as one unit (clean overlaps) — the difference
    /// offscreen-layer compositing buys you.
    fn overlapCircles(arena: std.mem.Allocator, scale: f32, alpha: u8, group: ?f32) !*const L.Element {
        const d: f32 = 40 * scale;
        const colors = [_]Color{
            .{ .r = 230, .g = 60, .b = 60, .a = alpha },
            .{ .r = 60, .g = 200, .b = 90, .a = alpha },
            .{ .r = 70, .g = 120, .b = 240, .a = alpha },
        };
        const circles = try arena.alloc(L.Element, colors.len);
        const ptrs = try arena.alloc(*const L.Element, colors.len);
        for (colors, 0..) |c, i| {
            circles[i] = .{
                .width = d,
                .height = d,
                // Pull each circle back over the previous one to overlap by ~half.
                .margin = if (i == 0) .{} else .{ .left = -d * 0.45 },
                .rect_style = .{ .background = c, .corner_radius = .all(d * 0.5) },
            };
            ptrs[i] = &circles[i];
        }
        const row = try arena.create(L.Element);
        row.* = .{ .direction = .row, .opacity = group, .children = ptrs };
        return row;
    }

    /// "Layers & alpha" section (#95/#121): per-primitive translucency vs an
    /// offscreen group composited at one opacity.
    fn buildLayers(self: *Demo, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        const header = try arena.create(L.Element);
        header.* = .{
            .text = "Layers — per-primitive alpha vs. group opacity",
            .text_style = .{ .color = self.theme.text_muted, .size = 12 * scale },
            .margin = .{ .bottom = 6 * scale },
        };
        // Left: 3 translucent circles — overlaps double-blend (darker seams).
        const alpha_demo = try overlapCircles(arena, scale, 150, null);
        // Right: 3 opaque circles in a 55% group — union fades cleanly, no seams.
        const group_demo = try overlapCircles(arena, scale, 255, 0.55);
        const cols = try arena.create(L.Element);
        cols.* = .{
            .direction = .row,
            .gap = 28 * scale,
            .children = try arena.dupe(*const L.Element, &.{ alpha_demo, group_demo }),
        };
        const section = try arena.create(L.Element);
        section.* = .{
            .direction = .column,
            .margin = .{ .bottom = 12 * scale },
            .children = try arena.dupe(*const L.Element, &.{ header, cols }),
        };
        return section;
    }

    /// A panel showcasing the paint primitives on the live GPU window: gradients
    /// (#118), rounded clip (#117), group opacity (#121), the animated dot (#170),
    /// the layers/alpha section (#95/#121), vector icons (#120), shadows (#119),
    /// images (#122), scroll (#96), text layout (#115), and Unicode (#114).
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
        // Continuous animation (#170): a dot slides along a track, driven by
        // `phase` (advanced by the real frame-delta in `animate`). Smooth and
        // the same speed at any refresh rate; uncapped from the old 60fps limit.
        const track_w: f32 = 200 * scale;
        const dot_w: f32 = 16 * scale;
        const t: f32 = 0.5 + 0.5 * @sin(self.phase);
        const dot = try arena.create(L.Element);
        dot.* = .{
            .width = dot_w,
            .height = dot_w,
            .margin = .{ .left = t * (track_w - dot_w) },
            .rect_style = .{ .background = Color.rgb(60, 130, 240), .corner_radius = .all(dot_w * 0.5) },
        };
        const track = try arena.create(L.Element);
        track.* = .{
            .direction = .row,
            .width = track_w,
            .height = dot_w,
            .margin = .{ .top = 8 * scale },
            .rect_style = .{ .background = self.theme.surface_variant, .corner_radius = .all(dot_w * 0.5) },
            .children = try arena.dupe(*const L.Element, &.{dot}),
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
                .background = self.theme.surface,
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
                .background = self.theme.surface_variant,
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
            .rect_style = .{ .background = self.theme.surface_variant, .border = .all(1 * scale, self.theme.border), .corner_radius = .all(6 * scale) },
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
            .text_style = .{ .color = self.theme.text, .size = 15 * scale },
            .text_wrap = .balance, // CSS text-wrap: even out the lines (#192)
            .text_align = .center,
        };
        // Drop zone (#128): highlights while a drag is over it; shows the last
        // dropped item count. Live drops need per-platform DnD registration.
        const drop_label = if (self.dropped > 0)
            try std.fmt.allocPrint(arena, "dropped {d} item(s)", .{self.dropped})
        else
            "drop files here";
        const drop_zone = try arena.create(L.Element);
        drop_zone.* = .{
            .width = 240 * scale,
            .height = 28 * scale,
            .margin = .{ .bottom = 10 * scale },
            .padding = .all(6 * scale),
            .text = drop_label,
            .text_style = .{ .color = self.theme.text_muted, .size = 13 * scale },
            .rect_style = .{
                .background = if (self.drag_over) self.theme.accent else self.theme.surface_variant,
                .border = .all(1 * scale, if (self.drag_over) self.theme.accent else self.theme.border),
                .corner_radius = .all(5 * scale),
            },
        };
        // IME composition status (#19): "committed [preedit]" updates live as
        // an input method composes. Empty until composition events arrive.
        const ime_text = try std.fmt.allocPrint(arena, "IME: {s}[{s}]", .{
            self.committed[0..self.committed_len],
            self.preedit[0..self.preedit_len],
        });
        const ime_label = try arena.create(L.Element);
        ime_label.* = .{
            .margin = .{ .bottom = 8 * scale },
            .text = ime_text,
            .text_style = .{ .color = self.theme.text_muted, .size = 13 * scale },
        };
        // Layers & alpha section (#95/#121).
        const layers = try self.buildLayers(arena, scale);
        // Unicode (#114): the dynamic glyph atlas rasterizes any codepoint the
        // OS font carries — Latin accents, Greek, Cyrillic, punctuation, arrows,
        // and math symbols all from one renderer.
        const uni = try arena.create(L.Element);
        uni.* = .{
            .text = "café · Ελληνικά · Привет · ½→∞ · «—»",
            .text_style = .{ .color = self.theme.text, .size = 16 * scale },
        };
        // Complex-script shaping (#116/#202/#203): the OS font + shaping
        // pipeline render these in display order. Arabic letters join
        // contextually; Hebrew runs right-to-left (BiDi); the mixed line proves
        // LTR+RTL BiDi in one string. (Indic reordering, #202, is unit-tested:
        // the macOS system font has no Devanagari glyphs and there is no
        // per-script font fallback yet, so it would render as tofu here.)
        const shaping_header = try arena.create(L.Element);
        shaping_header.* = .{
            .text = "Complex-script shaping (Arabic join · BiDi):",
            .text_style = .{ .color = self.theme.text_muted, .size = 12 * scale },
            .margin = .{ .top = 8 * scale, .bottom = 4 * scale },
        };
        const arabic_line = try arena.create(L.Element);
        arabic_line.* = .{ .text = "العربية · السلام عليكم", .text_style = .{ .color = self.theme.text, .size = 18 * scale }, .margin = .{ .bottom = 2 * scale } };
        const hebrew_line = try arena.create(L.Element);
        hebrew_line.* = .{ .text = "עברית · שלום עולם", .text_style = .{ .color = self.theme.text, .size = 18 * scale }, .margin = .{ .bottom = 2 * scale } };
        const mixed_line = try arena.create(L.Element);
        mixed_line.* = .{ .text = "mixed: hello שלום 123 world", .text_style = .{ .color = self.theme.text, .size = 15 * scale } };
        const shaping = try arena.create(L.Element);
        shaping.* = .{
            .direction = .column,
            .margin = .{ .bottom = 10 * scale },
            .children = try arena.dupe(*const L.Element, &.{ shaping_header, arabic_line, hebrew_line, mixed_line }),
        };

        // Text decorations (#191): underline + strikethrough as TextStyle flags.
        const underlined = try arena.create(L.Element);
        underlined.* = .{ .text = "underline", .text_style = .{ .color = self.theme.accent, .size = 15 * scale, .underline = true } };
        const struck = try arena.create(L.Element);
        struck.* = .{ .text = "strikethrough", .text_style = .{ .color = self.theme.text_muted, .size = 15 * scale, .strikethrough = true } };
        const deco = try arena.create(L.Element);
        deco.* = .{ .direction = .row, .gap = 14 * scale, .margin = .{ .top = 8 * scale }, .children = try arena.dupe(*const L.Element, &.{ underlined, struck }) };

        const panel = try arena.create(L.Element);
        panel.* = .{
            .direction = .column,
            .padding = .all(12 * scale),
            .rect_style = .{
                .background = self.theme.surface,
                // Border brightens to the accent while the pointer is inside (#127).
                .border = .all(2 * scale, if (self.pointer_inside) self.theme.accent else self.theme.border),
                .corner_radius = .all(10 * scale),
            },
            .children = try arena.dupe(*const L.Element, &.{ grad_bar, track, swatches, layers, card_wrap, icons, button, scroller, paragraph, drop_zone, ime_label, uni, shaping, deco }),
        };
        return panel;
    }

    /// Backend clear color (theming): the framework reads this each frame so a
    /// runtime theme change recolors the window backdrop too, not just content.
    pub fn background(self: *Demo) Color {
        return self.theme.background;
    }

    /// Frame-driver hook (#170): advance the animation by the real elapsed
    /// time, so the motion runs at the same speed regardless of refresh rate.
    pub fn animate(self: *Demo, dt_ns: u64) zooee.app.Command {
        const dt_s: f32 = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
        self.phase += dt_s * 2.0; // ~1 cycle / π seconds
        const tau = 6.2831855;
        if (self.phase > tau) self.phase -= tau;
        // Declarative layer (#125): the indicator slide settles on its own; the
        // pulse runs forever. Both feed the same per-frame delta.
        _ = self.sel_indicator.tick(dt_ns);
        _ = self.pulse.tick(dt_ns);
        return .redraw; // continuous animation → present every frame
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
        self.sel_indicator.retarget(@floatFromInt(self.selected));
        return .redraw;
    }

    pub fn onEvent(self: *Demo, ev: zooee.event.Event) zooee.app.Command {
        switch (ev) {
            .key_down => |k| switch (k.key) {
                .up => {
                    self.selected = if (self.selected == 0) items.len - 1 else self.selected - 1;
                    self.sel_indicator.retarget(@floatFromInt(self.selected));
                    return .redraw;
                },
                .down => {
                    self.selected = (self.selected + 1) % items.len;
                    self.sel_indicator.retarget(@floatFromInt(self.selected));
                    return .redraw;
                },
                .enter => {
                    self.checked[self.selected] = !self.checked[self.selected];
                    return .redraw;
                },
                // Page the showcase so every feature is reachable for QA even
                // without a scroll wheel.
                .page_down => {
                    self.page_y = @min(700, self.page_y + 120);
                    return .redraw;
                },
                .page_up => {
                    self.page_y = @max(0, self.page_y - 120);
                    return .redraw;
                },
                .escape => return .quit,
                else => {},
            },
            .text => |t| switch (t.codepoint) {
                'q' => return .quit,
                // Toggle the whole UI light ⇄ dark at runtime (theming). The
                // backend clear color follows via the `background` hook.
                't' => {
                    self.theme = if (self.theme.background.r > 128) zooee.Theme.dark else zooee.Theme.light;
                    return .redraw;
                },
                else => {},
            },
            .scroll => |s| {
                // Wheel/trackpad scrolls the whole showcase page so every
                // feature is reachable (#96/#126). Positive dy = content up.
                const step: f32 = if (s.unit == .pixel) s.dy else s.dy * 12;
                self.page_y = @max(0, @min(700, self.page_y + step));
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
            // Drag-and-drop (#128): highlight the drop zone, count drops.
            .drag_enter, .drag_over => {
                self.drag_over = true;
                return .redraw;
            },
            .drag_leave => {
                self.drag_over = false;
                return .redraw;
            },
            .drop => |dd| {
                self.drag_over = false;
                self.dropped = switch (dd.data) {
                    .files => |f| f.len,
                    .urls => |u| u.len,
                    .text => 1,
                    .unknown => 0,
                };
                return .redraw;
            },
            // IME composition (#19): mirror the pre-edit string; on commit,
            // append the finalized text and clear the pre-edit.
            .composition => |c| switch (c.phase) {
                .start, .update => {
                    const n = @min(c.text.len, self.preedit.len);
                    @memcpy(self.preedit[0..n], c.text[0..n]);
                    self.preedit_len = n;
                    return .redraw;
                },
                .commit => {
                    const room = self.committed.len - self.committed_len;
                    const n = @min(c.text.len, room);
                    @memcpy(self.committed[self.committed_len..][0..n], c.text[0..n]);
                    self.committed_len += n;
                    self.preedit_len = 0;
                    return .redraw;
                },
                .cancel => {
                    self.preedit_len = 0;
                    return .redraw;
                },
            },
            else => {},
        }
        return .none;
    }
};

pub fn main(init: std.process.Init) !void {
    var demo: Demo = .{};
    const title: [:0]const u8 = if (force_software) "zooee - raster" else "zooee - GPU";
    // Title-bar mode (#64) selectable at launch so each can be QA'd, e.g.
    // `ZOOEE_TITLEBAR=headless zig build run-gui` (native | integrated | headless).
    const titlebar: zooee.window.TitlebarMode = blk: {
        const v = init.environ_map.get("ZOOEE_TITLEBAR") orelse break :blk .native;
        if (std.mem.eql(u8, v, "integrated")) break :blk .integrated;
        if (std.mem.eql(u8, v, "headless")) break :blk .headless;
        break :blk .native;
    };
    // Pass the same theme the UI is built from, so the backend clear color
    // (window backdrop + resize-exposed regions) matches the content.
    try zooee.app.runWindow(Demo, Msg, &demo, init, .{ .title = title, .width = 760, .height = 760, .force_software = force_software, .theme = demo.theme, .titlebar = titlebar });
}
