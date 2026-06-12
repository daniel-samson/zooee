//! Core event types (#5).
//!
//! Design decisions baked in:
//! - #23: every event carries a `WindowId` from day one (single-window
//!   v1 apps ignore it; adding windows later breaks no signatures).
//! - #32: pointer events, not mouse events — `kind` distinguishes
//!   mouse/touch/pen and `id` identifies the contact, so multi-touch is
//!   additive.

const geometry = @import("geometry.zig");

pub const WindowId = u32;
/// The id every event uses until multi-window lands.
pub const main_window: WindowId = 0;

pub const PointerKind = enum { mouse, touch, pen };

pub const Buttons = packed struct(u8) {
    primary: bool = false,
    secondary: bool = false,
    middle: bool = false,
    _pad: u5 = 0,
};

pub const PointerEvent = struct {
    window: WindowId = main_window,
    /// Stable per contact; 0 for the mouse.
    id: u32 = 0,
    kind: PointerKind = .mouse,
    position: geometry.Point,
    buttons: Buttons = .{},
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

/// Keys that aren't text. Printable input arrives as `.text` events so
/// IME composition (#19) can slot in without reshaping the API.
pub const Key = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    escape,
    tab,
    backspace,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const KeyEvent = struct {
    window: WindowId = main_window,
    key: Key,
    mods: Modifiers = .{},
};

pub const TextEvent = struct {
    window: WindowId = main_window,
    /// A single codepoint for now; IME composition (#19) extends this.
    codepoint: u21,
    mods: Modifiers = .{},
};

pub const ResizeEvent = struct {
    window: WindowId = main_window,
    size: geometry.Size,
};

pub const Event = union(enum) {
    key_down: KeyEvent,
    text: TextEvent,
    pointer_down: PointerEvent,
    pointer_up: PointerEvent,
    pointer_move: PointerEvent,
    resized: ResizeEvent,
    focus_gained: WindowId,
    focus_lost: WindowId,
    close_requested: WindowId,
};
