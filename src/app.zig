//! App architecture (#4): the framework's model–view–update loop.
//!
//! Elm-shaped, which fits Zig (no closures needed):
//! - The app is a Model struct with three callbacks:
//!     view(*Model, gpa) !*const Element    — build the UI tree (arena-owned)
//!     update(*Model, Msg) Command          — react to messages
//!     onEvent(*Model, Event) Command       — raw events not turned into messages
//! - Elements carry optional interaction messages (`on_click`, hover via
//!   `hover_msg`); the framework hit-tests pointer events against the
//!   layout result and dispatches the element's message to update().
//! - `Command` tells the loop what to do: redraw, quit, or nothing.
//!
//! v1 runs on the terminal session; the same loop shape extends to GPU
//! windows (#9/#12) since input arrives as the same core events.

const std = @import("std");
const builtin = @import("builtin");
const layout_mod = @import("layout.zig");
const event_mod = @import("event.zig");
const backend_mod = @import("backend.zig");
const terminal_mod = @import("backends/terminal.zig");
const raster_mod = @import("backends/raster.zig");
const system_font = @import("font/system.zig");
const geometry = @import("geometry.zig");
const display = @import("display.zig");
const theme_mod = @import("theme.zig");
const style_mod = @import("style.zig");
const cursor_mod = @import("cursor.zig");
const ui_mod = @import("ui.zig");
const dialog = @import("dialog.zig");

/// Build the frame's Element tree from the Model (#4): prefer the widget-layer
/// `viewUi(ui) Widget` hook (lowered to Elements via `Ui`), else the raw
/// `view(arena, scale) *Element` contract. Lets models adopt the widget API
/// without changing the loops.
pub fn buildTree(comptime Model: type, model: *Model, arena: std.mem.Allocator, scale: f32) !*const layout_mod.Element {
    if (@hasDecl(Model, "viewUi")) {
        var u = ui_mod.Ui.init(arena);
        u.scale = scale;
        return u.lower(try model.viewUi(&u));
    }
    return model.view(arena, scale);
}

const window_mod = @import("window.zig");
pub const Theme = theme_mod.Theme;

/// The Model's current backend clear color, if it exposes an optional
/// `background() Color` hook (theming) — lets a runtime theme change track the
/// window/backdrop color. Null when the model has no such hook.
fn modelBackground(comptime Model: type, model: *Model) ?style_mod.Color {
    if (@hasDecl(Model, "background")) return model.background();
    return null;
}

pub const Command = enum { none, redraw, quit };

/// Per-frame timing for a present loop (#170): measures real inter-frame delta
/// and paces the sleep to the display's refresh interval instead of a hard-
/// coded 16ms — so a 120/144Hz monitor renders proportionally more frames, and
/// heavy frames don't add a fixed 16ms on top of their own cost.
const FrameLoop = struct {
    pacer: display.FramePacer,
    /// Monotonic ns at the start of the previous frame.
    last: i96 = 0,
    started: bool = false,
    /// Frames since the last refresh-rate re-sample (#27 hot-plug).
    tune_ctr: u32 = 0,

    fn init(hz: f32) FrameLoop {
        return .{ .pacer = display.FramePacer.forHz(hz) };
    }

    /// True roughly twice a second — when the loop should re-query the display
    /// refresh rate, so dragging the window to a different-Hz monitor (#27
    /// hot-plug) re-paces. Throttled so we don't query the OS every frame.
    fn shouldRetune(self: *FrameLoop) bool {
        self.tune_ctr += 1;
        if (self.tune_ctr < 120) return false;
        self.tune_ctr = 0;
        return true;
    }

    /// Adopt a new refresh rate (no-op if unchanged).
    fn retune(self: *FrameLoop, hz: f32) void {
        const p = display.FramePacer.forHz(hz);
        if (p.interval_ns != self.pacer.interval_ns) self.pacer = p;
    }

    fn nowNs(io: std.Io) i96 {
        return std.Io.Timestamp.now(io, .awake).nanoseconds;
    }

    /// Nanoseconds since the previous `delta` call (0 on the first frame), and
    /// records this frame's start. Feed this to `animate`.
    fn delta(self: *FrameLoop, io: std.Io) u64 {
        const now = nowNs(io);
        const dt: u64 = if (!self.started) 0 else @intCast(@max(0, now - self.last));
        self.last = now;
        self.started = true;
        return dt;
    }

    /// Sleep what's left of the refresh interval after this frame's work.
    fn pace(self: *FrameLoop, io: std.Io) !void {
        const work: u64 = @intCast(@max(0, nowNs(io) - self.last));
        const nap = self.pacer.sleepAfter(work);
        if (nap > 0) try io.sleep(.fromNanoseconds(@intCast(nap)), .awake);
    }
};

/// Call the Model's optional `animate(dt_ns) Command` hook (#170) so timers and
/// tweens advance with real elapsed time. Models without one are unaffected.
fn animate(comptime Model: type, model: *Model, dt: u64) Command {
    if (@hasDecl(Model, "animate")) return model.animate(dt);
    return .none;
}

/// Native window platform for the GUI runner. X11 is the #9 follow-up;
/// unsupported OSes get an empty struct (runWindow @compileErrors before
/// touching it). Comptime if only analyzes the taken arm.
const has_window_platform = builtin.os.tag == .windows or builtin.os.tag == .macos or builtin.os.tag == .linux;
const WindowPlatform = if (builtin.os.tag == .windows)
    @import("platform/win32.zig")
else if (builtin.os.tag == .macos)
    @import("platform/macos.zig")
else if (builtin.os.tag == .linux)
    @import("platform/x11.zig")
