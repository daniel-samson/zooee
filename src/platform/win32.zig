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
const WM_ERASEBKGND = 0x0014;
const WM_SIZE = 0x0005;
const WM_CLOSE = 0x0010;
const PM_REMOVE = 0x0001;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOWNORMAL = 1;
const GWLP_USERDATA = -21;
const IDC_ARROW: usize = 32512;
// Standard system-cursor ids (#123).
const IDC_IBEAM: usize = 32513;
const IDC_WAIT: usize = 32514;
const IDC_CROSS: usize = 32515;
const IDC_SIZENWSE: usize = 32642;
const IDC_SIZENESW: usize = 32643;
const IDC_SIZEWE: usize = 32644;
const IDC_SIZENS: usize = 32645;
const IDC_NO: usize = 32648;
const IDC_HAND: usize = 32649;
const WM_SETCURSOR: u32 = 0x0020;
const HTCLIENT: usize = 1;

extern "user32" fn LoadCursorW(?HINSTANCE, ?*const anyopaque) callconv(WINAPI) ?*anyopaque;
extern "user32" fn SetCursor(?*anyopaque) callconv(WINAPI) ?*anyopaque;
// Per-monitor DPI (#207). GetDpiForWindow + WM_DPICHANGED are Win10 1607+.
extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) u32;
extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(WINAPI) win.BOOL;
extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, u32) callconv(WINAPI) win.BOOL;
const WM_DPICHANGED: u32 = 0x02E0;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;
// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4.
const DPI_PER_MONITOR_V2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(WINAPI) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(WINAPI) win.BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) win.BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) win.BOOL;
// Window operations (#208).
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(WINAPI) win.BOOL;
extern "user32" fn IsIconic(HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn IsZoomed(HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(WINAPI) win.BOOL;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, win.BOOL, u32) callconv(WINAPI) win.BOOL;
extern "user32" fn GetWindowLongW(HWND, i32) callconv(WINAPI) i32;
extern "user32" fn ScreenToClient(HWND, *POINT) callconv(WINAPI) win.BOOL;
// Refresh rate (#206): VREFRESH from the device context.
extern "user32" fn GetDC(HWND) callconv(WINAPI) ?*anyopaque;
extern "user32" fn ReleaseDC(HWND, ?*anyopaque) callconv(WINAPI) i32;
extern "gdi32" fn GetDeviceCaps(?*anyopaque, i32) callconv(WINAPI) i32;
const VREFRESH: i32 = 116;
const SW_MAXIMIZE = 3;
const SW_MINIMIZE = 6;
const SW_RESTORE = 9;
const GWL_STYLE: i32 = -16;
const GWL_EXSTYLE: i32 = -20;
const SWP_NOMOVE: u32 = 0x0002;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(WINAPI) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) isize;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) HINSTANCE;

// --- events ----------------------------------------------------------------

const core_event = @import("../event.zig");
const cursor_mod = @import("../cursor.zig");
const clipboard_mod = @import("../clipboard.zig");

// System clipboard (#19/#209) via the Win32 clipboard API + CF_UNICODETEXT.
const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;
extern "user32" fn OpenClipboard(?HWND) callconv(WINAPI) win.BOOL;
extern "user32" fn CloseClipboard() callconv(WINAPI) win.BOOL;
extern "user32" fn EmptyClipboard() callconv(WINAPI) win.BOOL;
extern "user32" fn GetClipboardData(u32) callconv(WINAPI) ?*anyopaque;
extern "user32" fn SetClipboardData(u32, ?*anyopaque) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(u32, usize) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalLock(?*anyopaque) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(WINAPI) win.BOOL;
// Drag-and-drop file target (#212).
const WM_DROPFILES = 0x0233;
extern "shell32" fn DragAcceptFiles(HWND, win.BOOL) callconv(WINAPI) void;
extern "shell32" fn DragQueryFileW(?*anyopaque, u32, ?[*]u16, u32) callconv(WINAPI) u32;
extern "shell32" fn DragQueryPoint(?*anyopaque, *POINT) callconv(WINAPI) win.BOOL;
extern "shell32" fn DragFinish(?*anyopaque) callconv(WINAPI) void;

