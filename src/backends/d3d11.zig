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
const ttf = @import("../font/ttf.zig");
const grast = @import("../font/raster.zig");
const gatlas = @import("../font/atlas.zig");
const geometry = @import("../geometry.zig");
const style = @import("../style.zig");
const backend_mod = @import("../backend.zig");
const Backend = backend_mod.Backend;

comptime {
    if (builtin.os.tag != .windows) @compileError("d3d11.zig is Windows-only; gate imports on builtin.os.tag");
}

const WINAPI: std.builtin.CallingConvention = .winapi;
const HRESULT = i32;
const UINT = u32;
const BOOL = i32;

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub const Error = error{ NoDevice, NoBackBuffer, NoRtv, ReadbackFailed, ShaderFailed, ResizeFailed };

// --- DXGI / D3D11 structs ---------------------------------------------------

const HWND = *anyopaque;
const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
// IID_ID3D11Texture2D {6f15aaf2-d208-4e89-9ab4-489535d34f9c}
const IID_ID3D11Texture2D: GUID = .{ .d1 = 0x6f15aaf2, .d2 = 0xd208, .d3 = 0x4e89, .d4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

const DXGI_RATIONAL = extern struct { numerator: UINT = 0, denominator: UINT = 1 };
const DXGI_MODE_DESC = extern struct {
    width: UINT,
    height: UINT,
    refresh_rate: DXGI_RATIONAL = .{},
    format: UINT,
    scanline_ordering: UINT = 0,
    scaling: UINT = 0,
};
const DXGI_SWAP_CHAIN_DESC = extern struct {
    buffer_desc: DXGI_MODE_DESC,
    sample_desc: DXGI_SAMPLE_DESC = .{},
    buffer_usage: UINT,
    buffer_count: UINT,
    output_window: HWND,
    windowed: BOOL,
    swap_effect: UINT = 0, // DXGI_SWAP_EFFECT_DISCARD
    flags: UINT = 0,
};
const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;

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
const DXGI_FORMAT_R32G32_FLOAT: UINT = 16;
const D3D11_USAGE_DEFAULT: UINT = 0;
const D3D11_USAGE_IMMUTABLE: UINT = 1;
const D3D11_USAGE_STAGING: UINT = 3;
const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
const D3D11_BIND_VERTEX_BUFFER: UINT = 0x1;
const D3D11_BIND_CONSTANT_BUFFER: UINT = 0x4;
const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
const D3D11_CPU_ACCESS_READ: UINT = 0x20000;
const D3D11_MAP_READ: UINT = 1;
const D3D11_SDK_VERSION: UINT = 7;
const D3D_DRIVER_TYPE_HARDWARE: UINT = 1;
const D3D_DRIVER_TYPE_WARP: UINT = 5;
const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST: UINT = 4;
const D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: UINT = 5;
const D3D11_FILTER_MIN_MAG_MIP_POINT: UINT = 0;
const D3D11_TEXTURE_ADDRESS_CLAMP: UINT = 3;
const D3D11_INPUT_PER_VERTEX_DATA: UINT = 0;
const D3D11_FILL_SOLID: UINT = 3;
const D3D11_CULL_NONE: UINT = 1;

// --- COM interfaces (only the methods we call; the rest is padding) ---------

const IDevice = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [3]*const anyopaque, // IUnknown(3)
        CreateBuffer: *const fn (*IDevice, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*IBuffer) callconv(WINAPI) HRESULT, // 3
        _pad1: [1]*const anyopaque, // CreateTexture1D(4)
        CreateTexture2D: *const fn (*IDevice, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ITexture2D) callconv(WINAPI) HRESULT, // 5
        _pad2: [1]*const anyopaque, // CreateTexture3D(6)
        CreateShaderResourceView: *const fn (*IDevice, *ITexture2D, ?*const anyopaque, *?*ISrv) callconv(WINAPI) HRESULT, // 7
        _pad3: [1]*const anyopaque, // CreateUnorderedAccessView(8)
        CreateRenderTargetView: *const fn (*IDevice, *ITexture2D, ?*const anyopaque, *?*IRtv) callconv(WINAPI) HRESULT, // 9
        _pad4: [1]*const anyopaque, // CreateDepthStencilView(10)
        CreateInputLayout: *const fn (*IDevice, [*]const D3D11_INPUT_ELEMENT_DESC, UINT, *const anyopaque, usize, *?*IInputLayout) callconv(WINAPI) HRESULT, // 11
        CreateVertexShader: *const fn (*IDevice, *const anyopaque, usize, ?*anyopaque, *?*IVertexShader) callconv(WINAPI) HRESULT, // 12
        _pad5: [2]*const anyopaque, // CreateGeometryShader(13), …WithStreamOutput(14)
        CreatePixelShader: *const fn (*IDevice, *const anyopaque, usize, ?*anyopaque, *?*IPixelShader) callconv(WINAPI) HRESULT, // 15
        _pad6: [4]*const anyopaque, // 16..19
        CreateBlendState: *const fn (*IDevice, *const D3D11_BLEND_DESC, *?*IBlendState) callconv(WINAPI) HRESULT, // 20
        _pad6b: [1]*const anyopaque, // CreateDepthStencilState(21)
        CreateRasterizerState: *const fn (*IDevice, *const D3D11_RASTERIZER_DESC, *?*IRasterizerState) callconv(WINAPI) HRESULT, // 22
        CreateSamplerState: *const fn (*IDevice, *const D3D11_SAMPLER_DESC, *?*ISampler) callconv(WINAPI) HRESULT, // 23
    };
};

const IContext = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [7]*const anyopaque, // IUnknown(3)+DeviceChild(4)
        VSSetConstantBuffers: *const fn (*IContext, UINT, UINT, *const ?*IBuffer) callconv(WINAPI) void, // 7
        PSSetShaderResources: *const fn (*IContext, UINT, UINT, *const ?*ISrv) callconv(WINAPI) void, // 8
        PSSetShader: *const fn (*IContext, ?*IPixelShader, ?*const anyopaque, UINT) callconv(WINAPI) void, // 9
        PSSetSamplers: *const fn (*IContext, UINT, UINT, *const ?*ISampler) callconv(WINAPI) void, // 10
        VSSetShader: *const fn (*IContext, ?*IVertexShader, ?*const anyopaque, UINT) callconv(WINAPI) void, // 11
        _pad1: [1]*const anyopaque, // DrawIndexed(12)
        Draw: *const fn (*IContext, UINT, UINT) callconv(WINAPI) void, // 13
        Map: *const fn (*IContext, *ITexture2D, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(WINAPI) HRESULT, // 14
        Unmap: *const fn (*IContext, *ITexture2D, UINT) callconv(WINAPI) void, // 15
        PSSetConstantBuffers: *const fn (*IContext, UINT, UINT, *const ?*IBuffer) callconv(WINAPI) void, // 16
        IASetInputLayout: *const fn (*IContext, ?*IInputLayout) callconv(WINAPI) void, // 17
        IASetVertexBuffers: *const fn (*IContext, UINT, UINT, *const ?*IBuffer, *const UINT, *const UINT) callconv(WINAPI) void, // 18
        _pad3: [5]*const anyopaque, // 19..23
        IASetPrimitiveTopology: *const fn (*IContext, UINT) callconv(WINAPI) void, // 24
        _pad4: [8]*const anyopaque, // 25..32
        OMSetRenderTargets: *const fn (*IContext, UINT, *const ?*IRtv, ?*anyopaque) callconv(WINAPI) void, // 33
        _pad5a: [1]*const anyopaque, // OMSetRenderTargetsAndUnorderedAccessViews(34)
        OMSetBlendState: *const fn (*IContext, ?*IBlendState, ?*const [4]f32, UINT) callconv(WINAPI) void, // 35
        _pad5: [7]*const anyopaque, // 36..42
        RSSetState: *const fn (*IContext, ?*IRasterizerState) callconv(WINAPI) void, // 43
        RSSetViewports: *const fn (*IContext, UINT, *const D3D11_VIEWPORT) callconv(WINAPI) void, // 44
        RSSetScissorRects: *const fn (*IContext, UINT, *const D3D11_RECT) callconv(WINAPI) void, // 45
        _pad6: [1]*const anyopaque, // 46
        CopyResource: *const fn (*IContext, *ITexture2D, *ITexture2D) callconv(WINAPI) void, // 47
        _pad7: [2]*const anyopaque, // 48,49
        ClearRenderTargetView: *const fn (*IContext, *IRtv, *const [4]f32) callconv(WINAPI) void, // 50
    };
};

