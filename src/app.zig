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
    g_scale = scale; // for device→logical conversion in scrollbar drag (#312)
    if (@hasDecl(Model, "viewUi")) {
        var u = ui_mod.Ui.init(arena);
        u.scale = scale;
        // Widgets resolve colors from the theme (#21): the model's `theme()` hook,
        // else the dark default. (Pairs with `background()` for the clear color.)
        if (@hasDecl(Model, "theme")) u.theme = model.theme();
        focus_ring_color = u.theme.accent; // focus ring tracks the theme accent (#310)
        selection_color = u.theme.selection; // text-selection highlight (#318)
        selection_text_color = u.theme.selection_text;
        layout_mod.scrollbar_thumb = .{ .r = u.theme.text_muted.r, .g = u.theme.text_muted.g, .b = u.theme.text_muted.b, .a = 150 }; // muted neutral thumb (#312)
        return u.lower(try model.viewUi(&u));
    }
    return model.view(arena, scale);
}

const window_mod = @import("window.zig");
pub const Theme = theme_mod.Theme;

/// The key window's native ID for a window-only screenshot (`screencapture
/// -l<id>` on macOS). Null where unsupported. Debug aid for tooling (#306).
pub fn keyWindowId() ?i64 {
    if (@hasDecl(WindowPlatform, "keyWindowNumber")) return WindowPlatform.keyWindowNumber();
    return null;
}

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
        renderFocusRing(b, result.placements); // focus ring (#310)
        renderTextSelection(b, result.placements); // text selection (#318)
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
            renderFocusRing(b, result.placements); // focus ring (#310)
            renderTextSelection(b, result.placements); // text selection (#318)
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
        if (layout_mod.tickScrollbarFade(dt)) dirty = true; // scrollbar fade (#312)

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
            renderFocusRing(self.backend, result.placements); // focus ring (#310)
            renderTextSelection(self.backend, result.placements); // text selection (#318)
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
        if (layout_mod.tickScrollbarFade(dt)) dirty = true; // scrollbar fade (#312)

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
    glb.present_only = capture_path == null; // pipeline the present (#264)
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
            renderFocusRing(self.backend, result.placements); // focus ring (#310)
            renderTextSelection(self.backend, result.placements); // text selection (#318)
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
        if (layout_mod.tickScrollbarFade(dt)) dirty = true; // scrollbar fade (#312)
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
                renderFocusRing(b, result.placements); // focus ring (#310)
                renderTextSelection(b, result.placements); // text selection (#318)
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
    // Opt-in latency readout (#268): prints pump→present time on drag frames so
    // the input-to-photon budget can be measured, not guessed.
    const latency_log = init.environ_map.contains("ZOOEE_LATENCY");

    var ctx = try metal_backend.MetalContext.create();
    defer ctx.destroy();
    const px0 = platform.contentPixelSize(window);
    var layer = try metal_backend.MetalLayer.createOnView(ctx.device, window.contentView(), @intCast(px0.width), @intCast(px0.height));

    var mb = try metal_backend.MetalBackend.initOn(gpa, ctx.device, ctx.queue);
    mb.clear_color = theme.clearRgba(); // theme backdrop (theming)
    // Windowed present pipelines (no per-frame GPU stall); the capture path
    // reads pixels back on the CPU, so it keeps the completion wait (#264).
    mb.present_only = capture_path == null;
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
        io: std.Io,
        /// Print a per-phase timing breakdown for this frame (ZOOEE_LATENCY).
        profile: bool = false,

        fn draw(self: *@This()) void {
            // Drain this frame's autoreleased Metal objects (drawable, command
            // buffer, descriptors) so they don't pile up across frames — covers
            // both the loop and the modal-resize redraw callback.
            const pool = metal_backend.pushPool();
            defer metal_backend.drainPool(pool);
            const prof = self.profile;
            var t = if (prof) std.Io.Timestamp.now(self.io, .awake).nanoseconds else 0;
            const lap = struct {
                fn f(on: bool, iox: std.Io, prev: *i96) i64 {
                    if (!on) return 0;
                    const now = std.Io.Timestamp.now(iox, .awake).nanoseconds;
                    defer prev.* = now;
                    return @intCast(@divTrunc(now - prev.*, 1000));
                }
            }.f;
            // Runtime theme changes track the clear color (theming toggle).
            if (modelBackground(Model, self.model)) |c| self.mb.clear_color = c.rgbaF();
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const px = platform.contentPixelSize(self.win);
            self.layer.resize(@intCast(px.width), @intCast(px.height));
            const scale: f32 = @floatCast(px.scale);
            const root = buildTree(Model, self.model, a, scale) catch return;
            const t_build = lap(prof, self.io, &t);
            const viewport: geometry.Size = .{ .width = @floatFromInt(px.width), .height = @floatFromInt(px.height) };
            const result = layout_mod.layout(a, self.backend, root, viewport) catch return;
            const t_layout = lap(prof, self.io, &t);
            self.placements.* = result.placements;
            self.backend.beginFrame(viewport) catch return;
            const t_begin = lap(prof, self.io, &t);
            layout_mod.render(self.backend, result);
            renderFocusRing(self.backend, result.placements); // focus ring (#310)
            renderTextSelection(self.backend, result.placements); // text selection (#318)
            const t_walk = lap(prof, self.io, &t);
            self.backend.endFrame() catch return;
            const t_end = lap(prof, self.io, &t);
            // Transaction-synced present only during a live-resize drag; async
            // (display-link-paced) otherwise, so steady animation stays smooth.
            self.mb.presentTo(self.layer, self.win.inLiveResize() or self.sync_present);
            const t_present = lap(prof, self.io, &t);
            if (prof) std.debug.print("[latency] build {d}us  layout {d}us  begin {d}us  walk {d}us  end {d}us  present {d}us\n", .{ t_build, t_layout, t_begin, t_walk, t_end, t_present });
        }
    };
    var frame: Frame = .{ .model = model, .win = window, .backend = b, .mb = &mb, .layer = &layer, .arena = &frame_arena, .placements = &placements, .io = io };
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
        if (layout_mod.tickScrollbarFade(dt)) dirty = true; // scrollbar fade (#312)
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
                renderFocusRing(b, result.placements); // focus ring (#310)
                renderTextSelection(b, result.placements); // text selection (#318)
                try b.endFrame();
                const pixels = try mb.readPixels();
                defer gpa.free(pixels);
                try writePpm(gpa, io, path, pixels, mb.width, mb.height);
                return;
            }
            frame.profile = latency_log and pointer_drag;
            frame.draw();
            dirty = false;
        }

        // Re-pace if the window moved to a different-refresh monitor (#27).
        if (fl.shouldRetune()) fl.retune(platform.refreshHz(window));
        // Skip the pacing sleep on frames driven by a pointer drag: the sync
        // present already paces us, and sleeping would age the *next* input by
        // up to a full refresh before we pump it (the residual divider lag).
        // Holding still mid-drag emits no events → pointer_drag is false → we
        // pace normally, so this never busy-spins.
        if (!pointer_drag) try fl.pace(io);
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
            renderFocusRing(self.backend, result.placements); // focus ring (#310)
            renderTextSelection(self.backend, result.placements); // text selection (#318)
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
        if (layout_mod.tickScrollbarFade(dt)) dirty = true; // scrollbar fade (#312)
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
                renderFocusRing(b, result.placements); // focus ring (#310)
                renderTextSelection(b, result.placements); // text selection (#318)
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
    renderFocusRing(b, result.placements); // focus ring (#310)
    renderTextSelection(b, result.placements); // text selection (#318)
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

