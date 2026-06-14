//! Zooee — a cross-platform UI framework with pluggable rendering
//! backends (terminal, DirectX, OpenGL, web).

const std = @import("std");

pub const geometry = @import("geometry.zig");
pub const layout = @import("layout.zig");
pub const app = @import("app.zig");
pub const style = @import("style.zig");
pub const backend = @import("backend.zig");
pub const backends = struct {
    pub const record = @import("backends/record.zig");
    pub const terminal = @import("backends/terminal.zig");
    pub const raster = @import("backends/raster.zig");
    pub const gl = if (@import("builtin").os.tag == .linux) @import("backends/gl.zig") else struct {};
    pub const d3d11 = if (@import("builtin").os.tag == .windows) @import("backends/d3d11.zig") else struct {};
    pub const metal = if (@import("builtin").os.tag == .macos) @import("backends/metal.zig") else struct {};
};

pub const Backend = backend.Backend;
pub const Color = style.Color;
pub const Rect = geometry.Rect;
pub const Point = geometry.Point;
pub const Size = geometry.Size;

pub const fixtures = @import("testing/scenes.zig");

/// OFL test font (tests/goldens only — runtime apps use OS fonts, #10).
pub const test_font_ttf = @embedFile("poppins");
pub const app_fixtures = @import("testing/app_fixture.zig");
/// Synthetic-event test harness (#130): drive a Model with scripted events.
pub const Driver = @import("testing/driver.zig").Driver;
pub const driver = @import("testing/driver.zig");

pub const event = @import("event.zig");
pub const anim = @import("anim.zig");
/// Declarative animation (#125): CSS-like transitions + keyframes over anim.
pub const declarative = @import("declarative.zig");
pub const text = @import("text.zig");
pub const clipboard = @import("clipboard.zig");
pub const display = @import("display.zig");
pub const theme = @import("theme.zig");
pub const Theme = theme.Theme;
pub const font = struct {
    pub const ttf = @import("font/ttf.zig");
    pub const raster = @import("font/raster.zig");
    pub const system = @import("font/system.zig");
    pub const atlas = @import("font/atlas.zig");
    pub const fontset = @import("font/fontset.zig");
    pub const FontSet = fontset.FontSet;
};

pub const platform = struct {
    pub const win32 = if (@import("builtin").os.tag == .windows)
        @import("platform/win32.zig")
    else
        struct {};
    pub const win32_console = if (@import("builtin").os.tag == .windows)
        @import("platform/win32_console.zig")
    else
        struct {};
    pub const macos = if (@import("builtin").os.tag == .macos)
        @import("platform/macos.zig")
    else
        struct {};
    pub const posix_tty = if (@import("builtin").os.tag != .windows)
        @import("platform/posix_tty.zig")
    else
        struct {};
    pub const x11 = if (@import("builtin").os.tag == .linux)
        @import("platform/x11.zig")
    else
        struct {};
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/harness_test.zig");
    // refAllDecls is shallow — without this, platform tests are lazily
    // skipped and never compile-checked or run.
    if (@import("builtin").os.tag == .windows) {
        std.testing.refAllDecls(platform.win32);
        std.testing.refAllDecls(platform.win32_console);
    } else {
        std.testing.refAllDecls(platform.posix_tty);
        if (@import("builtin").os.tag == .linux) {
            std.testing.refAllDecls(platform.x11);
        }
        if (@import("builtin").os.tag == .macos) {
            std.testing.refAllDecls(platform.macos);
        }
    }
}
