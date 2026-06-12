//! Windows console session (#5, #7): the Windows counterpart of
//! posix_tty.zig — raw input via ReadConsoleInputW, VT-enabled output,
//! size tracking, and crash-safe mode restore (#25).
//!
//! Mirrors the Tty API (init / enableRaw / deinit / size / pumpEvents)
//! so app loops select a session type per-platform and share the rest.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../event.zig");
const geometry = @import("../geometry.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("win32_console.zig is Windows-only");
}

const win = std.os.windows;
const WINAPI: std.builtin.CallingConvention = .winapi;
const HANDLE = win.HANDLE;
const BOOL = win.BOOL;

const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_WINDOW_INPUT: u32 = 0x0008;
const ENABLE_MOUSE_INPUT: u32 = 0x0010;
const ENABLE_QUICK_EDIT_MODE: u32 = 0x0040; // swallows mouse input; must be off
const ENABLE_EXTENDED_FLAGS: u32 = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

const KEY_EVENT: u16 = 0x0001;
const MOUSE_EVENT: u16 = 0x0002;
const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

const MOUSE_MOVED: u32 = 0x0001;
const MOUSE_WHEELED: u32 = 0x0004;

const COORD = extern struct { x: i16, y: i16 };
const SMALL_RECT = extern struct { left: i16, top: i16, right: i16, bottom: i16 };

const KEY_EVENT_RECORD = extern struct {
    key_down: BOOL,
    repeat_count: u16,
    virtual_key_code: u16,
    virtual_scan_code: u16,
    unicode_char: u16,
    control_key_state: u32,
};

const INPUT_RECORD = extern struct {
    event_type: u16,
    _pad: u16 = 0,
    data: extern union {
        key: KEY_EVENT_RECORD,
        mouse: MOUSE_EVENT_RECORD,
        window_size: extern struct { size: COORD },
        raw: [16]u8,
    },
};

const MOUSE_EVENT_RECORD = extern struct {
    position: COORD,
    button_state: u32,
    control_key_state: u32,
    event_flags: u32,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    size: COORD,
    cursor_position: COORD,
    attributes: u16,
    window: SMALL_RECT,
    maximum_window_size: COORD,
};

extern "kernel32" fn GetStdHandle(u32) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GetConsoleMode(HANDLE, *u32) callconv(WINAPI) BOOL;
extern "kernel32" fn SetConsoleMode(HANDLE, u32) callconv(WINAPI) BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(HANDLE, *u32) callconv(WINAPI) BOOL;
extern "kernel32" fn ReadConsoleInputW(HANDLE, [*]INPUT_RECORD, u32, *u32) callconv(WINAPI) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(HANDLE, *CONSOLE_SCREEN_BUFFER_INFO) callconv(WINAPI) BOOL;

/// Stashed for crash-safe restore.
var saved_in_mode: ?u32 = null;
var saved_out_mode: ?u32 = null;
var saved_in: HANDLE = undefined;
var saved_out: HANDLE = undefined;

const vt_input = @import("vt_input.zig");