/// Keyboard focus (#310). The index of the focused element among the focusable
/// placements, in layout (Tab) order; null = nothing focused. Module-global like
/// the scroll range — single primary window assumed (per-window/keyed state is
/// the #5 follow-up). Apps/tests can read or reset it.
var g_focus: ?usize = null;
/// Whether the focus ring should show (`:focus-visible`, web parity): true when
/// focus last moved by keyboard (Tab), false when it moved by a pointer click —
/// so clicking a control focuses it without a ring, but Tabbing shows one.
var g_focus_visible: bool = false;

/// Read-only text selection (#318): the selectable text being dragged (its
/// placement index) and the raw drag endpoints in absolute coords. The render
/// pass resolves these points to byte offsets (it has the backend for caret
/// math) and draws the highlight; copy slices the source by those offsets.
/// Single active selection, like g_focus.
const TextSelection = struct {
    idx: usize,
    anchor_pt: geometry.Point,
    focus_pt: geometry.Point,
    dragging: bool = false,
};
var g_textsel: ?TextSelection = null;
var g_copy_request: bool = false; // ⌘C pressed; the render pass fills the buffer
var g_copy_pending: bool = false; // buffer ready; the OS-hooks pass writes the clipboard
var g_copy_buf: [4096]u8 = undefined;
var g_copy_len: usize = 0;

/// Clear any active text selection (tests / programmatic).
pub fn resetTextSelection() void {
    g_textsel = null;
    g_copy_request = false;
    g_copy_pending = false;
}

/// Topmost selectable text element under `p` (last in paint order wins).
fn selectableAt(placements: []const layout_mod.Placement, p: geometry.Point) ?usize {
    var found: ?usize = null;
    for (placements, 0..) |pl, i| {
        if (pl.element.text_selectable and pl.element.text != null and pl.rect.contains(p)) found = i;
    }
    return found;
}

/// Draw the active text selection's highlight, resolving the drag points to
/// byte offsets via the backend (#318). On a pending ⌘C, copy the selected
/// substring into g_copy_buf for the OS-hooks pass to put on the clipboard.
/// Called by every present loop right after `render`.
fn renderTextSelection(b: backend_mod.Backend, placements: []const layout_mod.Placement) void {
    const ts = g_textsel orelse return;
    if (ts.idx >= placements.len) return;
    const pl = placements[ts.idx];
    const el = pl.element;
    const t = el.text orelse return;
    if (!el.text_selectable) return;
    const inner = layout_mod.contentBoxOf(el, pl.rect);
    const a = layout_mod.textCaretAt(b, el, inner, ts.anchor_pt);
    const f = layout_mod.textCaretAt(b, el, inner, ts.focus_pt);
    // Highlight in the themed selection tint, with the selected glyphs redrawn
    // in the selection text color on top (#318).
    layout_mod.drawTextSelection(b, el, inner, a, f, selection_color, selection_text_color);

    if (g_copy_request) {
        const lo = @min(a, f);
        const hi = @min(@max(a, f), t.len);
        const start = @min(lo, hi);
        const len = @min(hi - start, g_copy_buf.len);
        @memcpy(g_copy_buf[0..len], t[start .. start + len]);
        g_copy_len = len;
        g_copy_request = false;
        g_copy_pending = true;
    }
}

pub fn focusedIndex() ?usize {
    return g_focus;
}
/// Whether the focus ring should currently show (`:focus-visible`): true after
/// keyboard focus, false after a mouse click. Backends gate ring drawing on it.
pub fn focusVisible() bool {
    return g_focus_visible;
}

/// The `on_scroll` id of the region the last scroll event was delivered to
/// (#312). Lets a model with several scroll regions route the wheel to the right
/// one from `onEvent` (which otherwise only sees the event, not which region).
var g_scroll_target: ?u32 = null;
pub fn scrollTarget() ?u32 {
    return g_scroll_target;
}

/// Device-pixel scale for the current frame (set in buildTree), used to convert
/// a device-space scrollbar drag back to the app's logical scroll offset (#312).
var g_scale: f32 = 1;

/// The logical max scroll offset for the region with this `on_scroll` id (#312),
/// read from the scrollbar recorded last frame; 0 if the region isn't
/// overflowing. Lets a model clamp its stored offset per region so scrolling /
/// dragging can't drift past the ends (sticky scroll-back).
pub fn scrollMaxFor(id: u32) f32 {
    return scrollMaxAxis(id, true);
}

/// Logical max scroll offset for a region on one axis (#313), from last frame's
/// scrollbar; 0 if that axis isn't overflowing.
fn scrollMaxAxis(id: u32, vertical: bool) f32 {
    const sc = if (g_scale > 0) g_scale else 1;
    for (layout_mod.scrollbars()) |sb| {
        if (sb.scroll_id == id and sb.vertical == vertical) return sb.max_offset / sc;
    }
    return 0;
}

