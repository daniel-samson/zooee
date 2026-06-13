# Zooee

[![CI](https://github.com/daniel-samson/zooee/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/daniel-samson/zooee/actions/workflows/ci.yml)

A cross-platform UI framework written in [Zig](https://ziglang.org/), with pluggable rendering backends: write your interface once and run it in the terminal, as a GPU-accelerated native window, or in the browser via WebAssembly.

> **Status: early development.** Zooee is in the design/bootstrap phase — the API and backends described below are the project's direction, not yet a finished product. Expect breaking changes on every commit.

## Why Zooee?

Most UI frameworks lock you into one rendering target. Zooee separates *what* your UI is from *how* it gets drawn:

- **Terminal backend** — render your app as a TUI over ANSI escape sequences. Great for CLIs, servers, and SSH sessions.
- **DirectX backend** — GPU-accelerated rendering on Windows.
- **OpenGL backend** — GPU-accelerated rendering on Linux and macOS.
- **Web backend** — compile to WebAssembly and render as real DOM elements + CSS in the browser (targeting Baseline 2025), for native text, accessibility, and selection for free.

The same widget tree, layout, and event handling drive all of them. Build a dashboard once; ship it as a terminal tool, a native desktop app, and a web app — from one codebase.

### Tiny binaries

No bundled runtime. A zooee app is native code that dynamically links the OS's *own* UI libraries (AppKit / X11 / Direct3D) — so the whole thing ships in **kilobytes, not the hundreds of megabytes** a bundled-browser app drags around. Measured `ReleaseSmall` builds:

| Binary | Size |
|---|---:|
| Terminal app | **~180 KB** |
| Native GPU window app | **~240 KB** |

That's the entire framework + app. CI gates the shipping size at a 2 MB tripwire ([`ci/check-size.sh`](ci/check-size.sh)) — currently ~10× under it. (Debug builds are ~2 MB; that's just DWARF debug info, stripped in release.)

### Rendering: GPU-accelerated, with a software fallback

Native windows render on the GPU by default (DirectX on Windows, OpenGL on Linux/macOS). When a usable GPU isn't available — missing or old drivers, remote-desktop sessions, virtual machines without 3D acceleration, or GPU device loss — zooee automatically falls back to a built-in CPU software renderer that draws into a framebuffer and blits it to the window. **It always renders something.** The software renderer is also the reference used to verify GPU output in tests, so both paths produce the same result. Today the framework ships the software path while the GPU backends are under construction.

## Goals

- **Backend-agnostic core** — widgets, layout, and input handling are pure Zig with no rendering dependencies.
- **Zero hidden allocations** — allocators are explicit, in idiomatic Zig fashion.
- **Small and embeddable** — usable as a library (`zooee` module) inside your own application, not just as a standalone runtime.
- **First-class terminal support** — the TUI backend is a peer of the GPU backends, not an afterthought.

## Requirements

- Zig **0.16.0** or newer

## Getting started

### Use as a dependency

```sh
zig fetch --save https://github.com/daniel-samson/zooee/archive/refs/heads/main.tar.gz
```

Then in your `build.zig`:

```zig
const zooee = b.dependency("zooee", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zooee", zooee.module("zooee"));
```

### Build from source

`zig build` builds only the library; demos, checks, and tools live under
explicit steps (`zig build --help` lists them all):

```sh
git clone https://github.com/daniel-samson/zooee.git
cd zooee
zig build          # build the library (zig-out/lib/libzooee.a)
zig build test     # run the unit tests
zig build demos    # build the demo apps (terminal + native GUI;
                   #   macOS → "Zooee GL.app" / "Zooee Raster.app")
zig build run      # run the terminal demo
zig build run-gui  # run the native GUI demo (GPU-rendered)
zig build clean    # remove zig-out (the build output)
```

Other steps: `check` (headless GPU backend self-checks — `zooee-gl-check` /
`zooee-d3d11-check`, not demos), `visual-test` (raster golden comparison).

## Project layout

```
src/
  root.zig    # library entry point (the `zooee` module)
  main.zig    # terminal demo
  backends/   # terminal, raster, GL (#11), D3D11 (#12)
  platform/   # x11, win32, macos windowing
examples/     # native GUI demo (examples/gui_demo.zig) + GPU self-checks
build.zig     # build graph (see `zig build --help`)
```

## Roadmap

Tracked as [milestones](https://github.com/daniel-samson/zooee/milestones), built backends-first and test-driven:

1. **Test harness & backends** — e2e test infrastructure (terminal output snapshots, offscreen golden-image rendering for GPU), then the terminal, OpenGL (Linux/macOS), DirectX (Windows), and web (wasm + canvas) backends, native windowing with integrated/headless title bars, in-house text rendering, and a CI gate keeping release binaries under 2MB
2. **Core framework** — layout engine, declarative widget API, event loop
3. **Component library** — high-level widgets (buttons, inputs, tables, tab bars) built on the backend primitives

## Acknowledgements

Zooee is heavily inspired by [Textual](https://github.com/Textualize/textual), Will McGugan and Textualize's Python framework that proved a modern, component-based UI framework can treat the terminal as a first-class rendering target — and run the same app in the browser. Zooee borrows that spirit (and ambition) in Zig — and extends it with native GUI backends: the same app can also run as a GPU-accelerated desktop application with real windows, not just in the terminal and browser.

## Contributing

Issues and pull requests are welcome. Since the project is young, opening an issue to discuss design direction before a large PR is appreciated.

## License

[MIT](LICENSE)
