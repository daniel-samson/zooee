//! App-level screenshot fixture (#13): a representative Model rendered
//! through the full stack (view → layout → text → raster) so the
//! offscreen harness screenshots the real app path, not just raw-draw
//! scenes. Golden-compared in CI; the same render runs against GPU
//! offscreen targets once those backends exist.

const std = @import("std");
const layout = @import("../layout.zig");
const style = @import("../style.zig");

const L = layout;
const Color = style.Color;

/// A static checklist card — exercises background, per-side border,
/// rounded corners, padding/margin, and real text in one frame.
pub const Checklist = struct {
    const items = [_][]const u8{ "Render offscreen", "Compare goldens", "Run headless in CI" };
    selected: usize = 1,

    pub fn view(self: *Checklist, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        const rows = try arena.alloc(L.Element, items.len);
        const row_ptrs = try arena.alloc(*const L.Element, items.len);
        for (items, 0..) |item, i| {
            rows[i] = .{
                .text = try std.fmt.allocPrint(arena, "[x] {s}", .{item}),
                .text_style = if (i == self.selected)
                    .{ .color = .{ .r = 0, .g = 120, .b = 255 }, .size = 16 * scale }
                else
                    .{ .color = Color.rgb(40, 40, 40), .size = 16 * scale },
                .margin = .{ .bottom = 6 * scale },
            };
            row_ptrs[i] = &rows[i];
        }
        const title = try arena.create(L.Element);
        title.* = .{
            .text = "Offscreen screenshot",
            .text_style = .{ .color = Color.black, .bold = true, .size = 20 * scale },
            .margin = .{ .bottom = 10 * scale },
        };
        const card = try arena.create(L.Element);
        card.* = .{
            .direction = .column,
            .padding = .all(12 * scale),
            .rect_style = .{
                .background = Color.white,
                .border = .all(2 * scale, Color.rgb(0, 120, 255)),
                .corner_radius = .all(8 * scale),
            },
            .children = row_ptrs,
        };
        const root = try arena.create(L.Element);
        root.* = .{
            .direction = .column,
            .padding = .all(14 * scale),
            .rect_style = .{ .background = Color.rgb(238, 240, 245) },
            .children = try arena.dupe(*const L.Element, &.{ title, card }),
        };
        return root;
    }
};
