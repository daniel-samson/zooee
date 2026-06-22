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
const ui_mod = @import("../ui.zig");
const raster_mod = @import("../backends/raster.zig");
const geometry = @import("../geometry.zig");

const menu_mod = @import("../menu.zig");

const Event = event_mod.Event;
const Point = geometry.Point;
const Size = geometry.Size;
const Command = app_mod.Command;

/// A windowless stand-in so the in-window overlay context menu (the X11 path)
/// can be driven headlessly: `native_menus = false` routes handleContextMenu to
/// the overlay; `popupMenu` exists only to satisfy the (unreached) call site.
const FakeWindow = struct {
    pub const native_menus = false;
    pub fn popupMenu(self: *FakeWindow, items: []const menu_mod.Item, x: f32, y: f32) ?u32 {
        _ = self;
        _ = items;
        _ = x;
        _ = y;
        return null;
    }
};

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
        /// Stand-in window for driving the overlay context menu (#319).
        fake_window: FakeWindow = .{},

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
            // Build through the same path the real loops use (#4): prefers a
            // `viewUi(ui) Widget` hook, falls back to `view(arena, scale)`.
            const root = try app_mod.buildTree(Model, self.model, a, self.scale);
            self.result = try layout_mod.layout(a, self.raster.interface(), root, self.viewport);
        }

        fn placements(self: *Self) []const layout_mod.Placement {
            return if (self.result) |r| r.placements else &.{};
        }

        /// The cursor shape the app would show at (x, y) — the same resolution
        /// the production loop runs on pointer_move (#123). Lets tests assert
        /// hover affordances (resize gutters, pointer regions) headlessly.
        pub fn cursorAt(self: *Self, x: f32, y: f32) @import("../cursor.zig").Cursor {
            return app_mod.cursorOverride(Model, self.model) orelse
                app_mod.cursorFor(self.placements(), .{ .x = x, .y = y });
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

        /// A discrete wheel scroll (line unit) at a point (#126).
        pub fn scroll(self: *Self, x: f32, y: f32, dx: f32, dy: f32) !Command {
            return self.send(.{ .scroll = .{ .position = .{ .x = x, .y = y }, .dx = dx, .dy = dy, .unit = .line } });
        }

        /// A smooth (pixel-unit) trackpad scroll with an explicit phase (#126).
        pub fn scrollPixel(self: *Self, x: f32, y: f32, dx: f32, dy: f32, phase: event_mod.ScrollPhase) !Command {
            return self.send(.{ .scroll = .{ .position = .{ .x = x, .y = y }, .dx = dx, .dy = dy, .unit = .pixel, .phase = phase } });
        }

        pub fn key(self: *Self, k: event_mod.Key) !Command {
            return self.send(.{ .key_down = .{ .key = k } });
        }

        pub fn keyUp(self: *Self, k: event_mod.Key) !Command {
            return self.send(.{ .key_up = .{ .key = k } });
        }

        /// A primary click carrying keyboard modifiers (#127): shift/⌘-click.
        pub fn clickMods(self: *Self, x: f32, y: f32, mods: event_mod.Modifiers) !Command {
            const cmd = try self.send(.{ .pointer_down = .{ .position = .{ .x = x, .y = y }, .buttons = .{ .primary = true }, .mods = mods } });
            _ = try self.pointerUp(x, y);
            return cmd;
        }

        /// A primary down with an explicit click count (#127): 2 = double.
        pub fn clickN(self: *Self, x: f32, y: f32, count: u8) !Command {
            return self.send(.{ .pointer_down = .{ .position = .{ .x = x, .y = y }, .buttons = .{ .primary = true }, .click_count = count } });
        }

        pub fn pointerEnter(self: *Self, x: f32, y: f32) !Command {
            return self.send(.{ .pointer_enter = .{ .position = .{ .x = x, .y = y } } });
        }

        // --- Drag-and-drop (#128): fake the OS drag sequence headlessly ----

        pub fn dragEnter(self: *Self, x: f32, y: f32, data: event_mod.DragData) !Command {
            return self.send(.{ .drag_enter = .{ .position = .{ .x = x, .y = y }, .data = data } });
        }

        pub fn dragOver(self: *Self, x: f32, y: f32, data: event_mod.DragData) !Command {
            return self.send(.{ .drag_over = .{ .position = .{ .x = x, .y = y }, .data = data } });
        }

        pub fn dragLeave(self: *Self) !Command {
            return self.send(.{ .drag_leave = .{ .position = .{ .x = 0, .y = 0 } } });
        }

        pub fn drop(self: *Self, x: f32, y: f32, data: event_mod.DragData) !Command {
            return self.send(.{ .drop = .{ .position = .{ .x = x, .y = y }, .data = data } });
        }

        /// Replay a full enter→over→drop sequence with one payload — the
        /// canned native-DnD flow apps are tested against (#128/#130).
        pub fn dragDrop(self: *Self, x: f32, y: f32, data: event_mod.DragData) !Command {
            _ = try self.dragEnter(x, y, data);
            _ = try self.dragOver(x, y, data);
            return self.drop(x, y, data);
        }

        pub fn pointerLeave(self: *Self, x: f32, y: f32) !Command {
            return self.send(.{ .pointer_leave = .{ .position = .{ .x = x, .y = y } } });
        }

        // --- Window state (#98) -------------------------------------------

        pub fn windowMinimized(self: *Self) !Command {
            return self.send(.{ .window_minimized = event_mod.main_window });
        }

        pub fn windowMaximized(self: *Self) !Command {
            return self.send(.{ .window_maximized = event_mod.main_window });
        }

        pub fn windowRestored(self: *Self) !Command {
            return self.send(.{ .window_restored = event_mod.main_window });
        }

        pub fn text(self: *Self, codepoint: u21) !Command {
            return self.send(.{ .text = .{ .codepoint = codepoint } });
        }

        /// Inject an IME pre-edit update (#19): the in-progress composition.
        pub fn compose(self: *Self, preedit: []const u8) !Command {
            return self.send(.{ .composition = .{ .phase = .update, .text = preedit, .caret = preedit.len } });
        }

        /// Inject an IME commit (#19): the finalized text to insert.
        pub fn commit(self: *Self, finalized: []const u8) !Command {
            return self.send(.{ .composition = .{ .phase = .commit, .text = finalized } });
        }

        pub fn resize(self: *Self, w: f32, h: f32) !Command {
            self.viewport = .{ .width = w, .height = h };
            const cmd = try self.send(.{ .resized = .{ .size = .{ .width = w, .height = h } } });
            try self.relayout(); // viewport changed regardless of command
            return cmd;
        }

        // --- Playwright-style helpers (#319) ------------------------------

        /// A `.text` event carrying modifiers — e.g. ⌘C / Ctrl+V shortcuts.
        pub fn textMods(self: *Self, codepoint: u21, mods: event_mod.Modifiers) !Command {
            return self.send(.{ .text = .{ .codepoint = codepoint, .mods = mods } });
        }

        /// Type a UTF-8 string into the focused field, one codepoint at a time.
        pub fn typeText(self: *Self, s: []const u8) !void {
            var i: usize = 0;
            while (i < s.len) {
                const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                const cp = std.unicode.utf8Decode(s[i .. i + n]) catch s[i];
                _ = try self.text(cp);
                i += n;
            }
        }

        /// The current value of the TextInput with this id.
        pub fn fieldValue(self: *Self, id: u32) []const u8 {
            _ = self;
            return app_mod.textInputValue(id);
        }

        /// The focused editable field id, or null.
        pub fn focusedFieldId(self: *Self) ?u32 {
            return app_mod.focusedEditFieldId(self.placements());
        }

        /// The text most recently copied to the clipboard (Copy/Cut/⌘C).
        pub fn copiedText(self: *Self) []const u8 {
            _ = self;
            return app_mod.copiedText();
        }

        /// Placement index of the first element whose text contains `needle`.
        pub fn findText(self: *Self, needle: []const u8) ?usize {
            for (self.placements(), 0..) |pl, i| {
                if (pl.element.text) |t| if (std.mem.indexOf(u8, t, needle) != null) return i;
            }
            return null;
        }

        /// Click the center of the first element whose text contains `needle`
        /// (e.g. to focus a field or start a selection). Errors if not found.
        pub fn clickText(self: *Self, needle: []const u8) !Command {
            const idx = self.findText(needle) orelse return error.TextNotFound;
            const r = self.placements()[idx].rect;
            return self.click(r.x + r.width / 2, r.y + r.height / 2);
        }

        /// A secondary (right) click that opens the in-window overlay context
        /// menu where applicable (field / selection), via the production
        /// handleContextMenu path with the headless stand-in window.
        pub fn rightClick(self: *Self, x: f32, y: f32) !Command {
            const ev = Event{ .pointer_down = .{ .position = .{ .x = x, .y = y }, .buttons = .{ .secondary = true } } };
            _ = app_mod.dispatchEvent(Model, Msg, self.model, ev, self.placements());
            const cmd = app_mod.handleContextMenu(Model, Msg, &self.fake_window, self.model, self.placements(), ev);
            self.last_command = cmd;
            if (cmd == .redraw) try self.relayout();
            return cmd;
        }

        /// Whether an overlay context menu is currently open.
        pub fn menuOpen(self: *Self) bool {
            _ = self;
            return app_mod.overlayMenuOpen();
        }

        /// Choose an open overlay menu item by label: render to position the
        /// menu, then click the item. Errors if no such item.
        pub fn chooseMenu(self: *Self, label: []const u8) !Command {
            _ = try self.render(); // sets the menu panel geometry for hit-testing
            const p = app_mod.overlayMenuItemPoint(label) orelse return error.MenuItemNotFound;
            return self.click(p.x, p.y);
        }

        /// Drag-select from (x1,y1) to (x2,y2): pointer down → move → up. Renders
        /// between steps so the field caret/selection (resolved in the render
        /// pass) tracks each point — within a field it selects between the two
        /// points; on read-only text it spans paragraphs.
        pub fn dragSelect(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32) !Command {
            const cmd = try self.pointerDown(x1, y1);
            _ = try self.render(); // resolve the anchor caret
            _ = try self.move(x2, y2);
            _ = try self.render(); // resolve the extended focus caret
            _ = try self.pointerUp(x2, y2);
            return cmd;
        }

        /// The selected substring of the TextInput with this id ("" if none).
        pub fn fieldSelectedText(self: *Self, id: u32) []const u8 {
            _ = self;
            return app_mod.fieldSelectedText(id);
        }

        /// The border-box rect of the placement at `idx`.
        pub fn elementRect(self: *Self, idx: usize) geometry.Rect {
            return self.placements()[idx].rect;
        }

        /// The text of the element at `idx` ("" if it has none).
        pub fn textAt(self: *Self, idx: usize) []const u8 {
            return self.placements()[idx].element.text orelse "";
        }

        /// Paste `text` into the focused field: stage it on a memory clipboard,
        /// send ⌘V, and run the framework's paste-apply (which the real loop does
        /// in frameOsHooks). Headless equivalent of the OS clipboard (#319).
        pub fn paste(self: *Self, clip_text: []const u8) !Command {
            var mc = @import("../clipboard.zig").MemoryClipboard.init(self.gpa);
            defer mc.deinit();
            try mc.interface().setText(clip_text);
            _ = try self.textMods('v', .{ .super = true }); // stages g_field_paste
            const cmd = app_mod.applyPendingPaste(Model, Msg, self.model, mc.interface(), self.gpa);
            self.last_command = cmd;
            if (cmd == .redraw) try self.relayout();
            return cmd;
        }

        // --- Rendering / assertions ---------------------------------------

        /// Render the current frame to the raster backend and return its RGBA
        /// pixels (borrowed; valid until the next render). For pixel assertions
        /// against the golden reference, exactly like the offscreen harness.
        pub fn render(self: *Self) ![]u8 {
            const b = self.raster.interface();
            try b.beginFrame(self.viewport);
            if (self.result) |r| {
                layout_mod.render(b, r);
                // The same overlay passes the real loops run after layout, so
                // tests see focus rings, the caret/selection, ⌘C copy fills, and
                // the in-window menu — not just the base tree (#310/#318/#319).
                app_mod.renderFocusRing(b, r.placements);
                app_mod.renderTextSelection(b, r.placements);
                app_mod.renderTextFields(b, r.placements);
                app_mod.renderMenuOverlay(b, self.viewport);
            }
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
const display_mod = @import("../display.zig");

/// A minimal interactive model: a button that toggles a fill color on click and
/// counts key presses — enough to exercise pointer hit-testing, message
/// dispatch, redraw-driven relayout, and key/text routing.
const Toggle = struct {
    on: bool = false,
    keys: u32 = 0,
    key_ups: u32 = 0,
    chars: u32 = 0,
    scroll_y: f32 = 0,
    entered: bool = false,
    last_mods: event_mod.Modifiers = .{},
    last_count: u8 = 0,
    drag_active: bool = false,
    dropped_files: usize = 0,
    composing: bool = false,
    preedit_len: usize = 0,
    committed_len: usize = 0,
    win_state: enum { normal, minimized, maximized } = .normal,

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
            .key_up => self.key_ups += 1,
            .pointer_enter => self.entered = true,
            .pointer_leave => self.entered = false,
            .window_minimized => self.win_state = .minimized,
            .window_maximized => self.win_state = .maximized,
            .window_restored => self.win_state = .normal,
            .drag_enter, .drag_over => {
                self.drag_active = true;
                return .redraw;
            },
            .drag_leave => {
                self.drag_active = false;
                return .redraw;
            },
            .drop => |dd| {
                self.drag_active = false;
                if (dd.data == .files) self.dropped_files = dd.data.files.len;
                return .redraw;
            },
            .pointer_down => |p| {
                self.last_mods = p.mods;
                self.last_count = p.click_count;
            },
            .text => self.chars += 1,
            .composition => |c| switch (c.phase) {
                .update, .start => {
                    self.composing = true;
                    self.preedit_len = c.text.len;
                },
                .commit => {
                    self.composing = false;
                    self.committed_len += c.text.len;
                },
                .cancel => self.composing = false,
            },
            .scroll => |s| {
                // Clamp to a 0..100 content range — the typical app pattern.
                self.scroll_y = std.math.clamp(self.scroll_y + s.dy * 10, 0, 100);
                return .redraw;
            },
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

// A widget-layer model: built with `viewUi` (host/composite, #4) instead of the
// raw `view`. Proves the driver and the real loops dispatch widget clicks
// through the same path (the thing that was hard to verify by pixel-clicking).
const WidgetApp = struct {
    hit: u32 = 0,
    pub const Msg = enum(u32) { _ };
    pub fn viewUi(self: *WidgetApp, u: *ui_mod.Ui) !ui_mod.Widget {
        _ = self;
        return u.button(.{ .label = "go", .on_click = 7 });
    }
    pub fn update(self: *WidgetApp, msg: Msg) Command {
        self.hit = @intFromEnum(msg);
        return .redraw;
    }
    pub fn onEvent(self: *WidgetApp, ev: event_mod.Event) Command {
        _ = self;
        _ = ev;
        return .none;
    }
};

test "viewUi widget button click dispatches through the real path (#4/#130)" {
    var m: WidgetApp = .{};
    var d = try Driver(WidgetApp, WidgetApp.Msg).init(testing.allocator, &m, .{ .width = 120, .height = 60 });
    defer d.deinit();
    _ = try d.render();
    try testing.expectEqual(@as(u32, 0), m.hit);
    _ = try d.click(2, 2); // inside the top-left button (its padding box)
    try testing.expectEqual(@as(u32, 7), m.hit); // on_click=7 routed to update
}

// A list-backed model: clicking a row selects it (the master/nav pattern, #273).
const ListApp = struct {
    selected: usize = 0,
    pub const Msg = enum(u32) { _ };
    pub fn viewUi(self: *ListApp, u: *ui_mod.Ui) !ui_mod.Widget {
        return u.list(.{ .selected = self.selected, .width = 120 }, &.{
            .{ .label = "Row A", .on_click = 0 },
            .{ .label = "Row B", .on_click = 1 },
            .{ .label = "Row C", .on_click = 2 },
        });
    }
    pub fn update(self: *ListApp, msg: Msg) Command {
        self.selected = @intFromEnum(msg);
        return .redraw;
    }
    pub fn onEvent(self: *ListApp, ev: event_mod.Event) Command {
        _ = self;
        _ = ev;
        return .none;
    }
};

test "viewUi list row click selects through the real path (#273/#130)" {
    var m: ListApp = .{};
    var d = try Driver(ListApp, ListApp.Msg).init(testing.allocator, &m, .{ .width = 140, .height = 140 });
    defer d.deinit();
    _ = try d.render();
    try testing.expectEqual(@as(usize, 0), m.selected);
    // Third row: rows stack from the top with ~2px gap + ~34px row height.
    _ = try d.click(20, 75);
    try testing.expectEqual(@as(usize, 2), m.selected);
}

// An overflowing scroll container with a clickable element reaching the right
// edge — where the auto-hide scrollbar thumb sits.
const HiddenBarApp = struct {
    clicked: bool = false,
    pub const Msg = enum(u32) { hit };
    pub fn viewUi(self: *HiddenBarApp, u: *ui_mod.Ui) !ui_mod.Widget {
        _ = self;
        return u.column(.{ .width = 100, .height = 50, .overflow_y = .auto, .on_scroll = 8888 }, &.{
            try u.column(.{ .width = 100, .height = 40, .on_click = @intFromEnum(Msg.hit) }, &.{}),
            try u.column(.{ .width = 100, .height = 40 }, &.{}),
            try u.column(.{ .width = 100, .height = 40 }, &.{}),
        });
    }
    pub fn update(self: *HiddenBarApp, msg: Msg) Command {
        if (msg == .hit) self.clicked = true;
        return .redraw;
    }
    pub fn onEvent(self: *HiddenBarApp, ev: event_mod.Event) Command {
        _ = self;
        _ = ev;
        return .none;
    }
};

test "auto-hidden scrollbar does not swallow clicks on the content beneath it (#312)" {
    var m: HiddenBarApp = .{};
    var d = try Driver(HiddenBarApp, HiddenBarApp.Msg).init(testing.allocator, &m, .{ .width = 100, .height = 50 });
    defer d.deinit();
    _ = try d.render(); // records the overflow thumb
    // Drive the overlay fully hidden (as it is at rest / long after a scroll),
    // independent of any global fade state left by earlier tests.
    _ = layout_mod.tickScrollbarFade(5_000_000_000);
    // Click the top row at the far-right edge, exactly where the (invisible)
    // thumb sits. It must reach the row's on_click, not be eaten as a drag.
    _ = try d.click(97, 12);
    try testing.expect(m.clicked);
}

// A scroll-view model (#274): wheel events adjust the bound offset, which the
// ScrollView renders; the layout engine clamps it to the content extent.
const ScrollApp = struct {
    offset: f32 = 0,
    pub const Msg = enum(u32) { _ };
    pub fn viewUi(self: *ScrollApp, u: *ui_mod.Ui) !ui_mod.Widget {
        return u.scroll(.{ .width = 100, .height = 60, .scroll_y = self.offset }, &.{
            u.text("line 1", .{}), u.text("line 2", .{}), u.text("line 3", .{}),
            u.text("line 4", .{}), u.text("line 5", .{}), u.text("line 6", .{}),
        });
    }
    pub fn update(self: *ScrollApp, msg: Msg) Command {
        _ = self;
        _ = msg;
        return .none;
    }
    pub fn onEvent(self: *ScrollApp, ev: event_mod.Event) Command {
        switch (ev) {
            .scroll => |s| {
                self.offset = @max(0, self.offset + s.dy * 10);
                return .redraw;
            },
            else => {},
        }
        return .none;
    }
};

test "viewUi scroll view: wheel updates the bound offset (#274/#130)" {
    var m: ScrollApp = .{};
    var d = try Driver(ScrollApp, ScrollApp.Msg).init(testing.allocator, &m, .{ .width = 120, .height = 80 });
    defer d.deinit();
    _ = try d.render();
    try testing.expectEqual(@as(f32, 0), m.offset);
    _ = try d.scroll(20, 20, 0, 3); // wheel down inside the viewport
    try testing.expect(m.offset > 0);
}

// A checkbox-backed model (#277): clicking the control toggles the bound bool.
const CheckApp = struct {
    on: bool = false,
    pub const Msg = enum(u32) { toggle, _ };
    pub fn viewUi(self: *CheckApp, u: *ui_mod.Ui) !ui_mod.Widget {
        return u.checkbox(.{ .checked = self.on, .label = "Enable", .on_change = @intFromEnum(Msg.toggle) });
    }
    pub fn update(self: *CheckApp, msg: Msg) Command {
        if (msg == .toggle) self.on = !self.on;
        return .redraw;
    }
    pub fn onEvent(self: *CheckApp, ev: event_mod.Event) Command {
        _ = self;
        _ = ev;
        return .none;
    }
};

test "viewUi checkbox click toggles through the real path (#277/#130)" {
    var m: CheckApp = .{};
    var d = try Driver(CheckApp, CheckApp.Msg).init(testing.allocator, &m, .{ .width = 160, .height = 40 });
    defer d.deinit();
    _ = try d.render();
    try testing.expect(!m.on);
    _ = try d.click(8, 9); // on the indicator box (top-left of the row)
    try testing.expect(m.on);
}

// A split-view model (#268): dragging the divider resizes the leading pane.
// The app tracks drag state from pointer events and clamps the width.
const SplitApp = struct {
    width: f32 = 200,
    dragging: bool = false,
    pub const Msg = enum(u32) { _ };
    pub fn viewUi(self: *SplitApp, u: *ui_mod.Ui) !ui_mod.Widget {
        return u.split(
            .{ .leading_size = self.width, .divider = 4 },
            try u.column(.{}, &.{u.text("nav", .{})}),
            try u.column(.{}, &.{u.text("content", .{})}),
        );
    }
    pub fn update(self: *SplitApp, msg: Msg) Command {
        _ = self;
        _ = msg;
        return .none;
    }
    pub fn onEvent(self: *SplitApp, ev: event_mod.Event) Command {
        switch (ev) {
            .pointer_down => |p| if (@abs(p.position.x - self.width) <= 6) {
                self.dragging = true;
            },
            .pointer_move => |p| if (self.dragging) {
                self.width = std.math.clamp(p.position.x, 100, 400);
                return .redraw;
            },
            .pointer_up => self.dragging = false,
            else => {},
        }
        return .none;
    }
    pub fn cursor(self: *SplitApp) ?@import("../cursor.zig").Cursor {
        return if (self.dragging) .ew_resize else null;
    }
};

test "viewUi split divider drag resizes the leading pane (#268/#130)" {
    var m: SplitApp = .{};
    var d = try Driver(SplitApp, SplitApp.Msg).init(testing.allocator, &m, .{ .width = 500, .height = 300 });
    defer d.deinit();
    _ = try d.render();
    try testing.expectEqual(@as(f32, 200), m.width);
    // The divider's grab gutter shows the horizontal-resize cursor; the panes don't.
    try testing.expectEqual(@import("../cursor.zig").Cursor.ew_resize, d.cursorAt(202, 150));
    try testing.expectEqual(@import("../cursor.zig").Cursor.default, d.cursorAt(80, 150));
    _ = try d.pointerDown(200, 150); // grab the divider at x≈200
    _ = try d.move(280, 150); // drag right
    // Cursor stays locked to the resize shape mid-drag, even though the pointer
    // (x=280) has outrun the divider's hit rect (now at x≈280 but tested far off).
    try testing.expectEqual(@import("../cursor.zig").Cursor.ew_resize, d.cursorAt(450, 150));
    _ = try d.pointerUp(280, 150);
    try testing.expectEqual(@as(f32, 280), m.width);
    // Released: cursor falls back to geometric resolution (default off the divider).
    try testing.expectEqual(@import("../cursor.zig").Cursor.default, d.cursorAt(450, 150));
    // A press away from the divider does not start a drag.
    _ = try d.pointerDown(50, 150);
    _ = try d.move(120, 150);
    try testing.expectEqual(@as(f32, 280), m.width);
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

test "wheel scroll routes to onEvent and updates + clamps offset" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 40, .height = 20 });
    defer d.deinit();
    const cmd = try d.scroll(10, 10, 0, 3); // 3 lines → +30
    try testing.expectEqual(Command.redraw, cmd);
    try testing.expectApproxEqAbs(@as(f32, 30), model.scroll_y, 1e-3);
    _ = try d.scroll(10, 10, 0, 20); // +200 but clamps at 100
    try testing.expectApproxEqAbs(@as(f32, 100), model.scroll_y, 1e-3);
    _ = try d.scrollPixel(10, 10, 0, -50, .momentum); // back down, clamps at 0
    try testing.expectApproxEqAbs(@as(f32, 0), model.scroll_y, 1e-3);
}

test "key_up routes to onEvent separately from key_down (#127)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    _ = try d.key(.enter);
    _ = try d.keyUp(.enter);
    try testing.expectEqual(@as(u32, 1), model.keys);
    try testing.expectEqual(@as(u32, 1), model.key_ups);
}

