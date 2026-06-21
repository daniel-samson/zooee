//! macOS Metal backend (#101), slice 1 — bring-up.
//!
//! Replaces the legacy NSOpenGL present (#11) on macOS with Metal +
//! CAMetalLayer, whose present is display-synced (vblank) so live resize is
//! lag-free — the bar NSOpenGL couldn't clear. Slice 1 stands up the device,
//! command queue, an offscreen render target (clear + readback for headless
//! golden tests and ZOOEE_CAPTURE), and the on-view CAMetalLayer clear/present.
//!
//! Driven straight through the Objective-C runtime like macos.zig — no
//! MetalKit, no Xcode project (keeps the size budget, #14). macOS-only; gate
//! imports on builtin.os.tag.

const std = @import("std");
const builtin = @import("builtin");
const ttf = @import("../font/ttf.zig");
const grast = @import("../font/raster.zig");
const gatlas = @import("../font/atlas.zig");
const fontset = @import("../font/fontset.zig");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend_mod = @import("../backend.zig");
const Backend = backend_mod.Backend;

comptime {
    if (builtin.os.tag != .macos) @compileError("metal.zig is macOS-only; gate imports on builtin.os.tag");
}

pub const Error = error{ NoDevice, NoQueue, NoTexture, NoDrawable, ReadbackFailed, ShaderFailed };

// --- objc runtime (mirrors macos.zig) ---------------------------------------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;

extern "objc" fn objc_getClass([*:0]const u8) Class;
extern "objc" fn sel_registerName([*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

// Metal's only free function we need; everything else is objc messaging.
extern "c" fn MTLCreateSystemDefaultDevice() id;

fn msg(comptime Ret: type, comptime Args: type, target: anytype, selector: SEL, args: Args) Ret {
    const fields = @typeInfo(Args).@"struct".fields;
    const Fn = switch (fields.len) {
        0 => *const fn (@TypeOf(target), SEL) callconv(.c) Ret,
        1 => *const fn (@TypeOf(target), SEL, fields[0].type) callconv(.c) Ret,
        2 => *const fn (@TypeOf(target), SEL, fields[0].type, fields[1].type) callconv(.c) Ret,
        3 => *const fn (@TypeOf(target), SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) Ret,
        4 => *const fn (@TypeOf(target), SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) Ret,
        else => @compileError("unsupported arg count"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return switch (fields.len) {
        0 => f(target, selector),
        1 => f(target, selector, @field(args, "0")),
        2 => f(target, selector, @field(args, "0"), @field(args, "1")),
        3 => f(target, selector, @field(args, "0"), @field(args, "1"), @field(args, "2")),
        4 => f(target, selector, @field(args, "0"), @field(args, "1"), @field(args, "2"), @field(args, "3")),
        else => unreachable,
    };
}

fn sel(comptime name: [:0]const u8) SEL {
    return sel_registerName(name.ptr);
}

fn cls(comptime name: [:0]const u8) Class {
    return objc_getClass(name.ptr);
}

/// Push a fresh NSAutoreleasePool. Metal creates a swarm of autoreleased
/// objects per frame — the CAMetalDrawable from `nextDrawable`, render-pass
/// descriptors, command buffers — and without draining a pool each frame they
/// pile up until the layer's small drawable pool exhausts (the loop stalls) or
/// memory balloons. The run loop wraps every frame in push/drain. Returns the
/// pool to hand to `drainPool`.
pub fn pushPool() id {
    return msg(id, struct {}, msg(id, struct {}, cls("NSAutoreleasePool"), sel("alloc"), .{}), sel("init"), .{});
}

pub fn drainPool(pool: id) void {
    _ = msg(void, struct {}, pool, sel("drain"), .{});
}

fn nsString(text: [*:0]const u8) id {
    return msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{text});
}

// --- Metal enums / structs --------------------------------------------------

// MTLPixelFormat: RGBA8Unorm=70 (offscreen, matches raster RGBA byte order),
// BGRA8Unorm=80 (required by CAMetalLayer for the window).
const MTLPixelFormatRGBA8Unorm: u64 = 70;
const MTLPixelFormatBGRA8Unorm: u64 = 80;
const MTLLoadActionLoad: u64 = 1;
const MTLLoadActionClear: u64 = 2;
const MTLStoreActionStore: u64 = 1;
const MTLPrimitiveTypeTriangleStrip: u64 = 4;
const MTLSamplerMinMagFilterNearest: u64 = 0;
const MTLSamplerMinMagFilterLinear: u64 = 1;
const MTLTextureUsageShaderRead: u64 = 1;
const MTLTextureUsageRenderTarget: u64 = 4;
const MTLStorageModeShared: u64 = 0; // CPU+GPU shared (Apple Silicon) → getBytes w/o sync
const MTLStorageModeShift: u64 = 4; // resourceOptions = storageMode << 4

const MTLClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const MTLOrigin = extern struct { x: u64, y: u64, z: u64 };
const MTLSize = extern struct { width: u64, height: u64, depth: u64 };
const MTLRegion = extern struct { origin: MTLOrigin, size: MTLSize };

// --- shared device + queue --------------------------------------------------

/// A Metal device + command queue. Borrowed by the offscreen RT and the
/// window layer; both need the same device to share textures.
pub const MetalContext = struct {
    device: id,
    queue: id,

    pub fn create() Error!MetalContext {
        const device = MTLCreateSystemDefaultDevice();
        if (device == null) return error.NoDevice;
        const queue = msg(id, struct {}, device, sel("newCommandQueue"), .{});
        if (queue == null) return error.NoQueue;
        return .{ .device = device, .queue = queue };
    }

    pub fn destroy(self: *MetalContext) void {
        release(self.queue);
        release(self.device);
    }
};

fn release(obj: id) void {
    if (obj != null) _ = msg(void, struct {}, obj, sel("release"), .{});
}

/// Clear `texture` to a color via a render pass (no draws) on `queue`. When
/// `present_drawable` is non-null, the command buffer also presents it (the
/// window path); `wait` blocks until completion (needed before readback).
fn clearPass(queue: id, texture: id, color: MTLClearColor, present_drawable: id, wait: bool) void {
    const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
    const attachments = msg(id, struct {}, rpd, sel("colorAttachments"), .{});
    const a0 = msg(id, struct { u64 }, attachments, sel("objectAtIndexedSubscript:"), .{0});
    _ = msg(void, struct { id }, a0, sel("setTexture:"), .{texture});
    _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
    _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
    _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{color});

    const cmdbuf = msg(id, struct {}, queue, sel("commandBuffer"), .{});
    const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
    _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
    if (present_drawable != null) _ = msg(void, struct { id }, cmdbuf, sel("presentDrawable:"), .{present_drawable});
    _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
    if (wait) _ = msg(void, struct {}, cmdbuf, sel("waitUntilCompleted"), .{});
}

// --- offscreen render target (headless: golden tests + ZOOEE_CAPTURE) -------

pub const MetalOffscreen = struct {
    ctx: MetalContext,
    target: id, // MTLTexture, RGBA8, Shared storage
    width: u32,
    height: u32,
    owns_ctx: bool,

    /// Headless: owns its own device/queue.
    pub fn create(width: u32, height: u32) Error!MetalOffscreen {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        const target = try makeTexture(ctx.device, width, height, MTLPixelFormatRGBA8Unorm);
        return .{ .ctx = ctx, .target = target, .width = width, .height = height, .owns_ctx = true };
    }

    pub fn destroy(self: *MetalOffscreen) void {
        release(self.target);
        if (self.owns_ctx) self.ctx.destroy();
    }

    pub fn clear(self: *MetalOffscreen, r: f32, g: f32, b: f32, a: f32) void {
        clearPass(self.ctx.queue, self.target, .{ .red = r, .green = g, .blue = b, .alpha = a }, null, true);
    }

    /// Read the target back as RGBA8, top-down. Caller owns the slice.
    pub fn readPixels(self: *MetalOffscreen, gpa: std.mem.Allocator) ![]u8 {
        const bpr: u64 = @as(u64, self.width) * 4;
        const buf = try gpa.alloc(u8, @as(usize, self.width) * self.height * 4);
        errdefer gpa.free(buf);
        const region: MTLRegion = .{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, self.target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, bpr, region, 0 });
        return buf;
    }
};

fn makeTexture(device: id, width: u32, height: u32, pixel_format: u64) Error!id {
    const desc = msg(id, struct { u64, u64, u64, bool }, cls("MTLTextureDescriptor"), sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), .{ pixel_format, @as(u64, width), @as(u64, height), false });
    _ = msg(void, struct { u64 }, desc, sel("setUsage:"), .{MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead});
    _ = msg(void, struct { u64 }, desc, sel("setStorageMode:"), .{MTLStorageModeShared});
    const tex = msg(id, struct { id }, device, sel("newTextureWithDescriptor:"), .{desc});
    if (tex == null) return error.NoTexture;
    return tex;
}

// --- window layer (on-screen present) ---------------------------------------

const CGSize = extern struct { width: f64, height: f64 };

