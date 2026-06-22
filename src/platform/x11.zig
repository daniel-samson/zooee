//! X11 windowing layer (#9): native Linux windows via Xlib — the
//! platform windowing API (like user32 on Windows, AppKit on macOS),
//! not a third-party abstraction (no GLFW/SDL). Works on X11 sessions
//! and on Wayland via XWayland. Wayland-native is a #9 follow-up.
//!
//! Mirrors the Win32/Cocoa shape: Window.create/destroy, non-blocking
//! pumpEvents emitting core events, blit (XPutImage), contentPixelSize.
//! DPI via Xft.dpi (#207); window operations (#208).

const std = @import("std");
const builtin = @import("builtin");
const core_event = @import("../event.zig");
const geometry = @import("../geometry.zig");
const cursor_mod = @import("../cursor.zig");
const window_mod = @import("../window.zig");
const menu_mod = @import("../menu.zig");
const clipboard_mod = @import("../clipboard.zig");

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
const XCrossingEvent = extern struct {
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
    mode: c_int,
    detail: c_int,
    same_screen: Bool,
    focus: Bool,
    state: c_uint,
};
const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    owner: Window_,
    requestor: Window_,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};
const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    requestor: Window_,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};
const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    xcrossing: XCrossingEvent,
    xselectionrequest: XSelectionRequestEvent,
    xselection: XSelectionEvent,
    pad: [24]c_long,
};

/// Decode one `file://` URI line from an XDND text/uri-list into a filesystem
/// path (#212): strips the scheme + optional host and percent-decodes. Returns
/// null for non-file URIs. Allocated in `a`.
fn decodeFileUri(a: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var rest = line[prefix.len..];
    // file://host/path → skip the host up to the next '/'; file:///path → '/...'.
    if (rest.len > 0 and rest[0] != '/') {
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..] else return null;
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                out.append(a, rest[i]) catch return null;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
                out.append(a, rest[i]) catch return null;
                continue;
            };
            out.append(a, hi * 16 + lo) catch return null;
            i += 2;
        } else {
            out.append(a, rest[i]) catch return null;
        }
    }
    return out.items;
}

/// Core modifiers from an X event `state` mask (#211): Shift/Control/Mod1(Alt)/
/// Mod4(Super).
fn x11Mods(state: c_uint) core_event.Modifiers {
    return .{
        .shift = state & (1 << 0) != 0,
        .ctrl = state & (1 << 2) != 0,
        .alt = state & (1 << 3) != 0,
        .super = state & (1 << 6) != 0,
    };
}

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
// X resource manager (#207): read the user-configured Xft.dpi. Core libX11 —
// no extra dependency.
const XrmDatabase = ?*opaque {};
const XrmValue = extern struct { size: c_uint, addr: ?[*:0]u8 };
extern "X11" fn XrmInitialize() void;
extern "X11" fn XResourceManagerString(*Display) ?[*:0]const u8;
extern "X11" fn XrmGetStringDatabase([*:0]const u8) XrmDatabase;
extern "X11" fn XrmDestroyDatabase(XrmDatabase) void;
extern "X11" fn XrmGetResource(XrmDatabase, [*:0]const u8, [*:0]const u8, *?[*:0]const u8, *XrmValue) c_int;
// Window operations (#208).
extern "X11" fn XResizeWindow(*Display, Window_, c_uint, c_uint) c_int;
extern "X11" fn XIconifyWindow(*Display, Window_, c_int) c_int;
extern "X11" fn XMapRaised(*Display, Window_) c_int;
extern "X11" fn XSendEvent(*Display, Window_, Bool, c_long, *XEvent) c_int;
extern "X11" fn XGetWindowProperty(*Display, Window_, Atom, c_long, c_long, Bool, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) c_int;
// Clipboard selections (#209/#19).
extern "X11" fn XSetSelectionOwner(*Display, Atom, Window_, Time) c_int;
extern "X11" fn XGetSelectionOwner(*Display, Atom) Window_;
extern "X11" fn XConvertSelection(*Display, Atom, Atom, Atom, Window_, Time) c_int;
extern "X11" fn XDeleteProperty(*Display, Window_, Atom) c_int;
extern "X11" fn XCheckTypedEvent(*Display, c_int, *XEvent) Bool;
const SelectionClear = 29;
const SelectionRequest = 30;
const SelectionNotify = 31;
// IME (#213): X Input Method / Context for CJK + dead-key composition.
const XIM = ?*opaque {};
const XIC = ?*opaque {};
const XNInputStyle = "inputStyle";
const XNClientWindow = "clientWindow";
const XIMPreeditNothing: c_long = 0x0008;
const XIMStatusNothing: c_long = 0x0400;
const LC_CTYPE: c_int = 0;
extern "c" fn setlocale(c_int, ?[*:0]const u8) ?[*:0]u8;
extern "X11" fn XSetLocaleModifiers([*:0]const u8) ?[*:0]u8;
extern "X11" fn XOpenIM(*Display, ?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) XIM;
extern "X11" fn XCloseIM(XIM) c_int;
extern "X11" fn XCreateIC(XIM, ...) XIC;
extern "X11" fn XDestroyIC(XIC) void;
extern "X11" fn XSetICFocus(XIC) void;
extern "X11" fn Xutf8LookupString(XIC, *XKeyEvent, [*]u8, c_int, *KeySym, *c_int) c_int;
extern "X11" fn XFilterEvent(*XEvent, Window_) Bool;
const SubstructureMask: c_long = (1 << 19) | (1 << 20); // Notify | Redirect
extern "X11" fn XCreateFontCursor(*Display, c_uint) XID;
extern "X11" fn XDefineCursor(*Display, Window_, XID) c_int;
extern "X11" fn XFreeCursor(*Display, XID) c_int;
extern "X11" fn XSetWindowBackground(*Display, Window_, c_ulong) c_int;
extern "X11" fn XClearWindow(*Display, Window_) c_int;
extern "X11" fn XPending(*Display) c_int;
extern "X11" fn XNextEvent(*Display, *XEvent) c_int;
extern "X11" fn XInternAtom(*Display, [*:0]const u8, Bool) Atom;
extern "X11" fn XSetWMProtocols(*Display, Window_, *Atom, c_int) c_int;
extern "X11" fn XLookupKeysym(*XKeyEvent, c_int) KeySym;
extern "X11" fn XLookupString(*XKeyEvent, [*]u8, c_int, ?*KeySym, ?*anyopaque) c_int;
extern "X11" fn XCreateGC(*Display, Drawable, c_ulong, ?*anyopaque) ?*GC;
extern "X11" fn XCreateImage(*Display, ?*Visual, c_uint, c_int, c_int, [*]u8, c_uint, c_uint, c_int, c_int) ?*XImage;
extern "X11" fn XPutImage(*Display, Drawable, *GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) c_int;

// --- XInput2 (#309): smooth + natural-scroll-aware wheel ---------------------
// The legacy core button 4/5/6/7 wheel path is not adjusted by libinput's
// "natural scrolling" setting and is notch-only. XInput2 delivers scroll as
// valuator deltas on the pointer device: each scroll axis has an increment whose
// sign already encodes the natural-scroll setting, so (value − last)/increment
// gives a signed, high-resolution line delta in our canonical convention
// (dy>0 = toward later content; dx>0 = toward the right).
const GenericEvent = 35;
const XIAllMasterDevices: c_int = 1;
const XIScrollClass: c_int = 8;
const XI_Motion: c_int = 17;
const XIScrollTypeVertical: c_int = 1;
const XIScrollTypeHorizontal: c_int = 2;

