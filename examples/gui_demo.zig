//! Native GUI demo (macOS .app / Windows exe): the layout engine drives
//! the CPU raster backend and the framebuffer blits into the native
//! window — CoreGraphics on macOS, GDI on Windows (GPU backends replace
//! the blit in #11/#12). Re-renders on resize. Text is placeholder
//! glyph blocks until the TTF rasterizer lands (#10).

const std = @import("std");
const builtin = @import("builtin");
const zooee = @import("zooee");
const L = zooee.layout;
const Color = zooee.Color;

const items = [_][]const u8{ "Terminal backend", "Raster backend", "Native windowing", "Layout engine", "Text rendering" };
const checked = [items.len]bool{ true, true, true, true, true };

/// OS font candidates (#10 policy: runtime apps use the system's fonts;
/// the vendored OFL font is tests-only). First parseable TTF wins.
const font_candidates: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Verdana.ttf",
    },
    .windows => &.{
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    },
    else => &.{},
};

fn loadSystemFont(gpa: std.mem.Allocator, io: std.Io, raster: *zooee.backends.raster.RasterBackend) void {
    for (font_candidates) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        raster.setFont(data) catch {
            gpa.free(data);
            continue;
        };
        return;
    }
    // No parseable font: placeholder blocks (still functional).
}

fn buildView(arena: std.mem.Allocator, scale: f32) !*const L.Element {
    const rows = try arena.alloc(L.Element, items.len);
    const row_ptrs = try arena.alloc(*const L.Element, items.len);
    for (items, 0..) |item, i| {
        const mark: []const u8 = if (checked[i]) "[x] " else "[ ] ";
        rows[i] = .{
            .text = try std.fmt.allocPrint(arena, "{s}{s}", .{ mark, item }),
            .text_style = if (i == 2)
                .{ .color = .{ .r = 0, .g = 120, .b = 255 }, .size = 15 * scale }
            else
                .{ .color = Color.rgb(40, 40, 40), .size = 15 * scale },
            .margin = .{ .bottom = 6 * scale },
        };
        row_ptrs[i] = &rows[i];
    }

    const title = try arena.create(L.Element);
    title.* = .{
        .text = "zooee native GUI — raster backend",
        .text_style = .{ .color = Color.black, .bold = true, .size = 22 * scale },
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
    loadSystemFont(gpa, io, &raster);
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var dirty = true;
    outer: while (true) {
        for (w.pumpEvents()) |ev| switch (ev) {
            .close_requested => break :outer,
            .resized => dirty = true,
        };

        if (dirty) {
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
