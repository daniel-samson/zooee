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
extern "objc" fn objc_allocateClassPair(Class, [*:0]const u8, usize) Class;
extern "objc" fn objc_registerClassPair(Class) void;
extern "objc" fn class_addMethod(Class, SEL, *const anyopaque, [*:0]const u8) bool;
extern "objc" fn object_getClass(id) Class;

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

fn msg(comptime Ret: type, comptime Args: type, target: anytype, selector: SEL, args: Args) Ret {
    const Fn = switch (@typeInfo(Args).@"struct".fields.len) {
        0 => *const fn (@TypeOf(target), SEL) callconv(.c) Ret,
        1 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type) callconv(.c) Ret,
        2 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type, @typeInfo(Args).@"struct".fields[1].type) callconv(.c) Ret,
        3 => *const fn (
            @TypeOf(target),
            SEL,
            @typeInfo(Args).@"struct".fields[0].type,
            @typeInfo(Args).@"struct".fields[1].type,
            @typeInfo(Args).@"struct".fields[2].type,
        ) callconv(.c) Ret,
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
        3 => f(target, selector, @field(args, "0"), @field(args, "1"), @field(args, "2")),
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

// --- clipboard (#19) --------------------------------------------------------

const clipboard_mod = @import("../clipboard.zig");

/// System clipboard backed by NSPasteboard (#19). Implements the core
/// `Clipboard` interface so apps copy/paste against the OS pasteboard. Live
/// interop with other apps needs an on-device check (no hosted GUI runner).
pub const SystemClipboard = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) SystemClipboard {
        return .{ .gpa = gpa };
    }

    pub fn interface(self: *SystemClipboard) clipboard_mod.Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: clipboard_mod.Clipboard.VTable = .{ .get_text = getText, .set_text = setText };
    const utf8_type = "public.utf8-plain-text";

    fn getText(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8 {
        _ = ptr;
        const pb = msg(id, struct {}, cls("NSPasteboard"), sel("generalPasteboard"), .{});
        const ns = msg(id, struct { id }, pb, sel("stringForType:"), .{nsString(utf8_type)});
        if (ns == null) return null;
        const c = msg([*:0]const u8, struct {}, ns, sel("UTF8String"), .{});
        return try gpa.dupe(u8, std.mem.span(c));
    }

    fn setText(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *SystemClipboard = @ptrCast(@alignCast(ptr));
        // NSString needs a null-terminated buffer; copy once.
        const z = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(z);
        const pb = msg(id, struct {}, cls("NSPasteboard"), sel("generalPasteboard"), .{});
        _ = msg(i64, struct {}, pb, sel("clearContents"), .{});
        const s = msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{z.ptr});
        _ = msg(bool, struct { id, id }, pb, sel("setString:forType:"), .{ s, nsString(utf8_type) });
    }
};

// --- events ----------------------------------------------------------------

const core_event = @import("../event.zig");
const cursor_mod = @import("../cursor.zig");
const window_mod = @import("../window.zig");
const menu_mod = @import("../menu.zig");
const style_mod = @import("../style.zig");

/// The user's system accent color (NSColor.controlAccentColor, macOS 10.14+),
/// converted to sRGB — so the app's theme can match the OS (#318). Null on
/// failure (older macOS).
pub fn systemAccent() ?style_mod.Color {
    const accent = msg(id, struct {}, cls("NSColor"), sel("controlAccentColor"), .{});
    if (accent == null) return null;
    const space = msg(id, struct {}, cls("NSColorSpace"), sel("sRGBColorSpace"), .{});
    const c = msg(id, struct { id }, accent, sel("colorUsingColorSpace:"), .{space}) orelse accent;
    var r: f64 = 0;
    var g: f64 = 0;
    var bl: f64 = 0;
    var a: f64 = 0;
    msg(void, struct { *f64, *f64, *f64, *f64 }, c, sel("getRed:green:blue:alpha:"), .{ &r, &g, &bl, &a });
    return style_mod.Color.rgb(
        @intFromFloat(std.math.clamp(r, 0, 1) * 255),
        @intFromFloat(std.math.clamp(g, 0, 1) * 255),
        @intFromFloat(std.math.clamp(bl, 0, 1) * 255),
    );
}

/// Whether the OS is in dark mode (NSApp.effectiveAppearance name contains
/// "Dark"). Lets an app default its theme to the system appearance (#318).
pub fn prefersDark() bool {
    const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
    const ap = msg(id, struct {}, app, sel("effectiveAppearance"), .{});
    if (ap == null) return false;
    const name = msg(id, struct {}, ap, sel("name"), .{});
    if (name == null) return false;
    const utf8 = msg([*:0]const u8, struct {}, name, sel("UTF8String"), .{});
    return std.mem.indexOf(u8, std.mem.span(utf8), "Dark") != null;
}
/// Native windows emit the same core events as the terminal session, so
/// one app loop drives every surface (#5).
pub const Event = core_event.Event;

const NSPoint = extern struct { x: f64, y: f64 };

const NSEventType = struct {
    const left_down: u64 = 1;
    const left_up: u64 = 2;
    const right_down: u64 = 3;
    const right_up: u64 = 4;
    const mouse_moved: u64 = 5;
    const left_dragged: u64 = 6;
    const right_dragged: u64 = 7;
    const key_down: u64 = 10;
    const key_up: u64 = 11;
    const scroll_wheel: u64 = 22;
};

/// NSEvent.modifierFlags bitmask → our Modifiers (#127). The device-independent
/// flags live in the high bits: shift 1<<17, ctrl 1<<18, alt 1<<19, cmd 1<<20.
fn modsFromFlags(flags: u64) core_event.Modifiers {
    return .{
        .shift = (flags & (1 << 17)) != 0,
        .ctrl = (flags & (1 << 18)) != 0,
        .alt = (flags & (1 << 19)) != 0,
        .super = (flags & (1 << 20)) != 0,
    };
}

fn keyCodeToKey(kc: u16) ?core_event.Key {
    return switch (kc) {
        126 => .up,
        125 => .down,
        123 => .left,
        124 => .right,
        115 => .home,
        119 => .end,
        116 => .page_up,
        121 => .page_down,
        36 => .enter,
        53 => .escape,
        48 => .tab,
        51 => .backspace,
        117 => .delete,
        else => null,
    };
}

// --- live-resize delegate ---------------------------------------------------
// AppKit runs a modal tracking loop while the user drags the resize edge, so
// our pumpEvents-driven loop is parked and the GL surface stretches the stale
// frame. A tiny NSWindowDelegate whose windowDidResize: fires *inside* that
// loop gives us the hook to redraw live. Single-window (the demo) for now.

