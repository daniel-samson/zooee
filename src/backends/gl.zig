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
//! when context creation fails. Linux-only: macOS uses Metal (#101) and
//! Windows uses D3D11 (#12), so this file is never compiled there.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend_mod = @import("../backend.zig");

comptime {
    // GLX windowing is Linux-only (macOS=Metal #101, Windows=D3D11 #12).
    if (builtin.os.tag != .linux)
        @compileError("gl.zig: GL backend is Linux-only (macOS uses Metal, Windows D3D11)");
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
// Library-agnostic so they resolve via OpenGL.framework on macOS and libGL
// on Linux (the build links the right one per-OS). The glX* externs above
// keep the "GL" tag — they're Linux-only and dead-pruned on macOS.
extern fn glClearColor(f32, f32, f32, f32) void;
extern fn glClear(c_uint) void;
extern fn glViewport(c_int, c_int, c_uint, c_uint) void;
extern fn glFinish() void;
extern fn glReadPixels(c_int, c_int, c_uint, c_uint, c_uint, c_uint, [*]u8) void;
extern fn glEnable(c_uint) void;
extern fn glBlendFunc(c_uint, c_uint) void;

const GL_BLEND: c_uint = 0x0BE2;
const GL_SRC_ALPHA: c_uint = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: c_uint = 0x0303;

/// Source-over blending. Required for SDF coverage/AA to composite
/// against the background — without it the quad's full area writes color
/// regardless of fragment alpha.
fn enableBlend() void {
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

// GLX visual attribute tokens.
const GLX_RGBA: c_int = 4;
const GLX_DOUBLEBUFFER: c_int = 5;
const GLX_RED_SIZE: c_int = 8;
const GLX_GREEN_SIZE: c_int = 9;
const GLX_BLUE_SIZE: c_int = 10;
const GLX_DEPTH_SIZE: c_int = 12;
const CWBorderPixel: c_ulong = 1 << 3;
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
        // CWBorderPixel required for a non-default (GLX) visual, else
        // BadMatch → Xlib exits the process. See x11.zig for the full note.
        var swa: XSetWindowAttributes = .{ .border_pixel = 0, .colormap = cmap, .event_mask = ExposureMask };
        const window = XCreateWindow(display, root, 0, 0, width, height, 0, vi.depth, InputOutput, vi.visual, CWBorderPixel | CWColormap | CWEventMask, &swa);
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
const GL_LINEAR: GLint = 0x2601;
const GL_CLAMP_TO_EDGE: GLint = 0x812F;
const GL_TRIANGLE_STRIP: GLenum = 0x0005;
const GL_FRAMEBUFFER: GLenum = 0x8D40;
const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;

extern "GL" fn glXGetProcAddressARB([*:0]const u8) ?*const anyopaque;

/// Resolve a GL entry point by name (GLX; works for core-1.1 and 2.0+ in Mesa).
fn glProc(name: [*:0]const u8) ?*const anyopaque {
    return glXGetProcAddressARB(name);
}

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
    deleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    bindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    texImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    texParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    activeTexture: *const fn (GLenum) callconv(.c) void,
    getUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,
    uniform1i: *const fn (GLint, GLint) callconv(.c) void,
    drawArrays: *const fn (GLenum, GLint, GLsizei) callconv(.c) void,
    genFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    deleteFramebuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    bindFramebuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    framebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(.c) void,
    checkFramebufferStatus: *const fn (GLenum) callconv(.c) GLenum,
    uniform1f: *const fn (GLint, f32) callconv(.c) void,
    uniform2f: *const fn (GLint, f32, f32) callconv(.c) void,
    uniform4f: *const fn (GLint, f32, f32, f32, f32) callconv(.c) void,
    uniform2fv: *const fn (GLint, GLsizei, [*]const f32) callconv(.c) void,
    uniform1fv: *const fn (GLint, GLsizei, [*]const f32) callconv(.c) void,
    uniform4fv: *const fn (GLint, GLsizei, [*]const f32) callconv(.c) void,
    getAttribLocation: *const fn (GLuint, [*:0]const u8) callconv(.c) GLint,

    fn load() Error!Gl {
        var g: Gl = undefined;
        inline for (@typeInfo(Gl).@"struct".fields) |f| {
            // GL symbol = "gl" + CamelCase field name (Mesa exposes VAO/FBO
            // entry points unsuffixed via glXGetProcAddressARB).
            const base = "gl" ++ [1]u8{std.ascii.toUpper(f.name[0])} ++ f.name[1..];
            const sym = base ++ "\x00";
            const p = glProc(sym[0 .. sym.len - 1 :0]) orelse return error.NoContext;
            @field(g, f.name) = @ptrCast(@alignCast(p));
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
        // Query the linked locations rather than assuming 0/1 — Apple's GL
        // doesn't guarantee the Mesa default attribute ordering.
        const pos_loc: GLuint = @intCast(gl.getAttribLocation(program, "pos"));
        const uv_loc: GLuint = @intCast(gl.getAttribLocation(program, "uv"));
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

// === Slice 3: native rect rendering =========================================
// Draws solid-color rects as GPU geometry (pixel coords → NDC in the
// vertex shader) — the first true GPU *drawing*, vs texturing a CPU
// frame. Rounded corners/borders (SDF), the glyph atlas, and the full
// Backend impl build on this; batching is a later optimization.

const rect_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\uniform vec2 viewport;
    \\void main() {
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
const rect_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec4 color;
    \\void main() { gl_FragColor = color; }
;

pub const RectRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u_viewport: GLint,
    u_color: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!RectRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, rect_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, rect_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.bindVertexArray(vao);
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));

        const pos_loc = gl.getAttribLocation(prog, "pos");
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(pos_loc),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_color = gl.getUniformLocation(prog, "color"),
        };
    }

    /// Begin a frame: bind program, set viewport size (pixels), clear.
    pub fn begin(self: *RectRenderer, w: u32, h: u32, clear: [4]f32) void {
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        glViewport(0, 0, w, h);
        glClearColor(clear[0], clear[1], clear[2], clear[3]);
        glClear(GL_COLOR_BUFFER_BIT);
        self.gl.useProgram(self.program);
        self.gl.uniform2f(self.u_viewport, self.vw, self.vh);
    }

    /// Fill a rect in pixel coords (y-down, origin top-left).
    pub fn fillRect(self: *RectRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        const gl = self.gl;
        const verts = [_]f32{ x, y, x + w, y, x, y + h, x + w, y + h };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// Two-stop axis-aligned linear gradient fill (#118). A `v_px` varying carries
// the top-down pixel position (gl_FragCoord is bottom-up in GL), so the
// fragment's `t` matches raster's Gradient.colorAt exactly.
const grad_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\uniform vec2 viewport;
    \\varying vec2 v_px;
    \\void main() {
    \\  v_px = pos;
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
const grad_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec4 rect;     // x,y,w,h
    \\uniform float kind;    // 0=linear, 1=radial
    \\uniform float axis;    // linear: 0=h, 1=v
    \\uniform int count;     // stop count
    \\uniform vec4 radial;   // cx, cy, radius, 0
    \\uniform float offsets[8];
    \\uniform vec4 colors[8];
    \\varying vec2 v_px;
    \\void main() {
    \\  float t;
    \\  if (kind < 0.5) { t = (axis < 0.5) ? (v_px.x - rect.x) / rect.z : (v_px.y - rect.y) / rect.w; }
    \\  else { float cx = rect.x + radial.x*rect.z; float cy = rect.y + radial.y*rect.w; float rr = radial.z*max(rect.z,rect.w); float dx=v_px.x-cx, dy=v_px.y-cy; t = (rr>0.0) ? sqrt(dx*dx+dy*dy)/rr : 0.0; }
    \\  t = clamp(t, 0.0, 1.0);
    \\  if (t <= offsets[0]) { gl_FragColor = colors[0]; return; }
    \\  for (int i = 1; i < 8; i++) {
    \\    if (i >= count) break;
    \\    if (t <= offsets[i]) { float span = offsets[i]-offsets[i-1]; float f = (span>0.0) ? (t-offsets[i-1])/span : 0.0; gl_FragColor = mix(colors[i-1], colors[i], f); return; }
    \\  }
    \\  // t past the last stop — use the last color (loop-index access only; GLSL
    \\  // 120 forbids indexing a uniform array by a non-constant like count-1).
    \\  vec4 last = colors[0];
    \\  for (int i = 0; i < 8; i++) { if (i >= count) break; last = colors[i]; }
    \\  gl_FragColor = last;
    \\}
;

pub const GradientRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u_viewport: GLint,
    u_rect: GLint,
    u_kind: GLint,
    u_axis: GLint,
    u_count: GLint,
    u_radial: GLint,
    u_offsets: GLint,
    u_colors: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!GradientRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, grad_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, grad_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_rect = gl.getUniformLocation(prog, "rect"),
            .u_kind = gl.getUniformLocation(prog, "kind"),
            .u_axis = gl.getUniformLocation(prog, "axis"),
            .u_count = gl.getUniformLocation(prog, "count"),
            .u_radial = gl.getUniformLocation(prog, "radial"),
            .u_offsets = gl.getUniformLocation(prog, "offsets"),
            .u_colors = gl.getUniformLocation(prog, "colors"),
        };
    }

    /// Fill a pixel-space rect with a linear or radial N-stop gradient (#118).
    pub fn fill(self: *GradientRenderer, rect: geometry.Rect, g: style.Gradient) void {
        const gl = self.gl;
        var buf: [style.Gradient.max_stops]style.Gradient.Stop = undefined;
        const ss = g.resolved(&buf);
        var offsets: [8]f32 = .{0} ** 8;
        var colors: [32]f32 = .{0} ** 32;
        for (ss, 0..) |s, i| {
            offsets[i] = s.offset;
            colors[i * 4] = @as(f32, @floatFromInt(s.color.r)) / 255;
            colors[i * 4 + 1] = @as(f32, @floatFromInt(s.color.g)) / 255;
            colors[i * 4 + 2] = @as(f32, @floatFromInt(s.color.b)) / 255;
            colors[i * 4 + 3] = @as(f32, @floatFromInt(s.color.a)) / 255;
        }
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, self.vw, self.vh);
        gl.uniform4f(self.u_rect, rect.x, rect.y, rect.width, rect.height);
        gl.uniform1f(self.u_kind, @floatFromInt(@intFromEnum(g.kind)));
        gl.uniform1f(self.u_axis, if (g.axis == .vertical) 1 else 0);
        gl.uniform1i(self.u_count, @intCast(ss.len));
        gl.uniform4f(self.u_radial, g.cx, g.cy, g.radius, 0);
        gl.uniform1fv(self.u_offsets, 8, &offsets);
        gl.uniform4fv(self.u_colors, 8, &colors);
        const verts = [_]f32{ rect.x, rect.y, rect.x + rect.width, rect.y, rect.x, rect.y + rect.height, rect.x + rect.width, rect.y + rect.height };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// Box shadow (#119). v_px carries the top-down pixel pos (gl_FragCoord is
// bottom-up); the PS replicates style.BoxShadow.coverage's erf/band exactly.
const shadow_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\uniform vec2 viewport;
    \\varying vec2 v_px;
    \\void main() {
    \\  v_px = pos;
    \\  gl_Position = vec4(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0, 0.0, 1.0);
    \\}
;
const shadow_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec4 rect;  // x,y,w,h
    \\uniform vec4 sh;    // dx,dy,blur,spread
    \\uniform float corner;
    \\uniform float inset;
    \\uniform vec4 color;
    \\varying vec2 v_px;
    \\float erf_(float x){ float t=1.0/(1.0+0.3275911*abs(x)); float y=1.0-(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-0.284496736)*t+0.254829592)*t*exp(-x*x); return x<0.0?-y:y; }
    \\float band_(float p,float lo,float hi,float s){ float inv=1.0/(s*1.4142135623730951); return 0.5*(erf_((hi-p)*inv)-erf_((lo-p)*inv)); }
    \\float werf_(float x){ float s=x<0.0?-1.0:1.0; float a=abs(x); float v=1.0+(0.278393+(0.230389+0.078108*(a*a))*a)*a; v*=v; return s - s/(v*v); }
    \\float gauss_(float x, float sigma){ return exp(-(x*x)/(2.0*sigma*sigma)) / (2.5066282746310002*sigma); }
    \\float roundedX_(float x, float y, float sigma, float cr, float hx, float hy){ float delta=min(hy-cr-abs(y), 0.0); float curved=hx-cr+sqrt(max(0.0, cr*cr-delta*delta)); float inv=0.7071067811865476/sigma; float lo=0.5+0.5*werf_((x-curved)*inv); float hi=0.5+0.5*werf_((x+curved)*inv); return hi-lo; }
    \\float boxCov_(float x0,float y0,float x1,float y1,float cn,float s,float px,float py){
    \\  if (s<=0.0) return (px>=x0&&px<x1&&py>=y0&&py<y1)?1.0:0.0;
    \\  if (cn<=0.0) return clamp(band_(px,x0,x1,s)*band_(py,y0,y1,s),0.0,1.0);
    \\  float cx=(x0+x1)*0.5, cy=(y0+y1)*0.5, hx=(x1-x0)*0.5, hy=(y1-y0)*0.5; float cr=min(cn,min(hx,hy));
    \\  float ptx=px-cx, pty=py-cy; float low=pty-hy, high=pty+hy; float start=clamp(-3.0*s,low,high); float end=clamp(3.0*s,low,high);
    \\  float step=(end-start)/4.0; float yv=start+step*0.5; float value=0.0;
    \\  for(int k=0;k<4;k++){ value+=roundedX_(ptx,pty-yv,s,cr,hx,hy)*gauss_(yv,s)*step; yv+=step; } return clamp(value,0.0,1.0);
    \\}
    \\bool insideRR_(float rx,float ry,float rw,float rh,float cn,float px,float py){
    \\  if(px<rx||px>=rx+rw||py<ry||py>=ry+rh) return false; float cr=min(cn,min(rw,rh)*0.5);
    \\  if(px<rx+cr&&py<ry+cr){float dx=px-(rx+cr),dy=py-(ry+cr); if(dx*dx+dy*dy>cr*cr) return false;}
    \\  if(px>=rx+rw-cr&&py<ry+cr){float dx=px-(rx+rw-cr),dy=py-(ry+cr); if(dx*dx+dy*dy>cr*cr) return false;}
    \\  if(px>=rx+rw-cr&&py>=ry+rh-cr){float dx=px-(rx+rw-cr),dy=py-(ry+rh-cr); if(dx*dx+dy*dy>cr*cr) return false;}
    \\  if(px<rx+cr&&py>=ry+rh-cr){float dx=px-(rx+cr),dy=py-(ry+rh-cr); if(dx*dx+dy*dy>cr*cr) return false;} return true;
    \\}
    \\void main(){
    \\  float dx=sh.x, dy=sh.y, blur=sh.z, spread=sh.w; float s=blur*0.5;
    \\  if (inset>0.5) {
    \\    if (!insideRR_(rect.x,rect.y,rect.z,rect.w,corner, v_px.x,v_px.y)) discard;
    \\    float ix0=rect.x+dx+spread, iy0=rect.y+dy+spread, ix1=rect.x+rect.z+dx-spread, iy1=rect.y+rect.w+dy-spread;
    \\    float cov = clamp(1.0 - boxCov_(ix0,iy0,ix1,iy1,corner,s, v_px.x,v_px.y), 0.0, 1.0);
    \\    gl_FragColor = vec4(color.rgb, cov*color.a); return;
    \\  }
    \\  float x0=rect.x+dx-spread, y0=rect.y+dy-spread, x1=rect.x+rect.z+dx+spread, y1=rect.y+rect.w+dy+spread;
    \\  gl_FragColor = vec4(color.rgb, boxCov_(x0,y0,x1,y1,corner,s, v_px.x,v_px.y)*color.a);
    \\}