// --- Built-in scroll (#313) -------------------------------------------------
// The framework owns the scroll offset per region (keyed by `on_scroll` id):
// it applies the wheel/drag with the OS-supplied (natural-scroll-aware) delta in
// the canonical direction and clamps to the content. Apps just read
// scrollOffset(id) into the container's scroll_x/scroll_y and never code scroll
// direction or clamping. One logical scroll-line ≈ this many px.
const scroll_line_px: f32 = 40;

const ScrollState = struct { id: u32, x: f32 = 0, y: f32 = 0 };
var g_scroll_state: [16]ScrollState = undefined;
var g_scroll_state_n: usize = 0;

fn scrollSlot(id: u32) *ScrollState {
    for (g_scroll_state[0..g_scroll_state_n]) |*s| {
        if (s.id == id) return s;
    }
    if (g_scroll_state_n < g_scroll_state.len) {
        g_scroll_state[g_scroll_state_n] = .{ .id = id };
        g_scroll_state_n += 1;
        return &g_scroll_state[g_scroll_state_n - 1];
    }
    return &g_scroll_state[0];
}

/// The framework-owned scroll offset (logical px) for the region with this
/// `on_scroll` id (#313). Apps read it into the scroll container's
/// scroll_x/scroll_y; the framework keeps it correct (direction + clamp) on
/// wheel and thumb-drag. Built-in — no per-app scroll-direction code.
pub fn scrollOffset(id: u32) struct { x: f32, y: f32 } {
    const s = scrollSlot(id);
    return .{ .x = s.x, .y = s.y };
}

/// Set a region's built-in scroll offset programmatically (#313): jump to a
/// position, reset on a layout change, or restore saved state. Clamped to
/// content at render.
pub fn setScrollOffset(id: u32, x: f32, y: f32) void {
    const s = scrollSlot(id);
    s.x = x;
    s.y = y;
}

/// Apply a wheel delta to a region's built-in offset, clamped to content (#313).
/// Platforms normalize the wheel to one canonical convention (#309): dy>0 =
/// toward later content (scroll down), dx>0 = right. Each platform bakes the
/// user's natural-scroll setting into the delta at its boundary (macOS negates
/// the inverted AppKit delta; Win32 negates its raw wheel; X11's increment sign
/// already carries it), so here we simply add — one place, all platforms.
fn applyWheel(id: u32, dx: f32, dy: f32, unit: event_mod.ScrollUnit) void {
    const step: f32 = if (unit == .pixel) 1 else scroll_line_px;
    const s = scrollSlot(id);
    s.y = std.math.clamp(s.y + dy * step, 0, scrollMaxAxis(id, true));
    s.x = std.math.clamp(s.x + dx * step, 0, scrollMaxAxis(id, false));
}

/// An in-progress scrollbar thumb drag (#312).
const BarDrag = struct {
    scroll_id: u32,
    vertical: bool,
    grab: f32, // pointer-to-thumb-start offset along the axis at grab time (device)
};
var g_bar_drag: ?BarDrag = null;

/// A primary-button press over a scrollbar thumb starts a drag (#312). Returns
/// true if a thumb was grabbed (the press is consumed).
fn beginBarDrag(p: geometry.Point) bool {
    // You can only grab a bar you can see. Thumbs stay recorded while the
    // overlay is auto-hidden (so wheel scroll still works), but hit-testing a
    // faded-out thumb would silently swallow clicks on the content beneath it.
    if (!layout_mod.scrollbarsVisible()) return false;
    for (layout_mod.scrollbars()) |sb| {
        if (!sb.thumb.contains(p)) continue;
        const along = if (sb.vertical) p.y else p.x;
        const thumb_start = if (sb.vertical) sb.thumb.y else sb.thumb.x;
        g_bar_drag = .{ .scroll_id = sb.scroll_id, .vertical = sb.vertical, .grab = along - thumb_start };
        layout_mod.bumpScrollbars(); // keep the bar lit while dragging (#312)
        return true;
    }
    return false;
}

/// While dragging a thumb, map the pointer to the target offset and set the
/// dragged region's built-in offset so the thumb tracks the cursor (#312/#313).
fn dragBar(p: geometry.Point) void {
    const drag = g_bar_drag orelse return;
    layout_mod.bumpScrollbars(); // stay lit through the drag
    for (layout_mod.scrollbars()) |sb| {
        if (sb.scroll_id != drag.scroll_id or sb.vertical != drag.vertical) continue;
        const avail = sb.track_len - sb.thumb_len;
        if (avail <= 0) return;
        const along = if (drag.vertical) p.y else p.x;
        const t = std.math.clamp((along - drag.grab - sb.track_start) / avail, 0, 1);
        const target_logical = (t * sb.max_offset) / (if (g_scale > 0) g_scale else 1);
        const s = scrollSlot(drag.scroll_id);
        if (drag.vertical) s.y = target_logical else s.x = target_logical;
        return;
    }
}
pub fn resetFocus() void {
    g_focus = null;
    g_focus_visible = false;
}

/// Number of focusable elements in the frame (the Tab order length).
fn focusableCount(placements: []const layout_mod.Placement) usize {
    var n: usize = 0;
    for (placements) |pl| {
        if (pl.element.focusable) n += 1;
    }
    return n;
}

/// The roving-tabindex group of the i-th focusable element (null = standalone).
fn groupOf(placements: []const layout_mod.Placement, i: usize) ?u32 {
    var k: usize = 0;
    for (placements) |pl| {
        if (!pl.element.focusable) continue;
        if (k == i) return pl.element.tab_group;
        k += 1;
    }
    return null;
}

/// First/last focusable index of the contiguous same-group run containing `i`
/// (a roving group is one tab "stop"); a standalone element is its own stop.
fn stopStart(placements: []const layout_mod.Placement, i: usize) usize {
    const g = groupOf(placements, i) orelse return i;
    var s = i;
    while (s > 0 and groupOf(placements, s - 1) == g) s -= 1;
    return s;
}
fn stopEnd(placements: []const layout_mod.Placement, i: usize, n: usize) usize {
    const g = groupOf(placements, i) orelse return i;
    var e = i;
    while (e + 1 < n and groupOf(placements, e + 1) == g) e += 1;
    return e;
}

