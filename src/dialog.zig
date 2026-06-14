//! Native file/folder dialogs (#129, slice 1 — dialogs half; menus are the
//! other half of the issue and can be split off).
//!
//! `openFile` shows the OS-native open panel and returns the chosen absolute
//! path (caller-owned) or null if the user cancelled. It BLOCKS until the
//! dialog is dismissed and requires an interactive desktop session.
//!
//! Per-platform backing:
//!   - macOS:  NSOpenPanel (objc, no extra link — AppKit is already linked).
//!   - Windows: comdlg32 GetOpenFileNameW (the simple, dependency-free path;
//!     IFileDialog + folder picking is a slice-2 upgrade).
//!   - Linux/X11: there is no native toolkit-agnostic dialog, so we shell out
//!     to `zenity` (GNOME) or `kdialog` (KDE) if present — the same approach
//!     most non-GTK/Qt apps take. Returns error.NoNativeDialog if neither is
//!     installed (the app can fall back to an in-window picker, #17).
//!
//! v1 scope: single-selection open, optional folder mode, optional title.
//! Deferred (same issue): save dialogs, multi-select, type filters, and the
//! Win32 IFileDialog / Linux XDG-portal upgrades.

const std = @import("std");
const builtin = @import("builtin");

pub const OpenOptions = struct {
    /// Dialog window title. Platform default ("Open") when empty.
    title: [:0]const u8 = "Open",
    /// Choose a folder instead of a file.
    directory: bool = false,
};

/// Show the native open dialog and return the selected absolute path (owned by
/// `gpa`, free with `gpa.free`) or null if cancelled. Blocks until dismissed.
pub fn openFile(gpa: std.mem.Allocator, opts: OpenOptions) !?[]u8 {
    return switch (builtin.os.tag) {
        .macos => openFileMac(gpa, opts),
        .windows => openFileWindows(gpa, opts),
        .linux => openFileLinux(gpa, opts),
        else => error.NoNativeDialog,
    };
}

// --- macOS: NSOpenPanel ------------------------------------------------------

const objc = struct {
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;
    const Class = ?*anyopaque;
    extern "objc" fn objc_getClass([*:0]const u8) Class;
    extern "objc" fn sel_registerName([*:0]const u8) SEL;
    extern "objc" fn objc_msgSend() void;

    fn sel(comptime name: [:0]const u8) SEL {
        return sel_registerName(name.ptr);
    }
    fn cls(comptime name: [:0]const u8) Class {
        return objc_getClass(name.ptr);
    }
    fn msg(comptime Ret: type, comptime Args: type, target: anytype, selector: SEL, args: Args) Ret {
        const n = @typeInfo(Args).@"struct".fields.len;
        const Fn = switch (n) {
            0 => *const fn (@TypeOf(target), SEL) callconv(.c) Ret,
            1 => *const fn (@TypeOf(target), SEL, @typeInfo(Args).@"struct".fields[0].type) callconv(.c) Ret,
            else => @compileError("unsupported arg count"),
        };
        const f: Fn = @ptrCast(&objc_msgSend);
        return switch (n) {
            0 => f(target, selector),
            1 => f(target, selector, @field(args, "0")),
            else => unreachable,
        };
    }
    fn nsString(text: [*:0]const u8) id {
        return msg(id, struct { [*:0]const u8 }, cls("NSString"), sel("stringWithUTF8String:"), .{text});
    }
};

fn openFileMac(gpa: std.mem.Allocator, opts: OpenOptions) !?[]u8 {
    const o = objc;
    const panel = o.msg(o.id, struct {}, o.cls("NSOpenPanel"), o.sel("openPanel"), .{});
    if (panel == null) return error.NoNativeDialog;
    _ = o.msg(void, struct { bool }, panel, o.sel("setCanChooseFiles:"), .{!opts.directory});
    _ = o.msg(void, struct { bool }, panel, o.sel("setCanChooseDirectories:"), .{opts.directory});
    _ = o.msg(void, struct { bool }, panel, o.sel("setAllowsMultipleSelection:"), .{false});
    if (opts.title.len > 0) _ = o.msg(void, struct { o.id }, panel, o.sel("setTitle:"), .{o.nsString(opts.title.ptr)});

    // NSModalResponseOK == 1.
    const resp = o.msg(isize, struct {}, panel, o.sel("runModal"), .{});
    if (resp != 1) return null;

    const url = o.msg(o.id, struct {}, panel, o.sel("URL"), .{});
    if (url == null) return null;
    const path = o.msg(o.id, struct {}, url, o.sel("path"), .{});
    if (path == null) return null;
    const c = o.msg([*:0]const u8, struct {}, path, o.sel("UTF8String"), .{});
    return try gpa.dupe(u8, std.mem.span(c));
}