;

/// Paints a Gaussian box shadow (#119) — the GL port of style.BoxShadow.coverage.
pub const ShadowRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u_viewport: GLint,
    u_rect: GLint,
    u_sh: GLint,
    u_corner: GLint,
    u_inset: GLint,
    u_color: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!ShadowRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, shadow_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, shadow_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_rect = gl.getUniformLocation(prog, "rect"),
            .u_sh = gl.getUniformLocation(prog, "sh"),
            .u_corner = gl.getUniformLocation(prog, "corner"),
            .u_inset = gl.getUniformLocation(prog, "inset"),
            .u_color = gl.getUniformLocation(prog, "color"),
        };
    }

    /// Draw the shadow over the expanded `quad` (x,y,w,h pixel space).
    pub fn draw(self: *ShadowRenderer, quad: [4]f32, rect: [4]f32, sh: [4]f32, color: [4]f32, corner: f32, inset: bool) void {
        const gl = self.gl;
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, self.vw, self.vh);
        gl.uniform4f(self.u_rect, rect[0], rect[1], rect[2], rect[3]);
        gl.uniform4f(self.u_sh, sh[0], sh[1], sh[2], sh[3]);
        gl.uniform1f(self.u_corner, corner);
        gl.uniform1f(self.u_inset, if (inset) 1 else 0);
        gl.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        const x = quad[0];
        const y = quad[1];
        const w = quad[2];
        const h = quad[3];
        const verts = [_]f32{ x, y, x + w, y, x, y + h, x + w, y + h };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// Filled path (#120). v_px carries the top-down pixel pos; the PS runs the
// same division-free even-odd test as geometry.pointInPolygon.
const path_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\uniform vec2 viewport;
    \\varying vec2 v_px;
    \\void main() {
    \\  v_px = pos;
    \\  gl_Position = vec4(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0, 0.0, 1.0);
    \\}
;
const path_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec2 pts[64];
    \\uniform int count;
    \\uniform vec4 color;
    \\varying vec2 v_px;
    \\void main(){
    \\  float px = v_px.x, py = v_px.y;
    \\  bool inside = false;
    \\  int j = count - 1;
    \\  for (int i = 0; i < 64; i++) {
    \\    if (i >= count) break;
    \\    vec2 b = pts[i]; vec2 a = pts[j];
    \\    if ((b.y > py) != (a.y > py)) {
    \\      float lhs = (a.x - b.x) * (py - b.y);
    \\      float rhs = (px - b.x) * (a.y - b.y);
    \\      bool left = (a.y > b.y) ? (rhs < lhs) : (rhs > lhs);
    \\      if (left) inside = !inside;
    \\    }
    \\    j = i;
    \\  }
    \\  if (!inside) discard;
    \\  gl_FragColor = color;
    \\}
;