pub const Console = struct {
    in: HANDLE,
    out: HANDLE,
    last_size: geometry.Size = .{},
    last_buttons: event.Buttons = .{},
    /// Windows Terminal/ConPTY deliver keys AND mouse only as VT byte
    /// sequences (inside KEY_EVENT records) when this mode is on — the
    /// reason MOUSE_EVENT records never arrive there. Textual-style fix:
    /// reconstruct the byte stream and use the shared VT parser. Classic
    /// conhost still sends MOUSE_EVENT records; both paths are handled.
    vt_mode: bool = false,
    /// Carry-over for VT sequences split across reads.
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init() !Console {
        const in = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NotATty;
        const out = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NotATty;
        var mode: u32 = 0;
        if (GetConsoleMode(in, &mode) == .FALSE) return error.NotATty;
        return .{ .in = in, .out = out };
    }

    pub fn enableRaw(self: *Console) !void {
        var in_mode: u32 = 0;
        var out_mode: u32 = 0;
        if (GetConsoleMode(self.in, &in_mode) == .FALSE) return error.BackendFailure;
        if (GetConsoleMode(self.out, &out_mode) == .FALSE) return error.BackendFailure;
        saved_in_mode = in_mode;
        saved_out_mode = out_mode;
        saved_in = self.in;
        saved_out = self.out;

        const raw_in = (in_mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_QUICK_EDIT_MODE)) |
            ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS;
        // Prefer VT input (Windows Terminal mouse only works this way);
        // fall back to legacy records if the console refuses it.
        if (SetConsoleMode(self.in, raw_in | ENABLE_VIRTUAL_TERMINAL_INPUT) != .FALSE) {
            self.vt_mode = true;
        } else if (SetConsoleMode(self.in, raw_in) == .FALSE) {
            return error.BackendFailure;
        }
        // VT processing makes the ANSI present() path work on conhost.
        _ = SetConsoleMode(self.out, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }

    pub fn deinit(self: *Console) void {
        _ = self;
        restoreNow();
    }

    pub fn size(self: *Console) geometry.Size {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(self.out, &info) == .FALSE) return self.last_size;
        return .{
            .width = @floatFromInt(info.window.right - info.window.left + 1),
            .height = @floatFromInt(info.window.bottom - info.window.top + 1),
        };
    }

    /// Drain pending console input into events. Non-blocking.
    pub fn pumpEvents(self: *Console, gpa: std.mem.Allocator) ![]event.Event {
        var events: std.ArrayList(event.Event) = .empty;
        errdefer events.deinit(gpa);

        const now_size = self.size();
        if (now_size.width != self.last_size.width or now_size.height != self.last_size.height) {
            if (self.last_size.width != 0 or self.last_size.height != 0) {
                try events.append(gpa, .{ .resized = .{ .size = now_size } });
            }
            self.last_size = now_size;
        }

        var pending: u32 = 0;
        if (GetNumberOfConsoleInputEvents(self.in, &pending) == .FALSE) return events.toOwnedSlice(gpa);

        var vt_buf: [512]u8 = undefined;
        @memcpy(vt_buf[0..self.pending_len], self.pending[0..self.pending_len]);
        var vt_len: usize = self.pending_len;
        self.pending_len = 0;

        while (pending > 0) {
            var records: [32]INPUT_RECORD = undefined;
            var got: u32 = 0;
            if (ReadConsoleInputW(self.in, &records, @min(pending, records.len), &got) == .FALSE) break;
            if (got == 0) break;
            pending -= got;
            for (records[0..got]) |rec| {
                if (self.vt_mode and rec.event_type == KEY_EVENT and
                    rec.data.key.key_down != .FALSE and rec.data.key.unicode_char != 0)
                {
                    // VT mode: chars ARE the byte stream (one UTF-16 unit
                    // per record; sequences span records). Surrogate
                    // pairs deferred to #19.
                    const ch = rec.data.key.unicode_char;
                    if (ch < 0xD800 or ch > 0xDFFF) {
                        var utf8: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(ch), &utf8) catch 0;
                        if (vt_len + n <= vt_buf.len) {
                            @memcpy(vt_buf[vt_len..][0..n], utf8[0..n]);
                            vt_len += n;
                        }
                    }
                } else {
                    try translateRecord(rec, &self.last_buttons, &events, gpa);
                }
            }
            if (GetNumberOfConsoleInputEvents(self.in, &pending) == .FALSE) break;
        }

        if (vt_len > 0) {
            const consumed = try vt_input.parseInput(vt_buf[0..vt_len], &events, gpa);
            const left = vt_len - consumed;
            if (left > 0 and left <= self.pending.len) {
                @memcpy(self.pending[0..left], vt_buf[consumed..vt_len]);
                self.pending_len = left;
            }
        }
        return events.toOwnedSlice(gpa);
    }
};

