//! Recording backend: a headless `Backend` implementation that captures
//! draw calls as data. It is the foundation of the test harnesses (#8,
//! #13) — interface-level tests assert on the recorded command list, and
//! later harnesses replay commands against real backends.
//!
//! Metrics model: 1 unit = 1 px-equivalent, identity snapping to whole
//! units, monospace text where every byte is `char_width` wide. Simple and
//! deterministic on purpose.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend = @import("../backend.zig");

const Backend = backend.Backend;

pub const Command = union(enum) {
    begin_frame: geometry.Size,
    end_frame,
    rect: struct { rect: geometry.Rect, style: style.RectStyle },
    text: struct { origin: geometry.Point, text: []const u8, style: style.TextStyle },
    image: struct { rect: geometry.Rect, texture_id: u32 },
    push_clip: geometry.Rect,
    pop_clip,
};

pub const RecordBackend = struct {
    gpa: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    clip_depth: usize = 0,
    in_frame: bool = false,
    next_texture_id: u32 = 1,
    live_textures: std.AutoHashMapUnmanaged(u32, void) = .empty,
    char_width: f32 = 8,
    line_height: f32 = 16,

    pub fn init(gpa: std.mem.Allocator) RecordBackend {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RecordBackend) void {
        for (self.commands.items) |cmd| switch (cmd) {
            .text => |t| self.gpa.free(t.text),
            else => {},
        };
        self.commands.deinit(self.gpa);
        self.live_textures.deinit(self.gpa);
    }

    pub fn interface(self: *RecordBackend) Backend {
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

    fn self_(ptr: *anyopaque) *RecordBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(!self.in_frame);
        self.in_frame = true;
        self.commands.append(self.gpa, .{ .begin_frame = viewport }) catch return error.OutOfMemory;
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(self.in_frame);
        std.debug.assert(self.clip_depth == 0); // unbalanced push/pop is a framework bug
        self.in_frame = false;
        self.commands.append(self.gpa, .end_frame) catch return error.OutOfMemory;
    }

    fn drawRect(ptr: *anyopaque, rect: geometry.Rect, rect_style: style.RectStyle) void {
        const self = self_(ptr);
        self.commands.append(self.gpa, .{ .rect = .{ .rect = rect, .style = rect_style } }) catch {};
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, text_style: style.TextStyle) void {
        const self = self_(ptr);
        const copy = self.gpa.dupe(u8, text) catch return;
        self.commands.append(self.gpa, .{ .text = .{ .origin = origin, .text = copy, .style = text_style } }) catch {
            self.gpa.free(copy);
        };
    }

    fn drawImage(ptr: *anyopaque, rect: geometry.Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const id: u32 = @intCast(@intFromPtr(texture));
        std.debug.assert(self.live_textures.contains(id));
        self.commands.append(self.gpa, .{ .image = .{ .rect = rect, .texture_id = id } }) catch {};
    }

    fn pushClip(ptr: *anyopaque, rect: geometry.Rect) void {
        const self = self_(ptr);
        self.clip_depth += 1;
        self.commands.append(self.gpa, .{ .push_clip = rect }) catch {};
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        std.debug.assert(self.clip_depth > 0);
        self.clip_depth -= 1;
        self.commands.append(self.gpa, .pop_clip) catch {};
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Backend.Error!*Backend.Texture {
        const self = self_(ptr);
        _ = width;
        _ = rgba;
        _ = height;
        const id = self.next_texture_id;
        self.next_texture_id += 1;
        self.live_textures.put(self.gpa, id, {}) catch return error.OutOfMemory;
        return @ptrFromInt(id);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const id: u32 = @intCast(@intFromPtr(texture));
        std.debug.assert(self.live_textures.remove(id));
    }

    fn measureText(ptr: *anyopaque, text: []const u8, text_style: style.TextStyle) geometry.Size {
        const self = self_(ptr);
        _ = text_style;
        // Deterministic monospace model; real Unicode width is #18.
        return .{
            .width = @as(f32, @floatFromInt(text.len)) * self.char_width,
            .height = self.line_height,
        };
    }

    fn snap(ptr: *anyopaque, value: f32, axis: geometry.Axis) f32 {
        _ = ptr;
        _ = axis;
        return @round(value);
    }
};

test "records a frame of draw commands" {
    var rec = RecordBackend.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.interface();

    try b.beginFrame(.{ .width = 80, .height = 24 });
    b.drawRect(.{ .x = 1, .y = 1, .width = 10, .height = 4 }, .{ .background = style.Color.white });
    b.pushClip(.{ .x = 1, .y = 1, .width = 10, .height = 4 });
    b.drawText(.{ .x = 2, .y = 2 }, "hello", .{});
    b.popClip();
    try b.endFrame();

    try std.testing.expectEqual(@as(usize, 6), rec.commands.items.len);
    try std.testing.expect(rec.commands.items[0] == .begin_frame);
    try std.testing.expectEqualStrings("hello", rec.commands.items[3].text.text);
    try std.testing.expect(rec.commands.items[5] == .end_frame);
}

test "texture lifecycle and image draw" {
    var rec = RecordBackend.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.interface();

    const pixels = [_]u8{ 255, 0, 0, 255 }; // 1x1 red
    const tex = try b.createTexture(1, 1, &pixels);
    try b.beginFrame(.{ .width = 80, .height = 24 });
    b.drawImage(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, tex);
    try b.endFrame();
    b.destroyTexture(tex);

    try std.testing.expect(rec.commands.items[1] == .image);
    try std.testing.expectEqual(@as(u32, 1), rec.commands.items[1].image.texture_id);
}

test "measureText is monospace-deterministic" {
    var rec = RecordBackend.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.interface();
    const size = b.measureText("abcd", .{});
    try std.testing.expectEqual(@as(f32, 32), size.width);
}

test "snap rounds to whole units" {
    var rec = RecordBackend.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.interface();
    try std.testing.expectEqual(@as(f32, 3), b.snap(3.4, .horizontal));
    try std.testing.expectEqual(@as(f32, 4), b.snap(3.6, .vertical));
}
