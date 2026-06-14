//! macOS windowing layer (#9): NSApplication/NSWindow driven directly
//! through the Objective-C runtime — no Xcode project, no frameworks
//! beyond AppKit itself, no third-party dependency (2MB budget, #14).
//!
//! Mirrors the Win32 layer's shape: Window.create/destroy + a
//! non-blocking pumpEvents translating a first event subset. Ships as a
//! .app bundle (assembled by zig build per Daniel's requirement);
//! activation policy is set programmatically so a bare dev binary still
//! fronts a window. DPI, full input translation, and integrated title
//! bars are #9 follow-ups.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) @compileError("macos.zig is macOS-only; gate imports on builtin.os.tag");
}

// --- objc runtime ----------------------------------------------------------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;

extern "objc" fn objc_getClass([*:0]const u8) Class;
extern "objc" fn sel_registerName([*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_allocateClassPair(Class, [*:0]const u8, usize) Class;
extern "objc" fn objc_registerClassPair(Class) void;
extern "objc" fn class_addMethod(Class, SEL, *const anyopaque, [*:0]const u8) bool;

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

fn msg(comptime Ret: type, comptime Args: type, target: anytype, selector: SEL, args: Args) Ret {
    const Fn = switch (@typeInfo(Args).@"struct".fields.len) {
        0 => *const fn (@TypeOf(target), SEL) callconv(.c) Ret,
        1 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type) callconv(.c) Ret,
        2 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type, @typeInfo(Args).@"struct".fields[1].type) callconv(.c) Ret,
        4 => *const fn (
            @TypeOf(target),
            SEL,
            @typeInfo(Args).@"struct".fields[0].type,
            @typeInfo(Args).@"struct".fields[1].type,
            @typeInfo(Args).@"struct".fields[2].type,
            @typeInfo(Args).@"struct".fields[3].type,
        ) callconv(.c) Ret,
        else => @compileError("unsupported arg count"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return switch (@typeInfo(Args).@"struct".fields.len) {
        0 => f(target, selector),
        1 => f(target, selector, @field(args, "0")),
        2 => f(target, selector, @field(args, "0"), @field(args, "1")),
        4 => f(target, selector, @field(args, "0"), @field(args, "1"), @field(args, "2"), @field(args, "3")),
        else => unreachable,
    };
}

fn sel(comptime name: [:0]const u8) SEL {
    // sel_registerName is cheap and idempotent; fine per call for v1.
    return sel_registerName(name.ptr);
}

fn cls(comptime name: [:0]const u8) Class {
    return objc_getClass(name.ptr);
}

fn nsString(text: [:0]const u8) id {
    return msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{text.ptr});
}

// --- events ----------------------------------------------------------------

const core_event = @import("../event.zig");
/// Native windows emit the same core events as the terminal session, so
/// one app loop drives every surface (#5).
pub const Event = core_event.Event;

const NSPoint = extern struct { x: f64, y: f64 };

const NSEventType = struct {
    const left_down: u64 = 1;
    const left_up: u64 = 2;
    const right_down: u64 = 3;
    const right_up: u64 = 4;
    const mouse_moved: u64 = 5;
    const left_dragged: u64 = 6;
    const right_dragged: u64 = 7;
    const key_down: u64 = 10;
    const key_up: u64 = 11;
    const scroll_wheel: u64 = 22;
};

/// NSEvent.modifierFlags bitmask → our Modifiers (#127). The device-independent
/// flags live in the high bits: shift 1<<17, ctrl 1<<18, alt 1<<19, cmd 1<<20.
fn modsFromFlags(flags: u64) core_event.Modifiers {
    return .{
        .shift = (flags & (1 << 17)) != 0,
        .ctrl = (flags & (1 << 18)) != 0,
        .alt = (flags & (1 << 19)) != 0,
        .super = (flags & (1 << 20)) != 0,
    };
}

fn keyCodeToKey(kc: u16) ?core_event.Key {
    return switch (kc) {
        126 => .up,
        125 => .down,
        123 => .left,
        124 => .right,
        115 => .home,
        119 => .end,
        116 => .page_up,
        121 => .page_down,
        36 => .enter,
        53 => .escape,
        48 => .tab,
        51 => .backspace,
        117 => .delete,
        else => null,
    };
}

// --- live-resize delegate ---------------------------------------------------
// AppKit runs a modal tracking loop while the user drags the resize edge, so
// our pumpEvents-driven loop is parked and the GL surface stretches the stale
// frame. A tiny NSWindowDelegate whose windowDidResize: fires *inside* that
// loop gives us the hook to redraw live. Single-window (the demo) for now.

var live_resize_window: ?*Window = null;
var delegate_instance: id = null;

fn resizeDelegate() id {
    if (delegate_instance) |d| return d;
    const class = objc_allocateClassPair(cls("NSObject"), "ZooeeWindowDelegate", 0);
    _ = class_addMethod(class, sel("windowDidResize:"), @ptrCast(&onWindowDidResize), "v@:@");
    // windowDidEndLiveResize: guarantees one final redraw at the settled size
    // even if the last windowDidResize: raced the drag's end.
    _ = class_addMethod(class, sel("windowDidEndLiveResize:"), @ptrCast(&onWindowDidResize), "v@:@");
    objc_registerClassPair(class);
    const inst = msg(id, struct {}, msg(id, struct {}, class, sel("alloc"), .{}), sel("init"), .{});
    delegate_instance = inst;
    return inst;
}

/// IMP for `windowDidResize:` — redraw the live window during the modal drag.
fn onWindowDidResize(_: id, _: SEL, _: id) callconv(.c) void {
    if (live_resize_window) |w| if (w.redraw_fn) |f| f(w.redraw_ctx);
}

// --- window ----------------------------------------------------------------

const NSWindowStyleMask = struct {
    const titled: u64 = 1 << 0;
    const closable: u64 = 1 << 1;
    const miniaturizable: u64 = 1 << 2;
    const resizable: u64 = 1 << 3;
};

pub const Window = struct {
    ns_window: id,
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Event) = .empty,
    last_size: NSRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Close = "was visible, now isn't" — visibility lags app launch, so
    /// a not-yet-visible window must not read as closed.
    was_visible: bool = false,
    /// NSOpenGLContext when the window is GPU-backed (#11 present path);
    /// null = CPU raster + CoreGraphics blit. Named gl_ctx to match the
    /// x11 window so runWindow's GL branch is platform-agnostic.
    gl_ctx: id = null,
    /// Render-one-frame callback (set by runWindow). AppKit's modal resize
    /// loop parks our event loop mid-drag, so without this the surface just
    /// stretches the last frame until release. The `windowDidResize:`
    /// delegate calls this to redraw live. See [[fix-live-resize]].
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        /// Try to create an NSOpenGLContext on the window (GPU-present).
        /// Falls back to raster + CoreGraphics if context creation fails.
        gl: bool = false,
    };

    /// Register the redraw callback and mark this as the window whose
    /// `windowDidResize:` should drive it. Single-window today (the demo);
    /// multi-window would store the Window* on the delegate via an ivar.
    pub fn setRedraw(self: *Window, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = f;
        live_resize_window = self;
    }

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        // NSApplicationActivationPolicyRegular = 0: Dock icon + key window
        // even for a bare binary (the .app bundle makes it look right).
        _ = msg(bool, struct { i64 }, app, sel("setActivationPolicy:"), .{0});
        // Required when launched via LaunchServices (.app double-click /
        // `open`): without it the window never becomes visible.
        _ = msg(void, struct {}, app, sel("finishLaunching"), .{});

        const window_alloc = msg(id, struct {}, cls("NSWindow"), sel("alloc"), .{});
        const style = NSWindowStyleMask.titled | NSWindowStyleMask.closable |
            NSWindowStyleMask.miniaturizable | NSWindowStyleMask.resizable;
        const frame: NSRect = .{ .x = 200, .y = 200, .w = @floatFromInt(opts.width), .h = @floatFromInt(opts.height) };
        const window = msg(id, struct { NSRect, u64, u64, bool }, window_alloc, sel("initWithContentRect:styleMask:backing:defer:"), .{ frame, style, 2, false });
        if (window == null) return error.BackendFailure;

        _ = msg(void, struct { id }, window, sel("setTitle:"), .{nsString(opts.title)});
        _ = msg(void, struct { bool }, window, sel("setReleasedWhenClosed:"), .{false});
        _ = msg(void, struct { bool }, window, sel("setAcceptsMouseMovedEvents:"), .{true});
        // Don't let AppKit cache-and-stretch the old frame during a live
        // resize drag — rely on our windowDidResize: redraw instead, so the
        // content snaps to each size rather than morphing toward it.
        _ = msg(void, struct { bool }, window, sel("setPreservesContentDuringLiveResize:"), .{false});
        _ = msg(void, struct { id }, window, sel("makeKeyAndOrderFront:"), .{null});
        _ = msg(void, struct { bool }, app, sel("activateIgnoringOtherApps:"), .{true});

        // A minimal NSWindowDelegate so `windowDidResize:` fires during
        // AppKit's modal resize tracking loop — the one chance to redraw
        // while the user is dragging (else the GL surface stretches).
        _ = msg(void, struct { id }, window, sel("setDelegate:"), .{resizeDelegate()});

        // Optional GPU context on the contentView (#11). Legacy 2.1 profile
        // (no NSOpenGLPFAOpenGLProfile attr) → GLSL 120, matching the shaders.
        var gl_ctx: id = null;
        if (opts.gl) gl_ctx = createGlContext(window);

        const self = try gpa.create(Window);
        self.* = .{ .ns_window = window, .gpa = gpa, .last_size = frame, .gl_ctx = gl_ctx };
        return self;
    }

    pub fn destroy(self: *Window) void {
        if (self.gl_ctx != null) {
            _ = msg(void, struct {}, self.gl_ctx, sel("clearDrawable"), .{});
        }
        _ = msg(void, struct {}, self.ns_window, sel("close"), .{});
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The window's content NSView (id) — where the Metal layer (#101) or GL
    /// context attaches.
    pub fn contentView(self: *Window) ?*anyopaque {
        return msg(id, struct {}, self.ns_window, sel("contentView"), .{});
    }

    /// Present the GL back buffer (GPU-present path). No-op for raster windows.
    pub fn glSwap(self: *Window) void {
        if (self.gl_ctx != null) _ = msg(void, struct {}, self.gl_ctx, sel("flushBuffer"), .{});
    }

    /// Resync the NSOpenGLContext with its view's current size. An
    /// NSOpenGLContext caches its drawable dimensions; without `-update`
    /// after the view resizes, the back buffer stays the old size and the
    /// frame is stretched (and on fullscreen the content lands off-screen).
    /// Cheap and idempotent — call once per frame before rendering. No-op
    /// for raster windows. (GLX tracks the X drawable, so x11 needs none.)
    pub fn glUpdate(self: *Window) void {
        if (self.gl_ctx != null) _ = msg(void, struct {}, self.gl_ctx, sel("update"), .{});
    }

    /// Drain pending AppKit events; non-blocking (#5 drivable loop).
    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        const distant_past = msg(id, struct {}, cls("NSDate"), sel("distantPast"), .{});
        const mode = nsString("kCFRunLoopDefaultMode");

        const view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});
        const bounds = msg(NSRect, struct {}, view, sel("bounds"), .{});
        const scale = msg(f64, struct {}, self.ns_window, sel("backingScaleFactor"), .{});

        while (true) {
            const ev = msg(id, struct { u64, id, id, bool }, app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{ std.math.maxInt(u64), distant_past, mode, true });
            if (ev == null) break;
            const et = msg(u64, struct {}, ev, sel("type"), .{});

            switch (et) {
                NSEventType.left_down, NSEventType.left_up, NSEventType.right_down, NSEventType.right_up, NSEventType.mouse_moved, NSEventType.left_dragged, NSEventType.right_dragged => {
                    const loc = msg(NSPoint, struct {}, ev, sel("locationInWindow"), .{});
                    // Window coords (y-up, bottom-left) → content-view →
                    // top-left pixels matching the rendered framebuffer.
                    const cv = msg(NSPoint, struct { NSPoint, id }, view, sel("convertPoint:fromView:"), .{ loc, null });
                    const flags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    const is_down = et == NSEventType.left_down or et == NSEventType.right_down;
                    const cc: u8 = if (is_down) @intCast(@max(1, msg(i64, struct {}, ev, sel("clickCount"), .{}))) else 1;
                    const pos: core_event.PointerEvent = .{ .position = .{
                        .x = @floatCast(cv.x * scale),
                        .y = @floatCast((bounds.h - cv.y) * scale),
                    }, .buttons = .{
                        .primary = et == NSEventType.left_down or et == NSEventType.left_dragged,
                        .secondary = et == NSEventType.right_down or et == NSEventType.right_dragged,
                    }, .mods = modsFromFlags(flags), .click_count = cc };
                    const core_ev: Event = switch (et) {
                        NSEventType.left_down, NSEventType.right_down => .{ .pointer_down = pos },
                        NSEventType.left_up, NSEventType.right_up => .{ .pointer_up = pos },
                        else => .{ .pointer_move = pos },
                    };
                    self.queue.append(self.gpa, core_ev) catch {};
                },
                NSEventType.key_down => {
                    const kc = msg(u16, struct {}, ev, sel("keyCode"), .{});
                    if (keyCodeToKey(kc)) |k| {
                        const kflags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                        self.queue.append(self.gpa, .{ .key_down = .{ .key = k, .mods = modsFromFlags(kflags) } }) catch {};
                    } else {
                        const chars = msg(id, struct {}, ev, sel("characters"), .{});
                        if (chars != null) {
                            const utf8 = msg([*:0]const u8, struct {}, chars, sel("UTF8String"), .{});
                            var it = std.unicode.Utf8View.initUnchecked(std.mem.span(utf8)).iterator();
                            while (it.nextCodepoint()) |cp| {
                                if (cp >= 0x20 and cp < 0xF700) {
                                    self.queue.append(self.gpa, .{ .text = .{ .codepoint = cp } }) catch {};
                                }
                            }
                        }
                    }
                    continue; // don't sendEvent keyDown — avoids the no-responder beep
                },
                NSEventType.scroll_wheel => {
                    // scrollingDeltaX/Y are pixel-precise on trackpads and
                    // high-res wheels; hasPreciseScrollingDeltas distinguishes
                    // them from coarse mouse notches. Positive AppKit deltaY is
                    // a downward finger-push → content scrolls up, matching our
                    // ScrollEvent dy convention.
                    const loc = msg(NSPoint, struct {}, ev, sel("locationInWindow"), .{});
                    const cv = msg(NSPoint, struct { NSPoint, id }, view, sel("convertPoint:fromView:"), .{ loc, null });
                    const precise = msg(bool, struct {}, ev, sel("hasPreciseScrollingDeltas"), .{});
                    const dx = msg(f64, struct {}, ev, sel("scrollingDeltaX"), .{});
                    const dy = msg(f64, struct {}, ev, sel("scrollingDeltaY"), .{});
                    const ph = msg(u64, struct {}, ev, sel("momentumPhase"), .{});
                    const sflags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    const phase: core_event.ScrollPhase = if (ph != 0) .momentum else .continue_;
                    self.queue.append(self.gpa, .{ .scroll = .{
                        .position = .{ .x = @floatCast(cv.x * scale), .y = @floatCast((bounds.h - cv.y) * scale) },
                        .dx = @floatCast(dx),
                        .dy = @floatCast(dy),
                        .unit = if (precise) .pixel else .line,
                        .phase = phase,
                        .mods = modsFromFlags(sflags),
                    } }) catch {};
                },
                NSEventType.key_up => {
                    const kc = msg(u16, struct {}, ev, sel("keyCode"), .{});
                    const flags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    if (keyCodeToKey(kc)) |k| {
                        self.queue.append(self.gpa, .{ .key_up = .{ .key = k, .mods = modsFromFlags(flags) } }) catch {};
                    }
                    continue;
                },
                else => {},
            }
            _ = msg(void, struct { id }, app, sel("sendEvent:"), .{ev});
        }

        // Close: the red button orders the window out.
        const visible = msg(bool, struct {}, self.ns_window, sel("isVisible"), .{});
        if (visible) {
            self.was_visible = true;
        } else if (self.was_visible) {
            self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
        }
        // Resize: poll the content frame.
        const content = msg(NSRect, struct {}, self.ns_window, sel("contentLayoutRect"), .{});
        if (content.w != self.last_size.w or content.h != self.last_size.h) {
            self.last_size = content;
            self.queue.append(self.gpa, .{ .resized = .{ .size = .{
                .width = @floatCast(@max(0, content.w)),
                .height = @floatCast(@max(0, content.h)),
            } } }) catch {};
        }
        return self.queue.items;
    }
};