else
    struct {};

const Session = if (builtin.os.tag == .windows)
    @import("platform/win32_console.zig").Console
else
    @import("platform/posix_tty.zig").Tty;

const session_mod = if (builtin.os.tag == .windows)
    @import("platform/win32_console.zig")
else
    @import("platform/posix_tty.zig");

/// GL backend (#11) — the GPU-present path for runWindow on Linux (GLX).
/// macOS uses Metal (#101) and Windows uses D3D11 (#12), so GL is Linux-only;
/// empty struct elsewhere so it only compiles where valid.
const gl_backend = if (builtin.os.tag == .linux)
    @import("backends/gl.zig")
else
    struct {};

/// D3D11 backend (#12) — the GPU-present path for runWindow on Windows.
const d3d_backend = if (builtin.os.tag == .windows)
    @import("backends/d3d11.zig")
else
    struct {};

/// Metal backend (#101) — the GPU-present path for runWindow on macOS
/// (display-synced CAMetalLayer → lag-free live resize). macOS is Metal-only:
/// runWindow picks Metal → raster (no GL on macOS).
const metal_backend = if (builtin.os.tag == .macos)
    @import("backends/metal.zig")
else
    struct {};

/// OSes whose native window carries a GL context (Linux/GLX only; macOS=Metal,
/// Windows=D3D11).
const has_gl_window = builtin.os.tag == .linux;
/// OSes with a native GPU window backend: GL (Linux), Metal (macOS, #101),
/// D3D11 (Windows). Note this is NOT derived from has_gl_window — macOS has a
/// GPU window via Metal but no GL window.
const has_gpu_window = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows;

/// Run a Model as a terminal app. Msg is the app's message type
/// (any integer-backed enum or integer type).
pub fn run(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    init: std.process.Init,
) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    terminal_mod.setupConsole();
    var term = terminal_mod.TerminalBackend.init(gpa);
    // Theme backdrop fills the whole TUI, not just where rects draw (theming).
    if (modelBackground(Model, model)) |c| term.clear_color = c;
    defer term.deinit();
    const b = term.interface();

    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var session = Session.init() catch {
        // Not a TTY: render one frame plainly and exit (CI-safe).
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        const root = try buildTree(Model, model, frame_arena.allocator(), 1);
        var result = try layout_mod.layout(frame_arena.allocator(), b, root, .{ .width = 60, .height = 14 });
        try b.beginFrame(.{ .width = 60, .height = 14 });
        layout_mod.render(b, result);
        try b.endFrame();
        result.deinit(frame_arena.allocator());
        const text = try term.renderToText(gpa);
        defer gpa.free(text);
        try out.writeAll(text);
        try out.flush();
        return;
    };
    try session.enableRaw();
    defer session.deinit();
    try out.writeAll(session_mod.enter_tui_seq);
    try out.flush();

    var dirty = true;
    var placements: []layout_mod.Placement = &.{};
    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    // Terminals have no vsync; pace at 60Hz so animations advance at a steady
    // cadence without busy-spinning (#170).
    var fl = FrameLoop.init(60);
    loop: while (true) {
        const dt = fl.delta(io);
        if (dirty) {
            if (modelBackground(Model, model)) |c| term.clear_color = c; // runtime theme
            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const root = try buildTree(Model, model, arena, 1);
            const viewport = session.size();
            const result = try layout_mod.layout(arena, b, root, viewport);
            placements = result.placements;
            try b.beginFrame(viewport);
            layout_mod.render(b, result);
            try b.endFrame();
            try term.present(out);
            try out.flush();
            dirty = false;
        }

        const events = try session.pumpEvents(frame_arena.allocator());
        for (events) |ev| {
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
        }
        if (animate(Model, model, dt) == .redraw) dirty = true;

        try fl.pace(io);
    }
}

