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
const WM_PAINT = 0x000F;
const WM_SIZE = 0x0005;
const WM_CLOSE = 0x0010;
const PM_REMOVE = 0x0001;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOWNORMAL = 1;
const GWLP_USERDATA = -21;
const WHITE_BRUSH = 0;
const IDC_ARROW: usize = 32512;

extern "gdi32" fn GetStockObject(i32) callconv(WINAPI) ?*anyopaque;
extern "user32" fn LoadCursorW(?HINSTANCE, ?*const anyopaque) callconv(WINAPI) ?*anyopaque;

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

const core_event = @import("../event.zig");
/// Native windows emit the same core events as the terminal session, so
/// one app loop drives every surface (#5).
pub const Event = core_event.Event;

const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MOUSEWHEEL = 0x020A;
const WM_KEYDOWN = 0x0100;
const WM_CHAR = 0x0102;

fn loShort(v: usize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(v & 0xFFFF))));
}
fn hiShort(v: usize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((v >> 16) & 0xFFFF))));
}

fn vkToKey(vk: usize) ?core_event.Key {
    return switch (vk) {
        0x26 => .up,
        0x28 => .down,
        0x25 => .left,
        0x27 => .right,
        0x24 => .home,
        0x23 => .end,
        0x21 => .page_up,
        0x22 => .page_down,
        0x0D => .enter,
        0x1B => .escape,
        0x09 => .tab,
        0x08 => .backspace,
        0x2E => .delete,
        else => null,
    };
}

// --- window ----------------------------------------------------------------

pub const Window = struct {
    hwnd: HWND,
    /// Single-producer queue filled by the wndproc during pumpEvents.
    queue: std.ArrayList(Event) = .empty,
    gpa: std.mem.Allocator,
    destroyed: bool = false,
    /// Retained last frame (BGRA top-down) re-presented on WM_PAINT —
    /// drawing outside the paint cycle gets erased on any repaint.
    frame_bgra: std.ArrayList(u8) = .empty,
    frame_width: usize = 0,
    frame_height: usize = 0,

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
                // Arrow cursor for the client area. Without a class cursor
                // the window never resets the pointer, so the launch
                // "app-starting" hourglass lingers over our window.
                .hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
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
        self.frame_bgra.deinit(self.gpa);
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

    fn presentFrame(self: *Window, dc: ?*anyopaque) void {
        const hdr: BITMAPINFOHEADER = .{
            .width = @intCast(self.frame_width),
            .height = -@as(i32, @intCast(self.frame_height)),
        };
        var rect: RECT = undefined;
        _ = GetClientRect(self.hwnd, &rect);
        _ = StretchDIBits(dc, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 0, 0, @intCast(self.frame_width), @intCast(self.frame_height), self.frame_bgra.items.ptr, &hdr, DIB_RGB_COLORS, SRCCOPY);
    }

    fn fromHwnd(hwnd: HWND) ?*Window {
        const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(ptr)));
    }

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(WINAPI) LRESULT {
        if (fromHwnd(hwnd)) |self| switch (msg) {
            WM_CLOSE => {
                self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
                return 0; // app decides whether to destroy
            },
            WM_SIZE => {
                const dims: usize = @bitCast(lparam);
                self.queue.append(self.gpa, .{ .resized = .{ .size = .{
                    .width = @floatFromInt(dims & 0xFFFF),
                    .height = @floatFromInt((dims >> 16) & 0xFFFF),
                } } }) catch {};
            },
            WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP => {
                const lp: usize = @bitCast(lparam);
                const pos: core_event.PointerEvent = .{
                    .position = .{ .x = @floatFromInt(loShort(lp)), .y = @floatFromInt(hiShort(lp)) },
                    .buttons = .{
                        .primary = wparam & 0x0001 != 0,
                        .secondary = wparam & 0x0002 != 0,
                        .middle = wparam & 0x0010 != 0,
                    },
                };
                const ev: Event = switch (msg) {
                    WM_MOUSEMOVE => .{ .pointer_move = pos },
                    WM_LBUTTONDOWN, WM_RBUTTONDOWN => .{ .pointer_down = pos },
                    else => .{ .pointer_up = pos },
                };
                self.queue.append(self.gpa, ev) catch {};
            },
            WM_MOUSEWHEEL => {
                const delta = hiShort(wparam);
                self.queue.append(self.gpa, .{ .key_down = .{ .key = if (delta > 0) .up else .down } }) catch {};
            },
            WM_KEYDOWN => {
                if (vkToKey(wparam)) |k| {
                    self.queue.append(self.gpa, .{ .key_down = .{ .key = k } }) catch {};
                }
            },
            WM_CHAR => {
                const ch: u21 = @intCast(wparam & 0x1FFFFF);
                if (ch >= 0x20 and ch != 0x7F) {
                    self.queue.append(self.gpa, .{ .text = .{ .codepoint = ch } }) catch {};
                }
            },
            WM_PAINT => {
                if (self.frame_width > 0) {
                    var ps: PAINTSTRUCT = undefined;
                    const dc = BeginPaint(hwnd, &ps);
                    defer _ = EndPaint(hwnd, &ps);
                    self.presentFrame(dc);
                    return 0;
                }
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

extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) win.BOOL;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, win.BOOL) callconv(WINAPI) win.BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(WINAPI) ?*anyopaque;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(WINAPI) win.BOOL;

const PAINTSTRUCT = extern struct {
    hdc: ?*anyopaque,
    f_erase: win.BOOL,
    rc_paint: RECT,
    f_restore: win.BOOL,
    f_inc_update: win.BOOL,
    rgb_reserved: [32]u8,
};
extern "gdi32" fn StretchDIBits(?*anyopaque, i32, i32, i32, i32, i32, i32, i32, i32, ?*const anyopaque, *const BITMAPINFOHEADER, u32, u32) callconv(WINAPI) i32;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const SRCCOPY: u32 = 0x00CC0020;
const DIB_RGB_COLORS: u32 = 0;

/// Present an RGBA8 framebuffer (row-major, top-down). The frame is
/// retained (converted to BGRA) inside the Window and re-presented on
/// every WM_PAINT — one-shot drawing gets erased on any repaint.
pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize) void {
    std.debug.assert(rgba.len == width * height * 4);
    window.frame_bgra.resize(window.gpa, rgba.len) catch return;
    const dst = window.frame_bgra.items;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        dst[i + 0] = rgba[i + 2];
        dst[i + 1] = rgba[i + 1];
        dst[i + 2] = rgba[i + 0];
        dst[i + 3] = rgba[i + 3];
    }
    window.frame_width = width;
    window.frame_height = height;
    _ = InvalidateRect(window.hwnd, null, .FALSE);
    _ = UpdateWindow(window.hwnd);
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
