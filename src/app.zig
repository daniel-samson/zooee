//! App architecture (#4): the framework's model–view–update loop.
//!
//! Elm-shaped, which fits Zig (no closures needed):
//! - The app is a Model struct with three callbacks:
//!     view(*Model, gpa) !*const Element    — build the UI tree (arena-owned)
//!     update(*Model, Msg) Command          — react to messages
//!     onEvent(*Model, Event) Command       — raw events not turned into messages
//! - Elements carry optional interaction messages (`on_click`, hover via
//!   `hover_msg`); the framework hit-tests pointer events against the
//!   layout result and dispatches the element's message to update().
//! - `Command` tells the loop what to do: redraw, quit, or nothing.
//!
//! v1 runs on the terminal session; the same loop shape extends to GPU
//! windows (#9/#12) since input arrives as the same core events.

const std = @import("std");
const builtin = @import("builtin");
const layout_mod = @import("layout.zig");
const event_mod = @import("event.zig");
const backend_mod = @import("backend.zig");
const terminal_mod = @import("backends/terminal.zig");
const raster_mod = @import("backends/raster.zig");
const system_font = @import("font/system.zig");
const geometry = @import("geometry.zig");

pub const Command = enum { none, redraw, quit };

/// Native window platform for the GUI runner. X11 is the #9 follow-up;
/// unsupported OSes get an empty struct (runWindow @compileErrors before
/// touching it). Comptime if only analyzes the taken arm.
const has_window_platform = builtin.os.tag == .windows or builtin.os.tag == .macos or builtin.os.tag == .linux;
const WindowPlatform = if (builtin.os.tag == .windows)
    @import("platform/win32.zig")
else if (builtin.os.tag == .macos)
    @import("platform/macos.zig")
else if (builtin.os.tag == .linux)
    @import("platform/x11.zig")
else
    struct {};

const Session = if (builtin.os.tag == .windows)
    @import("platform/win32_console.zig").Console
else
    @import("platform/posix_tty.zig").Tty;

const session_mod = if (builtin.os.tag == .windows)
    @import("platform/win32_console.zig")
else
    @import("platform/posix_tty.zig");

/// Run a Model as a terminal app. Msg is the app's message type
/// (any integer-backed enum or integer type).
pub fn run(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    init: std.process.Init,
) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    terminal_mod.setupConsole();
    var term = terminal_mod.TerminalBackend.init(gpa);
    defer term.deinit();
    const b = term.interface();

    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var session = Session.init() catch {
        // Not a TTY: render one frame plainly and exit (CI-safe).
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        const root = try model.view(frame_arena.allocator(), 1);
        var result = try layout_mod.layout(frame_arena.allocator(), b, root, .{ .width = 60, .height = 14 });
        try b.beginFrame(.{ .width = 60, .height = 14 });
        layout_mod.render(b, result);
        try b.endFrame();
        result.deinit(frame_arena.allocator());
        const text = try term.renderToText(gpa);
        defer gpa.free(text);
        try out.writeAll(text);
        try out.flush();
        return;
    };
    try session.enableRaw();
    defer session.deinit();
    try out.writeAll(session_mod.enter_tui_seq);
    try out.flush();

    var dirty = true;
    var placements: []layout_mod.Placement = &.{};
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    loop: while (true) {
        if (dirty) {
            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const root = try model.view(arena, 1);
            const viewport = session.size();
            const result = try layout_mod.layout(arena, b, root, viewport);
            placements = result.placements;
            try b.beginFrame(viewport);
            layout_mod.render(b, result);
            try b.endFrame();
            try term.present(out);
            try out.flush();
            dirty = false;
        }

        const events = try session.pumpEvents(frame_arena.allocator());
        for (events) |ev| {
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
        }

        if (!dirty) try io.sleep(.fromMilliseconds(16), .awake);
    }
}