test "pointer enter/leave drive hover state (#127)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    _ = try d.pointerEnter(30, 20);
    try testing.expect(model.entered);
    _ = try d.pointerLeave(30, 20);
    try testing.expect(!model.entered); // hover cleared on exit
}

test "modifiers and click-count reach the model (#127)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    // Click empty space (outside the 5,5..45,25 button) so the raw pointer_down
    // routes to onEvent carrying its modifiers + count.
    _ = try d.clickMods(55, 35, .{ .shift = true, .super = true });
    try testing.expect(model.last_mods.shift and model.last_mods.super);
    _ = try d.clickN(55, 35, 2);
    try testing.expectEqual(@as(u8, 2), model.last_count);
}

test "drag enter→over→drop delivers the payload, leave cancels (#128)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    const paths = [_][]const u8{ "/a/one.png", "/a/two.png" };
    _ = try d.dragEnter(30, 20, .unknown);
    try testing.expect(model.drag_active); // hover-accept feedback on
    _ = try d.dragLeave();
    try testing.expect(!model.drag_active); // cancel clears it
    _ = try d.dragDrop(30, 20, .{ .files = &paths });
    try testing.expect(!model.drag_active);
    try testing.expectEqual(@as(usize, 2), model.dropped_files);
}

test "IME composition: preedit then commit (#19)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    _ = try d.compose("ni"); // pinyin in progress
    try testing.expect(model.composing);
    try testing.expectEqual(@as(usize, 2), model.preedit_len);
    _ = try d.commit("你"); // commit the Han character (3 UTF-8 bytes)
    try testing.expect(!model.composing);
    try testing.expectEqual(@as(usize, 3), model.committed_len);
}

