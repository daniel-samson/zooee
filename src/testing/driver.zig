//! Synthetic-event test harness (#130): drive an `app` Model with a scripted
//! sequence of `Event`s through the real view→layout→dispatch→render path, on a
//! raster backend, with no OS window or cursor — so interaction (#126 scroll,
//! #127 input, #128 drag) is verified deterministically and headlessly.
//!
//! Mirrors Chromium's `EventGenerator`/`SyntheticGestureController`: inject at
//! the application boundary (the pull-based loop of #5, where `dispatch`
//! consumes plain `Event` structs) rather than synthesizing OS input. The
//! un-injectable native seams (drag modal loop, file dialogs, clipboard) sit
//! behind interfaces with fakes — see `fakes.zig`.
//!
//! Usage:
//!   var d = try Driver(Model, Msg).init(gpa, &model, .{ .width = 100, .height = 60 });
//!   defer d.deinit();
//!   _ = try d.click(10, 10);          // pointer down+up at a point
//!   try testing.expect(model.pressed); // assert Model state, or…
//!   const px = try d.render();         // …assert pixels vs an expectation

const std = @import("std");
const layout_mod = @import("../layout.zig");
const event_mod = @import("../event.zig");
const app_mod = @import("../app.zig");
const raster_mod = @import("../backends/raster.zig");
const geometry = @import("../geometry.zig");

const Event = event_mod.Event;
const Point = geometry.Point;
const Size = geometry.Size;
const Command = app_mod.Command;

/// A headless app driver bound to a Model/Msg pair. Owns a raster backend and a
/// frame arena; re-lays-out whenever an event reports a redraw so hit-testing
/// always runs against the current frame.
pub fn Driver(comptime Model: type, comptime Msg: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        model: *Model,
        raster: raster_mod.RasterBackend,
        viewport: Size,
        scale: f32 = 1,
        arena: std.heap.ArenaAllocator,
        result: ?layout_mod.LayoutResult = null,
        /// Commands returned by each `send`, newest last — lets tests assert the
        /// loop would have quit/redrawn without inspecting Model internals.
        last_command: Command = .none,

        pub fn init(gpa: std.mem.Allocator, model: *Model, viewport: Size) !Self {
            var self: Self = .{
                .gpa = gpa,
                .model = model,
                .raster = raster_mod.RasterBackend.init(gpa),
                .viewport = viewport,
                .arena = std.heap.ArenaAllocator.init(gpa),
            };
            try self.relayout();
            return self;
        }

        /// Use a TTF so text measures with real glyph metrics (optional —
        /// without it, text measures as placeholder blocks, still deterministic).
        pub fn setFont(self: *Self, ttf: []const u8) !void {
            try self.raster.setFont(ttf);
            try self.relayout();
        }

        pub fn deinit(self: *Self) void {
            if (self.result) |*r| r.deinit(self.arena.allocator());
            self.arena.deinit();
            self.raster.deinit();
        }

        /// Rebuild the layout from the Model's current view. Called after init
        /// and after any event that requests a redraw.
        fn relayout(self: *Self) !void {
            if (self.result) |*r| r.deinit(self.arena.allocator());
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const root = try self.model.view(a, self.scale);
            self.result = try layout_mod.layout(a, self.raster.interface(), root, self.viewport);
        }

        fn placements(self: *Self) []const layout_mod.Placement {
            return if (self.result) |r| r.placements else &.{};
        }

        /// Inject one event through the production dispatch path. Relays out the
        /// view if the resulting command is `redraw` (so subsequent events hit
        /// the updated tree). Returns the command.
        pub fn send(self: *Self, ev: Event) !Command {
            const cmd = app_mod.dispatchEvent(Model, Msg, self.model, ev, self.placements());
            self.last_command = cmd;
            if (cmd == .redraw) try self.relayout();
            return cmd;
        }

        // --- Convenience event builders -----------------------------------

        pub fn pointerDown(self: *Self, x: f32, y: f32) !Command {
            return self.send(.{ .pointer_down = .{ .position = .{ .x = x, .y = y }, .buttons = .{ .primary = true } } });
        }

        pub fn pointerUp(self: *Self, x: f32, y: f32) !Command {
            return self.send(.{ .pointer_up = .{ .position = .{ .x = x, .y = y } } });
        }

        pub fn move(self: *Self, x: f32, y: f32) !Command {
            return self.send(.{ .pointer_move = .{ .position = .{ .x = x, .y = y } } });
        }

        /// A full primary click: down then up at the same point. Returns the
        /// command from the `pointer_down` (where click messages dispatch).
        pub fn click(self: *Self, x: f32, y: f32) !Command {
            const cmd = try self.pointerDown(x, y);
            _ = try self.pointerUp(x, y);
            return cmd;
        }

        pub fn key(self: *Self, k: event_mod.Key) !Command {
            return self.send(.{ .key_down = .{ .key = k } });
        }

        pub fn text(self: *Self, codepoint: u21) !Command {
            return self.send(.{ .text = .{ .codepoint = codepoint } });
        }

        pub fn resize(self: *Self, w: f32, h: f32) !Command {
            self.viewport = .{ .width = w, .height = h };
            const cmd = try self.send(.{ .resized = .{ .size = .{ .width = w, .height = h } } });
            try self.relayout(); // viewport changed regardless of command
            return cmd;
        }

        // --- Rendering / assertions ---------------------------------------

        /// Render the current frame to the raster backend and return its RGBA
        /// pixels (borrowed; valid until the next render). For pixel assertions
        /// against the golden reference, exactly like the offscreen harness.
        pub fn render(self: *Self) ![]u8 {
            const b = self.raster.interface();
            try b.beginFrame(self.viewport);
            if (self.result) |r| layout_mod.render(b, r);
            try b.endFrame();
            return self.raster.pixels;
        }

        /// Color at a pixel of the last `render` (RGBA), for spot assertions.
        pub fn pixelAt(self: *Self, x: usize, y: usize) [4]u8 {
            const c = self.raster.pixelAt(x, y);
            return .{ c.r, c.g, c.b, c.a };
        }
    };
}

