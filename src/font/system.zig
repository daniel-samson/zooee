//! System font discovery (#10 runtime policy): load the OS's own fonts
//! from disk — zero font bytes in the binary, native look. A first-match
//! candidate list per platform; a real query API (DirectWrite/CoreText/
//! fontconfig-free scan) and .ttc collections are follow-ups on #10.

const std = @import("std");
const builtin = @import("builtin");
const raster = @import("../backends/raster.zig");
const ttf = @import("ttf.zig");
const fontset = @import("fontset.zig");

const log = std.log.scoped(.font);

// --- macOS CoreText system-font discovery (#204) ----------------------------
// The C CoreText/CoreFoundation API (no Objective-C): ask for the system UI
// font and copy its file URL → POSIX path. This yields the *real* system font
// (San Francisco, #205) regardless of where the OS version keeps it, instead
// of guessing a hardcoded path.
const ct = if (builtin.os.tag == .macos) struct {
    const kCTFontUIFontSystem: u32 = 2;
    const kCFURLPOSIXPathStyle: c_long = 0;
    const kCFStringEncodingUTF8: u32 = 0x08000100;
    extern "c" fn CTFontCreateUIFontForLanguage(uiType: u32, size: f64, language: ?*anyopaque) ?*anyopaque;
    extern "c" fn CTFontCopyFontDescriptor(font: ?*anyopaque) ?*anyopaque;
    extern "c" fn CTFontDescriptorCopyAttribute(desc: ?*anyopaque, attr: ?*anyopaque) ?*anyopaque;
    extern "c" fn CFURLCopyFileSystemPath(url: ?*anyopaque, style: c_long) ?*anyopaque;
    extern "c" fn CFStringGetCString(str: ?*anyopaque, buf: [*]u8, len: c_long, encoding: u32) bool;
    extern "c" fn CFRelease(cf: ?*anyopaque) void;
    extern const kCTFontURLAttribute: ?*anyopaque; // CFStringRef
} else struct {};

// --- Linux fontconfig discovery (#204) --------------------------------------
// dlopen libfontconfig (no link-time dependency — absent → fall back to the
// hardcoded paths) and resolve the default sans-serif font's file path.
extern "c" fn dlopen([*:0]const u8, c_int) ?*anyopaque;
extern "c" fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
const RTLD_NOW: c_int = 2;

/// The Linux default sans-serif font path (#204) via fontconfig, into `buf`.
/// Null when fontconfig is unavailable or the query fails.
fn linuxSystemFontPath(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const lib = dlopen("libfontconfig.so.1", RTLD_NOW) orelse return null;
    const FcInit = *const fn () callconv(.c) c_int;
    const FcNameParse = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
    const FcConfigSubstitute = *const fn (?*anyopaque, ?*anyopaque, c_int) callconv(.c) c_int;
    const FcDefaultSubstitute = *const fn (?*anyopaque) callconv(.c) void;
    const FcFontMatch = *const fn (?*anyopaque, ?*anyopaque, *c_int) callconv(.c) ?*anyopaque;
    const FcPatternGetString = *const fn (?*anyopaque, [*:0]const u8, c_int, *?[*:0]const u8) callconv(.c) c_int;
    const FcPatternDestroy = *const fn (?*anyopaque) callconv(.c) void;
    const init: FcInit = @ptrCast(dlsym(lib, "FcInit") orelse return null);
    const parse: FcNameParse = @ptrCast(dlsym(lib, "FcNameParse") orelse return null);
    const subst: FcConfigSubstitute = @ptrCast(dlsym(lib, "FcConfigSubstitute") orelse return null);
    const dflt: FcDefaultSubstitute = @ptrCast(dlsym(lib, "FcDefaultSubstitute") orelse return null);
    const match: FcFontMatch = @ptrCast(dlsym(lib, "FcFontMatch") orelse return null);
    const get: FcPatternGetString = @ptrCast(dlsym(lib, "FcPatternGetString") orelse return null);
    const destroy: FcPatternDestroy = @ptrCast(dlsym(lib, "FcPatternDestroy") orelse return null);

    if (init() == 0) return null;
    const pat = parse("sans-serif") orelse return null;
    defer destroy(pat);
    _ = subst(null, pat, 0); // FcMatchPattern
    dflt(pat);
    var result: c_int = 0;
    const m = match(null, pat, &result) orelse return null;
    defer destroy(m);
    var file: ?[*:0]const u8 = null;
    if (get(m, "file", 0, &file) != 0) return null; // != FcResultMatch
    const path = std.mem.span(file orelse return null);
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

/// The macOS system UI font's file path (#204/#205), written into `buf`.
/// Null if CoreText is unavailable or the lookup fails.
fn macSystemFontPath(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const font = ct.CTFontCreateUIFontForLanguage(ct.kCTFontUIFontSystem, 13.0, null) orelse return null;
    defer ct.CFRelease(font);
    const desc = ct.CTFontCopyFontDescriptor(font) orelse return null;
    defer ct.CFRelease(desc);
    const url = ct.CTFontDescriptorCopyAttribute(desc, ct.kCTFontURLAttribute) orelse return null;
    defer ct.CFRelease(url);
    const cfpath = ct.CFURLCopyFileSystemPath(url, ct.kCFURLPOSIXPathStyle) orelse return null;
    defer ct.CFRelease(cfpath);
    if (!ct.CFStringGetCString(cfpath, buf.ptr, @intCast(buf.len), ct.kCFStringEncodingUTF8)) return null;
    return std.mem.sliceTo(buf, 0);
}

/// Default UI-font candidates, most-preferred first.
pub const candidates: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Verdana.ttf",
        "/Library/Fonts/Arial.ttf",
    },
    .windows => &.{
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
        "C:\\Windows\\Fonts\\tahoma.ttf",
    },
    .linux => &.{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    },
    else => &.{},
};

