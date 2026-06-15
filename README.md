# Gorgeously Native, Elegantly Written

[![CI](https://github.com/daniel-samson/zooee/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/daniel-samson/zooee/actions/workflows/ci.yml)

Zooee is a cross-platform UI framework written in [Zig](https://ziglang.org/), with pluggable rendering backends: write your interface once and run it in the terminal, as a GPU-accelerated native window, or in the browser via WebAssembly.

> **Status: pre-1.0, but the engine works.** All four rendering backends, the layout engine, real text layout, the animation system, theming, and the full input/event stack are implemented and CI-verified (see [Features](#features)). What's still in flight is the high-level component library, the web/wasm backend, and some per-platform OS plumbing. The API is not yet stable — expect breaking changes.

## Why Zooee?

Most UI frameworks lock you into one rendering target. Zooee separates *what* your UI is from *how* it gets drawn:

- **Terminal backend** — render your app as a TUI over ANSI escape sequences. Great for CLIs, servers, and SSH sessions.
- **GPU backends, native to each OS** — Metal on macOS, Direct3D 11 on Windows, OpenGL on Linux. One renderer per platform, using the system's own modern graphics API.
- **Web backend** — compile to WebAssembly and render as real DOM elements + CSS in the browser (targeting Baseline 2025), for native text, accessibility, and selection for free.

The same widget tree, layout, and event handling drive all of them. Build a dashboard once; ship it as a terminal tool, a native desktop app, and a web app — from one codebase.

### Tiny binaries

No bundled runtime. A zooee app is native code that dynamically links the OS's *own* UI + graphics libraries (AppKit + Metal / X11 + OpenGL / Direct3D 11) — so the whole thing ships in **kilobytes, not the hundreds of megabytes** a bundled-browser app drags around. Measured `ReleaseSmall` builds:

| Binary | Size |
|---|---:|
| Terminal app | **~196 KB** |
| Native GPU window app | **~269 KB** |

That's the entire framework + app — the full GPU renderer (gradients, shadows, vector paths, offscreen layers, images, real text layout), the layout engine, the animation system, theming, and the complete input/event stack. CI gates the shipping size at a 2 MB tripwire ([`ci/check-size.sh`](ci/check-size.sh)) — still **~7–8× under it** even with everything turned on. (Debug builds are ~2 MB; that's just DWARF debug info, stripped in release.)

### Rendering: GPU-accelerated, with a software fallback

Native windows render on the GPU by default — **Metal** on macOS, **Direct3D 11** on Windows, **OpenGL** on Linux. When a usable GPU isn't available — missing or old drivers, remote-desktop sessions, virtual machines without 3D acceleration, or GPU device loss — zooee automatically falls back to a built-in CPU software renderer that draws into a framebuffer and blits it to the window. **It always renders something.** The software renderer is also the reference used to verify GPU output in tests: each GPU backend is checked pixel-exact against it, so all paths produce the same result.

## Features

Everything below works **today**, on **all four backends** (raster + Metal + OpenGL + Direct3D 11) where rendering is involved, and is **verified pixel-exact** against the software reference in CI — or unit-/harness-tested where it's pure logic.

### Drawing primitives
- **Rects & borders** — solid fills, per-side borders (CSS-style), independent per-corner radii.
- **Rounded-rect clipping** — clip a whole subtree to rounded corners.
- **Gradients** — linear, multi-stop, and radial, with a shared analytic formula so CPU and GPU match.
- **Shadows** — drop / box / **inset**, with blur, spread, and rounded corners (Evan-Wallace rounded-box-shadow math).
- **Vector paths** — arbitrary filled polygons (even-odd) and stroked polylines with round caps/joins.
- **Offscreen layers** — group opacity / render-to-texture compositing for a subtree.
- **Images** — fit modes (stretch / contain / cover), nearest **and bilinear** sampling, and **9-slice** scaling.
- **Text** — a dynamic Unicode glyph atlas (glyphs rasterized on demand), drawn from the OS font.

### Layout & text
- **Flexbox-style layout** — row/column containers, `grow`, `gap`, per-side margin/padding/border, snap-to-grid so independently-rounded children tile exactly.
- **Text layout** — word **wrapping** to a width, horizontal **alignment**, line-height, multi-line paragraphs, and caret ↔ point **hit-testing** (for selection / editable text).
- **Scrollable viewports** — clip + content offset as a backend primitive, driven by wheel/trackpad input.

### Motion & theming
- **Animation system** — a frame clock with real delta-time, a scheduler (one-shot/repeating timers, tweens, easing curves), and an **idle guarantee** (zero wakeups/redraws when nothing animates). Frames are **paced to the display's actual refresh rate** — no hard-coded 60 fps cap.
- **Theming** — semantic color tokens (background, surface, text, accent, border…) with built-in **light & dark** themes; the window backdrop and content share one source of truth, switchable at runtime.

### Input, events & OS integration
- **Pointer** — down/move/up with keyboard modifiers, click-count (double/triple), enter/leave, and capture.
- **Keyboard & text** — key down/up, text input, and **IME composition** (CJK pre-edit + commit).
- **Scroll / wheel** — line vs pixel deltas and trackpad gesture phases (incl. momentum).
- **Drag-and-drop**, **clipboard**, **window operations** (resize/minimise/maximise/close + state events), and **display robustness** (resize-storm coalescing, DPI-change policy).

### Testing
- A **synthetic-event harness** drives a real app (view → layout → dispatch → render) headlessly with scripted events and asserts Model state or pixels — so interaction is self-verified, no flaky on-screen automation.

> Some OS-level plumbing (e.g. wheel/clipboard/drag-and-drop on Windows & Linux) has its logic, fakes, and macOS path in place with the per-platform hooks flagged for on-device QA — see the closed issues for the precise per-feature status.

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
                   #   macOS → "Zooee.app"; ZOOEE_SOFTWARE=1 forces raster)
zig build run      # run the terminal demo
zig build run-gui  # run the native GUI demo (GPU-rendered)
zig build clean    # remove zig-out (the build output)
```

Builds are **Debug** by default (~2 MB, mostly debug info). For the small
shipping binaries (~180–240 KB), build in release:

```sh
zig build demos -Doptimize=ReleaseSmall   # smallest; or ReleaseFast for speed
```

Other steps: `check` (headless GPU backend self-checks, one per platform —
`zooee-metal-check` on macOS, `zooee-gl-check` on Linux, `zooee-d3d11-check`
on Windows; not demos), `visual-test` (raster golden comparison).

## Project layout

```
src/
  root.zig    # library entry point (the `zooee` module)
  main.zig    # terminal demo
  backends/   # terminal, raster, Metal (#101, macOS), GL (#11, Linux), D3D11 (#12, Windows)
  platform/   # x11, win32, macos windowing
examples/     # native GUI demo (examples/gui_demo.zig) + GPU self-checks
build.zig     # build graph (see `zig build --help`)
```

## Roadmap

Tracked as [milestones](https://github.com/daniel-samson/zooee/milestones), built backends-first and test-driven:

1. ✅ **Test harness & backends** — golden-image + synthetic-event test infrastructure, and the terminal, Metal (macOS), OpenGL (Linux), and Direct3D 11 (Windows) backends with native windowing, in-house text rendering, and the under-2 MB CI gate. *(Web/wasm backend still to come.)*
2. ✅ **Core framework** — layout engine, the full drawing-primitive set, text layout, the event loop + input stack, animation, and theming. *(See [Features](#features).)*
3. 🔜 **Component library** — high-level widgets (buttons, inputs, tables, tab bars) built on the backend primitives.

Still ahead: the web (wasm + DOM/CSS) backend, text shaping (kerning/ligatures/BiDi), font fallback + bold/italic faces, cursor shapes, a declarative keyframes/transitions API, and accessibility.

## Acknowledgements

Zooee is heavily inspired by [Textual](https://github.com/Textualize/textual), Will McGugan and Textualize's Python framework that proved a modern, component-based UI framework can treat the terminal as a first-class rendering target — and run the same app in the browser. Zooee borrows that spirit (and ambition) in Zig — and extends it with native GUI backends: the same app can also run as a GPU-accelerated desktop application with real windows, not just in the terminal and browser.

## Contributing

Issues and pull requests are welcome. Since the project is young, opening an issue to discuss design direction before a large PR is appreciated.

## License

[MIT](LICENSE)
