//! macOS windowing layer (#9): NSApplication/NSWindow driven directly
//! through the Objective-C runtime — no Xcode project, no frameworks
//! beyond AppKit itself, no third-party dependency (2MB budget, #14).
//!
//! Mirrors the Win32 layer's shape: Window.create/destroy + a
//! non-blocking pumpEvents translating a first event subset. Ships as a
//! .app bundle (assembled by zig build per Daniel's requirement);
//! activation policy is set programmatically so a bare dev binary still
//! fronts a window. DPI, full input translation, and integrated title
//! bars are #9 follow-ups.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) @compileError("macos.zig is macOS-only; gate imports on builtin.os.tag");
}

// --- objc runtime ----------------------------------------------------------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;

extern "objc" fn objc_getClass([*:0]const u8) Class;
extern "objc" fn sel_registerName([*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

fn msg(comptime Ret: type, comptime Args: type, target: anytype, selector: SEL, args: Args) Ret {
    const Fn = switch (@typeInfo(Args).@"struct".fields.len) {
        0 => *const fn (@TypeOf(target), SEL) callconv(.c) Ret,
        1 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type) callconv(.c) Ret,
        2 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type, @typeInfo(Args).@"struct".fields[1].type) callconv(.c) Ret,
        4 => *const fn (
            @TypeOf(target),
            SEL,
            @typeInfo(Args).@"struct".fields[0].type,
            @typeInfo(Args).@"struct".fields[1].type,
            @typeInfo(Args).@"struct".fields[2].type,
            @typeInfo(Args).@"struct".fields[3].type,
        ) callconv(.c) Ret,
        else => @compileError("unsupported arg count"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return switch (@typeInfo(Args).@"struct".fields.len) {
        0 => f(target, selector),
        1 => f(target, selector, @field(args, "0")),
        2 => f(target, selector, @field(args, "0"), @field(args, "1")),
        4 => f(target, selector, @field(args, "0"), @field(args, "1"), @field(args, "2"), @field(args, "3")),
        else => unreachable,
    };
}

fn sel(comptime name: [:0]const u8) SEL {
    // sel_registerName is cheap and idempotent; fine per call for v1.
    return sel_registerName(name.ptr);
}

fn cls(comptime name: [:0]const u8) Class {
    return objc_getClass(name.ptr);
}

fn nsString(text: [:0]const u8) id {
    return msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{text.ptr});
}

// --- events ----------------------------------------------------------------

pub const Event = union(enum) {
    close_requested,
    resized: struct { width: u32, height: u32 },
};

// --- window ----------------------------------------------------------------

const NSWindowStyleMask = struct {
    const titled: u64 = 1 << 0;
    const closable: u64 = 1 << 1;
    const miniaturizable: u64 = 1 << 2;
    const resizable: u64 = 1 << 3;
};

pub const Window = struct {
    ns_window: id,
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Event) = .empty,
    last_size: NSRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Close = "was visible, now isn't" — visibility lags app launch, so
    /// a not-yet-visible window must not read as closed.
    was_visible: bool = false,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: f64 = 800,
        height: f64 = 600,
    };

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        // NSApplicationActivationPolicyRegular = 0: Dock icon + key window
        // even for a bare binary (the .app bundle makes it look right).
        _ = msg(bool, struct { i64 }, app, sel("setActivationPolicy:"), .{0});
        // Required when launched via LaunchServices (.app double-click /
        // `open`): without it the window never becomes visible.
        _ = msg(void, struct {}, app, sel("finishLaunching"), .{});

        const window_alloc = msg(id, struct {}, cls("NSWindow"), sel("alloc"), .{});
        const style = NSWindowStyleMask.titled | NSWindowStyleMask.closable |
            NSWindowStyleMask.miniaturizable | NSWindowStyleMask.resizable;
        const frame: NSRect = .{ .x = 200, .y = 200, .w = opts.width, .h = opts.height };
        const window = msg(id, struct { NSRect, u64, u64, bool }, window_alloc, sel("initWithContentRect:styleMask:backing:defer:"), .{ frame, style, 2, false });
        if (window == null) return error.BackendFailure;

        _ = msg(void, struct { id }, window, sel("setTitle:"), .{nsString(opts.title)});
        _ = msg(void, struct { bool }, window, sel("setReleasedWhenClosed:"), .{false});
        _ = msg(void, struct { id }, window, sel("makeKeyAndOrderFront:"), .{null});
        _ = msg(void, struct { bool }, app, sel("activateIgnoringOtherApps:"), .{true});

        const self = try gpa.create(Window);
        self.* = .{ .ns_window = window, .gpa = gpa, .last_size = frame };
        return self;
    }

    pub fn destroy(self: *Window) void {
        _ = msg(void, struct {}, self.ns_window, sel("close"), .{});
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Drain pending AppKit events; non-blocking (#5 drivable loop).
    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        const distant_past = msg(id, struct {}, cls("NSDate"), sel("distantPast"), .{});
        const mode = nsString("kCFRunLoopDefaultMode");

        while (true) {
            const ev = msg(id, struct { u64, id, id, bool }, app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{ std.math.maxInt(u64), distant_past, mode, true });
            if (ev == null) break;
            _ = msg(void, struct { id }, app, sel("sendEvent:"), .{ev});
        }

        // Close: the red button orders the window out.
        const visible = msg(bool, struct {}, self.ns_window, sel("isVisible"), .{});
        if (visible) {
            self.was_visible = true;
        } else if (self.was_visible) {
            self.queue.append(self.gpa, .close_requested) catch {};
        }
        // Resize: poll the content frame.
        const content = msg(NSRect, struct {}, self.ns_window, sel("contentLayoutRect"), .{});
        if (content.w != self.last_size.w or content.h != self.last_size.h) {
            self.last_size = content;
            self.queue.append(self.gpa, .{ .resized = .{
                .width = @intFromFloat(@max(0, content.w)),
                .height = @intFromFloat(@max(0, content.h)),
            } }) catch {};
        }
        return self.queue.items;
    }
};