fn translateRecord(rec: INPUT_RECORD, last_buttons: *event.Buttons, events: *std.ArrayList(event.Event), gpa: std.mem.Allocator) !void {
    switch (rec.event_type) {
        MOUSE_EVENT => {
            const m = rec.data.mouse;
            const pos: geometry.Point = .{
                .x = @floatFromInt(m.position.x),
                .y = @floatFromInt(m.position.y),
            };
            if (m.event_flags & MOUSE_WHEELED != 0) {
                // High word of button_state is the signed wheel delta.
                const delta: i16 = @bitCast(@as(u16, @truncate(m.button_state >> 16)));
                const key: event.Key = if (delta > 0) .up else .down;
                try events.append(gpa, .{ .key_down = .{ .key = key } });
                return;
            }
            const buttons: event.Buttons = .{
                .primary = m.button_state & 0x1 != 0,
                .secondary = m.button_state & 0x2 != 0,
                .middle = m.button_state & 0x4 != 0,
            };
            const pe: event.PointerEvent = .{ .position = pos, .buttons = buttons };
            if (m.event_flags & MOUSE_MOVED != 0) {
                try events.append(gpa, .{ .pointer_move = pe });
            } else if (@as(u8, @bitCast(buttons)) != 0 and @as(u8, @bitCast(last_buttons.*)) == 0) {
                try events.append(gpa, .{ .pointer_down = pe });
            } else if (@as(u8, @bitCast(buttons)) == 0 and @as(u8, @bitCast(last_buttons.*)) != 0) {
                try events.append(gpa, .{ .pointer_up = pe });
            }
            last_buttons.* = buttons;
        },
        WINDOW_BUFFER_SIZE_EVENT => {
            // Size events are also caught by polling; emitting here keeps
            // latency low. last_size dedup happens at the poll.
        },
        KEY_EVENT => {
            const k = rec.data.key;
            if (k.key_down == .FALSE) return;
            const mods: event.Modifiers = .{
                .shift = (k.control_key_state & 0x0010) != 0,
                .ctrl = (k.control_key_state & 0x000C) != 0,
                .alt = (k.control_key_state & 0x0003) != 0,
            };
            const key: ?event.Key = switch (k.virtual_key_code) {
                0x26 => .up,
                0x28 => .down,
                0x25 => .left,
                0x27 => .right,
                0x24 => .home,
                0x23 => .end,
                0x21 => .page_up,
                0x22 => .page_down,
                0x0D => .enter,
                0x1B => .escape,
                0x09 => .tab,
                0x08 => .backspace,
                0x2E => .delete,
                0x70...0x7B => @enumFromInt(@intFromEnum(event.Key.f1) + (k.virtual_key_code - 0x70)),
                else => null,
            };
            if (key) |kk| {
                try events.append(gpa, .{ .key_down = .{ .key = kk, .mods = mods } });
                return;
            }
            const ch = k.unicode_char;
            if (ch == 0x03 or (mods.ctrl and (ch == 'c' or ch == 'C'))) {
                try events.append(gpa, .{ .close_requested = event.main_window });
                return;
            }
            if (ch >= 0x20 and ch < 0xD800) { // BMP, non-control; surrogates later (#19)
                try events.append(gpa, .{ .text = .{ .codepoint = ch, .mods = mods } });
            } else if (ch != 0 and ch < 0x20 and mods.ctrl) {
                try events.append(gpa, .{ .text = .{ .codepoint = ch + 'a' - 1, .mods = .{ .ctrl = true } } });
            }
        },
        else => {},
    }
}

/// Restore console modes (idempotent; raw API calls only).
pub fn restoreNow() void {
    if (saved_in_mode) |m| {
        _ = SetConsoleMode(saved_in, m);
        saved_in_mode = null;
    }
    if (saved_out_mode) |m| {
        _ = SetConsoleMode(saved_out, m);
        saved_out_mode = null;
        const seq = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l";
        var written: u32 = 0;
        _ = WriteFileShim(saved_out, seq, seq.len, &written);
    }
}

extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(WINAPI) BOOL;
fn WriteFileShim(h: HANDLE, buf: [*]const u8, len: usize, written: *u32) BOOL {
    return WriteFile(h, buf, @intCast(len), written, null);
}

/// Panic handler restoring the console before the trace prints (#25).
pub fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreNow();
    std.debug.defaultPanic(msg, first_trace_addr);
}