const IBlob = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [3]*const anyopaque, // IUnknown(3)
        GetBufferPointer: *const fn (*IBlob) callconv(WINAPI) ?*anyopaque, // 3
        GetBufferSize: *const fn (*IBlob) callconv(WINAPI) usize, // 4
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
const ISrv = extern struct { vtbl: *const IUnknownVtbl };
const IBuffer = extern struct { vtbl: *const IUnknownVtbl };
const ISampler = extern struct { vtbl: *const IUnknownVtbl };
const IVertexShader = extern struct { vtbl: *const IUnknownVtbl };
const IPixelShader = extern struct { vtbl: *const IUnknownVtbl };
const IInputLayout = extern struct { vtbl: *const IUnknownVtbl };
const IRasterizerState = extern struct { vtbl: *const IUnknownVtbl };
const IBlendState = extern struct { vtbl: *const IUnknownVtbl };

const D3D11_BLEND_SRC_ALPHA: UINT = 5;
const D3D11_BLEND_INV_SRC_ALPHA: UINT = 6;
const D3D11_BLEND_ONE: UINT = 2;
const D3D11_BLEND_ZERO: UINT = 1;
const D3D11_BLEND_OP_ADD: UINT = 1;

const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    blend_enable: BOOL = 0,
    src_blend: UINT = D3D11_BLEND_ONE,
    dest_blend: UINT = D3D11_BLEND_ZERO,
    blend_op: UINT = D3D11_BLEND_OP_ADD,
    src_blend_alpha: UINT = D3D11_BLEND_ONE,
    dest_blend_alpha: UINT = D3D11_BLEND_ZERO,
    blend_op_alpha: UINT = D3D11_BLEND_OP_ADD,
    render_target_write_mask: u8 = 0x0F,
};
const D3D11_BLEND_DESC = extern struct {
    alpha_to_coverage_enable: BOOL = 0,
    independent_blend_enable: BOOL = 0,
    render_target: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

const D3D11_RASTERIZER_DESC = extern struct {
    fill_mode: UINT = D3D11_FILL_SOLID,
    cull_mode: UINT = D3D11_CULL_NONE,
    front_counter_clockwise: BOOL = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip_enable: BOOL = 1,
    scissor_enable: BOOL = 0,
    multisample_enable: BOOL = 0,
    antialiased_line_enable: BOOL = 0,
};

const D3D11_BUFFER_DESC = extern struct {
    byte_width: UINT,
    usage: UINT,
    bind_flags: UINT,
    cpu_access_flags: UINT = 0,
    misc_flags: UINT = 0,
    structure_byte_stride: UINT = 0,
};
const D3D11_SUBRESOURCE_DATA = extern struct {
    p_sys_mem: *const anyopaque,
    sys_mem_pitch: UINT = 0,
    sys_mem_slice_pitch: UINT = 0,
};
const D3D11_INPUT_ELEMENT_DESC = extern struct {
    semantic_name: [*:0]const u8,
    semantic_index: UINT = 0,
    format: UINT,
    input_slot: UINT = 0,
    aligned_byte_offset: UINT,
    input_slot_class: UINT = D3D11_INPUT_PER_VERTEX_DATA,
    instance_data_step_rate: UINT = 0,
};
const D3D11_SAMPLER_DESC = extern struct {
    filter: UINT,
    address_u: UINT,
    address_v: UINT,
    address_w: UINT,
    mip_lod_bias: f32 = 0,
    max_anisotropy: UINT = 1,
    comparison_func: UINT = 1, // NEVER
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    min_lod: f32 = 0,
    max_lod: f32 = 3.4e38,
};
const D3D11_VIEWPORT = extern struct {
    top_left_x: f32 = 0,
    top_left_y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};
const D3D11_RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

// D3DCompile lives in d3dcompiler_47.dll, which ships with Windows but has
// no Zig-bundled import lib — so load it dynamically (kernel32 does have an
// import lib). Avoids a link-time dependency on the DirectX SDK entirely.
const D3DCompileFn = *const fn (
    src_data: *const anyopaque,
    src_size: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entrypoint: [*:0]const u8,
    target: [*:0]const u8,
    flags1: UINT,
    flags2: UINT,
    code: *?*IBlob,
    error_msgs: *?*IBlob,
) callconv(WINAPI) HRESULT;

extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(WINAPI) ?*anyopaque;

fn loadD3DCompile() ?D3DCompileFn {
    const dll = LoadLibraryA("d3dcompiler_47.dll") orelse return null;
    const p = GetProcAddress(dll, "D3DCompile") orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Compile one HLSL entry point to a bytecode blob (caller releases it).
fn compileSrc(d3d_compile: D3DCompileFn, src: []const u8, entry: [*:0]const u8, target: [*:0]const u8) ?*IBlob {
    var code: ?*IBlob = null;
    var errs: ?*IBlob = null;
    const hr = d3d_compile(src.ptr, src.len, "zooee.hlsl", null, null, entry, target, 0, 0, &code, &errs);
    if (errs) |e| release(e);
    if (!ok(hr)) return null;
    return code;
}

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

const ISwapChain = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [8]*const anyopaque, // IUnknown(3)+IDXGIObject(4)+GetDevice(1)
        Present: *const fn (*ISwapChain, UINT, UINT) callconv(WINAPI) HRESULT, // 8
        GetBuffer: *const fn (*ISwapChain, UINT, *const GUID, *?*ITexture2D) callconv(WINAPI) HRESULT, // 9
        _pad1: [3]*const anyopaque, // SetFullscreenState(10)+GetFullscreenState(11)+GetDesc(12)
        ResizeBuffers: *const fn (*ISwapChain, UINT, UINT, UINT, UINT, UINT) callconv(WINAPI) HRESULT, // 13
    };
};

extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    adapter: ?*anyopaque,
    driver_type: UINT,
    software: ?*anyopaque,
    flags: UINT,
    feature_levels: ?[*]const UINT,
    num_feature_levels: UINT,
    sdk_version: UINT,
    swap_chain_desc: *const DXGI_SWAP_CHAIN_DESC,
    swap_chain: *?*ISwapChain,
    device: *?*IDevice,
    feature_level: ?*UINT,
    context: *?*IContext,
) callconv(WINAPI) HRESULT;