/// Fills a closed polygon (#120) — the GL port of geometry.pointInPolygon.
pub const PathRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u_viewport: GLint,
    u_pts: GLint,
    u_count: GLint,
    u_color: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!PathRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, path_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, path_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_pts = gl.getUniformLocation(prog, "pts"),
            .u_count = gl.getUniformLocation(prog, "count"),
            .u_color = gl.getUniformLocation(prog, "color"),
        };
    }

    pub fn fill(self: *PathRenderer, points: []const geometry.Point, color: [4]f32) void {
        if (points.len < 3) return;
        const gl = self.gl;
        const n = @min(points.len, 64);
        var flat: [128]f32 = undefined;
        var minx = points[0].x;
        var miny = points[0].y;
        var maxx = points[0].x;
        var maxy = points[0].y;
        for (0..n) |i| {
            flat[i * 2] = points[i].x;
            flat[i * 2 + 1] = points[i].y;
            minx = @min(minx, points[i].x);
            miny = @min(miny, points[i].y);
            maxx = @max(maxx, points[i].x);
            maxy = @max(maxy, points[i].y);
        }
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, self.vw, self.vh);
        gl.uniform2fv(self.u_pts, @intCast(n), &flat);
        gl.uniform1i(self.u_count, @intCast(n));
        gl.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        const verts = [_]f32{ minx, miny, maxx, miny, minx, maxy, maxx, maxy };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// Stroked polyline (#120). Same v_px top-down pixel pos; the PS keeps a
// fragment within hw² (squared half-width) of any segment — geometry.segDist2.
const stroke_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec2 pts[64];
    \\uniform int count;
    \\uniform float hw2;
    \\uniform int closed;
    \\uniform vec4 color;
    \\varying vec2 v_px;
    \\float segd2(vec2 a, vec2 b, vec2 p){ vec2 v=b-a; vec2 w=p-a; float vv=dot(v,v); float t=(vv>0.0)?clamp(dot(w,v)/vv,0.0,1.0):0.0; vec2 d=a+t*v-p; return dot(d,d); }
    \\void main(){
    \\  vec2 p = v_px;
    \\  int last = (closed != 0) ? count : count - 1;
    \\  bool hit = false;
    \\  for (int i = 0; i < 64; i++) {
    \\    if (i >= last) break;
    \\    vec2 a = pts[i]; vec2 b = pts[int(mod(float(i + 1), float(count)))];
    \\    if (segd2(a, b, p) <= hw2) { hit = true; break; }
    \\  }
    \\  if (!hit) discard;
    \\  gl_FragColor = color;
    \\}
;

/// Strokes a polyline (#120) — the GL port of geometry.pointNearPolyline.
pub const StrokeRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u_viewport: GLint,
    u_pts: GLint,
    u_count: GLint,
    u_hw2: GLint,
    u_closed: GLint,
    u_color: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!StrokeRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, path_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, stroke_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_pts = gl.getUniformLocation(prog, "pts"),
            .u_count = gl.getUniformLocation(prog, "count"),
            .u_hw2 = gl.getUniformLocation(prog, "hw2"),
            .u_closed = gl.getUniformLocation(prog, "closed"),
            .u_color = gl.getUniformLocation(prog, "color"),
        };
    }

    pub fn stroke(self: *StrokeRenderer, points: []const geometry.Point, hw: f32, color: [4]f32, closed: bool) void {
        if (points.len < 2) return;
        const gl = self.gl;
        const n = @min(points.len, 64);
        var flat: [128]f32 = undefined;
        var minx = points[0].x;
        var miny = points[0].y;
        var maxx = points[0].x;
        var maxy = points[0].y;
        for (0..n) |i| {
            flat[i * 2] = points[i].x;
            flat[i * 2 + 1] = points[i].y;
            minx = @min(minx, points[i].x);
            miny = @min(miny, points[i].y);
            maxx = @max(maxx, points[i].x);
            maxy = @max(maxy, points[i].y);
        }
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, self.vw, self.vh);
        gl.uniform2fv(self.u_pts, @intCast(n), &flat);
        gl.uniform1i(self.u_count, @intCast(n));
        gl.uniform1f(self.u_hw2, hw * hw);
        gl.uniform1i(self.u_closed, if (closed) 1 else 0);
        gl.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        const verts = [_]f32{ minx - hw, miny - hw, maxx + hw, miny - hw, minx - hw, maxy + hw, maxx + hw, maxy + hw };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

const comp_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\attribute vec2 uv;
    \\varying vec2 v_uv;
    \\void main() { v_uv = uv; gl_Position = vec4(pos, 0.0, 1.0); }
;
const comp_frag: [*:0]const u8 =
    \\#version 120
    \\varying vec2 v_uv;
    \\uniform sampler2D tex;
    \\uniform float opacity;
    \\void main() { vec4 c = texture2D(tex, v_uv); gl_FragColor = vec4(c.rgb, c.a * opacity); }
;

/// Composites an offscreen layer texture over the bound framebuffer at a
/// uniform opacity (#121). Fragment emits straight-alpha (rgb, a*opacity);
/// under enableBlend()'s source-over this matches raster's popLayer. The
/// layer texture and the target FBO share GL's bottom-up orientation, so the
/// quad maps uv 1:1 to pos (no v-flip).
pub const LayerCompositor = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    uv_loc: GLuint,
    u_tex: GLint,
    u_opacity: GLint,

    pub fn init() Error!LayerCompositor {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, comp_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, comp_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .uv_loc = @intCast(gl.getAttribLocation(prog, "uv")),
            .u_tex = gl.getUniformLocation(prog, "tex"),
            .u_opacity = gl.getUniformLocation(prog, "opacity"),
        };
    }

    pub fn composite(self: *LayerCompositor, tex: GLuint, opacity: f32) void {
        const gl = self.gl;
        gl.useProgram(self.program);
        gl.uniform1f(self.u_opacity, opacity);
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.uniform1i(self.u_tex, 0);
        // pos.xy NDC, uv.xy (no flip): both FBOs are bottom-up.
        const verts = [_]f32{
            -1, -1, 0, 0,
            1,  -1, 1, 0,
            -1, 1,  0, 1,
            1,  1,  1, 1,
        };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.vertexAttribPointer(self.uv_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(8));
        gl.enableVertexAttribArray(self.uv_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// Round-clip mask shaders (#117). The vertex carries a [0,1] corner; v_uv
// samples the layer (bottom-up, no flip — matches LayerCompositor) while v_px
// is the TOP-DOWN pixel position so the insideRounded test matches raster.
const rclip_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 corner;
    \\uniform vec2 viewport;
    \\varying vec2 v_uv;
    \\varying vec2 v_px;
    \\void main() {
    \\  v_uv = corner;
    \\  v_px = vec2(corner.x * viewport.x, (1.0 - corner.y) * viewport.y);
    \\  gl_Position = vec4(corner.x * 2.0 - 1.0, corner.y * 2.0 - 1.0, 0.0, 1.0);
    \\}
;
const rclip_frag: [*:0]const u8 =
    \\#version 120
    \\uniform sampler2D tex;
    \\uniform vec4 rect;   // x,y,w,h
    \\uniform vec4 radius; // tl,tr,br,bl
    \\varying vec2 v_uv;
    \\varying vec2 v_px;
    \\void main() {
    \\  float fx = v_px.x, fy = v_px.y;
    \\  float rx = rect.x, ry = rect.y, rw = rect.z, rh = rect.w;
    \\  if (fx < rx || fx >= rx + rw || fy < ry || fy >= ry + rh) discard;
    \\  float maxr = min(rw, rh) * 0.5;
    \\  float cxm = rx + rw * 0.5, cym = ry + rh * 0.5;
    \\  { float r = min(radius.x, maxr); if (r > 0.0) { float cx = rx + radius.x, cy = ry + radius.x; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard; } } }
    \\  { float r = min(radius.y, maxr); if (r > 0.0) { float cx = rx + rw - radius.y, cy = ry + radius.y; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard; } } }
    \\  { float r = min(radius.z, maxr); if (r > 0.0) { float cx = rx + rw - radius.z, cy = ry + rh - radius.z; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard; } } }
    \\  { float r = min(radius.w, maxr); if (r > 0.0) { float cx = rx + radius.w, cy = ry + rh - radius.w; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard; } } }
    \\  gl_FragColor = texture2D(tex, v_uv);
    \\}
;

/// Composites a clip layer over its parent, masked to a rounded rect (#117):
/// the fragment discards pixels outside insideRounded at the top-down pixel
/// center, matching raster's hard-edged per-pixel rounded clip.
pub const RoundClipCompositor = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    corner_loc: GLuint,
    u_viewport: GLint,
    u_tex: GLint,
    u_rect: GLint,
    u_radius: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!RoundClipCompositor {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, rclip_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, rclip_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;
        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .corner_loc = @intCast(gl.getAttribLocation(prog, "corner")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_tex = gl.getUniformLocation(prog, "tex"),
            .u_rect = gl.getUniformLocation(prog, "rect"),
            .u_radius = gl.getUniformLocation(prog, "radius"),
        };
    }

    pub fn composite(self: *RoundClipCompositor, tex: GLuint, rect: geometry.Rect, radius: style.CornerRadius) void {
        const gl = self.gl;
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, self.vw, self.vh);
        gl.uniform4f(self.u_rect, rect.x, rect.y, rect.width, rect.height);
        gl.uniform4f(self.u_radius, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left);
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.uniform1i(self.u_tex, 0);
        const verts = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.corner_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.corner_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