var live_resize_window: ?*Window = null;
var delegate_instance: id = null;

// --- drag-and-drop destination (#212) ---------------------------------------
// Single-window: the dragging IMPs enqueue onto this Window. The destination
// methods are added once to the contentView's class; registerForDraggedTypes:
// activates them only on our registered view.
var drag_window: ?*Window = null;
var drag_methods_added = false;

const NSDragOperationCopy: u64 = 1;
const ns_filenames_type = "NSFilenamesPboardType";

/// IMP for `draggingEntered:`/`draggingUpdated:` — accept as a copy.
fn onDraggingEntered(_: id, _: SEL, _: id) callconv(.c) u64 {
    return NSDragOperationCopy;
}

/// IMP for `performDragOperation:` — read the dropped file paths off the drag
/// pasteboard and enqueue a core `.drop` event.
fn onPerformDrag(_: id, _: SEL, sender: id) callconv(.c) bool {
    const w = drag_window orelse return false;
    const pb = msg(id, struct {}, sender, sel("draggingPasteboard"), .{});
    const list = msg(id, struct { id }, pb, sel("propertyListForType:"), .{nsString(ns_filenames_type)});
    if (list == null) return false;
    const count = msg(u64, struct {}, list, sel("count"), .{});
    const a = w.drop_arena.allocator();
    const paths = a.alloc([]const u8, count) catch return false;
    var n: usize = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const s = msg(id, struct { u64 }, list, sel("objectAtIndex:"), .{i});
        const c = msg([*:0]const u8, struct {}, s, sel("UTF8String"), .{});
        paths[n] = a.dupe(u8, std.mem.span(c)) catch continue;
        n += 1;
    }
    const loc = msg(NSPoint, struct {}, sender, sel("draggingLocation"), .{});
    w.queue.append(w.gpa, .{ .drop = .{
        .position = .{ .x = @floatCast(loc.x), .y = @floatCast(loc.y) },
        .data = .{ .files = paths[0..n] },
        .operation = .copy,
    } }) catch {};
    return true;
}

// --- drag-and-drop source (#128) ---------------------------------------------
// Start an OS drag *out* of the window. The triggering NSEvent comes from
// [NSApp currentEvent], so the app can call beginDragText from a pointer-drag
// handler without us threading the live event through the decoupled loop.
var drag_source_instance: id = null;

/// IMP for `draggingSession:sourceOperationMaskForDraggingContext:` — allow
/// copy in any context (within-app and to other apps).
fn onDragSourceMask(_: id, _: SEL, _: id, _: i64) callconv(.c) u64 {
    return NSDragOperationCopy;
}

/// A shared NSDraggingSource whose op-mask method permits copy. Registered once.
fn dragSource() id {
    if (drag_source_instance) |s| return s;
    const c = objc_allocateClassPair(cls("NSObject"), "ZooeeDragSource", 0);
    _ = class_addMethod(c, sel("draggingSession:sourceOperationMaskForDraggingContext:"), @ptrCast(&onDragSourceMask), "Q@:@q");
    objc_registerClassPair(c);
    drag_source_instance = msg(id, struct {}, msg(id, struct {}, c, sel("alloc"), .{}), sel("init"), .{});
    return drag_source_instance;
}

/// Register the drag-destination methods on the contentView's class (once) and
/// accept filename drops on `view`.
fn enableDrop(view: id, w: *Window) void {
    drag_window = w;
    if (!drag_methods_added) {
        const c = object_getClass(view);
        _ = class_addMethod(c, sel("draggingEntered:"), @ptrCast(&onDraggingEntered), "Q@:@");
        _ = class_addMethod(c, sel("draggingUpdated:"), @ptrCast(&onDraggingEntered), "Q@:@");
        _ = class_addMethod(c, sel("performDragOperation:"), @ptrCast(&onPerformDrag), "c@:@");
        drag_methods_added = true;
    }
    const arr = msg(id, struct { id }, cls("NSArray"), sel("arrayWithObject:"), .{nsString(ns_filenames_type)});
    _ = msg(void, struct { id }, view, sel("registerForDraggedTypes:"), .{arr});
}

fn resizeDelegate() id {
    if (delegate_instance) |d| return d;
    const class = objc_allocateClassPair(cls("NSObject"), "ZooeeWindowDelegate", 0);
    _ = class_addMethod(class, sel("windowDidResize:"), @ptrCast(&onWindowDidResize), "v@:@");
    // windowDidEndLiveResize: guarantees one final redraw at the settled size
    // even if the last windowDidResize: raced the drag's end.
    _ = class_addMethod(class, sel("windowDidEndLiveResize:"), @ptrCast(&onWindowDidResize), "v@:@");
    // OS theme-change notifications (#318): accent + light/dark, so a live app
    // re-themes when the user changes them in System Settings.
    _ = class_addMethod(class, sel("zooeeThemeChanged:"), @ptrCast(&onThemeChanged), "v@:@");
    objc_registerClassPair(class);
    const inst = msg(id, struct {}, msg(id, struct {}, class, sel("alloc"), .{}), sel("init"), .{});
    delegate_instance = inst;
    // Accent + appearance changes post on the *distributed* center; system color
    // changes on the regular one. We re-read all OS colors on any of them.
    const dnc = msg(id, struct {}, cls("NSDistributedNotificationCenter"), sel("defaultCenter"), .{});
    inline for (.{ "AppleColorPreferencesChangedNotification", "AppleInterfaceThemeChangedNotification" }) |nm| {
        _ = msg(void, struct { id, SEL, id, id }, dnc, sel("addObserver:selector:name:object:"), .{ inst, sel("zooeeThemeChanged:"), nsString(nm), null });
    }
    const nc = msg(id, struct {}, cls("NSNotificationCenter"), sel("defaultCenter"), .{});
    _ = msg(void, struct { id, SEL, id, id }, nc, sel("addObserver:selector:name:object:"), .{ inst, sel("zooeeThemeChanged:"), nsString("NSSystemColorsDidChangeNotification"), null });
    return inst;
}

/// IMP for `windowDidResize:` — redraw the live window during the modal drag.
fn onWindowDidResize(_: id, _: SEL, _: id) callconv(.c) void {
    if (live_resize_window) |w| {
        w.applyTrafficLights(); // AppKit may relayout the titlebar on resize
        if (w.redraw_fn) |f| f(w.redraw_ctx);
    }
}

