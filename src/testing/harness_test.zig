//! Cross-backend fixture harness (#8, #13): every scene in scenes.zig is
//! rendered by every backend. Terminal output is asserted against text
//! snapshots; raster output against framebuffer hashes. On mismatch the
//! actual output/hash is printed for intentional regeneration.

const std = @import("std");
const scenes = @import("scenes.zig");
const terminal = @import("../backends/terminal.zig");
const raster = @import("../backends/raster.zig");

const testing = std.testing;

/// Dump the terminal cell buffer with background colors made visible:
/// glyphs render as themselves; glyph-less colored cells render as the
/// dominant channel letter (R/G/B, W for white-ish). Trailing spaces
/// trimmed per line.
fn dumpColored(term: *const terminal.TerminalBackend, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var y: usize = 0;
    while (y < term.height) : (y += 1) {
        const row = term.cells[y * term.width ..][0..term.width];
        var line_end: usize = 0;
        for (row, 0..) |cell, i| {
            if (cell.cp != ' ' or cell.bg != null) line_end = i + 1;
        }
        for (row[0..line_end]) |cell| {
            if (cell.cp != ' ') {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cell.cp, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..n]);
            } else if (cell.bg) |bg| {
                try out.append(gpa, colorLetter(bg));
            } else {
                try out.append(gpa, ' ');
            }
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn colorLetter(c: @import("../style.zig").Color) u8 {
    if (c.r > 200 and c.g > 200 and c.b > 200) return 'W';
    if (c.r >= c.g and c.r >= c.b) return 'R';
    if (c.g >= c.b) return 'G';
    return 'B';
}

const TerminalGolden = struct {
    name: []const u8,
    text: []const u8,
};

const terminal_goldens = [_]TerminalGolden{
    .{ .name = "card", .text =
    \\
    \\ ╭────────────────────╮
    \\ │WWWWWWWWWWWWWWWWWWWW│
    \\ │WzooeeWWWWWWWWWWWWWW│
    \\ │WWWWWWWWWWWWWWWWWWWW│
    \\ ╰────────────────────╯
    \\
    \\
    },
    .{ .name = "nested_clip", .text =
    \\BBBBBBBBBBBB
    \\BBBBBBBBBBBB
    \\
    \\
    \\
    \\
    },
    .{ .name = "overlap", .text =
    \\
    \\ RRRRRRRRR
    \\ RRRRRGGGGGGGGG
    \\ RRRRRGGGGGGGGG
    \\ RRRRRGGGGGGGGG
    \\      GGGGGGGGG
    \\
    },
    .{ .name = "sides", .text =
    \\
    \\ ╭──────────┐
    \\ │          │
    \\ │          │
    \\
    \\
    \\
    },
    .{ .name = "hello_text", .text =
    \\
    \\ Zooee 1.0!
    \\
    \\
    \\
    },
    .{ .name = "layout_card", .text =
    \\
    \\ ┌────────┐
    \\ │ layout │
    \\ └────────┘
    \\
    \\ RRRRRRRRRRR GGGGGGGGGG
    \\ RRRRRRRRRRR GGGGGGGGGG
    \\
    \\
    },
    .{ .name = "image", .text =
    \\
    \\ ▒▒▒▒▒▒▒▒
    \\ ▒▒▒▒▒▒▒▒
    \\ ▒▒▒▒▒▒▒▒
    \\ ▒▒▒▒▒▒▒▒
    \\
    \\
    },
};

fn findScene(name: []const u8) scenes.Scene {
    for (scenes.all) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    unreachable;
}

test "terminal renders all scenes to snapshot" {
    for (terminal_goldens) |golden| {
        const scene = findScene(golden.name);
        var term = terminal.TerminalBackend.init(testing.allocator);
        defer term.deinit();
        try scenes.run(scene, term.interface(), 1);
        const actual = try dumpColored(&term, testing.allocator);
        defer testing.allocator.free(actual);
        testing.expectEqualStrings(golden.text, actual) catch |err| {
            std.debug.print("terminal snapshot mismatch for scene '{s}'; actual:\n{s}\n", .{ golden.name, actual });
            return err;
        };
    }
}

const RasterGolden = struct {
    name: []const u8,
    hash: u64,
};

// FNV-1a of the RGBA framebuffer at scale 8. On mismatch the actual hash
// is printed; update deliberately when a scene/renderer change is intended.
const raster_goldens = [_]RasterGolden{
    .{ .name = "card", .hash = 0x9b1b64d3f174f163 },
    .{ .name = "nested_clip", .hash = 0x802b0f2a3db4bb25 },
    .{ .name = "overlap", .hash = 0xc6478bd603cbc525 },
    .{ .name = "sides", .hash = 0x1610961fa746f7eb },
    .{ .name = "layout_card", .hash = 0xb69813e5bdc834c },
    .{ .name = "hello_text", .hash = 0xc72d0c60fbbb6bbb },
    .{ .name = "image", .hash = 0x8b0e08f61841725 },
};

test "raster renders all scenes to golden hashes" {
    for (raster_goldens) |golden| {
        const scene = findScene(golden.name);
        var ras = raster.RasterBackend.init(testing.allocator);
        defer ras.deinit();
        try ras.setFont(@embedFile("poppins"));
        try scenes.run(scene, ras.interface(), 8);
        const actual = std.hash.Fnv1a_64.hash(ras.pixels);
        testing.expectEqual(golden.hash, actual) catch |err| {
            std.debug.print(
                "raster golden mismatch for scene '{s}': actual hash 0x{x}\n",
                .{ golden.name, actual },
            );
            return err;
        };
    }
}

test "every scene has goldens in both harnesses" {
    try testing.expectEqual(scenes.all.len, terminal_goldens.len);
    try testing.expectEqual(scenes.all.len, raster_goldens.len);
}