const XIEventMask = extern struct { deviceid: c_int, mask_len: c_int, mask: [*]u8 };
const XIAnyClassInfo = extern struct { type: c_int, sourceid: c_int };
const XIScrollClassInfo = extern struct {
    type: c_int,
    sourceid: c_int,
    number: c_int,
    scroll_type: c_int,
    increment: f64,
    flags: c_int,
};
const XIDeviceInfo = extern struct {
    deviceid: c_int,
    name: ?[*:0]u8,
    use: c_int,
    attachment: c_int,
    enabled: Bool,
    num_classes: c_int,
    classes: ?[*]*XIAnyClassInfo,
};
const XIValuatorState = extern struct { mask_len: c_int, mask: ?[*]u8, values: ?[*]f64 };
const XIModifierState = extern struct { base: c_int, latched: c_int, locked: c_int, effective: c_int };
const XIButtonState = extern struct { mask_len: c_int, mask: ?[*]u8 };
const XIDeviceEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    extension: c_int,
    evtype: c_int,
    time: Time,
    deviceid: c_int,
    sourceid: c_int,
    detail: c_int,
    root: Window_,
    event: Window_,
    child: Window_,
    root_x: f64,
    root_y: f64,
    event_x: f64,
    event_y: f64,
    flags: c_int,
    buttons: XIButtonState,
    valuators: XIValuatorState,
    mods: XIModifierState,
    group: XIModifierState,
};
const XGenericEventCookie = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    extension: c_int,
    evtype: c_int,
    cookie: c_uint,
    data: ?*anyopaque,
};
extern "X11" fn XQueryExtension(*Display, [*:0]const u8, *c_int, *c_int, *c_int) Bool;
extern "X11" fn XGetEventData(*Display, *XGenericEventCookie) Bool;
extern "X11" fn XFreeEventData(*Display, *XGenericEventCookie) void;
extern "Xi" fn XIQueryVersion(*Display, *c_int, *c_int) c_int;
extern "Xi" fn XISelectEvents(*Display, Window_, [*]XIEventMask, c_int) c_int;
extern "Xi" fn XIQueryDevice(*Display, c_int, *c_int) ?[*]XIDeviceInfo;
extern "Xi" fn XIFreeDeviceInfo([*]XIDeviceInfo) void;

// X errors are asynchronous and Xlib's default handler *exits the process*. A
// failed XISelectEvents (some servers' XInput2 is incomplete — e.g. Xvfb) must
// not be fatal, and we must detect it to fall back to the button wheel. Install
// a handler that just records that an error happened, then XSync + check it.
const XErrorEvent = extern struct {
    type: c_int,
    display: ?*Display,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
    resourceid: XID,
};
const XErrorHandlerFn = ?*const fn (?*Display, *XErrorEvent) callconv(.c) c_int;
extern "X11" fn XSetErrorHandler(XErrorHandlerFn) XErrorHandlerFn;
var g_x_error: bool = false;
fn xErrorHandler(_: ?*Display, _: *XErrorEvent) callconv(.c) c_int {
    g_x_error = true;
    return 0;
}

/// System clipboard backed by the X11 CLIPBOARD selection (#209). Unlike the
/// macOS/Win32 ones, X11's clipboard is asynchronous and window-owned, so this
/// wraps a *Window: setText takes ownership of the selection (served from
/// pumpEvents on SelectionRequest); getText converts + waits for SelectionNotify.
pub const SystemClipboard = struct {
    win: *Window,

    pub fn init(win: *Window) SystemClipboard {
        return .{ .win = win };
    }

    pub fn interface(self: *SystemClipboard) clipboard_mod.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: clipboard_mod.Clipboard.VTable = .{ .get_text = getText, .set_text = setText };

    fn setText(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *SystemClipboard = @ptrCast(@alignCast(ptr));
        const w = self.win;
        const copy = try w.gpa.dupe(u8, text);
        if (w.clipboard_text) |old| w.gpa.free(old);
        w.clipboard_text = copy;
        const clip = XInternAtom(w.display, "CLIPBOARD", 0);
        // ICCCM: acquire with the latest real event time, NOT CurrentTime — else
        // clipboard managers / the Xwayland bridge reject ownership (#318).
        w.clipboard_time = w.last_event_time;
        _ = XSetSelectionOwner(w.display, clip, w.handle, w.last_event_time);
        _ = XFlush(w.display);
    }

    fn getText(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8 {
        const self: *SystemClipboard = @ptrCast(@alignCast(ptr));
        const w = self.win;
        const clip = XInternAtom(w.display, "CLIPBOARD", 0);
        const utf8 = XInternAtom(w.display, "UTF8_STRING", 0);
        const dest = XInternAtom(w.display, "ZOOEE_CLIPBOARD", 0);
        // We own it → return our buffer directly (no round-trip).
        if (XGetSelectionOwner(w.display, clip) == w.handle) {
            if (w.clipboard_text) |t| return try gpa.dupe(u8, t);
            return null;
        }
        _ = XConvertSelection(w.display, clip, utf8, dest, w.handle, 0);
        _ = XFlush(w.display);
        // Wait (bounded ~500ms) for the SelectionNotify reply.
        var ev: XEvent = undefined;
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (XCheckTypedEvent(w.display, SelectionNotify, &ev) != 0) break;
            // 0.16 removed std.Thread.sleep in favour of Io-based sleep; this
            // X11 path is synchronous and Linux-only, so use the raw syscall.
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        } else return null;
        if (ev.xselection.property == 0) return null; // no owner / refused
        var atype: Atom = 0;
        var afmt: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        if (XGetWindowProperty(w.display, w.handle, dest, 0, 1 << 24, 0, utf8, &atype, &afmt, &nitems, &after, &data) != 0) return null;
        defer {
            if (data) |d| _ = XFree(d);
        }
        _ = XDeleteProperty(w.display, w.handle, dest);
        if (data == null or nitems == 0) return null;
        return try gpa.dupe(u8, data.?[0..nitems]);
    }
};

// --- GLX (optional GPU window; #11 GPU-present path) -------------------------
// When a GL window is requested we create the X11 window over a GLX-chosen
// visual and make a context current, so GlBackend can render straight to it.
// If any step fails the caller falls back to the raster (XCreateSimpleWindow
// + XPutImage) window. Mirrors the proven sequence in backends/gl.zig.
const Colormap = XID;
const GLXContext = ?*opaque {};