/// OS accent / appearance changed → flag it (the present loop polls
/// takeAppearanceChanged each frame) and nudge a repaint (#318).
var theme_changed: bool = false;
fn onThemeChanged(_: id, _: SEL, _: id) callconv(.c) void {
    theme_changed = true;
    if (live_resize_window) |w| if (w.redraw_fn) |f| f(w.redraw_ctx);
}

/// Consume the "OS theme changed" flag — the app repaints so its theme()
/// hook re-reads systemAccent()/prefersDark() (#318). `gpa`/`io` are part of the
/// cross-platform signature (Linux polls gsettings with them); unused here.
pub fn takeAppearanceChanged(gpa: std.mem.Allocator, io: std.Io) bool {
    _ = gpa;
    _ = io;
    defer theme_changed = false;
    return theme_changed;
}

// --- IME / text input (#213) ------------------------------------------------
// Bridge AppKit's NSTextInputClient to our pull-based loop: keyDown events are
// routed through the view's inputContext (in pumpEvents), which calls these
// IMPs added to the content view's class. insertText: → committed .text;
// setMarkedText: → .composition pre-edit. Single-window via `ime_window`.

const NSRange = extern struct { location: u64, length: u64 };
const ns_not_found: u64 = 0x7FFFFFFFFFFFFFFF; // NSNotFound

var ime_window: ?*Window = null;
var ime_methods_added = false;
var ime_has_marked = false;

/// Get an NSString from an insertText:/setMarkedText: arg (NSString or
/// NSAttributedString) and emit its codepoints / pre-edit.
fn imeStringPtr(s: id) ?[*:0]const u8 {
    if (s == null) return null;
    const str = if (msg(bool, struct { SEL }, s, sel("respondsToSelector:"), .{sel("string")}))
        msg(id, struct {}, s, sel("string"), .{})
    else
        s;
    if (str == null) return null;
    return msg([*:0]const u8, struct {}, str, sel("UTF8String"), .{});
}

fn onInsertText(_: id, _: SEL, s: id, _: NSRange) callconv(.c) void {
    ime_has_marked = false;
    const w = ime_window orelse return;
    const utf8 = imeStringPtr(s) orelse return;
    var it = std.unicode.Utf8View.initUnchecked(std.mem.span(utf8)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x20 and cp != 0x7f) w.queue.append(w.gpa, .{ .text = .{ .codepoint = cp } }) catch {};
    }
}

fn onSetMarkedText(_: id, _: SEL, s: id, _: NSRange, _: NSRange) callconv(.c) void {
    const w = ime_window orelse return;
    const utf8 = imeStringPtr(s) orelse return;
    const text = std.mem.span(utf8);
    ime_has_marked = text.len > 0;
    const a = w.drop_arena.allocator();
    const copy = a.dupe(u8, text) catch return;
    w.queue.append(w.gpa, .{ .composition = .{ .phase = if (text.len == 0) .cancel else .update, .text = copy, .caret = copy.len } }) catch {};
}