test "resize storm coalesces to one relayout at the final size (#27)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 100, .height = 60 });
    defer d.deinit();
    // The run-loop pattern: feed every OS resize to a coalescer, then apply
    // at most one relayout per frame at the final size.
    var c = display_mod.Coalescer.init(.{ .size = .{ .width = 100, .height = 60 }, .scale = 1 });
    var w: f32 = 101;
    while (w <= 160) : (w += 1) c.postSize(w, 90);
    const m = c.take().?; // one coalesced update for the whole burst
    try testing.expectEqual(@as(?display_mod.Metrics, null), c.take()); // no second relayout
    _ = try d.resize(m.size.width, m.size.height);
    const px = try d.render();
    try testing.expectEqual(@as(usize, 160 * 90 * 4), px.len); // laid out at the final size
}

test "window-state events normalize into the model (#98)" {
    var model: Toggle = .{};
    var d = try Driver(Toggle, Toggle.Msg).init(testing.allocator, &model, .{ .width = 60, .height = 40 });
    defer d.deinit();
    _ = try d.windowMaximized();
    try testing.expectEqual(@as(@TypeOf(model.win_state), .maximized), model.win_state);
    _ = try d.windowMinimized();
    try testing.expectEqual(@as(@TypeOf(model.win_state), .minimized), model.win_state);
    _ = try d.windowRestored();
    try testing.expectEqual(@as(@TypeOf(model.win_state), .normal), model.win_state);
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

// --- #319 text editing: field, selection, clipboard, overlay menu ----------
// A widget model with an editable field (id 9001, seeded "abc") and two
// selectable paragraphs — exercised headlessly through the real dispatch +
// render passes the Driver now runs.
const EditApp = struct {
    pub const Msg = enum(u32) { _ };
    pub fn viewUi(self: *EditApp, u: *ui_mod.Ui) !ui_mod.Widget {
        _ = self;
        return u.column(.{ .gap = 6 }, &.{
            u.textInput(.{ .id = 9001, .value = "abc", .width = 200 }),
            u.text("alpha", .{ .selectable = true }),
            u.text("omega", .{ .selectable = true }),
        });
    }
    pub fn update(self: *EditApp, msg: Msg) Command {
        _ = self;
        _ = msg;
        return .redraw;
    }
    pub fn onEvent(self: *EditApp, ev: event_mod.Event) Command {
        _ = self;
        _ = ev;
        return .none;
    }
};

fn editDriver(m: *EditApp) !Driver(EditApp, EditApp.Msg) {
    app_mod.resetForTest();
    return Driver(EditApp, EditApp.Msg).init(testing.allocator, m, .{ .width = 240, .height = 140 });
}

test "#319 click focuses a TextInput and typing updates its value" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    _ = try d.clickText("abc");
    try testing.expectEqual(@as(?u32, 9001), d.focusedFieldId());
    try d.typeText("Z"); // caret seeded at end → "abcZ"
    try testing.expectEqualStrings("abcZ", d.fieldValue(9001));
}

