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
    /// Keyboard modifiers held during the event (#127): shift/⌘-click for
    /// multi-select and range-select. Empty on platforms that don't report it.
    mods: Modifiers = .{},
    /// Consecutive-click count on `pointer_down` (#127): 1 single, 2 double,
    /// 3 triple. Always 1 for move/up. OS-provided where available, else 1.
    click_count: u8 = 1,
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

/// Scroll / wheel input (#126). A pointer-anchored delta normalized to one
/// cross-platform convention (#309):
///   `dy > 0` scrolls toward *later* content — the viewport moves down / content
///           moves up on screen — i.e. the scroll offset increases.
///   `dx > 0` scrolls toward content on the *right* (offset increases).
/// Platform layers map raw hardware deltas to this *after* the OS applies the
/// user's natural-scroll preference (macOS AppKit and Windows do this for us;
/// X11 gets it from XInput2 scroll valuators). So an app just adds the delta to
/// its scroll offset and the direction is correct everywhere, on either setting.
/// `unit` distinguishes discrete wheel lines from smooth pixel deltas
/// (trackpads); `phase` exposes the trackpad gesture lifecycle (incl. momentum).
pub const ScrollEvent = struct {
    window: WindowId = main_window,
    /// Pointer position when the scroll occurred (for hit-testing the target).
    position: geometry.Point,
    dx: f32 = 0,
    dy: f32 = 0,
    unit: ScrollUnit = .line,
    phase: ScrollPhase = .continue_,
    mods: Modifiers = .{},
};

pub const ScrollUnit = enum {
    /// Discrete wheel notches (mouse). One step is `dy = ±1` line.
    line,
    /// Smooth pixel deltas (trackpad, high-resolution wheel).
    pixel,
};

/// Trackpad gesture lifecycle (mouse wheels only ever emit `.continue_`).
pub const ScrollPhase = enum {
    /// Fingers touched down / gesture began.
    begin,
    /// An ongoing scroll update.
    continue_,
    /// Fingers lifted; the user-driven part ended.
    end,
    /// Inertial momentum frames after `end` (macOS); decays to a stop.
    momentum,
};

/// IME composition lifecycle (#19): CJK and other input methods build text in
/// a pre-edit buffer before committing. `update` carries the in-progress
/// (underlined) string with a caret; `commit` carries the finalized text that
/// should be inserted; `cancel` abandons the composition.
pub const CompositionPhase = enum { start, update, commit, cancel };

pub const CompositionEvent = struct {
    window: WindowId = main_window,
    phase: CompositionPhase,
    /// The pre-edit string (`update`) or the committed string (`commit`).
    /// Borrowed for the dispatch; apps that retain it must copy.
    text: []const u8 = "",
    /// Caret position within `text`, in bytes (for `update` underlining).
    caret: usize = 0,
};

/// What a drag carries (#128). Borrowed slices, valid only for the duration of
/// the event dispatch — apps that keep data must copy it.
pub const DragData = union(enum) {
    /// Absolute file-system paths (Finder/Explorer drops).
    files: []const []const u8,
    /// UTF-8 text.
    text: []const u8,
    /// URL strings.
    urls: []const []const u8,
    /// A drag whose payload type isn't surfaced yet (enter/leave probes).
    unknown: void,
};

/// Operation the source offers / the target accepts (#128).
pub const DragOperation = enum { none, copy, move, link };

/// An OS drag interacting with the window (#128): file/text/URL drops from
/// other apps. `drag_over` lets the app accept/reject by position before the
/// `drop`; `operation` is the proposed (enter/over) or committed (drop) action.
pub const DragEvent = struct {
    window: WindowId = main_window,
    position: geometry.Point,
    data: DragData = .unknown,
    operation: DragOperation = .copy,
};

pub const Event = union(enum) {
    key_down: KeyEvent,
    /// Key release (#127): held-key state, modifier release, games.
    key_up: KeyEvent,
    text: TextEvent,
    /// IME pre-edit / commit (#19): CJK and dead-key composition.
    composition: CompositionEvent,
    pointer_down: PointerEvent,
    pointer_up: PointerEvent,
    pointer_move: PointerEvent,
    /// Pointer entered the window's content area (#127).
    pointer_enter: PointerEvent,
    /// Pointer left the window — clears stuck hover state (#127).
    pointer_leave: PointerEvent,
    scroll: ScrollEvent,
    /// Drag-and-drop from another app (#128): enter → over* → (drop | leave).
    drag_enter: DragEvent,
    drag_over: DragEvent,
    drag_leave: DragEvent,
    drop: DragEvent,
    resized: ResizeEvent,
    focus_gained: WindowId,
    focus_lost: WindowId,
    /// Window-state transitions (#98), normalized from the OS — emitted by the
    /// platform whether the change was user- or app-initiated.
    window_minimized: WindowId,
    window_maximized: WindowId,
    window_restored: WindowId,
    close_requested: WindowId,
};