/// A D3D11 device + context + DXGI swapchain bound to a Win32 window — the
/// GPU-present path for runWindow. Requires the interactive desktop session
/// (DXGI fails NOT_CURRENTLY_AVAILABLE in service/SSH sessions); the caller
/// falls back to the CPU raster + GDI blit path when create() errors.
pub const D3dSwapchain = struct {
    device: *IDevice,
    context: *IContext,
    swapchain: *ISwapChain,
    width: u32,
    height: u32,

    pub fn create(hwnd: *anyopaque, width: u32, height: u32) Error!D3dSwapchain {
        var desc: DXGI_SWAP_CHAIN_DESC = .{
            .buffer_desc = .{ .width = width, .height = height, .format = DXGI_FORMAT_R8G8B8A8_UNORM },
            .buffer_usage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .buffer_count = 2,
            .output_window = hwnd,
            .windowed = 1,
        };
        var swapchain: ?*ISwapChain = null;
        var device: ?*IDevice = null;
        var context: ?*IContext = null;
        for ([_]UINT{ D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP }) |driver| {
            if (ok(D3D11CreateDeviceAndSwapChain(null, driver, null, 0, null, 0, D3D11_SDK_VERSION, &desc, &swapchain, &device, null, &context))) break;
        }
        if (swapchain == null or device == null or context == null) return error.NoDevice;
        return .{ .device = device.?, .context = context.?, .swapchain = swapchain.?, .width = width, .height = height };
    }

    pub fn destroy(self: *D3dSwapchain) void {
        release(self.swapchain);
        release(self.context);
        release(self.device);
    }

    /// The swapchain's back-buffer texture (caller releases). CopyResource
    /// the rendered frame into it, then present().
    pub fn backBuffer(self: *D3dSwapchain) Error!*ITexture2D {
        var bb: ?*ITexture2D = null;
        if (!ok(self.swapchain.vtbl.GetBuffer(self.swapchain, 0, &IID_ID3D11Texture2D, &bb)) or bb == null) return error.NoBackBuffer;
        return bb.?;
    }

    pub fn present(self: *D3dSwapchain) void {
        _ = self.swapchain.vtbl.Present(self.swapchain, 0, 0);
    }

    /// Resize the swapchain's back buffer to match the window's client area.
    /// Required on WM_SIZE: otherwise CopyResource into a stale-size back
    /// buffer is a no-op and Present stretches the old frame. The caller must
    /// hold no outstanding back-buffer reference (presentTo releases its own
    /// each frame, so this is safe between frames). No-op if unchanged.
    pub fn resize(self: *D3dSwapchain, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) return; // minimized — keep current
        if (width == self.width and height == self.height) return;
        // 0 buffer count / DXGI_FORMAT_UNKNOWN(0) = preserve existing.
        if (!ok(self.swapchain.vtbl.ResizeBuffers(self.swapchain, 0, width, height, 0, 0)))
            return error.ResizeFailed;
        self.width = width;
        self.height = height;
    }
};

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
    /// false when the device is borrowed (e.g. from a swapchain) — destroy
    /// must not release it then.
    owns_device: bool = true,

    /// Build the render target on an existing device/context (borrowed).
    pub fn createOnDevice(device: *IDevice, context: *IContext, width: u32, height: u32) Error!D3dOffscreen {
        var tdesc: D3D11_TEXTURE2D_DESC = .{ .width = width, .height = height, .format = DXGI_FORMAT_R8G8B8A8_UNORM, .usage = D3D11_USAGE_DEFAULT, .bind_flags = D3D11_BIND_RENDER_TARGET };
        var target: ?*ITexture2D = null;
        if (!ok(device.vtbl.CreateTexture2D(device, &tdesc, null, &target)) or target == null) return error.NoBackBuffer;
        errdefer release(target.?);
        var rtv: ?*IRtv = null;
        if (!ok(device.vtbl.CreateRenderTargetView(device, target.?, null, &rtv)) or rtv == null) return error.NoRtv;
        return .{ .device = device, .context = context, .target = target.?, .rtv = rtv.?, .width = width, .height = height, .owns_device = false };
    }

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
        if (self.owns_device) {
            release(self.context);
            release(self.device);
        }
    }

    /// Recreate the render-target texture + view at a new size (keeps the
    /// device/context). Used by D3dBackend.beginFrame when the viewport
    /// changes across frames/fixtures.
    pub fn resize(self: *D3dOffscreen, width: u32, height: u32) Error!void {
        if (width == self.width and height == self.height) return;
        var tdesc: D3D11_TEXTURE2D_DESC = .{ .width = width, .height = height, .format = DXGI_FORMAT_R8G8B8A8_UNORM, .usage = D3D11_USAGE_DEFAULT, .bind_flags = D3D11_BIND_RENDER_TARGET };
        var target: ?*ITexture2D = null;
        if (!ok(self.device.vtbl.CreateTexture2D(self.device, &tdesc, null, &target)) or target == null) return error.NoBackBuffer;
        var rtv: ?*IRtv = null;
        if (!ok(self.device.vtbl.CreateRenderTargetView(self.device, target.?, null, &rtv)) or rtv == null) {
            release(target.?);
            return error.NoRtv;
        }
        release(self.rtv);
        release(self.target);
        self.target = target.?;
        self.rtv = rtv.?;
        self.width = width;
        self.height = height;
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

    // Slice 2: textured fullscreen quad. Upload an RGBA image and draw it
    // 1:1 into the render target through the shader pipeline (point sampling
    // to match raster). The HLSL mirrors gl.zig's slice-2 textured quad; the
    // texture is top-down RGBA and D3D's texel origin is top-left, so no
    // v-flip is needed (unlike GL).
    const hlsl =
        \\struct VSIn  { float2 pos : POSITION; float2 uv : TEXCOORD; };
        \\struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
        \\VSOut VSMain(VSIn i) { VSOut o; o.pos = float4(i.pos, 0, 1); o.uv = i.uv; return o; }
        \\Texture2D tex : register(t0);
        \\SamplerState smp : register(s0);
        \\float4 PSMain(VSOut i) : SV_TARGET { return tex.Sample(smp, i.uv); }
    ;

    /// Draw `rgba` (w×h, top-down) as a fullscreen textured quad into the
    /// render target. Point sampling, clamp — matches raster's nearest.
    pub fn drawTexture(self: *D3dOffscreen, rgba: []const u8, w: u32, h: u32) Error!void {
        const dev = self.device;
        const ctx = self.context;

        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);
        const ps_ptr = ps_blob.vtbl.GetBufferPointer(ps_blob).?;
        const ps_len = ps_blob.vtbl.GetBufferSize(ps_blob);

        var vs: ?*IVertexShader = null;
        if (!ok(dev.vtbl.CreateVertexShader(dev, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        defer release(vs.?);
        var ps: ?*IPixelShader = null;
        if (!ok(dev.vtbl.CreatePixelShader(dev, ps_ptr, ps_len, null, &ps)) or ps == null) return error.ShaderFailed;
        defer release(ps.?);

        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
            .{ .semantic_name = "TEXCOORD", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 8 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(dev.vtbl.CreateInputLayout(dev, &elems, 2, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        defer release(layout.?);

        // Fullscreen triangle strip: pos.xy (NDC), uv.xy. No v-flip (D3D
        // texel origin is top-left, render target is top-down).
        const verts = [_]f32{
            -1, -1, 0, 1,
            1,  -1, 1, 1,
            -1, 1,  0, 0,
            1,  1,  1, 0,
        };
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        // Source texture + shader resource view.
        var tdesc: D3D11_TEXTURE2D_DESC = .{
            .width = w,
            .height = h,
            .format = DXGI_FORMAT_R8G8B8A8_UNORM,
            .usage = D3D11_USAGE_IMMUTABLE,
            .bind_flags = D3D11_BIND_SHADER_RESOURCE,
        };
        var tdata: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = rgba.ptr, .sys_mem_pitch = w * 4 };
        var tex: ?*ITexture2D = null;
        if (!ok(dev.vtbl.CreateTexture2D(dev, &tdesc, &tdata, &tex)) or tex == null) return error.ShaderFailed;
        defer release(tex.?);
        var srv: ?*ISrv = null;
        if (!ok(dev.vtbl.CreateShaderResourceView(dev, tex.?, null, &srv)) or srv == null) return error.ShaderFailed;
        defer release(srv.?);

        var sdesc: D3D11_SAMPLER_DESC = .{
            .filter = D3D11_FILTER_MIN_MAG_MIP_POINT,
            .address_u = D3D11_TEXTURE_ADDRESS_CLAMP,
            .address_v = D3D11_TEXTURE_ADDRESS_CLAMP,
            .address_w = D3D11_TEXTURE_ADDRESS_CLAMP,
        };
        var sampler: ?*ISampler = null;
        if (!ok(dev.vtbl.CreateSamplerState(dev, &sdesc, &sampler)) or sampler == null) return error.ShaderFailed;
        defer release(sampler.?);

        // Rasterizer state with no back-face culling — D3D culls back faces
        // by default (GL doesn't), which would drop the fullscreen quad.
        var rdesc: D3D11_RASTERIZER_DESC = .{};
        var raster: ?*IRasterizerState = null;
        if (!ok(dev.vtbl.CreateRasterizerState(dev, &rdesc, &raster)) or raster == null) return error.ShaderFailed;
        defer release(raster.?);

        // Bind pipeline + draw.
        var vp: D3D11_VIEWPORT = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, raster.?);
        var rtv_slot: ?*IRtv = self.rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, layout.?);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 16;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, vs.?, null, 0);
        ctx.vtbl.PSSetShader(ctx, ps.?, null, 0);
        var srv_slot: ?*ISrv = srv.?;
        ctx.vtbl.PSSetShaderResources(ctx, 0, 1, &srv_slot);
        var samp_slot: ?*ISampler = sampler.?;
        ctx.vtbl.PSSetSamplers(ctx, 0, 1, &samp_slot);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Slice 3: native rect geometry ==========================================
// Draws solid-color rects as GPU triangle-strip quads — the first true GPU
// *drawing* (vs texturing a CPU image). Mirrors gl.zig's RectRenderer: the VS
// maps pixel coords → NDC via a viewport constant buffer, the PS outputs the
// uniform color. Shaders/layout/rasterizer are compiled once; each fillRect
// uploads a 4-vertex quad + a {viewport,color} constant buffer.

const rect_hlsl =
    \\cbuffer CB : register(b0) { float2 viewport; float2 pad; float4 color; };
    \\struct VSIn  { float2 pos : POSITION; };
    \\struct VSOut { float4 pos : SV_POSITION; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  float2 ndc = float2(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0);
    \\  o.pos = float4(ndc, 0, 1);
    \\  return o;
    \\}
    \\float4 PSMain(VSOut i) : SV_TARGET { return color; }
;

const RectCB = extern struct { vw: f32, vh: f32, pad0: f32 = 0, pad1: f32 = 0, color: [4]f32 };

pub const D3dRectRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,

    pub fn init(device: *IDevice, context: *IContext, scissor: bool) Error!D3dRectRenderer {
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, rect_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, rect_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);

        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 1, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = @intFromBool(scissor) };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;

        return .{ .device = device, .context = context, .vs = vs.?, .ps = ps.?, .layout = layout.?, .raster = raster.? };
    }

    pub fn deinit(self: *D3dRectRenderer) void {
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
    }

    /// Fill a rect (pixel coords, y-down) into the render target. `vw`/`vh`
    /// are the framebuffer size; color is RGBA 0..1.
    pub fn fillRect(self: *D3dRectRenderer, rtv: *IRtv, vw: f32, vh: f32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) Error!void {
        const dev = self.device;
        const ctx = self.context;
        const verts = [_]f32{ x, y, x + w, y, x, y + h, x + w, y + h };
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        var cbv: RectCB = .{ .vw = vw, .vh = vh, .color = color };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(RectCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 8;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot); // viewport (VS)
        ctx.vtbl.PSSetConstantBuffers(ctx, 0, 1, &cb_slot); // color (PS)
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Linear gradient fill (#118) ============================================
// Mirrors the Metal/GL gradient renderers: a full-rect quad whose PS
// interpolates from→to along the axis using the fragment's pixel position.
// SV_Position is the pixel center, top-left origin (like raster) — no y-flip.

const grad_hlsl =
    \\cbuffer CB : register(b0) { float2 viewport; float axis; float pad; float4 rect; float4 c0; float4 c1; };
    \\struct VSIn  { float2 pos : POSITION; };
    \\struct VSOut { float4 pos : SV_POSITION; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  o.pos = float4(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0, 0, 1);
    \\  return o;
    \\}
    \\float4 PSMain(VSOut i) : SV_TARGET {
    \\  float t = (axis < 0.5) ? (i.pos.x - rect.x) / rect.z : (i.pos.y - rect.y) / rect.w;
    \\  t = saturate(t);
    \\  return lerp(c0, c1, t);
    \\}
;

const GradCB = extern struct { vw: f32, vh: f32, axis: f32, pad: f32 = 0, rect: [4]f32, c0: [4]f32, c1: [4]f32 };

pub const D3dGradientRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,

    pub fn init(device: *IDevice, context: *IContext, scissor: bool) Error!D3dGradientRenderer {
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, grad_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, grad_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);

        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 1, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = @intFromBool(scissor) };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;

        return .{ .device = device, .context = context, .vs = vs.?, .ps = ps.?, .layout = layout.?, .raster = raster.? };
    }

    pub fn deinit(self: *D3dGradientRenderer) void {
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
    }

    pub fn fill(self: *D3dGradientRenderer, rtv: *IRtv, vw: f32, vh: f32, rect: geometry.Rect, axis: f32, c0: [4]f32, c1: [4]f32) Error!void {
        const dev = self.device;
        const ctx = self.context;
        const verts = [_]f32{ rect.x, rect.y, rect.x + rect.width, rect.y, rect.x, rect.y + rect.height, rect.x + rect.width, rect.y + rect.height };
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        var cbv: GradCB = .{ .vw = vw, .vh = vh, .axis = axis, .rect = .{ rect.x, rect.y, rect.width, rect.height }, .c0 = c0, .c1 = c1 };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(GradCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        ctx.vtbl.OMSetBlendState(ctx, null, null, 0xffffffff); // opaque fill
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 8;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot);
        ctx.vtbl.PSSetConstantBuffers(ctx, 0, 1, &cb_slot);
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Slice 4: SDF rounded rects + border ====================================
// Ports gl.zig's RoundedRectRenderer: a signed-distance pixel shader gives
// anti-aliased rounded corners + a uniform border in one draw, matching
// raster's RectStyle (bg + corner_radius + border). The VS passes a per-
// vertex `local` (rect-center-relative) coord; the PS evaluates sdRoundBox,
// smoothsteps the edge (~1px AA) and the border, and mixes the two colors.

const round_hlsl =
    \\cbuffer CB : register(b0) {
    \\  float2 viewport; float2 half_size;
    \\  float radius; float border; float2 pad;
    \\  float4 bg; float4 border_color;
    \\};
    \\struct VSIn  { float2 pos : POSITION; float2 local : TEXCOORD; };
    \\struct VSOut { float4 pos : SV_POSITION; float2 local : TEXCOORD; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  float2 ndc = float2(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0);
    \\  o.pos = float4(ndc, 0, 1);
    \\  o.local = i.local;
    \\  return o;
    \\}
    \\float sdRoundBox(float2 p, float2 b, float r) {
    \\  float2 q = abs(p) - b + r;
    \\  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\float4 PSMain(VSOut i) : SV_TARGET {
    \\  float d = sdRoundBox(i.local, half_size, radius);
    \\  float outer = smoothstep(1.0, -1.0, d);
    \\  float fill = smoothstep(1.0, -1.0, d + border);
    \\  float4 col = lerp(border_color, bg, fill);
    \\  col.a *= outer;
    \\  return col;
    \\}
;

const RoundCB = extern struct {
    vw: f32,
    vh: f32,
    hw: f32,
    hh: f32,
    radius: f32,
    border: f32,
    pad0: f32 = 0,
    pad1: f32 = 0,
    bg: [4]f32,
    border_color: [4]f32,
};

pub const D3dRoundedRectRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,
    blend: *IBlendState,

    pub fn init(device: *IDevice, context: *IContext, scissor: bool) Error!D3dRoundedRectRenderer {
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, round_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, round_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);

        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
            .{ .semantic_name = "TEXCOORD", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 8 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 2, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = @intFromBool(scissor) };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;

        // Source-over alpha blend so the SDF coverage/cut composites against
        // the background (D3D has no blending by default — GL had it on).
        var bdesc: D3D11_BLEND_DESC = .{ .render_target = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8 };
        bdesc.render_target[0] = .{
            .blend_enable = 1,
            .src_blend = D3D11_BLEND_SRC_ALPHA,
            .dest_blend = D3D11_BLEND_INV_SRC_ALPHA,
            .blend_op = D3D11_BLEND_OP_ADD,
            .src_blend_alpha = D3D11_BLEND_ONE,
            .dest_blend_alpha = D3D11_BLEND_INV_SRC_ALPHA,
            .blend_op_alpha = D3D11_BLEND_OP_ADD,
        };
        var blend: ?*IBlendState = null;
        if (!ok(device.vtbl.CreateBlendState(device, &bdesc, &blend)) or blend == null) return error.ShaderFailed;

        return .{ .device = device, .context = context, .vs = vs.?, .ps = ps.?, .layout = layout.?, .raster = raster.?, .blend = blend.? };
    }

    pub fn deinit(self: *D3dRoundedRectRenderer) void {
        release(self.blend);
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
    }

    /// Rounded rect (pixel coords, y-down) with uniform radius + border.
    /// bg/border_color are RGBA 0..1.
    pub fn draw(self: *D3dRoundedRectRenderer, rtv: *IRtv, vw: f32, vh: f32, x: f32, y: f32, w: f32, h: f32, radius: f32, border: f32, bg: [4]f32, border_color: [4]f32) Error!void {
        const dev = self.device;
        const ctx = self.context;
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
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        var cbv: RoundCB = .{ .vw = vw, .vh = vh, .hw = hw, .hh = hh, .radius = radius, .border = border, .bg = bg, .border_color = border_color };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(RoundCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        ctx.vtbl.OMSetBlendState(ctx, self.blend, null, 0xffffffff);
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 16;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot); // viewport (VS)
        ctx.vtbl.PSSetConstantBuffers(ctx, 0, 1, &cb_slot); // sdf params + colors (PS)
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Slice 5: glyph atlas text ==============================================
// Reuses the font rasterizer (font/raster.zig) to produce glyph alpha
// bitmaps, shelf-packs ASCII 32..126 into one RGBA atlas texture (rgb=255,
// a=coverage), and draws text as a batch of textured-quad triangles tinted
// by the text color. Same approach as gl.zig's GlyphRenderer (non-ASCII /
// dynamic glyphs are a follow-up, tracked separately).

const atlas_dim: u32 = 512;

const glyph_hlsl =
    \\cbuffer CB : register(b0) { float2 viewport; float2 pad; float4 color; };
    \\struct VSIn  { float2 pos : POSITION; float2 uv : TEXCOORD; };
    \\struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  o.pos = float4(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0, 0, 1);
    \\  o.uv = i.uv;
    \\  return o;
    \\}
    \\Texture2D atlas : register(t0);
    \\SamplerState smp : register(s0);
    \\float4 PSMain(VSOut i) : SV_TARGET {
    \\  float a = atlas.Sample(smp, i.uv).a;
    \\  return float4(color.rgb, color.a * a);
    \\}
;

const GlyphCB = extern struct { vw: f32, vh: f32, pad0: f32 = 0, pad1: f32 = 0, color: [4]f32 };

pub const D3dGlyphRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,
    blend: *IBlendState,
    sampler: *ISampler,
    atlas_tex: *ITexture2D,
    atlas_srv: *ISrv,
    atlas: gatlas.Atlas,

    pub fn init(gpa: std.mem.Allocator, device: *IDevice, context: *IContext, font: *const ttf.Font, size_px: f32, scissor: bool) !D3dGlyphRenderer {
        var atlas = try gatlas.Atlas.init(gpa, font, size_px, atlas_dim, atlas_dim);
        errdefer atlas.deinit();

        // GPU resources.
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, glyph_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, glyph_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);

        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
            .{ .semantic_name = "TEXCOORD", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 8 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 2, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = @intFromBool(scissor) };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;
        var bdesc: D3D11_BLEND_DESC = .{ .render_target = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8 };
        bdesc.render_target[0] = .{ .blend_enable = 1, .src_blend = D3D11_BLEND_SRC_ALPHA, .dest_blend = D3D11_BLEND_INV_SRC_ALPHA, .blend_op = D3D11_BLEND_OP_ADD, .src_blend_alpha = D3D11_BLEND_ONE, .dest_blend_alpha = D3D11_BLEND_INV_SRC_ALPHA, .blend_op_alpha = D3D11_BLEND_OP_ADD };
        var blend: ?*IBlendState = null;
        if (!ok(device.vtbl.CreateBlendState(device, &bdesc, &blend)) or blend == null) return error.ShaderFailed;

        var tdesc: D3D11_TEXTURE2D_DESC = .{ .width = atlas_dim, .height = atlas_dim, .format = DXGI_FORMAT_R8G8B8A8_UNORM, .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_SHADER_RESOURCE };
        var tdata: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = atlas.pixels.ptr, .sys_mem_pitch = atlas_dim * 4 };
        var tex: ?*ITexture2D = null;
        if (!ok(device.vtbl.CreateTexture2D(device, &tdesc, &tdata, &tex)) or tex == null) return error.ShaderFailed;
        var srv: ?*ISrv = null;
        if (!ok(device.vtbl.CreateShaderResourceView(device, tex.?, null, &srv)) or srv == null) return error.ShaderFailed;
        var sdesc: D3D11_SAMPLER_DESC = .{ .filter = D3D11_FILTER_MIN_MAG_MIP_POINT, .address_u = D3D11_TEXTURE_ADDRESS_CLAMP, .address_v = D3D11_TEXTURE_ADDRESS_CLAMP, .address_w = D3D11_TEXTURE_ADDRESS_CLAMP };
        var sampler: ?*ISampler = null;
        if (!ok(device.vtbl.CreateSamplerState(device, &sdesc, &sampler)) or sampler == null) return error.ShaderFailed;
        atlas.dirty = false; // initial (empty) atlas just uploaded

        return .{
            .device = device,
            .context = context,
            .vs = vs.?,
            .ps = ps.?,
            .layout = layout.?,
            .raster = raster.?,
            .blend = blend.?,
            .sampler = sampler.?,
            .atlas_tex = tex.?,
            .atlas_srv = srv.?,
            .atlas = atlas,
        };
    }

    pub fn deinit(self: *D3dGlyphRenderer) void {
        release(self.atlas_srv);
        release(self.atlas_tex);
        release(self.sampler);
        release(self.blend);
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
        self.atlas.deinit();
    }

    /// Recreate the atlas texture + SRV from the CPU pixels if new glyphs were
    /// packed (D3D11 IMMUTABLE textures can't be updated; recreating avoids the
    /// UpdateSubresource/Map vtable plumbing and only happens when glyphs are
    /// first seen). The atlas only appends, so this is rare after warm-up.
    fn uploadAtlas(self: *D3dGlyphRenderer) Error!void {
        if (!self.atlas.dirty) return;
        var tdesc: D3D11_TEXTURE2D_DESC = .{ .width = self.atlas.width, .height = self.atlas.height, .format = DXGI_FORMAT_R8G8B8A8_UNORM, .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_SHADER_RESOURCE };
        var tdata: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = self.atlas.pixels.ptr, .sys_mem_pitch = self.atlas.width * 4 };
        var tex: ?*ITexture2D = null;
        if (!ok(self.device.vtbl.CreateTexture2D(self.device, &tdesc, &tdata, &tex)) or tex == null) return error.ShaderFailed;
        var srv: ?*ISrv = null;
        if (!ok(self.device.vtbl.CreateShaderResourceView(self.device, tex.?, null, &srv)) or srv == null) {
            release(tex.?);
            return error.ShaderFailed;
        }
        release(self.atlas_srv);
        release(self.atlas_tex);
        self.atlas_tex = tex.?;
        self.atlas_srv = srv.?;
        self.atlas.dirty = false;
    }

    /// Draw `text` (UTF-8, any codepoint) at pixel (x,y) (top-left) tinted
    /// `color` into the render target. Glyphs rasterized + packed on demand
    /// into the dynamic atlas (#114); the texture is recreated before the draw
    /// when new glyphs appear (the atlas appends, so existing UVs stay valid).
    pub fn drawText(self: *D3dGlyphRenderer, gpa: std.mem.Allocator, rtv: *IRtv, vw: f32, vh: f32, x: f32, y: f32, text: []const u8, color: [4]f32) !void {
        const dev = self.device;
        const ctx = self.context;
        var verts: std.ArrayList(f32) = .empty;
        defer verts.deinit(gpa);
        var pen = x;
        const baseline = y + self.atlas.ascent;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const e = self.atlas.glyph(self.atlas.font.glyphIndex(cp));
            if (e.w > 0) {
                const gx = @round(pen) + e.x_off;
                const gy = @round(baseline) + e.y_off;
                const x1 = gx + e.w;
                const y1 = gy + e.h;
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
        try self.uploadAtlas();

        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = verts.items.ptr };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @intCast(verts.items.len * 4), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        var cbv: GlyphCB = .{ .vw = vw, .vh = vh, .color = color };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(GlyphCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        ctx.vtbl.OMSetBlendState(ctx, self.blend, null, 0xffffffff);
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 16;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot); // viewport (VS)
        ctx.vtbl.PSSetConstantBuffers(ctx, 0, 1, &cb_slot); // color (PS)
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        var srv_slot: ?*ISrv = self.atlas_srv;
        ctx.vtbl.PSSetShaderResources(ctx, 0, 1, &srv_slot);
        var samp_slot: ?*ISampler = self.sampler;
        ctx.vtbl.PSSetSamplers(ctx, 0, 1, &samp_slot);
        ctx.vtbl.Draw(ctx, @intCast(verts.items.len / 4), 0);
    }
};