/// Run a Model in a native GUI window: layout → raster backend → blit,
/// with pointer/keyboard events dispatched exactly as the terminal loop
/// (#4/#9). Loads a system font (#10) so text renders. Coordinates are
/// content pixels on both axes, matching the rendered framebuffer.
pub fn runWindow(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    init: std.process.Init,
    opts: WindowOptions,
) !void {
    if (!has_window_platform) @compileError("runWindow: no native window platform for this OS (X11 is #9 follow-up)");
    const platform = WindowPlatform;
    const gpa = init.arena.allocator();
    const io = init.io;

    // GPU-present by default on platforms with a GPU backend (#11/#12);
    // ZOOEE_SOFTWARE forces the CPU raster path (deterministic CI, debugging).
    const want_gpu = has_gpu_window and !opts.force_software and !init.environ_map.contains("ZOOEE_SOFTWARE");

    // Only Linux carries a GL context on the window (macOS=Metal, Windows=D3D).
    const want_gl_ctx = want_gpu and builtin.os.tag == .linux;
    const window = try platform.Window.create(gpa, .{ .title = opts.title, .width = opts.width, .height = opts.height, .gl = want_gl_ctx, .titlebar = opts.titlebar });
    defer window.destroy();

    // macOS: Metal is the primary GPU path (display-synced → lag-free resize).
    // If Metal is unavailable, fall through to the CPU raster path below.
    if (comptime builtin.os.tag == .macos) {
        if (want_gpu) {
            if (runWindowMetal(Model, Msg, model, window, init, opts.theme)) {
                return;
            } else |_| {}
        }
    }

    // GL window + current context succeeded → drive the GPU-present loop.
    // Otherwise fall through to the CPU raster + OS blit path below.
    if (comptime has_gl_window) {
        if (window.gl_ctx != null) return runWindowGl(Model, Msg, model, window, init, opts.theme);
    }

    // Windows: try a D3D11 swapchain on the HWND (#12). Needs the interactive
    // desktop session — falls back to raster + GDI blit when create() fails.
    if (comptime builtin.os.tag == .windows) {
        if (want_gpu) {
            const px0 = platform.contentPixelSize(window);
            if (d3d_backend.D3dSwapchain.create(window.hwnd, @intCast(px0.width), @intCast(px0.height))) |sc| {
                winlog(init, "path=d3d swapchain=ok size={d}x{d}", .{ px0.width, px0.height });
                var swapchain = sc;
                return runWindowD3d(Model, Msg, model, window, &swapchain, init, opts.theme);
            } else |err| {
                winlog(init, "path=raster swapchain_err={t} size={d}x{d}", .{ err, px0.width, px0.height });
            }
        } else {
            winlog(init, "path=raster want_gpu=false", .{});
        }
    }

    var raster = raster_mod.RasterBackend.init(gpa);
    raster.clear_color = opts.theme.background; // theme backdrop (theming)
    defer raster.deinit();
    _ = system_font.loadInto(gpa, io, &raster); // placeholder blocks if none found
    const b = raster.interface();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    var placements: []layout_mod.Placement = &.{};
    var dirty = true;

    // One-frame render+blit, callable during a modal resize drag (macOS) so
    // the CPU framebuffer is re-rendered at the new size instead of the OS
    // stretching the stale blit. Same shape as the GL/Metal loops.
    const Frame = struct {
        model: *Model,
        win: @TypeOf(window),
        backend: @TypeOf(b),
        raster: *raster_mod.RasterBackend,
        arena: *std.heap.ArenaAllocator,
        placements: *[]layout_mod.Placement,

        fn draw(self: *@This()) void {
            // Runtime theme changes track the clear color (theming toggle).
            if (@hasDecl(Model, "background")) self.raster.clear_color = self.model.background();
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const px = platform.contentPixelSize(self.win);
            const scale: f32 = @floatCast(px.scale);
            self.raster.char_width = 8 * scale;
            self.raster.line_height = 16 * scale;
            const root = buildTree(Model, self.model, a, scale) catch return;
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = layout_mod.layout(a, self.backend, root, viewport) catch return;
            self.placements.* = result.placements;
            self.backend.beginFrame(viewport) catch return;
            layout_mod.render(self.backend, result);
            self.backend.endFrame() catch return;
            platform.blit(self.win, self.raster.pixels, self.raster.width, self.raster.height);
        }
    };
    var frame: Frame = .{ .model = model, .win = window, .backend = b, .raster = &raster, .arena = &frame_arena, .placements = &placements };
    window.setRedraw(&frame, struct {
        fn call(p: ?*anyopaque) void {
            const f: *Frame = @ptrCast(@alignCast(p));
            f.draw();
        }
    }.call);

    var fl = FrameLoop.init(platform.refreshHz(window));
    var last_cursor: cursor_mod.Cursor = .default; // #123: only re-set on change
    setupMenuBar(Model, window, model); // #129: install the native menu bar
    loop: while (true) {
        const dt = fl.delta(io);
        for (window.pumpEvents()) |ev| {
            applyCursor(Model, window, model, placements, ev, &last_cursor);
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
            // Native right-click context menu (#129): pops at the click and
            // routes the choice through the model's onMenuCommand.
            if (handleContextMenu(Model, window, model, ev) == .redraw) dirty = true;
        }
        // Native menu-bar selections + file-open requests (#129).
        if (frameOsHooks(Model, window, model, gpa, io) == .redraw) dirty = true;
        if (animate(Model, model, dt) == .redraw) dirty = true;

        if (dirty) {
            frame.draw();
            dirty = false;
        }

        // Re-pace if the window moved to a different-refresh monitor (#27).
        if (fl.shouldRetune()) fl.retune(platform.refreshHz(window));
        try fl.pace(io);
    }
}

