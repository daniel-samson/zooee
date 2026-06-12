//! POSIX terminal session (#5, #7): raw mode, alternate screen, input
//! parsing, size tracking, and crash-safe restore (#25).
//!
//! Restore discipline: `enableRaw` stashes the original termios in a
//! global so `restoreNow` can be called from a panic handler — the
//! terminal must be sane before a stack trace prints. Apps install it
//! via `zooee.platform.posix_tty.panicRestore` (see demo main.zig).
//!
//! The input parser is a plain function over bytes (`parseInput`) so it
//! is unit-testable without a TTY (#8). Windows console input is a
//! follow-up (#7) — this file is POSIX-only.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../event.zig");
const geometry = @import("../geometry.zig");

comptime {
    if (builtin.os.tag == .windows) @compileError("posix_tty.zig is POSIX-only");
}

const posix = std.posix;

/// Stashed state for crash-safe restore. Single-terminal by nature.
var saved_termios: ?posix.termios = null;
var raw_fd: posix.fd_t = 0;

pub const Tty = struct {
    fd: posix.fd_t,
    last_size: geometry.Size = .{},
    /// Carry-over for escape sequences split across reads.
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init() !Tty {
        const fd: posix.fd_t = posix.STDIN_FILENO;
        // TIOCGWINSZ succeeding is the tty probe: isatty is gone in 0.16,
        // and tcgetattr on a non-tty trips unexpectedErrno noise in debug.
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS) return error.NotATty;
        return .{ .fd = fd };
    }

    /// Enter raw mode. Pair with `deinit`; a panic handler should call
    /// `restoreNow` (see `panicRestore`).
    pub fn enableRaw(self: *Tty) !void {
        const orig = try posix.tcgetattr(self.fd);
        saved_termios = orig;
        raw_fd = self.fd;

        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false; // we deliver ctrl-c as an event
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        // Non-blocking reads: read() returns immediately with what's there.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.fd, .NOW, raw);
    }

    pub fn deinit(self: *Tty) void {
        _ = self;
        restoreNow();
    }

    /// Current terminal size in cells.
    pub fn size(self: *Tty) geometry.Size {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(self.fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS) return self.last_size;
        return .{
            .width = @floatFromInt(ws.col),
            .height = @floatFromInt(ws.row),
        };
    }

    /// Drain available input into events. Non-blocking. Also emits a
    /// `resized` event when the terminal size changed since last poll
    /// (polling beats SIGWINCH for signal-safety; #27 covers storms).
    pub fn pumpEvents(self: *Tty, gpa: std.mem.Allocator) ![]event.Event {
        var events: std.ArrayList(event.Event) = .empty;
        errdefer events.deinit(gpa);

        const now_size = self.size();
        if (now_size.width != self.last_size.width or now_size.height != self.last_size.height) {
            if (self.last_size.width != 0 or self.last_size.height != 0) {
                try events.append(gpa, .{ .resized = .{ .size = now_size } });
            }
            self.last_size = now_size;
        }

        var buf: [256]u8 = undefined;
        @memcpy(buf[0..self.pending_len], self.pending[0..self.pending_len]);
        var len = self.pending_len;
        self.pending_len = 0;
        const n = posix.read(self.fd, buf[len..]) catch 0;
        len += n;

        const consumed = try parseInput(buf[0..len], &events, gpa);
        const left = len - consumed;
        if (left > 0 and left <= self.pending.len) {
            @memcpy(self.pending[0..left], buf[consumed..len]);
            self.pending_len = left;
        }
        return events.toOwnedSlice(gpa);
    }
};

/// Restore the terminal immediately (idempotent, signal/panic-safe-ish:
/// only direct syscalls and a static buffer).
pub fn restoreNow() void {
    if (saved_termios) |orig| {
        posix.tcsetattr(raw_fd, .NOW, orig) catch {};
        saved_termios = null;
        // Leave alternate screen, show cursor, reset attributes.
        // Raw syscall: must stay signal/panic-safe (no Io, no allocation).
        const out: []const u8 = "\x1b[0m\x1b[?25h\x1b[?1049l";
        _ = posix.system.write(posix.STDOUT_FILENO, out.ptr, out.len);
    }
}

/// Panic handler that restores the terminal before the default panic
/// prints its stack trace (#25). Install in the app root:
///   pub const panic = std.debug.FullPanic(zooee.platform.posix_tty.panicRestore);
pub fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreNow();
    std.debug.defaultPanic(msg, first_trace_addr);
}

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