// === Image renderer (positioned textured quad) ==============================
// drawImage: sample a texture (by SRV) into a pixel-space rect. Point/clamp
// to match raster's nearest, no blend (opaque copy). Scissor-enabled so the
// Backend's clip stack applies.

const image_hlsl =
    \\cbuffer CB : register(b0) { float2 viewport; float2 pad; };
    \\struct VSIn  { float2 pos : POSITION; float2 uv : TEXCOORD; };
    \\struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  o.pos = float4(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0, 0, 1);
    \\  o.uv = i.uv;
    \\  return o;
    \\}
    \\Texture2D tex : register(t0);
    \\SamplerState smp : register(s0);
    \\float4 PSMain(VSOut i) : SV_TARGET { return tex.Sample(smp, i.uv); }
;
const ImageCB = extern struct { vw: f32, vh: f32, pad0: f32 = 0, pad1: f32 = 0 };

const D3dImageRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,
    sampler: *ISampler,

    fn init(device: *IDevice, context: *IContext) Error!D3dImageRenderer {
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, image_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, image_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);
        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
            .{ .semantic_name = "TEXCOORD", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 8 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 2, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = 1 };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;
        var sdesc: D3D11_SAMPLER_DESC = .{ .filter = D3D11_FILTER_MIN_MAG_MIP_POINT, .address_u = D3D11_TEXTURE_ADDRESS_CLAMP, .address_v = D3D11_TEXTURE_ADDRESS_CLAMP, .address_w = D3D11_TEXTURE_ADDRESS_CLAMP };
        var sampler: ?*ISampler = null;
        if (!ok(device.vtbl.CreateSamplerState(device, &sdesc, &sampler)) or sampler == null) return error.ShaderFailed;
        return .{ .device = device, .context = context, .vs = vs.?, .ps = ps.?, .layout = layout.?, .raster = raster.?, .sampler = sampler.? };
    }

    fn deinit(self: *D3dImageRenderer) void {
        release(self.sampler);
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
    }

    fn draw(self: *D3dImageRenderer, rtv: *IRtv, vw: f32, vh: f32, rect: geometry.Rect, srv: *ISrv) Error!void {
        const dev = self.device;
        const ctx = self.context;
        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.width;
        const y1 = rect.y + rect.height;
        const verts = [_]f32{ x0, y0, 0, 0, x1, y0, 1, 0, x0, y1, 0, 1, x1, y1, 1, 1 };
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);
        var cbv: ImageCB = .{ .vw = vw, .vh = vh };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(ImageCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        ctx.vtbl.OMSetBlendState(ctx, null, null, 0xffffffff); // opaque copy
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 16;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot);
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        var srv_slot: ?*ISrv = srv;
        ctx.vtbl.PSSetShaderResources(ctx, 0, 1, &srv_slot);
        var samp_slot: ?*ISampler = self.sampler;
        ctx.vtbl.PSSetSamplers(ctx, 0, 1, &samp_slot);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Slice 7: exact rect renderer (per-side borders, per-corner radii) ======