fn onUnmarkText(_: id, _: SEL) callconv(.c) void {
    ime_has_marked = false;
}
fn onHasMarkedText(_: id, _: SEL) callconv(.c) bool {
    return ime_has_marked;
}
fn onMarkedRange(_: id, _: SEL) callconv(.c) NSRange {
    return if (ime_has_marked) .{ .location = 0, .length = 0 } else .{ .location = ns_not_found, .length = 0 };
}
fn onSelectedRange(_: id, _: SEL) callconv(.c) NSRange {
    return .{ .location = 0, .length = 0 };
}
fn onValidAttributes(_: id, _: SEL) callconv(.c) id {
    return msg(id, struct {}, cls("NSArray"), sel("array"), .{});
}
fn onAttributedSubstring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) id {
    return null;
}
fn onFirstRect(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) NSRect {
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
fn onCharIndexForPoint(_: id, _: SEL, _: NSPoint) callconv(.c) u64 {
    return ns_not_found;
}
fn onDoCommand(_: id, _: SEL, _: SEL) callconv(.c) void {}
fn onAcceptsFirstResponder(_: id, _: SEL) callconv(.c) bool {
    return true;
}

/// Add NSTextInputClient (+ acceptsFirstResponder) to the content view's class
/// once, route `w` as the IME target, and make the view first responder so its
/// inputContext is live.
fn enableTextInput(window: id, view: id, w: *Window) void {
    ime_window = w;
    if (!ime_methods_added) {
        const c = object_getClass(view);
        _ = class_addMethod(c, sel("acceptsFirstResponder"), @ptrCast(&onAcceptsFirstResponder), "c@:");
        _ = class_addMethod(c, sel("insertText:replacementRange:"), @ptrCast(&onInsertText), "v@:@{_NSRange=QQ}");
        _ = class_addMethod(c, sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(&onSetMarkedText), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
        _ = class_addMethod(c, sel("unmarkText"), @ptrCast(&onUnmarkText), "v@:");
        _ = class_addMethod(c, sel("hasMarkedText"), @ptrCast(&onHasMarkedText), "c@:");
        _ = class_addMethod(c, sel("markedRange"), @ptrCast(&onMarkedRange), "{_NSRange=QQ}@:");
        _ = class_addMethod(c, sel("selectedRange"), @ptrCast(&onSelectedRange), "{_NSRange=QQ}@:");
        _ = class_addMethod(c, sel("validAttributesForMarkedText"), @ptrCast(&onValidAttributes), "@@:");
        _ = class_addMethod(c, sel("attributedSubstringForProposedRange:actualRange:"), @ptrCast(&onAttributedSubstring), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
        _ = class_addMethod(c, sel("firstRectForCharacterRange:actualRange:"), @ptrCast(&onFirstRect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
        _ = class_addMethod(c, sel("characterIndexForPoint:"), @ptrCast(&onCharIndexForPoint), "Q@:{CGPoint=dd}");
        _ = class_addMethod(c, sel("doCommandBySelector:"), @ptrCast(&onDoCommand), "v@::");
        ime_methods_added = true;
    }
    _ = msg(bool, struct { id }, window, sel("makeFirstResponder:"), .{view});
}

// --- native context menu (#129) ----------------------------------------------

/// Set by the menu item action to the chosen item's tag (== model id) while a
/// popup is up; read synchronously after popUpMenuPositioningItem returns. The
/// popup runs a nested modal loop, so a single global is safe (one at a time).
var menu_selected_id: u32 = 0;
var menu_target: id = null;

/// NSMenuItem action target: stash the sender's tag (the model id).
fn onMenuAction(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag = msg(isize, struct {}, sender, sel("tag"), .{});
    menu_selected_id = if (tag > 0) @intCast(tag) else 0;
}

/// A shared target instance whose `zooeeMenuAction:` records the selection.
/// The class is registered once; the instance lives for the process.
fn menuTarget() id {
    if (menu_target) |t| return t;
    const c = objc_allocateClassPair(cls("NSObject"), "ZooeeMenuTarget", 0);
    _ = class_addMethod(c, sel("zooeeMenuAction:"), @ptrCast(&onMenuAction), "v@:@");
    objc_registerClassPair(c);
    menu_target = msg(id, struct {}, msg(id, struct {}, c, sel("alloc"), .{}), sel("init"), .{});
    return menu_target;
}

/// Build an autoreleased NSMenu from the model, recursing into submenus.
fn buildMenu(items: []const menu_mod.Item) id {
    const m = msg(id, struct {}, msg(id, struct {}, cls("NSMenu"), sel("alloc"), .{}), sel("init"), .{});
    // Honor our enabled flags instead of AppKit's automatic enabling.
    _ = msg(void, struct { bool }, m, sel("setAutoenablesItems:"), .{false});
    const target = menuTarget();
    const empty = nsString("");
    for (items) |it| {
        if (it.separator) {
            const sep = msg(id, struct {}, cls("NSMenuItem"), sel("separatorItem"), .{});
            _ = msg(void, struct { id }, m, sel("addItem:"), .{sep});
            continue;
        }
        const alloc_item = msg(id, struct {}, cls("NSMenuItem"), sel("alloc"), .{});
        const action: SEL = if (it.submenu.len > 0) null else sel("zooeeMenuAction:");
        const item = msg(id, struct { id, SEL, id }, alloc_item, sel("initWithTitle:action:keyEquivalent:"), .{ nsString(it.label), action, empty });
        if (it.submenu.len > 0) {
            _ = msg(void, struct { id }, item, sel("setSubmenu:"), .{buildMenu(it.submenu)});
        } else {
            _ = msg(void, struct { id }, item, sel("setTarget:"), .{target});
            _ = msg(void, struct { isize }, item, sel("setTag:"), .{@as(isize, @intCast(it.id))});
            _ = msg(void, struct { bool }, item, sel("setEnabled:"), .{it.enabled});
            if (it.checked) _ = msg(void, struct { isize }, item, sel("setState:"), .{1}); // NSControlStateValueOn
        }
        _ = msg(void, struct { id }, m, sel("addItem:"), .{item});
    }
    return m;
}

// --- window ----------------------------------------------------------------

const NSWindowStyleMask = struct {
    const titled: u64 = 1 << 0;
    const closable: u64 = 1 << 1;
    const miniaturizable: u64 = 1 << 2;
    const resizable: u64 = 1 << 3;
    const full_size_content_view: u64 = 1 << 15; // #64
};

pub const Window = struct {
    /// Native OS menus are available (NSMenu): the framework uses them rather
    /// than the in-window overlay (#319).
    pub const native_menus = true;

    ns_window: id,
    gpa: std.mem.Allocator,
    queue: std.ArrayList(Event) = .empty,
    last_size: NSRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Close = "was visible, now isn't" — visibility lags app launch, so
    /// a not-yet-visible window must not read as closed.
    was_visible: bool = false,
    /// NSOpenGLContext when the window is GPU-backed (#11 present path);
    /// null = CPU raster + CoreGraphics blit. Named gl_ctx to match the
    /// x11 window so runWindow's GL branch is platform-agnostic.
    gl_ctx: id = null,
    /// Render-one-frame callback (set by runWindow). AppKit's modal resize
    /// loop parks our event loop mid-drag, so without this the surface just
    /// stretches the last frame until release. The `windowDidResize:`
    /// delegate calls this to redraw live. See [[fix-live-resize]].
    redraw_ctx: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    /// Scratch for drop payloads (#212): dropped paths live here until the next
    /// pumpEvents resets it (DragData is "valid only during dispatch").
    drop_arena: std.heap.ArenaAllocator,
    /// Optional traffic-light reposition. `tl_defaults` caches the OS default
    /// button origins (captured on first apply) so re-applies after a resize are
    /// absolute and never drift.
    traffic_lights: ?window_mod.TrafficLights = null,
    tl_defaults: [3]NSPoint = undefined,
    tl_have_defaults: bool = false,

    pub const CreateOptions = struct {
        title: [:0]const u8 = "zooee",
        width: u32 = 800,
        height: u32 = 600,
        /// Try to create an NSOpenGLContext on the window (GPU-present).
        /// Falls back to raster + CoreGraphics if context creation fails.
        gl: bool = false,
        /// Title-bar presentation (#64).
        titlebar: window_mod.TitlebarMode = .native,
        /// Optional traffic-light reposition (close/minimise/zoom).
        traffic_lights: ?window_mod.TrafficLights = null,
    };

    /// Register the redraw callback and mark this as the window whose
    /// `windowDidResize:` should drive it. Single-window today (the demo);
    /// multi-window would store the Window* on the delegate via an ivar.
    pub fn setRedraw(self: *Window, ctx: ?*anyopaque, f: *const fn (?*anyopaque) void) void {
        self.redraw_ctx = ctx;
        self.redraw_fn = f;
        live_resize_window = self;
    }

    pub fn create(gpa: std.mem.Allocator, opts: CreateOptions) !*Window {
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        // NSApplicationActivationPolicyRegular = 0: Dock icon + key window
        // even for a bare binary (the .app bundle makes it look right).
        _ = msg(bool, struct { i64 }, app, sel("setActivationPolicy:"), .{0});
        // Required when launched via LaunchServices (.app double-click /
        // `open`): without it the window never becomes visible.
        _ = msg(void, struct {}, app, sel("finishLaunching"), .{});

        const window_alloc = msg(id, struct {}, cls("NSWindow"), sel("alloc"), .{});
        var style = NSWindowStyleMask.titled | NSWindowStyleMask.closable |
            NSWindowStyleMask.miniaturizable | NSWindowStyleMask.resizable;
        // Integrated/headless title bars (#64): let the content view extend under
        // the title bar. The bar stays present-but-transparent so the traffic
        // lights + system window-drag keep working while the app draws the strip.
        if (opts.titlebar != .native) style |= NSWindowStyleMask.full_size_content_view;
        const frame: NSRect = .{ .x = 200, .y = 200, .w = @floatFromInt(opts.width), .h = @floatFromInt(opts.height) };
        const window = msg(id, struct { NSRect, u64, u64, bool }, window_alloc, sel("initWithContentRect:styleMask:backing:defer:"), .{ frame, style, 2, false });
        if (window == null) return error.BackendFailure;

        _ = msg(void, struct { id }, window, sel("setTitle:"), .{nsString(opts.title)});
        if (opts.titlebar != .native) {
            // Transparent bar + hidden title → the app's content shows through
            // the title-bar strip (#64). NSWindowTitleHidden = 1.
            _ = msg(void, struct { bool }, window, sel("setTitlebarAppearsTransparent:"), .{true});
            _ = msg(void, struct { i64 }, window, sel("setTitleVisibility:"), .{1});
        }
        _ = msg(void, struct { bool }, window, sel("setReleasedWhenClosed:"), .{false});
        _ = msg(void, struct { bool }, window, sel("setAcceptsMouseMovedEvents:"), .{true});
        // Don't let AppKit cache-and-stretch the old frame during a live
        // resize drag — rely on our windowDidResize: redraw instead, so the
        // content snaps to each size rather than morphing toward it.
        _ = msg(void, struct { bool }, window, sel("setPreservesContentDuringLiveResize:"), .{false});
        _ = msg(void, struct { id }, window, sel("makeKeyAndOrderFront:"), .{null});
        _ = msg(void, struct { bool }, app, sel("activateIgnoringOtherApps:"), .{true});

        // A minimal NSWindowDelegate so `windowDidResize:` fires during
        // AppKit's modal resize tracking loop — the one chance to redraw
        // while the user is dragging (else the GL surface stretches).
        _ = msg(void, struct { id }, window, sel("setDelegate:"), .{resizeDelegate()});

        // Optional GPU context on the contentView (#11). Legacy 2.1 profile
        // (no NSOpenGLPFAOpenGLProfile attr) → GLSL 120, matching the shaders.
        var gl_ctx: id = null;
        if (opts.gl) gl_ctx = createGlContext(window);

        const self = try gpa.create(Window);
        self.* = .{ .ns_window = window, .gpa = gpa, .last_size = frame, .gl_ctx = gl_ctx, .drop_arena = std.heap.ArenaAllocator.init(gpa) };
        // Accept file drops (#212) + IME text input (#213) on the content view.
        const cv = msg(id, struct {}, window, sel("contentView"), .{});
        enableDrop(cv, self);
        enableTextInput(window, cv, self);
        self.traffic_lights = opts.traffic_lights;
        self.applyTrafficLights();
        return self;
    }

    /// Offset the traffic-light cluster per `self.traffic_lights`. The OS default
    /// origins are cached on first call so later re-applies (after a resize, when
    /// AppKit may relayout the titlebar) are absolute — they don't accumulate.
    /// No-op when unset or zero, so the default placement is untouched.
    fn applyTrafficLights(self: *Window) void {
        const tl = self.traffic_lights orelse return;
        if (tl.x == 0 and tl.y == 0) return;
        // NSWindowButton: 0 = close, 1 = miniaturize, 2 = zoom.
        for ([_]u64{ 0, 1, 2 }, 0..) |button, i| {
            const btn = msg(id, struct { u64 }, self.ns_window, sel("standardWindowButton:"), .{button});
            if (btn == null) continue;
            if (!self.tl_have_defaults) {
                const f = msg(NSRect, struct {}, btn, sel("frame"), .{});
                self.tl_defaults[i] = .{ .x = f.x, .y = f.y };
            }
            const d = self.tl_defaults[i];
            // View coords are y-up, so a positive `y` offset moves the cluster down.
            const origin: NSPoint = .{ .x = d.x + tl.x, .y = d.y - tl.y };
            _ = msg(void, struct { NSPoint }, btn, sel("setFrameOrigin:"), .{origin});
        }
        self.tl_have_defaults = true;
    }

    pub fn destroy(self: *Window) void {
        if (self.gl_ctx != null) {
            _ = msg(void, struct {}, self.gl_ctx, sel("clearDrawable"), .{});
        }
        _ = msg(void, struct {}, self.ns_window, sel("close"), .{});
        if (drag_window == self) drag_window = null;
        if (ime_window == self) ime_window = null;
        self.queue.deinit(self.gpa);
        self.drop_arena.deinit();
        self.gpa.destroy(self);
    }

    // --- Programmatic window operations (#98) -----------------------------
    // The app can drive its own window, not just respond to the title-bar
    // controls. macOS impls; Win32/X11 mirror these (on-device).

    /// Resize the content area to `w`×`h` points (top-left preserved).
    pub fn setSize(self: *Window, w: f32, h: f32) void {
        const frame = msg(NSRect, struct {}, self.ns_window, sel("frame"), .{});
        // setFrame uses the window frame (incl. titlebar); keep the top edge
        // fixed by adjusting y so the window doesn't appear to jump up.
        const new: NSRect = .{ .x = frame.x, .y = frame.y + (frame.h - h), .w = w, .h = h };
        _ = msg(void, struct { NSRect, bool }, self.ns_window, sel("setFrame:display:"), .{ new, true });
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = msg(void, struct { id }, self.ns_window, sel("setTitle:"), .{nsString(title)});
    }

    /// Pop up `items` as a native NSMenu context menu at client-area pixel
    /// point (x, y) — top-down pixels, matching zooee's event coordinates — and
    /// block until the user chooses or dismisses (#129). Returns the chosen item
    /// id, or null on dismiss.
    pub fn popupMenu(self: *Window, items: []const menu_mod.Item, x: f32, y: f32) ?u32 {
        menu_selected_id = 0;
        const m = buildMenu(items);
        const view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});
        // Event coords are device pixels; AppKit view coords are points and
        // bottom-up. Convert px→points (÷ backing scale) then flip y.
        const scale = msg(f64, struct {}, self.ns_window, sel("backingScaleFactor"), .{});
        const bounds = msg(NSRect, struct {}, view, sel("bounds"), .{});
        const loc: NSPoint = .{ .x = @as(f64, x) / scale, .y = bounds.h - @as(f64, y) / scale };
        _ = msg(bool, struct { id, NSPoint, id }, m, sel("popUpMenuPositioningItem:atLocation:inView:"), .{ null, loc, view });
        const r = menu_selected_id;
        menu_selected_id = 0; // clear so a later takeMenuCommand() isn't fooled
        return if (r == 0) null else r;
    }

    /// Begin an OS drag-and-drop *source* session carrying `text` (#128). Call
    /// from a pointer-drag handler; uses the current NSEvent as the trigger and
    /// a generic drag image. Returns false if there's no current event (not in a
    /// drag gesture). The OS drives the rest; drops into other apps paste text.
    pub fn beginDragText(self: *Window, text: [:0]const u8) bool {
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        const event = msg(id, struct {}, app, sel("currentEvent"), .{});
        if (event == null) return false;
        const view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});

        const pbitem = msg(id, struct {}, msg(id, struct {}, cls("NSPasteboardItem"), sel("alloc"), .{}), sel("init"), .{});
        _ = msg(bool, struct { id, id }, pbitem, sel("setString:forType:"), .{ nsString(text), nsString("public.utf8-plain-text") });

        const ditem = msg(id, struct { id }, msg(id, struct {}, cls("NSDraggingItem"), sel("alloc"), .{}), sel("initWithPasteboardWriter:"), .{pbitem});
        const img = msg(id, struct { id }, cls("NSImage"), sel("imageNamed:"), .{nsString("NSMultipleDocuments")});
        const loc = msg(NSPoint, struct {}, event, sel("locationInWindow"), .{});
        const frame: NSRect = .{ .x = loc.x - 16, .y = loc.y - 16, .w = 32, .h = 32 };
        _ = msg(void, struct { NSRect, id }, ditem, sel("setDraggingFrame:contents:"), .{ frame, img });

        const arr = msg(id, struct { id }, cls("NSArray"), sel("arrayWithObject:"), .{ditem});
        const sess = msg(id, struct { id, id, id }, view, sel("beginDraggingSessionWithItems:event:source:"), .{ arr, event, dragSource() });
        return sess != null;
    }

    /// Install `items` as the application menu bar (#129). Each top-level item
    /// should carry a submenu (File, Edit, …); macOS shows the first as the app
    /// menu. Chosen items are reported via `takeMenuCommand`.
    pub fn setMenuBar(self: *Window, items: []const menu_mod.Item) void {
        _ = self;
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        _ = msg(void, struct { id }, app, sel("setMainMenu:"), .{buildMenu(items)});
    }

    /// Drain the most recent menu-bar selection (#129): returns the chosen
    /// item id once, then null until the next selection. Poll each frame.
    pub fn takeMenuCommand(self: *Window) ?u32 {
        _ = self;
        const r = menu_selected_id;
        menu_selected_id = 0;
        return if (r == 0) null else r;
    }

    pub fn minimise(self: *Window) void {
        _ = msg(void, struct { id }, self.ns_window, sel("miniaturize:"), .{null});
    }

    pub fn restore(self: *Window) void {
        if (self.isMinimised()) {
            _ = msg(void, struct { id }, self.ns_window, sel("deminiaturize:"), .{null});
        } else if (self.isMaximised()) {
            _ = msg(void, struct { id }, self.ns_window, sel("zoom:"), .{null}); // zoom toggles
        }
    }

    /// Toggle the standard "zoom" (maximise) state.
    pub fn maximise(self: *Window) void {
        if (!self.isMaximised()) _ = msg(void, struct { id }, self.ns_window, sel("zoom:"), .{null});
    }

    pub fn close(self: *Window) void {
        _ = msg(void, struct { id }, self.ns_window, sel("performClose:"), .{null});
    }

    pub fn isMinimised(self: *Window) bool {
        return msg(bool, struct {}, self.ns_window, sel("isMiniaturized"), .{});
    }

    pub fn isMaximised(self: *Window) bool {
        return msg(bool, struct {}, self.ns_window, sel("isZoomed"), .{});
    }

    /// True while the user is dragging a resize edge (#170/#181): the present
    /// loop uses a transaction-synced present then, async (vsync-paced) otherwise.
    pub fn inLiveResize(self: *Window) bool {
        const view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});
        return msg(bool, struct {}, view, sel("inLiveResize"), .{});
    }

    /// Apply a pointer cursor shape (#123). Maps to the matching `NSCursor`
    /// class cursor and sends `set`. Shapes without a public AppKit cursor
    /// (the diagonal resizes, `wait`) fall back to the closest available one.
    pub fn setCursor(self: *Window, shape: cursor_mod.Cursor) void {
        _ = self;
        const ns = cls("NSCursor");
        const getter: SEL = switch (shape) {
            .default => sel("arrowCursor"),
            .pointer => sel("pointingHandCursor"),
            .text => sel("IBeamCursor"),
            .crosshair => sel("crosshairCursor"),
            .not_allowed => sel("operationNotAllowedCursor"),
            .grab => sel("openHandCursor"),
            .grabbing => sel("closedHandCursor"),
            .ew_resize => sel("resizeLeftRightCursor"),
            .ns_resize => sel("resizeUpDownCursor"),
            // AppKit has no public diagonal-resize or busy cursor; arrow is the
            // documented fallback.
            .nwse_resize, .nesw_resize, .wait => sel("arrowCursor"),
        };
        const cursor_obj = msg(id, struct {}, ns, getter, .{});
        _ = msg(void, struct {}, cursor_obj, sel("set"), .{});
    }

    /// The window's content NSView (id) — where the Metal layer (#101) or GL
    /// context attaches.
    pub fn contentView(self: *Window) ?*anyopaque {
        return msg(id, struct {}, self.ns_window, sel("contentView"), .{});
    }

    /// Present the GL back buffer (GPU-present path). No-op for raster windows.
    pub fn glSwap(self: *Window) void {
        if (self.gl_ctx != null) _ = msg(void, struct {}, self.gl_ctx, sel("flushBuffer"), .{});
    }

    /// Resync the NSOpenGLContext with its view's current size. An
    /// NSOpenGLContext caches its drawable dimensions; without `-update`
    /// after the view resizes, the back buffer stays the old size and the
    /// frame is stretched (and on fullscreen the content lands off-screen).
    /// Cheap and idempotent — call once per frame before rendering. No-op
    /// for raster windows. (GLX tracks the X drawable, so x11 needs none.)
    pub fn glUpdate(self: *Window) void {
        if (self.gl_ctx != null) _ = msg(void, struct {}, self.gl_ctx, sel("update"), .{});
    }

    /// Drain pending AppKit events; non-blocking (#5 drivable loop).
    pub fn pumpEvents(self: *Window) []const Event {
        self.queue.clearRetainingCapacity();
        _ = self.drop_arena.reset(.retain_capacity); // free last frame's drop paths (#212)
        // Drain the NSEvents (and other autoreleased objc objects) this pump
        // creates, every call — otherwise a continuously-redrawing app leaks
        // them each frame and eventually crashes. The returned queue holds our
        // own copied Event structs, so draining here is safe.
        const pool = msg(id, struct {}, msg(id, struct {}, cls("NSAutoreleasePool"), sel("alloc"), .{}), sel("init"), .{});
        defer _ = msg(void, struct {}, pool, sel("drain"), .{});
        const app = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
        const distant_past = msg(id, struct {}, cls("NSDate"), sel("distantPast"), .{});
        const mode = nsString("kCFRunLoopDefaultMode");

        const view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});
        const bounds = msg(NSRect, struct {}, view, sel("bounds"), .{});
        const scale = msg(f64, struct {}, self.ns_window, sel("backingScaleFactor"), .{});

        while (true) {
            const ev = msg(id, struct { u64, id, id, bool }, app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{ std.math.maxInt(u64), distant_past, mode, true });
            if (ev == null) break;
            const et = msg(u64, struct {}, ev, sel("type"), .{});

            switch (et) {
                NSEventType.left_down, NSEventType.left_up, NSEventType.right_down, NSEventType.right_up, NSEventType.mouse_moved, NSEventType.left_dragged, NSEventType.right_dragged => {
                    const loc = msg(NSPoint, struct {}, ev, sel("locationInWindow"), .{});
                    // Window coords (y-up, bottom-left) → content-view →
                    // top-left pixels matching the rendered framebuffer.
                    const cv = msg(NSPoint, struct { NSPoint, id }, view, sel("convertPoint:fromView:"), .{ loc, null });
                    const flags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    const is_down = et == NSEventType.left_down or et == NSEventType.right_down;
                    const cc: u8 = if (is_down) @intCast(@max(1, msg(i64, struct {}, ev, sel("clickCount"), .{}))) else 1;
                    const pos: core_event.PointerEvent = .{ .position = .{
                        .x = @floatCast(cv.x * scale),
                        .y = @floatCast((bounds.h - cv.y) * scale),
                    }, .buttons = .{
                        .primary = et == NSEventType.left_down or et == NSEventType.left_dragged,
                        .secondary = et == NSEventType.right_down or et == NSEventType.right_dragged,
                    }, .mods = modsFromFlags(flags), .click_count = cc };
                    const core_ev: Event = switch (et) {
                        NSEventType.left_down, NSEventType.right_down => .{ .pointer_down = pos },
                        NSEventType.left_up, NSEventType.right_up => .{ .pointer_up = pos },
                        else => .{ .pointer_move = pos },
                    };
                    self.queue.append(self.gpa, core_ev) catch {};
                },
                NSEventType.key_down => {
                    const kc = msg(u16, struct {}, ev, sel("keyCode"), .{});
                    if (keyCodeToKey(kc)) |k| {
                        const kflags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                        self.queue.append(self.gpa, .{ .key_down = .{ .key = k, .mods = modsFromFlags(kflags) } }) catch {};
                    } else {
                        const kflags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                        const kmods = modsFromFlags(kflags);
                        if (kmods.super or kmods.ctrl) {
                            // Command/Ctrl shortcut (e.g. ⌘C/⌘A): deliver the base
                            // letter as a .text event WITH mods so the app can act
                            // on the shortcut. Skip IME — combos aren't composition.
                            const base = msg(id, struct {}, ev, sel("charactersIgnoringModifiers"), .{});
                            if (base != null) {
                                const u8s = msg([*:0]const u8, struct {}, base, sel("UTF8String"), .{});
                                var it2 = std.unicode.Utf8View.initUnchecked(std.mem.span(u8s)).iterator();
                                while (it2.nextCodepoint()) |cp| {
                                    self.queue.append(self.gpa, .{ .text = .{ .codepoint = cp, .mods = kmods } }) catch {};
                                }
                            }
                            continue;
                        }
                        // Route through the view's input context so IME
                        // composition works (#213); insertText:/setMarkedText:
                        // enqueue the resulting .text / .composition. Fall back to
                        // raw characters if the context didn't consume it.
                        const input_view = msg(id, struct {}, self.ns_window, sel("contentView"), .{});
                        const ic = msg(id, struct {}, input_view, sel("inputContext"), .{});
                        const handled = ic != null and msg(bool, struct { id }, ic, sel("handleEvent:"), .{ev});
                        if (!handled) {
                            const chars = msg(id, struct {}, ev, sel("characters"), .{});
                            if (chars != null) {
                                const utf8 = msg([*:0]const u8, struct {}, chars, sel("UTF8String"), .{});
                                var it = std.unicode.Utf8View.initUnchecked(std.mem.span(utf8)).iterator();
                                while (it.nextCodepoint()) |cp| {
                                    if (cp >= 0x20 and cp < 0xF700) {
                                        self.queue.append(self.gpa, .{ .text = .{ .codepoint = cp } }) catch {};
                                    }
                                }
                            }
                        }
                    }
                    continue; // don't sendEvent keyDown — avoids the no-responder beep
                },
                NSEventType.scroll_wheel => {
                    // scrollingDeltaX/Y are pixel-precise on trackpads and
                    // high-res wheels; hasPreciseScrollingDeltas distinguishes
                    // them from coarse mouse notches. AppKit's raw deltaY is the
                    // inverse of our canonical convention (#309: dy>0 = toward
                    // later content / scroll down) — a downward gesture yields a
                    // positive AppKit deltaY but should advance content — so we
                    // negate both axes here to match Win32/X11. The user's
                    // natural-scroll setting is already baked into the AppKit
                    // delta, so this single negation honours it on every Mac.
                    const loc = msg(NSPoint, struct {}, ev, sel("locationInWindow"), .{});
                    const cv = msg(NSPoint, struct { NSPoint, id }, view, sel("convertPoint:fromView:"), .{ loc, null });
                    const precise = msg(bool, struct {}, ev, sel("hasPreciseScrollingDeltas"), .{});
                    const dx = msg(f64, struct {}, ev, sel("scrollingDeltaX"), .{});
                    const dy = msg(f64, struct {}, ev, sel("scrollingDeltaY"), .{});
                    const ph = msg(u64, struct {}, ev, sel("momentumPhase"), .{});
                    const sflags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    const phase: core_event.ScrollPhase = if (ph != 0) .momentum else .continue_;
                    self.queue.append(self.gpa, .{ .scroll = .{
                        .position = .{ .x = @floatCast(cv.x * scale), .y = @floatCast((bounds.h - cv.y) * scale) },
                        .dx = @floatCast(-dx),
                        .dy = @floatCast(-dy),
                        .unit = if (precise) .pixel else .line,
                        .phase = phase,
                        .mods = modsFromFlags(sflags),
                    } }) catch {};
                },
                NSEventType.key_up => {
                    const kc = msg(u16, struct {}, ev, sel("keyCode"), .{});
                    const flags = msg(u64, struct {}, ev, sel("modifierFlags"), .{});
                    if (keyCodeToKey(kc)) |k| {
                        self.queue.append(self.gpa, .{ .key_up = .{ .key = k, .mods = modsFromFlags(flags) } }) catch {};
                    }
                    continue;
                },
                else => {},
            }
            _ = msg(void, struct { id }, app, sel("sendEvent:"), .{ev});
        }

        // Close: the red button orders the window out.
        const visible = msg(bool, struct {}, self.ns_window, sel("isVisible"), .{});
        if (visible) {
            self.was_visible = true;
        } else if (self.was_visible) {
            self.queue.append(self.gpa, .{ .close_requested = core_event.main_window }) catch {};
        }
        // Resize: poll the content frame.
        const content = msg(NSRect, struct {}, self.ns_window, sel("contentLayoutRect"), .{});
        if (content.w != self.last_size.w or content.h != self.last_size.h) {
            self.last_size = content;
            self.queue.append(self.gpa, .{ .resized = .{ .size = .{
                .width = @floatCast(@max(0, content.w)),
                .height = @floatCast(@max(0, content.h)),
            } } }) catch {};
        }
        return self.queue.items;
    }
};

