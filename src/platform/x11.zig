//! X11 windowing layer (#9): native Linux windows via Xlib — the
//! platform windowing API (like user32 on Windows, AppKit on macOS),
//! not a third-party abstraction (no GLFW/SDL). Works on X11 sessions
//! and on Wayland via XWayland. Wayland-native is a #9 follow-up.
//!
//! Mirrors the Win32/Cocoa shape: Window.create/destroy, non-blocking
//! pumpEvents emitting core events, blit (XPutImage), contentPixelSize.
//! DPI (Xft.dpi) is #27; v1 reports scale 1.

const std = @import("std");
const builtin = @import("builtin");
const core_event = @import("../event.zig");
const geometry = @import("../geometry.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("x11.zig is Linux-only; gate imports on builtin.os.tag");
}

// --- Xlib types (64-bit C ABI) ----------------------------------------------

const XID = c_ulong;
const Window_ = XID;
const Drawable = XID;
const Atom = c_ulong;
const Time = c_ulong;
const KeySym = c_ulong;
const Bool = c_int;
const Display = opaque {};
const Visual = opaque {};
const GC = opaque {};

const XImageFuncs = extern struct {
    create_image: ?*anyopaque = null,
    destroy_image: ?*const fn (*XImage) callconv(.c) c_int = null,
    get_pixel: ?*anyopaque = null,
    put_pixel: ?*anyopaque = null,
    sub_image: ?*anyopaque = null,
    add_pixel: ?*anyopaque = null,
};

const XImage = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: ?[*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    f: XImageFuncs,
};

// XEvent is a union of all event structs; every member starts with `type`.
// We declare the members we read and pad to the full union size (24 longs).
const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};
const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};
const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};
const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: Window_,
    window: Window_,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window_,
    override_redirect: Bool,
};
const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};
const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    pad: [24]c_long,
};

// --- Xlib functions ---------------------------------------------------------

