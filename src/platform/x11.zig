//! X11 windowing layer (#9): native Linux windows via Xlib — the
//! platform windowing API (like user32 on Windows, AppKit on macOS),
//! not a third-party abstraction (no GLFW/SDL). Works on X11 sessions
//! and on Wayland via XWayland. Wayland-native is a #9 follow-up.
//!
//! Mirrors the Win32/Cocoa shape: Window.create/destroy, non-blocking
//! pumpEvents emitting core events, blit (XPutImage), contentPixelSize.
//! DPI (Xft.dpi) is #27; v1 reports scale 1.

const std = @import("std");
const builtin = @import("builtin");
const core_event = @import("../event.zig");
const geometry = @import("../geometry.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("x11.zig is Linux-only; gate imports on builtin.os.tag");
}

// --- Xlib types (64-bit C ABI) ----------------------------------------------

const XID = c_ulong;
const Window_ = XID;
const Drawable = XID;
const Atom = c_ulong;
const Time = c_ulong;
const KeySym = c_ulong;
const Bool = c_int;
const Display = opaque {};
const Visual = opaque {};
const GC = opaque {};

const XImageFuncs = extern struct {
    create_image: ?*anyopaque = null,
    destroy_image: ?*const fn (*XImage) callconv(.c) c_int = null,
    get_pixel: ?*anyopaque = null,
    put_pixel: ?*anyopaque = null,
    sub_image: ?*anyopaque = null,
    add_pixel: ?*anyopaque = null,
};

const XImage = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    data: ?[*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    f: XImageFuncs,
};

// XEvent is a union of all event structs; every member starts with `type`.
// We declare the members we read and pad to the full union size (24 longs).
const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};
const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};
const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    root: Window_,
    subwindow: Window_,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};
const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: Window_,
    window: Window_,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window_,
    override_redirect: Bool,
};
const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window_,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};
const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    pad: [24]c_long,
};

// --- Xlib functions ---------------------------------------------------------

extern "X11" fn XOpenDisplay(?[*:0]const u8) ?*Display;
extern "X11" fn XCloseDisplay(*Display) c_int;
extern "X11" fn XDefaultScreen(*Display) c_int;
extern "X11" fn XRootWindow(*Display, c_int) Window_;
extern "X11" fn XDefaultVisual(*Display, c_int) ?*Visual;
extern "X11" fn XDefaultDepth(*Display, c_int) c_int;
extern "X11" fn XWhitePixel(*Display, c_int) c_ulong;
extern "X11" fn XCreateSimpleWindow(*Display, Window_, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) Window_;
extern "X11" fn XDestroyWindow(*Display, Window_) c_int;
extern "X11" fn XStoreName(*Display, Window_, [*:0]const u8) c_int;
extern "X11" fn XChangeProperty(*Display, Window_, Atom, Atom, c_int, c_int, [*]const u8, c_int) c_int;
extern "X11" fn XSelectInput(*Display, Window_, c_long) c_int;
extern "X11" fn XMapWindow(*Display, Window_) c_int;
extern "X11" fn XFlush(*Display) c_int;
extern "X11" fn XPending(*Display) c_int;
extern "X11" fn XNextEvent(*Display, *XEvent) c_int;
extern "X11" fn XInternAtom(*Display, [*:0]const u8, Bool) Atom;
extern "X11" fn XSetWMProtocols(*Display, Window_, *Atom, c_int) c_int;
extern "X11" fn XLookupKeysym(*XKeyEvent, c_int) KeySym;
extern "X11" fn XLookupString(*XKeyEvent, [*]u8, c_int, ?*KeySym, ?*anyopaque) c_int;
extern "X11" fn XCreateGC(*Display, Drawable, c_ulong, ?*anyopaque) ?*GC;
extern "X11" fn XCreateImage(*Display, ?*Visual, c_uint, c_int, c_int, [*]u8, c_uint, c_uint, c_int, c_int) ?*XImage;
extern "X11" fn XPutImage(*Display, Drawable, *GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) c_int;

// Event masks / types / ZPixmap.
const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const StructureNotifyMask: c_long = 1 << 17;

const KeyPress = 2;
const ButtonPress = 4;
const ButtonRelease = 5;
const MotionNotify = 6;
const Expose = 12;
const ConfigureNotify = 22;
const ClientMessage = 33;
const ZPixmap = 2;

fn keysymToKey(ks: KeySym) ?core_event.Key {
    return switch (ks) {
        0xff52 => .up,
        0xff54 => .down,
        0xff51 => .left,
        0xff53 => .right,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff0d => .enter,
        0xff1b => .escape,
        0xff09 => .tab,
        0xff08 => .backspace,
        0xffff => .delete,
        else => null,
    };
}

pub const Event = core_event.Event;

