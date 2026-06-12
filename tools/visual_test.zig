//! visual-test: render every scene fixture through the CPU raster backend
//! and compare byte-exactly against checked-in PPM goldens (#13).
//!
//! Usage: visual-test <goldens-dir> [--update]
//!
//! The raster backend is deterministic, so comparison is exact. On
//! mismatch the actual image is written next to the golden as
//! <name>.actual.ppm (CI uploads these as failure artifacts) and the
//! exit code is 1. `--update` rewrites the goldens — do this only for
//! intentional rendering changes, and eyeball the images first.

const std = @import("std");
const zooee = @import("zooee");

const scale: f32 = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print("usage: visual-test <goldens-dir> [--update]\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const dir_path = args[1];
    const update = args.len > 2 and std.mem.eql(u8, args[2], "--update");

    const cwd: std.Io.Dir = .cwd();
    // createDir is not recursive; create each component, tolerating existing.
    var component_it = std.fs.path.componentIterator(dir_path);
    while (component_it.next()) |component| {
        cwd.createDir(io, component.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var failures: usize = 0;
    for (zooee.fixtures.all) |scene| {
        var ras = zooee.backends.raster.RasterBackend.init(gpa);
        defer ras.deinit();
        try ras.setFont(zooee.test_font_ttf);
        try zooee.fixtures.run(scene, ras.interface(), scale);

        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &actual);
        try ras.writePpm(&aw.writer);
        actual = aw.toArrayList();

        const golden_name = try std.fmt.allocPrint(gpa, "{s}.ppm", .{scene.name});

        if (update) {
            try dir.writeFile(io, .{ .sub_path = golden_name, .data = actual.items });
            std.debug.print("visual-test: updated {s}/{s}\n", .{ dir_path, golden_name });
            continue;
        }

        const golden = dir.readFileAlloc(io, golden_name, gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("visual-test: {s}: missing golden {s} ({t}) — run with --update\n", .{ scene.name, golden_name, err });
            failures += 1;
            continue;
        };

        if (!std.mem.eql(u8, golden, actual.items)) {
            const actual_name = try std.fmt.allocPrint(gpa, "{s}.actual.ppm", .{scene.name});
            try dir.writeFile(io, .{ .sub_path = actual_name, .data = actual.items });
            std.debug.print("visual-test: MISMATCH {s} — wrote {s}/{s}\n", .{ scene.name, dir_path, actual_name });
            failures += 1;
        } else {
            std.debug.print("visual-test: ok {s}\n", .{scene.name});
        }
    }

    if (failures > 0) {
        std.debug.print("visual-test: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    }
}
