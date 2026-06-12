# Zooee

A cross-platform UI framework written in [Zig](https://ziglang.org/), with pluggable rendering backends: write your interface once and run it in the terminal or as a GPU-accelerated native window.

> **Status: early development.** Zooee is in the design/bootstrap phase — the API and backends described below are the project's direction, not yet a finished product. Expect breaking changes on every commit.

## Why Zooee?

Most UI frameworks lock you into one rendering target. Zooee separates *what* your UI is from *how* it gets drawn:

- **Terminal backend** — render your app as a TUI over ANSI escape sequences. Great for CLIs, servers, and SSH sessions.
- **DirectX backend** — GPU-accelerated rendering on Windows.
- **OpenGL backend** — GPU-accelerated rendering across Linux, macOS, and Windows.

The same widget tree, layout, and event handling drive all of them. Build a dashboard once; ship it as both a terminal tool and a desktop app.

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

```sh
git clone https://github.com/daniel-samson/zooee.git
cd zooee
zig build        # build the library and demo executable
zig build run    # run the demo
zig build test   # run the test suite
```

## Project layout

```
src/
  root.zig   # library entry point (the `zooee` module)
  main.zig   # demo executable
build.zig    # build graph
```

## Roadmap

- [ ] Core widget tree and layout engine
- [ ] Event/input abstraction (keyboard, mouse, resize)
- [ ] Terminal backend (ANSI / escape sequences)
- [ ] OpenGL backend
- [ ] DirectX backend
- [ ] Theming and styling
- [ ] Examples and documentation

## Contributing

Issues and pull requests are welcome. Since the project is young, opening an issue to discuss design direction before a large PR is appreciated.

## License

[MIT](LICENSE)
