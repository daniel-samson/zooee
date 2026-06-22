//! Editable-text model (#319): the buffer + caret + selection logic behind the
//! `TextInput` widget and browser-like Cut/Copy/Paste/Select-All. Pure logic —
//! no rendering or IO — so it is unit-tested directly here; the app loop keeps
//! one `TextEdit` per focused field and drives it from key / clipboard events.
//!
//! All offsets are byte indices into a UTF-8 buffer and always land on a
//! codepoint boundary. The selection is the (possibly empty) range between
//! `anchor` and `caret`; `anchor == null` means "no selection, just a caret".

const std = @import("std");

pub const TextEdit = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Caret byte offset (UTF-8 boundary). The moving end of a selection.
    caret: usize = 0,
    /// Selection anchor byte offset, or null when there is no selection. The
    /// fixed end while shift-extending.
    anchor: ?usize = null,

    pub fn deinit(self: *TextEdit, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
        self.* = undefined;
    }

    pub fn text(self: *const TextEdit) []const u8 {
        return self.buf.items;
    }

    /// Normalized selection range, or null when nothing is selected (no anchor
    /// or an empty selection).
    pub fn selection(self: *const TextEdit) ?struct { lo: usize, hi: usize } {
        const a = self.anchor orelse return null;
        if (a == self.caret) return null;
        return .{ .lo = @min(a, self.caret), .hi = @max(a, self.caret) };
    }

    pub fn selectedText(self: *const TextEdit) []const u8 {
        const s = self.selection() orelse return self.buf.items[self.caret..self.caret];
        return self.buf.items[s.lo..s.hi];
    }

    /// Replace the whole buffer (e.g. the widget's bound value changed), placing
    /// the caret at the end and clearing the selection.
    pub fn setText(self: *TextEdit, gpa: std.mem.Allocator, new_text: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(gpa, new_text);
        self.caret = self.buf.items.len;
        self.anchor = null;
    }

    /// Insert UTF-8 text at the caret, replacing the selection first if any.
    /// Caret lands just past the inserted text; selection is cleared.
    pub fn insert(self: *TextEdit, gpa: std.mem.Allocator, s: []const u8) !void {
        self.deleteSelection(gpa);
        try self.buf.insertSlice(gpa, self.caret, s);
        self.caret += s.len;
        self.anchor = null;
    }

    /// Delete the selection if present; else the codepoint before the caret
    /// (Backspace).
    pub fn backspace(self: *TextEdit, gpa: std.mem.Allocator) void {
        if (self.selection() != null) return self.deleteSelection(gpa);
        if (self.caret == 0) return;
        const start = prevBoundary(self.buf.items, self.caret);
        self.buf.replaceRange(gpa, start, self.caret - start, &.{}) catch unreachable;
        self.caret = start;
        self.anchor = null;
    }

    /// Delete the selection if present; else the codepoint after the caret
    /// (Delete / forward-delete).
    pub fn deleteForward(self: *TextEdit, gpa: std.mem.Allocator) void {
        if (self.selection() != null) return self.deleteSelection(gpa);
        if (self.caret >= self.buf.items.len) return;
        const end = nextBoundary(self.buf.items, self.caret);
        self.buf.replaceRange(gpa, self.caret, end - self.caret, &.{}) catch unreachable;
        self.anchor = null;
    }

    /// Remove the current selection (if any), collapsing the caret to its start.
    pub fn deleteSelection(self: *TextEdit, gpa: std.mem.Allocator) void {
        const s = self.selection() orelse return;
        self.buf.replaceRange(gpa, s.lo, s.hi - s.lo, &.{}) catch unreachable;
        self.caret = s.lo;
        self.anchor = null;
    }

    // --- caret movement ----------------------------------------------------
    // `extend` = hold Shift: keep/start the anchor and move only the caret.
    // Without extend, an existing selection collapses to the appropriate edge.

    pub fn moveLeft(self: *TextEdit, extend: bool) void {
        if (!extend) {
            if (self.selection()) |s| {
                self.caret = s.lo;
                self.anchor = null;
                return;
            }
        } else self.beginExtend();
        if (self.caret > 0) self.caret = prevBoundary(self.buf.items, self.caret);
        self.normalizeAnchor(extend);
    }

    pub fn moveRight(self: *TextEdit, extend: bool) void {
        if (!extend) {
            if (self.selection()) |s| {
                self.caret = s.hi;
                self.anchor = null;
                return;
            }
        } else self.beginExtend();
        if (self.caret < self.buf.items.len) self.caret = nextBoundary(self.buf.items, self.caret);
        self.normalizeAnchor(extend);
    }

    pub fn moveHome(self: *TextEdit, extend: bool) void {
        if (extend) self.beginExtend() else self.anchor = null;
        self.caret = 0;
        self.normalizeAnchor(extend);
    }

    pub fn moveEnd(self: *TextEdit, extend: bool) void {
        if (extend) self.beginExtend() else self.anchor = null;
        self.caret = self.buf.items.len;
        self.normalizeAnchor(extend);
    }

    pub fn selectAll(self: *TextEdit) void {
        self.anchor = 0;
        self.caret = self.buf.items.len;
    }

    /// Move the caret to an explicit byte offset (e.g. a mouse click resolved to
    /// a caret position). `extend` keeps the anchor for shift-click.
    pub fn setCaret(self: *TextEdit, offset: usize, extend: bool) void {
        if (extend) self.beginExtend() else self.anchor = null;
        self.caret = @min(offset, self.buf.items.len);
        self.normalizeAnchor(extend);
    }

    fn beginExtend(self: *TextEdit) void {
        if (self.anchor == null) self.anchor = self.caret;
    }

    fn normalizeAnchor(self: *TextEdit, extend: bool) void {
        if (!extend) self.anchor = null;
    }
};

