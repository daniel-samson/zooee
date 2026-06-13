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

pub const Error = error{ NoDevice, NoQueue, NoTexture, NoDrawable, ReadbackFailed };

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

// --- Metal enums / structs --------------------------------------------------

// MTLPixelFormat: RGBA8Unorm=70 (offscreen, matches raster RGBA byte order),
// BGRA8Unorm=80 (required by CAMetalLayer for the window).
const MTLPixelFormatRGBA8Unorm: u64 = 70;
const MTLPixelFormatBGRA8Unorm: u64 = 80;
const MTLLoadActionClear: u64 = 2;
const MTLStoreActionStore: u64 = 1;
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
