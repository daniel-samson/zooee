//! Demo executable. For now: drives the recording backend through a tiny
//! scene and dumps the captured command list — the smallest end-to-end
//! exercise of the draw-primitive interface. Real backends replace this
//! as they land (#7, #11, #12, #15).

const std = @import("std");
const Io = std.Io;
const zooee = @import("zooee");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var rec = zooee.backends.record.RecordBackend.init(arena);
    defer rec.deinit();
    const b = rec.interface();

    try b.beginFrame(.{ .width = 80, .height = 24 });
    b.drawRect(
        .{ .x = 2, .y = 1, .width = 40, .height = 5 },
        .{ .background = zooee.Color.white, .border = .{ .width = 1 }, .corner_radius = 2 },
    );
    b.drawText(.{ .x = 4, .y = 3 }, "hello from zooee", .{});
    try b.endFrame();

    try out.print("zooee demo — recorded {d} draw commands:\n", .{rec.commands.items.len});
    for (rec.commands.items) |cmd| {
        try out.print("  {t}\n", .{cmd});
    }
    try out.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