const XVisualInfo = extern struct {
    visual: ?*Visual,
    visualid: c_ulong,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

const XSetWindowAttributes = extern struct {
    background_pixmap: XID = 0,
    background_pixel: c_ulong = 0,
    border_pixmap: XID = 0,
    border_pixel: c_ulong = 0,
    bit_gravity: c_int = 0,
    win_gravity: c_int = 0,
    backing_store: c_int = 0,
    backing_planes: c_ulong = 0,
    backing_pixel: c_ulong = 0,
    save_under: Bool = 0,
    event_mask: c_long = 0,
    do_not_propagate_mask: c_long = 0,
    override_redirect: Bool = 0,
    colormap: Colormap = 0,
    cursor: XID = 0,
};

extern "X11" fn XCreateColormap(*Display, Window_, ?*Visual, c_int) Colormap;
extern "X11" fn XCreateWindow(*Display, Window_, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, ?*Visual, c_ulong, *XSetWindowAttributes) Window_;
extern "X11" fn XSync(*Display, Bool) c_int;
extern "X11" fn XFree(?*anyopaque) c_int;
extern "GL" fn glXChooseVisual(*Display, c_int, [*]c_int) ?*XVisualInfo;
extern "GL" fn glXCreateContext(*Display, *XVisualInfo, GLXContext, Bool) GLXContext;
extern "GL" fn glXDestroyContext(*Display, GLXContext) void;
extern "GL" fn glXMakeCurrent(*Display, XID, GLXContext) Bool;
extern "GL" fn glXSwapBuffers(*Display, XID) void;

const GLX_RGBA: c_int = 4;
const GLX_DOUBLEBUFFER: c_int = 5;
const GLX_RED_SIZE: c_int = 8;
const GLX_GREEN_SIZE: c_int = 9;
const GLX_BLUE_SIZE: c_int = 10;
const GLX_DEPTH_SIZE: c_int = 12;
const CWBackPixel: c_ulong = 1 << 1;
const CWBorderPixel: c_ulong = 1 << 3;
const CWBitGravity: c_ulong = 1 << 4;
const CWColormap: c_ulong = 1 << 13;
const CWEventMask: c_ulong = 1 << 11;
/// bit_gravity: keep existing content anchored top-left on resize (#182), so
/// growing the window doesn't re-expose/shift what's already painted.
const NorthWestGravity: c_int = 1;
const InputOutput: c_uint = 1;
const AllocNone: c_int = 0;

// Event masks / types / ZPixmap.
const ExposureMask: c_long = 1 << 15;
const KeyPressMask: c_long = 1 << 0;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const StructureNotifyMask: c_long = 1 << 17;

const KeyReleaseMask: c_long = 1 << 1;
const EnterWindowMask: c_long = 1 << 4;
const LeaveWindowMask: c_long = 1 << 5;
const KeyPress = 2;
const KeyRelease = 3;
const EnterNotify = 7;
const LeaveNotify = 8;
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

// --- OS appearance integration (#318): GNOME via gsettings ------------------
// Mirrors the macOS/Windows hooks so the app loop can re-theme live. Degrades
// to "light, no accent, no live updates" on non-GNOME desktops (no gsettings).
const style_mod = @import("../style.zig");

const AppearanceWatcher = struct {
    started: bool = false,
    child: ?std.process.Child = null,
    fd: std.posix.fd_t = -1,
};
var g_watcher: AppearanceWatcher = .{};

/// Run `gsettings get org.gnome.desktop.interface <key>`; caller frees the
/// returned stdout. Null when gsettings is missing or the read fails.
fn gsettingsGet(key: [:0]const u8) ?[]u8 {
    const res = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", key },
    }) catch return null;
    std.heap.page_allocator.free(res.stderr);
    return res.stdout;
}

/// Whether the desktop prefers dark — GNOME `color-scheme == 'prefer-dark'`.
/// Mirrors macOS/Windows `prefersDark()`; false on non-GNOME or when unset.
pub fn prefersDark() bool {
    const out = gsettingsGet("color-scheme") orelse return false;
    defer std.heap.page_allocator.free(out);
    return std.mem.indexOf(u8, out, "prefer-dark") != null;
}

/// The desktop accent (GNOME 47+ `accent-color`, a named enum) → sRGB, or null
/// on older / non-GNOME desktops. Best-effort parity with macOS/Windows accent.
pub fn systemAccent() ?style_mod.Color {
    const out = gsettingsGet("accent-color") orelse return null;
    defer std.heap.page_allocator.free(out);
    const Named = struct { name: []const u8, r: u8, g: u8, b: u8 };
    const palette = [_]Named{
        .{ .name = "blue", .r = 0x35, .g = 0x84, .b = 0xe4 },
        .{ .name = "teal", .r = 0x21, .g = 0x90, .b = 0xa4 },
        .{ .name = "green", .r = 0x3a, .g = 0x94, .b = 0x4a },
        .{ .name = "yellow", .r = 0xc8, .g = 0x88, .b = 0x00 },
        .{ .name = "orange", .r = 0xed, .g = 0x5b, .b = 0x00 },
        .{ .name = "red", .r = 0xe6, .g = 0x2d, .b = 0x42 },
        .{ .name = "pink", .r = 0xd5, .g = 0x61, .b = 0x99 },
        .{ .name = "purple", .r = 0x91, .g = 0x41, .b = 0xac },
        .{ .name = "slate", .r = 0x6f, .g = 0x83, .b = 0x96 },
    };
    for (palette) |p| if (std.mem.indexOf(u8, out, p.name) != null) return style_mod.Color.rgb(p.r, p.g, p.b);
    return null;
}

