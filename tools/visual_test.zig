//! visual-test: offscreen screenshot harness (#13). Renders every scene
//! fixture AND the full-app fixture through the CPU raster backend —
//! headless, no window — and byte-compares against checked-in PPM
//! goldens. The PPM goldens ARE the screenshots; CI uploads them (and
//! any <name>.actual.ppm on mismatch) as artifacts.
//!
//! Usage: visual-test <goldens-dir> [--update]
//!
//! The raster backend is deterministic, so comparison is exact.
//! `--update` rewrites the goldens — do this only for intentional
//! rendering changes, and eyeball the images first.
//!
//! GPU backends (#11/#12/#15) plug into the SAME harness: render the
//! same fixtures to an offscreen FBO/render-target, read pixels back,
//! and compare against these raster goldens with a perceptual tolerance
//! (tools/visual-diff), since AA differs across drivers.

const std = @import("std");
const zooee = @import("zooee");

const scale: f32 = 8;

const State = struct {
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    gpa: std.mem.Allocator,
    update: bool,
    failures: usize = 0,

    /// Compare one offscreen render against its golden (or update it).
    fn check(self: *State, name: []const u8, actual: []const u8) !void {
        const golden_name = try std.fmt.allocPrint(self.gpa, "{s}.ppm", .{name});
        if (self.update) {
            try self.dir.writeFile(self.io, .{ .sub_path = golden_name, .data = actual });
            std.debug.print("visual-test: updated {s}/{s}\n", .{ self.dir_path, golden_name });
            return;
        }
        const golden = self.dir.readFileAlloc(self.io, golden_name, self.gpa, .limited(64 * 1024 * 1024)) catch |err| {
            std.debug.print("visual-test: {s}: missing golden ({t}) — run with --update\n", .{ name, err });
            self.failures += 1;
            return;
        };
        if (!std.mem.eql(u8, golden, actual)) {
            const actual_name = try std.fmt.allocPrint(self.gpa, "{s}.actual.ppm", .{name});
            try self.dir.writeFile(self.io, .{ .sub_path = actual_name, .data = actual });
            std.debug.print("visual-test: MISMATCH {s} — wrote {s}/{s}\n", .{ name, self.dir_path, actual_name });
            self.failures += 1;
        } else {
            std.debug.print("visual-test: ok {s}\n", .{name});
        }
    }
};

fn ppmOf(gpa: std.mem.Allocator, ras: *zooee.backends.raster.RasterBackend) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    try ras.writePpm(&w.writer);
    return w.toArrayList().items;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print("usage: visual-test <goldens-dir> [--update]\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const dir_path = args[1];

    const cwd: std.Io.Dir = .cwd();
    var component_it = std.fs.path.componentIterator(dir_path);
    while (component_it.next()) |component| {
        cwd.createDir(io, component.path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    var state: State = .{
        .io = io,
        .dir = dir,
        .dir_path = dir_path,
        .gpa = gpa,
        .update = args.len > 2 and std.mem.eql(u8, args[2], "--update"),
    };

    // Raw-draw + layout scene fixtures.
    for (zooee.fixtures.all) |scene| {
        var ras = zooee.backends.raster.RasterBackend.init(gpa);
        defer ras.deinit();
        try ras.setFont(zooee.test_font_ttf);
        try zooee.fixtures.run(scene, ras.interface(), scale);
        try state.check(scene.name, try ppmOf(gpa, &ras));
    }

    // Full-app fixture: a Model rendered offscreen through the entire
    // view → layout → text → raster stack (zooee.app.renderOffscreen) —
    // the real app path, screenshotted headlessly.
    {
        var ras = zooee.backends.raster.RasterBackend.init(gpa);
        defer ras.deinit();
        try ras.setFont(zooee.test_font_ttf);
        var model: zooee.app_fixtures.Checklist = .{};
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();
        var result = try zooee.app.renderOffscreen(
            zooee.app_fixtures.Checklist,
            &model,
            ras.interface(),
            frame.allocator(),
            .{ .width = 360, .height = 190 },
            1,
        );
        result.deinit(frame.allocator());
        try state.check("app_checklist", try ppmOf(gpa, &ras));
    }

    if (state.failures > 0) {
        std.debug.print("visual-test: {d} failure(s)\n", .{state.failures});
        std.process.exit(1);
    }
}