extern "X11" fn XOpenDisplay(?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(*Display) c_int;
extern "X11" fn XDefaultScreen(*Display) c_int;
extern "X11" fn XRootWindow(*Display, c_int) Window_;
extern "X11" fn XDefaultVisual(*Display, c_int) ?*Visual;
extern "X11" fn XDefaultDepth(*Display, c_int) c_int;
extern "X11" fn XWhitePixel(*Display, c_int) c_ulong;
extern "X11" fn XCreateSimpleWindow(*Display, Window_, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) Window_;
extern "X11" fn XDestroyWindow(*Display, Window_) c_int;
extern "X11" fn XStoreName(*Display, Window_, [*:0]const u8) c_int;
extern "X11" fn XChangeProperty(*Display, Window_, Atom, Atom, c_int, c_int, [*]const u8, c_int) c_int;
extern "X11" fn XSelectInput(*Display, Window_, c_long) c_int;
extern "X11" fn XMapWindow(*Display, Window_) c_int;
extern "X11" fn XFlush(*Display) c_int;
extern "X11" fn XSetWindowBackground(*Display, Window_, c_ulong) c_int;
extern "X11" fn XClearWindow(*Display, Window_) c_int;
extern "X11" fn XPending(*Display) c_int;
extern "X11" fn XNextEvent(*Display, *XEvent) c_int;
extern "X11" fn XInternAtom(*Display, [*:0]const u8, Bool) Atom;
extern "X11" fn XSetWMProtocols(*Display, Window_, *Atom, c_int) c_int;
extern "X11" fn XLookupKeysym(*XKeyEvent, c_int) KeySym;
extern "X11" fn XLookupString(*XKeyEvent, [*]u8, c_int, ?*KeySym, ?*anyopaque) c_int;
extern "X11" fn XCreateGC(*Display, Drawable, c_ulong, ?*anyopaque) ?*GC;
extern "X11" fn XCreateImage(*Display, ?*Visual, c_uint, c_int, c_int, [*]u8, c_uint, c_uint, c_int, c_int) ?*XImage;
extern "X11" fn XPutImage(*Display, Drawable, *GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) c_int;

// --- GLX (optional GPU window; #11 GPU-present path) -------------------------
// When a GL window is requested we create the X11 window over a GLX-chosen
// visual and make a context current, so GlBackend can render straight to it.
// If any step fails the caller falls back to the raster (XCreateSimpleWindow
// + XPutImage) window. Mirrors the proven sequence in backends/gl.zig.
const Colormap = XID;
const GLXContext = ?*opaque {};

const XVisualInfo = extern struct {
    visual: ?*Visual,
    visualid: c_ulong,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

const XSetWindowAttributes = extern struct {
    background_pixmap: XID = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: XID = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: Bool = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: Bool = 0,
    colormap: Colormap = 0,
    cursor: XID = 0,
};

extern "X11" fn XCreateColormap(*Display, Window_, ?*Visual, c_int) Colormap;
extern "X11" fn XCreateWindow(*Display, Window_, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, ?*Visual, c_ulong, *XSetWindowAttributes) Window_;
extern "X11" fn XSync(*Display, Bool) c_int;
extern "X11" fn XFree(?*anyopaque) c_int;
extern "GL" fn glXChooseVisual(*Display, c_int, [*]c_int) ?*XVisualInfo;
extern "GL" fn glXCreateContext(*Display, *XVisualInfo, GLXContext, Bool) GLXContext;
extern "GL" fn glXDestroyContext(*Display, GLXContext) void;
extern "GL" fn glXMakeCurrent(*Display, XID, GLXContext) Bool;
extern "GL" fn glXSwapBuffers(*Display, XID) void;

const GLX_RGBA: c_int = 4;
const GLX_DOUBLEBUFFER: c_int = 5;
const GLX_RED_SIZE: c_int = 8;
const GLX_GREEN_SIZE: c_int = 9;
const GLX_BLUE_SIZE: c_int = 10;
const GLX_DEPTH_SIZE: c_int = 12;
const CWBackPixel: c_ulong = 1 << 1;
const CWBorderPixel: c_ulong = 1 << 3;
const CWBitGravity: c_ulong = 1 << 4;
const CWColormap: c_ulong = 1 << 13;
const CWEventMask: c_ulong = 1 << 11;
/// bit_gravity: keep existing content anchored top-left on resize (#182), so
/// growing the window doesn't re-expose/shift what's already painted.
const NorthWestGravity: c_int = 1;
const InputOutput: c_uint = 1;
const AllocNone: c_int = 0;

// Event masks / types / ZPixmap.
const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const StructureNotifyMask: c_long = 1 << 17;

const KeyPress = 2;
const ButtonPress = 4;
const ButtonRelease = 5;
const MotionNotify = 6;
const Expose = 12;
const ConfigureNotify = 22;
const ClientMessage = 33;
const ZPixmap = 2;

fn keysymToKey(ks: KeySym) ?core_event.Key {
    return switch (ks) {
        0xff52 => .up,
        0xff54 => .down,
        0xff51 => .left,
        0xff53 => .right,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff0d => .enter,
        0xff1b => .escape,
        0xff09 => .tab,
        0xff08 => .backspace,
        0xffff => .delete,
        else => null,
    };
}

pub const Event = core_event.Event;

pub const Window = struct {
    display: *Display,
    handle: Window_,
    gc: *GC,
    visual: ?*Visual,
    depth: c_uint,
    wm_delete: Atom,
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Event) = .empty,
    bgra: std.ArrayList(u8) = .empty,
    ximage: ?*XImage = null,
    img_w: usize = 0,
    img_h: usize = 0,
    width: u32,
    height: u32,
    /// Set when the window was created GL-capable and a context is current
    /// (the GPU-present path). null = raster (XPutImage) window.
    gl_ctx: GLXContext = null,
    gl_vi: ?*XVisualInfo = null,
    /// Render-one-frame callback (#182): invoked synchronously on
    /// ConfigureNotify so a resize repaints in the same turn instead of
    /// lagging to the next loop iteration (the exposed strip flashing).
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    redraw_ctx: ?*anyopaque = null,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        visible: bool = true,
        /// Try to create a GLX-capable window + current context. Falls back
        /// to a raster window if GLX is unavailable (old driver, no GLX).
        gl: bool = false,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const display = XOpenDisplay(null) orelse return error.BackendFailure;
        errdefer _ = XCloseDisplay(display);
        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        const white = XWhitePixel(display, screen);

        // Try a GL-capable window first when requested; on any failure fall
        // back to the simple (raster) window over the default visual.
        var gl_ctx: GLXContext = null;
        var gl_vi: ?*XVisualInfo = null;
        var gl_visual: ?*Visual = null;
        var gl_depth: c_uint = 0;
        var handle: Window_ = 0;
        if (opts.gl) {
            var attrs = [_]c_int{ GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_DEPTH_SIZE, 24, 0 };
            if (glXChooseVisual(display, screen, &attrs)) |vi| {
                const cmap = XCreateColormap(display, root, vi.visual, AllocNone);
                // CWBorderPixel is REQUIRED when the window's visual/depth
                // differs from the parent (the GLX visual vs the root): the
                // default border_pixmap is CopyFromParent, invalid across
                // depths → BadMatch, which Xlib's default handler turns into
                // a process exit ("window opens blank, then closes"). Xvfb/
                // llvmpipe is lax about it; real X servers are not.
                var swa: XSetWindowAttributes = .{
                    .border_pixel = 0,
                    .colormap = cmap,
                    .event_mask = ExposureMask | KeyPressMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask,
                    // Anchor existing content top-left on grow so the exposed
                    // strip is the only repaint, not a full re-expose (#182).
                    .bit_gravity = NorthWestGravity,
                };
                const gh = XCreateWindow(display, root, 0, 0, opts.width, opts.height, 0, vi.depth, InputOutput, vi.visual, CWBorderPixel | CWColormap | CWEventMask | CWBitGravity, &swa);
                const ctx = glXCreateContext(display, vi, null, 1);
                if (ctx != null and glXMakeCurrent(display, gh, ctx) != 0) {
                    handle = gh;
                    gl_ctx = ctx;
                    gl_vi = vi;
                    gl_visual = vi.visual;
                    gl_depth = @intCast(vi.depth);
                } else {
                    if (ctx != null) glXDestroyContext(display, ctx);
                    _ = XDestroyWindow(display, gh);
                    _ = XFree(vi);
                }
            }
        }
        if (handle == 0) handle = XCreateSimpleWindow(display, root, 0, 0, opts.width, opts.height, 0, white, white);
        _ = XStoreName(display, handle, opts.title.ptr); // legacy/fallback (Latin-1)
        // Modern UTF-8 title: _NET_WM_NAME = UTF8_STRING, so the WM shows
        // multibyte glyphs (e.g. the em-dash) correctly. PropModeReplace=0.
        const net_wm_name = XInternAtom(display, "_NET_WM_NAME", 0);
        const utf8_string = XInternAtom(display, "UTF8_STRING", 0);
        _ = XChangeProperty(display, handle, net_wm_name, utf8_string, 8, 0, opts.title.ptr, @intCast(opts.title.len));
        _ = XSelectInput(display, handle, ExposureMask | KeyPressMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask);

        var wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", 0);
        _ = XSetWMProtocols(display, handle, &wm_delete, 1);

        const gc = XCreateGC(display, handle, 0, null) orelse return error.BackendFailure;
        if (opts.visible) _ = XMapWindow(display, handle);
        _ = XFlush(display);

        const self = try gpa.create(Window);
        self.* = .{
            .display = display,
            .handle = handle,
            .gc = gc,
            .visual = if (gl_visual) |v| v else XDefaultVisual(display, screen),
            .depth = if (gl_depth != 0) gl_depth else @intCast(XDefaultDepth(display, screen)),
            .wm_delete = wm_delete,
            .gpa = gpa,
            .width = opts.width,
            .height = opts.height,
            .gl_ctx = gl_ctx,
            .gl_vi = gl_vi,
        };
        return self;
    }

    /// Present the GL default framebuffer (GPU-present path). No-op if this
    /// is a raster window.
    pub fn glSwap(self: *Window) void {
        if (self.gl_ctx != null) glXSwapBuffers(self.display, self.handle);
    }

    /// No-op: GLX tracks the X drawable's size automatically on resize.
    /// (macOS needs `[NSOpenGLContext update]`; this keeps runWindowGl
    /// platform-agnostic.)
    pub fn glUpdate(self: *Window) void {
        _ = self;
    }

    /// Register the render-one-frame callback. Unlike the original no-op, X11
    /// now repaints synchronously on ConfigureNotify (#182): the resize repaint
    /// happens in the same pumpEvents call, not the next loop iteration, so the
    /// newly-exposed strip doesn't flash before it's painted.
    pub fn setRedraw(self: *Window, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = f;
    }

    /// Set the window's background to `(r,g,b)` (#182). The server fills any
    /// region exposed by a resize-grow with this — the theme background —
    /// instead of black, until the client repaints. Assumes a TrueColor visual
    /// (the GLX RGBA visual is one): pixel = R<<16 | G<<8 | B.
    pub fn setBackground(self: *Window, r: u8, g: u8, b: u8) void {
        const pixel: c_ulong = (@as(c_ulong, r) << 16) | (@as(c_ulong, g) << 8) | @as(c_ulong, b);
        _ = XSetWindowBackground(self.display, self.handle, pixel);
        _ = XClearWindow(self.display, self.handle);
        _ = XFlush(self.display);
    }

    pub fn destroy(self: *Window) void {
        if (self.gl_ctx) |ctx| {
            _ = glXMakeCurrent(self.display, 0, null);
            glXDestroyContext(self.display, ctx);
            if (self.gl_vi) |vi| _ = XFree(vi);
        }
        if (self.ximage) |img| {
            img.data = null; // our buffer; let Xlib free only the struct
            if (img.f.destroy_image) |di| _ = di(img);
        }
        self.bgra.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        _ = XDestroyWindow(self.display, self.handle);
        _ = XCloseDisplay(self.display);
        self.gpa.destroy(self);
    }

    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        while (XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = XNextEvent(self.display, &ev);
            switch (ev.type) {
                ClientMessage => {
                    if (@as(Atom, @bitCast(ev.xclient.data.l[0])) == self.wm_delete) {
                        self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
                    }
                },
                ConfigureNotify => {
                    const w: u32 = @intCast(ev.xconfigure.width);
                    const h: u32 = @intCast(ev.xconfigure.height);
                    if (w != self.width or h != self.height) {
                        self.width = w;
                        self.height = h;
                        self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } } }) catch {};
                        // Repaint immediately at the new size (#182) so the
                        // exposed strip is painted this turn, not next iteration.
                        if (self.redraw_fn) |f| f(self.redraw_ctx);
                    }
                },
                Expose => self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) } } }) catch {},
                MotionNotify => self.queue.append(self.gpa, .{ .pointer_move = .{ .position = .{ .x = @floatFromInt(ev.xmotion.x), .y = @floatFromInt(ev.xmotion.y) } } }) catch {},
                ButtonPress, ButtonRelease => {
                    const b = ev.xbutton.button;
                    if (b == 4 or b == 5) {
                        if (ev.type == ButtonPress) {
                            self.queue.append(self.gpa, .{ .key_down = .{ .key = if (b == 4) .up else .down } }) catch {};
                        }
                    } else {
                        const pe: core_event.PointerEvent = .{
                            .position = .{ .x = @floatFromInt(ev.xbutton.x), .y = @floatFromInt(ev.xbutton.y) },
                            .buttons = .{ .primary = b == 1, .middle = b == 2, .secondary = b == 3 },
                        };
                        self.queue.append(self.gpa, if (ev.type == ButtonPress) .{ .pointer_down = pe } else .{ .pointer_up = pe }) catch {};
                    }
                },
                KeyPress => {
                    const ks = XLookupKeysym(&ev.xkey, 0);
                    if (keysymToKey(ks)) |k| {
                        self.queue.append(self.gpa, .{ .key_down = .{ .key = k } }) catch {};
                    } else {
                        var buf: [8]u8 = undefined;
                        const n = XLookupString(&ev.xkey, &buf, buf.len, null, null);
                        if (n > 0 and buf[0] >= 0x20 and buf[0] != 0x7f) {
                            self.queue.append(self.gpa, .{ .text = .{ .codepoint = buf[0] } }) catch {};
                        }
                    }
                },
                else => {},
            }
        }
        return self.queue.items;
    }
};