/// GPU-present loop (#11): the platform created a GL window and made its
/// context current; GlBackend renders straight to the window's default
/// framebuffer and the platform swaps buffers. Same view→layout→render and
/// event dispatch as the raster loop — only the backend and present differ.
/// Linux/GLX and macOS/NSOpenGL; referenced only behind a comptime guard.
fn runWindowGl(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    window: anytype,
    init: std.process.Init,
    theme: Theme,
) !void {
    const platform = WindowPlatform;
    const gpa = init.arena.allocator();
    const io = init.io;

    // Headless capture hook: ZOOEE_CAPTURE=<path> renders one frame, reads
    // the window's GL back buffer back, writes it as a PPM, and exits — so
    // the real on-window GPU render can be snapshotted without a screenshot
    // (screen-recording perms) on either platform.
    const capture_path = init.environ_map.get("ZOOEE_CAPTURE");

    var glb = try gl_backend.GlBackend.initOnCurrent(gpa);
    glb.clear_color = theme.clearRgba(); // theme backdrop (theming)
    defer glb.deinit();
    if (system_font.loadFontSet(gpa, io)) |set| glb.setFontSet(set);
    const b = glb.interface();

    // X11 window background = theme backdrop (#182): a resize-grow's exposed
    // strip shows the theme color instead of black until the frame repaints.
    window.setBackground(theme.background.r, theme.background.g, theme.background.b);

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    var placements: []layout_mod.Placement = &.{};
    var dirty = true;

    // One-frame render+present, factored out so the platform can call it
    // *during* a modal resize drag (macOS) — when our own loop is parked —
    // and redraw live instead of stretching the stale frame. Best-effort:
    // a redraw mid-drag swallows transient errors rather than crashing.
    const Frame = struct {
        model: *Model,
        win: @TypeOf(window),
        backend: @TypeOf(b),
        arena: *std.heap.ArenaAllocator,
        placements: *[]layout_mod.Placement,

        fn draw(self: *@This()) void {
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            self.win.glUpdate(); // resync the GL context with the window size (macOS resize)
            const px = platform.contentPixelSize(self.win);
            const scale: f32 = @floatCast(px.scale);
            const root = buildTree(Model, self.model, a, scale) catch return;
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = layout_mod.layout(a, self.backend, root, viewport) catch return;
            self.placements.* = result.placements;
            self.backend.beginFrame(viewport) catch return;
            layout_mod.render(self.backend, result);
            self.backend.endFrame() catch return;
            self.win.glSwap();
        }
    };
    var frame: Frame = .{ .model = model, .win = window, .backend = b, .arena = &frame_arena, .placements = &placements };
    window.setRedraw(&frame, struct {
        fn call(ctx: ?*anyopaque) void {
            const f: *Frame = @ptrCast(@alignCast(ctx));
            f.draw();
        }
    }.call);

    var fl = FrameLoop.init(platform.refreshHz(window));
    var last_cursor: cursor_mod.Cursor = .default; // #123: only re-set on change
    setupMenuBar(Model, window, model); // #129: install the native menu bar
    loop: while (true) {
        const dt = fl.delta(io);
        for (window.pumpEvents()) |ev| {
            applyCursor(Model, window, model, placements, ev, &last_cursor);
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
            // Native right-click context menu (#129): pops at the click and
            // routes the choice through the model's onMenuCommand.
            if (handleContextMenu(Model, window, model, ev) == .redraw) dirty = true;
        }
        // Native menu-bar selections + file-open requests (#129).
        if (frameOsHooks(Model, window, model, gpa, io) == .redraw) dirty = true;
        if (animate(Model, model, dt) == .redraw) dirty = true;
        if (modelBackground(Model, model)) |c| glb.clear_color = c.rgbaF(); // theming toggle

        if (dirty) {
            // Headless capture hook: render once, read the GL back buffer,
            // write a PPM, and exit (no present needed for the snapshot).
            if (capture_path) |path| {
                _ = frame_arena.reset(.retain_capacity);
                const arena = frame_arena.allocator();
                window.glUpdate();
                const px = platform.contentPixelSize(window);
                const scale: f32 = @floatCast(px.scale);
                const root = try buildTree(Model, model, arena, scale);
                const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
                const result = try layout_mod.layout(arena, b, root, viewport);
                placements = result.placements;
                try b.beginFrame(viewport);
                layout_mod.render(b, result);
                try b.endFrame();
                const pixels = try glb.readPixels();
                defer gpa.free(pixels);
                var ppm: std.ArrayList(u8) = .empty;
                var pw: std.Io.Writer.Allocating = .fromArrayList(gpa, &ppm);
                try gl_backend.writePpmRgba(&pw.writer, pixels, glb.width, glb.height);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pw.toArrayList().items });
                return;
            }
            frame.draw();
            dirty = false;
        }

        // Re-pace if the window moved to a different-refresh monitor (#27).
        if (fl.shouldRetune()) fl.retune(platform.refreshHz(window));
        try fl.pace(io);
    }
}