// Ports gl.zig's ExactRectRenderer: a pixel shader that replicates
// raster.zig's insideRounded() + borderColorAt() per fragment (pixel-center
// sampling, per-corner radii, per-side border colors, hard edges / no AA),
// matching the raster reference pixel-exact. SV_Position gives the pixel
// center; D3D's window origin is top-left like our rects, so — unlike GL —
// there is NO y-flip.

const exact_hlsl =
    \\cbuffer CB : register(b0) {
    \\  float2 viewport; float2 pad0;
    \\  float4 rect; float4 rad; float4 inner; float4 irad; float4 bw;
    \\  float4 bg; float4 ct; float4 cr; float4 cb; float4 cl; float4 flags;
    \\};
    \\struct VSIn  { float2 pos : POSITION; };
    \\struct VSOut { float4 pos : SV_POSITION; };
    \\VSOut VSMain(VSIn i) {
    \\  VSOut o;
    \\  o.pos = float4(i.pos.x / viewport.x * 2.0 - 1.0, 1.0 - i.pos.y / viewport.y * 2.0, 0, 1);
    \\  return o;
    \\}
    \\bool cornerOut(float2 p, float trad, float cx, float cy, float2 r0, float2 rsz) {
    \\  if (trad <= 0.0) return false;
    \\  bool in_x = (cx <= r0.x + rsz.x*0.5) ? (p.x < cx) : (p.x > cx);
    \\  bool in_y = (cy <= r0.y + rsz.y*0.5) ? (p.y < cy) : (p.y > cy);
    \\  if (in_x && in_y) { float dx = p.x-cx; float dy = p.y-cy; return dx*dx+dy*dy > trad*trad; }
    \\  return false;
    \\}
    \\bool insideRounded(float4 r, float4 rd, float2 p) {
    \\  if (p.x < r.x || p.x >= r.x + r.z || p.y < r.y || p.y >= r.y + r.w) return false;
    \\  float mx = min(r.z, r.w) * 0.5;
    \\  float2 r0 = r.xy; float2 rsz = r.zw;
    \\  if (cornerOut(p, min(rd.x, mx), r.x + rd.x,       r.y + rd.x,       r0, rsz)) return false;
    \\  if (cornerOut(p, min(rd.y, mx), r.x + r.z - rd.y, r.y + rd.y,       r0, rsz)) return false;
    \\  if (cornerOut(p, min(rd.z, mx), r.x + r.z - rd.z, r.y + r.w - rd.z, r0, rsz)) return false;
    \\  if (cornerOut(p, min(rd.w, mx), r.x + rd.w,       r.y + r.w - rd.w, r0, rsz)) return false;
    \\  return true;
    \\}
    \\float4 borderColorAt(float2 p) {
    \\  if (p.x < rect.x + rad.x && p.y < rect.y + rad.x) return (bw.x > 0.0) ? ct : cl;
    \\  if (p.x >= rect.x + rect.z - rad.y && p.y < rect.y + rad.y) return (bw.x > 0.0) ? ct : cr;
    \\  if (p.x >= rect.x + rect.z - rad.z && p.y >= rect.y + rect.w - rad.z) return (bw.z > 0.0) ? cb : cr;
    \\  if (p.x < rect.x + rad.w && p.y >= rect.y + rect.w - rad.w) return (bw.z > 0.0) ? cb : cl;
    \\  if (p.y < inner.y) return ct;
    \\  if (p.y >= inner.y + inner.w) return cb;
    \\  if (p.x < inner.x) return cl;
    \\  return cr;
    \\}
    \\float4 PSMain(VSOut i) : SV_TARGET {
    \\  float2 p = i.pos.xy; // pixel center, top-left origin — no flip
    \\  if (!insideRounded(rect, rad, p)) { discard; }
    \\  bool has_border = (bw.x + bw.y + bw.z + bw.w) > 0.0;
    \\  if (has_border && !insideRounded(inner, irad, p)) return borderColorAt(p);
    \\  if (flags.x > 0.5) return bg;
    \\  discard;
    \\  return float4(0,0,0,0);
    \\}