/// Consume the "OS appearance changed" signal. Lazily starts a single
/// `gsettings monitor org.gnome.desktop.interface` child and polls its pipe
/// non-blocking; any output means a key (color-scheme / accent-color) flipped.
/// The app loop calls this each frame, so no extra fd needs to join the X wait.
pub fn takeAppearanceChanged() bool {
    if (!g_watcher.started) {
        g_watcher.started = true;
        var child = std.process.Child.init(
            &.{ "gsettings", "monitor", "org.gnome.desktop.interface" },
            std.heap.page_allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            g_watcher.child = null;
            return false;
        };
        g_watcher.child = child;
        g_watcher.fd = if (child.stdout) |o| o.handle else -1;
    }
    if (g_watcher.fd < 0) return false;
    var pfd = [_]std.posix.pollfd{.{ .fd = g_watcher.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 0) catch return false;
    if (ready == 0 or (pfd[0].revents & std.posix.POLL.IN) == 0) return false;
    var buf: [512]u8 = undefined;
    const n = std.posix.read(g_watcher.fd, &buf) catch return false;
    return n > 0; // n==0 is EOF (monitor died) — not a change
}

/// Stop the gsettings monitor child. Called from Window.destroy so the helper
/// process doesn't outlive the app.
fn stopAppearanceWatcher() void {
    if (g_watcher.child) |*c| {
        _ = c.kill() catch {};
        g_watcher.child = null;
        g_watcher.fd = -1;
    }
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
    /// Set when the window was created GL-capable and a context is current
    /// (the GPU-present path). null = raster (XPutImage) window.
    gl_ctx: GLXContext = null,
    gl_vi: ?*XVisualInfo = null,
    /// Render-one-frame callback (#182): invoked synchronously on
    /// ConfigureNotify so a resize repaints in the same turn instead of
    /// lagging to the next loop iteration (the exposed strip flashing).
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    redraw_ctx: ?*anyopaque = null,
    /// Lazily-created X font cursors per shape (#123), indexed by the Cursor
    /// enum tag; 0 = not yet created. Freed in `destroy`.
    cursors: [std.meta.fields(cursor_mod.Cursor).len]XID = [_]XID{0} ** std.meta.fields(cursor_mod.Cursor).len,
    /// Click-count tracking (#211): X has no native multi-click, so we count
    /// presses of the same button within 250 ms.
    last_click_time: Time = 0,
    last_click_button: c_uint = 0,
    click_count: u8 = 1,
    /// CLIPBOARD selection contents we own (#209), served to other apps on
    /// SelectionRequest. Owned by `gpa`; freed in destroy.
    clipboard_text: ?[]u8 = null,
    /// Timestamp of the last input event. ICCCM requires acquiring a selection
    /// with a real event time, NOT CurrentTime — clipboard managers and the
    /// Xwayland↔Wayland bridge reject ownership taken with CurrentTime, so copy
    /// silently fails. We stamp ownership with this (#318).
    last_event_time: Time = 0,
    /// The time we took CLIPBOARD ownership — served for the TIMESTAMP target.
    clipboard_time: Time = 0,
    /// XDND drag source during a drag-over (#212); 0 = no drag in progress.
    xdnd_source: Window_ = 0,
    /// X Input Method / Context (#213); null when no IM is available (the
    /// KeyPress path then falls back to XLookupString, ASCII only).
    xim: XIM = null,
    xic: XIC = null,
    /// Drop arena (#212): dropped paths live here until the next pumpEvents.
    drop_arena: std.heap.ArenaAllocator = undefined,
    /// XInput2 scroll state (#309). `xi_opcode` < 0 = XI2 unavailable → fall back
    /// to legacy core button 4/5/6/7 wheel events. The vertical/horizontal scroll
    /// valuators (number + increment) come from XIQueryDevice; `*_last` holds the
    /// previous absolute valuator value (NaN until the first event) so we can emit
    /// signed deltas.
    xi_opcode: c_int = -1,
    xi_v_number: c_int = -1,
    xi_v_incr: f64 = 0,
    xi_h_number: c_int = -1,
    xi_h_incr: f64 = 0,
    xi_v_last: f64 = std.math.nan(f64),
    xi_h_last: f64 = std.math.nan(f64),
    /// Server time of the last XI2 scroll we emitted. The legacy button wheel is
    /// suppressed only within a short window after this (so a wheel that fires
    /// both XI2 *and* core button events doesn't double-scroll) — but if XI2 is
    /// enabled yet silent (some drivers/RDP only send buttons), buttons still
    /// work. 0 = no XI2 scroll seen yet.
    xi_last_scroll_time: Time = 0,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        visible: bool = true,
        /// Try to create a GLX-capable window + current context. Falls back
        /// to a raster window if GLX is unavailable (old driver, no GLX).
        gl: bool = false,
        /// Title-bar mode (#64); honored on macOS, ignored here for now.
        titlebar: window_mod.TitlebarMode = .native,
        /// Accepted for cross-platform parity; macOS-only (traffic lights).
        traffic_lights: ?window_mod.TrafficLights = null,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const display = XOpenDisplay(null) orelse return error.BackendFailure;
        errdefer _ = XCloseDisplay(display);
        const screen = XDefaultScreen(display);
        const root = XRootWindow(display, screen);
        const white = XWhitePixel(display, screen);

        // Try a GL-capable window first when requested; on any failure fall
        // back to the simple (raster) window over the default visual.
        var gl_ctx: GLXContext = null;
        var gl_vi: ?*XVisualInfo = null;
        var gl_visual: ?*Visual = null;
        var gl_depth: c_uint = 0;
        var handle: Window_ = 0;
        if (opts.gl) {
            var attrs = [_]c_int{ GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_DEPTH_SIZE, 24, 0 };
            if (glXChooseVisual(display, screen, &attrs)) |vi| {
                const cmap = XCreateColormap(display, root, vi.visual, AllocNone);
                // CWBorderPixel is REQUIRED when the window's visual/depth
                // differs from the parent (the GLX visual vs the root): the
                // default border_pixmap is CopyFromParent, invalid across
                // depths → BadMatch, which Xlib's default handler turns into
                // a process exit ("window opens blank, then closes"). Xvfb/
                // llvmpipe is lax about it; real X servers are not.
                var swa: XSetWindowAttributes = .{
                    .border_pixel = 0,
                    .colormap = cmap,
                    .event_mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | EnterWindowMask | LeaveWindowMask | StructureNotifyMask,
                    // Anchor existing content top-left on grow so the exposed
                    // strip is the only repaint, not a full re-expose (#182).
                    .bit_gravity = NorthWestGravity,
                };
                const gh = XCreateWindow(display, root, 0, 0, opts.width, opts.height, 0, vi.depth, InputOutput, vi.visual, CWBorderPixel | CWColormap | CWEventMask | CWBitGravity, &swa);
                const ctx = glXCreateContext(display, vi, null, 1);
                if (ctx != null and glXMakeCurrent(display, gh, ctx) != 0) {
                    handle = gh;
                    gl_ctx = ctx;
                    gl_vi = vi;
                    gl_visual = vi.visual;
                    gl_depth = @intCast(vi.depth);
                } else {
                    if (ctx != null) glXDestroyContext(display, ctx);
                    _ = XDestroyWindow(display, gh);
                    _ = XFree(vi);
                }
            }
        }
        if (handle == 0) handle = XCreateSimpleWindow(display, root, 0, 0, opts.width, opts.height, 0, white, white);
        _ = XStoreName(display, handle, opts.title.ptr); // legacy/fallback (Latin-1)
        // Modern UTF-8 title: _NET_WM_NAME = UTF8_STRING, so the WM shows
        // multibyte glyphs (e.g. the em-dash) correctly. PropModeReplace=0.
        const net_wm_name = XInternAtom(display, "_NET_WM_NAME", 0);
        const utf8_string = XInternAtom(display, "UTF8_STRING", 0);
        _ = XChangeProperty(display, handle, net_wm_name, utf8_string, 8, 0, opts.title.ptr, @intCast(opts.title.len));
        _ = XSelectInput(display, handle, ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | EnterWindowMask | LeaveWindowMask | StructureNotifyMask);

        var wm_delete = XInternAtom(display, "WM_DELETE_WINDOW", 0);
        _ = XSetWMProtocols(display, handle, &wm_delete, 1);

        // Advertise XDND v5 so other apps can drop files on us (#212).
        var xdnd_version: Atom = 5;
        _ = XChangeProperty(display, handle, XInternAtom(display, "XdndAware", 0), 4, 32, 0, @ptrCast(&xdnd_version), 1); // XA_ATOM=4

        // Title bar (#64): only `.headless` drops the WM decorations (the app
        // owns the whole surface) via _MOTIF_WM_HINTS (flags =
        // MWM_HINTS_DECORATIONS 1<<1, decorations = 0). `.integrated` is a
        // macOS-specific transparent-overlay look that has no X11 analogue while
        // keeping working window controls, so on X11 it falls back to the normal
        // window-manager title bar (same as `.native`) — otherwise the window
        // has no title bar and can't be moved or closed.
        if (opts.titlebar == .headless) {
            const motif = XInternAtom(display, "_MOTIF_WM_HINTS", 0);
            var hints = [5]c_long{ 2, 0, 0, 0, 0 };
            _ = XChangeProperty(display, handle, motif, motif, 32, 0, @ptrCast(&hints), 5);
        }

        // IME (#213): open an input method + a root-style context bound to the
        // window, so KeyPress can use Xutf8LookupString for CJK/dead-key
        // composition. Best-effort — falls back to ASCII if no IM is available.
        _ = setlocale(LC_CTYPE, "");
        _ = XSetLocaleModifiers("");
        const xim = XOpenIM(display, null, null, null);
        var xic: XIC = null;
        if (xim != null) {
            xic = XCreateIC(xim, XNInputStyle.ptr, XIMPreeditNothing | XIMStatusNothing, XNClientWindow.ptr, handle, @as(?*anyopaque, null));
            if (xic != null) XSetICFocus(xic);
        }

        const gc = XCreateGC(display, handle, 0, null) orelse return error.BackendFailure;
        if (opts.visible) _ = XMapWindow(display, handle);
        _ = XFlush(display);

        const self = try gpa.create(Window);
        self.* = .{
            .display = display,
            .handle = handle,
            .gc = gc,
            .visual = if (gl_visual) |v| v else XDefaultVisual(display, screen),
            .depth = if (gl_depth != 0) gl_depth else @intCast(XDefaultDepth(display, screen)),
            .wm_delete = wm_delete,
            .drop_arena = std.heap.ArenaAllocator.init(gpa),
            .xim = xim,
            .xic = xic,
            .gpa = gpa,
            .width = opts.width,
            .height = opts.height,
            .gl_ctx = gl_ctx,
            .gl_vi = gl_vi,
        };
        self.initXi2(); // smooth + natural-scroll-aware wheel (#309); best-effort
        return self;
    }

    /// Best-effort XInput2 setup (#309): probe the extension, select XI_Motion on
    /// this window, and find the pointer's vertical/horizontal scroll valuators.
    /// On any failure leaves `xi_opcode` < 0 so pumpEvents uses the legacy
    /// button-wheel fallback.
    fn initXi2(self: *Window) void {
        var op: c_int = 0;
        var first_ev: c_int = 0;
        var first_err: c_int = 0;
        if (XQueryExtension(self.display, "XInputExtension", &op, &first_ev, &first_err) == 0) return;
        var major: c_int = 2;
        var minor: c_int = 0;
        if (XIQueryVersion(self.display, &major, &minor) != 0) return; // Success == 0

        // From here, make X errors non-fatal so a server with incomplete XInput2
        // (e.g. Xvfb) can't kill us — we detect the failure and fall back instead.
        _ = XSetErrorHandler(xErrorHandler);

        // Select XI_Motion (carries scroll valuators) for all master pointers,
        // then XSync and check whether the server accepted it. If not, bail with
        // xi_opcode still < 0 so pumpEvents uses the legacy button wheel.
        var bits = [_]u8{0} ** 4;
        const e: usize = @intCast(XI_Motion);
        bits[e >> 3] |= @as(u8, 1) << @intCast(e & 7);
        var em: XIEventMask = .{ .deviceid = XIAllMasterDevices, .mask_len = bits.len, .mask = &bits };
        g_x_error = false;
        _ = XISelectEvents(self.display, self.handle, @ptrCast(&em), 1);
        _ = XSync(self.display, 0);
        if (g_x_error) return; // XI2 scroll selection rejected → button fallback

        // Discover scroll valuators (axis number + increment) on the devices.
        var n: c_int = 0;
        const devs = XIQueryDevice(self.display, XIAllMasterDevices, &n) orelse return;
        defer XIFreeDeviceInfo(devs);
        var di: usize = 0;
        while (di < @as(usize, @intCast(n))) : (di += 1) {
            const dev = devs[di];
            const classes = dev.classes orelse continue;
            var ci: usize = 0;
            while (ci < @as(usize, @intCast(dev.num_classes))) : (ci += 1) {
                const any = classes[ci];
                if (any.type != XIScrollClass) continue;
                const sc: *XIScrollClassInfo = @ptrCast(@alignCast(any));
                if (sc.scroll_type == XIScrollTypeVertical) {
                    self.xi_v_number = sc.number;
                    self.xi_v_incr = sc.increment;
                } else if (sc.scroll_type == XIScrollTypeHorizontal) {
                    self.xi_h_number = sc.number;
                    self.xi_h_incr = sc.increment;
                }
            }
        }
        // Enable XI2 only if we actually found a vertical scroll valuator (the
        // common axis); otherwise keep the legacy button wheel so scrolling still
        // works.
        if (self.xi_v_number < 0) return;
        self.xi_opcode = op;
    }

    /// Turn an XI_Motion's scroll valuators into a canonical scroll event (#309).
    /// Each axis reports an absolute accumulator; the per-event delta is
    /// (value − last)/increment, whose sign already reflects natural scrolling.
    fn handleXiScroll(self: *Window, de: *const XIDeviceEvent) void {
        const vs = de.valuators;
        const mask = vs.mask orelse return;
        const values = vs.values orelse return;
        var dx: f64 = 0;
        var dy: f64 = 0;
        var have = false;
        var vidx: usize = 0; // index into the packed values[] (set bits only)
        const nbits: usize = @intCast(vs.mask_len * 8);
        var i: usize = 0;
        while (i < nbits) : (i += 1) {
            if (mask[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) continue;
            const val = values[vidx];
            vidx += 1;
            const num: c_int = @intCast(i);
            if (num == self.xi_v_number and self.xi_v_incr != 0) {
                if (!std.math.isNan(self.xi_v_last)) {
                    dy += (val - self.xi_v_last) / self.xi_v_incr;
                    have = true;
                }
                self.xi_v_last = val;
            } else if (num == self.xi_h_number and self.xi_h_incr != 0) {
                if (!std.math.isNan(self.xi_h_last)) {
                    dx += (val - self.xi_h_last) / self.xi_h_incr;
                    have = true;
                }
                self.xi_h_last = val;
            }
        }
        if (!have or (dx == 0 and dy == 0)) return;
        self.xi_last_scroll_time = de.time; // de-dup the core button wheel
        self.queue.append(self.gpa, .{ .scroll = .{
            .position = .{ .x = @floatCast(de.event_x), .y = @floatCast(de.event_y) },
            .dx = @floatCast(dx),
            .dy = @floatCast(dy),
            .unit = .line,
            .mods = x11Mods(@intCast(de.mods.effective)),
        } }) catch {};
    }

    /// Present the GL default framebuffer (GPU-present path). No-op if this
    /// is a raster window.
    pub fn glSwap(self: *Window) void {
        if (self.gl_ctx != null) glXSwapBuffers(self.display, self.handle);
    }

    /// No-op: GLX tracks the X drawable's size automatically on resize.
    /// (macOS needs `[NSOpenGLContext update]`; this keeps runWindowGl
    /// platform-agnostic.)
    pub fn glUpdate(self: *Window) void {
        _ = self;
    }

    /// Register the render-one-frame callback. Unlike the original no-op, X11
    /// now repaints synchronously on ConfigureNotify (#182): the resize repaint
    /// happens in the same pumpEvents call, not the next loop iteration, so the
    /// newly-exposed strip doesn't flash before it's painted.
    pub fn setRedraw(self: *Window, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = f;
    }

    /// Apply a pointer cursor shape (#123) via the X cursor font. Cursors are
    /// created lazily and cached per shape. The cursor-font glyph numbers are
    /// the standard `XC_*` constants from `<X11/cursorfont.h>`.
    pub fn setCursor(self: *Window, shape: cursor_mod.Cursor) void {
        // XC_* glyph indices. Diagonal resizes use the nearest corner cursor;
        // not_allowed uses XC_X_cursor (no slashed-circle exists in the font).
        const glyph: c_uint = switch (shape) {
            .default => 68, // XC_left_ptr
            .pointer => 60, // XC_hand2
            .text => 152, // XC_xterm
            .crosshair => 34, // XC_crosshair
            .not_allowed => 0, // XC_X_cursor
            .grab => 58, // XC_hand1
            .grabbing => 58, // XC_hand1 (no closed-hand glyph)
            .ew_resize => 108, // XC_sb_h_double_arrow
            .ns_resize => 116, // XC_sb_v_double_arrow
            .nwse_resize => 134, // XC_top_left_corner
            .nesw_resize => 136, // XC_top_right_corner
            .wait => 150, // XC_watch
        };
        const idx = @intFromEnum(shape);
        if (self.cursors[idx] == 0) self.cursors[idx] = XCreateFontCursor(self.display, glyph);
        _ = XDefineCursor(self.display, self.handle, self.cursors[idx]);
        _ = XFlush(self.display);
    }

    // --- Window operations (#208) — mirror the macOS Window method set. ---

    pub fn setSize(self: *Window, w: f32, h: f32) void {
        _ = XResizeWindow(self.display, self.handle, @intFromFloat(@max(1, w)), @intFromFloat(@max(1, h)));
        _ = XFlush(self.display);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = XStoreName(self.display, self.handle, title.ptr);
        const net = XInternAtom(self.display, "_NET_WM_NAME", 0);
        const utf8 = XInternAtom(self.display, "UTF8_STRING", 0);
        _ = XChangeProperty(self.display, self.handle, net, utf8, 8, 0, title.ptr, @intCast(title.len));
        _ = XFlush(self.display);
    }

    pub fn minimise(self: *Window) void {
        _ = XIconifyWindow(self.display, self.handle, XDefaultScreen(self.display));
        _ = XFlush(self.display);
    }

    /// De-iconify / un-maximise back to normal.
    pub fn restore(self: *Window) void {
        self.netWmState(0, "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"); // remove
        _ = XMapRaised(self.display, self.handle);
        _ = XFlush(self.display);
    }

    pub fn maximise(self: *Window) void {
        self.netWmState(1, "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"); // add
    }

    /// App-initiated close: enqueue close_requested so the loop breaks, matching
    /// macOS performClose (the app decides whether to destroy).
    pub fn close(self: *Window) void {
        self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
    }

    /// Native context menu (#129): X11 has no toolkit-agnostic native menu, so
    /// there's nothing to pop. Returns null; apps fall back to an in-window
    /// overlay menu (#17). Present so the app loop's context-menu dispatch
    /// compiles uniformly across platforms.
    pub fn popupMenu(self: *Window, items: []const menu_mod.Item, x: f32, y: f32) ?u32 {
        _ = self;
        _ = items;
        _ = x;
        _ = y;
        return null;
    }

    /// Native menu bar (#129): no native X11 menu bar; no-op (apps draw their
    /// own, #17). Present for cross-platform uniformity.
    pub fn setMenuBar(self: *Window, items: []const menu_mod.Item) void {
        _ = self;
        _ = items;
    }

    /// No native menu bar on X11, so never a menu-bar command. (#129)
    pub fn takeMenuCommand(self: *Window) ?u32 {
        _ = self;
        return null;
    }

    pub fn isMinimised(self: *Window) bool {
        // WM_STATE first value == IconicState (3).
        return self.firstCard("WM_STATE") == 3;
    }

    pub fn isMaximised(self: *Window) bool {
        return self.hasNetState("_NET_WM_STATE_MAXIMIZED_VERT");
    }

    /// Send a _NET_WM_STATE client message to the root (action: 0=remove,
    /// 1=add) toggling up to two state atoms.
    fn netWmState(self: *Window, action: c_long, a1: [:0]const u8, a2: [:0]const u8) void {
        const root = XRootWindow(self.display, XDefaultScreen(self.display));
        var ev: XEvent = undefined;
        ev.xclient = .{
            .type = ClientMessage,
            .serial = 0,
            .send_event = 1,
            .display = self.display,
            .window = self.handle,
            .message_type = XInternAtom(self.display, "_NET_WM_STATE", 0),
            .format = 32,
            .data = .{
                .l = .{
                    action,
                    @bitCast(@as(c_ulong, XInternAtom(self.display, a1, 0))),
                    @bitCast(@as(c_ulong, XInternAtom(self.display, a2, 0))),
                    1, // source: application
                    0,
                },
            },
        };
        _ = XSendEvent(self.display, root, 0, SubstructureMask, &ev);
        _ = XFlush(self.display);
    }

    /// First 32-bit value of `prop_name` on this window, or -1 if absent.
    fn firstCard(self: *Window, prop_name: [:0]const u8) c_long {
        const prop = XInternAtom(self.display, prop_name, 0);
        var atype: Atom = 0;
        var afmt: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        if (XGetWindowProperty(self.display, self.handle, prop, 0, 2, 0, 0, &atype, &afmt, &nitems, &after, &data) != 0) return -1;
        defer {
            if (data) |d| {
                _ = XFree(d);
            }
        }
        if (data == null or afmt != 32 or nitems == 0) return -1;
        const vals: [*]const c_ulong = @ptrCast(@alignCast(data.?));
        return @bitCast(@as(c_ulong, vals[0]));
    }

    /// Whether `_NET_WM_STATE` contains the named atom.
    fn hasNetState(self: *Window, atom_name: [:0]const u8) bool {
        const prop = XInternAtom(self.display, "_NET_WM_STATE", 0);
        const want = XInternAtom(self.display, atom_name, 0);
        var atype: Atom = 0;
        var afmt: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        if (XGetWindowProperty(self.display, self.handle, prop, 0, 32, 0, 0, &atype, &afmt, &nitems, &after, &data) != 0) return false;
        defer {
            if (data) |d| {
                _ = XFree(d);
            }
        }
        if (data == null or afmt != 32) return false;
        const atoms: [*]const c_ulong = @ptrCast(@alignCast(data.?));
        var i: usize = 0;
        while (i < nitems) : (i += 1) if (atoms[i] == want) return true;
        return false;
    }

    // --- XDND drop target (#212) ------------------------------------------

    /// Handle an XDND client message (Enter/Position/Leave/Drop). Returns true
    /// if it was an XDND message.
    fn handleXdnd(self: *Window, cm: *const XClientMessageEvent) bool {
        const d = self.display;
        const mt = cm.message_type;
        if (mt == XInternAtom(d, "XdndEnter", 0)) {
            self.xdnd_source = @bitCast(cm.data.l[0]);
            return true;
        } else if (mt == XInternAtom(d, "XdndPosition", 0)) {
            self.sendXdndStatus(@bitCast(cm.data.l[0]));
            return true;
        } else if (mt == XInternAtom(d, "XdndLeave", 0)) {
            self.xdnd_source = 0;
            return true;
        } else if (mt == XInternAtom(d, "XdndDrop", 0)) {
            const src: Window_ = @bitCast(cm.data.l[0]);
            const time: Time = @bitCast(cm.data.l[2]);
            self.xdnd_source = src;
            _ = XConvertSelection(d, XInternAtom(d, "XdndSelection", 0), XInternAtom(d, "text/uri-list", 0), XInternAtom(d, "XdndTarget", 0), self.handle, time);
            _ = XFlush(d);
            return true; // data arrives via SelectionNotify
        }
        return false;
    }

    fn sendXdndStatus(self: *Window, source: Window_) void {
        const d = self.display;
        var ev: XEvent = undefined;
        ev.xclient = .{
            .type = ClientMessage,
            .serial = 0,
            .send_event = 1,
            .display = d,
            .window = source,
            .message_type = XInternAtom(d, "XdndStatus", 0),
            .format = 32,
            .data = .{
                .l = .{
                    @bitCast(@as(c_ulong, self.handle)),
                    1, // accept
                    0, // empty rect → re-ask each move
                    0,
                    @bitCast(@as(c_ulong, XInternAtom(d, "XdndActionCopy", 0))),
                },
            },
        };
        _ = XSendEvent(d, source, 0, 0, &ev);
        _ = XFlush(d);
    }

    fn sendXdndFinished(self: *Window) void {
        if (self.xdnd_source == 0) return;
        const d = self.display;
        var ev: XEvent = undefined;
        ev.xclient = .{
            .type = ClientMessage,
            .serial = 0,
            .send_event = 1,
            .display = d,
            .window = self.xdnd_source,
            .message_type = XInternAtom(d, "XdndFinished", 0),
            .format = 32,
            .data = .{ .l = .{ @bitCast(@as(c_ulong, self.handle)), 1, @bitCast(@as(c_ulong, XInternAtom(d, "XdndActionCopy", 0))), 0, 0 } },
        };
        _ = XSendEvent(d, self.xdnd_source, 0, 0, &ev);
        _ = XFlush(d);
        self.xdnd_source = 0;
    }

    /// Read the dropped text/uri-list property, enqueue a .drop, ack the source.
    fn readXdndDrop(self: *Window) void {
        const d = self.display;
        const prop = XInternAtom(d, "XdndTarget", 0);
        var atype: Atom = 0;
        var afmt: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        if (XGetWindowProperty(d, self.handle, prop, 0, 1 << 24, 0, 0, &atype, &afmt, &nitems, &after, &data) == 0) {
            defer {
                if (data) |dd| _ = XFree(dd);
            }
            if (data != null and nitems > 0) {
                const a = self.drop_arena.allocator();
                var paths: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitAny(u8, data.?[0..nitems], "\r\n");
                while (it.next()) |line| {
                    if (line.len == 0 or line[0] == '#') continue;
                    if (decodeFileUri(a, line)) |p| paths.append(a, p) catch {};
                }
                self.queue.append(self.gpa, .{ .drop = .{
                    .position = .{ .x = 0, .y = 0 },
                    .data = .{ .files = paths.items },
                    .operation = .copy,
                } }) catch {};
            }
        }
        _ = XDeleteProperty(d, self.handle, prop);
        self.sendXdndFinished();
    }

    /// Set the window's background to `(r,g,b)` (#182). The server fills any
    /// region exposed by a resize-grow with this — the theme background —
    /// instead of black, until the client repaints. Assumes a TrueColor visual
    /// (the GLX RGBA visual is one): pixel = R<<16 | G<<8 | B.
    pub fn setBackground(self: *Window, r: u8, g: u8, b: u8) void {
        const pixel: c_ulong = (@as(c_ulong, r) << 16) | (@as(c_ulong, g) << 8) | @as(c_ulong, b);
        _ = XSetWindowBackground(self.display, self.handle, pixel);
        _ = XClearWindow(self.display, self.handle);
        _ = XFlush(self.display);
    }

    pub fn destroy(self: *Window) void {
        stopAppearanceWatcher(); // don't leave the gsettings monitor running
        if (self.gl_ctx) |ctx| {
            _ = glXMakeCurrent(self.display, 0, null);
            glXDestroyContext(self.display, ctx);
            if (self.gl_vi) |vi| _ = XFree(vi);
        }
        if (self.ximage) |img| {
            img.data = null; // our buffer; let Xlib free only the struct
            if (img.f.destroy_image) |di| _ = di(img);
        }
        for (self.cursors) |c| if (c != 0) {
            _ = XFreeCursor(self.display, c);
        };
        if (self.xic != null) XDestroyIC(self.xic);
        if (self.xim != null) _ = XCloseIM(self.xim);
        if (self.clipboard_text) |t| self.gpa.free(t);
        self.drop_arena.deinit();
        self.bgra.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        _ = XDestroyWindow(self.display, self.handle);
        _ = XCloseDisplay(self.display);
        self.gpa.destroy(self);
    }

    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        _ = self.drop_arena.reset(.retain_capacity); // free last frame's drop paths (#212)
        while (XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = XNextEvent(self.display, &ev);
            // Let the input method consume keystrokes it's composing (#213).
            if (self.xic != null and XFilterEvent(&ev, self.handle) != 0) continue;
            // Track the latest input-event time for selection ownership (#318).
            switch (ev.type) {
                KeyPress, KeyRelease => self.last_event_time = ev.xkey.time,
                ButtonPress, ButtonRelease => self.last_event_time = ev.xbutton.time,
                MotionNotify => self.last_event_time = ev.xmotion.time,
                else => {},
            }
            switch (ev.type) {
                ClientMessage => {
                    if (@as(Atom, @bitCast(ev.xclient.data.l[0])) == self.wm_delete) {
                        self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
                    } else {
                        _ = self.handleXdnd(&ev.xclient); // #212
                    }
                },
                SelectionNotify => {
                    // XDND drop data arrived (#212); clipboard's SelectionNotify
                    // is consumed synchronously elsewhere (distinct property).
                    if (ev.xselection.property == XInternAtom(self.display, "XdndTarget", 0)) {
                        self.readXdndDrop();
                    }
                },
                ConfigureNotify => {
                    const w: u32 = @intCast(ev.xconfigure.width);
                    const h: u32 = @intCast(ev.xconfigure.height);
                    if (w != self.width or h != self.height) {
                        self.width = w;
                        self.height = h;
                        self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } } }) catch {};
                        // Repaint immediately at the new size (#182) so the
                        // exposed strip is painted this turn, not next iteration.
                        if (self.redraw_fn) |f| f(self.redraw_ctx);
                    }
                },
                Expose => self.queue.append(self.gpa, .{ .resized = .{ .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) } } }) catch {},
                MotionNotify => self.queue.append(self.gpa, .{ .pointer_move = .{ .position = .{ .x = @floatFromInt(ev.xmotion.x), .y = @floatFromInt(ev.xmotion.y) }, .mods = x11Mods(ev.xmotion.state) } }) catch {},
                EnterNotify => self.queue.append(self.gpa, .{ .pointer_enter = .{ .position = .{ .x = @floatFromInt(ev.xcrossing.x), .y = @floatFromInt(ev.xcrossing.y) }, .mods = x11Mods(ev.xcrossing.state) } }) catch {},
                LeaveNotify => self.queue.append(self.gpa, .{ .pointer_leave = .{ .position = .{ .x = @floatFromInt(ev.xcrossing.x), .y = @floatFromInt(ev.xcrossing.y) }, .mods = x11Mods(ev.xcrossing.state) } }) catch {},
                KeyRelease => {
                    const ks = XLookupKeysym(&ev.xkey, 0);
                    if (keysymToKey(ks)) |k| {
                        self.queue.append(self.gpa, .{ .key_up = .{ .key = k, .mods = x11Mods(ev.xkey.state) } }) catch {};
                    }
                },
                GenericEvent => {
                    // XInput2 scroll (#309): a cookie-bearing event from the
                    // XInputExtension; fetch its data, and if it's an XI_Motion
                    // turn its scroll valuators into a canonical scroll event.
                    if (self.xi_opcode >= 0) {
                        const cookie: *XGenericEventCookie = @ptrCast(&ev);
                        if (cookie.extension == self.xi_opcode and XGetEventData(self.display, cookie) != 0) {
                            if (cookie.evtype == XI_Motion) {
                                if (cookie.data) |d| self.handleXiScroll(@ptrCast(@alignCast(d)));
                            }
                            XFreeEventData(self.display, cookie);
                        }
                    }
                },
                ButtonPress, ButtonRelease => {
                    const b = ev.xbutton.button;
                    // Legacy wheel: 4=up, 5=down, 6=left, 7=right (one notch per
                    // press). Suppressed only within ~60ms of an XI2 scroll, so a
                    // wheel that fires both XI2 and core buttons doesn't double-
                    // scroll — but if XI2 is enabled yet silent (some drivers/RDP
                    // only deliver buttons), these still drive scrolling. Canonical
                    // sign (#309): dy>0 = toward later content (down), dx>0 = right.
                    if (b >= 4 and b <= 7) {
                        const t = ev.xbutton.time;
                        const xi_recent = self.xi_last_scroll_time != 0 and t >= self.xi_last_scroll_time and (t - self.xi_last_scroll_time) < 60;
                        if (!xi_recent and ev.type == ButtonPress) {
                            self.queue.append(self.gpa, .{ .scroll = .{
                                .position = .{ .x = @floatFromInt(ev.xbutton.x), .y = @floatFromInt(ev.xbutton.y) },
                                .dx = switch (b) {
                                    6 => -1,
                                    7 => 1,
                                    else => 0,
                                },
                                .dy = switch (b) {
                                    4 => -1,
                                    5 => 1,
                                    else => 0,
                                },
                                .unit = .line,
                            } }) catch {};
                        }
                    } else {
                        // Click-count (#211): X has no native multi-click — count
                        // same-button presses within 250 ms.
                        if (ev.type == ButtonPress) {
                            const t = ev.xbutton.time;
                            if (b == self.last_click_button and t >= self.last_click_time and t - self.last_click_time <= 250) {
                                self.click_count +|= 1;
                            } else {
                                self.click_count = 1;
                            }
                            self.last_click_time = t;
                            self.last_click_button = b;
                        }
                        const pe: core_event.PointerEvent = .{
                            .position = .{ .x = @floatFromInt(ev.xbutton.x), .y = @floatFromInt(ev.xbutton.y) },
                            .buttons = .{ .primary = b == 1, .middle = b == 2, .secondary = b == 3 },
                            .mods = x11Mods(ev.xbutton.state),
                            .click_count = if (ev.type == ButtonPress) self.click_count else 1,
                        };
                        self.queue.append(self.gpa, if (ev.type == ButtonPress) .{ .pointer_down = pe } else .{ .pointer_up = pe }) catch {};
                    }
                },
                KeyPress => {
                    const ks = XLookupKeysym(&ev.xkey, 0);
                    if (keysymToKey(ks)) |k| {
                        self.queue.append(self.gpa, .{ .key_down = .{ .key = k, .mods = x11Mods(ev.xkey.state) } }) catch {};
                    } else if ((x11Mods(ev.xkey.state).ctrl or x11Mods(ev.xkey.state).super) and ks >= 'a' and ks <= 'z') {
                        // Ctrl/Super + letter → the base letter as a .text event with
                        // mods, so shortcuts like Ctrl+C reach the app (#318).
                        // XLookupString would otherwise yield a dropped control char.
                        self.queue.append(self.gpa, .{ .text = .{ .codepoint = @intCast(ks), .mods = x11Mods(ev.xkey.state) } }) catch {};
                    } else {
                        // With an input context (#213) use Xutf8LookupString so
                        // IME-composed / dead-key / multi-byte input comes back as
                        // UTF-8; decode and emit a .text per codepoint.
                        var buf: [64]u8 = undefined;
                        var ksym: KeySym = 0;
                        var status: c_int = 0;
                        const n: usize = if (self.xic != null)
                            @intCast(@max(0, Xutf8LookupString(self.xic, &ev.xkey, &buf, buf.len, &ksym, &status)))
                        else
                            @intCast(@max(0, XLookupString(&ev.xkey, &buf, buf.len, null, null)));
                        if (n > 0) {
                            const mods = x11Mods(ev.xkey.state);
                            var view = std.unicode.Utf8View.initUnchecked(buf[0..n]);
                            var cit = view.iterator();
                            while (cit.nextCodepoint()) |cp| {
                                if (cp >= 0x20 and cp != 0x7f) {
                                    self.queue.append(self.gpa, .{ .text = .{ .codepoint = cp, .mods = mods } }) catch {};
                                }
                            }
                        }
                    }
                },
                SelectionRequest => {
                    // Another app is pasting the CLIPBOARD selection we own
                    // (#209): serve clipboard_text, or refuse with property=None.
                    const req = ev.xselectionrequest;
                    const utf8 = XInternAtom(self.display, "UTF8_STRING", 0);
                    const targets_atom = XInternAtom(self.display, "TARGETS", 0);
                    const timestamp_atom = XInternAtom(self.display, "TIMESTAMP", 0);
                    var prop = req.property;
                    if (self.clipboard_text) |text| {
                        if (req.target == utf8 or req.target == 31) { // XA_STRING=31
                            _ = XChangeProperty(self.display, req.requestor, req.property, req.target, 8, 0, text.ptr, @intCast(text.len));
                        } else if (req.target == targets_atom) {
                            // Advertise the targets a clipboard manager checks for.
                            var list = [_]Atom{ targets_atom, timestamp_atom, utf8, 31 };
                            _ = XChangeProperty(self.display, req.requestor, req.property, 4, 32, 0, @ptrCast(&list), list.len); // XA_ATOM=4
                        } else if (req.target == timestamp_atom) {
                            // ICCCM: report the ownership time as an INTEGER (XA_INTEGER=19).
                            var t: Time = self.clipboard_time;
                            _ = XChangeProperty(self.display, req.requestor, req.property, 19, 32, 0, @ptrCast(&t), 1);
                        } else {
                            prop = 0; // unsupported target → None
                        }
                    } else {
                        prop = 0;
                    }
                    var nev: XEvent = undefined;
                    nev.xselection = .{
                        .type = SelectionNotify,
                        .serial = 0,
                        .send_event = 1,
                        .display = self.display,
                        .requestor = req.requestor,
                        .selection = req.selection,
                        .target = req.target,
                        .property = prop,
                        .time = req.time,
                    };
                    _ = XSendEvent(self.display, req.requestor, 0, 0, &nev);
                    _ = XFlush(self.display);
                },
                else => {},
            }
        }
        return self.queue.items;
    }
};

