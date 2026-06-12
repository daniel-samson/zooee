//! VT input parser (#5, #7): bytes → core events. Platform-neutral —
//! POSIX reads these bytes from the tty; Windows reconstructs the byte
//! stream from console records under ENABLE_VIRTUAL_TERMINAL_INPUT
//! (Windows Terminal delivers keys AND mouse as VT sequences only).
//! Pure functions over byte slices: unit-testable with no terminal (#8).

const std = @import("std");
const event = @import("../event.zig");
const geometry = @import("../geometry.zig");

/// Parse a byte buffer into events; returns bytes consumed. Incomplete
/// trailing escape sequences are left unconsumed for the next read.
pub fn parseInput(bytes: []const u8, events: *std.ArrayList(event.Event), gpa: std.mem.Allocator) !usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0x1b) {
            const r = parseEscape(bytes[i..]) orelse {
                // Incomplete sequence: if it's at the buffer tail, wait for
                // more bytes; a lone ESC (nothing after) is the Escape key
                // only when nothing follows in this read.
                if (bytes.len - i == 1) {
                    try events.append(gpa, .{ .key_down = .{ .key = .escape } });
                    return bytes.len;
                }
                return i; // keep partial sequence pending
            };
            if (r.ev) |ev| try events.append(gpa, ev);
            i += r.len;
        } else if (b == '\r' or b == '\n') {
            try events.append(gpa, .{ .key_down = .{ .key = .enter } });
            i += 1;
        } else if (b == '\t') {
            try events.append(gpa, .{ .key_down = .{ .key = .tab } });
            i += 1;
        } else if (b == 0x7f or b == 0x08) {
            try events.append(gpa, .{ .key_down = .{ .key = .backspace } });
            i += 1;
        } else if (b == 0x03) { // ctrl-c
            try events.append(gpa, .{ .close_requested = event.main_window });
            i += 1;
        } else if (b < 0x20) { // other ctrl-<letter>
            try events.append(gpa, .{ .text = .{ .codepoint = b + 'a' - 1, .mods = .{ .ctrl = true } } });
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
                i += 1;
                continue;
            };
            if (i + seq_len > bytes.len) return i; // partial UTF-8, keep pending
            const cp = std.unicode.utf8Decode(bytes[i..][0..seq_len]) catch {
                i += 1;
                continue;
            };
            try events.append(gpa, .{ .text = .{ .codepoint = cp } });
            i += seq_len;
        }
    }
    return bytes.len;
}

const EscResult = struct { ev: ?event.Event, len: usize };

fn parseEscape(bytes: []const u8) ?EscResult {
    // bytes[0] == ESC. CSI: ESC [ <final>; SS3: ESC O <final>.
    if (bytes.len < 2) return null;
    const kind = bytes[1];
    if (kind != '[' and kind != 'O') {
        // ESC + other byte: alt-modified key; deliver the key, eat both.
        return .{ .ev = null, .len = 2 };
    }
    if (bytes.len < 3) return null;

    // SGR mouse report: ESC [ < b ; x ; y (M=press/motion | m=release).
    if (kind == '[' and bytes[2] == '<') return parseSgrMouse(bytes);

    // Find the final byte (0x40–0x7e) of the CSI sequence.
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= 0x40 and c <= 0x7e) {
            const key: ?event.Key = switch (c) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                '~' => switch (bytes[2]) {
                    '1', '7' => .home,
                    '4', '8' => .end,
                    '3' => .delete,
                    '5' => .page_up,
                    '6' => .page_down,
                    else => null,
                },
                else => null,
            };
            const ev: ?event.Event = if (key) |k| .{ .key_down = .{ .key = k } } else null;
            return .{ .ev = ev, .len = i + 1 };
        }
        if (i > 16) return .{ .ev = null, .len = i }; // runaway; bail
    }
    return null; // incomplete
}

fn parseSgrMouse(bytes: []const u8) ?EscResult {
    // bytes = ESC [ < btn ; col ; row M|m   (cols/rows 1-based)
    var nums: [3]u32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var i: usize = 3;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= '0' and c <= '9') {
            nums[n] = nums[n] * 10 + (c - '0');
        } else if (c == ';') {
            n += 1;
            if (n >= nums.len) return .{ .ev = null, .len = i + 1 }; // malformed
        } else if (c == 'M' or c == 'm') {
            if (n != 2) return .{ .ev = null, .len = i + 1 }; // malformed
            const btn = nums[0];
            const pos: geometry.Point = .{
                .x = @floatFromInt(nums[1] -| 1),
                .y = @floatFromInt(nums[2] -| 1),
            };
            // Wheel: 64=up, 65=down → reuse key events (scroll as arrows
            // until ScrollView exists; recorded as such in the demo).
            if (btn & 64 != 0) {
                const key: event.Key = if (btn & 1 == 0) .up else .down;
                return .{ .ev = .{ .key_down = .{ .key = key } }, .len = i + 1 };
            }
            const motion = btn & 32 != 0;
            var buttons: event.Buttons = .{};
            switch (btn & 3) {
                0 => buttons.primary = true,
                1 => buttons.middle = true,
                2 => buttons.secondary = true,
                else => {}, // 3 = release marker in legacy; SGR uses 'm'
            }
            const pe: event.PointerEvent = .{ .position = pos, .buttons = buttons };
            const ev: event.Event = if (motion)
                .{ .pointer_move = pe }
            else if (c == 'M')
                .{ .pointer_down = pe }
            else
                .{ .pointer_up = pe };
            return .{ .ev = ev, .len = i + 1 };
        } else {
            return .{ .ev = null, .len = i + 1 }; // malformed
        }
        if (i > 24) return .{ .ev = null, .len = i }; // runaway
    }
    return null; // incomplete
}