/// GPU-present loop (#101), macOS/Metal: a CAMetalLayer on the window's view.
/// MetalBackend renders the UI into an offscreen RT (shared device); each
/// frame the RT is drawn into the layer's next drawable and presented. The
/// present is display-synced, so live resize (driven through the same
/// windowDidResize: callback as GL, #100) is lag-free. Errors on setup so the
/// caller can fall back to raster. Referenced only behind a macOS guard.
fn runWindowMetal(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    window: anytype,
    init: std.process.Init,
    theme: Theme,
) !void {
    const platform = WindowPlatform;
    const gpa = init.arena.allocator();
    const io = init.io;
    const capture_path = init.environ_map.get("ZOOEE_CAPTURE");

    var ctx = try metal_backend.MetalContext.create();
    defer ctx.destroy();
    const px0 = platform.contentPixelSize(window);
    var layer = try metal_backend.MetalLayer.createOnView(ctx.device, window.contentView(), @intCast(px0.width), @intCast(px0.height));

    var mb = try metal_backend.MetalBackend.initOn(gpa, ctx.device, ctx.queue);
    mb.clear_color = theme.clearRgba(); // theme backdrop (theming)
    defer mb.deinit();
    if (system_font.loadFontSet(gpa, io)) |set| mb.setFontSet(set);
    const b = mb.interface();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    var placements: []layout_mod.Placement = &.{};
    var dirty = true;

    // One-frame render+present, callable during the modal resize drag (#100).
    const Frame = struct {
        model: *Model,
        win: @TypeOf(window),
        backend: @TypeOf(b),
        mb: *metal_backend.MetalBackend,
        layer: *metal_backend.MetalLayer,
        arena: *std.heap.ArenaAllocator,
        placements: *[]layout_mod.Placement,
        /// Present this frame synchronously (low-latency) instead of via the
        /// display link. Set during interactive pointer drags so dragged content
        /// (e.g. a split divider) stays under the cursor, same as a live resize.
        sync_present: bool = false,

        fn draw(self: *@This()) void {
            // Drain this frame's autoreleased Metal objects (drawable, command
            // buffer, descriptors) so they don't pile up across frames — covers
            // both the loop and the modal-resize redraw callback.
            const pool = metal_backend.pushPool();
            defer metal_backend.drainPool(pool);
            // Runtime theme changes track the clear color (theming toggle).
            if (modelBackground(Model, self.model)) |c| self.mb.clear_color = c.rgbaF();
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const px = platform.contentPixelSize(self.win);
            self.layer.resize(@intCast(px.width), @intCast(px.height));
            const scale: f32 = @floatCast(px.scale);
            const root = buildTree(Model, self.model, a, scale) catch return;
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = layout_mod.layout(a, self.backend, root, viewport) catch return;
            self.placements.* = result.placements;
            self.backend.beginFrame(viewport) catch return;
            layout_mod.render(self.backend, result);
            self.backend.endFrame() catch return;
            // Transaction-synced present only during a live-resize drag; async
            // (display-link-paced) otherwise, so steady animation stays smooth.
            self.mb.presentTo(self.layer, self.win.inLiveResize() or self.sync_present);
        }
    };
    var frame: Frame = .{ .model = model, .win = window, .backend = b, .mb = &mb, .layer = &layer, .arena = &frame_arena, .placements = &placements };
    window.setRedraw(&frame, struct {
        fn call(p: ?*anyopaque) void {
            const f: *Frame = @ptrCast(@alignCast(p));
            f.draw();
        }
    }.call);

    var fl = FrameLoop.init(platform.refreshHz(window));
    var last_cursor: cursor_mod.Cursor = .default; // #123: only re-set on change
    setupMenuBar(Model, window, model); // #129: install the native menu bar
    loop: while (true) {
        const dt = fl.delta(io);
        var pointer_drag = false; // a pointer event drove this frame → present synced
        for (window.pumpEvents()) |ev| {
            applyCursor(Model, window, model, placements, ev, &last_cursor);
            const cmd = dispatch(Model, Msg, model, ev, placements);
            switch (cmd) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
            if (cmd == .redraw and isPointerEvent(ev)) pointer_drag = true;
            // Native right-click context menu (#129): pops at the click and
            // routes the choice through the model's onMenuCommand.
            if (handleContextMenu(Model, window, model, ev) == .redraw) dirty = true;
        }
        // Native menu-bar selections + file-open requests (#129).
        if (frameOsHooks(Model, window, model, gpa, io) == .redraw) dirty = true;
        if (animate(Model, model, dt) == .redraw) dirty = true;
        frame.sync_present = pointer_drag; // low-latency present while dragging

        if (dirty) {
            // Headless capture hook: render one frame to the RT, read it, exit.
            if (capture_path) |path| {
                _ = frame_arena.reset(.retain_capacity);
                const arena = frame_arena.allocator();
                const px = platform.contentPixelSize(window);
                const scale: f32 = @floatCast(px.scale);
                const root = try buildTree(Model, model, arena, scale);
                const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
                const result = try layout_mod.layout(arena, b, root, viewport);
                placements = result.placements;
                try b.beginFrame(viewport);
                layout_mod.render(b, result);
                try b.endFrame();
                const pixels = try mb.readPixels();
                defer gpa.free(pixels);
                try writePpm(gpa, io, path, pixels, mb.width, mb.height);
                return;
            }
            frame.draw();
            dirty = false;
        }

        // Re-pace if the window moved to a different-refresh monitor (#27).
        if (fl.shouldRetune()) fl.retune(platform.refreshHz(window));
        try fl.pace(io);
    }
}