/// The user-configured Xft.dpi from the X resource manager (#207), or null
/// when unset (e.g. a bare Xvfb). 96 dpi = scale 1.0.
fn xftDpi(display: *Display) ?f32 {
    XrmInitialize();
    const rm = XResourceManagerString(display) orelse return null;
    const db = XrmGetStringDatabase(rm);
    defer XrmDestroyDatabase(db);
    var type_ret: ?[*:0]const u8 = null;
    var value: XrmValue = undefined;
    if (XrmGetResource(db, "Xft.dpi", "Xft.Dpi", &type_ret, &value) == 0) return null;
    const addr = value.addr orelse return null;
    return std.fmt.parseFloat(f32, std.mem.span(addr)) catch null;
}

/// Module-level to match win32/macos (app.zig calls platform.contentPixelSize).
/// X11 windows are sized in physical pixels; scale = Xft.dpi/96 tells layout how
/// to upscale logical units (#207). Defaults to 1.0 when Xft.dpi is unset.
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    const dpi = xftDpi(window.display) orelse 96.0;
    const scale: f64 = @as(f64, dpi) / 96.0;
    return .{ .width = window.width, .height = window.height, .scale = if (scale > 0.1) scale else 1.0 };
}

extern "c" fn dlopen([*:0]const u8, c_int) ?*anyopaque;
extern "c" fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