test "key translation: arrows and text" {
    var test_buttons: event.Buttons = .{};
    var events: std.ArrayList(event.Event) = .empty;
    defer events.deinit(std.testing.allocator);

    const down_arrow: INPUT_RECORD = .{
        .event_type = KEY_EVENT,
        .data = .{ .key = .{
            .key_down = .TRUE,
            .repeat_count = 1,
            .virtual_key_code = 0x28,
            .virtual_scan_code = 0,
            .unicode_char = 0,
            .control_key_state = 0,
        } },
    };
    try translateRecord(down_arrow, &test_buttons, &events, std.testing.allocator);
    try std.testing.expectEqual(event.Key.down, events.items[0].key_down.key);

    const q_key: INPUT_RECORD = .{
        .event_type = KEY_EVENT,
        .data = .{ .key = .{
            .key_down = .TRUE,
            .repeat_count = 1,
            .virtual_key_code = 'Q',
            .virtual_scan_code = 0,
            .unicode_char = 'q',
            .control_key_state = 0,
        } },
    };
    try translateRecord(q_key, &test_buttons, &events, std.testing.allocator);
    try std.testing.expectEqual(@as(u21, 'q'), events.items[1].text.codepoint);

    // key-up must be ignored
    var up_rec = q_key;
    up_rec.data.key.key_down = .FALSE;
    try translateRecord(up_rec, &test_buttons, &events, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
}

test "mouse translation: press, release, wheel" {
    var test_buttons: event.Buttons = .{};
    var events: std.ArrayList(event.Event) = .empty;
    defer events.deinit(std.testing.allocator);

    var press: INPUT_RECORD = .{
        .event_type = MOUSE_EVENT,
        .data = .{ .mouse = .{
            .position = .{ .x = 10, .y = 5 },
            .button_state = 0x1,
            .control_key_state = 0,
            .event_flags = 0,
        } },
    };
    try translateRecord(press, &test_buttons, &events, std.testing.allocator);
    try std.testing.expect(events.items[0] == .pointer_down);
    try std.testing.expectEqual(@as(f32, 10), events.items[0].pointer_down.position.x);

    press.data.mouse.button_state = 0;
    try translateRecord(press, &test_buttons, &events, std.testing.allocator);
    try std.testing.expect(events.items[1] == .pointer_up);

    press.data.mouse.event_flags = MOUSE_WHEELED;
    press.data.mouse.button_state = @as(u32, @as(u16, @bitCast(@as(i16, 120)))) << 16;
    try translateRecord(press, &test_buttons, &events, std.testing.allocator);
    try std.testing.expectEqual(event.Key.up, events.items[2].key_down.key);
}

pub const enter_tui_seq = vt_input.enter_tui_seq;

test "vt mode: SGR mouse bytes inside KEY_EVENT records decode to pointer events" {
    const con: Console = .{ .in = undefined, .out = undefined, .vt_mode = true };
    var events: std.ArrayList(event.Event) = .empty;
    defer events.deinit(std.testing.allocator);

    // Simulate the per-record byte handling for "\x1b[<0;10;5M".
    var vt_buf: [64]u8 = undefined;
    var vt_len: usize = 0;
    for ("\x1b[<0;10;5M") |byte| {
        const rec: INPUT_RECORD = .{
            .event_type = KEY_EVENT,
            .data = .{ .key = .{
                .key_down = .TRUE,
                .repeat_count = 1,
                .virtual_key_code = 0,
                .virtual_scan_code = 0,
                .unicode_char = byte,
                .control_key_state = 0,
            } },
        };
        // Mirror pumpEvents' VT branch.
        if (con.vt_mode and rec.event_type == KEY_EVENT and
            rec.data.key.key_down != .FALSE and rec.data.key.unicode_char != 0)
        {
            vt_buf[vt_len] = @intCast(rec.data.key.unicode_char);
            vt_len += 1;
        }
    }
    _ = try vt_input.parseInput(vt_buf[0..vt_len], &events, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .pointer_down);
    try std.testing.expectEqual(@as(f32, 9), events.items[0].pointer_down.position.x);
}
