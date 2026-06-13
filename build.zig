const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    // The zooee module itself touches AppKit on macOS (platform/macos.zig),
    // so anything importing it — tests included — needs the framework.
    const mod = b.addModule("zooee", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    if (target.result.os.tag == .macos) {
        mod.linkFramework("AppKit", .{});
        // OpenGL.framework (deprecated but present): the macOS GPU backend
        // (#11) is GL via CGL/NSOpenGL. Provides the GL + CGL symbols.
        mod.linkFramework("OpenGL", .{});
        mod.link_libc = true; // dlsym for GL proc resolution
    }
    if (target.result.os.tag == .linux) {
        // Xlib is the Linux platform windowing API (like AppKit/user32),
        // dynamically linked — no bytes in our binary.
        mod.link_libc = true;
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("GL", .{}); // GLX/OpenGL — the platform GPU API
    }
    // Test font for the font pipeline (#10): OFL Poppins, tests/goldens only.
    mod.addAnonymousImport("poppins", .{
        .root_source_file = b.path("testdata/fonts/Poppins-Regular.ttf"),
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zooee",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zooee" is the name you will use in your source code to
                // import this module (e.g. `@import("zooee")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zooee", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- visual testing (#13) ---------------------------------------------

    // visual-diff: standalone image comparison (PPM/BMP, tolerance or
    // --expect-solid). Used by the e2e capture check on self-hosted CI.
    const visual_diff = b.addExecutable(.{
        .name = "visual-diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/visual_diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(visual_diff);

    // visual-test: render scene fixtures through the raster backend and
    // compare byte-exactly against checked-in goldens.
    const visual_test = b.addExecutable(.{
        .name = "visual-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/visual_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zooee", .module = mod }},
        }),
    });
    const run_visual_test = b.addRunArtifact(visual_test);
    run_visual_test.addArg(b.pathFromRoot("testdata/visual"));
    if (b.args) |args| run_visual_test.addArgs(args); // forward --update
    const visual_step = b.step("visual-test", "Render scene fixtures and compare against PPM goldens");
    visual_step.dependOn(&run_visual_test.step);

    // GUI demo: macOS → .app bundle by plain `zig build` (Daniel's
    // requirement, #9); Windows → GUI-subsystem exe; Linux → X11 exe.
    if (target.result.os.tag == .macos or target.result.os.tag == .windows or target.result.os.tag == .linux) {
        const gui_demo = b.addExecutable(.{
            .name = "zooee-gui-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/gui_demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zooee", .module = mod }},
            }),
        });

        if (target.result.os.tag == .windows) {
            gui_demo.subsystem = .Windows;
            b.installArtifact(gui_demo);
        }
        if (target.result.os.tag == .linux) {
            b.installArtifact(gui_demo);
        }

        const plist = b.addWriteFiles().add("Info.plist",
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0"><dict>
            \\  <key>CFBundleIdentifier</key><string>dev.zooee.demo</string>
            \\  <key>CFBundleName</key><string>Zooee Demo</string>
            \\  <key>CFBundleExecutable</key><string>zooee-gui-demo</string>
            \\  <key>CFBundlePackageType</key><string>APPL</string>
            \\  <key>NSHighResolutionCapable</key><true/>
            \\</dict></plist>
            \\
        );
        if (target.result.os.tag == .macos) {
            const app_bin = b.addInstallArtifact(gui_demo, .{
                .dest_dir = .{ .override = .{ .custom = "Zooee Demo.app/Contents/MacOS" } },
            });
            const app_plist = b.addInstallFile(plist, "Zooee Demo.app/Contents/Info.plist");
            b.getInstallStep().dependOn(&app_bin.step);
            b.getInstallStep().dependOn(&app_plist.step);
        }

        const run_gui = b.step("run-gui", "Run the native GUI demo");
        const run_gui_cmd = b.addRunArtifact(gui_demo);
        run_gui.dependOn(&run_gui_cmd.step);
    }

    // GL backend demo (#11): self-checking GL-vs-raster golden comparison +
    // renderer round-trips. Linux uses a hidden GLX window (slice-1 present
    // check too); macOS uses an offscreen CGL context. Runs headless.
    if (target.result.os.tag == .linux or target.result.os.tag == .macos) {
        const gl_demo = b.addExecutable(.{
            .name = "zooee-gl-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/gl_demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zooee", .module = mod }},
            }),
        });
        b.installArtifact(gl_demo);
    }

    // Native window demo, Windows targets only — the e2e visual subject.
    if (target.result.os.tag == .windows) {
        const window_demo = b.addExecutable(.{
            .name = "zooee-window-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/window_demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zooee", .module = mod }},
            }),
        });
        // GUI subsystem: without this Windows allocates a console window
        // before showing the app window — wrong for a GUI app.
        window_demo.subsystem = .Windows;
        b.installArtifact(window_demo);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