/// A CAMetalLayer attached to an NSView for on-screen present (BGRA8). Borrows
/// a device (must be the same one the MetalBackend renders on, so its RT can
/// be sampled into the drawable). MetalBackend.presentTo drives the drawable.
pub const MetalLayer = struct {
    layer: id, // CAMetalLayer
    width: u32,
    height: u32,

    /// Attach a CAMetalLayer (on `device`) to `view` (an NSView id), sized
    /// `width`x`height` device pixels. `framebufferOnly=false` so the drawable
    /// can be a render target.
    pub fn createOnView(device: id, view: id, width: u32, height: u32) Error!MetalLayer {
        const layer = msg(id, struct {}, cls("CAMetalLayer"), sel("layer"), .{});
        if (layer == null) return error.NoDrawable;
        _ = msg(void, struct { id }, layer, sel("setDevice:"), .{device});
        _ = msg(void, struct { u64 }, layer, sel("setPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
        _ = msg(void, struct { bool }, layer, sel("setFramebufferOnly:"), .{false});
        // presentsWithTransaction is toggled per-frame in `presentTo`: false for
        // smooth, display-link-paced steady-state animation; true only during a
        // live-resize drag so the drawable lands in the resize's CATransaction
        // (no squash/stretch flash). See #170/#181 and [[live-resize-pattern]].
        _ = msg(void, struct { CGSize }, layer, sel("setDrawableSize:"), .{.{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        _ = msg(void, struct { bool }, view, sel("setWantsLayer:"), .{true});
        _ = msg(void, struct { id }, view, sel("setLayer:"), .{layer});
        return .{ .layer = layer, .width = width, .height = height };
    }

    pub fn resize(self: *MetalLayer, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.width = width;
        self.height = height;
        _ = msg(void, struct { CGSize }, self.layer, sel("setDrawableSize:"), .{.{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
    }

    fn nextDrawable(self: *MetalLayer) id {
        return msg(id, struct {}, self.layer, sel("nextDrawable"), .{});
    }
};

// --- pipeline / resource helpers --------------------------------------------

// MTLBlendFactor / MTLBlendOperation for standard (straight-alpha) source-over.
const MTLBlendFactorOne: u64 = 1;
const MTLBlendFactorSourceAlpha: u64 = 4;
const MTLBlendFactorOneMinusSourceAlpha: u64 = 5;

/// Compile an MSL source string and build a render pipeline state from its
/// `v_main`/`f_main` functions, targeting `pixel_format`. With `blend`, the
/// color attachment uses straight-alpha source-over (AA edges, text, images).
fn compilePipeline(device: id, source: [*:0]const u8, pixel_format: u64, blend: bool) Error!id {
    var err: id = null;
    const library = msg(id, struct { id, id, *id }, device, sel("newLibraryWithSource:options:error:"), .{ nsString(source), null, &err });
    if (library == null) return error.ShaderFailed;
    const vfn = msg(id, struct { id }, library, sel("newFunctionWithName:"), .{nsString("v_main")});
    const ffn = msg(id, struct { id }, library, sel("newFunctionWithName:"), .{nsString("f_main")});
    if (vfn == null or ffn == null) return error.ShaderFailed;

    const desc = msg(id, struct {}, msg(id, struct {}, cls("MTLRenderPipelineDescriptor"), sel("alloc"), .{}), sel("init"), .{});
    _ = msg(void, struct { id }, desc, sel("setVertexFunction:"), .{vfn});
    _ = msg(void, struct { id }, desc, sel("setFragmentFunction:"), .{ffn});
    const attachments = msg(id, struct {}, desc, sel("colorAttachments"), .{});
    const a0 = msg(id, struct { u64 }, attachments, sel("objectAtIndexedSubscript:"), .{0});
    _ = msg(void, struct { u64 }, a0, sel("setPixelFormat:"), .{pixel_format});
    if (blend) {
        _ = msg(void, struct { bool }, a0, sel("setBlendingEnabled:"), .{true});
        _ = msg(void, struct { u64 }, a0, sel("setSourceRGBBlendFactor:"), .{MTLBlendFactorSourceAlpha});
        _ = msg(void, struct { u64 }, a0, sel("setDestinationRGBBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});
        _ = msg(void, struct { u64 }, a0, sel("setSourceAlphaBlendFactor:"), .{MTLBlendFactorOne});
        _ = msg(void, struct { u64 }, a0, sel("setDestinationAlphaBlendFactor:"), .{MTLBlendFactorOneMinusSourceAlpha});
    }

    const pipeline = msg(id, struct { id, *id }, device, sel("newRenderPipelineStateWithDescriptor:error:"), .{ desc, &err });
    if (pipeline == null) return error.ShaderFailed;
    return pipeline;
}

/// Upload RGBA8 (top-down) into a sampled texture.
fn uploadTexture(device: id, rgba: []const u8, w: u32, h: u32) Error!id {
    const tex = try makeTexture(device, w, h, MTLPixelFormatRGBA8Unorm);
    const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = w, .height = h, .depth = 1 } };
    _ = msg(void, struct { MTLRegion, u64, [*]const u8, u64 }, tex, sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), .{ region, 0, rgba.ptr, @as(u64, w) * 4 });
    return tex;
}

fn makeSampler(device: id) id {
    return makeSamplerFilter(device, MTLSamplerMinMagFilterNearest);
}

fn makeSamplerFilter(device: id, filter: u64) id {
    const desc = msg(id, struct {}, msg(id, struct {}, cls("MTLSamplerDescriptor"), sel("alloc"), .{}), sel("init"), .{});
    _ = msg(void, struct { u64 }, desc, sel("setMinFilter:"), .{filter});
    _ = msg(void, struct { u64 }, desc, sel("setMagFilter:"), .{filter});
    return msg(id, struct { id }, device, sel("newSamplerStateWithDescriptor:"), .{desc});
}

// --- slice 2: textured quad -------------------------------------------------

/// Sample a CPU image through the shader/texture pipeline into a render
/// target — proves the MSL/pipeline/vertex-buffer machinery (slice 2). The
/// later rect/glyph/image renderers reuse the same scaffolding.
pub const MetalQuadRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    sampler: id,
    verts: id, // vertex buffer: 4 × float4 (xy = clip pos, zw = uv)

    // NEAREST, full-RT triangle strip. uv.y is set so the readback (top-down)
    // matches the source's top-down byte order: clip-top (+y) → uv.y 0.
    const quad = [_]f32{
        -1, -1, 0, 1, // bottom-left
        1, -1, 1, 1, // bottom-right
        -1, 1, 0, 0, // top-left
        1, 1, 1, 0, // top-right
    };

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], const device float4* v [[buffer(0)]]) {
        \\    VOut o; o.pos = float4(v[vid].xy, 0, 1); o.uv = v[vid].zw; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    return tex.sample(s, in.uv);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalQuadRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, false);
        const sampler = makeSampler(device);
        const verts = msg(id, struct { [*]const f32, u64, u64 }, device, sel("newBufferWithBytes:length:options:"), .{ &quad, @as(u64, @sizeOf(@TypeOf(quad))), 0 });
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .sampler = sampler, .verts = verts };
    }

    pub fn deinit(self: *MetalQuadRenderer) void {
        release(self.verts);
        release(self.sampler);
        release(self.pipeline);
    }

    /// Upload `rgba` (top-down), draw it 1:1 into a w×h target, read it back.
    pub fn renderOffscreen(self: *MetalQuadRenderer, gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
        const target = try makeTexture(self.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);
        const src_tex = try uploadTexture(self.device, rgba, w, h);
        defer release(src_tex);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = 0, .green = 0, .blue = 0, .alpha = 1 }});

        const cmdbuf = msg(id, struct {}, self.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.pipeline});
        _ = msg(void, struct { id, u64, u64 }, enc, sel("setVertexBuffer:offset:atIndex:"), .{ self.verts, 0, 0 });
        _ = msg(void, struct { id, u64 }, enc, sel("setFragmentTexture:atIndex:"), .{ src_tex, 0 });
        _ = msg(void, struct { id, u64 }, enc, sel("setFragmentSamplerState:atIndex:"), .{ self.sampler, 0 });
        _ = msg(void, struct { u64, u64, u64 }, enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
        _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("waitUntilCompleted"), .{});

        const bpr: u64 = @as(u64, w) * 4;
        const buf = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(buf);
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = w, .height = h, .depth = 1 } };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, bpr, region, 0 });
        return buf;
    }
};

// --- slice 3: native rect geometry ------------------------------------------

const RectUniform = extern struct { rect: [4]f32, viewport: [2]f32 }; // rect = x,y,w,h px

/// Fills axis-aligned rects in pixel coordinates (origin top-left) — the
/// workhorse for backgrounds and solid fills. A unit quad is transformed to
/// the rect in the vertex shader; the fragment is a flat color. Drives an
/// externally-supplied render encoder so the Backend can batch many fills
/// into one pass.
pub const MetalRectRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    // Transient per-pass state, set by renderOffscreen / the Backend.
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct RectU { float4 rect; float2 viewport; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant RectU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 px = u.rect.xy + corner[vid] * u.rect.zw;
        \\    return float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0, 1);
        \\}
        \\fragment float4 f_main(constant float4& color [[buffer(0)]]) { return color; }
    ;

    pub fn init(device: id, queue: id) Error!MetalRectRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, false);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalRectRenderer) void {
        release(self.pipeline);
    }

    /// Fill a pixel-space rect with a solid RGBA color on the active encoder.
    pub fn fillRect(self: *MetalRectRenderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        var u: RectUniform = .{ .rect = .{ x, y, w, h }, .viewport = .{ self.vw, self.vh } };
        var c = color;
        _ = msg(void, struct { *const RectUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RectUniform)), 0 });
        _ = msg(void, struct { *const [4]f32, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &c, 16, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }

    /// Render a scene of rects into a w×h target (cleared to `clear`) and read
    /// it back — the headless harness for the self-check and goldens.
    pub fn renderOffscreen(self: *MetalRectRenderer, gpa: std.mem.Allocator, w: u32, h: u32, clear: [4]f32, scene: *const fn (*MetalRectRenderer) void) ![]u8 {
        const target = try makeTexture(self.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.pipeline});
        self.enc = enc;
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        scene(self);
        self.enc = null;
        _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("waitUntilCompleted"), .{});

        const buf = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(buf);
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = w, .height = h, .depth = 1 } };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, @as(u64, w) * 4, region, 0 });
        return buf;
    }
};

// --- slice 4: rounded rect + border (SDF) -----------------------------------

const RoundUniform = extern struct {
    rect: [4]f32, // x, y, w, h px
    viewport: [2]f32,
    radius: f32,
    border: f32,
    bg: [4]f32,
    border_color: [4]f32,
};

/// Anti-aliased rounded rect with a uniform border in one blended draw —
/// matches raster's RectStyle (bg + corner_radius + border), the card/button
/// case. A signed-distance fragment gives the corners + border; AA over ~1px
/// via smoothstep (no fwidth — we render at known pixel scale). Ported from
/// the GL RoundedRectRenderer (#11). Per-side borders are a later refinement.
pub const MetalRoundedRectRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct RoundU { float4 rect; float2 viewport; float radius; float border; float4 bg; float4 border_color; };
        \\struct VOut { float4 pos [[position]]; float2 local; };
        \\vertex VOut v_main(uint vid [[vertex_id]], constant RoundU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 c = corner[vid];
        \\    float2 px = u.rect.xy + c * u.rect.zw;
        \\    VOut o;
        \\    o.pos = float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0, 1);
        \\    o.local = (c - 0.5) * u.rect.zw;
        \\    return o;
        \\}
        \\static float sdRoundBox(float2 p, float2 b, float r) {
        \\    float2 q = abs(p) - b + float2(r);
        \\    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], constant RoundU& u [[buffer(0)]]) {
        \\    float2 half_size = u.rect.zw * 0.5;
        \\    float d = sdRoundBox(in.local, half_size, u.radius);
        \\    float outer = smoothstep(1.0, -1.0, d);
        \\    float fill = smoothstep(1.0, -1.0, d + u.border);
        \\    float4 col = mix(u.border_color, u.bg, fill);
        \\    col.a *= outer;
        \\    return col;
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalRoundedRectRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalRoundedRectRenderer) void {
        release(self.pipeline);
    }

    pub fn draw(self: *MetalRoundedRectRenderer, x: f32, y: f32, w: f32, h: f32, radius: f32, border: f32, bg: [4]f32, border_color: [4]f32) void {
        var u: RoundUniform = .{
            .rect = .{ x, y, w, h },
            .viewport = .{ self.vw, self.vh },
            .radius = radius,
            .border = border,
            .bg = bg,
            .border_color = border_color,
        };
        _ = msg(void, struct { *const RoundUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RoundUniform)), 0 });
        _ = msg(void, struct { *const RoundUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RoundUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }

    pub fn renderOffscreen(self: *MetalRoundedRectRenderer, gpa: std.mem.Allocator, w: u32, h: u32, clear: [4]f32, scene: *const fn (*MetalRoundedRectRenderer) void) ![]u8 {
        const target = try makeTexture(self.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.pipeline});
        self.enc = enc;
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        scene(self);
        self.enc = null;
        _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("waitUntilCompleted"), .{});

        const buf = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(buf);
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = w, .height = h, .depth = 1 } };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, @as(u64, w) * 4, region, 0 });
        return buf;
    }
};