/// Move to the next/prev tab STOP (#310/#16): a roving group counts as one stop,
/// so Tab enters a list at its first row and Shift+Tab lands on a prior stop's
/// start. From nothing focused, the first (or last) stop.
fn nextStop(placements: []const layout_mod.Placement, cur: ?usize, n: usize, shift: bool) ?usize {
    if (n == 0) return null;
    const c = cur orelse return if (shift) stopStart(placements, n - 1) else 0;
    if (shift) {
        const prev_end = (stopStart(placements, c) + n - 1) % n;
        return stopStart(placements, prev_end);
    }
    return (stopEnd(placements, c, n) + 1) % n;
}

/// Move within the current roving group with an arrow key (wrap inside the
/// group); null when the focused element is standalone (arrows then pass to the
/// app). `up` reverses.
fn arrowWithinGroup(placements: []const layout_mod.Placement, cur: usize, n: usize, up: bool) ?usize {
    _ = groupOf(placements, cur) orelse return null;
    const s = stopStart(placements, cur);
    const e = stopEnd(placements, cur, n);
    if (up) return if (cur > s) cur - 1 else e;
    return if (cur < e) cur + 1 else s;
}

/// The placement of the currently-focused element, or null. Drives Enter
/// activation and the focus ring.
fn focusedPlacement(placements: []const layout_mod.Placement) ?layout_mod.Placement {
    const target = g_focus orelse return null;
    var i: usize = 0;
    for (placements) |pl| {
        if (!pl.element.focusable) continue;
        if (i == target) return pl;
        i += 1;
    }
    return null;
}

/// The focused element's border-box rect (for drawing the focus ring), or null.
pub fn focusedRect(placements: []const layout_mod.Placement) ?geometry.Rect {
    return if (focusedPlacement(placements)) |pl| pl.rect else null;
}

/// Activate the focused element's `on_click` (Enter/Space, web parity): returns
/// the resulting Command, or null if nothing focusable is focused / has a click.
fn activateFocused(comptime Model: type, comptime Msg: type, model: *Model, placements: []const layout_mod.Placement) ?Command {
    if (focusedPlacement(placements)) |pl| {
        if (pl.element.on_click) |m| return model.update(@as(Msg, @enumFromInt(m)));
    }
    return null;
}

/// Move focus to `new` (an index into the focusable placements, or null),
/// firing `on_blur` on the element losing focus and `on_focus` on the one
/// gaining it (#310). No-op when focus is unchanged.
fn changeFocus(comptime Model: type, comptime Msg: type, model: *Model, placements: []const layout_mod.Placement, new: ?usize) void {
    if (g_focus == new) return;
    if (focusedPlacement(placements)) |old| {
        if (old.element.on_blur) |m| _ = model.update(@as(Msg, @enumFromInt(m)));
    }
    g_focus = new;
    if (focusedPlacement(placements)) |nw| {
        if (nw.element.on_focus) |m| _ = model.update(@as(Msg, @enumFromInt(m)));
    }
}

/// Focus-ring color (#310): the theme accent, refreshed each frame from the
/// model's theme in `buildTree`. Falls back to the system accent blue before the
/// first build / for raw `view` models. Width/offset/radius are still the
/// pixel-tunable part.
var focus_ring_color = style_mod.Color.rgb(10, 132, 255);
var selection_color = theme_mod.Theme.dark.selection; // text-selection highlight (#318)
var selection_text_color = theme_mod.Theme.dark.selection_text;

/// Draw the focus ring around the focused element (#310): a 2px accent outline
/// just outside its border box, matching its corner radius. Loops call this
/// after `render`. No-op when nothing is focused.
pub fn renderFocusRing(b: backend_mod.Backend, placements: []const layout_mod.Placement) void {
    if (!g_focus_visible) return; // :focus-visible — keyboard focus only
    const pl = focusedPlacement(placements) orelse return;
    const o: f32 = 2; // outset from the border box
    const ring: geometry.Rect = .{
        .x = pl.rect.x - o,
        .y = pl.rect.y - o,
        .width = pl.rect.width + 2 * o,
        .height = pl.rect.height + 2 * o,
    };
    b.drawRect(ring, .{ .border = style_mod.Border.all(2, focus_ring_color), .corner_radius = pl.element.rect_style.corner_radius });
}