// --- GL context (NSOpenGL, #11 GPU-present) ---------------------------------
// NSOpenGLPixelFormatAttribute tokens. No NSOpenGLPFAOpenGLProfile (=99) is
// requested, so the context is legacy 2.1 → GLSL 120 + APPLE VAOs + EXT FBOs,
// matching backends/gl.zig's macOS path. The attr list is u32, 0-terminated.
const NSOpenGLPFADoubleBuffer: u32 = 5;
const NSOpenGLPFAColorSize: u32 = 8;
const NSOpenGLPFAAlphaSize: u32 = 11;
const NSOpenGLPFAAccelerated: u32 = 73;

/// Create an NSOpenGLContext bound to the window's contentView and make it
/// current. Returns null on any failure (caller falls back to raster).
fn createGlContext(window: id) id {
    const attrs = [_]u32{ NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0 };
    const pf_alloc = msg(id, struct {}, cls("NSOpenGLPixelFormat"), sel("alloc"), .{});
    const pf = msg(id, struct { [*]const u32 }, pf_alloc, sel("initWithAttributes:"), .{&attrs});
    if (pf == null) return null;
    const ctx_alloc = msg(id, struct {}, cls("NSOpenGLContext"), sel("alloc"), .{});
    const ctx = msg(id, struct { id, id }, ctx_alloc, sel("initWithFormat:shareContext:"), .{ pf, null });
    if (ctx == null) return null;
    const view = msg(id, struct {}, window, sel("contentView"), .{});
    // Full-resolution backing so the GL surface matches contentPixelSize on
    // Retina (otherwise the drawable is point-sized and the viewport is off).
    _ = msg(void, struct { bool }, view, sel("setWantsBestResolutionOpenGLSurface:"), .{true});
    _ = msg(void, struct { id }, ctx, sel("setView:"), .{view});
    _ = msg(void, struct {}, ctx, sel("makeCurrentContext"), .{});
    // Swap interval 0: don't block flushBuffer on vsync. During a live resize
    // AppKit drives windowDidResize: faster than vblank; waiting on the swap
    // adds a frame of latency, so the surface lags the window edge. The idle
    // loop already throttles itself with a 16ms sleep, so unsynced presents
    // cost nothing there. NSOpenGLContextParameterSwapInterval = 222.
    const swap_interval: i32 = 0;
    _ = msg(void, struct { *const i32, u64 }, ctx, sel("setValues:forParameter:"), .{ &swap_interval, 222 });
    return ctx;
}

