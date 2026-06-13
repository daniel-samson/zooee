const std = @import("std");

// Build layout. `zig build` builds only the library; everything else lives
// under an explicit step (see `zig build --help`):
//   default (`zig build`) — libzooee static library
//   test       — unit tests
//   check      — automated GPU backend self-checks (GL #11 / D3D11 #12) +
//                the visual-diff helper. CI builds this, then runs the
//                self-check binaries.
//   visual-test— render fixtures and compare against PPM goldens (#13)
//   demos      — the runnable demo apps: terminal + native GUI window
//                (macOS → GL/Raster .app bundles)
//   run / run-gui — run the terminal / GUI demo
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    // The zooee library module. Each native window/GPU backend links its
    // platform API: AppKit + OpenGL (macOS), X11 + GL/GLX (Linux), D3D11 +
    // DXGI (Windows). D3DCompile is loaded at runtime (no import lib).
    const mod = b.addModule("zooee", .{ .root_source_file = b.path("src/root.zig"), .target = target });
    switch (os) {
        .macos => {
            mod.linkFramework("AppKit", .{});
            mod.linkFramework("OpenGL", .{}); // CGL/NSOpenGL (#11)
            mod.linkFramework("Metal", .{}); // (#101)
            mod.linkFramework("QuartzCore", .{}); // CAMetalLayer (#101)
            mod.link_libc = true; // dlsym for GL proc resolution
        },
        .linux => {
            mod.link_libc = true;
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("GL", .{}); // GLX (#11)
        },
        .windows => {
            mod.linkSystemLibrary("d3d11", .{}); // (#12)
            mod.linkSystemLibrary("dxgi", .{});
        },
        else => {},
    }
    // OFL Poppins for the font pipeline (#10): tests/goldens only.
    mod.addAnonymousImport("poppins", .{ .root_source_file = b.path("testdata/fonts/Poppins-Regular.ttf") });

    // --- default: the library ----------------------------------------------
    const lib = b.addLibrary(.{ .name = "zooee", .linkage = .static, .root_module = mod });
    b.installArtifact(lib);

    // --- clean -------------------------------------------------------------
    // Removes the install output (zig-out). The incremental cache (.zig-cache)
    // is held open by the build runner, so it can't be cleared from within a
    // step — delete it by hand for a fully cold build:
    //   rm -rf .zig-cache zig-out
    const clean_step = b.step("clean", "Remove the build output (zig-out)");
    const rm = if (@import("builtin").os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/c", "if exist zig-out rmdir /s /q zig-out" })
    else
        b.addSystemCommand(&.{ "rm", "-rf", "zig-out" });
    rm.has_side_effects = true; // always run; never cached
    clean_step.dependOn(&rm.step);

    // --- test --------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // --- check: automated GPU backend self-checks --------------------------
    // These are CI tests, not demos: they self-check (assert bad_frac vs the
    // raster reference) and exit. CI builds `check`, then runs the binaries.
    const check_step = b.step("check", "Build the automated GPU backend self-checks");
    // visual-diff: image comparison helper used by the e2e capture check.
    check_step.dependOn(&b.addInstallArtifact(addExe(b, target, optimize, null, "visual-diff", "tools/visual_diff.zig"), .{}).step);
    // GPU self-checks are platform-exclusive: GL on Linux, Metal on macOS,
    // D3D11 on Windows.
    if (os == .linux) {
        check_step.dependOn(&b.addInstallArtifact(addExe(b, target, optimize, mod, "zooee-gl-check", "examples/gl_demo.zig"), .{}).step);
    }
    if (os == .macos) {
        check_step.dependOn(&b.addInstallArtifact(addExe(b, target, optimize, mod, "zooee-metal-check", "examples/metal_demo.zig"), .{}).step);
    }
    if (os == .windows) {
        check_step.dependOn(&b.addInstallArtifact(addExe(b, target, optimize, mod, "zooee-d3d11-check", "examples/d3d11_demo.zig"), .{}).step);
    }

    // visual-test: render fixtures through raster and compare to goldens.
    const visual_test = addExe(b, target, optimize, mod, "visual-test", "tools/visual_test.zig");
    const run_visual_test = b.addRunArtifact(visual_test);
    run_visual_test.addArg(b.pathFromRoot("testdata/visual"));
    if (b.args) |args| run_visual_test.addArgs(args); // forward --update
    b.step("visual-test", "Render scene fixtures and compare against PPM goldens").dependOn(&run_visual_test.step);

    // --- demos: the runnable apps ------------------------------------------
    const demos_step = b.step("demos", "Build the runnable demo apps");
    // Terminal demo.
    demos_step.dependOn(&b.addInstallArtifact(addExe(b, target, optimize, mod, "zooee", "src/main.zig"), .{}).step);
    // Native GUI window demo(s).
    switch (os) {
        .macos => {
            // One .app: Metal (#101) with the raster fallback built in. Force
            // the raster path for QA with ZOOEE_SOFTWARE=1 — no separate app
            // needed (raster's other role, the golden reference, is headless).
            installMacApp(b, demos_step, guiDemo(b, mod, target, optimize, "zooee-gui-demo", false), "Zooee", "zooee-gui-demo");
        },
        .windows => {
            const gui = guiDemo(b, mod, target, optimize, "zooee-gui-demo", false);
            gui.subsystem = .Windows; // no console window for a GUI app
            demos_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
        },
        .linux => {
            const gui = guiDemo(b, mod, target, optimize, "zooee-gui-demo", false);
            demos_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
        },
        else => {},
    }

    // run / run-gui: convenience runners.
    const run = b.addRunArtifact(addExe(b, target, optimize, mod, "zooee-run", "src/main.zig"));
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the terminal demo").dependOn(&run.step);
    if (os == .macos or os == .windows or os == .linux) {
        b.step("run-gui", "Run the native GUI demo (GPU path)")
            .dependOn(&b.addRunArtifact(guiDemo(b, mod, target, optimize, "zooee-gui-run", false)).step);
    }
}

/// An executable importing the zooee module (or none, for a standalone tool).
fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: ?*std.Build.Module,
    name: []const u8,
    src: []const u8,
) *std.Build.Step.Compile {
    const imports: []const std.Build.Module.Import = if (mod) |m|
        &.{.{ .name = "zooee", .module = m }}
    else
        &.{};
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
}

/// The GUI demo with the renderer baked in via the `force_software` build
/// option (a GL/GPU variant vs a raster variant).
fn guiDemo(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    force_software: bool,
) *std.Build.Step.Compile {
    const exe = addExe(b, target, optimize, mod, name, "examples/gui_demo.zig");
    const opts = b.addOptions();
    opts.addOption(bool, "force_software", force_software);
    exe.root_module.addOptions("build_options", opts);
    return exe;
}

/// Install `exe` as `<app_name>.app` (macOS bundle) and wire it to `step`.
fn installMacApp(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    app_name: []const u8,
    exec_name: []const u8,
) void {
    const bin = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}.app/Contents/MacOS", .{app_name}) } },
    });
    const plist_text = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\  <key>CFBundleIdentifier</key><string>dev.zooee.{s}</string>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\</dict></plist>
        \\
    , .{ exec_name, app_name, exec_name });
    const plist = b.addWriteFiles().add("Info.plist", plist_text);
    const plist_install = b.addInstallFile(plist, b.fmt("{s}.app/Contents/Info.plist", .{app_name}));
    step.dependOn(&bin.step);
    step.dependOn(&plist_install.step);
}