/// The focusable index of the topmost focusable element under `p` (for
/// click-to-focus), or null if the click missed every focusable element.
fn focusIndexAt(placements: []const layout_mod.Placement, p: geometry.Point) ?usize {
    var found: ?usize = null;
    var i: usize = 0;
    for (placements) |pl| {
        if (!pl.element.focusable) continue;
        if (pl.rect.contains(p)) found = i; // last (topmost) wins
        i += 1;
    }
    return found;
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
                // Grab a scrollbar thumb if the press landed on one (#312).
                if (beginBarDrag(p.position)) break :blk .redraw;
                // Text selection (#318): pressing on selectable text starts a
                // drag-select; pressing elsewhere clears any existing selection.
                if (selectableAt(placements, p.position)) |sidx| {
                    g_textsel = .{ .idx = sidx, .anchor_pt = p.position, .focus_pt = p.position, .dragging = true };
                    break :blk .redraw;
                }
                if (g_textsel != null) g_textsel = null;
                // Click-to-focus (#310, web parity): a primary click moves focus
                // to the focusable element under the pointer — but without a ring
                // (:focus-visible shows only for keyboard focus).
                if (focusIndexAt(placements, p.position)) |fi| {
                    changeFocus(Model, Msg, model, placements, fi);
                    g_focus_visible = false;
                }
                if (hitMsg(placements, p.position, .click)) |m| {
                    break :blk model.update(@as(Msg, @enumFromInt(m)));
                }
            }
            break :blk model.onEvent(ev);
        },
        .pointer_up => blk: {
            g_bar_drag = null; // end any scrollbar drag
            if (g_textsel) |*ts| ts.dragging = false; // end a text drag-select (#318)
            break :blk model.onEvent(ev); // also let the app end a drag of its own
        },
        .pointer_move => |p| blk: {
            // Extending a text selection (#318) takes precedence while dragging.
            if (g_textsel) |*ts| if (ts.dragging) {
                ts.focus_pt = p.position;
                break :blk .redraw;
            };
            // A scrollbar drag takes precedence and scrolls the dragged region.
            if (g_bar_drag != null) {
                dragBar(p.position);
                break :blk .redraw;
            }
            if (hitMsg(placements, p.position, .hover)) |m| {
                break :blk model.update(@as(Msg, @enumFromInt(m)));
            }
            break :blk model.onEvent(ev);
        },
        // Scroll routing (#309): a scroll event carries a delta (not expressible
        // as a bare Msg), so rather than dispatch through update() we forward the
        // full event to onEvent. Scoped routing is opt-in: once any element marks
        // itself a scroll target with `on_scroll`, scroll is delivered only when
        // the pointer is over a target (so input doesn't leak between regions);
        // until then scroll is global, preserving the legacy onEvent behavior.
        .scroll => |s| blk: {
            if (!anyOnScroll(placements)) {
                g_scroll_target = null;
                break :blk model.onEvent(ev);
            }
            if (hitMsg(placements, s.position, .scroll)) |id| {
                g_scroll_target = id; // which region the wheel is over (#312)
                applyWheel(id, s.dx, s.dy, s.unit); // built-in offset (#313)
                layout_mod.bumpScrollbars(); // reveal the overlay bars
                // Still notify onEvent for apps that handle scroll themselves; the
                // built-in offset is the recommended path (read app.scrollOffset).
                const cmd = model.onEvent(ev);
                break :blk if (cmd == .quit) .quit else .redraw;
            }
            break :blk .none;
        },
        // Keyboard navigation (#310), web-parity: Tab / Shift+Tab move focus
        // through focusable elements in layout order (wrap-around); Enter
        // activates the focused element's `on_click`. Any other key, and keys
        // when nothing focusable exists, still fall through to onEvent.
        .key_down => |k| blk: {
            if (k.key == .tab) {
                const n = focusableCount(placements);
                if (n == 0) break :blk model.onEvent(ev);
                changeFocus(Model, Msg, model, placements, nextStop(placements, g_focus, n, k.mods.shift));
                g_focus_visible = true; // keyboard focus → show the ring
                break :blk .redraw;
            }
            // Arrow keys move within the focused roving group (#310/#16: list /
            // radio group / segmented control). Standalone controls don't capture
            // arrows — they pass to the app — matching the web.
            if ((k.key == .up or k.key == .down) and g_focus != null) {
                if (arrowWithinGroup(placements, g_focus.?, focusableCount(placements), k.key == .up)) |nx| {
                    changeFocus(Model, Msg, model, placements, nx);
                    g_focus_visible = true;
                    break :blk .redraw;
                }
            }
            if (k.key == .enter) {
                if (activateFocused(Model, Msg, model, placements)) |cmd| break :blk cmd;
            }
            // Esc blurs (clears focus), web parity — but still reaches onEvent so
            // the app can also use Esc (e.g. to close a dialog).
            if (k.key == .escape) {
                const had = g_focus != null;
                changeFocus(Model, Msg, model, placements, null);
                g_focus_visible = false;
                const cmd = model.onEvent(ev);
                break :blk if (cmd == .none and had) .redraw else cmd;
            }
            break :blk model.onEvent(ev);
        },
        // Space activates the focused control too (web parity), as long as it's a
        // plain Space — otherwise it's ordinary text. (Once focusable text fields
        // exist, the focused element's kind decides type-vs-activate.)
        .text => |t| blk: {
            // Copy the active text selection (#318): ⌘C / Ctrl+C. The render pass
            // resolves the selected substring and the OS-hooks pass writes it.
            if ((t.mods.super or t.mods.ctrl) and (t.codepoint == 'c' or t.codepoint == 'C') and g_textsel != null) {
                g_copy_request = true;
                break :blk .redraw;
            }
            if (t.codepoint == ' ' and !t.mods.ctrl and !t.mods.alt and !t.mods.super) {
                if (activateFocused(Model, Msg, model, placements)) |cmd| break :blk cmd;
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
    // Text-selection copy (#318): the render pass filled the buffer on ⌘C.
    if (g_copy_pending) {
        var clip = systemClipboard(window, gpa);
        clip.interface().setText(g_copy_buf[0..g_copy_len]) catch {};
        g_copy_pending = false;
    }
    // Live OS theme change (#318): the user changed their accent / light-dark in
    // System Settings → repaint so theme() re-reads the system colors.
    if (@hasDecl(WindowPlatform, "takeAppearanceChanged") and WindowPlatform.takeAppearanceChanged()) cmd = .redraw;
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

/// The user's OS accent color, if the platform exposes one (#318). A Model can
/// match the system in its `theme()` hook:
///   `return Theme.dark.withAccent(zooee.app.systemAccent() orelse Theme.dark.accent);`
pub fn systemAccent() ?style_mod.Color {
    if (@hasDecl(WindowPlatform, "systemAccent")) return WindowPlatform.systemAccent();
    return null;
}

/// Whether the OS is in dark mode, if the platform reports it (#318) — for an
/// app that wants to default its theme to the system appearance.
pub fn systemPrefersDark() bool {
    if (@hasDecl(WindowPlatform, "prefersDark")) return WindowPlatform.prefersDark();
    return false;
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

const Interaction = enum { click, hover, scroll };

/// Whether any placed element opts into scoped scroll routing (#309).
fn anyOnScroll(placements: []const layout_mod.Placement) bool {
    for (placements) |pl| if (pl.element.on_scroll != null) return true;
    return false;
}

/// Topmost (last-placed) element containing the point that carries the
/// requested message kind.
fn hitMsg(placements: []const layout_mod.Placement, p: geometry.Point, kind: Interaction) ?u32 {
    var found: ?u32 = null;
    for (placements) |pl| {
        if (!pl.rect.contains(p)) continue;
        const msg = switch (kind) {
            .click => pl.element.on_click,
            .hover => pl.element.on_hover,
            // A scroll target is anything with an explicit on_scroll id, or any
            // engine scroll container (legacy `scroll` flag / non-visible
            // overflow) so existing scroll views keep receiving the wheel. The
            // sentinel 0 just signals "a target is here" when there's no id.
            .scroll => pl.element.on_scroll orelse
                (if (pl.element.scroll or pl.element.overflow_x != .visible or pl.element.overflow_y != .visible) @as(u32, 0) else null),
        };
        if (msg) |m| found = m;
    }
    return found;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const record = @import("backends/record.zig");

test "focus ring draws an accent outline around the focused element (#310)" {
    resetFocus();
    var rb = raster_mod.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    const b = rb.interface();

    // A focusable 40x20 box at (10,10); the ring outsets 2px → spans (8,8)-(52,32).
    const btn: layout_mod.Element = .{ .width = 40, .height = 20, .focusable = true, .on_click = 1 };
    const root: layout_mod.Element = .{ .padding = .{ .left = 10, .top = 10, .right = 10, .bottom = 10 }, .children = &.{&btn} };

    try b.beginFrame(.{ .width = 64, .height = 44 });
    var result = try layout_mod.layout(testing.allocator, b, &root, .{ .width = 64, .height = 44 });
    defer result.deinit(testing.allocator);

    // Nothing focused → no ring (the pixel just outside the box stays clear).
    layout_mod.render(b, result);
    renderFocusRing(b, result.placements);
    try testing.expectEqual(style_mod.Color.rgb(255, 255, 255), rb.pixelAt(9, 20));

    // Tab focuses the box → the ring paints accent blue just outside it.
    const Msg = enum(u32) { _ };
    const M = struct {
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    var m: M = .{};
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .tab } }, result.placements);
    layout_mod.render(b, result);
    renderFocusRing(b, result.placements);
    try b.endFrame();
    try testing.expectEqual(focus_ring_color, rb.pixelAt(9, 20)); // ring present at the outset edge
    resetFocus();
}

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

test "Space activates the focused control; :focus-visible only on keyboard focus (#310)" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        activated: ?u32 = null,
        pub fn update(self: *@This(), m: Msg) Command {
            self.activated = @intFromEnum(m);
            return .redraw;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    const r: geometry.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const btn: layout_mod.Element = .{ .focusable = true, .on_click = 7 };
    const placements = [_]layout_mod.Placement{.{ .element = &btn, .rect = r }};
    var m: M = .{};

    // Tab → focus + ring visible; Space activates the focused control.
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .tab } }, &placements);
    try testing.expect(focusVisible());
    _ = dispatch(M, Msg, &m, .{ .text = .{ .codepoint = ' ' } }, &placements);
    try testing.expectEqual(@as(?u32, 7), m.activated);

    // Click-to-focus → focused, but the ring is hidden (:focus-visible off).
    resetFocus();
    _ = dispatch(M, Msg, &m, .{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 }, .buttons = .{ .primary = true } } }, &placements);
    try testing.expect(focusedIndex() != null);
    try testing.expect(!focusVisible());
    // Then Tab reveals the ring again.
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .tab } }, &placements);
    try testing.expect(focusVisible());
    resetFocus();
}