// --- raster blit (CoreGraphics) ---------------------------------------------
// Presents a CPU-rendered RGBA framebuffer in the window: the GUI path
// until GPU backends land (#11/#12) — same approach for first pixels.

const CGColorSpace = ?*anyopaque;
const CGDataProvider = ?*anyopaque;
const CGImage = ?*anyopaque;

extern "c" fn CGColorSpaceCreateDeviceRGB() CGColorSpace;
extern "c" fn CGColorSpaceRelease(CGColorSpace) void;
extern "c" fn CGDataProviderCreateWithData(?*anyopaque, ?*const anyopaque, usize, ?*const anyopaque) CGDataProvider;
extern "c" fn CGDataProviderRelease(CGDataProvider) void;
extern "c" fn CGImageCreate(usize, usize, usize, usize, usize, CGColorSpace, u32, CGDataProvider, ?*const anyopaque, bool, i32) CGImage;
extern "c" fn CGImageRelease(CGImage) void;

const kCGImageAlphaNoneSkipLast: u32 = 5; // RGBX, our raster layout

/// Present an RGBA8 framebuffer (row-major, top-down) in the window.
/// The buffer must stay valid for the duration of the call (the image
/// copies via the data provider before returning from setContents).
pub fn blit(window: *Window, rgba: []const u8, width: usize, height: usize) void {
    std.debug.assert(rgba.len == width * height * 4);
    const space = CGColorSpaceCreateDeviceRGB();
    defer CGColorSpaceRelease(space);
    const provider = CGDataProviderCreateWithData(null, rgba.ptr, rgba.len, null);
    defer CGDataProviderRelease(provider);
    const image = CGImageCreate(width, height, 8, 32, width * 4, space, kCGImageAlphaNoneSkipLast, provider, null, false, 0);
    defer CGImageRelease(image);

    const view = msg(id, struct {}, window.ns_window, sel("contentView"), .{});
    _ = msg(void, struct { bool }, view, sel("setWantsLayer:"), .{true});
    const layer = msg(id, struct {}, view, sel("layer"), .{});
    const scale = msg(f64, struct {}, window.ns_window, sel("backingScaleFactor"), .{});
    _ = msg(void, struct { f64 }, layer, sel("setContentsScale:"), .{scale});
    _ = msg(void, struct { id }, layer, sel("setContents:"), .{image});
}

/// Content size in pixels (points × backing scale) for rendering.
pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    const content = msg(NSRect, struct {}, window.ns_window, sel("contentLayoutRect"), .{});
    const scale = msg(f64, struct {}, window.ns_window, sel("backingScaleFactor"), .{});
    return .{
        .width = @intFromFloat(@max(1, content.w * scale)),
        .height = @intFromFloat(@max(1, content.h * scale)),
        .scale = scale,
    };
}

test "objc runtime reachable: NSString round-trip" {
    const s = nsString("zooee");
    try std.testing.expect(s != null);
    const len = msg(u64, struct {}, s, sel("length"), .{});
    try std.testing.expectEqual(@as(u64, 5), len);
}
