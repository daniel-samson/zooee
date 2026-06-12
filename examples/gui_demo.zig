//! Native GUI demo. macOS: ships as Zooee Demo.app and renders real
//! zooee content — the layout engine drives the CPU raster backend and
//! the framebuffer blits into the window (GPU backends replace the blit
//! in #11/#12). Re-renders on resize. Text is placeholder glyph blocks
//! until the TTF rasterizer lands (#10).
//! Windows: opens the bare window (GDI blit is the next slice).

const std = @import("std");
const builtin = @import("builtin");
const zooee = @import("zooee");
const L = zooee.layout;
const Color = zooee.Color;

const items = [_][]const u8{ "Terminal backend", "Raster backend", "Native windowing", "Layout engine", "Raster blit" };
const checked = [items.len]bool{ true, true, true, true, true };

fn buildView(arena: std.mem.Allocator, scale: f32) !*const L.Element {
    const rows = try arena.alloc(L.Element, items.len);
    const row_ptrs = try arena.alloc(*const L.Element, items.len);
    for (items, 0..) |item, i| {
        const mark: []const u8 = if (checked[i]) "[x] " else "[ ] ";
        rows[i] = .{
            .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ mark, item }),
            .text_style = if (i == 2)
                .{ .color = .{ .r = 0, .g = 120, .b = 255 } }
            else
                .{ .color = Color.rgb(40, 40, 40) },
            .margin = .{ .bottom = 6 * scale },
        };
        row_ptrs[i] = &rows[i];
    }

    const title = try arena.create(L.Element);
    title.* = .{
        .text = "zooee native GUI — raster backend",
        .text_style = .{ .color = Color.black, .bold = true },
        .margin = .{ .bottom = 10 * scale },
    };
    const list = try arena.create(L.Element);
    list.* = .{
        .direction = .column,
        .padding = .all(14 * scale),
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const platform = switch (builtin.os.tag) {
        .macos => zooee.platform.macos,
        .windows => zooee.platform.win32,
        else => @compileError("gui demo: unsupported OS (X11 is #9 follow-up)"),
    };

    const w = try platform.Window.create(gpa, .{ .title = "zooee — native window" });
    defer w.destroy();

    var raster = zooee.backends.raster.RasterBackend.init(gpa);
    defer raster.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var dirty = true;
    outer: while (true) {
        for (w.pumpEvents()) |ev| switch (ev) {
            .close_requested => break :outer,
            .resized => dirty = true,
        };

        if (dirty and builtin.os.tag == .macos) {
            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const px = platform.contentPixelSize(w);
            const scale: f32 = @floatCast(px.scale);

            // Scale the placeholder glyph metrics with the display.
            raster.char_width = 8 * scale;
            raster.line_height = 16 * scale;
            const b = raster.interface();
            const root = try buildView(arena, scale);
            const viewport: zooee.Size = .{
                .width = @floatFromInt(px.width),
                .height = @floatFromInt(px.height),
            };
            const result = try L.layout(arena, b, root, viewport);
            try b.beginFrame(viewport);
            L.render(b, result);
            try b.endFrame();
            platform.blit(w, raster.pixels, raster.width, raster.height);
            dirty = false;
        }

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