// --- Windows: comdlg32 GetOpenFileNameW --------------------------------------

const win = std.os.windows;
const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque = null,
    hInstance: ?*anyopaque = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*:0]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*:0]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*:0]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: usize = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};
const OFN_FILEMUSTEXIST: u32 = 0x00001000;
const OFN_PATHMUSTEXIST: u32 = 0x00000800;
extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(.winapi) win.BOOL;

fn openFileWindows(gpa: std.mem.Allocator, opts: OpenOptions) !?[]u8 {
    // The simple comdlg32 picker is files-only; folder selection is a slice-2
    // IFileDialog(FOS_PICKFOLDERS) upgrade.
    if (opts.directory) return error.NoNativeDialog;

    var file_buf = [_]u16{0} ** 1024;
    var title_buf: [256]u16 = undefined;
    const title_len = try std.unicode.utf8ToUtf16Le(title_buf[0..255], opts.title);
    title_buf[title_len] = 0;

    var ofn: OPENFILENAMEW = .{
        .lStructSize = @sizeOf(OPENFILENAMEW),
        .lpstrFile = @ptrCast(&file_buf),
        .nMaxFile = file_buf.len,
        .lpstrTitle = if (opts.title.len > 0) title_buf[0..title_len :0] else null,
        .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST,
    };
    if (GetOpenFileNameW(&ofn) == .FALSE) return null; // cancelled or error

    const w = std.mem.sliceTo(&file_buf, 0);
    return try std.unicode.utf16LeToUtf8Alloc(gpa, w);
}

// --- Linux/X11: zenity or kdialog --------------------------------------------

fn openFileLinux(gpa: std.mem.Allocator, opts: OpenOptions) !?[]u8 {
    // Try zenity (GNOME) then kdialog (KDE). Both print the chosen path to
    // stdout and exit non-zero on cancel.
    const zenity: []const []const u8 = if (opts.directory)
        &.{ "zenity", "--file-selection", "--directory" }
    else
        &.{ "zenity", "--file-selection" };
    if (try runPicker(gpa, zenity)) |p| return p;

    const kdialog: []const []const u8 = if (opts.directory)
        &.{ "kdialog", "--getexistingdirectory", "." }
    else
        &.{ "kdialog", "--getopenfilename", "." };
    if (try runPicker(gpa, kdialog)) |p| return p;

    return error.NoNativeDialog;
}

/// Run an external picker and return its stdout path, or null on cancel.
/// Returns error.NoNativeDialog if the binary isn't installed (so the caller
/// can try the next one).
fn runPicker(gpa: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    var child = std.process.Child.init(argv, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.NoNativeDialog; // binary missing
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (child.stdout) |so| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&buf) catch break;
            if (n == 0) break;
            try out.appendSlice(gpa, buf[0..n]);
        }
    }
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return null, // user cancelled
        else => return null,
    }
    const trimmed = std.mem.trimRight(u8, out.items, "\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

// === Tests ==================================================================
// The dialog itself is interactive (needs a desktop session), so unit tests
// here cover only the non-UI plumbing: option defaults and the
// unsupported-platform contract. Real verification is manual (see the PR).

test "openFile reports no native dialog on unsupported platforms" {
    if (builtin.os.tag == .macos or builtin.os.tag == .windows or builtin.os.tag == .linux) return error.SkipZigTest;
    try std.testing.expectError(error.NoNativeDialog, openFile(std.testing.allocator, .{}));
}

test "OpenOptions defaults" {
    const o: OpenOptions = .{};
    try std.testing.expect(!o.directory);
    try std.testing.expectEqualStrings("Open", o.title);
}
