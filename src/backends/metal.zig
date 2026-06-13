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

fn nsString(text: [*:0]const u8) id {
    return msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{text});
}

// --- Metal enums / structs --------------------------------------------------

// MTLPixelFormat: RGBA8Unorm=70 (offscreen, matches raster RGBA byte order),
// BGRA8Unorm=80 (required by CAMetalLayer for the window).
const MTLPixelFormatRGBA8Unorm: u64 = 70;
const MTLPixelFormatBGRA8Unorm: u64 = 80;
const MTLLoadActionClear: u64 = 2;
const MTLStoreActionStore: u64 = 1;
const MTLPrimitiveTypeTriangleStrip: u64 = 4;
const MTLSamplerMinMagFilterNearest: u64 = 0;
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

/// A CAMetalLayer attached to an NSView, for on-screen present. Slice 1 only
/// clears-and-presents to prove the layer reaches the screen; later slices
/// render the UI into the drawable.
pub const MetalLayer = struct {
    ctx: MetalContext,
    layer: id, // CAMetalLayer
    width: u32,
    height: u32,

    /// Attach a CAMetalLayer to `view` (an NSView id) sized `width`x`height`
    /// device pixels. Returns null-ish errors if Metal is unavailable so the
    /// caller can fall back to GL/raster.
    pub fn createOnView(view: id, width: u32, height: u32) Error!MetalLayer {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();

        const layer = msg(id, struct {}, cls("CAMetalLayer"), sel("layer"), .{});
        if (layer == null) return error.NoDrawable;
        _ = msg(void, struct { id }, layer, sel("setDevice:"), .{ctx.device});
        _ = msg(void, struct { u64 }, layer, sel("setPixelFormat:"), .{MTLPixelFormatBGRA8Unorm});
        _ = msg(void, struct { bool }, layer, sel("setFramebufferOnly:"), .{false});
        _ = msg(void, struct { CGSize }, layer, sel("setDrawableSize:"), .{.{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});

        // Host the layer in the view (layer-backed).
        _ = msg(void, struct { bool }, view, sel("setWantsLayer:"), .{true});
        _ = msg(void, struct { id }, view, sel("setLayer:"), .{layer});

        return .{ .ctx = ctx, .layer = layer, .width = width, .height = height };
    }

    pub fn destroy(self: *MetalLayer) void {
        self.ctx.destroy();
    }

    pub fn resize(self: *MetalLayer, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.width = width;
        self.height = height;
        _ = msg(void, struct { CGSize }, self.layer, sel("setDrawableSize:"), .{.{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
    }

    /// Slice 1: clear the next drawable to a color and present it.
    pub fn clearAndPresent(self: *MetalLayer, r: f32, g: f32, b: f32, a: f32) Error!void {
        const drawable = msg(id, struct {}, self.layer, sel("nextDrawable"), .{});
        if (drawable == null) return error.NoDrawable;
        const texture = msg(id, struct {}, drawable, sel("texture"), .{});
        clearPass(self.ctx.queue, texture, .{ .red = r, .green = g, .blue = b, .alpha = a }, drawable, false);
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
    const desc = msg(id, struct {}, msg(id, struct {}, cls("MTLSamplerDescriptor"), sel("alloc"), .{}), sel("init"), .{});
    _ = msg(void, struct { u64 }, desc, sel("setMinFilter:"), .{MTLSamplerMinMagFilterNearest});
    _ = msg(void, struct { u64 }, desc, sel("setMagFilter:"), .{MTLSamplerMinMagFilterNearest});
    return msg(id, struct { id }, device, sel("newSamplerStateWithDescriptor:"), .{desc});
}

// --- slice 2: textured quad -------------------------------------------------

/// Sample a CPU image through the shader/texture pipeline into a render
/// target — proves the MSL/pipeline/vertex-buffer machinery (slice 2). The
/// later rect/glyph/image renderers reuse the same scaffolding.
pub const MetalQuadRenderer = struct {
    ctx: MetalContext,
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

    pub fn init() Error!MetalQuadRenderer {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm, false);
        const sampler = makeSampler(ctx.device);
        const verts = msg(id, struct { [*]const f32, u64, u64 }, ctx.device, sel("newBufferWithBytes:length:options:"), .{ &quad, @as(u64, @sizeOf(@TypeOf(quad))), 0 });
        return .{ .ctx = ctx, .pipeline = pipeline, .sampler = sampler, .verts = verts };
    }

    pub fn deinit(self: *MetalQuadRenderer) void {
        release(self.verts);
        release(self.sampler);
        release(self.pipeline);
        self.ctx.destroy();
    }

    /// Upload `rgba` (top-down), draw it 1:1 into a w×h target, read it back.
    pub fn renderOffscreen(self: *MetalQuadRenderer, gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
        const target = try makeTexture(self.ctx.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);
        const src_tex = try uploadTexture(self.ctx.device, rgba, w, h);
        defer release(src_tex);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = 0, .green = 0, .blue = 0, .alpha = 1 }});

        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
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
    ctx: MetalContext,
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

    pub fn init() Error!MetalRectRenderer {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm, false);
        return .{ .ctx = ctx, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalRectRenderer) void {
        release(self.pipeline);
        self.ctx.destroy();
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
        const target = try makeTexture(self.ctx.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
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
    ctx: MetalContext,
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

    pub fn init() Error!MetalRoundedRectRenderer {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm, true);
        return .{ .ctx = ctx, .pipeline = pipeline };
    }

    pub fn deinit(self: *MetalRoundedRectRenderer) void {
        release(self.pipeline);
        self.ctx.destroy();
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
        const target = try makeTexture(self.ctx.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
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

const atlas_w: u32 = 256;
const first_cp: u21 = 32;
const last_cp: u21 = 126;
const glyph_count = last_cp - first_cp + 1;

const GlyphEntry = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 0,
    v1: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    x_off: f32 = 0,
    y_off: f32 = 0,
    advance: f32 = 0,
};

pub const MetalGlyphRenderer = struct {
    ctx: MetalContext,
    pipeline: id,
    atlas_tex: id,
    sampler: id,
    entries: [glyph_count]GlyphEntry,
    ascent: f32,
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

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

    pub fn init(gpa: std.mem.Allocator, font: *const ttf.Font, size_px: f32) !MetalGlyphRenderer {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm, true);

        // Rasterize glyphs, shelf-pack, build the atlas RGBA.
        var entries: [glyph_count]GlyphEntry = undefined;
        var bmps: [glyph_count]?grast.Bitmap = @splat(null);
        defer for (&bmps) |*b| if (b.*) |*bb| bb.deinit(gpa);

        const fscale = size_px / @as(f32, @floatFromInt(font.units_per_em));
        var cx: u32 = 1;
        var cy: u32 = 1;
        var row_h: u32 = 0;
        var atlas_h: u32 = 1;
        for (0..glyph_count) |i| {
            const cp: u21 = first_cp + @as(u21, @intCast(i));
            const gi = font.glyphIndex(cp);
            const adv = @as(f32, @floatFromInt(font.hMetrics(gi).advance)) * fscale;
            entries[i] = .{ .advance = adv };
            const outline = (font.outline(gpa, gi) catch null) orelse continue;
            var o = outline;
            defer o.deinit(gpa);
            const bmp = grast.rasterize(gpa, font, o, size_px) catch continue;
            bmps[i] = bmp;
            if (cx + bmp.width + 1 > atlas_w) {
                cx = 1;
                cy += row_h + 1;
                row_h = 0;
            }
            entries[i].u0 = @floatFromInt(cx);
            entries[i].v0 = @floatFromInt(cy);
            entries[i].w = @floatFromInt(bmp.width);
            entries[i].h = @floatFromInt(bmp.height);
            entries[i].x_off = @floatFromInt(bmp.x_off);
            entries[i].y_off = @floatFromInt(bmp.y_off);
            cx += @as(u32, @intCast(bmp.width)) + 1;
            row_h = @max(row_h, @as(u32, @intCast(bmp.height)));
            atlas_h = @max(atlas_h, cy + row_h + 1);
        }

        const atlas = try gpa.alloc(u8, atlas_w * atlas_h * 4);
        defer gpa.free(atlas);
        @memset(atlas, 0);
        for (0..glyph_count) |i| {
            const bmp = bmps[i] orelse continue;
            const ax: usize = @intFromFloat(entries[i].u0);
            const ay: usize = @intFromFloat(entries[i].v0);
            var yy: usize = 0;
            while (yy < bmp.height) : (yy += 1) {
                var xx: usize = 0;
                while (xx < bmp.width) : (xx += 1) {
                    const a = bmp.alpha[yy * bmp.width + xx];
                    const k = ((ay + yy) * atlas_w + (ax + xx)) * 4;
                    atlas[k + 0] = 255;
                    atlas[k + 1] = 255;
                    atlas[k + 2] = 255;
                    atlas[k + 3] = a;
                }
            }
            const fw: f32 = @floatFromInt(atlas_w);
            const fh: f32 = @floatFromInt(atlas_h);
            entries[i].u1 = (entries[i].u0 + entries[i].w) / fw;
            entries[i].v1 = (entries[i].v0 + entries[i].h) / fh;
            entries[i].u0 /= fw;
            entries[i].v0 /= fh;
        }

        const atlas_tex = try uploadTexture(ctx.device, atlas, atlas_w, atlas_h);
        const sampler = makeSampler(ctx.device);
        return .{
            .ctx = ctx,
            .pipeline = pipeline,
            .atlas_tex = atlas_tex,
            .sampler = sampler,
            .entries = entries,
            .ascent = @as(f32, @floatFromInt(font.ascent)) * fscale,
        };
    }

    pub fn deinit(self: *MetalGlyphRenderer) void {
        release(self.sampler);
        release(self.atlas_tex);
        release(self.pipeline);
        self.ctx.destroy();
    }

    /// Draw `text` with top-left at (x,y) px (baseline = y + ascent), tinted
    /// `color`. ASCII only for now.
    pub fn drawText(self: *MetalGlyphRenderer, gpa: std.mem.Allocator, x: f32, y: f32, text: []const u8, color: [4]f32) !void {
        var verts: std.ArrayList(f32) = .empty;
        defer verts.deinit(gpa);
        var pen = x;
        const baseline = y + self.ascent;
        for (text) |c| {
            if (c < first_cp or c > last_cp) continue;
            const e = self.entries[c - first_cp];
            if (e.w > 0) {
                const gx = @round(pen) + e.x_off;
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
            pen += e.advance;
        }
        if (verts.items.len == 0) return;
        const vbuf = msg(id, struct { [*]const f32, u64, u64 }, self.ctx.device, sel("newBufferWithBytes:length:options:"), .{ verts.items.ptr, verts.items.len * 4, 0 });
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
        const target = try makeTexture(self.ctx.device, w, h, MTLPixelFormatRGBA8Unorm);
        defer release(target);

        const rpd = msg(id, struct {}, cls("MTLRenderPassDescriptor"), sel("renderPassDescriptor"), .{});
        const a0 = msg(id, struct { u64 }, msg(id, struct {}, rpd, sel("colorAttachments"), .{}), sel("objectAtIndexedSubscript:"), .{0});
        _ = msg(void, struct { id }, a0, sel("setTexture:"), .{target});
        _ = msg(void, struct { u64 }, a0, sel("setLoadAction:"), .{MTLLoadActionClear});
        _ = msg(void, struct { u64 }, a0, sel("setStoreAction:"), .{MTLStoreActionStore});
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = clear[0], .green = clear[1], .blue = clear[2], .alpha = clear[3] }});

        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        _ = msg(void, struct { id }, enc, sel("setRenderPipelineState:"), .{self.pipeline});
        self.enc = enc;
        self.vw = @floatFromInt(w);
        self.vh = @floatFromInt(h);
        try self.drawText(gpa, x, y, text, color);
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