/// Module-level to match win32/macos (app.zig calls platform.contentPixelSize).
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    return .{ .width = window.width, .height = window.height, .scale = 1.0 };
}

/// Display refresh rate (Hz) for frame pacing (#170). Returning 0 makes the
/// caller fall back to 60. The real query — XRRConfigCurrentRate (Xrandr) —
/// NEEDS ON-DEVICE QA on the Ubuntu VM, so this is a safe 60 stub for now.
pub fn refreshHz(window: *Window) f32 {
    _ = window;
    return 0;
}

pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize) void {
    std.debug.assert(rgba.len == width * height * 4);
    window.bgra.resize(window.gpa, rgba.len) catch return;
    const dst = window.bgra.items;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        dst[i + 0] = rgba[i + 2];
        dst[i + 1] = rgba[i + 1];
        dst[i + 2] = rgba[i + 0];
        dst[i + 3] = 255;
    }
    if (window.ximage == null or window.img_w != width or window.img_h != height) {
        if (window.ximage) |old| {
            old.data = null;
            if (old.f.destroy_image) |di| _ = di(old);
        }
        window.ximage = XCreateImage(window.display, window.visual, window.depth, ZPixmap, 0, dst.ptr, @intCast(width), @intCast(height), 32, @intCast(width * 4));
        window.img_w = width;
        window.img_h = height;
    } else {
        window.ximage.?.data = dst.ptr; // buffer may have moved on resize-to-same
    }
    if (window.ximage) |img| {
        _ = XPutImage(window.display, window.handle, window.gc, img, 0, 0, 0, 0, @intCast(width), @intCast(height));
        _ = XFlush(window.display);
    }
}