// --- raster blit (CoreGraphics) ---------------------------------------------
// Presents a CPU-rendered RGBA framebuffer in the window: the GUI path
// until GPU backends land (#11/#12) — same approach for first pixels.

const CGColorSpace = ?*anyopaque;
const CGDataProvider = ?*anyopaque;
const CGImage = ?*anyopaque;

extern "c" fn CGColorSpaceCreateDeviceRGB() CGColorSpace;
extern "c" fn CGColorSpaceRelease(CGColorSpace) void;
extern "c" fn CGDataProviderCreateWithData(?*anyopaque, ?*const anyopaque, usize, ?*const anyopaque) CGDataProvider;
extern "c" fn CGDataProviderRelease(CGDataProvider) void;
extern "c" fn CGImageCreate(usize, usize, usize, usize, usize, CGColorSpace, u32, CGDataProvider, ?*const anyopaque, bool, i32) CGImage;
extern "c" fn CGImageRelease(CGImage) void;

const kCGImageAlphaNoneSkipLast: u32 = 5; // RGBX, our raster layout

/// Present an RGBA8 framebuffer (row-major, top-down) in the window.
/// The buffer must stay valid for the duration of the call (the image
/// copies via the data provider before returning from setContents).
pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize) void {
    std.debug.assert(rgba.len == width * height * 4);
    const space = CGColorSpaceCreateDeviceRGB();
    defer CGColorSpaceRelease(space);
    const provider = CGDataProviderCreateWithData(null, rgba.ptr, rgba.len, null);
    defer CGDataProviderRelease(provider);
    const image = CGImageCreate(width, height, 8, 32, width * 4, space, kCGImageAlphaNoneSkipLast, provider, null, false, 0);
    defer CGImageRelease(image);

    const view = msg(id, struct {}, window.ns_window, sel("contentView"), .{});
    _ = msg(void, struct { bool }, view, sel("setWantsLayer:"), .{true});
    const layer = msg(id, struct {}, view, sel("layer"), .{});
    const scale = msg(f64, struct {}, window.ns_window, sel("backingScaleFactor"), .{});
    _ = msg(void, struct { f64 }, layer, sel("setContentsScale:"), .{scale});
    _ = msg(void, struct { id }, layer, sel("setContents:"), .{image});
}

/// Content size in pixels (points × backing scale) for rendering.
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    const content = msg(NSRect, struct {}, window.ns_window, sel("contentLayoutRect"), .{});
    const scale = msg(f64, struct {}, window.ns_window, sel("backingScaleFactor"), .{});
    return .{
        .width = @intFromFloat(@max(1, content.w * scale)),
        .height = @intFromFloat(@max(1, content.h * scale)),
        .scale = scale,
    };
}

test "objc runtime reachable: NSString round-trip" {
    const s = nsString("zooee");
    try std.testing.expect(s != null);
    const len = msg(u64, struct {}, s, sel("length"), .{});
    try std.testing.expectEqual(@as(u64, 5), len);
}