test "click hits a list row at Retina scale (2x) through the real buildTree path" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        selected: usize = 0,
        pub fn viewUi(self: *@This(), u: *ui_mod.Ui) !ui_mod.Widget {
            return u.column(.{ .width = 140, .height = 140, .overflow_y = .auto, .on_scroll = 7777 }, &.{
                try u.list(.{ .selected = self.selected }, &.{
                    .{ .label = "A", .on_click = 0 }, .{ .label = "B", .on_click = 1 }, .{ .label = "C", .on_click = 2 },
                }),
            });
        }
        pub fn update(self: *@This(), msg: Msg) Command {
            self.selected = @intFromEnum(msg);
            return .redraw;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    var rb = raster_mod.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    try rb.setFont(@embedFile("poppins")); // real glyph metrics so text scales with s
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m: M = .{};
    const root = try buildTree(M, &m, arena.allocator(), 2);
    var res = try layout_mod.layout(arena.allocator(), rb.interface(), root, .{ .width = 280, .height = 280 });
    defer res.deinit(arena.allocator());
    // Find row C's placement and click its center (physical/scaled coords).
    var target: ?geometry.Rect = null;
    for (res.placements) |pl| {
        if (pl.element.on_click) |oc| if (oc == 2) {
            target = pl.rect;
        };
    }
    try testing.expect(target != null);
    const c = target.?;
    _ = dispatch(M, Msg, &m, .{ .pointer_down = .{ .position = .{ .x = c.x + c.width / 2, .y = c.y + c.height / 2 }, .buttons = .{ .primary = true } } }, res.placements);
    try testing.expectEqual(@as(usize, 2), m.selected);
}