/// Run a Model in a native GUI window: layout → raster backend → blit,
/// with pointer/keyboard events dispatched exactly as the terminal loop
/// (#4/#9). Loads a system font (#10) so text renders. Coordinates are
/// content pixels on both axes, matching the rendered framebuffer.
pub fn runWindow(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    init: std.process.Init,
    opts: WindowOptions,
) !void {
    if (!has_window_platform) @compileError("runWindow: no native window platform for this OS (X11 is #9 follow-up)");
    const platform = WindowPlatform;
    const gpa = init.arena.allocator();
    const io = init.io;

    const window = try platform.Window.create(gpa, .{ .title = opts.title, .width = opts.width, .height = opts.height });
    defer window.destroy();

    var raster = raster_mod.RasterBackend.init(gpa);
    defer raster.deinit();
    _ = system_font.loadInto(gpa, io, &raster); // placeholder blocks if none found
    const b = raster.interface();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    var placements: []layout_mod.Placement = &.{};
    var dirty = true;

    loop: while (true) {
        for (window.pumpEvents()) |ev| {
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
        }

        if (dirty) {
            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const px = platform.contentPixelSize(window);
            const scale: f32 = @floatCast(px.scale);
            raster.char_width = 8 * scale;
            raster.line_height = 16 * scale;
            const root = try model.view(arena, scale);
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = try layout_mod.layout(arena, b, root, viewport);
            placements = result.placements;
            try b.beginFrame(viewport);
            layout_mod.render(b, result);
            try b.endFrame();
            platform.blit(window, raster.pixels, raster.width, raster.height);
            dirty = false;
        }

        try io.sleep(.fromMilliseconds(16), .awake);
    }
}

pub const WindowOptions = struct {
    title: [:0]const u8 = "zooee",
    width: u32 = 800,
    height: u32 = 600,
};

/// Map one event to a Command, dispatching interaction messages through
/// the model. Shared by the terminal and GUI loops.
fn dispatch(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    ev: event_mod.Event,
    placements: []const layout_mod.Placement,
) Command {
    return switch (ev) {
        .close_requested => .quit,
        .resized => .redraw,
        .pointer_down => |p| blk: {
            if (p.buttons.primary) {
                if (hitMsg(placements, p.position, .click)) |m| {
                    break :blk model.update(@as(Msg, @enumFromInt(m)));
                }
            }
            break :blk model.onEvent(ev);
        },
        .pointer_move => |p| blk: {
            if (hitMsg(placements, p.position, .hover)) |m| {
                break :blk model.update(@as(Msg, @enumFromInt(m)));
            }
            break :blk model.onEvent(ev);
        },
        else => model.onEvent(ev),
    };
}

const Interaction = enum { click, hover };

/// Topmost (last-placed) element containing the point that carries the
/// requested message kind.
fn hitMsg(placements: []const layout_mod.Placement, p: geometry.Point, kind: Interaction) ?u32 {
    var found: ?u32 = null;
    for (placements) |pl| {
        if (!pl.rect.contains(p)) continue;
        const msg = switch (kind) {
            .click => pl.element.on_click,
            .hover => pl.element.on_hover,
        };
        if (msg) |m| found = m;
    }
    return found;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const record = @import("backends/record.zig");

test "hitMsg picks the topmost interactive element" {
    const e1: layout_mod.Element = .{ .on_click = 1 };
    const e2: layout_mod.Element = .{ .on_click = 2 };
    const placements = [_]layout_mod.Placement{
        .{ .element = &e1, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .element = &e2, .rect = .{ .x = 2, .y = 2, .width = 4, .height = 4 } },
    };
    try testing.expectEqual(@as(?u32, 2), hitMsg(&placements, .{ .x = 3, .y = 3 }, .click));
    try testing.expectEqual(@as(?u32, 1), hitMsg(&placements, .{ .x = 8, .y = 8 }, .click));
    try testing.expectEqual(@as(?u32, null), hitMsg(&placements, .{ .x = 50, .y = 50 }, .click));
}