/// System clipboard backed by the Win32 clipboard (#209). Implements the core
/// `Clipboard` interface, mirroring the macOS `SystemClipboard`. Cross-app
/// interop needs on-device QA (no hosted GUI runner).
pub const SystemClipboard = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) SystemClipboard {
        return .{ .gpa = gpa };
    }

    pub fn interface(self: *SystemClipboard) clipboard_mod.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: clipboard_mod.Clipboard.VTable = .{ .get_text = getText, .set_text = setText };

    fn getText(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8 {
        _ = ptr;
        if (OpenClipboard(null) == 0) return null;
        defer _ = CloseClipboard();
        const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const p = GlobalLock(h) orelse return null;
        defer _ = GlobalUnlock(h);
        const u16ptr: [*:0]const u16 = @ptrCast(@alignCast(p));
        return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(u16ptr));
    }

    fn setText(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *SystemClipboard = @ptrCast(@alignCast(ptr));
        const u16buf = try std.unicode.utf8ToUtf16LeAllocZ(self.gpa, text);
        defer self.gpa.free(u16buf);
        const h = GlobalAlloc(GMEM_MOVEABLE, (u16buf.len + 1) * 2) orelse return error.OutOfMemory;
        const dst = GlobalLock(h) orelse return error.OutOfMemory;
        const dstp: [*]u16 = @ptrCast(@alignCast(dst));
        @memcpy(dstp[0..u16buf.len], u16buf);
        dstp[u16buf.len] = 0;
        _ = GlobalUnlock(h);
        if (OpenClipboard(null) == 0) return error.AccessDenied;
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        _ = SetClipboardData(CF_UNICODETEXT, h); // system takes ownership of h
    }
};
/// Native windows emit the same core events as the terminal session, so
/// one app loop drives every surface (#5).
pub const Event = core_event.Event;

const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MOUSEWHEEL = 0x020A;
const WM_MOUSEHWHEEL = 0x020E;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_SYSKEYUP = 0x0105;
const WM_CHAR = 0x0102;
// Input completeness (#211).
const WM_LBUTTONDBLCLK = 0x0203;
const WM_RBUTTONDBLCLK = 0x0206;
const WM_MBUTTONDBLCLK = 0x0209;
const WM_MOUSELEAVE = 0x02A3;
const CS_DBLCLKS: u32 = 0x0008;
const TME_LEAVE: u32 = 0x0002;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_LWIN = 0x5B;
const VK_RWIN = 0x5C;

const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: ?HWND,
    dwHoverTime: u32,
};
extern "user32" fn GetKeyState(i32) callconv(WINAPI) i16;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(WINAPI) win.BOOL;

