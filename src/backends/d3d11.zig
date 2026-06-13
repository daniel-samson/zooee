//! Direct3D 11 backend (#12), slice 1: device + offscreen render target.
//!
//! Mirrors how the GL backend began (gl.zig slice 1 / the offscreen FBO the
//! goldens use): prove the riskiest part — device/context creation +
//! render-target + clear + readback — in isolation, before any shaders or
//! primitives. Create a D3D11 device, make an offscreen render-target
//! texture, clear it to a known color, copy it to a staging texture, map
//! it, and read the pixels back. No shaders yet; later slices add the
//! draw-primitive interface (HLSL), matching the GL backend's shape.
//!
//! Offscreen (no swapchain) so it's headless-verifiable: a DXGI swapchain
//! needs interactive-desktop access (fails with NOT_CURRENTLY_AVAILABLE
//! over SSH / in service sessions), so the window-present swapchain is its
//! own later slice — exactly like GL did offscreen first, window present
//! later. GPU-primary per #11; on hardware-device failure (VMs without 3D
//! accel, incl. our CI VM) it retries the WARP software rasterizer.
//!
//! COM is called through explicit vtable structs: each interface is
//! `extern struct { vtbl }` and a method call is `obj.vtbl.Method(obj, …)`.
//! Unused vtable slots are `[N]*const anyopaque` padding so the methods we
//! use land at the right indices.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) @compileError("d3d11.zig is Windows-only; gate imports on builtin.os.tag");
}

const WINAPI: std.builtin.CallingConvention = .winapi;
const HRESULT = i32;
const UINT = u32;

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub const Error = error{ NoDevice, NoBackBuffer, NoRtv, ReadbackFailed };

// --- DXGI / D3D11 structs ---------------------------------------------------

const DXGI_SAMPLE_DESC = extern struct { count: UINT = 1, quality: UINT = 0 };
const D3D11_TEXTURE2D_DESC = extern struct {
    width: UINT,
    height: UINT,
    mip_levels: UINT = 1,
    array_size: UINT = 1,
    format: UINT,
    sample_desc: DXGI_SAMPLE_DESC = .{},
    usage: UINT,
    bind_flags: UINT = 0,
    cpu_access_flags: UINT = 0,
    misc_flags: UINT = 0,
};
const D3D11_MAPPED_SUBRESOURCE = extern struct {
    p_data: ?*anyopaque = null,
    row_pitch: UINT = 0,
    depth_pitch: UINT = 0,
};

const DXGI_FORMAT_R8G8B8A8_UNORM: UINT = 28;
const D3D11_USAGE_DEFAULT: UINT = 0;
const D3D11_USAGE_STAGING: UINT = 3;
const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
const D3D11_CPU_ACCESS_READ: UINT = 0x20000;
const D3D11_MAP_READ: UINT = 1;
const D3D11_SDK_VERSION: UINT = 7;
const D3D_DRIVER_TYPE_HARDWARE: UINT = 1;
const D3D_DRIVER_TYPE_WARP: UINT = 5;

// --- COM interfaces (only the methods we call; the rest is padding) ---------

const IDevice = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [5]*const anyopaque, // IUnknown(3) + CreateBuffer + CreateTexture1D
        CreateTexture2D: *const fn (*IDevice, *const D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?*ITexture2D) callconv(WINAPI) HRESULT, // 5
        _pad1: [3]*const anyopaque, // CreateTexture3D, CreateShaderResourceView, CreateUnorderedAccessView
        CreateRenderTargetView: *const fn (*IDevice, *ITexture2D, ?*const anyopaque, *?*IRtv) callconv(WINAPI) HRESULT, // 9
    };
};

const IContext = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [14]*const anyopaque, // IUnknown(3)+DeviceChild(4)+methods 7..13
        Map: *const fn (*IContext, *ITexture2D, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(WINAPI) HRESULT, // 14
        Unmap: *const fn (*IContext, *ITexture2D, UINT) callconv(WINAPI) void, // 15
        _pad1: [31]*const anyopaque, // 16..46
        CopyResource: *const fn (*IContext, *ITexture2D, *ITexture2D) callconv(WINAPI) void, // 47
        _pad2: [2]*const anyopaque, // 48,49
        ClearRenderTargetView: *const fn (*IContext, *IRtv, *const [4]f32) callconv(WINAPI) void, // 50
    };
};

const IUnknownVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
};
const IUnknown = extern struct { vtbl: *const IUnknownVtbl };
const ITexture2D = extern struct { vtbl: *const IUnknownVtbl };
const IRtv = extern struct { vtbl: *const IUnknownVtbl };