/// Make a GlWindow context current and return it, for offscreen use.
/// Renders `scene` into an FBO of size w×h and reads it back (top-down).
pub fn renderRectsOffscreen(
    gpa: std.mem.Allocator,
    rr: *RectRenderer,
    w: u32,
    h: u32,
    clear: [4]f32,
    scene: *const fn (*RectRenderer) void,
) ![]u8 {
    const gl = rr.gl;
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

    rr.begin(w, h, clear);
    scene(rr);
    glFinish();

    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
    flipY(out, w, h);
    return out;
}

// === Slice 4: SDF rounded rects + border ====================================
// A signed-distance fragment shader gives anti-aliased rounded corners
// and a uniform border in one draw — matching raster's RectStyle (bg +
// corner_radius + border). Per-side borders / per-corner radii are a
// refinement; this covers the common card/button case.

const round_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\attribute vec2 local;
    \\uniform vec2 viewport;
    \\varying vec2 v_local;
    \\void main() {
    \\  v_local = local;
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
// AA over ~1px via smoothstep (no fwidth — avoids GLSL 120 extension needs;
// we render at known pixel scale). sdRoundBox: standard rounded-box SDF.
const round_frag: [*:0]const u8 =
    \\#version 120
    \\varying vec2 v_local;
    \\uniform vec2 half_size;
    \\uniform float radius;
    \\uniform float border;
    \\uniform vec4 bg;
    \\uniform vec4 border_color;
    \\float sdRoundBox(vec2 p, vec2 b, float r) {
    \\  vec2 q = abs(p) - b + vec2(r);
    \\  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
    \\}
    \\void main() {
    \\  float d = sdRoundBox(v_local, half_size, radius);
    \\  float outer = smoothstep(1.0, -1.0, d);        // 1 inside shape
    \\  float fill = smoothstep(1.0, -1.0, d + border); // 1 inside the bg (past border)
    \\  vec4 col = mix(border_color, bg, fill);
    \\  col.a *= outer;
    \\  gl_FragColor = col;
    \\}
;

pub const RoundedRectRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    local_loc: GLuint,
    u_viewport: GLint,
    u_half: GLint,
    u_radius: GLint,
    u_border: GLint,
    u_bg: GLint,
    u_border_color: GLint,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init() Error!RoundedRectRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, round_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, round_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.bindVertexArray(vao);
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));

        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .local_loc = @intCast(gl.getAttribLocation(prog, "local")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_half = gl.getUniformLocation(prog, "half_size"),
            .u_radius = gl.getUniformLocation(prog, "radius"),
            .u_border = gl.getUniformLocation(prog, "border"),
            .u_bg = gl.getUniformLocation(prog, "bg"),
            .u_border_color = gl.getUniformLocation(prog, "border_color"),
        };
    }

    pub fn begin(self: *RoundedRectRenderer, w: u32, h: u32, clear: [4]f32) void {
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        glViewport(0, 0, w, h);
        glClearColor(clear[0], clear[1], clear[2], clear[3]);
        glClear(GL_COLOR_BUFFER_BIT);
        self.gl.useProgram(self.program);
        self.gl.uniform2f(self.u_viewport, self.vw, self.vh);
        enableBlend();
    }

    /// Rounded rect with uniform corner radius + uniform border, pixel
    /// coords (y-down). bg/border are RGBA 0..1.
    pub fn draw(self: *RoundedRectRenderer, x: f32, y: f32, w: f32, h: f32, radius: f32, border: f32, bg: [4]f32, border_color: [4]f32) void {
        const gl = self.gl;
        const hw = w / 2;
        const hh = h / 2;
        const p = 1.0; // AA padding
        // Interleaved pos.xy, local.xy for the 4 padded corners.
        const verts = [_]f32{
            x - p,     y - p,     -(hw + p), -(hh + p),
            x + w + p, y - p,     hw + p,    -(hh + p),
            x - p,     y + h + p, -(hw + p), hh + p,
            x + w + p, y + h + p, hw + p,    hh + p,
        };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.vertexAttribPointer(self.local_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(8));
        gl.enableVertexAttribArray(self.local_loc);
        gl.uniform2f(self.u_half, hw, hh);
        gl.uniform1f(self.u_radius, radius);
        gl.uniform1f(self.u_border, border);
        gl.uniform4f(self.u_bg, bg[0], bg[1], bg[2], bg[3]);
        gl.uniform4f(self.u_border_color, border_color[0], border_color[1], border_color[2], border_color[3]);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

// === Exact rect renderer (per-side borders, per-corner radii) ===============
// The slice-4 SDF renderer (RoundedRectRenderer) gives anti-aliased uniform
// corners/border — but raster.zig (the golden reference, #13) draws rects
// HARD-edged with per-side border colors and per-corner radii. To match it
// pixel-exact through the Backend, this renderer replicates raster's
// insideRounded() + borderColorAt() per fragment: same pixel-center sampling,
// same corner-square side attribution, no AA. gl_FragCoord gives the pixel
// center (x+0.5); we flip y (FBO is bottom-up) so p matches raster's (px,py).

const exact_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\uniform vec2 viewport;
    \\void main() {
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
const exact_frag: [*:0]const u8 =
    \\#version 120
    \\uniform vec2 viewport;
    \\uniform vec4 rect;   // x,y,w,h (top-down px)
    \\uniform vec4 rad;    // outer radii: tl,tr,br,bl
    \\uniform vec4 inner;  // x,y,w,h
    \\uniform vec4 irad;   // inner radii: tl,tr,br,bl
    \\uniform vec4 bw;     // border widths: top,right,bottom,left
    \\uniform float has_bg;
    \\uniform vec4 bg;
    \\uniform vec4 ct;     // border colors: top,right,bottom,left
    \\uniform vec4 cr;
    \\uniform vec4 cb;
    \\uniform vec4 cl;
    \\bool cornerOut(vec2 p, float orad, float trad, float cx, float cy, vec2 r0, vec2 rsz) {
    \\  // p is outside the shape if it lies past this corner's quarter-circle.
    \\  if (trad <= 0.0) return false;
    \\  bool in_x = (cx <= r0.x + rsz.x*0.5) ? (p.x < cx) : (p.x > cx);
    \\  bool in_y = (cy <= r0.y + rsz.y*0.5) ? (p.y < cy) : (p.y > cy);
    \\  if (in_x && in_y) { float dx = p.x-cx; float dy = p.y-cy; return dx*dx+dy*dy > trad*trad; }
    \\  return false;
    \\}
    \\bool insideRounded(vec4 r, vec4 rd, vec2 p) {
    \\  if (p.x < r.x || p.x >= r.x + r.z || p.y < r.y || p.y >= r.y + r.w) return false;
    \\  float mx = min(r.z, r.w) * 0.5;
    \\  vec2 r0 = r.xy; vec2 rsz = r.zw;
    \\  if (cornerOut(p, rd.x, min(rd.x, mx), r.x + rd.x,        r.y + rd.x,        r0, rsz)) return false; // tl
    \\  if (cornerOut(p, rd.y, min(rd.y, mx), r.x + r.z - rd.y,  r.y + rd.y,        r0, rsz)) return false; // tr
    \\  if (cornerOut(p, rd.z, min(rd.z, mx), r.x + r.z - rd.z,  r.y + r.w - rd.z,  r0, rsz)) return false; // br
    \\  if (cornerOut(p, rd.w, min(rd.w, mx), r.x + rd.w,        r.y + r.w - rd.w,  r0, rsz)) return false; // bl
    \\  return true;
    \\}
    \\vec4 borderColorAt(vec2 p) {
    \\  if (p.x < rect.x + rad.x && p.y < rect.y + rad.x) return (bw.x > 0.0) ? ct : cl;
    \\  if (p.x >= rect.x + rect.z - rad.y && p.y < rect.y + rad.y) return (bw.x > 0.0) ? ct : cr;
    \\  if (p.x >= rect.x + rect.z - rad.z && p.y >= rect.y + rect.w - rad.z) return (bw.z > 0.0) ? cb : cr;
    \\  if (p.x < rect.x + rad.w && p.y >= rect.y + rect.w - rad.w) return (bw.z > 0.0) ? cb : cl;
    \\  if (p.y < inner.y) return ct;
    \\  if (p.y >= inner.y + inner.w) return cb;
    \\  if (p.x < inner.x) return cl;
    \\  return cr;
    \\}
    \\void main() {
    \\  vec2 p = vec2(gl_FragCoord.x, viewport.y - gl_FragCoord.y);
    \\  if (!insideRounded(rect, rad, p)) discard;
    \\  bool has_border = (bw.x + bw.y + bw.z + bw.w) > 0.0;
    \\  if (has_border && !insideRounded(inner, irad, p)) { gl_FragColor = borderColorAt(p); return; }
    \\  if (has_bg > 0.5) { gl_FragColor = bg; return; }
    \\  discard;
    \\}
;

pub const ExactRectRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    u: struct {
        viewport: GLint,
        rect: GLint,
        rad: GLint,
        inner: GLint,
        irad: GLint,
        bw: GLint,
        has_bg: GLint,
        bg: GLint,
        ct: GLint,
        cr: GLint,
        cb: GLint,
        cl: GLint,
    },

    pub fn init() Error!ExactRectRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, exact_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, exact_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.bindVertexArray(vao);
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));

        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .u = .{
                .viewport = gl.getUniformLocation(prog, "viewport"),
                .rect = gl.getUniformLocation(prog, "rect"),
                .rad = gl.getUniformLocation(prog, "rad"),
                .inner = gl.getUniformLocation(prog, "inner"),
                .irad = gl.getUniformLocation(prog, "irad"),
                .bw = gl.getUniformLocation(prog, "bw"),
                .has_bg = gl.getUniformLocation(prog, "has_bg"),
                .bg = gl.getUniformLocation(prog, "bg"),
                .ct = gl.getUniformLocation(prog, "ct"),
                .cr = gl.getUniformLocation(prog, "cr"),
                .cb = gl.getUniformLocation(prog, "cb"),
                .cl = gl.getUniformLocation(prog, "cl"),
            },
        };
    }

    /// Draw one styled rect, replicating raster pixel-exact. `vw`/`vh` are
    /// the viewport (framebuffer) size in pixels.
    pub fn draw(self: *ExactRectRenderer, vw: f32, vh: f32, rect: geometry.Rect, rs: style.RectStyle) void {
        const gl = self.gl;
        const b = rs.border;
        // Inner rect (border-box → content-box) and inner radii, matching
        // raster.drawRect exactly.
        const inner = [4]f32{
            rect.x + b.left.width,
            rect.y + b.top.width,
            @max(0, rect.width - b.left.width - b.right.width),
            @max(0, rect.height - b.top.width - b.bottom.width),
        };
        const cr_ = rs.corner_radius;
        const irad = [4]f32{
            @max(0, cr_.top_left - @max(b.top.width, b.left.width)),
            @max(0, cr_.top_right - @max(b.top.width, b.right.width)),
            @max(0, cr_.bottom_right - @max(b.bottom.width, b.right.width)),
            @max(0, cr_.bottom_left - @max(b.bottom.width, b.left.width)),
        };

        gl.useProgram(self.program);
        gl.uniform2f(self.u.viewport, vw, vh);
        gl.uniform4f(self.u.rect, rect.x, rect.y, rect.width, rect.height);
        gl.uniform4f(self.u.rad, cr_.top_left, cr_.top_right, cr_.bottom_right, cr_.bottom_left);
        gl.uniform4f(self.u.inner, inner[0], inner[1], inner[2], inner[3]);
        gl.uniform4f(self.u.irad, irad[0], irad[1], irad[2], irad[3]);
        gl.uniform4f(self.u.bw, b.top.width, b.right.width, b.bottom.width, b.left.width);
        if (rs.background) |bg| {
            const c = col4(bg);
            gl.uniform1f(self.u.has_bg, 1);
            gl.uniform4f(self.u.bg, c[0], c[1], c[2], c[3]);
        } else {
            gl.uniform1f(self.u.has_bg, 0);
        }
        const ct = col4(b.top.color);
        const crr = col4(b.right.color);
        const cb = col4(b.bottom.color);
        const cll = col4(b.left.color);
        gl.uniform4f(self.u.ct, ct[0], ct[1], ct[2], ct[3]);
        gl.uniform4f(self.u.cr, crr[0], crr[1], crr[2], crr[3]);
        gl.uniform4f(self.u.cb, cb[0], cb[1], cb[2], cb[3]);
        gl.uniform4f(self.u.cl, cll[0], cll[1], cll[2], cll[3]);

        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.width;
        const y1 = rect.y + rect.height;
        const verts = [_]f32{ x0, y0, x1, y0, x0, y1, x1, y1 };
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 0, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

fn col4(c: style.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255,
        @as(f32, @floatFromInt(c.g)) / 255,
        @as(f32, @floatFromInt(c.b)) / 255,
        @as(f32, @floatFromInt(c.a)) / 255,
    };
}

