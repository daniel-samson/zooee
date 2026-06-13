//! System font discovery (#10 runtime policy): load the OS's own fonts
//! from disk — zero font bytes in the binary, native look. A first-match
//! candidate list per platform; a real query API (DirectWrite/CoreText/
//! fontconfig-free scan) and .ttc collections are follow-ups on #10.

const std = @import("std");
const builtin = @import("builtin");
const raster = @import("../backends/raster.zig");

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

/// Load the first parseable candidate into the raster backend. Returns
/// true on success; false leaves the backend on placeholder glyphs.
pub fn loadInto(gpa: std.mem.Allocator, io: std.Io, r: *raster.RasterBackend) bool {
    for (candidates) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch continue;
        r.setFont(data) catch {
            gpa.free(data);
            continue;
        };
        return true;
    }
    return false;
}