/// GPU-present loop (#12), Windows/D3D11: a DXGI swapchain on the HWND.
/// D3dBackend renders to an offscreen RT on the swapchain's device; each
/// frame the result is copied to the back buffer and presented. Same loop
/// shape as runWindowGl; referenced only behind a comptime windows guard.
fn runWindowD3d(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    window: anytype,
    swapchain: anytype,
    init: std.process.Init,
    theme: Theme,
) !void {
    const platform = WindowPlatform;
    const gpa = init.arena.allocator();
    const io = init.io;
    defer swapchain.destroy();

    const capture_path = init.environ_map.get("ZOOEE_CAPTURE");

    var db = try d3d_backend.D3dBackend.initOnDevice(gpa, swapchain.device, swapchain.context);
    db.clear_color = theme.clearRgba(); // theme backdrop (theming)
    defer db.deinit();
    if (system_font.loadFontSet(gpa, io)) |set| db.setFontSet(set);
    const b = db.interface();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();
    var placements: []layout_mod.Placement = &.{};
    var dirty = true;

    // One-frame resize+render+present, callable from win32 WM_SIZE during the
    // modal WM_ENTERSIZEMOVE loop (which parks our pump loop) so the content
    // redraws live instead of freezing until the drag ends. Resizing the
    // swapchain each step also keeps CopyResource from no-op'ing (no stretch).
    const Frame = struct {
        model: *Model,
        win: @TypeOf(window),
        backend: @TypeOf(b),
        db: *d3d_backend.D3dBackend,
        swapchain: @TypeOf(swapchain),
        arena: *std.heap.ArenaAllocator,
        placements: *[]layout_mod.Placement,

        fn draw(self: *@This()) void {
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const px = platform.contentPixelSize(self.win);
            self.swapchain.resize(@intCast(px.width), @intCast(px.height)) catch {};
            const scale: f32 = @floatCast(px.scale);
            const root = buildTree(Model, self.model, a, scale) catch return;
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = layout_mod.layout(a, self.backend, root, viewport) catch return;
            self.placements.* = result.placements;
            self.backend.beginFrame(viewport) catch return;
            layout_mod.render(self.backend, result);
            self.backend.endFrame() catch return;
            self.db.presentTo(self.swapchain);
        }
    };
    var frame: Frame = .{ .model = model, .win = window, .backend = b, .db = &db, .swapchain = swapchain, .arena = &frame_arena, .placements = &placements };
    window.setRedraw(&frame, struct {
        fn call(p: ?*anyopaque) void {
            const f: *Frame = @ptrCast(@alignCast(p));
            f.draw();
        }
    }.call);

    var fl = FrameLoop.init(platform.refreshHz(window));
    var last_cursor: cursor_mod.Cursor = .default; // #123: only re-set on change
    setupMenuBar(Model, window, model); // #129: install the native menu bar
    loop: while (true) {
        const dt = fl.delta(io);
        for (window.pumpEvents()) |ev| {
            applyCursor(Model, window, model, placements, ev, &last_cursor);
            switch (dispatch(Model, Msg, model, ev, placements)) {
                .none => {},
                .redraw => dirty = true,
                .quit => break :loop,
            }
            // Native right-click context menu (#129): pops at the click and
            // routes the choice through the model's onMenuCommand.
            if (handleContextMenu(Model, window, model, ev) == .redraw) dirty = true;
        }
        // Native menu-bar selections + file-open requests (#129).
        if (frameOsHooks(Model, window, model, gpa, io) == .redraw) dirty = true;
        if (animate(Model, model, dt) == .redraw) dirty = true;
        if (modelBackground(Model, model)) |c| db.clear_color = c.rgbaF(); // theming toggle

        if (dirty) {
            // Headless capture hook: render one frame to the offscreen RT,
            // read it back, write a PPM, and exit.
            if (capture_path) |path| {
                _ = frame_arena.reset(.retain_capacity);
                const arena = frame_arena.allocator();
                const px = platform.contentPixelSize(window);
                const scale: f32 = @floatCast(px.scale);
                const root = try buildTree(Model, model, arena, scale);
                const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
                const result = try layout_mod.layout(arena, b, root, viewport);
                placements = result.placements;
                try b.beginFrame(viewport);
                layout_mod.render(b, result);
                try b.endFrame();
                const pixels = try db.readPixels();
                defer gpa.free(pixels);
                try writePpm(gpa, io, path, pixels, db.off.width, db.off.height);
                return;
            }
            frame.draw();
            dirty = false;
            // GPU device-lost recovery (#25): present reported the device was
            // removed/reset (driver upgrade, TDR, GPU eviction). Rebuild the
            // whole D3D device + swapchain and every device-bound resource
            // (backend renderers + glyph atlas + textures), then redraw — the
            // app/model code never sees it. If the rebuild itself fails (e.g.
            // the GPU is gone for good), exit the GPU loop cleanly.
            if (swapchain.isLost()) {
                d3dRecover(&db, swapchain, theme, gpa, io) catch break :loop;
                dirty = true;
            }
        }

        // Re-pace if the window moved to a different-refresh monitor (#27).
        if (fl.shouldRetune()) fl.retune(platform.refreshHz(window));
        try fl.pace(io);
    }
}

/// GPU device-lost recovery (#25): rebuild the D3D device + swapchain and the
/// whole backend (renderers + glyph atlas + textures) in place, on the same
/// window, then reload the system font. `db` is mutated in place so the
/// Backend interface pointer the loop holds stays valid. Errors propagate so
/// the caller can exit the GPU loop (the GPU is gone for good / no fallback).
fn d3dRecover(
    db: *d3d_backend.D3dBackend,
    swapchain: anytype,
    theme: Theme,
    gpa: std.mem.Allocator,
    io: std.Io,
) !void {
    std.log.scoped(.d3d11).warn("device lost — recovering", .{});
    try swapchain.recreate(); // new device + context + swapchain (same window)
    db.deinit(); // release renderers/atlas/textures bound to the dead device
    db.* = try d3d_backend.D3dBackend.initOnDevice(gpa, swapchain.device, swapchain.context);
    db.clear_color = theme.clearRgba();
    if (system_font.loadFontSet(gpa, io)) |set| db.setFontSet(set);
    std.log.scoped(.d3d11).info("device recovered", .{});
}

/// Minimal P6 (binary RGB) PPM writer for the ZOOEE_CAPTURE hook on Windows
/// (the GL path reuses gl.zig's writer). `rgba` is top-down RGBA.
fn writePpm(gpa: std.mem.Allocator, io: std.Io, path: []const u8, rgba: []const u8, w: u32, h: u32) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var hbuf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&hbuf, "P6\n{d} {d}\n255\n", .{ w, h });
    try buf.appendSlice(gpa, header);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) try buf.appendSlice(gpa, rgba[i .. i + 3]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

/// Opt-in window-path diagnostic: when ZOOEE_WINLOG names a file, record
/// which present path runWindow chose (the GUI demo is subsystem=.Windows,
/// so it has no console). One line per run; truncates. No-op otherwise.
fn winlog(init: std.process.Init, comptime fmt: []const u8, args: anytype) void {
    const path = init.environ_map.get("ZOOEE_WINLOG") orelse return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = line }) catch {};
}

pub const WindowOptions = struct {
    title: [:0]const u8 = "zooee",
    width: u32 = 800,
    height: u32 = 600,
    /// Force the CPU raster + OS-blit path even where a GPU backend exists
    /// (same effect as the ZOOEE_SOFTWARE env var). Lets a build bake the
    /// renderer choice in — e.g. separate GL and raster demo apps.
    force_software: bool = false,
    /// Theme tokens (theming). `background` becomes every backend's clear
    /// color, so the window backdrop and the area exposed during a resize-grow
    /// match the app's content instead of a hard-coded white.
    theme: Theme = Theme.light,
    /// Title-bar presentation (#64): `.native` (default), `.integrated`
    /// (content under a transparent title bar), or `.headless`.
    titlebar: window_mod.TitlebarMode = .native,
};

