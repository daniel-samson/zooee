//! Win32 windowing layer (#9): direct user32/kernel32 calls, no
//! third-party windowing dependency (2MB budget, #14).
//!
//! v1 scope: window class registration, window creation/destruction, and
//! a non-blocking message pump translating a first event subset (close,
//! resize). Integrated/headless title bars (DWM + WM_NCHITTEST), DPI
//! awareness, and full input translation are #9 follow-ups; the D3D11
//! swap chain attaches in #12.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) @compileError("win32.zig is Windows-only; gate imports on builtin.os.tag");
}

const win = std.os.windows;
const WINAPI: std.builtin.CallingConvention = .winapi;

// --- minimal user32/kernel32 surface -------------------------------------

const HWND = win.HWND;
const HINSTANCE = win.HINSTANCE;
const WPARAM = usize; // ULONG_PTR; absent from std.os.windows in 0.16
const LPARAM = win.LPARAM;
const LRESULT = isize; // LONG_PTR

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const POINT = extern struct { x: i32, y: i32 };

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
};

const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_CLOSE = 0x0010;
const PM_REMOVE = 0x0001;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOWNORMAL = 1;
const GWLP_USERDATA = -21;
const WHITE_BRUSH = 0;

extern "gdi32" fn GetStockObject(i32) callconv(WINAPI) ?*anyopaque;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(WINAPI) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(WINAPI) win.BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) win.BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) win.BOOL;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(WINAPI) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) isize;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) HINSTANCE;

// --- events ----------------------------------------------------------------

pub const Event = union(enum) {
    close_requested,
    resized: struct { width: u32, height: u32 },
};

// --- window ----------------------------------------------------------------

pub const Window = struct {
    hwnd: HWND,
    /// Single-producer queue filled by the wndproc during pumpEvents.
    queue: std.ArrayList(Event) = .empty,
    gpa: std.mem.Allocator,
    destroyed: bool = false,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zooee_window");
    var class_registered = false;

    pub const CreateOptions = struct {
        title: []const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        visible: bool = true,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const hinstance = GetModuleHandleW(null);

        if (!class_registered) {
            const wc: WNDCLASSEXW = .{
                .lpfnWndProc = wndProc,
                .hInstance = hinstance,
                .lpszClassName = class_name,
                // Defined clear color before any backend paints. Without a
                // background brush the client area is undefined (renders
                // black) — caught by the e2e window visual test.
                .hbrBackground = GetStockObject(WHITE_BRUSH),
            };
            if (RegisterClassExW(&wc) == 0) return error.BackendFailure;
            class_registered = true;
        }

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);

        var title_buf: [256]u16 = undefined;
        const title_len = try std.unicode.utf8ToUtf16Le(title_buf[0..255], opts.title);
        title_buf[title_len] = 0;

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title_buf[0..title_len :0],
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(opts.width),
            @intCast(opts.height),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.BackendFailure;

        self.* = .{ .hwnd = hwnd, .gpa = gpa };
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        if (opts.visible) _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        return self;
    }

    pub fn destroy(self: *Window) void {
        if (!self.destroyed) {
            _ = SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
            _ = DestroyWindow(self.hwnd);
        }
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Drain pending OS messages into the event queue; returns the events.
    /// Non-blocking — the drivable-loop primitive (#5).
    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE).toBool()) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return self.queue.items;
    }

    fn fromHwnd(hwnd: HWND) ?*Window {
        const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(ptr)));
    }

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(WINAPI) LRESULT {
        if (fromHwnd(hwnd)) |self| switch (msg) {
            WM_CLOSE => {
                self.queue.append(self.gpa, .close_requested) catch {};
                return 0; // app decides whether to destroy
            },
            WM_SIZE => {
                const dims: usize = @bitCast(lparam);
                self.queue.append(self.gpa, .{ .resized = .{
                    .width = @intCast(dims & 0xFFFF),
                    .height = @intCast((dims >> 16) & 0xFFFF),
                } }) catch {};
            },
            WM_DESTROY => self.destroyed = true,
            else => {},
        };
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};

// --- raster blit (GDI) -------------------------------------------------------
// Windows twin of the macOS CoreGraphics blit: present a CPU-rendered
// RGBA framebuffer in the client area until D3D11 (#12) replaces it.

const BITMAPINFOHEADER = extern struct {
    size: u32 = @sizeOf(BITMAPINFOHEADER),
    width: i32,
    height: i32, // negative = top-down, matching the raster buffer
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: u32 = 0, // BI_RGB
    size_image: u32 = 0,
    x_ppm: i32 = 0,
    y_ppm: i32 = 0,
    clr_used: u32 = 0,
    clr_important: u32 = 0,
};

extern "user32" fn GetDC(HWND) callconv(WINAPI) ?*anyopaque;
extern "user32" fn ReleaseDC(HWND, ?*anyopaque) callconv(WINAPI) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) win.BOOL;
extern "gdi32" fn StretchDIBits(?*anyopaque, i32, i32, i32, i32, i32, i32, i32, i32, ?*const anyopaque, *const BITMAPINFOHEADER, u32, u32) callconv(WINAPI) i32;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const SRCCOPY: u32 = 0x00CC0020;
const DIB_RGB_COLORS: u32 = 0;

/// Present an RGBA8 framebuffer (row-major, top-down) in the client
/// area. GDI wants BGRA, so the caller's buffer is converted in place
/// of a copy — pass a scratch buffer the same size.
pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize, bgra_scratch: []u8) void {
    std.debug.assert(rgba.len == width * height * 4);
    std.debug.assert(bgra_scratch.len >= rgba.len);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        bgra_scratch[i + 0] = rgba[i + 2];
        bgra_scratch[i + 1] = rgba[i + 1];
        bgra_scratch[i + 2] = rgba[i + 0];
        bgra_scratch[i + 3] = rgba[i + 3];
    }
    const hdr: BITMAPINFOHEADER = .{ .width = @intCast(width), .height = -@as(i32, @intCast(height)) };
    const dc = GetDC(window.hwnd) orelse return;
    defer _ = ReleaseDC(window.hwnd, dc);
    var rect: RECT = undefined;
    _ = GetClientRect(window.hwnd, &rect);
    _ = StretchDIBits(
        dc,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        0,
        0,
        @intCast(width),
        @intCast(height),
        bgra_scratch.ptr,
        &hdr,
        DIB_RGB_COLORS,
        SRCCOPY,
    );
}

/// Content size in pixels for rendering (per-monitor DPI is #27;
/// v1 reports raw client pixels, scale 1).
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    var rect: RECT = undefined;
    _ = GetClientRect(window.hwnd, &rect);
    return .{
        .width = @intCast(@max(1, rect.right - rect.left)),
        .height = @intCast(@max(1, rect.bottom - rect.top)),
        .scale = 1.0,
    };
}

test "create, pump, and destroy a real window" {
    const w = try Window.create(std.testing.allocator, .{
        .title = "zooee smoke test",
        .width = 320,
        .height = 200,
        .visible = false, // do not flash on CI desktops
    });
    defer w.destroy();

    // Creation posts at least a WM_SIZE; pump must not crash or leak.
    _ = w.pumpEvents();
    try std.testing.expect(!w.destroyed);
}