// === Image renderer (positioned textured quad) ==============================
// Draws an uploaded RGBA texture into a pixel-space rect — the GL half of
// Backend.drawImage. GL_NEAREST + CLAMP_TO_EDGE match raster.drawImage's
// nearest-neighbor, clamped sampling, so GL is pixel-exact against the
// raster golden. uv runs 0..1 across the rect; texel 0 (first uploaded row)
// is our top-down row 0, placed at the rect's top edge.

const image_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\attribute vec2 uv;
    \\uniform vec2 viewport;
    \\varying vec2 v_uv;
    \\void main() {
    \\  v_uv = uv;
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
const image_frag: [*:0]const u8 =
    \\#version 120
    \\varying vec2 v_uv;
    \\uniform sampler2D tex;
    \\void main() { gl_FragColor = texture2D(tex, v_uv); }
;

pub const ImageRenderer = struct {
    gl: Gl,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    pos_loc: GLuint,
    uv_loc: GLuint,
    u_viewport: GLint,
    u_tex: GLint,

    pub fn init() Error!ImageRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, image_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, image_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        gl.bindVertexArray(vao);
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));

        return .{
            .gl = gl,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .uv_loc = @intCast(gl.getAttribLocation(prog, "uv")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_tex = gl.getUniformLocation(prog, "tex"),
        };
    }

    /// Upload an RGBA image (top-down) into a new GL texture; nearest +
    /// clamp to match raster. Returns the texture id.
    pub fn upload(self: *ImageRenderer, width: u32, height: u32, rgba: []const u8) GLuint {
        const gl = self.gl;
        var tex: GLuint = 0;
        gl.genTextures(1, @ptrCast(&tex));
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(width), @intCast(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        return tex;
    }

    /// Draw texture `tex` into pixel-space `rect`. `vw`/`vh` are the
    /// framebuffer size.
    pub fn draw(self: *ImageRenderer, vw: f32, vh: f32, rect: geometry.Rect, tex: GLuint) void {
        self.drawUv(vw, vh, rect, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, tex, .nearest);
    }

    /// Draw the `src` UV sub-rect of `tex` into pixel-space `dst` (#122 fit),
    /// with nearest or bilinear filtering.
    pub fn drawUv(self: *ImageRenderer, vw: f32, vh: f32, dst: geometry.Rect, src: geometry.Rect, tex: GLuint, sampling: Backend.Sampling) void {
        const gl = self.gl;
        const x0 = dst.x;
        const y0 = dst.y;
        const x1 = dst.x + dst.width;
        const y1 = dst.y + dst.height;
        const tx0 = src.x;
        const ty0 = src.y;
        const tx1 = src.x + src.width;
        const ty1 = src.y + src.height;
        // Interleaved pos.xy, uv.xy. uv.t = 0 at the rect top (texel row 0).
        const verts = [_]f32{
            x0, y0, tx0, ty0,
            x1, y0, tx1, ty0,
            x0, y1, tx0, ty1,
            x1, y1, tx1, ty1,
        };
        gl.useProgram(self.program);
        gl.uniform2f(self.u_viewport, vw, vh);
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, tex);
        const filter: GLint = switch (sampling) {
            .nearest => GL_NEAREST,
            .linear => GL_LINEAR,
        };
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
        gl.uniform1i(self.u_tex, 0);
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.vertexAttribPointer(self.uv_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(8));
        gl.enableVertexAttribArray(self.uv_loc);
        gl.drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
};

/// Offscreen FBO render for the rounded-rect renderer (mirrors
/// renderRectsOffscreen). Readback is top-down.
pub fn renderRoundedOffscreen(
    gpa: std.mem.Allocator,
    rr: *RoundedRectRenderer,
    w: u32,
    h: u32,
    clear: [4]f32,
    scene: *const fn (*RoundedRectRenderer) void,
) ![]u8 {
    const gl = rr.gl;
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
    rr.begin(w, h, clear);
    scene(rr);
    glFinish();
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
    flipY(out, w, h);
    return out;
}

// === Slice 5: glyph atlas text ==============================================
// Reuses the raster font rasterizer (font/raster.zig) to produce glyph
// alpha bitmaps, shelf-packs ASCII 32..126 into one RGBA atlas texture
// (rgb=255, a=coverage), and draws text as a batch of textured quads
// tinted by the text color. The same atlas approach serves every GPU
// backend; non-ASCII/dynamic glyphs are a follow-up.

const ttf = @import("../font/ttf.zig");
const grast = @import("../font/raster.zig");
const gatlas = @import("../font/atlas.zig");
const fontset = @import("../font/fontset.zig");

const GL_TRIANGLES: GLenum = 0x0004;
const atlas_dim: u32 = 512;