test "text selection: drag selects a range and ⌘C copies the substring (#318)" {
    resetTextSelection();
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        pub fn viewUi(_: *@This(), u: *ui_mod.Ui) !ui_mod.Widget {
            return u.column(.{ .width = 400 }, &.{u.text("hello world", .{ .selectable = true })});
        }
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    var rb = raster_mod.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    try rb.setFont(@embedFile("poppins"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m: M = .{};
    const root = try buildTree(M, &m, arena.allocator(), 1);
    var res = try layout_mod.layout(arena.allocator(), rb.interface(), root, .{ .width = 400, .height = 100 });
    defer res.deinit(arena.allocator());
    var r: ?geometry.Rect = null;
    for (res.placements) |pl| {
        if (pl.element.text_selectable) r = pl.rect;
    }
    try testing.expect(r != null);
    const t = r.?;
    const midy = t.y + t.height / 2;
    // Press at the left edge, drag past the right edge → select the whole string.
    _ = dispatch(M, Msg, &m, .{ .pointer_down = .{ .position = .{ .x = t.x + 1, .y = midy }, .buttons = .{ .primary = true } } }, res.placements);
    try testing.expect(g_textsel != null);
    _ = dispatch(M, Msg, &m, .{ .pointer_move = .{ .position = .{ .x = t.x + t.width + 50, .y = midy } } }, res.placements);
    _ = dispatch(M, Msg, &m, .{ .pointer_up = .{ .position = .{ .x = t.x + t.width + 50, .y = midy } } }, res.placements);
    // ⌘C, then the render pass fills the copy buffer.
    _ = dispatch(M, Msg, &m, .{ .text = .{ .codepoint = 'c', .mods = .{ .super = true } } }, res.placements);
    try testing.expect(g_copy_request);
    renderTextSelection(rb.interface(), res.placements);
    try testing.expect(g_copy_pending);
    try testing.expectEqualStrings("hello world", g_copy_buf[0..g_copy_len]);

    // A press off the selectable text clears the selection.
    _ = dispatch(M, Msg, &m, .{ .pointer_down = .{ .position = .{ .x = t.x + 1, .y = t.y + 80 }, .buttons = .{ .primary = true } } }, res.placements);
    try testing.expect(g_textsel == null);
    resetTextSelection();
}

test "roving tabindex: a group is one Tab stop; arrows move within it (#310/#16)" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        keys: usize = 0,
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(self: *@This(), ev: event_mod.Event) Command {
            if (ev == .key_down) self.keys += 1;
            return .none;
        }
    };
    const r: geometry.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    // A 3-row group (tab_group=1), then a standalone button (no group).
    const g0: layout_mod.Element = .{ .focusable = true, .tab_group = 1 };
    const g1: layout_mod.Element = .{ .focusable = true, .tab_group = 1 };
    const g2: layout_mod.Element = .{ .focusable = true, .tab_group = 1 };
    const btn: layout_mod.Element = .{ .focusable = true };
    const placements = [_]layout_mod.Placement{
        .{ .element = &g0, .rect = r }, .{ .element = &g1, .rect = r },
        .{ .element = &g2, .rect = r }, .{ .element = &btn, .rect = r },
    };
    var m: M = .{};
    const tab: event_mod.Event = .{ .key_down = .{ .key = .tab } };
    const down: event_mod.Event = .{ .key_down = .{ .key = .down } };
    const up: event_mod.Event = .{ .key_down = .{ .key = .up } };

    // Tab enters the group at its first row; arrows move within (wrap).
    _ = dispatch(M, Msg, &m, tab, &placements);
    try testing.expectEqual(@as(?usize, 0), focusedIndex());
    _ = dispatch(M, Msg, &m, down, &placements);
    try testing.expectEqual(@as(?usize, 1), focusedIndex());
    _ = dispatch(M, Msg, &m, down, &placements);
    _ = dispatch(M, Msg, &m, down, &placements); // 2 → wrap 0
    try testing.expectEqual(@as(?usize, 0), focusedIndex());
    _ = dispatch(M, Msg, &m, up, &placements); // 0 → wrap 2
    try testing.expectEqual(@as(?usize, 2), focusedIndex());

    // Tab leaves the whole group → the standalone button (one stop).
    _ = dispatch(M, Msg, &m, tab, &placements);
    try testing.expectEqual(@as(?usize, 3), focusedIndex());
    // Arrows on a standalone control pass through to the app (not consumed).
    _ = dispatch(M, Msg, &m, down, &placements);
    try testing.expectEqual(@as(?usize, 3), focusedIndex());
    try testing.expectEqual(@as(usize, 1), m.keys);
    // Tab wraps back to the group's first row; Shift+Tab returns to the button.
    _ = dispatch(M, Msg, &m, tab, &placements);
    try testing.expectEqual(@as(?usize, 0), focusedIndex());
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .tab, .mods = .{ .shift = true } } }, &placements);
    try testing.expectEqual(@as(?usize, 3), focusedIndex());
    resetFocus();
}

test "on_focus / on_blur fire as focus moves (#310)" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        log: [8]u32 = undefined,
        n: usize = 0,
        pub fn update(self: *@This(), m: Msg) Command {
            self.log[self.n] = @intFromEnum(m);
            self.n += 1;
            return .redraw;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    const r: geometry.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const a: layout_mod.Element = .{ .focusable = true, .on_focus = 1, .on_blur = 2 };
    const b: layout_mod.Element = .{ .focusable = true, .on_focus = 3, .on_blur = 4 };
    const placements = [_]layout_mod.Placement{ .{ .element = &a, .rect = r }, .{ .element = &b, .rect = r } };
    var m: M = .{};
    const tab: event_mod.Event = .{ .key_down = .{ .key = .tab } };
    _ = dispatch(M, Msg, &m, tab, &placements); // focus a → on_focus(1)
    _ = dispatch(M, Msg, &m, tab, &placements); // blur a (2), focus b (3)
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .escape } }, &placements); // blur b (4)
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, m.log[0..m.n]);
    resetFocus();
}

test "Esc clears keyboard focus (#310)" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    const btn: layout_mod.Element = .{ .focusable = true, .on_click = 1 };
    const placements = [_]layout_mod.Placement{.{ .element = &btn, .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 } }};
    var m: M = .{};
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .tab } }, &placements);
    try testing.expect(focusedIndex() != null);
    _ = dispatch(M, Msg, &m, .{ .key_down = .{ .key = .escape } }, &placements);
    try testing.expectEqual(@as(?usize, null), focusedIndex());
    try testing.expect(!focusVisible());
    resetFocus();
}

