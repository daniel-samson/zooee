//! Demo executable: draws a small scene through the terminal backend and
//! prints it. Grows into the gallery app (#24) as components land.

const std = @import("std");
const Io = std.Io;
const zooee = @import("zooee");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var term = zooee.backends.terminal.TerminalBackend.init(arena);
    defer term.deinit();
    const b = term.interface();

    try b.beginFrame(.{ .width = 44, .height = 7 });
    b.drawRect(
        .{ .x = 1, .y = 1, .width = 42, .height = 5 },
        .{ .border = .{ .width = 1 }, .corner_radius = 2 },
    );
    b.drawText(.{ .x = 4, .y = 3 }, "hello from zooee's terminal backend", .{});
    try b.endFrame();

    const text = try term.renderToText(arena);
    try out.writeAll(text);
    try out.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