/// Byte offset of the start of the codepoint preceding `i` (UTF-8).
fn prevBoundary(buf: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (buf[j] & 0xC0 != 0x80) break; // not a continuation byte → boundary
    }
    return j;
}

/// Byte offset of the start of the codepoint following the one at `i` (UTF-8).
fn nextBoundary(buf: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(buf[i]) catch 1;
    return @min(i + len, buf.len);
}

// === Tests ==================================================================

const testing = std.testing;

fn expectState(te: *const TextEdit, txt: []const u8, caret: usize, sel: ?[2]usize) !void {
    try testing.expectEqualStrings(txt, te.text());
    try testing.expectEqual(caret, te.caret);
    if (sel) |want| {
        const s = te.selection() orelse return error.NoSelection;
        try testing.expectEqual(want[0], s.lo);
        try testing.expectEqual(want[1], s.hi);
    } else {
        try testing.expect(te.selection() == null);
    }
}

test "insert and caret advance" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.insert(gpa, "hi");
    try te.insert(gpa, "!");
    try expectState(&te, "hi!", 3, null);
}

test "backspace deletes the codepoint before the caret, not a byte (UTF-8)" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.insert(gpa, "é"); // 2 bytes (U+00E9)
    try testing.expectEqual(@as(usize, 2), te.caret);
    te.backspace(gpa);
    try expectState(&te, "", 0, null);
}

test "moveLeft/Right step whole codepoints" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "a€b"); // '€' is 3 bytes
    te.moveHome(false);
    try testing.expectEqual(@as(usize, 0), te.caret);
    te.moveRight(false); // past 'a'
    try testing.expectEqual(@as(usize, 1), te.caret);
    te.moveRight(false); // past '€'
    try testing.expectEqual(@as(usize, 4), te.caret);
    te.moveLeft(false); // back over '€'
    try testing.expectEqual(@as(usize, 1), te.caret);
}

test "shift-extend builds a selection; typing replaces it" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "hello");
    te.moveHome(false);
    te.moveRight(true);
    te.moveRight(true); // select "he"
    try expectState(&te, "hello", 2, .{ 0, 2 });
    try testing.expectEqualStrings("he", te.selectedText());
    try te.insert(gpa, "HE"); // replaces selection
    try expectState(&te, "HEllo", 2, null);
}

test "selectAll then backspace clears the buffer" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "delete me");
    te.selectAll();
    try testing.expectEqualStrings("delete me", te.selectedText());
    te.backspace(gpa);
    try expectState(&te, "", 0, null);
}

test "moveLeft collapses an existing selection to its left edge" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "abcd");
    te.moveHome(false);
    te.moveRight(true);
    te.moveRight(true); // select "ab", caret at 2
    te.moveLeft(false); // collapse to left edge
    try expectState(&te, "abcd", 0, null);
}

test "deleteForward removes the codepoint after the caret" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "abc");
    te.moveHome(false);
    te.deleteForward(gpa);
    try expectState(&te, "bc", 0, null);
}

test "setCaret with extend makes a shift-click selection" {
    const gpa = testing.allocator;
    var te: TextEdit = .{};
    defer te.deinit(gpa);
    try te.setText(gpa, "abcdef"); // caret at 6
    te.setCaret(2, true); // shift-click at offset 2
    try expectState(&te, "abcdef", 2, .{ 2, 6 });
}