;

const ExactCB = extern struct {
    vw: f32,
    vh: f32,
    pad0: f32 = 0,
    pad1: f32 = 0,
    rect: [4]f32,
    rad: [4]f32,
    inner: [4]f32,
    irad: [4]f32,
    bw: [4]f32,
    bg: [4]f32,
    ct: [4]f32,
    cr: [4]f32,
    cb: [4]f32,
    cl: [4]f32,
    flags: [4]f32,
};

pub const D3dExactRectRenderer = struct {
    device: *IDevice,
    context: *IContext,
    vs: *IVertexShader,
    ps: *IPixelShader,
    layout: *IInputLayout,
    raster: *IRasterizerState,
    blend: *IBlendState,

    pub fn init(device: *IDevice, context: *IContext, scissor: bool) Error!D3dExactRectRenderer {
        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compileSrc(d3d_compile, exact_hlsl, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compileSrc(d3d_compile, exact_hlsl, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
        defer release(ps_blob);
        const vs_ptr = vs_blob.vtbl.GetBufferPointer(vs_blob).?;
        const vs_len = vs_blob.vtbl.GetBufferSize(vs_blob);
        var vs: ?*IVertexShader = null;
        if (!ok(device.vtbl.CreateVertexShader(device, vs_ptr, vs_len, null, &vs)) or vs == null) return error.ShaderFailed;
        var ps: ?*IPixelShader = null;
        if (!ok(device.vtbl.CreatePixelShader(device, ps_blob.vtbl.GetBufferPointer(ps_blob).?, ps_blob.vtbl.GetBufferSize(ps_blob), null, &ps)) or ps == null) return error.ShaderFailed;
        var elems = [_]D3D11_INPUT_ELEMENT_DESC{
            .{ .semantic_name = "POSITION", .format = DXGI_FORMAT_R32G32_FLOAT, .aligned_byte_offset = 0 },
        };
        var layout: ?*IInputLayout = null;
        if (!ok(device.vtbl.CreateInputLayout(device, &elems, 1, vs_ptr, vs_len, &layout)) or layout == null) return error.ShaderFailed;
        var rdesc: D3D11_RASTERIZER_DESC = .{ .scissor_enable = @intFromBool(scissor) };
        var raster: ?*IRasterizerState = null;
        if (!ok(device.vtbl.CreateRasterizerState(device, &rdesc, &raster)) or raster == null) return error.ShaderFailed;
        var bdesc: D3D11_BLEND_DESC = .{ .render_target = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8 };
        bdesc.render_target[0] = .{ .blend_enable = 1, .src_blend = D3D11_BLEND_SRC_ALPHA, .dest_blend = D3D11_BLEND_INV_SRC_ALPHA, .blend_op = D3D11_BLEND_OP_ADD, .src_blend_alpha = D3D11_BLEND_ONE, .dest_blend_alpha = D3D11_BLEND_INV_SRC_ALPHA, .blend_op_alpha = D3D11_BLEND_OP_ADD };
        var blend: ?*IBlendState = null;
        if (!ok(device.vtbl.CreateBlendState(device, &bdesc, &blend)) or blend == null) return error.ShaderFailed;
        return .{ .device = device, .context = context, .vs = vs.?, .ps = ps.?, .layout = layout.?, .raster = raster.?, .blend = blend.? };
    }

    pub fn deinit(self: *D3dExactRectRenderer) void {
        release(self.blend);
        release(self.raster);
        release(self.layout);
        release(self.ps);
        release(self.vs);
    }

    /// Draw one styled rect, replicating raster pixel-exact.
    pub fn draw(self: *D3dExactRectRenderer, rtv: *IRtv, vw: f32, vh: f32, rect: geometry.Rect, rs: style.RectStyle) Error!void {
        const dev = self.device;
        const ctx = self.context;
        const b = rs.border;
        const inner = [4]f32{
            rect.x + b.left.width,
            rect.y + b.top.width,
            @max(0, rect.width - b.left.width - b.right.width),
            @max(0, rect.height - b.top.width - b.bottom.width),
        };
        const crn = rs.corner_radius;
        const irad = [4]f32{
            @max(0, crn.top_left - @max(b.top.width, b.left.width)),
            @max(0, crn.top_right - @max(b.top.width, b.right.width)),
            @max(0, crn.bottom_right - @max(b.bottom.width, b.right.width)),
            @max(0, crn.bottom_left - @max(b.bottom.width, b.left.width)),
        };
        var cbv: ExactCB = .{
            .vw = vw,
            .vh = vh,
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .rad = .{ crn.top_left, crn.top_right, crn.bottom_right, crn.bottom_left },
            .inner = inner,
            .irad = irad,
            .bw = .{ b.top.width, b.right.width, b.bottom.width, b.left.width },
            .bg = if (rs.background) |bgc| col(bgc) else .{ 0, 0, 0, 0 },
            .ct = col(b.top.color),
            .cr = col(b.right.color),
            .cb = col(b.bottom.color),
            .cl = col(b.left.color),
            .flags = .{ if (rs.background != null) 1 else 0, 0, 0, 0 },
        };
        var cb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &cbv };
        var cb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(ExactCB), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_CONSTANT_BUFFER };
        var cb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &cb_desc, &cb_data, &cb)) or cb == null) return error.ShaderFailed;
        defer release(cb.?);

        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.width;
        const y1 = rect.y + rect.height;
        const verts = [_]f32{ x0, y0, x1, y0, x0, y1, x1, y1 };
        var vb_data: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = &verts };
        var vb_desc: D3D11_BUFFER_DESC = .{ .byte_width = @sizeOf(@TypeOf(verts)), .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_VERTEX_BUFFER };
        var vb: ?*IBuffer = null;
        if (!ok(dev.vtbl.CreateBuffer(dev, &vb_desc, &vb_data, &vb)) or vb == null) return error.ShaderFailed;
        defer release(vb.?);

        var vp: D3D11_VIEWPORT = .{ .width = vw, .height = vh };
        ctx.vtbl.RSSetViewports(ctx, 1, &vp);
        ctx.vtbl.RSSetState(ctx, self.raster);
        ctx.vtbl.OMSetBlendState(ctx, self.blend, null, 0xffffffff);
        var rtv_slot: ?*IRtv = rtv;
        ctx.vtbl.OMSetRenderTargets(ctx, 1, &rtv_slot, null);
        ctx.vtbl.IASetInputLayout(ctx, self.layout);
        var vb_slot: ?*IBuffer = vb.?;
        const stride: UINT = 8;
        const offset: UINT = 0;
        ctx.vtbl.IASetVertexBuffers(ctx, 0, 1, &vb_slot, &stride, &offset);
        ctx.vtbl.IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        ctx.vtbl.VSSetShader(ctx, self.vs, null, 0);
        var cb_slot: ?*IBuffer = cb.?;
        ctx.vtbl.VSSetConstantBuffers(ctx, 0, 1, &cb_slot);
        ctx.vtbl.PSSetConstantBuffers(ctx, 0, 1, &cb_slot);
        ctx.vtbl.PSSetShader(ctx, self.ps, null, 0);
        ctx.vtbl.Draw(ctx, 4, 0);
    }
};