test "Tab moves focus in layout order, wraps; Enter activates; Shift+Tab reverses (#310)" {
    resetFocus();
    const Msg = enum(u32) { _ };
    const M = struct {
        activated: ?u32 = null,
        pub fn update(self: *@This(), m: Msg) Command {
            self.activated = @intFromEnum(m);
            return .redraw;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    const r: geometry.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const a: layout_mod.Element = .{ .focusable = true, .on_click = 10 };
    const mid: layout_mod.Element = .{}; // not focusable — skipped in Tab order
    const b: layout_mod.Element = .{ .focusable = true, .on_click = 20 };
    const placements = [_]layout_mod.Placement{
        .{ .element = &a, .rect = r },
        .{ .element = &mid, .rect = r },
        .{ .element = &b, .rect = r },
    };
    var m: M = .{};
    const key = struct {
        fn ev(k: event_mod.Key, shift: bool) event_mod.Event {
            return .{ .key_down = .{ .key = k, .mods = .{ .shift = shift } } };
        }
    };
    // Tab → first focusable (a); Enter activates its on_click.
    _ = dispatch(M, Msg, &m, key.ev(.tab, false), &placements);
    try testing.expectEqual(@as(?usize, 0), focusedIndex());
    _ = dispatch(M, Msg, &m, key.ev(.enter, false), &placements);
    try testing.expectEqual(@as(?u32, 10), m.activated);
    // Tab → next focusable (b, skipping the non-focusable middle); Enter activates.
    _ = dispatch(M, Msg, &m, key.ev(.tab, false), &placements);
    try testing.expectEqual(@as(?usize, 1), focusedIndex());
    _ = dispatch(M, Msg, &m, key.ev(.enter, false), &placements);
    try testing.expectEqual(@as(?u32, 20), m.activated);
    // Tab wraps back to the first; Shift+Tab reverses to the last.
    _ = dispatch(M, Msg, &m, key.ev(.tab, false), &placements);
    try testing.expectEqual(@as(?usize, 0), focusedIndex());
    _ = dispatch(M, Msg, &m, key.ev(.tab, true), &placements);
    try testing.expectEqual(@as(?usize, 1), focusedIndex());
    try testing.expect(focusedRect(&placements) != null);
    resetFocus();
}

test "built-in scroll: wheel moves the framework offset with direction + clamp (#313)" {
    g_scale = 1;
    setScrollOffset(2, 0, 0);
    var rb = raster_mod.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    const b = rb.interface();
    const Msg = enum(u32) { _ };
    const M = struct {
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    const child: layout_mod.Element = .{ .height = 300 };
    const box: layout_mod.Element = .{ .width = 50, .height = 100, .direction = .column, .overflow_y = .scroll, .on_scroll = 2, .children = &.{&child} };
    try b.beginFrame(.{ .width = 50, .height = 100 });
    var result = try layout_mod.layout(testing.allocator, b, &box, .{ .width = 50, .height = 100 });
    defer result.deinit(testing.allocator);
    layout_mod.render(b, result); // records the scrollbar → max = 200
    try b.endFrame();
    var m: M = .{};
    const over: geometry.Point = .{ .x = 25, .y = 50 };
    // Canonical convention (#309): dy>0 = toward later content. Platforms
    // normalize their raw wheel to this, so applyWheel simply adds.
    _ = dispatch(M, Msg, &m, .{ .scroll = .{ .position = over, .dy = 2, .unit = .line } }, result.placements);
    try testing.expectApproxEqAbs(@as(f32, 80), scrollOffset(2).y, 0.5); // 2 lines × 40
    _ = dispatch(M, Msg, &m, .{ .scroll = .{ .position = over, .dy = 10, .unit = .line } }, result.placements);
    try testing.expectApproxEqAbs(@as(f32, 200), scrollOffset(2).y, 0.5); // clamped to max
    _ = dispatch(M, Msg, &m, .{ .scroll = .{ .position = over, .dy = -100, .unit = .line } }, result.placements);
    try testing.expectEqual(@as(f32, 0), scrollOffset(2).y); // clamped to 0
    setScrollOffset(2, 0, 0);
}

test "scrollbar thumb drag scrolls the region (#312/#313)" {
    resetFocus();
    g_scale = 1;
    setScrollOffset(1, 0, 0);
    var rb = raster_mod.RasterBackend.init(testing.allocator);
    defer rb.deinit();
    const b = rb.interface();
    const Msg = enum(u32) { _ };
    const M = struct {
        pub fn update(_: *@This(), _: Msg) Command {
            return .none;
        }
        pub fn onEvent(_: *@This(), _: event_mod.Event) Command {
            return .none;
        }
    };
    // 50x100 scroll box over 300px of content → a vertical thumb is recorded.
    const child: layout_mod.Element = .{ .height = 300, .rect_style = .{ .background = style_mod.Color.rgb(1, 2, 3) } };
    const box: layout_mod.Element = .{ .width = 50, .height = 100, .direction = .column, .overflow_y = .scroll, .on_scroll = 1, .children = &.{&child} };
    try b.beginFrame(.{ .width = 50, .height = 100 });
    var result = try layout_mod.layout(testing.allocator, b, &box, .{ .width = 50, .height = 100 });
    defer result.deinit(testing.allocator);
    layout_mod.render(b, result);
    try b.endFrame();
    const bars = layout_mod.scrollbars();
    try testing.expect(bars.len >= 1);
    const thumb = bars[0].thumb;
    const cx = thumb.x + thumb.width / 2;
    const cy = thumb.y + thumb.height / 2;
    var m: M = .{};
    _ = dispatch(M, Msg, &m, .{ .pointer_down = .{ .position = .{ .x = cx, .y = cy }, .buttons = .{ .primary = true } } }, result.placements);
    try testing.expect(g_bar_drag != null); // grabbed the thumb
    _ = dispatch(M, Msg, &m, .{ .pointer_move = .{ .position = .{ .x = cx, .y = cy + 30 } } }, result.placements);
    try testing.expect(scrollOffset(1).y > 0); // dragging down increased the built-in offset
    _ = dispatch(M, Msg, &m, .{ .pointer_up = .{ .position = .{ .x = cx, .y = cy + 30 } } }, result.placements);
    try testing.expect(g_bar_drag == null); // released
    setScrollOffset(1, 0, 0);
    resetFocus();
}

test "scroll events route only to on_scroll regions (#309)" {
    const Msg = enum(u32) { _ };
    const M = struct {
        hits: usize = 0,
        pub fn update(self: *@This(), m: Msg) Command {
            _ = self;
            _ = m;
            return .none;
        }
        pub fn onEvent(self: *@This(), ev: event_mod.Event) Command {
            if (ev == .scroll) self.hits += 1;
            return .none;
        }
    };
    const plain: layout_mod.Element = .{};
    const target: layout_mod.Element = .{ .on_scroll = 7 };
    const placements = [_]layout_mod.Placement{
        .{ .element = &plain, .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .element = &target, .rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
    };
    var m: M = .{};
    // Over the target → forwarded to onEvent.
    _ = dispatch(M, Msg, &m, .{ .scroll = .{ .position = .{ .x = 5, .y = 5 }, .dy = 1 } }, &placements);
    try testing.expectEqual(@as(usize, 1), m.hits);
    // Outside the target (over a non-scroll region) → ignored.
    _ = dispatch(M, Msg, &m, .{ .scroll = .{ .position = .{ .x = 50, .y = 50 }, .dy = 1 } }, &placements);
    try testing.expectEqual(@as(usize, 1), m.hits);
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
