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
    device: id,
    queue: id,
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

    pub fn init(device: id, queue: id, gpa: std.mem.Allocator, font: *const ttf.Font, size_px: f32) !MetalGlyphRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);

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

        const atlas_tex = try uploadTexture(device, atlas, atlas_w, atlas_h);
        const sampler = makeSampler(device);
        return .{
            .device = device,
            .queue = queue,
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
        \\    float2 px = u.rect.xy + corner[vid] * u.rect.zw;
        \\    return float4(px.x / u.viewport_hasbg.x * 2.0 - 1.0, 1.0 - px.y / u.viewport_hasbg.y * 2.0, 0, 1);
        \\}
        \\static bool cornerOut(float2 p, float trad, float cx, float cy, float2 r0, float2 rsz) {
        \\    if (trad <= 0.0) return false;
        \\    bool in_x = (cx <= r0.x + rsz.x * 0.5) ? (p.x < cx) : (p.x > cx);
        \\    bool in_y = (cy <= r0.y + rsz.y * 0.5) ? (p.y < cy) : (p.y > cy);
        \\    if (in_x && in_y) { float dx = p.x - cx; float dy = p.y - cy; return dx*dx + dy*dy > trad*trad; }
        \\    return false;
        \\}
        \\static bool insideRounded(float4 r, float4 rd, float2 p) {
        \\    if (p.x < r.x || p.x >= r.x + r.z || p.y < r.y || p.y >= r.y + r.w) return false;
        \\    float mx = min(r.z, r.w) * 0.5;
        \\    float2 r0 = r.xy; float2 rsz = r.zw;
        \\    if (cornerOut(p, min(rd.x, mx), r.x + rd.x,       r.y + rd.x,       r0, rsz)) return false;
        \\    if (cornerOut(p, min(rd.y, mx), r.x + r.z - rd.y, r.y + rd.y,       r0, rsz)) return false;
        \\    if (cornerOut(p, min(rd.z, mx), r.x + r.z - rd.z, r.y + r.w - rd.z, r0, rsz)) return false;
        \\    if (cornerOut(p, min(rd.w, mx), r.x + rd.w,       r.y + r.w - rd.w, r0, rsz)) return false;
        \\    return true;
        \\}
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
        \\    if (!insideRounded(u.rect, u.rad, p)) discard_fragment();
        \\    bool has_border = (u.bw.x + u.bw.y + u.bw.z + u.bw.w) > 0.0;
        \\    if (has_border && !insideRounded(u.inner, u.irad, p)) return borderColorAt(u, p);
        \\    if (u.viewport_hasbg.z > 0.5) return u.bg;
        \\    discard_fragment();
        \\    return float4(0);
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
    enc: id = null,
    vw: f32 = 0,
    vh: f32 = 0,

    const shader =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\struct RectU { float4 rect; float2 viewport; };
        \\struct VOut { float4 pos [[position]]; float2 uv; };
        \\vertex VOut v_main(uint vid [[vertex_id]], constant RectU& u [[buffer(0)]]) {
        \\    float2 corner[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        \\    float2 c = corner[vid];
        \\    float2 px = u.rect.xy + c * u.rect.zw;
        \\    VOut o; o.pos = float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0, 1); o.uv = c; return o;
        \\}
        \\fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        \\    return tex.sample(s, in.uv);
        \\}
    ;

    pub fn init(device: id, queue: id) Error!MetalImageRenderer {
        const pipeline = try compilePipeline(device, shader, MTLPixelFormatRGBA8Unorm, true);
        const sampler = makeSampler(device);
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .sampler = sampler };
    }

    pub fn deinit(self: *MetalImageRenderer) void {
        release(self.sampler);
        release(self.pipeline);
    }

    pub fn draw(self: *MetalImageRenderer, x: f32, y: f32, w: f32, h: f32, tex: id) void {
        var u: RectUniform = .{ .rect = .{ x, y, w, h }, .viewport = .{ self.vw, self.vh } };
        _ = msg(void, struct { *const RectUniform, u64, u64 }, self.enc, sel("setVertexBytes:length:atIndex:"), .{ &u, @as(u64, @sizeOf(RectUniform)), 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentTexture:atIndex:"), .{ tex, 0 });
        _ = msg(void, struct { id, u64 }, self.enc, sel("setFragmentSamplerState:atIndex:"), .{ self.sampler, 0 });
        _ = msg(void, struct { u64, u64, u64 }, self.enc, sel("drawPrimitives:vertexStart:vertexCount:"), .{ MTLPrimitiveTypeTriangleStrip, 0, 4 });
    }
};

const ScissorRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };
const MTLScissorRect = extern struct { x: u64, y: u64, width: u64, height: u64 };