// === Tests ==================================================================

const testing = std.testing;
const L = layout_mod;
const Color = @import("../style.zig").Color;

/// A minimal interactive model: a button that toggles a fill color on click and
/// counts key presses — enough to exercise pointer hit-testing, message
/// dispatch, redraw-driven relayout, and key/text routing.
const Toggle = struct {
    on: bool = false,
    keys: u32 = 0,
    chars: u32 = 0,

    const Msg = enum { tapped };

    pub fn view(self: *Toggle, arena: std.mem.Allocator, scale: f32) !*const L.Element {
        _ = scale;
        // A 40×20 button inset by 5px padding inside the root, so clicks outside
        // the button (but inside the window) genuinely miss.
        const button = try arena.create(L.Element);
        button.* = .{
            .width = 40,
            .height = 20,
            .on_click = @intFromEnum(Msg.tapped),
            .rect_style = .{ .background = if (self.on) Color.rgb(0, 200, 0) else Color.rgb(200, 0, 0) },
        };
        const root = try arena.create(L.Element);
        root.* = .{
            .padding = .all(5),
            .children = try arena.dupe(*const L.Element, &.{button}),
        };
        return root;
    }

    pub fn update(self: *Toggle, msg: Msg) Command {
        switch (msg) {
            .tapped => self.on = !self.on,
        }
        return .redraw;
    }

    pub fn onEvent(self: *Toggle, ev: event_mod.Event) Command {
        switch (ev) {
            .key_down => self.keys += 1,
            .text => self.chars += 1,
            else => {},
        }
        return .none;
    }
};

test "click toggles model state and the rendered color" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 40, .height = 20 });
    defer d.deinit();

    _ = try d.render();
    try testing.expectEqual(@as(u8, 200), d.pixelAt(10, 10)[0]); // red.r before
    try testing.expect(!model.on);

    const cmd = try d.click(10, 10);
    try testing.expectEqual(Command.redraw, cmd);
    try testing.expect(model.on);

    _ = try d.render();
    try testing.expectEqual(@as(u8, 200), d.pixelAt(10, 10)[1]); // green.g after
}

test "click outside the element does not dispatch" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 100, .height = 60 });
    defer d.deinit();
    _ = try d.click(80, 50); // outside the 40×20 button
    try testing.expect(!model.on);
}

test "key and text events route to onEvent" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 40, .height = 20 });
    defer d.deinit();
    _ = try d.key(.enter);
    _ = try d.key(.escape);
    _ = try d.text('a');
    try testing.expectEqual(@as(u32, 2), model.keys);
    try testing.expectEqual(@as(u32, 1), model.chars);
}

test "scripted sequence: two clicks return to the start state" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 40, .height = 20 });
    defer d.deinit();
    const script = [_]struct { x: f32, y: f32 }{ .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 } };
    for (script) |s| _ = try d.click(s.x, s.y);
    try testing.expect(!model.on); // toggled twice
}

test "resize relays out to the new viewport" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 40, .height = 20 });
    defer d.deinit();
    const cmd = try d.resize(80, 40);
    try testing.expectEqual(Command.redraw, cmd); // resized → redraw
    const px = try d.render();
    try testing.expectEqual(@as(usize, 80 * 40 * 4), px.len);
}
