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
const BOOL = i32;

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub const Error = error{ NoDevice, NoBackBuffer, NoRtv, ReadbackFailed, ShaderFailed };

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
const DXGI_FORMAT_R32G32_FLOAT: UINT = 16;
const D3D11_USAGE_DEFAULT: UINT = 0;
const D3D11_USAGE_IMMUTABLE: UINT = 1;
const D3D11_USAGE_STAGING: UINT = 3;
const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
const D3D11_BIND_VERTEX_BUFFER: UINT = 0x1;
const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
const D3D11_CPU_ACCESS_READ: UINT = 0x20000;
const D3D11_MAP_READ: UINT = 1;
const D3D11_SDK_VERSION: UINT = 7;
const D3D_DRIVER_TYPE_HARDWARE: UINT = 1;
const D3D_DRIVER_TYPE_WARP: UINT = 5;
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
        _pad6: [6]*const anyopaque, // 16..21
        CreateRasterizerState: *const fn (*IDevice, *const D3D11_RASTERIZER_DESC, *?*IRasterizerState) callconv(WINAPI) HRESULT, // 22
        CreateSamplerState: *const fn (*IDevice, *const D3D11_SAMPLER_DESC, *?*ISampler) callconv(WINAPI) HRESULT, // 23
    };
};

const IContext = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        _pad0: [8]*const anyopaque, // IUnknown(3)+DeviceChild(4)+VSSetConstantBuffers(7)
        PSSetShaderResources: *const fn (*IContext, UINT, UINT, *const ?*ISrv) callconv(WINAPI) void, // 8
        PSSetShader: *const fn (*IContext, ?*IPixelShader, ?*const anyopaque, UINT) callconv(WINAPI) void, // 9
        PSSetSamplers: *const fn (*IContext, UINT, UINT, *const ?*ISampler) callconv(WINAPI) void, // 10
        VSSetShader: *const fn (*IContext, ?*IVertexShader, ?*const anyopaque, UINT) callconv(WINAPI) void, // 11
        _pad1: [1]*const anyopaque, // DrawIndexed(12)
        Draw: *const fn (*IContext, UINT, UINT) callconv(WINAPI) void, // 13
        Map: *const fn (*IContext, *ITexture2D, UINT, UINT, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(WINAPI) HRESULT, // 14
        Unmap: *const fn (*IContext, *ITexture2D, UINT) callconv(WINAPI) void, // 15
        _pad2: [1]*const anyopaque, // PSSetConstantBuffers(16)
        IASetInputLayout: *const fn (*IContext, ?*IInputLayout) callconv(WINAPI) void, // 17
        IASetVertexBuffers: *const fn (*IContext, UINT, UINT, *const ?*IBuffer, *const UINT, *const UINT) callconv(WINAPI) void, // 18
        _pad3: [5]*const anyopaque, // 19..23
        IASetPrimitiveTopology: *const fn (*IContext, UINT) callconv(WINAPI) void, // 24
        _pad4: [8]*const anyopaque, // 25..32
        OMSetRenderTargets: *const fn (*IContext, UINT, *const ?*IRtv, ?*anyopaque) callconv(WINAPI) void, // 33
        _pad5: [9]*const anyopaque, // 34..42
        RSSetState: *const fn (*IContext, ?*IRasterizerState) callconv(WINAPI) void, // 43
        RSSetViewports: *const fn (*IContext, UINT, *const D3D11_VIEWPORT) callconv(WINAPI) void, // 44
        _pad6: [2]*const anyopaque, // 45,46
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

    fn compile(d3d_compile: D3DCompileFn, entry: [*:0]const u8, target: [*:0]const u8) ?*IBlob {
        var code: ?*IBlob = null;
        var errs: ?*IBlob = null;
        const hr = d3d_compile(hlsl.ptr, hlsl.len, "zooee.hlsl", null, null, entry, target, 0, 0, &code, &errs);
        if (errs) |e| release(e);
        if (!ok(hr)) return null;
        return code;
    }

    /// Draw `rgba` (w×h, top-down) as a fullscreen textured quad into the
    /// render target. Point sampling, clamp — matches raster's nearest.
    pub fn drawTexture(self: *D3dOffscreen, rgba: []const u8, w: u32, h: u32) Error!void {
        const dev = self.device;
        const ctx = self.context;

        const d3d_compile = loadD3DCompile() orelse return error.ShaderFailed;
        const vs_blob = compile(d3d_compile, "VSMain", "vs_4_0") orelse return error.ShaderFailed;
        defer release(vs_blob);
        const ps_blob = compile(d3d_compile, "PSMain", "ps_4_0") orelse return error.ShaderFailed;
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