/// Release any COM object — Release is IUnknown slot 2, present on every
/// interface, so we reinterpret through the IUnknown layout.
fn release(obj: anytype) void {
    const u: *IUnknown = @ptrCast(obj);
    _ = u.vtbl.Release(u);
}

extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: UINT,
    software: ?*anyopaque,
    flags: UINT,
    feature_levels: ?[*]const UINT,
    num_feature_levels: UINT,
    sdk_version: UINT,
    device: *?*IDevice,
    feature_level: ?*UINT,
    context: *?*IContext,
) callconv(WINAPI) HRESULT;

// --- bring-up ---------------------------------------------------------------

/// A D3D11 device + offscreen render-target texture. Slice 1: enough to
/// clear the target and read it back — no window/swapchain (headless).
pub const D3dOffscreen = struct {
    device: *IDevice,
    context: *IContext,
    target: *ITexture2D,
    rtv: *IRtv,
    width: u32,
    height: u32,

    pub fn create(width: u32, height: u32) Error!D3dOffscreen {
        var device: ?*IDevice = null;
        var context: ?*IContext = null;
        // Hardware first; fall back to WARP (software) — VMs without 3D
        // accel (incl. our CI VM) have no hardware D3D11.
        var last_hr: HRESULT = 0;
        for ([_]UINT{ D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP }) |driver| {
            last_hr = D3D11CreateDevice(null, driver, null, 0, null, 0, D3D11_SDK_VERSION, &device, null, &context);
            if (ok(last_hr)) break;
        }
        if (device == null or context == null) return error.NoDevice;
        errdefer {
            release(context.?);
            release(device.?);
        }

        // Offscreen render-target texture.
        var tdesc: D3D11_TEXTURE2D_DESC = .{
            .width = width,
            .height = height,
            .format = DXGI_FORMAT_R8G8B8A8_UNORM,
            .usage = D3D11_USAGE_DEFAULT,
            .bind_flags = D3D11_BIND_RENDER_TARGET,
        };
        var target: ?*ITexture2D = null;
        if (!ok(device.?.vtbl.CreateTexture2D(device.?, &tdesc, null, &target)) or target == null)
            return error.NoBackBuffer;
        errdefer release(target.?);
        var rtv: ?*IRtv = null;
        if (!ok(device.?.vtbl.CreateRenderTargetView(device.?, target.?, null, &rtv)) or rtv == null)
            return error.NoRtv;

        return .{ .device = device.?, .context = context.?, .target = target.?, .rtv = rtv.?, .width = width, .height = height };
    }

    pub fn destroy(self: *D3dOffscreen) void {
        release(self.rtv);
        release(self.target);
        release(self.context);
        release(self.device);
    }

    /// Clear the render target to an RGBA color.
    pub fn clear(self: *D3dOffscreen, r: f32, g: f32, b: f32, a: f32) void {
        const color = [4]f32{ r, g, b, a };
        self.context.vtbl.ClearRenderTargetView(self.context, self.rtv, &color);
    }

    /// Read the render target back as RGBA8 (top-down). Caller owns it.
    pub fn readPixels(self: *D3dOffscreen, gpa: std.mem.Allocator) ![]u8 {
        // Staging texture (CPU-readable), copy the target into it, map.
        var sdesc: D3D11_TEXTURE2D_DESC = .{
            .width = self.width,
            .height = self.height,
            .format = DXGI_FORMAT_R8G8B8A8_UNORM,
            .usage = D3D11_USAGE_STAGING,
            .cpu_access_flags = D3D11_CPU_ACCESS_READ,
        };
        var staging: ?*ITexture2D = null;
        if (!ok(self.device.vtbl.CreateTexture2D(self.device, &sdesc, null, &staging)) or staging == null)
            return error.ReadbackFailed;
        defer release(staging.?);

        self.context.vtbl.CopyResource(self.context, staging.?, self.target);

        var mapped: D3D11_MAPPED_SUBRESOURCE = .{};
        if (!ok(self.context.vtbl.Map(self.context, staging.?, 0, D3D11_MAP_READ, 0, &mapped)) or mapped.p_data == null)
            return error.ReadbackFailed;
        defer self.context.vtbl.Unmap(self.context, staging.?, 0);

        const out = try gpa.alloc(u8, @as(usize, self.width) * self.height * 4);
        const src: [*]const u8 = @ptrCast(mapped.p_data.?);
        const row_bytes = @as(usize, self.width) * 4;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            const src_row = src[y * mapped.row_pitch ..][0..row_bytes];
            @memcpy(out[y * row_bytes ..][0..row_bytes], src_row);
        }
        return out;
    }
};