// ---------------------------------------------------------------------------
// Parser tests — no TTY required (#8).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseAll(bytes: []const u8) !std.ArrayList(event.Event) {
    var events: std.ArrayList(event.Event) = .empty;
    _ = try parseInput(bytes, &events, testing.allocator);
    return events;
}

test "plain text becomes text events" {
    var evs = try parseAll("hi");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
    try testing.expectEqual(@as(u21, 'h'), evs.items[0].text.codepoint);
    try testing.expectEqual(@as(u21, 'i'), evs.items[1].text.codepoint);
}

test "arrow keys decode from CSI" {
    var evs = try parseAll("\x1b[A\x1b[B\x1b[C\x1b[D");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), evs.items.len);
    try testing.expectEqual(event.Key.up, evs.items[0].key_down.key);
    try testing.expectEqual(event.Key.down, evs.items[1].key_down.key);
    try testing.expectEqual(event.Key.right, evs.items[2].key_down.key);
    try testing.expectEqual(event.Key.left, evs.items[3].key_down.key);
}

test "ctrl-c becomes close_requested" {
    var evs = try parseAll("\x03");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expect(evs.items[0] == .close_requested);
}

test "enter, tab, backspace, delete" {
    var evs = try parseAll("\r\t\x7f\x1b[3~");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(event.Key.enter, evs.items[0].key_down.key);
    try testing.expectEqual(event.Key.tab, evs.items[1].key_down.key);
    try testing.expectEqual(event.Key.backspace, evs.items[2].key_down.key);
    try testing.expectEqual(event.Key.delete, evs.items[3].key_down.key);
}

test "utf8 text decodes whole codepoints" {
    var evs = try parseAll("é");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), evs.items.len);
    try testing.expectEqual(@as(u21, 0xe9), evs.items[0].text.codepoint);
}

test "partial escape sequence is left pending" {
    var events: std.ArrayList(event.Event) = .empty;
    defer events.deinit(testing.allocator);
    const consumed = try parseInput("a\x1b[", &events, testing.allocator);
    try testing.expectEqual(@as(usize, 1), consumed); // only 'a'
    try testing.expectEqual(@as(usize, 1), events.items.len);
}

test "lone escape is the escape key" {
    var evs = try parseAll("\x1b");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(event.Key.escape, evs.items[0].key_down.key);
}

test "SGR mouse press, release, motion decode to pointer events" {
    var evs = try parseAll("\x1b[<0;10;5M\x1b[<0;10;5m\x1b[<32;11;5M");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), evs.items.len);
    try testing.expect(evs.items[0] == .pointer_down);
    try testing.expectEqual(@as(f32, 9), evs.items[0].pointer_down.position.x); // 1-based → 0-based
    try testing.expectEqual(@as(f32, 4), evs.items[0].pointer_down.position.y);
    try testing.expect(evs.items[0].pointer_down.buttons.primary);
    try testing.expect(evs.items[1] == .pointer_up);
    try testing.expect(evs.items[2] == .pointer_move);
}

test "SGR wheel maps to arrow keys for now" {
    var evs = try parseAll("\x1b[<64;3;3M\x1b[<65;3;3M");
    defer evs.deinit(testing.allocator);
    try testing.expectEqual(event.Key.up, evs.items[0].key_down.key);
    try testing.expectEqual(event.Key.down, evs.items[1].key_down.key);
}

test "partial SGR mouse sequence stays pending" {
    var events: std.ArrayList(event.Event) = .empty;
    defer events.deinit(testing.allocator);
    const consumed = try parseInput("\x1b[<0;10", &events, testing.allocator);
    try testing.expectEqual(@as(usize, 0), consumed);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

/// Escape sequence enabling the TUI session: alternate screen, hidden
/// cursor, SGR mouse reporting (1006 — keys and mouse arrive as the VT
/// sequences this module parses). Both platforms emit it; the session's
/// restore path disables it.
pub const enter_tui_seq = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h";