pub const GlyphRenderer = struct {
    gl: Gl,
    gpa: std.mem.Allocator,
    program: GLuint,
    vao: GLuint,
    vbo: GLuint,
    atlas_tex: GLuint,
    pos_loc: GLuint,
    uv_loc: GLuint,
    u_viewport: GLint,
    u_color: GLint,
    atlas: gatlas.Atlas,
    vw: f32 = 0,
    vh: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, set: *const fontset.FontSet, size_px: f32) !GlyphRenderer {
        const gl = try Gl.load();
        const vs = QuadRenderer.compile(gl, GL_VERTEX_SHADER, glyph_vert) orelse return error.NoContext;
        const fs = QuadRenderer.compile(gl, GL_FRAGMENT_SHADER, glyph_frag) orelse return error.NoContext;
        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var ok: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &ok);
        if (ok == 0) return error.NoContext;

        var atlas = try gatlas.Atlas.init(gpa, set, size_px, atlas_dim, atlas_dim);
        errdefer atlas.deinit();

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        var vbo: GLuint = 0;
        gl.genBuffers(1, @ptrCast(&vbo));
        var tex: GLuint = 0;
        gl.genTextures(1, @ptrCast(&tex));
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(atlas_dim), @intCast(atlas_dim), 0, GL_RGBA, GL_UNSIGNED_BYTE, atlas.pixels.ptr);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        atlas.dirty = false; // just uploaded the (empty) atlas

        return .{
            .gl = gl,
            .gpa = gpa,
            .program = prog,
            .vao = vao,
            .vbo = vbo,
            .atlas_tex = tex,
            .pos_loc = @intCast(gl.getAttribLocation(prog, "pos")),
            .uv_loc = @intCast(gl.getAttribLocation(prog, "uv")),
            .u_viewport = gl.getUniformLocation(prog, "viewport"),
            .u_color = gl.getUniformLocation(prog, "color"),
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *GlyphRenderer) void {
        self.atlas.deinit();
    }

    pub fn begin(self: *GlyphRenderer, w: u32, h: u32) void {
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        self.gl.useProgram(self.program);
        self.gl.uniform2f(self.u_viewport, self.vw, self.vh);
        enableBlend();
    }

    /// Draw `text` (UTF-8, any codepoint) with its top-left at (x,y) px
    /// (baseline = y + ascent), tinted `color`. Glyphs rasterized + packed on
    /// demand into the dynamic atlas (#114); the texture is re-uploaded before
    /// the draw when new glyphs appear (GL is immediate; the atlas appends).
    pub fn drawText(self: *GlyphRenderer, gpa: std.mem.Allocator, x: f32, y: f32, text: []const u8, color: [4]f32, fstyle: fontset.Style) !void {
        const gl = self.gl;
        var verts: std.ArrayList(f32) = .empty;
        defer verts.deinit(gpa);
        var pen = x;
        const baseline = y + self.atlas.ascent;
        var prev_cp: ?u21 = null;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            if (prev_cp) |pc| pen += self.atlas.kernCp(pc, cp, fstyle); // #116
            const e = self.atlas.glyphForCp(cp, fstyle);
            if (e.w > 0) {
                const gx = @round(pen) + e.x_off;
                const gy = @round(baseline) + e.y_off;
                const x1 = gx + e.w;
                const y1 = gy + e.h;
                // 2 triangles: pos.xy, uv.xy.
                const quad = [_]f32{
                    gx, gy, e.u0, e.v0,
                    x1, gy, e.u1, e.v0,
                    gx, y1, e.u0, e.v1,
                    x1, gy, e.u1, e.v0,
                    x1, y1, e.u1, e.v1,
                    gx, y1, e.u0, e.v1,
                };
                try verts.appendSlice(gpa, &quad);
            }
            pen += e.advance;
            prev_cp = cp;
        }
        if (verts.items.len == 0) return;
        if (self.atlas.dirty) {
            gl.bindTexture(GL_TEXTURE_2D, self.atlas_tex);
            gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(self.atlas.width), @intCast(self.atlas.height), 0, GL_RGBA, GL_UNSIGNED_BYTE, self.atlas.pixels.ptr);
            self.atlas.dirty = false;
        }
        gl.bindVertexArray(self.vao);
        gl.bindBuffer(GL_ARRAY_BUFFER, self.vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @intCast(verts.items.len * 4), verts.items.ptr, GL_STATIC_DRAW);
        gl.vertexAttribPointer(self.pos_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(0));
        gl.enableVertexAttribArray(self.pos_loc);
        gl.vertexAttribPointer(self.uv_loc, 2, GL_FLOAT, GL_FALSE, 16, @ptrFromInt(8));
        gl.enableVertexAttribArray(self.uv_loc);
        gl.activeTexture(GL_TEXTURE0);
        gl.bindTexture(GL_TEXTURE_2D, self.atlas_tex);
        gl.uniform1i(gl.getUniformLocation(self.program, "atlas"), 0);
        gl.uniform4f(self.u_color, color[0], color[1], color[2], color[3]);
        gl.drawArrays(GL_TRIANGLES, 0, @intCast(verts.items.len / 4));
    }
};

const glyph_vert: [*:0]const u8 =
    \\#version 120
    \\attribute vec2 pos;
    \\attribute vec2 uv;
    \\uniform vec2 viewport;
    \\varying vec2 v_uv;
    \\void main() {
    \\  v_uv = uv;
    \\  vec2 ndc = vec2(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0);
    \\  gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;
const glyph_frag: [*:0]const u8 =
    \\#version 120
    \\varying vec2 v_uv;
    \\uniform sampler2D atlas;
    \\uniform vec4 color;
    \\void main() {
    \\  float a = texture2D(atlas, v_uv).a;
    \\  gl_FragColor = vec4(color.rgb, color.a * a);
    \\}
;

/// Offscreen FBO render of one text string (glyph atlas) + readback
/// (top-down). Headless path for golden tests.
pub fn renderTextOffscreen(gpa: std.mem.Allocator, gr: *GlyphRenderer, w: u32, h: u32, clear: [4]f32, x: f32, y: f32, text: []const u8, color: [4]f32) ![]u8 {
    const gl = gr.gl;
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
    glClearColor(clear[0], clear[1], clear[2], clear[3]);
    glClear(GL_COLOR_BUFFER_BIT);
    gr.begin(w, h);
    try gr.drawText(gpa, x, y, text, color, .{});
    glFinish();
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
    flipY(out, w, h);
    return out;
}

/// Write RGBA (top-down) as binary PPM (P6) for visual inspection.
pub fn writePpmRgba(writer: *std.Io.Writer, rgba: []const u8, w: u32, h: u32) std.Io.Writer.Error!void {
    try writer.print("P6\n{d} {d}\n255\n", .{ w, h });
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) try writer.writeAll(rgba[i .. i + 3]);
}

// === Slice 6: the GL Backend vtable =========================================
// Implements the draw-primitive Backend interface (backend.zig) on the
// GL renderers, so layout.render() drives GL directly. Renders to an
// offscreen FBO (headless golden tests); the windowed/runWindow path +
// raster fallback is the next slice. drawRect routes solid→RectRenderer
// (hard edges, matches raster) and bg/border/radius→RoundedRectRenderer;
// clip → glScissor (intersection stack, GL y-flip); text → per-size glyph
// atlas cache. Per-side borders / per-corner radii approximate to uniform
// (a refinement); validated against raster goldens within tolerance.

extern fn glScissor(c_int, c_int, c_int, c_int) void;
extern fn glDisable(c_uint) void;
const GL_SCISSOR_TEST: c_uint = 0x0C11;

const Backend = backend_mod.Backend;

const ScissorRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// A pushed group-opacity layer (#121): its offscreen FBO + color texture and
/// the framebuffer it redirected from (composited back into on popLayer).
const LayerState = struct { fbo: GLuint, tex: GLuint, parent_fbo: GLuint, opacity: f32 };

/// A pushed rounded clip (#117): like a layer, composited back masked to the
/// rounded rect on popClip.
const RoundState = struct { fbo: GLuint, tex: GLuint, parent_fbo: GLuint, rect: geometry.Rect, radius: style.CornerRadius };

/// Which stack a popClip unwinds: a plain scissor entry or a rounded-clip layer.
const ClipOp = enum { scissor, rounded };