test "#319 backspace deletes the codepoint before the caret" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    _ = try d.clickText("abc");
    _ = try d.key(.backspace);
    try testing.expectEqualStrings("ab", d.fieldValue(9001));
}

test "#319 select-all + copy stages the field text on the clipboard" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    _ = try d.clickText("abc");
    _ = try d.textMods('a', .{ .super = true }); // ⌘A
    _ = try d.textMods('c', .{ .super = true }); // ⌘C
    try testing.expectEqualStrings("abc", d.copiedText());
}

test "#319 cut copies the selection and clears the field" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    _ = try d.clickText("abc");
    _ = try d.textMods('a', .{ .super = true });
    _ = try d.textMods('x', .{ .super = true }); // ⌘X
    try testing.expectEqualStrings("abc", d.copiedText());
    try testing.expectEqualStrings("", d.fieldValue(9001));
}

test "#319 overlay context menu Select All targets the clicked field" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    const fr = d.placements()[d.findText("abc").?].rect;
    _ = try d.rightClick(fr.x + fr.width / 2, fr.y + fr.height / 2);
    try testing.expect(d.menuOpen());
    _ = try d.chooseMenu("Select All");
    try testing.expect(!d.menuOpen()); // closed after a choice
    _ = try d.textMods('c', .{ .super = true });
    try testing.expectEqualStrings("abc", d.copiedText());
}

