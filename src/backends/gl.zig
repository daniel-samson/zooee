//! OpenGL backend (#11), slice 1: GLX context bring-up on Linux/X11.
//!
//! The riskiest part of a GPU backend is context creation + presentation
//! plumbing, so this slice proves exactly that in isolation: choose a
//! GL visual, create an X11 window for it, make a GLX context current,
//! clear to a color, swap buffers, and read pixels back. No shaders yet
//! — `glClear`/`glClearColor`/`glReadPixels` are core GL 1.x, directly
//! linkable. Slice 2 adds the proc loader + shaders + a textured-quad
//! presenter; later slices add native primitives.
//!
//! GPU-primary per #11; the raster + OS-blit path remains the fallback
//! when context creation fails. macOS (CGL) and the Window-backed
//! `Backend` integration are follow-ups.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) @compileError("gl.zig slice 1 is Linux/GLX-only");
}

// --- minimal X11 + GLX surface ----------------------------------------------

const XID = c_ulong;
const Window_ = XID;
const Colormap = XID;
const Display = opaque {};
const Bool = c_int;

const XVisualInfo = extern struct {
    visual: ?*anyopaque,
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

const GLXContext = ?*opaque {};
const GLXDrawable = XID;

extern "X11" fn XOpenDisplay(?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(*Display) c_int;
extern "X11" fn XDefaultScreen(*Display) c_int;
extern "X11" fn XRootWindow(*Display, c_int) Window_;
extern "X11" fn XCreateColormap(*Display, Window_, ?*anyopaque, c_int) Colormap;
extern "X11" fn XCreateWindow(*Display, Window_, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, ?*anyopaque, c_ulong, *XSetWindowAttributes) Window_;
extern "X11" fn XStoreName(*Display, Window_, [*:0]const u8) c_int;
extern "X11" fn XMapWindow(*Display, Window_) c_int;
extern "X11" fn XDestroyWindow(*Display, Window_) c_int;
extern "X11" fn XSync(*Display, Bool) c_int;
extern "X11" fn XFree(?*anyopaque) c_int;

extern "GL" fn glXChooseVisual(*Display, c_int, [*]c_int) ?*XVisualInfo;
extern "GL" fn glXCreateContext(*Display, *XVisualInfo, GLXContext, Bool) GLXContext;
extern "GL" fn glXDestroyContext(*Display, GLXContext) void;
extern "GL" fn glXMakeCurrent(*Display, GLXDrawable, GLXContext) Bool;
extern "GL" fn glXSwapBuffers(*Display, GLXDrawable) void;

// Core GL 1.x — directly linkable (no proc loading needed for these).
const GL_COLOR_BUFFER_BIT: c_uint = 0x00004000;
const GL_RGBA: c_uint = 0x1908;
const GL_UNSIGNED_BYTE: c_uint = 0x1401;
extern "GL" fn glClearColor(f32, f32, f32, f32) void;
extern "GL" fn glClear(c_uint) void;
extern "GL" fn glViewport(c_int, c_int, c_uint, c_uint) void;
extern "GL" fn glFinish() void;
extern "GL" fn glReadPixels(c_int, c_int, c_uint, c_uint, c_uint, c_uint, [*]u8) void;

// GLX visual attribute tokens.
const GLX_RGBA: c_int = 4;
const GLX_DOUBLEBUFFER: c_int = 5;
const GLX_RED_SIZE: c_int = 8;
const GLX_GREEN_SIZE: c_int = 9;
const GLX_BLUE_SIZE: c_int = 10;
const GLX_DEPTH_SIZE: c_int = 12;
const CWColormap: c_ulong = 1 << 13;
const CWEventMask: c_ulong = 1 << 11;
const InputOutput: c_uint = 1;
const AllocNone: c_int = 0;
const ExposureMask: c_long = 1 << 15;

pub const Error = error{ NoDisplay, NoVisual, NoContext };

/// A GL window + current context. Slice 1: enough to clear and present.
pub const GlWindow = struct {
    display: *Display,
    window: Window_,
    ctx: GLXContext,
    vi: *XVisualInfo,
    width: u32,
    height: u32,

    pub fn create(title: [:0]const u8, width: u32, height: u32) Error!GlWindow {
        const display = XOpenDisplay(null) orelse return error.NoDisplay;
        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);

        var attrs = [_]c_int{ GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_DEPTH_SIZE, 24, 0 };
        const vi = glXChooseVisual(display, screen, &attrs) orelse return error.NoVisual;

        const cmap = XCreateColormap(display, root, vi.visual, AllocNone);
        var swa: XSetWindowAttributes = .{ .colormap = cmap, .event_mask = ExposureMask };
        const window = XCreateWindow(display, root, 0, 0, width, height, 0, vi.depth, InputOutput, vi.visual, CWColormap | CWEventMask, &swa);
        _ = XStoreName(display, window, title.ptr);
        _ = XMapWindow(display, window);

        const ctx = glXCreateContext(display, vi, null, 1);
        if (ctx == null) return error.NoContext;
        _ = glXMakeCurrent(display, window, ctx);
        _ = XSync(display, 0);

        return .{ .display = display, .window = window, .ctx = ctx, .vi = vi, .width = width, .height = height };
    }

    pub fn destroy(self: *GlWindow) void {
        _ = glXMakeCurrent(self.display, 0, null);
        glXDestroyContext(self.display, self.ctx);
        _ = XDestroyWindow(self.display, self.window);
        _ = XFree(self.vi);
        _ = XCloseDisplay(self.display);
    }

    /// Clear the framebuffer to an RGBA color and present.
    pub fn clearAndPresent(self: *GlWindow, r: f32, g: f32, b: f32, a: f32) void {
        glViewport(0, 0, self.width, self.height);
        glClearColor(r, g, b, a);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        glXSwapBuffers(self.display, self.window);
    }

    /// Read the rendered framebuffer back as RGBA (bottom-up, GL origin).
    /// caller owns the returned buffer.
    pub fn readPixels(self: *GlWindow, gpa: std.mem.Allocator) ![]u8 {
        const buf = try gpa.alloc(u8, @as(usize, self.width) * self.height * 4);
        glReadPixels(0, 0, self.width, self.height, GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
        return buf;
    }
};