/// The D3D11/GL-equivalent Metal Backend: implements the draw-primitive
/// interface (backend.zig) so layout.render() drives Metal. Renders into an
/// owned offscreen RT; one render encoder per frame, pipeline switched per
/// draw. initOnLayer (windowed) lands in slice 7.
pub const MetalBackend = struct {
    gpa: std.mem.Allocator,
    ctx: MetalContext,
    target: id = null,
    width: u32 = 0,
    height: u32 = 0,
    rect: MetalRectRenderer,
    exact: MetalExactRectRenderer,
    image: MetalImageRenderer,
    glyphs: std.AutoHashMapUnmanaged(u16, MetalGlyphRenderer) = .empty,
    clips: std.ArrayList(ScissorRect) = .empty,
    font: ?ttf.Font = null,
    enc: id = null,
    cmdbuf: id = null,

    /// Headless Backend over an offscreen render target (golden tests).
    pub fn initOffscreen(gpa: std.mem.Allocator) !MetalBackend {
        var ctx = try MetalContext.create();
        errdefer ctx.destroy();
        return .{
            .gpa = gpa,
            .ctx = ctx,
            .rect = try MetalRectRenderer.init(ctx.device, ctx.queue),
            .exact = try MetalExactRectRenderer.init(ctx.device, ctx.queue),
            .image = try MetalImageRenderer.init(ctx.device, ctx.queue),
        };
    }

    pub fn deinit(self: *MetalBackend) void {
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| g.deinit();
        self.glyphs.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.image.deinit();
        self.exact.deinit();
        self.rect.deinit();
        if (self.target != null) release(self.target);
        self.ctx.destroy();
    }

    pub fn setFont(self: *MetalBackend, data: []const u8) !void {
        self.font = try ttf.Font.parse(data);
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
        .push_clip = pushClip,
        .pop_clip = popClip,
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
        _ = msg(void, struct { MTLClearColor }, a0, sel("setClearColor:"), .{.{ .red = 1, .green = 1, .blue = 1, .alpha = 1 }}); // match raster white clear
        const cmdbuf = msg(id, struct {}, self.ctx.queue, sel("commandBuffer"), .{});
        self.cmdbuf = cmdbuf;
        const enc = msg(id, struct { id }, cmdbuf, sel("renderCommandEncoderWithDescriptor:"), .{rpd});
        self.enc = enc;
        self.setViewportOnRenderers(enc, @floatFromInt(w), @floatFromInt(h));
        self.clips.clearRetainingCapacity();
        self.applyScissor();
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        const self = self_(ptr);
        _ = msg(void, struct {}, self.enc, sel("endEncoding"), .{});
        _ = msg(void, struct {}, self.cmdbuf, sel("commit"), .{});
        _ = msg(void, struct {}, self.cmdbuf, sel("waitUntilCompleted"), .{});
        self.enc = null;
    }

    fn drawRect(ptr: *anyopaque, rect: geometry.Rect, rs: style.RectStyle) void {
        const self = self_(ptr);
        if (rs.corner_radius.isNone() and rs.border.isNone()) {
            if (rs.background) |bg| {
                _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.rect.pipeline});
                self.rect.fillRect(rect.x, rect.y, rect.width, rect.height, col4(bg));
            }
            return;
        }
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.exact.pipeline});
        self.exact.draw(rect, rs);
    }

    fn glyphFor(self: *MetalBackend, size_px: u16) ?*MetalGlyphRenderer {
        if (self.font == null) return null;
        if (self.glyphs.getPtr(size_px)) |g| return g;
        const g = MetalGlyphRenderer.init(self.ctx.device, self.ctx.queue, self.gpa, &self.font.?, @floatFromInt(size_px)) catch return null;
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
        gr.drawText(self.gpa, origin.x, origin.y, text, col4(color)) catch {};
    }

    fn drawImage(ptr: *anyopaque, rect: geometry.Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        _ = msg(void, struct { id }, self.enc, sel("setRenderPipelineState:"), .{self.image.pipeline});
        self.image.draw(rect.x, rect.y, rect.width, rect.height, @ptrCast(texture));
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

    fn pushClip(ptr: *anyopaque, rect: geometry.Rect) void {
        const self = self_(ptr);
        self.clips.append(self.gpa, .{
            .x0 = @intFromFloat(@round(rect.x)),
            .y0 = @intFromFloat(@round(rect.y)),
            .x1 = @intFromFloat(@round(rect.x + rect.width)),
            .y1 = @intFromFloat(@round(rect.y + rect.height)),
        }) catch {};
        self.applyScissor();
    }

    fn popClip(ptr: *anyopaque) void {
        const self = self_(ptr);
        if (self.clips.items.len > 0) _ = self.clips.pop();
        self.applyScissor();
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
        if (self.font) |*font| {
            const upem: f32 = @floatFromInt(font.units_per_em);
            const fscale = ts.size / upem;
            var width: f32 = 0;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepoint()) |cp| {
                width += @as(f32, @floatFromInt(font.hMetrics(font.glyphIndex(cp)).advance)) * fscale;
            }
            const line = @as(f32, @floatFromInt(font.ascent - font.descent + font.line_gap)) * fscale;
            return .{ .width = width, .height = line };
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