pub const Window = struct {
    display: *Display,
    handle: Window_,
    gc: *GC,
    visual: ?*Visual,
    depth: c_uint,
    wm_delete: Atom,
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Event) = .empty,
    bgra: std.ArrayList(u8) = .empty,
    ximage: ?*XImage = null,
    img_w: usize = 0,
    img_h: usize = 0,
    width: u32,
    height: u32,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        visible: bool = true,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const display = XOpenDisplay(null) orelse return error.BackendFailure;
        errdefer _ = XCloseDisplay(display);
        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        const white = XWhitePixel(display, screen);

        const handle = XCreateSimpleWindow(display, root, 0, 0, opts.width, opts.height, 0, white, white);
        _ = XStoreName(display, handle, opts.title.ptr); // legacy/fallback (Latin-1)
        // Modern UTF-8 title: _NET_WM_NAME = UTF8_STRING, so the WM shows
        // multibyte glyphs (e.g. the em-dash) correctly. PropModeReplace=0.
        const net_wm_name = XInternAtom(display, "_NET_WM_NAME", 0);
        const utf8_string = XInternAtom(display, "UTF8_STRING", 0);
        _ = XChangeProperty(display, handle, net_wm_name, utf8_string, 8, 0, opts.title.ptr, @intCast(opts.title.len));
        _ = XSelectInput(display, handle, ExposureMask | KeyPressMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask);

        var wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", 0);
        _ = XSetWMProtocols(display, handle, &wm_delete, 1);

        const gc = XCreateGC(display, handle, 0, null) orelse return error.BackendFailure;
        if (opts.visible) _ = XMapWindow(display, handle);
        _ = XFlush(display);

        const self = try gpa.create(Window);
        self.* = .{
            .display = display,
            .handle = handle,
            .gc = gc,
            .visual = XDefaultVisual(display, screen),
            .depth = @intCast(XDefaultDepth(display, screen)),
            .wm_delete = wm_delete,
            .gpa = gpa,
            .width = opts.width,
            .height = opts.height,
        };
        return self;
    }

    pub fn destroy(self: *Window) void {
        if (self.ximage) |img| {
            img.data = null; // our buffer; let Xlib free only the struct
            if (img.f.destroy_image) |di| _ = di(img);
        }
        self.bgra.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        _ = XDestroyWindow(self.display, self.handle);
        _ = XCloseDisplay(self.display);
        self.gpa.destroy(self);
    }

    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        while (XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = XNextEvent(self.display, &ev);
            switch (ev.type) {
                ClientMessage => {
                    if (@as(Atom, @bitCast(ev.xclient.data.l[0])) == self.wm_delete) {
                        self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
                    }
                },
                ConfigureNotify => {
                    const w: u32 = @intCast(ev.xconfigure.width);
                    const h: u32 = @intCast(ev.xconfigure.height);
                    if (w != self.width or h != self.height) {
                        self.width = w;
                        self.height = h;
                        self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } } }) catch {};
                    }
                },
                Expose => self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) } } }) catch {},
                MotionNotify => self.queue.append(self.gpa, .{ .pointer_move = .{ .position = .{ .x = @floatFromInt(ev.xmotion.x), .y = @floatFromInt(ev.xmotion.y) } } }) catch {},
                ButtonPress, ButtonRelease => {
                    const b = ev.xbutton.button;
                    if (b == 4 or b == 5) {
                        if (ev.type == ButtonPress) {
                            self.queue.append(self.gpa, .{ .key_down = .{ .key = if (b == 4) .up else .down } }) catch {};
                        }
                    } else {
                        const pe: core_event.PointerEvent = .{
                            .position = .{ .x = @floatFromInt(ev.xbutton.x), .y = @floatFromInt(ev.xbutton.y) },
                            .buttons = .{ .primary = b == 1, .middle = b == 2, .secondary = b == 3 },
                        };
                        self.queue.append(self.gpa, if (ev.type == ButtonPress) .{ .pointer_down = pe } else .{ .pointer_up = pe }) catch {};
                    }
                },
                KeyPress => {
                    const ks = XLookupKeysym(&ev.xkey, 0);
                    if (keysymToKey(ks)) |k| {
                        self.queue.append(self.gpa, .{ .key_down = .{ .key = k } }) catch {};
                    } else {
                        var buf: [8]u8 = undefined;
                        const n = XLookupString(&ev.xkey, &buf, buf.len, null, null);
                        if (n > 0 and buf[0] >= 0x20 and buf[0] != 0x7f) {
                            self.queue.append(self.gpa, .{ .text = .{ .codepoint = buf[0] } }) catch {};
                        }
                    }
                },
                else => {},
            }
        }
        return self.queue.items;
    }
};

/// Module-level to match win32/macos (app.zig calls platform.contentPixelSize).
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    return .{ .width = window.width, .height = window.height, .scale = 1.0 };
}

pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize) void {
    std.debug.assert(rgba.len == width * height * 4);
    window.bgra.resize(window.gpa, rgba.len) catch return;
    const dst = window.bgra.items;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        dst[i + 0] = rgba[i + 2];
        dst[i + 1] = rgba[i + 1];
        dst[i + 2] = rgba[i + 0];
        dst[i + 3] = 255;
    }
    if (window.ximage == null or window.img_w != width or window.img_h != height) {
        if (window.ximage) |old| {
            old.data = null;
            if (old.f.destroy_image) |di| _ = di(old);
        }
        window.ximage = XCreateImage(window.display, window.visual, window.depth, ZPixmap, 0, dst.ptr, @intCast(width), @intCast(height), 32, @intCast(width * 4));
        window.img_w = width;
        window.img_h = height;
    } else {
        window.ximage.?.data = dst.ptr; // buffer may have moved on resize-to-same
    }
    if (window.ximage) |img| {
        _ = XPutImage(window.display, window.handle, window.gc, img, 0, 0, 0, 0, @intCast(width), @intCast(height));
        _ = XFlush(window.display);
    }
}