/// Current keyboard modifiers from the async key state (#211).
fn winMods() core_event.Modifiers {
    return .{
        .shift = GetKeyState(VK_SHIFT) < 0,
        .ctrl = GetKeyState(VK_CONTROL) < 0,
        .alt = GetKeyState(VK_MENU) < 0,
        .super = GetKeyState(VK_LWIN) < 0 or GetKeyState(VK_RWIN) < 0,
    };
}

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
    /// Render-one-frame callback (set by runWindow). WM_SIZE fires inside the
    /// modal WM_ENTERSIZEMOVE loop, so calling this there redraws live during
    /// a resize drag instead of stretching the stale blit. See the macOS twin.
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    /// Desired pointer cursor id (#123). Windows resets the cursor to the class
    /// cursor on every WM_MOUSEMOVE, so the wndproc re-applies this on
    /// WM_SETCURSOR over the client area instead of fighting it from the loop.
    cursor_idc: usize = IDC_ARROW,
    /// True between a synthesized pointer_enter and the matching WM_MOUSELEAVE
    /// (#211): we re-arm TrackMouseEvent on each move only when not tracking.
    mouse_tracking: bool = false,
    /// Scratch for drop payloads (#212): dropped file paths are allocated here
    /// and stay valid until the next pumpEvents resets it (matching DragData's
    /// "valid only during dispatch" contract).
    drop_arena: std.heap.ArenaAllocator,

    /// Apply a pointer cursor shape (#123). Stores the system-cursor id and
    /// applies it now; the wndproc re-applies it on WM_SETCURSOR (Windows
    /// otherwise reverts to the class cursor on each mouse move). Diagonal
    /// resizes and grab map to the nearest IDC_* cursor.
    pub fn setCursor(self: *Window, shape: cursor_mod.Cursor) void {
        self.cursor_idc = switch (shape) {
            .default => IDC_ARROW,
            .pointer => IDC_HAND,
            .text => IDC_IBEAM,
            .crosshair => IDC_CROSS,
            .not_allowed => IDC_NO,
            .grab, .grabbing => IDC_HAND, // no open/closed-hand system cursor
            .ew_resize => IDC_SIZEWE,
            .ns_resize => IDC_SIZENS,
            .nwse_resize => IDC_SIZENWSE,
            .nesw_resize => IDC_SIZENESW,
            .wait => IDC_WAIT,
        };
        _ = SetCursor(LoadCursorW(null, @ptrFromInt(self.cursor_idc)));
    }

    /// Register the live-resize redraw callback (mirrors macos/x11 setRedraw).
    pub fn setRedraw(self: *Window, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = f;
    }

    // --- Window operations (#208) — mirror the macOS Window method set. ---

    /// Resize the client area to `w`×`h` logical px (grows the window rect to
    /// fit the frame). Position is preserved.
    pub fn setSize(self: *Window, w: f32, h: f32) void {
        var r: RECT = .{ .left = 0, .top = 0, .right = @intFromFloat(@max(1, w)), .bottom = @intFromFloat(@max(1, h)) };
        const style: u32 = @bitCast(GetWindowLongW(self.hwnd, GWL_STYLE));
        const exstyle: u32 = @bitCast(GetWindowLongW(self.hwnd, GWL_EXSTYLE));
        _ = AdjustWindowRectEx(&r, style, .FALSE, exstyle);
        _ = SetWindowPos(self.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        var buf: [256]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&buf, title) catch return;
        if (n >= buf.len) return;
        buf[n] = 0;
        _ = SetWindowTextW(self.hwnd, buf[0..n :0].ptr);
    }

    pub fn minimise(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_MINIMIZE);
    }

    pub fn maximise(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_MAXIMIZE);
    }

    pub fn restore(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_RESTORE);
    }

    /// Post WM_CLOSE so the wndproc emits `close_requested` (the app decides
    /// whether to actually destroy) — same contract as macOS performClose.
    pub fn close(self: *Window) void {
        _ = PostMessageW(self.hwnd, WM_CLOSE, 0, 0);
    }

    pub fn isMinimised(self: *Window) bool {
        return IsIconic(self.hwnd) != 0;
    }

    pub fn isMaximised(self: *Window) bool {
        return IsZoomed(self.hwnd) != 0;
    }

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zooee_window");
    var class_registered = false;

    pub const CreateOptions = struct {
        title: []const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        visible: bool = true,
        /// Accepted for cross-platform parity; the Windows GPU path is
        /// D3D11 (#12), not GL, so this is ignored here.
        gl: bool = false,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const hinstance = GetModuleHandleW(null);

        // Per-monitor-v2 DPI awareness (#207): without it Windows lies about the
        // client size and GetDpiForWindow always returns 96. Process-wide and
        // idempotent — safe to call on every create. Ignored on pre-1607.
        _ = SetProcessDpiAwarenessContext(DPI_PER_MONITOR_V2);

        if (!class_registered) {
            const wc: WNDCLASSEXW = .{
                .style = CS_DBLCLKS, // deliver WM_*BUTTONDBLCLK (#211)
                .lpfnWndProc = wndProc,
                .hInstance = hinstance,
                .lpszClassName = class_name,
                // No background brush: the client area is owned entirely by
                // the renderer — either the GDI raster blit (WM_PAINT below)
                // or the D3D11 swapchain present (#12). A WHITE_BRUSH here
                // erases white over the swapchain on every WM_PAINT, which is
                // exactly the "GPU window opens blank" bug. WM_ERASEBKGND is
                // swallowed below so the OS never paints the client itself.
                .hbrBackground = null,
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

        self.* = .{ .hwnd = hwnd, .gpa = gpa, .drop_arena = std.heap.ArenaAllocator.init(gpa) };
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        DragAcceptFiles(hwnd, 1); // accept WM_DROPFILES (#212)
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
        self.drop_arena.deinit();
        self.gpa.destroy(self);
    }

    /// Drain pending OS messages into the event queue; returns the events.
    /// Non-blocking — the drivable-loop primitive (#5).
    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        _ = self.drop_arena.reset(.retain_capacity); // free last frame's drop paths (#212)
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
                // Redraw live during the modal WM_ENTERSIZEMOVE loop (which
                // parks our pump loop) so the frame tracks the size.
                if (self.redraw_fn) |f| f(self.redraw_ctx);
            },
            WM_DPICHANGED => {
                // Dragged to a monitor with a different DPI (#207). lParam is the
                // suggested window rect; resize to it — the ensuing WM_SIZE emits
                // `resized`, and contentPixelSize reports the new scale next frame,
                // so the Coalescer relayouts + regenerates the glyph atlas.
                const prc: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = SetWindowPos(hwnd, null, prc.left, prc.top, prc.right - prc.left, prc.bottom - prc.top, SWP_NOZORDER | SWP_NOACTIVATE);
                return 0;
            },
            WM_SETCURSOR => {
                // Over the client area, apply the app-requested cursor (#123)
                // and claim the message; elsewhere (borders, title bar) let the
                // default proc draw the resize/arrow cursors.
                if (loShort(@bitCast(lparam)) == HTCLIENT) {
                    _ = SetCursor(LoadCursorW(null, @ptrFromInt(self.cursor_idc)));
                    return 1; // TRUE — handled
                }
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_LBUTTONDBLCLK, WM_RBUTTONDBLCLK, WM_MBUTTONDBLCLK => {
                const lp: usize = @bitCast(lparam);
                // A double-click message is the *second* press → click_count 2
                // (#211). Native triple-click isn't delivered by Windows.
                const dbl = msg == WM_LBUTTONDBLCLK or msg == WM_RBUTTONDBLCLK or msg == WM_MBUTTONDBLCLK;
                const pos: core_event.PointerEvent = .{
                    .position = .{ .x = @floatFromInt(loShort(lp)), .y = @floatFromInt(hiShort(lp)) },
                    .buttons = .{
                        .primary = wparam & 0x0001 != 0,
                        .secondary = wparam & 0x0002 != 0,
                        .middle = wparam & 0x0010 != 0,
                    },
                    .mods = winMods(),
                    .click_count = if (dbl) 2 else 1,
                };
                if (msg == WM_MOUSEMOVE and !self.mouse_tracking) {
                    // First move after entering / after a leave: emit enter and
                    // arm leave tracking (#211).
                    self.mouse_tracking = true;
                    var tme: TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(TRACKMOUSEEVENT), .dwFlags = TME_LEAVE, .hwndTrack = hwnd, .dwHoverTime = 0 };
                    _ = TrackMouseEvent(&tme);
                    self.queue.append(self.gpa, .{ .pointer_enter = pos }) catch {};
                }
                const ev: Event = switch (msg) {
                    WM_MOUSEMOVE => .{ .pointer_move = pos },
                    WM_LBUTTONUP, WM_RBUTTONUP => .{ .pointer_up = pos },
                    else => .{ .pointer_down = pos }, // down + dbl-click
                };
                self.queue.append(self.gpa, ev) catch {};
            },
            WM_DROPFILES => {
                // Files dropped from Explorer (#212). HDROP in wParam; query the
                // paths into the per-frame arena and emit a .drop.
                const hdrop: ?*anyopaque = @ptrFromInt(wparam);
                const a = self.drop_arena.allocator();
                const count = DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
                const paths = a.alloc([]const u8, count) catch {
                    DragFinish(hdrop);
                    return 0;
                };
                var n: usize = 0;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const len = DragQueryFileW(hdrop, i, null, 0); // chars, excl NUL
                    const wbuf = a.alloc(u16, len + 1) catch continue;
                    _ = DragQueryFileW(hdrop, i, wbuf.ptr, len + 1);
                    const path = std.unicode.utf16LeToUtf8Alloc(a, wbuf[0..len]) catch continue;
                    paths[n] = path;
                    n += 1;
                }
                var pt: POINT = undefined;
                _ = DragQueryPoint(hdrop, &pt);
                DragFinish(hdrop);
                self.queue.append(self.gpa, .{ .drop = .{
                    .position = .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) },
                    .data = .{ .files = paths[0..n] },
                    .operation = .copy,
                } }) catch {};
                return 0;
            },
            WM_MOUSELEAVE => {
                self.mouse_tracking = false;
                self.queue.append(self.gpa, .{ .pointer_leave = .{ .position = .{ .x = 0, .y = 0 }, .mods = winMods() } }) catch {};
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                // Wheel delta is in the high word of wParam, in WHEEL_DELTA (120)
                // units; lParam is *screen* coords → ScreenToClient (#126/#210).
                // dy>0 = wheel up, dx>0 = tilt right. unit = line.
                const lp: usize = @bitCast(lparam);
                var pt: POINT = .{ .x = loShort(lp), .y = hiShort(lp) };
                _ = ScreenToClient(hwnd, &pt);
                const steps: f32 = @as(f32, @floatFromInt(hiShort(wparam))) / 120.0;
                const horiz = msg == WM_MOUSEHWHEEL;
                self.queue.append(self.gpa, .{ .scroll = .{
                    .position = .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) },
                    .dx = if (horiz) steps else 0,
                    .dy = if (horiz) 0 else steps,
                    .unit = .line,
                } }) catch {};
            },
            WM_KEYDOWN => {
                if (vkToKey(wparam)) |k| {
                    self.queue.append(self.gpa, .{ .key_down = .{ .key = k, .mods = winMods() } }) catch {};
                }
            },
            WM_KEYUP, WM_SYSKEYUP => {
                if (vkToKey(wparam)) |k| {
                    self.queue.append(self.gpa, .{ .key_up = .{ .key = k, .mods = winMods() } }) catch {};
                }
            },
            WM_CHAR => {
                const ch: u21 = @intCast(wparam & 0x1FFFFF);
                if (ch >= 0x20 and ch != 0x7F) {
                    self.queue.append(self.gpa, .{ .text = .{ .codepoint = ch } }) catch {};
                }
            },
            // Swallow background erase: the renderer owns every client pixel.
            // Without this the OS would erase (white/gray) over the swapchain.
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                // Validate the update region without erasing. When a GDI raster
                // frame is retained, re-present it; the D3D path (frame_width==0)
                // leaves the swapchain's presented pixels untouched.
                var ps: PAINTSTRUCT = undefined;
                const dc = BeginPaint(hwnd, &ps);
                defer _ = EndPaint(hwnd, &ps);
                if (self.frame_width > 0) self.presentFrame(dc);
                return 0;
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
    // With per-monitor-v2 awareness the client rect is already physical pixels
    // (#207); scale = DPI/96 tells layout how to upscale logical units. Mirrors
    // macOS (physical px + backing scale). 0 → pre-1607 → 1.0.
    const dpi = GetDpiForWindow(window.hwnd);
    const scale: f64 = if (dpi > 0) @as(f64, @floatFromInt(dpi)) / 96.0 else 1.0;
    return .{
        .width = @intCast(@max(1, rect.right - rect.left)),
        .height = @intCast(@max(1, rect.bottom - rect.top)),
        .scale = scale,
    };
}

/// Display refresh rate (Hz) for frame pacing (#170/#206) via the device
/// context's VREFRESH. 0 or 1 means "default" → 0 so the caller falls back to 60.
pub fn refreshHz(window: *Window) f32 {
    const hdc = GetDC(window.hwnd) orelse return 0;
    defer _ = ReleaseDC(window.hwnd, hdc);
    const hz = GetDeviceCaps(hdc, VREFRESH);
    return if (hz > 1) @floatFromInt(hz) else 0;
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