// --- slice 5: glyph atlas text ----------------------------------------------
// Reuses the raster font rasterizer (font/raster.zig) for glyph alpha bitmaps,
// shelf-packs ASCII 32..126 into one RGBA atlas texture (rgb=255, a=coverage),
// and draws text as textured quads tinted by the color. Ported from the GL
// GlyphRenderer (#11); same atlas approach.

/// One positioned glyph in a cached shaped run (#264): which face/glyph and its
/// pen offset from the run start (kerning + advances already accumulated). The
/// expensive shaping (cmap/GPOS/GSUB/Arabic) is done once; draw just re-reads the
/// atlas entry (a cheap hash hit) and emits a quad at base + pen_rel.
const ShapedGlyph = struct { face_id: u8, glyph: u16, pen_rel: f32 };
const ShapeKey = struct { text: []const u8, bold: bool, italic: bool };
const ShapeCtx = struct {
    pub fn hash(_: ShapeCtx, k: ShapeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.text);
        h.update(&.{ @intFromBool(k.bold), @intFromBool(k.italic) });
        return h.final();
    }
    pub fn eql(_: ShapeCtx, a: ShapeKey, b: ShapeKey) bool {
        return a.bold == b.bold and a.italic == b.italic and std.mem.eql(u8, a.text, b.text);
    }
};

pub const MetalGlyphRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    atlas: gatlas.Atlas,
    atlas_tex: id,
    sampler: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,
    gpa: std.mem.Allocator,
    /// (text, style) → shaped run (#264). Size is fixed per renderer. Keys own
    /// their bytes; freed in deinit. Bounded at 8192 entries.
    shape_cache: std.HashMapUnmanaged(ShapeKey, []const ShapedGlyph, ShapeCtx, std.hash_map.default_max_load_percentage) = .empty,

    const dim: u32 = 512;

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], const device float4* v [[buffer(0)]], constant float2& viewport [[buffer(1)]]) {
        \\    float4 vert = v[vid];
        \\    VOut o;
        \\    o.pos = float4(vert.x / viewport.x * 2.0 - 1.0, 1.0 - vert.y / viewport.y * 2.0, 0, 1);
        \\    o.uv = vert.zw;
        \\    return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]], constant float4& color [[buffer(0)]]) {
        \\    float a = atlas.sample(s, in.uv).a;
        \\    return float4(color.rgb, color.a * a);
        \\}
    ;

    pub fn init(device: id, queue: id, gpa: std.mem.Allocator, set: *const fontset.FontSet, size_px: f32) !MetalGlyphRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        var atlas = try gatlas.Atlas.init(gpa, set, size_px, dim, dim);
        errdefer atlas.deinit();
        const atlas_tex = try makeTexture(device, dim, dim, MTLPixelFormatRGBA8Unorm);
        const sampler = makeSampler(device);
        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .atlas = atlas,
            .atlas_tex = atlas_tex,
            .sampler = sampler,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *MetalGlyphRenderer) void {
        self.clearShapeCache(self.gpa); // free cached runs + keys (#264)
        self.shape_cache.deinit(self.gpa);
        release(self.sampler);
        release(self.atlas_tex);
        release(self.pipeline);
        self.atlas.deinit();
    }

    /// Upload the atlas to its GPU texture if new glyphs were packed. MUST be
    /// called after endEncoding but before commit: the atlas only ever appends
    /// (never moves existing glyphs), so the already-encoded quads read the
    /// final atlas content correctly when the command buffer runs — no latency,
    /// no pass split.
    pub fn uploadIfDirty(self: *MetalGlyphRenderer) void {
        if (!self.atlas.dirty) return;
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = self.atlas.width, .height = self.atlas.height, .depth = 1 } };
        _ = msg(void, struct { MTLRegion, u64, [*]const u8, u64 }, self.atlas_tex, sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), .{ region, 0, self.atlas.pixels.ptr, @as(u64, self.atlas.width) * 4 });
        self.atlas.dirty = false;
    }

    /// Draw `text` (UTF-8, any codepoint) with top-left at (x,y) px (baseline =
    /// y + ascent), tinted `color`. Glyphs are rasterized + packed on demand
    /// into the dynamic atlas (#114); call uploadIfDirty before commit.
    /// The shaped run for (text, style), built once and memoized (#264). Pen
    /// offsets are relative to the run start, so the cached run is reusable at any
    /// draw position. Shaping (cmap/GPOS/GSUB/Arabic) is the costly part skipped
    /// on a hit; the per-glyph atlas lookup at draw is a cheap hash hit.
    fn shapedRun(self: *MetalGlyphRenderer, gpa: std.mem.Allocator, text: []const u8, fstyle: fontset.Style) ![]const ShapedGlyph {
        const key: ShapeKey = .{ .text = text, .bold = fstyle.bold, .italic = fstyle.italic };
        if (self.shape_cache.getContext(key, .{})) |run| return run;
        var list: std.ArrayList(ShapedGlyph) = .empty;
        errdefer list.deinit(gpa);
        var pen: f32 = 0;
        var prev: ?fontset.Glyph = null;
        var sh = fontset.Shaper.init(self.atlas.set, fstyle, text);
        while (sh.next()) |g| {
            if (prev) |pg| if (pg.face_id == g.face_id) {
                pen += self.atlas.kernGid(g.face_id, pg.glyph, g.glyph); // #116/#201
            };
            try list.append(gpa, .{ .face_id = g.face_id, .glyph = g.glyph, .pen_rel = pen });
            pen += self.atlas.glyphForGid(g.face_id, g.glyph).advance;
            prev = g;
        }
        const run = try list.toOwnedSlice(gpa);
        errdefer gpa.free(run);
        if (self.shape_cache.count() >= 8192) self.clearShapeCache(gpa);
        const owned = try gpa.dupe(u8, text);
        var k = key;
        k.text = owned;
        self.shape_cache.putContext(gpa, k, run, .{}) catch |e| {
            gpa.free(owned);
            return e;
        };
        return run;
    }

    /// Free cached shaped runs + their keys (#264).
    fn clearShapeCache(self: *MetalGlyphRenderer, gpa: std.mem.Allocator) void {
        var it = self.shape_cache.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.text);
            gpa.free(kv.value_ptr.*);
        }
        self.shape_cache.clearRetainingCapacity();
    }

    pub fn drawText(self: *MetalGlyphRenderer, gpa: std.mem.Allocator, x: f32, y: f32, text: []const u8, color: [4]f32, fstyle: fontset.Style) !void {
        const run = try self.shapedRun(gpa, text, fstyle);
        var verts: std.ArrayList(f32) = .empty;
        defer verts.deinit(gpa);
        const baseline = y + self.atlas.ascent;
        for (run) |sg| {
            const e = self.atlas.glyphForGid(sg.face_id, sg.glyph);
            if (e.w > 0) {
                const gx = @round(x + sg.pen_rel) + e.x_off;
                const gy = @round(baseline) + e.y_off;
                const x1 = gx + e.w;
                const y1 = gy + e.h;
                // 2 triangles: each vertex = pos.xy, uv.xy (a float4).
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
        }
        if (verts.items.len == 0) return;
        const vbuf = msg(id, struct { [*]const f32, u64, u64 }, self.device, sel("newBufferWithBytes:length:options:"), .{ verts.items.ptr, verts.items.len * 4, 0 });
        defer release(vbuf);
        var viewport = [2]f32{ self.vw, self.vh };
        var c = color;
        _ = msg(void, struct { id, u64, u64 }, self.enc, sel("setVertexBuffer:offset:atIndex:"), .{ vbuf, 0, 0 });
        _ = msg(void, struct { *const [2]f32, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &viewport, 8, 1 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentTexture:atIndex:"), .{ self.atlas_tex, 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentSamplerState:atIndex:"), .{ self.sampler, 0 });
        _ = msg(void, struct { *const [4]f32, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &c, 16, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ 3, 0, @as(u64, verts.items.len / 4) });
    }

    /// Headless: render one text string into a w×h target and read back.
    pub fn renderTextOffscreen(self: *MetalGlyphRenderer, gpa: std.mem.Allocator, w: u32, h: u32, clear: [4]f32, x: f32, y: f32, text: []const u8, color: [4]f32) ![]u8 {
        const target = try makeTexture(self.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.pipeline});
        self.enc = enc;
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        try self.drawText(gpa, x, y, text, color, .{});
        self.enc = null;
        _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
        self.uploadIfDirty(); // after endEncoding, before commit (see uploadIfDirty)
        _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
        _ = msg(void, struct {}, cmdbuf, sel("waitUntilCompleted"), .{});

        const buf = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(buf);
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = w, .height = h, .depth = 1 } };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, @as(u64, w) * 4, region, 0 });
        return buf;
    }
};

// --- slice 6: exact rect, image, and the MetalBackend vtable ----------------

fn col4(c: style.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255,
        @as(f32, @floatFromInt(c.g)) / 255,
        @as(f32, @floatFromInt(c.b)) / 255,
        @as(f32, @floatFromInt(c.a)) / 255,
    };
}

// Packed all-float4 uniform (16-byte aligned members → offsets match a Zig
// extern struct of [4]f32). viewport_hasbg = {vw, vh, has_bg, 0}.
const ExactUniform = extern struct {
    viewport_hasbg: [4]f32,
    rect: [4]f32,
    rad: [4]f32, // outer radii tl,tr,br,bl
    inner: [4]f32, // x,y,w,h
    irad: [4]f32, // inner radii
    bw: [4]f32, // border widths top,right,bottom,left
    bg: [4]f32,
    ct: [4]f32, // border colors top,right,bottom,left
    cr: [4]f32,
    cb: [4]f32,
    cl: [4]f32,
};