/// A font family with its style-variant files (#114). `bold`/`italic`/
/// `bold_italic` are best-effort: missing variants fall back to `regular`.
const Family = struct {
    regular: []const u8,
    bold: ?[]const u8 = null,
    italic: ?[]const u8 = null,
    bold_italic: ?[]const u8 = null,
};

/// Per-OS families, most-preferred first. The first family whose `regular`
/// loads becomes primary (with its variants); later families' `regular`s join
/// the fallback chain for broader codepoint coverage.
const families: []const Family = switch (builtin.os.tag) {
    .macos => &.{
        .{
            .regular = "/System/Library/Fonts/Supplemental/Arial.ttf",
            .bold = "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            .italic = "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
            .bold_italic = "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf",
        },
        .{ .regular = "/System/Library/Fonts/Supplemental/Verdana.ttf", .bold = "/System/Library/Fonts/Supplemental/Verdana Bold.ttf" },
    },
    .windows => &.{
        .{ .regular = "C:\\Windows\\Fonts\\segoeui.ttf", .bold = "C:\\Windows\\Fonts\\segoeuib.ttf", .italic = "C:\\Windows\\Fonts\\segoeuii.ttf", .bold_italic = "C:\\Windows\\Fonts\\segoeuiz.ttf" },
        .{ .regular = "C:\\Windows\\Fonts\\arial.ttf", .bold = "C:\\Windows\\Fonts\\arialbd.ttf" },
        .{ .regular = "C:\\Windows\\Fonts\\tahoma.ttf" },
    },
    .linux => &.{
        .{ .regular = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", .bold = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", .italic = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf", .bold_italic = "/usr/share/fonts/truetype/dejavu/DejaVuSans-BoldOblique.ttf" },
        .{ .regular = "/usr/share/fonts/TTF/DejaVuSans.ttf", .bold = "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf" },
        .{ .regular = "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf", .bold = "/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf" },
    },
    else => &.{},
};

fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch null;
}

fn parsed(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) ?ttf.Font {
    const p = path orelse return null;
    const data = read(gpa, io, p) orelse return null;
    return ttf.Font.parse(data) catch {
        gpa.free(data);
        return null;
    };
}

/// Build a `FontSet` from the OS fonts (#114): the first available family's
/// regular + bold/italic variants as the primary, plus later families' regulars
/// as the fallback chain. Returns null if no font loads (caller keeps
/// placeholder glyphs). Loaded bytes live for the process (borrowed by the set).
pub fn loadFontSet(gpa: std.mem.Allocator, io: std.Io) ?fontset.FontSet {
    var set: fontset.FontSet = .{};
    var have_primary = false;

    // Native discovery first (#204): the OS's real system font, wherever it
    // lives this OS version (San Francisco on macOS, #205). Bold/italic still
    // come from the family list below until per-weight discovery lands.
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        var path_buf: [1024]u8 = undefined;
        const discovered = if (builtin.os.tag == .macos) macSystemFontPath(&path_buf) else linuxSystemFontPath(&path_buf);
        if (discovered) |p| {
            if (parsed(gpa, io, p)) |reg| {
                set.setFace(fontset.FontSet.regular, reg);
                have_primary = true;
                // Bold/italic from the first family until SF's weight axis is
                // instanced (#205) — a known regular-SF + bold-Arial mix.
                if (families.len > 0) {
                    if (parsed(gpa, io, families[0].bold)) |f| set.setFace(fontset.FontSet.bold_slot, f);
                    if (parsed(gpa, io, families[0].italic)) |f| set.setFace(fontset.FontSet.italic_slot, f);
                    if (parsed(gpa, io, families[0].bold_italic)) |f| set.setFace(fontset.FontSet.bold_italic_slot, f);
                }
            } else log.warn("discovered system font at '{s}' failed to parse; using fallbacks", .{p});
        }
    }

    for (families) |fam| {
        if (!have_primary) {
            const reg = parsed(gpa, io, fam.regular) orelse continue;
            set.setFace(fontset.FontSet.regular, reg);
            if (parsed(gpa, io, fam.bold)) |f| set.setFace(fontset.FontSet.bold_slot, f);
            if (parsed(gpa, io, fam.italic)) |f| set.setFace(fontset.FontSet.italic_slot, f);
            if (parsed(gpa, io, fam.bold_italic)) |f| set.setFace(fontset.FontSet.bold_italic_slot, f);
            have_primary = true;
        } else {
            if (parsed(gpa, io, fam.regular)) |f| set.addFallback(f);
        }
    }
    if (!have_primary) {
        // Non-silent failure (#204): the app renders placeholder blocks, so say
        // why instead of degrading quietly.
        log.warn("no system font found (tried CoreText + {d} candidate families) — text will use placeholder glyphs", .{families.len});
        return null;
    }
    return set;
}

/// Read the first existing candidate font file's bytes (caller owns).
/// Returns null if none are readable. Does not validate the TTF — the
/// caller's setFont does that.
pub fn loadBytes(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    for (candidates) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        return data;
    }
    return null;
}

/// Load the OS font set (regular + bold/italic + Unicode fallback) into the
/// raster backend (#114). Returns true on success; false leaves the backend on
/// placeholder glyphs.
pub fn loadInto(gpa: std.mem.Allocator, io: std.Io, r: *raster.RasterBackend) bool {
    if (loadFontSet(gpa, io)) |set| {
        r.setFontSet(set);
        return true;
    }
    return false;
}
