const std = @import("std");

// Build layout (grouped into top-level steps; see `zig build --help`):
//   default (`zig build`) — the terminal app + tools + demos + gpu checks
//   run        — run the terminal app
//   test       — unit tests
//   tools      — visual-diff / visual-test helpers (#13)
//   visual-test— render fixtures and compare against PPM goldens
//   demos      — native GUI window demos (macOS → .app bundles)
//   run-gui    — run the GUI demo
//   gpu-check  — headless GPU backend self-checks (GL #11 / D3D11 #12)
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

    // --- app: the terminal binary ------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zooee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zooee", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the terminal app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // --- test --------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- tools (#13) -------------------------------------------------------
    const tools_step = b.step("tools", "Build the visual-diff / visual-test helpers");

    const visual_diff = addExe(b, target, optimize, null, "visual-diff", "tools/visual_diff.zig");
    b.installArtifact(visual_diff); // CI's e2e capture check uses it
    tools_step.dependOn(&b.addInstallArtifact(visual_diff, .{}).step);

    const visual_test = addExe(b, target, optimize, mod, "visual-test", "tools/visual_test.zig");
    tools_step.dependOn(&b.addInstallArtifact(visual_test, .{}).step);
    const run_visual_test = b.addRunArtifact(visual_test);
    run_visual_test.addArg(b.pathFromRoot("testdata/visual"));
    if (b.args) |args| run_visual_test.addArgs(args); // forward --update
    b.step("visual-test", "Render scene fixtures and compare against PPM goldens").dependOn(&run_visual_test.step);

    // --- demos: native GUI window apps -------------------------------------
    const demos_step = b.step("demos", "Build the native GUI window demos (macOS → .app bundles)");
    switch (os) {
        .macos => {
            // Two .apps so each renderer can be launched and compared: the
            // GL one GPU-presents (#11), the raster one forces software.
            installMacApp(b, demos_step, guiDemo(b, mod, target, optimize, "zooee-gui-gl", false), "Zooee GL", "zooee-gui-gl");
            installMacApp(b, demos_step, guiDemo(b, mod, target, optimize, "zooee-gui-raster", true), "Zooee Raster", "zooee-gui-raster");
        },
        .windows => {
            const gui = guiDemo(b, mod, target, optimize, "zooee-gui-demo", false);
            gui.subsystem = .Windows; // no console window for a GUI app
            demos_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
            // Bare-window e2e visual subject for the self-hosted runner.
            const window_demo = addExe(b, target, optimize, mod, "zooee-window-demo", "examples/window_demo.zig");
            window_demo.subsystem = .Windows;
            demos_step.dependOn(&b.addInstallArtifact(window_demo, .{}).step);
        },
        .linux => {
            const gui = guiDemo(b, mod, target, optimize, "zooee-gui-demo", false);
            demos_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
        },
        else => {},
    }
    b.getInstallStep().dependOn(demos_step); // build demos on plain `zig build`

    // run-gui: the GL/GPU GUI demo (the comparison subject).
    if (os == .macos or os == .windows or os == .linux) {
        const run_gui = b.step("run-gui", "Run the native GUI demo (GPU path)");
        run_gui.dependOn(&b.addRunArtifact(guiDemo(b, mod, target, optimize, "zooee-gui-run", false)).step);
    }

    // --- gpu-check: headless GPU backend self-checks -----------------------
    const gpu_step = b.step("gpu-check", "Build the headless GPU backend self-checks");
    if (os == .linux or os == .macos) {
        const gl_demo = addExe(b, target, optimize, mod, "zooee-gl-demo", "examples/gl_demo.zig");
        b.installArtifact(gl_demo); // CI runs it under Xvfb (Linux) / direct (macOS)
        gpu_step.dependOn(&b.addInstallArtifact(gl_demo, .{}).step);
    }
    if (os == .windows) {
        const d3d11_demo = addExe(b, target, optimize, mod, "zooee-d3d11-demo", "examples/d3d11_demo.zig");
        b.installArtifact(d3d11_demo);
        gpu_step.dependOn(&b.addInstallArtifact(d3d11_demo, .{}).step);
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
