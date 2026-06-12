//! Native window demo (Windows-only build artifact): opens a real Win32
//! window and runs the event pump until closed. The e2e visual test
//! captures its client area on the self-hosted runner (#13). The client
//! area stays unpainted (white) until a GPU backend attaches (#12).

const std = @import("std");
const zooee = @import("zooee");
const win32 = zooee.platform.win32;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const w = try win32.Window.create(gpa, .{
        .title = "zooee window demo",
        .width = 520,
        .height = 260,
        .visible = true,
    });
    defer w.destroy();

    outer: while (true) {
        for (w.pumpEvents()) |ev| switch (ev) {
            .close_requested => break :outer,
            else => {},
        };
        try io.sleep(.fromMilliseconds(16), .awake);
    }
}
