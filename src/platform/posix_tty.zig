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
        installSignalHandlers(); // restore on SIGINT/SIGTERM/SIGHUP (#25)
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
        // Disable mouse reporting, leave alternate screen, show cursor,
        // reset attributes. Raw syscall: signal/panic-safe only.
        const out: []const u8 = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l";
        _ = posix.system.write(posix.STDOUT_FILENO, out.ptr, out.len);
    }
}

/// Restore the terminal then die with the signal's default disposition (#25),
/// so a `kill`/SIGHUP/SIGTERM doesn't leave the shell in raw + alt-screen mode.
/// Async-signal-safe: restoreNow uses only raw syscalls.
fn onTerminate(_: c_int) callconv(.c) void {
    restoreNow();
    std.c._exit(130); // shell is restored; raw _exit (async-signal-safe)
}

/// Install SIGINT/SIGTERM/SIGHUP handlers that restore the terminal (#25).
/// Ctrl-C in raw mode arrives as a byte event (ISIG off), so these fire for
/// external `kill`s and hangups. Called from `enableRaw`. The handler fn is
/// `@ptrCast` because the signal-number param type is platform-specific
/// (c_int on Linux, an enum in macOS's libc bindings).
pub fn installSignalHandlers() void {
    const act: posix.Sigaction = .{ .handler = .{ .handler = @ptrCast(&onTerminate) }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}

test "restoreNow is idempotent with no saved terminal" {
    saved_termios = null;
    restoreNow(); // must not touch the tty / crash when nothing was entered
    restoreNow();
    try std.testing.expect(saved_termios == null);
}

pub const vt_input = @import("vt_input.zig");
pub const parseInput = vt_input.parseInput;

pub const enter_tui_seq = vt_input.enter_tui_seq;

/// Panic handler that restores the terminal before the default panic
/// prints its stack trace (#25). Install in the app root:
///   pub const panic = std.debug.FullPanic(zooee.platform.posix_tty.panicRestore);
pub fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreNow();
    std.debug.defaultPanic(msg, first_trace_addr);
}
