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

// === Slice 2: proc loader + shader pipeline + textured-quad ================
// Loads modern GL via glXGetProcAddressARB, compiles a textured-quad
// program, and renders an uploaded RGBA image — to the window (present)
// or to an offscreen FBO (headless golden tests). This is the texture/
// shader/FBO foundation the glyph atlas and final present both reuse.

const GLuint = c_uint;
const GLint = c_int;
const GLenum = c_uint;
const GLsizei = c_int;

const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
const GL_VERTEX_SHADER: GLenum = 0x8B31;
const GL_COMPILE_STATUS: GLenum = 0x8B81;
const GL_LINK_STATUS: GLenum = 0x8B82;
const GL_ARRAY_BUFFER: GLenum = 0x8892;
const GL_STATIC_DRAW: GLenum = 0x88E4;
const GL_FLOAT: GLenum = 0x1406;
const GL_FALSE: u8 = 0;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE0: GLenum = 0x84C0;
const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
const GL_NEAREST: GLint = 0x2600;
const GL_CLAMP_TO_EDGE: GLint = 0x812F;
const GL_TRIANGLE_STRIP: GLenum = 0x0005;
const GL_FRAMEBUFFER: GLenum = 0x8D40;
const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;

extern "GL" fn glXGetProcAddressARB([*:0]const u8) ?*const anyopaque;

/// Loaded modern-GL entry points (glXGetProcAddressARB works for both
/// core-1.1 and 2.0+ in Mesa).
const Gl = struct {
    createShader: *const fn (GLenum) callconv(.c) GLuint,
    shaderSource: *const fn (GLuint, GLsizei, [*]const [*:0]const u8, ?[*]const GLint) callconv(.c) void,
    compileShader: *const fn (GLuint) callconv(.c) void,
    getShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    createProgram: *const fn () callconv(.c) GLuint,
    attachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    linkProgram: *const fn (GLuint) callconv(.c) void,
    getProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    useProgram: *const fn (GLuint) callconv(.c) void,
    genVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    bindVertexArray: *const fn (GLuint) callconv(.c) void,
    genBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    bindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    bufferData: *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(.c) void,
    vertexAttribPointer: *const fn (GLuint, GLint, GLenum, u8, GLsizei, ?*const anyopaque) callconv(.c) void,
    enableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    genTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    bindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    texImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    texParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    activeTexture: *const fn (GLenum) callconv(.c) void,
    getUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    drawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,
    genFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    bindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    framebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(.c) void,
    checkFramebufferStatus: *const fn (GLenum) callconv(.c) GLenum,

    fn load() Error!Gl {
        var g: Gl = undefined;
        inline for (@typeInfo(Gl).@"struct".fields) |f| {
            // GL symbol = "gl" + CamelCase field name.
            const sym = "gl" ++ [1]u8{std.ascii.toUpper(f.name[0])} ++ f.name[1..] ++ "\x00";
            const p = glXGetProcAddressARB(sym[0 .. sym.len - 1 :0]) orelse return error.NoContext;
            @field(g, f.name) = @ptrCast(p);
        }
        return g;
    }
};

const vert_src: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\attribute vec2 uv;
    \\varying vec2 v_uv;
    \\void main() { v_uv = uv; gl_Position = vec4(pos, 0.0, 1.0); }
;
const frag_src: [*:0]const u8 =
    \\#version 120
    \\varying vec2 v_uv;
    \\uniform sampler2D tex;
    \\void main() { gl_FragColor = texture2D(tex, v_uv); }
;

/// Textured-quad renderer over a current GL context. Renders an uploaded
/// RGBA image to the bound framebuffer (default = window; or an FBO).
pub const QuadRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    tex: GLuint,

    pub fn init() Error!QuadRenderer {
        const gl = try Gl.load();
        const program = try buildProgram(gl);

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.bindVertexArray(vao);
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        gl.bindBuffer(GL_ARRAY_BUFFER, vbo);
        // Fullscreen triangle strip: pos.xy, uv.xy. v flips (texture is
        // top-down RGBA; GL samples bottom-up).
        const verts = [_]f32{
            -1, -1, 0, 1,
            1,  -1, 1, 1,
            -1, 1,  0, 0,
            1,  1,  1, 0,
        };
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        const pos_loc = 0;
        const uv_loc = 1;
        gl.vertexAttribPointer(pos_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(0));
        gl.enableVertexAttribArray(pos_loc);
        gl.vertexAttribPointer(uv_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(8));
        gl.enableVertexAttribArray(uv_loc);

        var tex: GLuint = 0;
        gl.genTextures(1, @ptrCast(&tex));

        return .{ .gl = gl, .program = program, .vao = vao, .tex = tex };
    }

    fn buildProgram(gl: Gl) Error!GLuint {
        const vs = compile(gl, GL_VERTEX_SHADER, vert_src) orelse return error.NoContext;
        const fs = compile(gl, GL_FRAGMENT_SHADER, frag_src) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        // Bind attribute locations before link (GLSL 120 has no layout()).
        // Locations 0/1 match pos/uv via the default ordering in Mesa;
        // explicit binding would need glBindAttribLocation — fine here as
        // we set pointers by the same indices.
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        return prog;
    }

    fn compile(gl: Gl, kind: GLenum, src: [*:0]const u8) ?GLuint {
        const sh = gl.createShader(kind);
        var srcs = [_][*:0]const u8{src};
        gl.shaderSource(sh, 1, &srcs, null);
        gl.compileShader(sh);
        var ok: GLint = 0;
        gl.getShaderiv(sh, GL_COMPILE_STATUS, &ok);
        return if (ok == 0) null else sh;
    }

    /// Draw `rgba` (w×h, top-down) as a fullscreen quad into the current
    /// framebuffer/viewport.
    pub fn drawImage(self: *QuadRenderer, rgba: []const u8, w: u32, h: u32) void {
        const gl = self.gl;
        gl.useProgram(self.program);
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, self.tex);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(w), @intCast(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
        gl.uniform1i(gl.getUniformLocation(self.program, "tex"), 0);
        gl.bindVertexArray(self.vao);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    /// Render `rgba` into an offscreen FBO and read it back as RGBA
    /// (top-down). Headless — the path GPU golden tests use (#13).
    pub fn renderOffscreen(self: *QuadRenderer, gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
        const gl = self.gl;
        var fbo: GLuint = 0;
        gl.genFramebuffers(1, @ptrCast(&fbo));
        gl.bindFramebuffer(GL_FRAMEBUFFER, fbo);
        var target: GLuint = 0;
        gl.genTextures(1, @ptrCast(&target));
        gl.bindTexture(GL_TEXTURE_2D, target);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(w), @intCast(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
        if (gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return error.NoContext;

        glViewport(0, 0, w, h);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        self.drawImage(rgba, w, h);
        glFinish();

        const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
        // GL readback is bottom-up; flip to top-down to match the input.
        flipY(out, w, h);
        return out;
    }
};

fn flipY(px: []u8, w: u32, h: u32) void {
    const row = @as(usize, w) * 4;
    var y: usize = 0;
    while (y < h / 2) : (y += 1) {
        const top = px[y * row ..][0..row];
        const bot = px[(h - 1 - y) * row ..][0..row];
        for (top, bot) |*t, *b| std.mem.swap(u8, t, b);
    }
}