pub const GlBackend = struct {
    gpa: std.mem.Allocator,
    /// Owned hidden window for the offscreen/golden path; null when the
    /// platform owns the window + context (the runWindow GPU-present path).
    win: ?GlWindow = null,
    rect: RectRenderer,
    exact: ExactRectRenderer,
    image: ImageRenderer,
    grad: GradientRenderer,
    shadow: ShadowRenderer,
    path: PathRenderer,
    stroke: StrokeRenderer,
    comp: LayerCompositor,
    rclip: RoundClipCompositor,
    /// Active group-opacity layers (#121): each holds its offscreen FBO +
    /// texture and the framebuffer to composite back into on popLayer.
    layers: std.ArrayList(LayerState) = .empty,
    /// Active rounded clips (#117) and a per-clip-op marker so popClip unwinds
    /// the right stack.
    rounds: std.ArrayList(RoundState) = .empty,
    clip_ops: std.ArrayList(ClipOp) = .empty,
    /// The framebuffer currently bound for draws (frame FBO, 0, or a layer).
    bound_fbo: GLuint = 0,
    /// When true, render straight to the window's default framebuffer
    /// (fbo 0) instead of an offscreen FBO — the GPU-present path. The
    /// pixel→NDC mapping is identical, so output is upright on screen.
    default_fb: bool = false,
    fbo: GLuint = 0,
    target: GLuint = 0,
    width: u32 = 0,
    height: u32 = 0,
    clips: std.ArrayList(ScissorRect) = .empty,
    /// Window clear color (theming, #170 follow-up). Defaults to white so the
    /// offscreen golden path is unchanged; the windowed app sets it from the
    /// theme background. Only the default-framebuffer (present) path uses it.
    clear_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Content translation for scroll viewports (#96): added to draw coords and
    /// pushed scissor rects so a clipped subtree pans within a viewport.
    translate: geometry.Point = .{ .x = 0, .y = 0 },
    translate_stack: std.ArrayList(geometry.Point) = .empty,
    fonts: ?fontset.FontSet = null,
    glyphs: std.AutoHashMapUnmanaged(u32, GlyphRenderer) = .empty,

    /// Headless GL backend over an offscreen FBO (for golden tests). A hidden
    /// GLX window makes a context current before the renderers load.
    pub fn initOffscreen(gpa: std.mem.Allocator) !GlBackend {
        return .{
            .gpa = gpa,
            .win = try GlWindow.create("zooee-gl-backend", 16, 16),
            .rect = try RectRenderer.init(),
            .exact = try ExactRectRenderer.init(),
            .image = try ImageRenderer.init(),
            .grad = try GradientRenderer.init(),
            .shadow = try ShadowRenderer.init(),
            .path = try PathRenderer.init(),
            .stroke = try StrokeRenderer.init(),
            .comp = try LayerCompositor.init(),
            .rclip = try RoundClipCompositor.init(),
        };
    }

    /// GL backend that renders to the already-current context's default
    /// framebuffer — the platform (x11/macos) created the GL window and
    /// made its context current. Used by runWindow for GPU presentation.
    pub fn initOnCurrent(gpa: std.mem.Allocator) !GlBackend {
        return .{
            .gpa = gpa,
            .win = null,
            .rect = try RectRenderer.init(),
            .exact = try ExactRectRenderer.init(),
            .image = try ImageRenderer.init(),
            .grad = try GradientRenderer.init(),
            .shadow = try ShadowRenderer.init(),
            .path = try PathRenderer.init(),
            .stroke = try StrokeRenderer.init(),
            .comp = try LayerCompositor.init(),
            .rclip = try RoundClipCompositor.init(),
            .default_fb = true,
        };
    }

    pub fn deinit(self: *GlBackend) void {
        for (self.layers.items) |l| {
            self.comp.gl.deleteFramebuffers(1, @ptrCast(&l.fbo));
            self.comp.gl.deleteTextures(1, @ptrCast(&l.tex));
        }
        self.layers.deinit(self.gpa);
        for (self.rounds.items) |r| {
            self.comp.gl.deleteFramebuffers(1, @ptrCast(&r.fbo));
            self.comp.gl.deleteTextures(1, @ptrCast(&r.tex));
        }
        self.rounds.deinit(self.gpa);
        self.clip_ops.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.translate_stack.deinit(self.gpa);
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| g.deinit();
        self.glyphs.deinit(self.gpa);
        if (self.win) |*w| w.destroy();
    }

    pub fn setFont(self: *GlBackend, data: []const u8) !void {
        var set: fontset.FontSet = .{};
        set.setFace(fontset.FontSet.regular, try ttf.Font.parse(data));
        self.fonts = set;
    }

    pub fn setFontSet(self: *GlBackend, set: fontset.FontSet) void {
        self.fonts = set;
    }

    pub fn interface(self: *GlBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Read the FBO back as top-down RGBA (caller owns).
    pub fn readPixels(self: *GlBackend) ![]u8 {
        const out = try self.gpa.alloc(u8, @as(usize, self.width) * self.height * 4);
        glReadPixels(0, 0, self.width, self.height, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
        flipY(out, self.width, self.height);
        return out;
    }

    const vtable: Backend.VTable = .{
        .begin_frame = beginFrame,
        .end_frame = endFrame,
        .draw_rect = drawRect,
        .draw_text = drawText,
        .draw_image = drawImage,
        .draw_image_uv = drawImageUv,
        .fill_path = fillPath,
        .stroke_path = strokePath,
        .push_clip = pushClip,
        .pop_clip = popClip,
        .push_translate = pushTranslate,
        .pop_translate = popTranslate,
        .push_clip_rounded = pushClipRounded,
        .push_layer = pushLayer,
        .pop_layer = popLayer,
        .create_texture = createTexture,
        .destroy_texture = destroyTexture,
        .measure_text = measureText,
        .snap = snap,
    };

    fn self_(ptr: *anyopaque) *GlBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        const w: u32 = @intFromFloat(@max(1, @round(viewport.width)));
        const h: u32 = @intFromFloat(@max(1, @round(viewport.height)));
        const gl = self.rect.gl;
        if (self.default_fb) {
            // GPU-present path: draw straight to the window (fbo 0).
            self.width = w;
            self.height = h;
            gl.bindFramebuffer(GL_FRAMEBUFFER, 0);
            self.bound_fbo = 0;
            glViewport(0, 0, w, h);
            glDisable(GL_SCISSOR_TEST);
            glClearColor(self.clear_color[0], self.clear_color[1], self.clear_color[2], self.clear_color[3]);
            glClear(GL_COLOR_BUFFER_BIT);
            enableBlend();
            self.clips.clearRetainingCapacity();
            self.clip_ops.clearRetainingCapacity();
            return;
        }
        if (self.fbo == 0 or w != self.width or h != self.height) {
            if (self.fbo == 0) gl.genFramebuffers(1, @ptrCast(&self.fbo));
            gl.bindFramebuffer(GL_FRAMEBUFFER, self.fbo);
            if (self.target == 0) gl.genTextures(1, @ptrCast(&self.target));
            gl.bindTexture(GL_TEXTURE_2D, self.target);
            gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(w), @intCast(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
            gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, self.target, 0);
            self.width = w;
            self.height = h;
        }
        gl.bindFramebuffer(GL_FRAMEBUFFER, self.fbo);
        self.bound_fbo = self.fbo;
        glViewport(0, 0, w, h);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(1, 1, 1, 1); // match raster's white clear
        glClear(GL_COLOR_BUFFER_BIT);
        enableBlend();
        self.clips.clearRetainingCapacity();
        self.clip_ops.clearRetainingCapacity();
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(self.layers.items.len == 0); // balanced push/popLayer
        std.debug.assert(self.rounds.items.len == 0); // balanced rounded clips
        glFinish();
    }

    fn col(c: style.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c.r)) / 255,
            @as(f32, @floatFromInt(c.g)) / 255,
            @as(f32, @floatFromInt(c.b)) / 255,
            @as(f32, @floatFromInt(c.a)) / 255,
        };
    }

    /// Shift a rect by the active content translation (#96).
    fn offRect(self: *const GlBackend, r: geometry.Rect) geometry.Rect {
        return .{ .x = r.x + self.translate.x, .y = r.y + self.translate.y, .width = r.width, .height = r.height };
    }

    fn drawRect(ptr: *anyopaque, rect_in: geometry.Rect, rs: style.RectStyle) void {
        const self = self_(ptr);
        const rect = self.offRect(rect_in);
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        const rrect: [4]f32 = .{ rect.x, rect.y, rect.width, rect.height };
        // Outer shadow paints behind the fill.
        if (rs.shadow) |sh| if (!sh.inset) {
            enableBlend();
            self.shadow.vw = w;
            self.shadow.vh = h;
            const margin = sh.blur * 2 + @abs(sh.spread) + 2;
            const quad: [4]f32 = .{ rect.x + sh.dx - sh.spread - margin, rect.y + sh.dy - sh.spread - margin, rect.width + 2 * (sh.spread + margin), rect.height + 2 * (sh.spread + margin) };
            self.shadow.draw(quad, rrect, .{ sh.dx, sh.dy, sh.blur, sh.spread }, col(sh.color), sh.corner_radius, false);
        };
        // Fill.
        if (rs.gradient) |g| {
            enableBlend();
            self.grad.vw = w;
            self.grad.vh = h;
            self.grad.fill(rect, g);
        } else if (rs.corner_radius.isNone() and rs.border.isNone()) {
            if (rs.background) |bg| {
                const rr = &self.rect;
                rr.gl.useProgram(rr.program);
                rr.vw = w;
                rr.vh = h;
                rr.gl.uniform2f(rr.u_viewport, w, h);
                rr.fillRect(rect.x, rect.y, rect.width, rect.height, col(bg));
            }
        } else {
            // bg + border + radius via the exact renderer (hard-edged).
            enableBlend();
            self.exact.draw(w, h, rect, rs);
        }
        // Inset shadow paints on top, clipped to the rect's rounded shape.
        if (rs.shadow) |sh| if (sh.inset) {
            enableBlend();
            self.shadow.vw = w;
            self.shadow.vh = h;
            self.shadow.draw(rrect, rrect, .{ sh.dx, sh.dy, sh.blur, sh.spread }, col(sh.color), sh.corner_radius, true);
        };
    }

    fn glyphFor(self: *GlBackend, size_px: u16) ?*GlyphRenderer {
        if (self.fonts == null) return null;
        if (self.glyphs.getPtr(size_px)) |g| return g;
        const g = GlyphRenderer.init(self.gpa, &self.fonts.?, @floatFromInt(size_px)) catch return null;
        self.glyphs.put(self.gpa, size_px, g) catch return null;
        return self.glyphs.getPtr(size_px);
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, ts: style.TextStyle) void {
        const self = self_(ptr);
        const size_px: u16 = @intFromFloat(@max(4, ts.size));
        const gr = self.glyphFor(size_px) orelse return;
        gr.gl.useProgram(gr.program);
        gr.vw = @floatFromInt(self.width);
        gr.vh = @floatFromInt(self.height);
        gr.gl.uniform2f(gr.u_viewport, gr.vw, gr.vh);
        enableBlend();
        const color = ts.color orelse style.Color.black;
        gr.drawText(self.gpa, origin.x + self.translate.x, origin.y + self.translate.y, text, col(color), .{ .bold = ts.bold, .italic = ts.italic }) catch {};
        // Text decorations (#191): a filled line, same geometry as raster.
        if (ts.underline or ts.strikethrough) {
            const rw = self.fonts.?.measure(text, ts.size, .{ .bold = ts.bold, .italic = ts.italic }).width;
            const bx = origin.x + self.translate.x;
            const baseline = origin.y + self.translate.y + gr.atlas.ascent;
            const c = col(color);
            const rr = &self.rect;
            rr.gl.useProgram(rr.program);
            rr.vw = @floatFromInt(self.width);
            rr.vh = @floatFromInt(self.height);
            rr.gl.uniform2f(rr.u_viewport, rr.vw, rr.vh);
            if (ts.underline) {
                const r = style.TextDecoration.underlineRect(bx, baseline, rw, ts.size);
                rr.fillRect(r.x, r.y, r.width, r.height, c);
            }
            if (ts.strikethrough) {
                const r = style.TextDecoration.strikeRect(bx, baseline, rw, ts.size);
                rr.fillRect(r.x, r.y, r.width, r.height, c);
            }
        }
    }

    fn drawImage(ptr: *anyopaque, rect: geometry.Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        enableBlend();
        self.image.draw(@floatFromInt(self.width), @floatFromInt(self.height), self.offRect(rect), @intCast(@intFromPtr(texture)));
    }

    fn drawImageUv(ptr: *anyopaque, dst: geometry.Rect, texture: *Backend.Texture, src: geometry.Rect, sampling: Backend.Sampling) void {
        const self = self_(ptr);
        enableBlend();
        self.image.drawUv(@floatFromInt(self.width), @floatFromInt(self.height), self.offRect(dst), src, @intCast(@intFromPtr(texture)), sampling);
    }

    /// Copy `points` shifted by the content translation into `buf` (#96).
    fn offPoints(self: *const GlBackend, points: []const geometry.Point, buf: []geometry.Point) []geometry.Point {
        const n = @min(points.len, buf.len);
        for (0..n) |k| buf[k] = .{ .x = points[k].x + self.translate.x, .y = points[k].y + self.translate.y };
        return buf[0..n];
    }

    fn fillPath(ptr: *anyopaque, points: []const geometry.Point, color: style.Color) void {
        const self = self_(ptr);
        enableBlend();
        self.path.vw = @floatFromInt(self.width);
        self.path.vh = @floatFromInt(self.height);
        var buf: [256]geometry.Point = undefined;
        self.path.fill(self.offPoints(points, &buf), col(color));
    }

    fn strokePath(ptr: *anyopaque, points: []const geometry.Point, width: f32, color: style.Color, closed: bool) void {
        const self = self_(ptr);
        enableBlend();
        self.stroke.vw = @floatFromInt(self.width);
        self.stroke.vh = @floatFromInt(self.height);
        var buf: [256]geometry.Point = undefined;
        self.stroke.stroke(self.offPoints(points, &buf), width * 0.5, col(color), closed);
    }

    fn applyScissor(self: *GlBackend) void {
        if (self.clips.items.len == 0) {
            glDisable(GL_SCISSOR_TEST);
            return;
        }
        var s: ScissorRect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
        for (self.clips.items) |c| {
            s.x0 = @max(s.x0, c.x0);
            s.y0 = @max(s.y0, c.y0);
            s.x1 = @min(s.x1, c.x1);
            s.y1 = @min(s.y1, c.y1);
        }
        glEnable(GL_SCISSOR_TEST);
        // GL scissor origin is bottom-left; our rects are top-left.
        const gh: i32 = @intCast(self.height);
        const sw = @max(0, s.x1 - s.x0);
        const sh = @max(0, s.y1 - s.y0);
        glScissor(s.x0, gh - s.y1, sw, sh);
    }

    fn pushClip(ptr: *anyopaque, rect_in: geometry.Rect) void {
        const self = self_(ptr);
        const rect = self.offRect(rect_in);
        self.clips.append(self.gpa, .{
            .x0 = @intFromFloat(@round(rect.x)),
            .y0 = @intFromFloat(@round(rect.y)),
            .x1 = @intFromFloat(@round(rect.x + rect.width)),
            .y1 = @intFromFloat(@round(rect.y + rect.height)),
        }) catch {};
        self.clip_ops.append(self.gpa, .scissor) catch {};
        self.applyScissor();
    }

    fn pushTranslate(ptr: *anyopaque, dx: f32, dy: f32) void {
        const self = self_(ptr);
        self.translate_stack.append(self.gpa, self.translate) catch return;
        self.translate.x += dx;
        self.translate.y += dy;
    }

    fn popTranslate(ptr: *anyopaque) void {
        const self = self_(ptr);
        if (self.translate_stack.pop()) |prev| self.translate = prev;
    }

    /// Rounded clip (#117): redirect draws into an offscreen FBO (like
    /// pushLayer); popClip composites it back masked to the rounded rect.
    fn pushClipRounded(ptr: *anyopaque, rect_in: geometry.Rect, radius: style.CornerRadius) void {
        const self = self_(ptr);
        if (radius.isNone()) return pushClip(ptr, rect_in);
        const rect = self.offRect(rect_in);
        const gl = self.comp.gl;
        var fbo: GLuint = 0;
        var tex: GLuint = 0;
        gl.genFramebuffers(1, @ptrCast(&fbo));
        gl.genTextures(1, @ptrCast(&tex));
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(self.width), @intCast(self.height), 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.bindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        self.rounds.append(self.gpa, .{ .fbo = fbo, .tex = tex, .parent_fbo = self.bound_fbo, .rect = rect, .radius = radius }) catch {
            gl.deleteFramebuffers(1, @ptrCast(&fbo));
            gl.deleteTextures(1, @ptrCast(&tex));
            return;
        };
        self.clip_ops.append(self.gpa, .rounded) catch {};
        self.bound_fbo = fbo;
        glViewport(0, 0, self.width, self.height);
        glClearColor(0, 0, 0, 0); // transparent layer
        glClear(GL_COLOR_BUFFER_BIT);
        enableBlend();
        self.applyScissor();
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        const op = self.clip_ops.pop() orelse .scissor;
        switch (op) {
            .scissor => {
                if (self.clips.items.len > 0) _ = self.clips.pop();
                self.applyScissor();
            },
            .rounded => {
                const gl = self.comp.gl;
                const r = self.rounds.pop() orelse return;
                gl.bindFramebuffer(GL_FRAMEBUFFER, r.parent_fbo);
                self.bound_fbo = r.parent_fbo;
                glViewport(0, 0, self.width, self.height);
                self.applyScissor();
                enableBlend();
                self.rclip.vw = @floatFromInt(self.width);
                self.rclip.vh = @floatFromInt(self.height);
                self.rclip.composite(r.tex, r.rect, r.radius);
                gl.deleteFramebuffers(1, @ptrCast(&r.fbo));
                gl.deleteTextures(1, @ptrCast(&r.tex));
            },
        }
    }

    /// Redirect draws into a fresh transparent offscreen FBO (#121). The clip
    /// stack and viewport carry over; on popLayer the layer texture is
    /// composited back over the parent framebuffer at the layer opacity.
    fn pushLayer(ptr: *anyopaque, opacity: f32) Backend.Error!void {
        const self = self_(ptr);
        const gl = self.comp.gl;
        var fbo: GLuint = 0;
        var tex: GLuint = 0;
        gl.genFramebuffers(1, @ptrCast(&fbo));
        gl.genTextures(1, @ptrCast(&tex));
        gl.bindTexture(GL_TEXTURE_2D, tex);
        gl.texImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(self.width), @intCast(self.height), 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.bindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        self.layers.append(self.gpa, .{ .fbo = fbo, .tex = tex, .parent_fbo = self.bound_fbo, .opacity = opacity }) catch {
            gl.deleteFramebuffers(1, @ptrCast(&fbo));
            gl.deleteTextures(1, @ptrCast(&tex));
            return error.OutOfMemory;
        };
        self.bound_fbo = fbo;
        glViewport(0, 0, self.width, self.height);
        glClearColor(0, 0, 0, 0); // transparent layer
        glClear(GL_COLOR_BUFFER_BIT);
        enableBlend();
        self.applyScissor();
    }

    fn popLayer(ptr: *anyopaque) void {
        const self = self_(ptr);
        const gl = self.comp.gl;
        const l = self.layers.pop() orelse return;
        gl.bindFramebuffer(GL_FRAMEBUFFER, l.parent_fbo);
        self.bound_fbo = l.parent_fbo;
        glViewport(0, 0, self.width, self.height);
        self.applyScissor();
        enableBlend();
        self.comp.composite(l.tex, l.opacity);
        // The composite draw is issued; GL completes it before honoring the
        // deletes, so freeing now is safe.
        gl.deleteFramebuffers(1, @ptrCast(&l.fbo));
        gl.deleteTextures(1, @ptrCast(&l.tex));
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Backend.Error!*Backend.Texture {
        const self = self_(ptr);
        const tex = self.image.upload(width, height, rgba);
        return @ptrFromInt(tex);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const tex: GLuint = @intCast(@intFromPtr(texture));
        self.image.gl.deleteTextures(1, @ptrCast(&tex));
    }

    fn measureText(ptr: *anyopaque, text: []const u8, ts: style.TextStyle) geometry.Size {
        const self = self_(ptr);
        if (self.fonts) |*set| {
            const mtr = set.measure(text, ts.size, .{ .bold = ts.bold, .italic = ts.italic });
            return .{ .width = mtr.width, .height = mtr.height };
        }
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return .{ .width = @as(f32, @floatFromInt(n)) * 8, .height = 16 };
    }

    fn snap(ptr: *anyopaque, value: f32, axis: geometry.Axis) f32 {
        _ = ptr;
        _ = axis;
        return @round(value);
    }
};