/// Display refresh rate (Hz) for frame pacing (#170/#206) via XRandR, loaded
/// with dlopen so libXrandr is NOT a hard link dependency (absent → 0 → the
/// caller falls back to 60). Keeps the binary runnable on minimal X setups.
pub fn refreshHz(window: *Window) f32 {
    const lib = dlopen("libXrandr.so.2", RTLD_NOW) orelse return 0;
    const GetInfo = *const fn (*Display, Window_) callconv(.c) ?*anyopaque;
    const CurRate = *const fn (?*anyopaque) callconv(.c) c_short;
    const FreeInfo = *const fn (?*anyopaque) callconv(.c) void;
    const get_info: GetInfo = @ptrCast(dlsym(lib, "XRRGetScreenInfo") orelse return 0);
    const cur_rate: CurRate = @ptrCast(dlsym(lib, "XRRConfigCurrentRate") orelse return 0);
    const free_info: FreeInfo = @ptrCast(dlsym(lib, "XRRFreeScreenConfigInfo") orelse return 0);
    const root = XRootWindow(window.display, XDefaultScreen(window.display));
    const conf = get_info(window.display, root) orelse return 0;
    defer free_info(conf);
    const rate = cur_rate(conf);
    return if (rate > 0) @floatFromInt(rate) else 0;
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