/// Render a Model's view into `b` once, offscreen — no window, no event
/// loop. The reusable headless-rendering entry point (#13): the test
/// harness drives it with the CPU raster backend to screenshot the full
/// app stack (view → layout → render), and GPU backends will drive the
/// same call against an offscreen FBO/render-target for golden
/// comparison. Returns the LayoutResult (placements) for hit-test reuse;
/// caller owns it (deinit, or use an arena).
pub fn renderOffscreen(
    comptime Model: type,
    model: *Model,
    b: backend_mod.Backend,
    arena: std.mem.Allocator,
    viewport: geometry.Size,
    scale: f32,
) !layout_mod.LayoutResult {
    const root = try buildTree(Model, model, arena, scale);
    const result = try layout_mod.layout(arena, b, root, viewport);
    try b.beginFrame(viewport);
    layout_mod.render(b, result);
    try b.endFrame();
    return result;
}

/// Drive a Model with one event exactly as the production loops do — the
/// seam the synthetic-event harness (#130) uses to self-verify interaction
/// without a real window. `placements` is the current layout result.
pub fn dispatchEvent(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    ev: event_mod.Event,
    placements: []const layout_mod.Placement,
) Command {
    return dispatch(Model, Msg, model, ev, placements);
}

/// Map one event to a Command, dispatching interaction messages through
/// the model. Shared by the terminal and GUI loops.
fn dispatch(
    comptime Model: type,
    comptime Msg: type,
    model: *Model,
    ev: event_mod.Event,
    placements: []const layout_mod.Placement,
) Command {
    return switch (ev) {
        .close_requested => .quit,
        .resized => .redraw,
        .pointer_down => |p| blk: {
            if (p.buttons.primary) {
                if (hitMsg(placements, p.position, .click)) |m| {
                    break :blk model.update(@as(Msg, @enumFromInt(m)));
                }
            }
            break :blk model.onEvent(ev);
        },
        .pointer_move => |p| blk: {
            if (hitMsg(placements, p.position, .hover)) |m| {
                break :blk model.update(@as(Msg, @enumFromInt(m)));
            }
            break :blk model.onEvent(ev);
        },
        else => model.onEvent(ev),
    };
}

/// Native context menu (#129): on a secondary (right) click, if the model
/// exposes `contextMenu()`, pop the OS-native menu at the click and route the
/// chosen item id back through `onMenuCommand(id)`. No-ops for models without
/// the hook, and on X11 (no native menu → popupMenu returns null). Generic over
/// the window type (each platform Window exposes `popupMenu`).
fn handleContextMenu(comptime Model: type, window: anytype, model: *Model, ev: event_mod.Event) Command {
    if (!@hasDecl(Model, "contextMenu")) return .none;
    if (ev != .pointer_down) return .none;
    const p = ev.pointer_down;
    if (!p.buttons.secondary) return .none;
    const items = model.contextMenu() orelse return .none;
    const chosen = window.popupMenu(items, p.position.x, p.position.y) orelse return .none;
    if (@hasDecl(Model, "onMenuCommand")) return model.onMenuCommand(chosen);
    return .none;
}

/// Install the model's native menu bar once at loop start, if it exposes
/// `menuBar()`. No-op otherwise / on X11 (no native menu bar). (#129)
fn setupMenuBar(comptime Model: type, window: anytype, model: *Model) void {
    if (@hasDecl(Model, "menuBar")) window.setMenuBar(model.menuBar());
}

/// Per-frame OS hooks (#129): drain a menu-bar selection and, if the model
/// requested it (via `takeOpenRequest`), show the native file-open dialog and
/// hand the chosen path to `onFileChosen`. Returns `.redraw` if anything
/// changed model state. No-ops without the corresponding hooks.
fn frameOsHooks(comptime Model: type, window: anytype, model: *Model, gpa: std.mem.Allocator, io: std.Io) Command {
    var cmd: Command = .none;
    if (@hasDecl(Model, "menuBar")) {
        if (window.takeMenuCommand()) |id| {
            if (model.onMenuCommand(id) == .redraw) cmd = .redraw;
        }
    }
    if (@hasDecl(Model, "takeOpenRequest") and @hasDecl(Model, "onFileChosen")) {
        if (model.takeOpenRequest()) {
            if (dialog.openFile(gpa, io, .{ .title = "Open a file" })) |maybe| {
                if (maybe) |path| {
                    defer gpa.free(path);
                    if (model.onFileChosen(path) == .redraw) cmd = .redraw;
                }
            } else |_| {}
        }
    }
    // System clipboard (#178): copy text the model hands us, and on a paste
    // request read the clipboard and deliver it to onPaste.
    if (@hasDecl(Model, "takeClipboardWrite")) {
        if (model.takeClipboardWrite()) |text| {
            var clip = systemClipboard(window, gpa);
            clip.interface().setText(text) catch {};
        }
    }
    if (@hasDecl(Model, "requestPaste") and @hasDecl(Model, "onPaste")) {
        if (model.requestPaste()) {
            var clip = systemClipboard(window, gpa);
            if (clip.interface().getText(gpa)) |maybe| {
                if (maybe) |text| {
                    defer gpa.free(text);
                    if (model.onPaste(text) == .redraw) cmd = .redraw;
                }
            } else |_| {}
        }
    }
    return cmd;
}

/// Construct the platform clipboard. X11 needs the window (display + selection
/// ownership); macOS/Windows use a global pasteboard and take the allocator.
fn systemClipboard(window: anytype, gpa: std.mem.Allocator) WindowPlatform.SystemClipboard {
    return if (builtin.os.tag == .linux)
        WindowPlatform.SystemClipboard.init(window)
    else
        WindowPlatform.SystemClipboard.init(gpa);
}

