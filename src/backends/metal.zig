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

/// Compile an MSL source string and build a render pipeline state from its
/// `v_main`/`f_main` functions, targeting `pixel_format`.
fn compilePipeline(device: id, source: [*:0]const u8, pixel_format: u64) Error!id {
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
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm);
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
        const pipeline = try compilePipeline(ctx.device, shader, MTLPixelFormatRGBA8Unorm);
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