/// Hard-edged rect with per-side borders + per-corner radii, replicating
/// raster's insideRounded()/borderColorAt() per fragment (pixel-exact, no AA)
/// — the Backend's draw_rect path for bg+border+radius. Ported from the GL
/// ExactRectRenderer (#11). Metal's [[position]] is top-left/pixel-centered,
/// matching raster's (px,py) — no y-flip needed.
pub const MetalExactRectRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct U { float4 viewport_hasbg; float4 rect; float4 rad; float4 inner; float4 irad; float4 bw; float4 bg; float4 ct; float4 cr; float4 cb; float4 cl; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant U& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    // Inflate the quad 1px so the anti-aliased outer edge has fragments.
        \\    float2 px = u.rect.xy - 1.0 + corner[vid] * (u.rect.zw + 2.0);
        \\    return float4(px.x / u.viewport_hasbg.x * 2.0 - 1.0, 1.0 - px.y / u.viewport_hasbg.y * 2.0, 0, 1);
        \\}
        \\// IQ per-corner rounded-box SDF — mirrors raster.sdRoundRect exactly so
        \\// GPU==raster coverage holds. rd = (tl,tr,br,bl); y-down quadrant select.
        \\static float sdRoundRect(float4 r, float4 rd, float2 p) {
        \\    float2 hs = r.zw * 0.5;
        \\    float maxr = min(hs.x, hs.y);
        \\    float2 q = p - (r.xy + hs);
        \\    float rr = (q.x > 0.0) ? ((q.y > 0.0) ? rd.z : rd.y) : ((q.y > 0.0) ? rd.w : rd.x);
        \\    rr = min(rr, maxr);
        \\    float2 e = abs(q) - hs + rr;
        \\    return length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - rr;
        \\}
        \\static float covRR(float4 r, float4 rd, float2 p) { return clamp(0.5 - sdRoundRect(r, rd, p), 0.0, 1.0); }
        \\static float4 borderColorAt(constant U& u, float2 p) {
        \\    if (p.x < u.rect.x + u.rad.x && p.y < u.rect.y + u.rad.x) return (u.bw.x > 0.0) ? u.ct : u.cl;
        \\    if (p.x >= u.rect.x + u.rect.z - u.rad.y && p.y < u.rect.y + u.rad.y) return (u.bw.x > 0.0) ? u.ct : u.cr;
        \\    if (p.x >= u.rect.x + u.rect.z - u.rad.z && p.y >= u.rect.y + u.rect.w - u.rad.z) return (u.bw.z > 0.0) ? u.cb : u.cr;
        \\    if (p.x < u.rect.x + u.rad.w && p.y >= u.rect.y + u.rect.w - u.rad.w) return (u.bw.z > 0.0) ? u.cb : u.cl;
        \\    if (p.y < u.inner.y) return u.ct;
        \\    if (p.y >= u.inner.y + u.inner.w) return u.cb;
        \\    if (p.x < u.inner.x) return u.cl;
        \\    return u.cr;
        \\}
        \\fragment float4 f_main(float4 fragpos [[position]], constant U& u [[buffer(0)]]) {
        \\    float2 p = fragpos.xy;
        \\    float outer = covRR(u.rect, u.rad, p);
        \\    if (outer <= 0.0) discard_fragment();
        \\    bool has_border = (u.bw.x + u.bw.y + u.bw.z + u.bw.w) > 0.0;
        \\    float hasbg = u.viewport_hasbg.z;
        \\    if (has_border) {
        \\        // Single-fragment equivalent of raster's two-pass source-over
        \\        // (border ring under fill): Sa = ra+fa-ra*fa keeps a translucent
        \\        // fill from revealing the border beneath it.
        \\        float fill = covRR(u.inner, u.irad, p);
        \\        float ring = clamp(outer - fill, 0.0, 1.0);
        \\        float4 bcol = borderColorAt(u, p);
        \\        float ra = bcol.a * ring;
        \\        float fa = (hasbg > 0.5 ? u.bg.a : 0.0) * fill;
        \\        float Sa = ra + fa - ra * fa;
        \\        if (Sa <= 0.0) discard_fragment();
        \\        float3 Sp = u.bg.rgb * fa + bcol.rgb * ra * (1.0 - fa);
        \\        return float4(Sp / Sa, Sa);
        \\    }
        \\    if (hasbg <= 0.5) discard_fragment();
        \\    return float4(u.bg.rgb, u.bg.a * outer);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalExactRectRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalExactRectRenderer) void {
        release(self.pipeline);
    }

    pub fn draw(self: *MetalExactRectRenderer, rect: geometry.Rect, rs: style.RectStyle) void {
        const b = rs.border;
        const cr_ = rs.corner_radius;
        const inner = [4]f32{
            rect.x + b.left.width,
            rect.y + b.top.width,
            @max(0, rect.width - b.left.width - b.right.width),
            @max(0, rect.height - b.top.width - b.bottom.width),
        };
        const irad = [4]f32{
            @max(0, cr_.top_left - @max(b.top.width, b.left.width)),
            @max(0, cr_.top_right - @max(b.top.width, b.right.width)),
            @max(0, cr_.bottom_right - @max(b.bottom.width, b.right.width)),
            @max(0, cr_.bottom_left - @max(b.bottom.width, b.left.width)),
        };
        var u: ExactUniform = .{
            .viewport_hasbg = .{ self.vw, self.vh, if (rs.background != null) 1 else 0, 0 },
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .rad = .{ cr_.top_left, cr_.top_right, cr_.bottom_right, cr_.bottom_left },
            .inner = inner,
            .irad = irad,
            .bw = .{ b.top.width, b.right.width, b.bottom.width, b.left.width },
            .bg = if (rs.background) |bg| col4(bg) else .{ 0, 0, 0, 0 },
            .ct = col4(b.top.color),
            .cr = col4(b.right.color),
            .cb = col4(b.bottom.color),
            .cl = col4(b.left.color),
        };
        _ = msg(void, struct { *const ExactUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(ExactUniform)), 0 });
        _ = msg(void, struct { *const ExactUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(ExactUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

/// Draws an uploaded RGBA texture into a pixel-space rect (NEAREST, clamped)
/// — the Backend's draw_image path, pixel-exact vs raster's nearest sampling.
pub const MetalImageRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    sampler: id,
    sampler_linear: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct ImgU { float4 rect; float4 src; float4 vp; };
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], constant ImgU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 c = corner[vid];
        \\    float2 px = u.rect.xy + c * u.rect.zw;
        \\    VOut o; o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1); o.uv = u.src.xy + c * u.src.zw; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    return tex.sample(s, in.uv);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalImageRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        const sampler = makeSampler(device);
        const sampler_linear = makeSamplerFilter(device, MTLSamplerMinMagFilterLinear);
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .sampler = sampler, .sampler_linear = sampler_linear };
    }

    pub fn deinit(self: *MetalImageRenderer) void {
        release(self.sampler_linear);
        release(self.sampler);
        release(self.pipeline);
    }

    pub fn draw(self: *MetalImageRenderer, x: f32, y: f32, w: f32, h: f32, tex: id) void {
        self.drawUv(x, y, w, h, .{ 0, 0, 1, 1 }, tex, .nearest);
    }

    /// Draw the `src` UV sub-rect into the dst rect with `sampling`.
    pub fn drawUv(self: *MetalImageRenderer, x: f32, y: f32, w: f32, h: f32, src: [4]f32, tex: id, sampling: Backend.Sampling) void {
        const ImgUniform = extern struct { rect: [4]f32, src: [4]f32, vp: [4]f32 };
        var u: ImgUniform = .{ .rect = .{ x, y, w, h }, .src = src, .vp = .{ self.vw, self.vh, 0, 0 } };
        _ = msg(void, struct { *const ImgUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(ImgUniform)), 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentTexture:atIndex:"), .{ tex, 0 });
        const samp = switch (sampling) {
            .nearest => self.sampler,
            .linear => self.sampler_linear,
        };
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentSamplerState:atIndex:"), .{ samp, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Gradient uniform (#118). cfg = {kind(0=linear,1=radial), axis, stop_count, 0};
// radial = {cx, cy, radius, 0}; offsets[8] + colors[8] are the stops. MSL packs
// scalar/vector arrays tightly, so [8]f32 / [8][4]f32 match float offsets[8] /
// float4 colors[8].
const GradUniform = extern struct {
    rect: [4]f32,
    vp: [4]f32,
    cfg: [4]f32,
    radial: [4]f32,
    offsets: [8]f32,
    colors: [8][4]f32,
};

/// Fills a rect with a linear or radial, N-stop gradient (#118), evaluated
/// per-fragment to match raster's `Gradient.colorAt` (straight RGB).
pub const MetalGradientRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct GradU { float4 rect; float4 vp; float4 cfg; float4 radial; float offsets[8]; float4 colors[8]; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant GradU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 px = u.rect.xy + corner[vid] * u.rect.zw;
        \\    return float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1);
        \\}
        \\fragment float4 f_main(float4 fp [[position]], constant GradU& u [[buffer(0)]]) {
        \\    float t;
        \\    if (u.cfg.x < 0.5) { t = (u.cfg.y < 0.5) ? (fp.x - u.rect.x) / u.rect.z : (fp.y - u.rect.y) / u.rect.w; }
        \\    else { float cx = u.rect.x + u.radial.x*u.rect.z; float cy = u.rect.y + u.radial.y*u.rect.w; float rr = u.radial.z*max(u.rect.z,u.rect.w); float dx = fp.x-cx, dy = fp.y-cy; t = (rr>0.0) ? sqrt(dx*dx+dy*dy)/rr : 0.0; }
        \\    t = clamp(t, 0.0, 1.0);
        \\    int n = int(u.cfg.z);
        \\    if (t <= u.offsets[0]) return u.colors[0];
        \\    float4 col = u.colors[n-1];
        \\    for (int i = 1; i < 8; i++) {
        \\        if (i >= n) break;
        \\        if (t <= u.offsets[i]) { float span = u.offsets[i]-u.offsets[i-1]; float f = (span>0.0) ? (t-u.offsets[i-1])/span : 0.0; col = mix(u.colors[i-1], u.colors[i], f); break; }
        \\    }
        \\    return col;
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalGradientRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, false);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalGradientRenderer) void {
        release(self.pipeline);
    }

    pub fn fill(self: *MetalGradientRenderer, rect: geometry.Rect, g: style.Gradient) void {
        var buf: [style.Gradient.max_stops]style.Gradient.Stop = undefined;
        const ss = g.resolved(&buf);
        var u: GradUniform = .{
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .vp = .{ self.vw, self.vh, 0, 0 },
            .cfg = .{ @floatFromInt(@intFromEnum(g.kind)), if (g.axis == .vertical) 1 else 0, @floatFromInt(ss.len), 0 },
            .radial = .{ g.cx, g.cy, g.radius, 0 },
            .offsets = undefined,
            .colors = undefined,
        };
        for (ss, 0..) |s, i| {
            u.offsets[i] = s.offset;
            u.colors[i] = col4(s.color);
        }
        _ = msg(void, struct { *const GradUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(GradUniform)), 0 });
        _ = msg(void, struct { *const GradUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(GradUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Box-shadow uniform (#119). quad = expanded bounds to rasterize; rect = the
// element rect; sh = {dx,dy,blur,spread}; vp = {vw,vh,0,0}.
const ShadowUniform = extern struct { quad: [4]f32, rect: [4]f32, sh: [4]f32, color: [4]f32, vp: [4]f32 };

/// Paints a Gaussian box shadow (#119) using the SAME analytic erf coverage as
/// style.BoxShadow.coverage, so it matches the raster reference within float
/// tolerance.
pub const MetalShadowRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct ShU { float4 quad; float4 rect; float4 sh; float4 color; float4 vp; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant ShU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 px = u.quad.xy + corner[vid] * u.quad.zw;
        \\    return float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1);
        \\}
        \\static float erf_(float x) { float t = 1.0/(1.0+0.3275911*fabs(x)); float y = 1.0-(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-0.284496736)*t+0.254829592)*t*exp(-x*x); return x<0.0?-y:y; }
        \\static float band_(float p, float lo, float hi, float s) { float inv = 1.0/(s*1.4142135623730951); return 0.5*(erf_((hi-p)*inv)-erf_((lo-p)*inv)); }
        \\static float werf_(float x) { float s = x<0.0?-1.0:1.0; float a = fabs(x); float v = 1.0+(0.278393+(0.230389+0.078108*(a*a))*a)*a; v*=v; return s - s/(v*v); }
        \\static float gauss_(float x, float sigma) { return exp(-(x*x)/(2.0*sigma*sigma)) / (2.5066282746310002*sigma); }
        \\static float roundedX_(float x, float y, float sigma, float corner, float hx, float hy) { float delta = min(hy-corner-fabs(y), 0.0); float curved = hx-corner+sqrt(max(0.0, corner*corner-delta*delta)); float inv = 0.7071067811865476/sigma; float lo = 0.5+0.5*werf_((x-curved)*inv); float hi = 0.5+0.5*werf_((x+curved)*inv); return hi-lo; }
        \\static float boxCov_(float x0,float y0,float x1,float y1,float corner,float s,float px,float py){
        \\    if (s<=0.0) return (px>=x0&&px<x1&&py>=y0&&py<y1)?1.0:0.0;
        \\    if (corner<=0.0) return clamp(band_(px,x0,x1,s)*band_(py,y0,y1,s),0.0,1.0);
        \\    float cx=(x0+x1)*0.5, cy=(y0+y1)*0.5, hx=(x1-x0)*0.5, hy=(y1-y0)*0.5; float cr=min(corner,min(hx,hy));
        \\    float ptx=px-cx, pty=py-cy; float low=pty-hy, high=pty+hy; float start=clamp(-3.0*s,low,high); float end=clamp(3.0*s,low,high);
        \\    float step=(end-start)/4.0; float yv=start+step*0.5; float value=0.0;
        \\    for(int k=0;k<4;k++){ value+=roundedX_(ptx,pty-yv,s,cr,hx,hy)*gauss_(yv,s)*step; yv+=step; } return clamp(value,0.0,1.0);
        \\}
        \\static bool insideRR_(float rx,float ry,float rw,float rh,float corner,float px,float py){
        \\    if(px<rx||px>=rx+rw||py<ry||py>=ry+rh) return false; float cr=min(corner,min(rw,rh)*0.5);
        \\    if(px<rx+cr&&py<ry+cr){float dx=px-(rx+cr),dy=py-(ry+cr); if(dx*dx+dy*dy>cr*cr) return false;}
        \\    if(px>=rx+rw-cr&&py<ry+cr){float dx=px-(rx+rw-cr),dy=py-(ry+cr); if(dx*dx+dy*dy>cr*cr) return false;}
        \\    if(px>=rx+rw-cr&&py>=ry+rh-cr){float dx=px-(rx+rw-cr),dy=py-(ry+rh-cr); if(dx*dx+dy*dy>cr*cr) return false;}
        \\    if(px<rx+cr&&py>=ry+rh-cr){float dx=px-(rx+cr),dy=py-(ry+rh-cr); if(dx*dx+dy*dy>cr*cr) return false;} return true;
        \\}
        \\fragment float4 f_main(float4 fp [[position]], constant ShU& u [[buffer(0)]]) {
        \\    float dx=u.sh.x, dy=u.sh.y, blur=u.sh.z, spread=u.sh.w; float corner=u.vp.z; bool inset=u.vp.w>0.5; float s=blur*0.5;
        \\    if (inset) {
        \\        if (!insideRR_(u.rect.x,u.rect.y,u.rect.z,u.rect.w,corner, fp.x,fp.y)) discard_fragment();
        \\        float ix0=u.rect.x+dx+spread, iy0=u.rect.y+dy+spread, ix1=u.rect.x+u.rect.z+dx-spread, iy1=u.rect.y+u.rect.w+dy-spread;
        \\        float cov = clamp(1.0 - boxCov_(ix0,iy0,ix1,iy1,corner,s, fp.x,fp.y), 0.0, 1.0);
        \\        return float4(u.color.rgb, cov*u.color.a);
        \\    }
        \\    float x0=u.rect.x+dx-spread, y0=u.rect.y+dy-spread, x1=u.rect.x+u.rect.z+dx+spread, y1=u.rect.y+u.rect.w+dy+spread;
        \\    return float4(u.color.rgb, boxCov_(x0,y0,x1,y1,corner,s, fp.x,fp.y)*u.color.a);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalShadowRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalShadowRenderer) void {
        release(self.pipeline);
    }

    pub fn draw(self: *MetalShadowRenderer, quad: [4]f32, rect: [4]f32, sh: [4]f32, color: [4]f32, corner: f32, inset: bool) void {
        var u: ShadowUniform = .{ .quad = quad, .rect = rect, .sh = sh, .color = color, .vp = .{ self.vw, self.vh, corner, if (inset) 1 else 0 } };
        _ = msg(void, struct { *const ShadowUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(ShadowUniform)), 0 });
        _ = msg(void, struct { *const ShadowUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(ShadowUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Filled-path uniform (#120). quad = bbox to rasterize; count = point count
// (≤64); pts = polygon points (pixel space). The PS runs the same even-odd
// test as geometry.pointInPolygon, so the fill matches raster pixel-exact.
const max_path_pts = 64;
// meta.x = point count (as float). A float4 (not uint+uint3) so the MSL and Zig
// layouts agree — an int-3 vector aligns to 16 in MSL and would shift `pts`.
const PathUniform = extern struct {
    quad: [4]f32,
    color: [4]f32,
    vp: [4]f32,
    meta: [4]f32,
    pts: [max_path_pts][2]f32,
};

pub const MetalPathRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct PathU { float4 quad; float4 color; float4 vp; float4 meta; float2 pts[64]; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant PathU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 px = u.quad.xy + corner[vid] * u.quad.zw;
        \\    return float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1);
        \\}
        \\static float segd2(float2 a, float2 b, float2 p) {
        \\    float2 v = b - a; float2 w = p - a; float vv = dot(v, v);
        \\    float t = (vv > 0.0) ? clamp(dot(w, v) / vv, 0.0, 1.0) : 0.0;
        \\    float2 d = a + t * v - p; return dot(d, d);
        \\}
        \\fragment float4 f_main(float4 fp [[position]], constant PathU& u [[buffer(0)]]) {
        \\    float px = fp.x, py = fp.y; float2 p = float2(px, py);
        \\    bool inside = false; float best = 1e30;
        \\    uint n = uint(u.meta.x);
        \\    uint j = n - 1;
        \\    for (uint i = 0; i < n; i++) {
        \\        float2 b = u.pts[i]; float2 a = u.pts[j];
        \\        best = min(best, segd2(a, b, p)); // closed polygon edge
        \\        if ((b.y > py) != (a.y > py)) {
        \\            float lhs = (a.x - b.x) * (py - b.y);
        \\            float rhs = (px - b.x) * (a.y - b.y);
        \\            bool left = (a.y > b.y) ? (rhs < lhs) : (rhs > lhs);
        \\            if (left) inside = !inside;
        \\        }
        \\        j = i;
        \\    }
        \\    // Signed distance → ~1px coverage; mirrors raster.fillPath (#316).
        \\    float sd = inside ? sqrt(best) : -sqrt(best);
        \\    float cov = clamp(0.5 + sd, 0.0, 1.0);
        \\    if (cov <= 0.0) discard_fragment();
        \\    return float4(u.color.rgb, u.color.a * cov);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalPathRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalPathRenderer) void {
        release(self.pipeline);
    }

    pub fn fill(self: *MetalPathRenderer, points: []const geometry.Point, color: [4]f32) void {
        if (points.len < 3) return;
        const n = @min(points.len, max_path_pts);
        var minx = points[0].x;
        var miny = points[0].y;
        var maxx = points[0].x;
        var maxy = points[0].y;
        for (points[1..n]) |p| {
            minx = @min(minx, p.x);
            miny = @min(miny, p.y);
            maxx = @max(maxx, p.x);
            maxy = @max(maxy, p.y);
        }
        var u: PathUniform = .{
            // +1px margin for the AA edge fringe (#316).
            .quad = .{ minx - 1, miny - 1, (maxx - minx) + 2, (maxy - miny) + 2 },
            .color = color,
            .vp = .{ self.vw, self.vh, 0, 0 },
            .meta = .{ @floatFromInt(n), 0, 0, 0 },
            .pts = undefined,
        };
        for (0..n) |i| u.pts[i] = .{ points[i].x, points[i].y };
        _ = msg(void, struct { *const PathUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(PathUniform)), 0 });
        _ = msg(void, struct { *const PathUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(PathUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Stroke uniform (#120). meta = {count, hw2, closed, 0}.
const StrokeUniform = extern struct {
    quad: [4]f32,
    color: [4]f32,
    vp: [4]f32,
    meta: [4]f32,
    pts: [max_path_pts][2]f32,
};

/// Strokes a polyline (#120) — the GPU port of geometry.pointNearPolyline: a
/// fragment is kept if its squared distance to any segment is ≤ hw².
pub const MetalStrokeRenderer = struct {
    device: id,
    queue: id,
    pipeline: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct StrokeU { float4 quad; float4 color; float4 vp; float4 meta; float2 pts[64]; };
        \\vertex float4 v_main(uint vid [[vertex_id]], constant StrokeU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 px = u.quad.xy + corner[vid] * u.quad.zw;
        \\    return float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1);
        \\}
        \\static float segd2(float2 a, float2 b, float2 p) {
        \\    float2 v = b - a; float2 w = p - a; float vv = dot(v, v);
        \\    float t = (vv > 0.0) ? clamp(dot(w, v) / vv, 0.0, 1.0) : 0.0;
        \\    float2 d = a + t * v - p; return dot(d, d);
        \\}
        \\fragment float4 f_main(float4 fp [[position]], constant StrokeU& u [[buffer(0)]]) {
        \\    float2 p = fp.xy;
        \\    int n = int(u.meta.x); float hw = u.meta.y; bool closed = u.meta.z > 0.5;
        \\    int last = closed ? n : n - 1;
        \\    float best = 1e30;
        \\    for (int i = 0; i < 64; i++) {
        \\        if (i >= last) break;
        \\        float2 a = u.pts[i]; float2 b = u.pts[(i + 1) % n];
        \\        best = min(best, segd2(a, b, p));
        \\    }
        \\    // Distance to centerline → ~1px coverage at the hw edge (#316).
        \\    float cov = clamp(hw + 0.5 - sqrt(best), 0.0, 1.0);
        \\    if (cov <= 0.0) discard_fragment();
        \\    return float4(u.color.rgb, u.color.a * cov);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalStrokeRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .device = device, .queue = queue, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalStrokeRenderer) void {
        release(self.pipeline);
    }

    pub fn stroke(self: *MetalStrokeRenderer, points: []const geometry.Point, hw: f32, color: [4]f32, closed: bool) void {
        if (points.len < 2) return;
        const n = @min(points.len, max_path_pts);
        var minx = points[0].x;
        var miny = points[0].y;
        var maxx = points[0].x;
        var maxy = points[0].y;
        for (points[1..n]) |p| {
            minx = @min(minx, p.x);
            miny = @min(miny, p.y);
            maxx = @max(maxx, p.x);
            maxy = @max(maxy, p.y);
        }
        var u: StrokeUniform = .{
            // +1px beyond the half-width for the AA edge fringe (#316).
            .quad = .{ minx - hw - 1, miny - hw - 1, (maxx - minx) + 2 * hw + 2, (maxy - miny) + 2 * hw + 2 },
            .color = color,
            .vp = .{ self.vw, self.vh, 0, 0 },
            .meta = .{ @floatFromInt(n), hw, if (closed) 1 else 0, 0 },
            .pts = undefined,
        };
        for (0..n) |i| u.pts[i] = .{ points[i].x, points[i].y };
        _ = msg(void, struct { *const StrokeUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(StrokeUniform)), 0 });
        _ = msg(void, struct { *const StrokeUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(StrokeUniform)), 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Compositor uniform. vp_op = {vw, vh, opacity, 0}.
const CompUniform = extern struct { rect: [4]f32, vp_op: [4]f32 };

/// Composites an offscreen layer texture over the current target at a uniform
/// opacity (#121). The fragment outputs straight-alpha `(rgb, a*opacity)` and
/// the pipeline's standard source-over blend matches raster's popLayer.
pub const MetalLayerCompositor = struct {
    device: id,
    queue: id,
    pipeline: id,
    sampler: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct CompU { float4 rect; float4 vp_op; };
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], constant CompU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 c = corner[vid];
        \\    float2 px = u.rect.xy + c * u.rect.zw;
        \\    VOut o; o.pos = float4(px.x / u.vp_op.x * 2.0 - 1.0, 1.0 - px.y / u.vp_op.y * 2.0, 0, 1); o.uv = c; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], constant CompU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    float4 c = tex.sample(s, in.uv);
        \\    return float4(c.rgb, c.a * u.vp_op.z);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalLayerCompositor {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        const sampler = makeSampler(device);
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .sampler = sampler };
    }

    pub fn deinit(self: *MetalLayerCompositor) void {
        release(self.sampler);
        release(self.pipeline);
    }

    /// Draw `tex` over the whole viewport at `opacity`.
    pub fn composite(self: *MetalLayerCompositor, tex: id, opacity: f32) void {
        var u: CompUniform = .{ .rect = .{ 0, 0, self.vw, self.vh }, .vp_op = .{ self.vw, self.vh, opacity, 0 } };
        _ = msg(void, struct { *const CompUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(CompUniform)), 0 });
        _ = msg(void, struct { *const CompUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(CompUniform)), 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentTexture:atIndex:"), .{ tex, 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentSamplerState:atIndex:"), .{ self.sampler, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

// Round-clip uniform. vp = {vw,vh,0,0}; radius = {tl,tr,br,bl}.
const RClipUniform = extern struct { rect: [4]f32, vp: [4]f32, radius: [4]f32 };

/// Composites a clip layer over its parent, masked to a rounded rect (#117):
/// the fragment discards pixels outside `insideRounded(rect, radius)` at the
/// pixel center, so the corners keep the backdrop — hard-edged, matching
/// raster's per-pixel rounded clip exactly.
pub const MetalRoundClipCompositor = struct {
    device: id,
    queue: id,
    pipeline: id,
    sampler: id,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct RClipU { float4 rect; float4 vp; float4 radius; };
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], constant RClipU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 c = corner[vid];
        \\    float2 px = c * u.vp.xy;
        \\    VOut o; o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0, 1); o.uv = c; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], constant RClipU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    float fx = in.pos.x, fy = in.pos.y;
        \\    float rx = u.rect.x, ry = u.rect.y, rw = u.rect.z, rh = u.rect.w;
        \\    if (fx < rx || fx >= rx + rw || fy < ry || fy >= ry + rh) discard_fragment();
        \\    float maxr = min(rw, rh) * 0.5;
        \\    float cxm = rx + rw * 0.5, cym = ry + rh * 0.5;
        \\    float4 rad = u.radius; // tl, tr, br, bl
        \\    { float r = min(rad.x, maxr); if (r > 0.0) { float cx = rx + rad.x, cy = ry + rad.x; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard_fragment(); } } }
        \\    { float r = min(rad.y, maxr); if (r > 0.0) { float cx = rx + rw - rad.y, cy = ry + rad.y; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard_fragment(); } } }
        \\    { float r = min(rad.z, maxr); if (r > 0.0) { float cx = rx + rw - rad.z, cy = ry + rh - rad.z; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard_fragment(); } } }
        \\    { float r = min(rad.w, maxr); if (r > 0.0) { float cx = rx + rad.w, cy = ry + rh - rad.w; bool ix = (cx <= cxm) ? (fx < cx) : (fx > cx); bool iy = (cy <= cym) ? (fy < cy) : (fy > cy); if (ix && iy) { float dx = fx - cx, dy = fy - cy; if (dx*dx + dy*dy > r*r) discard_fragment(); } } }
        \\    return tex.sample(s, in.uv);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalRoundClipCompositor {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        const sampler = makeSampler(device);
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .sampler = sampler };
    }

    pub fn deinit(self: *MetalRoundClipCompositor) void {
        release(self.sampler);
        release(self.pipeline);
    }

    pub fn composite(self: *MetalRoundClipCompositor, tex: id, rect: geometry.Rect, radius: style.CornerRadius) void {
        var u: RClipUniform = .{
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .vp = .{ self.vw, self.vh, 0, 0 },
            .radius = .{ radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left },
        };
        _ = msg(void, struct { *const RClipUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RClipUniform)), 0 });
        _ = msg(void, struct { *const RClipUniform, u64, u64 }, self.enc, sel("setFragmentBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RClipUniform)), 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentTexture:atIndex:"), .{ tex, 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentSamplerState:atIndex:"), .{ self.sampler, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

const ScissorRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// A pushed group-opacity layer (#121): the target it redirected from, the
/// offscreen texture draws accumulate into, and the composite opacity.
const LayerState = struct { parent: id, layer: id, opacity: f32 };

/// A pushed rounded clip (#117): like a layer, composited back masked to the
/// rounded rect on popClip.
const RoundClip = struct { parent: id, layer: id, rect: geometry.Rect, radius: style.CornerRadius };

/// Which stack a popClip unwinds: a plain scissor entry or a rounded-clip layer.
const ClipOp = enum { scissor, rounded };
const MTLScissorRect = extern struct { x: u64, y: u64, width: u64, height: u64 };

/// The D3D11/GL-equivalent Metal Backend: implements the draw-primitive
/// interface (backend.zig) so layout.render() drives Metal. Renders into an
/// owned offscreen RT; one render encoder per frame, pipeline switched per
/// draw. initOnLayer (windowed) lands in slice 7.
/// Persistent text-measurement cache (#264). Shaping a run (cmap → kerning →
/// ligatures → Arabic) is repeated for every text element on every frame and
/// dominates layout time. The UI's text is overwhelmingly stable frame-to-frame,
/// so memoizing (text, size, style) → Size makes relayout nearly free. Keyed by
/// the byte content (owned copies), not the transient per-frame slice.
const MeasureKey = struct { text: []const u8, size_bits: u32, bold: bool, italic: bool };
const MeasureCtx = struct {
    pub fn hash(_: MeasureCtx, k: MeasureKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.text);
        h.update(std.mem.asBytes(&k.size_bits));
        h.update(&.{ @intFromBool(k.bold), @intFromBool(k.italic) });
        return h.final();
    }
    pub fn eql(_: MeasureCtx, a: MeasureKey, b: MeasureKey) bool {
        return a.size_bits == b.size_bits and a.bold == b.bold and a.italic == b.italic and std.mem.eql(u8, a.text, b.text);
    }
};

pub const MetalBackend = struct {
    gpa: std.mem.Allocator,
    ctx: MetalContext,
    target: id = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Framebuffer clear color (theming, #170 follow-up). Defaults to white so
    /// the offscreen golden path is unchanged; the windowed app sets it from
    /// the theme background.
    clear_color: [4]f32 = .{ 1, 1, 1, 1 },
    rect: MetalRectRenderer,
    exact: MetalExactRectRenderer,
    image: MetalImageRenderer,
    grad: MetalGradientRenderer,
    shadow: MetalShadowRenderer,
    path: MetalPathRenderer,
    stroke: MetalStrokeRenderer,
    comp: MetalLayerCompositor,
    rclip: MetalRoundClipCompositor,
    glyphs: std.AutoHashMapUnmanaged(u16, MetalGlyphRenderer) = .empty,
    clips: std.ArrayList(ScissorRect) = .empty,
    /// Content translation for scroll viewports (#96): added to draw coords and
    /// pushed scissor rects so a clipped subtree pans within a viewport.
    translate: geometry.Point = .{ .x = 0, .y = 0 },
    translate_stack: std.ArrayList(geometry.Point) = .empty,
    /// Active group-opacity layers (#121) and the offscreen textures awaiting
    /// release once the frame's command buffer completes.
    layers: std.ArrayList(LayerState) = .empty,
    pending_tex: std.ArrayList(id) = .empty,
    /// Active rounded clips (#117) and a per-clip-op marker so popClip unwinds
    /// the right stack (scissor vs rounded layer).
    rounds: std.ArrayList(RoundClip) = .empty,
    clip_ops: std.ArrayList(ClipOp) = .empty,
    fonts: ?fontset.FontSet = null,
    /// Windowed present mode (#264): skip the per-frame GPU completion wait in
    /// endFrame (nothing reads back on screen). Left false for offscreen/golden
    /// readback paths, which getBytes the target on the CPU.
    present_only: bool = false,
    /// (text, size, style) → measured Size (#264). Cleared when the font set
    /// changes; freed in deinit. Keys own their text bytes.
    measure_cache: std.HashMapUnmanaged(MeasureKey, geometry.Size, MeasureCtx, std.hash_map.default_max_load_percentage) = .empty,
    enc: id = null,
    cmdbuf: id = null,
    owns_ctx: bool = true,
    // Present pipeline (slice 7): draws the RGBA RT into the BGRA8 drawable.
    present_pipeline: id = null,
    present_sampler: id = null,

    const present_shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]]) {
        \\    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        \\    float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        \\    VOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    return tex.sample(s, in.uv);
        \\}
    ;

    /// Headless Backend over an offscreen render target (golden tests). Owns
    /// its own device/queue.
    pub fn initOffscreen(gpa: std.mem.Allocator) !MetalBackend {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        return initWith(gpa, ctx, true);
    }

    /// Backend on a borrowed device/queue (the windowed path shares the
    /// CAMetalLayer's device so its RT can be sampled into the drawable).
    pub fn initOn(gpa: std.mem.Allocator, device: id, queue: id) !MetalBackend {
        return initWith(gpa, .{ .device = device, .queue = queue }, false);
    }

    fn initWith(gpa: std.mem.Allocator, ctx: MetalContext, owns: bool) !MetalBackend {
        return .{
            .gpa = gpa,
            .ctx = ctx,
            .owns_ctx = owns,
            .rect = try MetalRectRenderer.init(ctx.device, ctx.queue),
            .exact = try MetalExactRectRenderer.init(ctx.device, ctx.queue),
            .image = try MetalImageRenderer.init(ctx.device, ctx.queue),
            .grad = try MetalGradientRenderer.init(ctx.device, ctx.queue),
            .shadow = try MetalShadowRenderer.init(ctx.device, ctx.queue),
            .path = try MetalPathRenderer.init(ctx.device, ctx.queue),
            .stroke = try MetalStrokeRenderer.init(ctx.device, ctx.queue),
            .comp = try MetalLayerCompositor.init(ctx.device, ctx.queue),
            .rclip = try MetalRoundClipCompositor.init(ctx.device, ctx.queue),
        };
    }

    pub fn deinit(self: *MetalBackend) void {
        self.clearMeasureCache(); // free cached text keys (#264)
        self.measure_cache.deinit(self.gpa);
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| g.deinit();
        self.glyphs.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.translate_stack.deinit(self.gpa);
        for (self.layers.items) |l| release(l.layer);
        self.layers.deinit(self.gpa);
        for (self.pending_tex.items) |t| release(t);
        self.pending_tex.deinit(self.gpa);
        for (self.rounds.items) |r| release(r.layer);
        self.rounds.deinit(self.gpa);
        self.clip_ops.deinit(self.gpa);
        self.image.deinit();
        self.exact.deinit();
        self.rect.deinit();
        self.grad.deinit();
        self.shadow.deinit();
        self.path.deinit();
        self.stroke.deinit();
        self.comp.deinit();
        self.rclip.deinit();
        if (self.present_sampler != null) release(self.present_sampler);
        if (self.present_pipeline != null) release(self.present_pipeline);
        if (self.target != null) release(self.target);
        if (self.owns_ctx) self.ctx.destroy();
    }

    /// Draw the offscreen RT into the layer's next drawable (RGBA→BGRA via the
    /// framebuffer store) and present it — the windowed GPU path (slice 7).
    /// Present the rendered frame. `synchronous` picks the present mode:
    /// - false (steady state): async, display-link-paced via the layer's own
    ///   vsync — smooth animation. This is the default.
    /// - true (during a live-resize drag): a presentsWithTransaction present
    ///   (commit → waitUntilScheduled → [drawable present]) so the new frame
    ///   lands in the same CATransaction as the window resize, with no flash
    ///   of the old-size drawable (#170/#181). The synchronous main-thread wait
    ///   is what would make steady-state animation choppy, so it's resize-only.
    pub fn presentTo(self: *MetalBackend, layer: *MetalLayer, synchronous: bool) void {
        if (self.target == null) return;
        if (self.present_pipeline == null) {
            self.present_pipeline = compilePipeline(self.ctx.device, present_shader, MTLPixelFormatBGRA8Unorm, false) catch return;
            self.present_sampler = makeSampler(self.ctx.device);
        }
        const drawable = layer.nextDrawable();
        if (drawable == null) return;
        const texture = msg(id, struct {}, drawable, sel("texture"), .{});

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{texture});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = 1, .green = 1, .blue = 1, .alpha = 1 }});

        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.present_pipeline});
        _ = msg(void, struct { id, u64 }, enc, sel("setFragmentTexture:atIndex:"), .{ self.target, 0 });
        _ = msg(void, struct { id, u64 }, enc, sel("setFragmentSamplerState:atIndex:"), .{ self.present_sampler, 0 });
        _ = msg(void, struct { u64, u64, u64 }, enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
        _ = msg(void, struct {}, enc, sel("endEncoding"), .{});
        // Match the layer's present mode to how we're about to present.
        _ = msg(void, struct { bool }, layer.layer, sel("setPresentsWithTransaction:"), .{synchronous});
        if (synchronous) {
            // Transaction-synced present (live resize): commit, wait until the
            // GPU work is scheduled, then present on this (main) thread so the
            // frame lands in the same CATransaction as the resize (#181).
            _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
            _ = msg(void, struct {}, cmdbuf, sel("waitUntilScheduled"), .{});
            _ = msg(void, struct {}, drawable, sel("present"), .{});
        } else {
            // Async, display-link-paced present (steady state) — smooth, no
            // main-thread wait.
            _ = msg(void, struct { id }, cmdbuf, sel("presentDrawable:"), .{drawable});
            _ = msg(void, struct {}, cmdbuf, sel("commit"), .{});
        }
    }

    pub fn setFont(self: *MetalBackend, data: []const u8) !void {
        var set: fontset.FontSet = .{};
        set.setFace(fontset.FontSet.regular, try ttf.Font.parse(data));
        self.fonts = set;
        self.clearMeasureCache(); // metrics changed (#264)
    }

    pub fn setFontSet(self: *MetalBackend, set: fontset.FontSet) void {
        self.fonts = set;
        self.clearMeasureCache(); // metrics changed (#264)
    }

    pub fn interface(self: *MetalBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Read the render target back as top-down RGBA (caller owns).
    pub fn readPixels(self: *MetalBackend) ![]u8 {
        const buf = try self.gpa.alloc(u8, @as(usize, self.width) * self.height * 4);
        errdefer self.gpa.free(buf);
        const region: MTLRegion = .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = self.width, .height = self.height, .depth = 1 } };
        _ = msg(void, struct { [*]u8, u64, MTLRegion, u64 }, self.target, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), .{ buf.ptr, @as(u64, self.width) * 4, region, 0 });
        return buf;
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

    fn self_(ptr: *anyopaque) *MetalBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn setViewportOnRenderers(self: *MetalBackend, enc: id, w: f32, h: f32) void {
        self.rect.enc = enc;
        self.rect.vw = w;
        self.rect.vh = h;
        self.exact.enc = enc;
        self.exact.vw = w;
        self.exact.vh = h;
        self.image.enc = enc;
        self.image.vw = w;
        self.image.vh = h;
        self.grad.enc = enc;
        self.grad.vw = w;
        self.grad.vh = h;
        self.shadow.enc = enc;
        self.shadow.vw = w;
        self.shadow.vh = h;
        self.path.enc = enc;
        self.path.vw = w;
        self.path.vh = h;
        self.stroke.enc = enc;
        self.stroke.vw = w;
        self.stroke.vh = h;
        self.comp.enc = enc;
        self.comp.vw = w;
        self.comp.vh = h;
        self.rclip.enc = enc;
        self.rclip.vw = w;
        self.rclip.vh = h;
    }

    /// Start a fresh render pass targeting `tex` on the frame's command buffer,
    /// install it as the current encoder, and restore viewport + scissor.
    /// `clear` clears to transparent; otherwise the target's contents load.
    fn beginPass(self: *MetalBackend, tex: id, clear: bool) void {
        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{tex});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{if (clear) MTLLoadActionClear else MTLLoadActionLoad});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        if (clear) _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }});
        const enc = msg(id, struct { id }, self.cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        self.enc = enc;
        self.setViewportOnRenderers(enc, @floatFromInt(self.width), @floatFromInt(self.height));
        self.applyScissor();
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        const w: u32 = @intFromFloat(@max(1, @round(viewport.width)));
        const h: u32 = @intFromFloat(@max(1, @round(viewport.height)));
        if (self.target == null or w != self.width or h != self.height) {
            if (self.target != null) release(self.target);
            self.target = makeTexture(self.ctx.device, w, h, MTLPixelFormatRGBA8Unorm) catch return error.OutOfMemory;
            self.width = w;
            self.height = h;
        }
        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{self.target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = self.clear_color[0], .green = self.clear_color[1], .blue = self.clear_color[2], .alpha = self.clear_color[3] }});
        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
        self.cmdbuf = cmdbuf;
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        self.enc = enc;
        self.setViewportOnRenderers(enc, @floatFromInt(w), @floatFromInt(h));
        self.clips.clearRetainingCapacity();
        self.clip_ops.clearRetainingCapacity();
        self.applyScissor();
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        std.debug.assert(self.layers.items.len == 0); // balanced push/popLayer
        std.debug.assert(self.rounds.items.len == 0); // balanced rounded clips
        _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
        // Upload any glyphs packed this frame — after endEncoding, before
        // commit (the atlas only appends, so the encoded quads read the final
        // texture correctly; see MetalGlyphRenderer.uploadIfDirty).
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| g.uploadIfDirty();
        _ = msg(void, struct {}, self.cmdbuf, sel("commit"), .{});
        // Block until the GPU finishes only when the CPU reads the target back
        // (offscreen goldens / capture). In the windowed present path nothing
        // reads back: the queue is FIFO so presentTo (which samples the target)
        // runs after this render, and the committed buffer retains its resources
        // until completion — so the wait is pure latency there (#264).
        if (!self.present_only) _ = msg(void, struct {}, self.cmdbuf, sel("waitUntilCompleted"), .{});
        for (self.pending_tex.items) |t| release(t);
        self.pending_tex.clearRetainingCapacity();
        self.enc = null;
    }

    /// Shift a rect by the active content translation (#96).
    fn offRect(self: *const MetalBackend, r: geometry.Rect) geometry.Rect {
        return .{ .x = r.x + self.translate.x, .y = r.y + self.translate.y, .width = r.width, .height = r.height };
    }

    /// Copy `points` shifted by the content translation into `buf` (#96).
    fn offPoints(self: *const MetalBackend, points: []const geometry.Point, buf: []geometry.Point) []geometry.Point {
        const n = @min(points.len, buf.len);
        for (0..n) |k| buf[k] = .{ .x = points[k].x + self.translate.x, .y = points[k].y + self.translate.y };
        return buf[0..n];
    }

    fn drawRect(ptr: *anyopaque, rect_in: geometry.Rect, rs: style.RectStyle) void {
        const self = self_(ptr);
        const rect = self.offRect(rect_in);
        const rrect: [4]f32 = .{ rect.x, rect.y, rect.width, rect.height };
        const shc: [4]f32 = if (rs.shadow) |sh| .{ sh.dx, sh.dy, sh.blur, sh.spread } else undefined;
        // Outer shadow paints behind the fill.
        if (rs.shadow) |sh| if (!sh.inset) {
            const margin = sh.blur * 2 + @abs(sh.spread) + 2;
            const quad: [4]f32 = .{ rect.x + sh.dx - sh.spread - margin, rect.y + sh.dy - sh.spread - margin, rect.width + 2 * (sh.spread + margin), rect.height + 2 * (sh.spread + margin) };
            _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.shadow.pipeline});
            self.shadow.draw(quad, rrect, shc, col4(sh.color), sh.corner_radius, false);
        };
        // Fill.
        if (rs.gradient) |g| {
            _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.grad.pipeline});
            self.grad.fill(rect, g);
        } else if (rs.corner_radius.isNone() and rs.border.isNone()) {
            if (rs.background) |bg| {
                _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.rect.pipeline});
                self.rect.fillRect(rect.x, rect.y, rect.width, rect.height, col4(bg));
            }
        } else {
            _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.exact.pipeline});
            self.exact.draw(rect, rs);
        }
        // Inset shadow paints on top, clipped to the rect's rounded shape.
        if (rs.shadow) |sh| if (sh.inset) {
            _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.shadow.pipeline});
            self.shadow.draw(rrect, rrect, shc, col4(sh.color), sh.corner_radius, true);
        };
    }

    fn glyphFor(self: *MetalBackend, size_px: u16) ?*MetalGlyphRenderer {
        if (self.fonts == null) return null;
        if (self.glyphs.getPtr(size_px)) |g| return g;
        const g = MetalGlyphRenderer.init(self.ctx.device, self.ctx.queue, self.gpa, &self.fonts.?, @floatFromInt(size_px)) catch return null;
        self.glyphs.put(self.gpa, size_px, g) catch return null;
        return self.glyphs.getPtr(size_px);
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, ts: style.TextStyle) void {
        const self = self_(ptr);
        const size_px: u16 = @intFromFloat(@max(4, ts.size));
        const gr = self.glyphFor(size_px) orelse return;
        gr.enc = self.enc;
        gr.vw = @floatFromInt(self.width);
        gr.vh = @floatFromInt(self.height);
        const color = ts.color orelse style.Color.black;
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{gr.pipeline});
        gr.drawText(self.gpa, origin.x + self.translate.x, origin.y + self.translate.y, text, col4(color), .{ .bold = ts.effectiveBold(), .italic = ts.italic }) catch {};
        // Text decorations (#191): a filled line, same geometry as raster.
        if (ts.underline or ts.strikethrough) {
            const rw = self.fonts.?.measure(text, ts.size, .{ .bold = ts.effectiveBold(), .italic = ts.italic }).width;
            const bx = origin.x + self.translate.x;
            const baseline = origin.y + self.translate.y + gr.atlas.ascent;
            const c4 = col4(color);
            _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.rect.pipeline});
            if (ts.underline) {
                const r = style.TextDecoration.underlineRect(bx, baseline, rw, ts.size);
                self.rect.fillRect(r.x, r.y, r.width, r.height, c4);
            }
            if (ts.strikethrough) {
                const r = style.TextDecoration.strikeRect(bx, baseline, rw, ts.size);
                self.rect.fillRect(r.x, r.y, r.width, r.height, c4);
            }
        }
    }

    fn drawImage(ptr: *anyopaque, rect_in: geometry.Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const rect = self.offRect(rect_in);
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.image.pipeline});
        self.image.draw(rect.x, rect.y, rect.width, rect.height, @ptrCast(texture));
    }

    fn drawImageUv(ptr: *anyopaque, dst_in: geometry.Rect, texture: *Backend.Texture, src: geometry.Rect, sampling: Backend.Sampling) void {
        const self = self_(ptr);
        const dst = self.offRect(dst_in);
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.image.pipeline});
        self.image.drawUv(dst.x, dst.y, dst.width, dst.height, .{ src.x, src.y, src.width, src.height }, @ptrCast(texture), sampling);
    }

    fn fillPath(ptr: *anyopaque, points: []const geometry.Point, color: style.Color) void {
        const self = self_(ptr);
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.path.pipeline});
        var buf: [256]geometry.Point = undefined;
        self.path.fill(self.offPoints(points, &buf), col4(color));
    }

    fn strokePath(ptr: *anyopaque, points: []const geometry.Point, width: f32, color: style.Color, closed: bool) void {
        const self = self_(ptr);
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.stroke.pipeline});
        var buf: [256]geometry.Point = undefined;
        self.stroke.stroke(self.offPoints(points, &buf), width * 0.5, col4(color), closed);
    }

    fn applyScissor(self: *MetalBackend) void {
        var s: ScissorRect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
        for (self.clips.items) |c| {
            s.x0 = @max(s.x0, c.x0);
            s.y0 = @max(s.y0, c.y0);
            s.x1 = @min(s.x1, c.x1);
            s.y1 = @min(s.y1, c.y1);
        }
        s.x0 = std.math.clamp(s.x0, 0, @as(i32, @intCast(self.width)));
        s.y0 = std.math.clamp(s.y0, 0, @as(i32, @intCast(self.height)));
        s.x1 = std.math.clamp(s.x1, s.x0, @as(i32, @intCast(self.width)));
        s.y1 = std.math.clamp(s.y1, s.y0, @as(i32, @intCast(self.height)));
        const r: MTLScissorRect = .{ .x = @intCast(s.x0), .y = @intCast(s.y0), .width = @intCast(s.x1 - s.x0), .height = @intCast(s.y1 - s.y0) };
        _ = msg(void, struct { MTLScissorRect }, self.enc, sel("setScissorRect:"), .{r});
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

    /// Rounded clip (#117): redirect draws into an offscreen layer (like
    /// pushLayer); popClip composites it back masked to the rounded rect.
    fn pushClipRounded(ptr: *anyopaque, rect_in: geometry.Rect, radius: style.CornerRadius) void {
        const self = self_(ptr);
        if (radius.isNone()) return pushClip(ptr, rect_in);
        const rect = self.offRect(rect_in);
        const layer_tex = makeTexture(self.ctx.device, self.width, self.height, MTLPixelFormatRGBA8Unorm) catch return;
        self.rounds.append(self.gpa, .{ .parent = self.target, .layer = layer_tex, .rect = rect, .radius = radius }) catch {
            release(layer_tex);
            return;
        };
        self.clip_ops.append(self.gpa, .rounded) catch {};
        _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
        self.target = layer_tex;
        self.beginPass(layer_tex, true);
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
                const rc = self.rounds.pop() orelse return;
                _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
                self.target = rc.parent;
                self.beginPass(rc.parent, false); // load the backdrop
                _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.rclip.pipeline});
                self.rclip.composite(rc.layer, rc.rect, rc.radius);
                self.pending_tex.append(self.gpa, rc.layer) catch release(rc.layer);
            },
        }
    }

    /// Redirect draws into a fresh transparent offscreen texture (#121). Ends
    /// the current pass (storing the backdrop) and opens a clear pass on the
    /// new layer texture; the clip stack and viewport carry over.
    fn pushLayer(ptr: *anyopaque, opacity: f32) Backend.Error!void {
        const self = self_(ptr);
        const layer_tex = makeTexture(self.ctx.device, self.width, self.height, MTLPixelFormatRGBA8Unorm) catch return error.OutOfMemory;
        self.layers.append(self.gpa, .{ .parent = self.target, .layer = layer_tex, .opacity = opacity }) catch {
            release(layer_tex);
            return error.OutOfMemory;
        };
        _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
        self.target = layer_tex;
        self.beginPass(layer_tex, true);
    }

    /// Composite the top layer over its parent at the layer opacity, then
    /// resume drawing into the parent. The layer texture is released after the
    /// command buffer completes (endFrame).
    fn popLayer(ptr: *anyopaque) void {
        const self = self_(ptr);
        const l = self.layers.pop() orelse return;
        _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
        self.target = l.parent;
        self.beginPass(l.parent, false); // load the backdrop
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.comp.pipeline});
        self.comp.composite(l.layer, l.opacity);
        self.pending_tex.append(self.gpa, l.layer) catch release(l.layer);
    }

    fn createTexture(ptr: *anyopaque, width: u32, height: u32, rgba: []const u8) Backend.Error!*Backend.Texture {
        const self = self_(ptr);
        const tex = uploadTexture(self.ctx.device, rgba, width, height) catch return error.OutOfMemory;
        return @ptrCast(tex);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        _ = self_(ptr);
        release(@ptrCast(texture));
    }

    fn measureText(ptr: *anyopaque, text: []const u8, ts: style.TextStyle) geometry.Size {
        const self = self_(ptr);
        if (self.fonts) |*set| {
            const key: MeasureKey = .{ .text = text, .size_bits = @bitCast(ts.size), .bold = ts.effectiveBold(), .italic = ts.italic };
            if (self.measure_cache.getContext(key, .{})) |sz| return sz; // #264 hit
            const mtr = set.measure(text, ts.size, .{ .bold = key.bold, .italic = key.italic });
            const sz: geometry.Size = .{ .width = mtr.width, .height = mtr.height };
            // Memoize with an owned key. Bound it so dynamic text can't grow it
            // without limit; on OOM just skip caching (correctness unaffected).
            if (self.measure_cache.count() >= 8192) self.clearMeasureCache();
            if (self.gpa.dupe(u8, text)) |owned| {
                var k = key;
                k.text = owned;
                self.measure_cache.putContext(self.gpa, k, sz, .{}) catch self.gpa.free(owned);
            } else |_| {}
            return sz;
        }
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return .{ .width = @as(f32, @floatFromInt(n)) * 8, .height = 16 };
    }

    /// Free the cached measurement keys and empty the map (#264). Called when
    /// the font set changes (metrics invalidated) and on deinit.
    fn clearMeasureCache(self: *MetalBackend) void {
        var it = self.measure_cache.keyIterator();
        while (it.next()) |k| self.gpa.free(k.text);
        self.measure_cache.clearRetainingCapacity();
    }

    fn snap(ptr: *anyopaque, value: f32, axis: geometry.Axis) f32 {
        _ = ptr;
        _ = axis;
        return @round(value);
    }
};