test "#319 drag-select across paragraphs and ⌘C joins them with a newline" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    const a = d.placements()[d.findText("alpha").?].rect;
    const o = d.placements()[d.findText("omega").?].rect;
    _ = try d.pointerDown(a.x, a.y + a.height / 2); // start at alpha's left edge
    _ = try d.move(o.x + o.width - 0.5, o.y + o.height / 2); // into omega, near its end
    _ = try d.pointerUp(o.x + o.width - 0.5, o.y + o.height / 2);
    _ = try d.textMods('c', .{ .super = true });
    _ = try d.render(); // renderTextSelection fills the copy buffer across elements
    try testing.expect(std.mem.startsWith(u8, d.copiedText(), "alpha\n")); // alpha full + join
    try testing.expect(std.mem.indexOf(u8, d.copiedText(), "o") != null); // some of omega
}

test "#319 paste inserts the clipboard text at the caret" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    defer d.deinit();
    _ = try d.clickText("abc"); // focus, caret seeded at end
    _ = try d.paste("XY"); // "abc" + "XY"
    try testing.expectEqualStrings("abcXY", d.fieldValue(9001));
}

test "#319 clicking inside a field places the caret (type inserts there)" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    d.setFont(@import("../root.zig").test_font_ttf) catch {}; // real metrics for caret math
    defer d.deinit();
    const fr = d.placements()[d.findText("abc").?].rect;
    // Click near the left edge of the field → caret before 'a'; render resolves it.
    _ = try d.click(fr.x + 2, fr.y + fr.height / 2);
    _ = try d.render(); // resolves the pending caret-click to an offset
    _ = try d.text('Z'); // inserts at the caret (start), not the end
    try testing.expectEqualStrings("Zabc", d.fieldValue(9001));
}

test "#319 mouse drag-selects text within a field" {
    var m: EditApp = .{};
    var d = try editDriver(&m);
    d.setFont(@import("../root.zig").test_font_ttf) catch {}; // real metrics for caret math
    defer d.deinit();
    const fr = d.placements()[d.findText("abc").?].rect;
    const midy = fr.y + fr.height / 2;
    // Drag from the left edge (before 'a') to past the right edge (after 'c').
    _ = try d.dragSelect(fr.x + 1, midy, fr.x + fr.width + 20, midy);
    try testing.expectEqualStrings("abc", d.fieldSelectedText(9001));
    // The selection is now copyable.
    _ = try d.textMods('c', .{ .super = true });
    try testing.expectEqualStrings("abc", d.copiedText());
}