/// On a pointer_move, resolve the cursor under the pointer and apply it to the
/// window — but only when it changed, so the GPU loops don't hammer the OS
/// cursor API every frame. `last` carries the shape across iterations. Generic
/// over the window type (each platform Window exposes `setCursor`).
fn applyCursor(comptime Model: type, window: anytype, model: *Model, placements: []const layout_mod.Placement, ev: event_mod.Event, last: *cursor_mod.Cursor) void {
    switch (ev) {
        .pointer_move => |p| {
            // A model `cursor()` override wins over geometric resolution — this
            // is how a drag locks the cursor (e.g. a splitter): while dragging,
            // the pointer outruns the divider's hit rect, so geometry alone would
            // flip back to `.default`. (Element-level pointer capture is #5.)
            const shape = cursorOverride(Model, model) orelse cursorFor(placements, p.position);
            if (shape != last.*) {
                window.setCursor(shape);
                last.* = shape;
            }
        },
        else => {},
    }
}

/// True for pointer button/move events — used to flag a frame as an interactive
/// drag so the Metal loop presents it synchronously (low latency) instead of via
/// the display link (which buffers a frame and makes dragged content lag).
fn isPointerEvent(ev: event_mod.Event) bool {
    return switch (ev) {
        .pointer_down, .pointer_up, .pointer_move => true,
        else => false,
    };
}

/// The model's active cursor override (#123), or null to fall back to geometric
/// resolution. A model opts in with `pub fn cursor(self) ?Cursor` — used to lock
/// the cursor during a drag.
pub fn cursorOverride(comptime Model: type, model: *Model) ?cursor_mod.Cursor {
    if (@hasDecl(Model, "cursor")) return model.cursor();
    return null;
}

/// The cursor shape (#123) the topmost region under `p` requests, or
/// `.default` when none does. Pure — the platform loops call this on each
/// pointer_move and apply the result via `window.setCursor`.
pub fn cursorFor(placements: []const layout_mod.Placement, p: geometry.Point) cursor_mod.Cursor {
    var shape: cursor_mod.Cursor = .default;
    for (placements) |pl| {
        if (!pl.rect.contains(p)) continue;
        if (pl.element.cursor) |c| shape = c;
    }
    return shape;
}

const Interaction = enum { click, hover };

/// Topmost (last-placed) element containing the point that carries the
/// requested message kind.
fn hitMsg(placements: []const layout_mod.Placement, p: geometry.Point, kind: Interaction) ?u32 {
    var found: ?u32 = null;
    for (placements) |pl| {
        if (!pl.rect.contains(p)) continue;
        const msg = switch (kind) {
            .click => pl.element.on_click,
            .hover => pl.element.on_hover,
        };
        if (msg) |m| found = m;
    }
    return found;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const record = @import("backends/record.zig");

test "buildTree prefers viewUi and lowers it to an Element tree (#4)" {
    const M = struct {
        pub fn viewUi(self: *@This(), u: *ui_mod.Ui) !ui_mod.Widget {
            _ = self;
            return u.column(.{ .gap = 4 }, &.{
                u.text("hi", .{}),
                u.button(.{ .label = "go", .on_click = 9 }),
            });
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m: M = .{};
    const el = try buildTree(M, &m, arena.allocator(), 2);
    try testing.expectEqual(@as(usize, 2), el.children.len);
    try testing.expectEqualStrings("hi", el.children[0].text.?);
    try testing.expectEqual(@as(?u32, 9), el.children[1].on_click);
}

test "hitMsg picks the topmost interactive element" {
    const e1: layout_mod.Element = .{ .on_click = 1 };
    const e2: layout_mod.Element = .{ .on_click = 2 };
    const placements = [_]layout_mod.Placement{
        .{ .element = &e1, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .element = &e2, .rect = .{ .x = 2, .y = 2, .width = 4, .height = 4 } },
    };
    try testing.expectEqual(@as(?u32, 2), hitMsg(&placements, .{ .x = 3, .y = 3 }, .click));
    try testing.expectEqual(@as(?u32, 1), hitMsg(&placements, .{ .x = 8, .y = 8 }, .click));
    try testing.expectEqual(@as(?u32, null), hitMsg(&placements, .{ .x = 50, .y = 50 }, .click));
}

test "cursorFor resolves topmost region, defaults when none" {
    const e1: layout_mod.Element = .{ .cursor = .text };
    const e2: layout_mod.Element = .{ .cursor = .pointer };
    const e3: layout_mod.Element = .{}; // no cursor request
    const placements = [_]layout_mod.Placement{
        .{ .element = &e1, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .element = &e2, .rect = .{ .x = 2, .y = 2, .width = 4, .height = 4 } },
        .{ .element = &e3, .rect = .{ .x = 2, .y = 2, .width = 4, .height = 4 } },
    };
    // Inside e2 (topmost with a cursor): e3 sits on top but requests none, so
    // the last *set* cursor wins → pointer.
    try testing.expectEqual(cursor_mod.Cursor.pointer, cursorFor(&placements, .{ .x = 3, .y = 3 }));
    // Only e1 covers (8,8) → its I-beam.
    try testing.expectEqual(cursor_mod.Cursor.text, cursorFor(&placements, .{ .x = 8, .y = 8 }));
    // Outside everything → default.
    try testing.expectEqual(cursor_mod.Cursor.default, cursorFor(&placements, .{ .x = 50, .y = 50 }));
}
