//! Shared windowing types (#64) used by both the app loop and the platform
//! window layers (a leaf module, so neither imports the other).

/// How the window's title bar is presented (#64 — Chrome-style chrome):
/// - `native`: the OS draws a standard title bar above the content.
/// - `integrated`: the content area extends *under* a transparent title bar,
///   so the app can draw into that strip (tabs, toolbars) while the OS window
///   controls stay usable.
/// - `headless`: no OS title bar — the app owns the whole surface and supplies
///   its own window controls + drag regions.
pub const TitlebarMode = enum { native, integrated, headless };
