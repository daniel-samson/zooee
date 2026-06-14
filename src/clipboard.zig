//! Clipboard (#19): a tiny runtime-dispatched interface for reading and writing
//! the system clipboard, behind which the OS pasteboard sits (NSPasteboard,
//! Win32 clipboard, X11 selections, web async Clipboard, OSC 52 on the
//! terminal). An in-memory `MemoryClipboard` fake lets app logic — copy/cut/
//! paste — be unit-tested and driven by the synthetic-event harness (#130)
//! without touching the real pasteboard.
//!
//! Text only for now; rich content (HTML, images) is a later extension that
//! adds vtable entries without reshaping this.

const std = @import("std");

pub const Clipboard = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the clipboard's current text, newly allocated with `gpa`
        /// (caller owns), or null if it holds no text.
        get_text: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8,
        /// Replace the clipboard's contents with `text` (copied internally).
        set_text: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
    };

    pub fn getText(self: Clipboard, gpa: std.mem.Allocator) !?[]u8 {
        return self.vtable.get_text(self.ptr, gpa);
    }

    pub fn setText(self: Clipboard, text: []const u8) !void {
        return self.vtable.set_text(self.ptr, text);
    }
};

/// An in-memory clipboard — the fake used by tests and the headless harness,
/// and a perfectly good real clipboard for a single process.
pub const MemoryClipboard = struct {
    gpa: std.mem.Allocator,
    buf: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) MemoryClipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryClipboard) void {
        if (self.buf) |b| self.gpa.free(b);
        self.buf = null;
    }

    pub fn interface(self: *MemoryClipboard) Clipboard {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Clipboard.VTable = .{ .get_text = getText, .set_text = setText };

    fn getText(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8 {
        const self: *MemoryClipboard = @ptrCast(@alignCast(ptr));
        const b = self.buf orelse return null;
        return try gpa.dupe(u8, b);
    }

    fn setText(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *MemoryClipboard = @ptrCast(@alignCast(ptr));
        const copy = try self.gpa.dupe(u8, text);
        if (self.buf) |b| self.gpa.free(b);
        self.buf = copy;
    }
};

// === Tests ==================================================================

const testing = std.testing;

test "memory clipboard round-trips text and owns its copy" {
    var cb = MemoryClipboard.init(testing.allocator);
    defer cb.deinit();
    const c = cb.interface();

    try testing.expect(null == try c.getText(testing.allocator)); // empty at first

    // The source buffer can be freed after set — the clipboard copied it.
    {
        const tmp = try testing.allocator.dupe(u8, "hello");
        try c.setText(tmp);
        testing.allocator.free(tmp);
    }
    const got = (try c.getText(testing.allocator)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);

    try c.setText("world"); // overwrite frees the old buffer (no leak)
    const got2 = (try c.getText(testing.allocator)).?;
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("world", got2);
}