// --- GL context (NSOpenGL, #11 GPU-present) ---------------------------------
// NSOpenGLPixelFormatAttribute tokens. No NSOpenGLPFAOpenGLProfile (=99) is
// requested, so the context is legacy 2.1 → GLSL 120 + APPLE VAOs + EXT FBOs,
// matching backends/gl.zig's macOS path. The attr list is u32, 0-terminated.
const NSOpenGLPFADoubleBuffer: u32 = 5;
const NSOpenGLPFAColorSize: u32 = 8;
const NSOpenGLPFAAlphaSize: u32 = 11;
const NSOpenGLPFAAccelerated: u32 = 73;

/// Create an NSOpenGLContext bound to the window's contentView and make it
/// current. Returns null on any failure (caller falls back to raster).
fn createGlContext(window: id) id {
    const attrs = [_]u32{ NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0 };
    const pf_alloc = msg(id, struct {}, cls("NSOpenGLPixelFormat"), sel("alloc"), .{});
    const pf = msg(id, struct { [*]const u32 }, pf_alloc, sel("initWithAttributes:"), .{&attrs});
    if (pf == null) return null;
    const ctx_alloc = msg(id, struct {}, cls("NSOpenGLContext"), sel("alloc"), .{});
    const ctx = msg(id, struct { id, id }, ctx_alloc, sel("initWithFormat:shareContext:"), .{ pf, null });
    if (ctx == null) return null;
    const view = msg(id, struct {}, window, sel("contentView"), .{});
    // Full-resolution backing so the GL surface matches contentPixelSize on
    // Retina (otherwise the drawable is point-sized and the viewport is off).
    _ = msg(void, struct { bool }, view, sel("setWantsBestResolutionOpenGLSurface:"), .{true});
    _ = msg(void, struct { id }, ctx, sel("setView:"), .{view});
    _ = msg(void, struct {}, ctx, sel("makeCurrentContext"), .{});
    // Swap interval 0: don't block flushBuffer on vsync. During a live resize
    // AppKit drives windowDidResize: faster than vblank; waiting on the swap
    // adds a frame of latency, so the surface lags the window edge. The idle
    // loop already throttles itself with a 16ms sleep, so unsynced presents
    // cost nothing there. NSOpenGLContextParameterSwapInterval = 222.
    const swap_interval: i32 = 0;
    _ = msg(void, struct { *const i32, u64 }, ctx, sel("setValues:forParameter:"), .{ &swap_interval, 222 });
    return ctx;
}

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
/// The key window's CGWindowID (`NSWindow.windowNumber`), for `screencapture
/// -l<id>` — a window-only screenshot. Null if no key window. Debug aid (#306).
pub fn keyWindowNumber() ?i64 {
    const nsapp = msg(id, struct {}, cls("NSApplication"), sel("sharedApplication"), .{});
    const kw = msg(id, struct {}, nsapp, sel("keyWindow"), .{});
    if (kw == null) return null;
    return msg(i64, struct {}, kw, sel("windowNumber"), .{});
}

