//! Interactive terminal demo: a selectable list rendered through the
//! layout engine, driven by the event layer. QA surface for #3/#5/#7.
//!
//! Controls: ↑/↓ move · space/enter toggle · q or ctrl-c quit.
//! Falls back to a single static frame when stdout isn't a TTY (CI).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zooee = @import("zooee");

// Restore the terminal before any panic stack trace (#25).
pub const panic = if (builtin.os.tag != .windows)
    std.debug.FullPanic(zooee.platform.posix_tty.panicRestore)
else
    std.debug.FullPanic(std.debug.defaultPanic);

const items = [_][]const u8{ "Terminal backend", "Raster backend", "Win32 windowing", "Layout engine", "Event layer" };

const State = struct {
    selected: usize = 0,
    checked: [items.len]bool = .{ true, true, true, true, false },
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    zooee.backends.terminal.setupConsole();
    var term = zooee.backends.terminal.TerminalBackend.init(arena);
    defer term.deinit();
    const b = term.interface();

    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var state: State = .{};

    if (builtin.os.tag == .windows) {
        // Windows console input is a #7 follow-up: render one frame.
        try renderFrame(arena, b, &term, &state, .{ .width = 44, .height = 12 });
        try dumpPlain(&term, arena, out);
        return;
    }

    var tty = zooee.platform.posix_tty.Tty.init() catch {
        // Not a TTY (CI, pipes): render one static frame and exit.
        try renderFrame(arena, b, &term, &state, .{ .width = 44, .height = 12 });
        try dumpPlain(&term, arena, out);
        return;
    };
    try tty.enableRaw();
    defer tty.deinit();

    try out.writeAll("\x1b[?1049h\x1b[?25l"); // alternate screen, hide cursor
    try out.flush();

    var dirty = true;
    loop: while (true) {
        if (dirty) {
            try renderFrame(arena, b, &term, &state, tty.size());
            try term.present(out);
            try out.flush();
            dirty = false;
        }

        const events = try tty.pumpEvents(arena);
        for (events) |ev| switch (ev) {
            .close_requested => break :loop,
            .resized => dirty = true,
            .key_down => |k| switch (k.key) {
                .up => {
                    state.selected = if (state.selected == 0) items.len - 1 else state.selected - 1;
                    dirty = true;
                },
                .down => {
                    state.selected = (state.selected + 1) % items.len;
                    dirty = true;
                },
                .enter => {
                    state.checked[state.selected] = !state.checked[state.selected];
                    dirty = true;
                },
                .escape => break :loop,
                else => {},
            },
            .text => |t| switch (t.codepoint) {
                'q' => break :loop,
                ' ' => {
                    state.checked[state.selected] = !state.checked[state.selected];
                    dirty = true;
                },
                else => {},
            },
            else => {},
        };

        if (!dirty) try io.sleep(.fromMilliseconds(16), .awake);
    }
}

fn renderFrame(
    gpa: std.mem.Allocator,
    b: zooee.Backend,
    term: *zooee.backends.terminal.TerminalBackend,
    state: *const State,
    viewport: zooee.Size,
) !void {
    _ = term;
    const L = zooee.layout;

    var labels: [items.len][32]u8 = undefined;
    var rows: [items.len]L.Element = undefined;
    for (items, 0..) |item, i| {
        const mark: []const u8 = if (state.checked[i]) "[x] " else "[ ] ";
        const cursor: []const u8 = if (state.selected == i) "> " else "  ";
        const text = try std.fmt.bufPrint(&labels[i], "{s}{s}{s}", .{ cursor, mark, item });
        rows[i] = .{
            .text = text,
            .text_style = if (state.selected == i)
                .{ .color = .{ .r = 0, .g = 120, .b = 255 }, .bold = true }
            else
                .{ .color = .black },
        };
    }

    var rows_ptrs: [items.len]*const L.Element = undefined;
    for (&rows, 0..) |*r, i| rows_ptrs[i] = r;

    const title: L.Element = .{ .text = "zooee demo — ↑/↓ move · space toggle · q quit", .text_style = .{ .bold = true } };
    const list: L.Element = .{
        .direction = .column,
        .padding = .symmetric(2, 1),
        .rect_style = .{ .border = .all(1, .black), .corner_radius = .all(1) },
        .children = &rows_ptrs,
    };
    const root: L.Element = .{
        .direction = .column,
        .padding = .all(1),
        .gap = 1,
        .children = &.{ &title, &list },
    };

    var result = try L.layout(gpa, b, &root, viewport);
    defer result.deinit(gpa);
    try b.beginFrame(viewport);
    L.render(b, result);
    try b.endFrame();
}

fn dumpPlain(term: *zooee.backends.terminal.TerminalBackend, gpa: std.mem.Allocator, out: *Io.Writer) !void {
    const text = try term.renderToText(gpa);
    defer gpa.free(text);
    try out.writeAll(text);
    try out.flush();
}