// === Slice 6: the D3D11 Backend vtable =======================================
// Implements backend.zig's draw-primitive interface on the D3D11 renderers,
// so layout.render() drives D3D11 directly — matching GlBackend in gl.zig.
// drawRect routes solid→D3dRectRenderer (hard edges, matches raster) and
// bg/border/radius→D3dRoundedRectRenderer; clip→D3D11 scissor (intersection
// stack); text→a per-size glyph atlas cache. Per-side borders / per-corner
// radii approximate to uniform — a later "exact" slice (the GL slice-7
// equivalent) handles those pixel-exact, so the demo compares only the
// fixtures the current renderers reproduce exactly.

const ScissorRect = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

fn col(c: style.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255,
        @as(f32, @floatFromInt(c.g)) / 255,
        @as(f32, @floatFromInt(c.b)) / 255,
        @as(f32, @floatFromInt(c.a)) / 255,
    };
}

pub const D3dBackend = struct {
    gpa: std.mem.Allocator,
    off: D3dOffscreen,
    rect: D3dRectRenderer,
    exact: D3dExactRectRenderer,
    image: D3dImageRenderer,
    grad: D3dGradientRenderer,
    font: ?ttf.Font = null,
    glyphs: std.AutoHashMapUnmanaged(u32, D3dGlyphRenderer) = .empty,
    clips: std.ArrayList(ScissorRect) = .empty,

    /// Headless D3D11 Backend over an offscreen render target (golden tests).
    pub fn initOffscreen(gpa: std.mem.Allocator) !D3dBackend {
        var off = try D3dOffscreen.create(1, 1);
        errdefer off.destroy();
        return fromOffscreen(gpa, off);
    }

    /// D3D Backend on a borrowed device/context (e.g. a swapchain's) — the
    /// GPU-present path. Renders to an owned offscreen RT; the caller copies
    /// it to the swapchain back buffer (copyTo) and presents.
    pub fn initOnDevice(gpa: std.mem.Allocator, device: *IDevice, context: *IContext) !D3dBackend {
        var off = try D3dOffscreen.createOnDevice(device, context, 1, 1);
        errdefer off.destroy();
        return fromOffscreen(gpa, off);
    }

    fn fromOffscreen(gpa: std.mem.Allocator, off: D3dOffscreen) !D3dBackend {
        return .{
            .gpa = gpa,
            .off = off,
            .rect = try D3dRectRenderer.init(off.device, off.context, true),
            .exact = try D3dExactRectRenderer.init(off.device, off.context, true),
            .image = try D3dImageRenderer.init(off.device, off.context),
            .grad = try D3dGradientRenderer.init(off.device, off.context, true),
        };
    }

    /// Copy the rendered frame to the swapchain's back buffer and present it
    /// (the GPU-present path). Same size/format required — both RGBA8 at the
    /// window size.
    pub fn presentTo(self: *D3dBackend, sc: *D3dSwapchain) void {
        const back = sc.backBuffer() catch return;
        self.off.context.vtbl.CopyResource(self.off.context, back, self.off.target);
        release(back);
        sc.present();
    }

    pub fn deinit(self: *D3dBackend) void {
        var it = self.glyphs.valueIterator();
        while (it.next()) |g| g.deinit();
        self.glyphs.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.image.deinit();
        self.grad.deinit();
        self.exact.deinit();
        self.rect.deinit();
        self.off.destroy();
    }

    pub fn setFont(self: *D3dBackend, data: []const u8) !void {
        self.font = try ttf.Font.parse(data);
    }

    pub fn interface(self: *D3dBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Read the render target back as top-down RGBA (caller owns).
    pub fn readPixels(self: *D3dBackend) ![]u8 {
        return self.off.readPixels(self.gpa);
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

    fn self_(ptr: *anyopaque) *D3dBackend {
        return @ptrCast(@alignCast(ptr));
    }

    fn fullScissor(self: *D3dBackend) void {
        var r: D3D11_RECT = .{ .left = 0, .top = 0, .right = @intCast(self.off.width), .bottom = @intCast(self.off.height) };
        self.off.context.vtbl.RSSetScissorRects(self.off.context, 1, &r);
    }

    fn beginFrame(ptr: *anyopaque, viewport: geometry.Size) Backend.Error!void {
        const self = self_(ptr);
        const w: u32 = @intFromFloat(@max(1, @round(viewport.width)));
        const h: u32 = @intFromFloat(@max(1, @round(viewport.height)));
        self.off.resize(w, h) catch return error.OutOfMemory;
        self.off.clear(1, 1, 1, 1); // match raster's white clear
        self.clips.clearRetainingCapacity();
        self.fullScissor();
    }

    fn endFrame(ptr: *anyopaque) Backend.Error!void {
        _ = self_(ptr);
    }

    fn drawRect(ptr: *anyopaque, rect: geometry.Rect, rs: style.RectStyle) void {
        const self = self_(ptr);
        const w: f32 = @floatFromInt(self.off.width);
        const h: f32 = @floatFromInt(self.off.height);
        if (rs.gradient) |g| {
            self.grad.fill(self.off.rtv, w, h, rect, if (g.axis == .vertical) 1 else 0, col(g.from), col(g.to)) catch {};
            return;
        }
        if (rs.corner_radius.isNone() and rs.border.isNone()) {
            if (rs.background) |bg| {
                self.rect.fillRect(self.off.rtv, w, h, rect.x, rect.y, rect.width, rect.height, col(bg)) catch {};
            }
            return;
        }
        // bg + border + radius via the exact renderer: per-side borders +
        // per-corner radii, pixel-exact vs raster (hard-edged).
        self.exact.draw(self.off.rtv, w, h, rect, rs) catch {};
    }

    fn glyphFor(self: *D3dBackend, size_px: u16) ?*D3dGlyphRenderer {
        if (self.font == null) return null;
        if (self.glyphs.getPtr(size_px)) |g| return g;
        const g = D3dGlyphRenderer.init(self.gpa, self.off.device, self.off.context, &self.font.?, @floatFromInt(size_px), true) catch return null;
        self.glyphs.put(self.gpa, size_px, g) catch return null;
        return self.glyphs.getPtr(size_px);
    }

    fn drawText(ptr: *anyopaque, origin: geometry.Point, text: []const u8, ts: style.TextStyle) void {
        const self = self_(ptr);
        const size_px: u16 = @intFromFloat(@max(4, ts.size));
        const gr = self.glyphFor(size_px) orelse return;
        const w: f32 = @floatFromInt(self.off.width);
        const h: f32 = @floatFromInt(self.off.height);
        const color = ts.color orelse style.Color.black;
        gr.drawText(self.gpa, self.off.rtv, w, h, origin.x, origin.y, text, col(color)) catch {};
    }

    fn drawImage(ptr: *anyopaque, rect: geometry.Rect, texture: *Backend.Texture) void {
        const self = self_(ptr);
        const w: f32 = @floatFromInt(self.off.width);
        const h: f32 = @floatFromInt(self.off.height);
        const srv: *ISrv = @ptrCast(@alignCast(texture));
        self.image.draw(self.off.rtv, w, h, rect, srv) catch {};
    }

    fn applyScissor(self: *D3dBackend) void {
        var s: ScissorRect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(self.off.width), .y1 = @intCast(self.off.height) };
        for (self.clips.items) |c| {
            s.x0 = @max(s.x0, c.x0);
            s.y0 = @max(s.y0, c.y0);
            s.x1 = @min(s.x1, c.x1);
            s.y1 = @min(s.y1, c.y1);
        }
        // D3D scissor is top-left origin like our rects — no y-flip.
        var r: D3D11_RECT = .{ .left = s.x0, .top = s.y0, .right = @max(s.x0, s.x1), .bottom = @max(s.y0, s.y1) };
        self.off.context.vtbl.RSSetScissorRects(self.off.context, 1, &r);
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
        const dev = self.off.device;
        var tdesc: D3D11_TEXTURE2D_DESC = .{ .width = width, .height = height, .format = DXGI_FORMAT_R8G8B8A8_UNORM, .usage = D3D11_USAGE_IMMUTABLE, .bind_flags = D3D11_BIND_SHADER_RESOURCE };
        var tdata: D3D11_SUBRESOURCE_DATA = .{ .p_sys_mem = rgba.ptr, .sys_mem_pitch = width * 4 };
        var tex: ?*ITexture2D = null;
        if (!ok(dev.vtbl.CreateTexture2D(dev, &tdesc, &tdata, &tex)) or tex == null) return error.OutOfMemory;
        defer release(tex.?); // the SRV keeps the texture alive
        var srv: ?*ISrv = null;
        if (!ok(dev.vtbl.CreateShaderResourceView(dev, tex.?, null, &srv)) or srv == null) return error.OutOfMemory;
        return @ptrCast(srv.?);
    }

    fn destroyTexture(ptr: *anyopaque, texture: *Backend.Texture) void {
        _ = self_(ptr);
        const srv: *ISrv = @ptrCast(@alignCast(texture));
        release(srv);
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