pub fn contentPixelSize(window: *Window) struct { width: usize, height: usize, scale: f64 } {
    // Use the full content-view bounds, NOT contentLayoutRect: with a custom
    // overlay title bar the window is full_size_content_view, so contentLayoutRect
    // is inset below the (transparent) title bar while pointer events arrive in
    // the full content-view space. Laying out against the inset rect offsets every
    // hit-test by the title-bar height (clicks land ~32px low). The content is
    // meant to be full-bleed anyway — apps pad the top to clear the traffic
    // lights — so the layout viewport must match the bounds the mouse uses.
    const view = msg(id, struct {}, window.ns_window, sel("contentView"), .{});
    const content = msg(NSRect, struct {}, view, sel("bounds"), .{});
    const scale = msg(f64, struct {}, window.ns_window, sel("backingScaleFactor"), .{});
    return .{
        .width = @intFromFloat(@max(1, content.w * scale)),
        .height = @intFromFloat(@max(1, content.h * scale)),
        .scale = scale,
    };
}

/// The refresh rate (Hz) of the display the window is on (#170), for frame
/// pacing. Uses NSScreen.maximumFramesPerSecond (macOS 12+); 0 → caller's
/// fallback (60). A ProMotion / 120Hz panel reports 120 here.
pub fn refreshHz(window: *Window) f32 {
    const screen = msg(id, struct {}, window.ns_window, sel("screen"), .{});
    if (screen == null) return 0;
    const fps = msg(i64, struct {}, screen, sel("maximumFramesPerSecond"), .{});
    return if (fps > 0) @floatFromInt(fps) else 0;
}

test "objc runtime reachable: NSString round-trip" {
    const s = nsString("zooee");
    try std.testing.expect(s != null);
    const len = msg(u64, struct {}, s, sel("length"), .{});
    try std.testing.expectEqual(@as(u64, 5), len);
}
