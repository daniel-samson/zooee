//! Framework-owned text-field state (#319): the live `TextEdit` (buffer/caret/
//! selection) for each `TextInput`, keyed by the widget's stable `id`. Persists
//! across frames (unlike the per-frame layout arena), so the widget layer only
//! seeds the initial value and the app loop drives editing.
//!
//! A leaf module (imports only text_edit) so both ui.zig and app.zig can use it
//! without an import cycle. Single-threaded UI loop, so the globals are fine.

const std = @import("std");
const TextEdit = @import("text_edit.zig").TextEdit;

// Field buffers are tiny and few; page_allocator keeps this dependency-free and
// version-stable. State lives for the process, so nothing is freed per frame.
const gpa = std.heap.page_allocator;

var fields: std.AutoHashMapUnmanaged(u32, TextEdit) = .empty;

/// Ensure field `id` exists, seeding it with `seed` only on first creation
/// (uncontrolled-input semantics — later prop changes don't clobber edits).
pub fn ensure(id: u32, seed: []const u8) void {
    if (fields.contains(id)) return;
    var te: TextEdit = .{};
    te.setText(gpa, seed) catch {};
    fields.put(gpa, id, te) catch {};
}

/// The mutable edit state for `id`, or null if it was never `ensure`d.
pub fn get(id: u32) ?*TextEdit {
    return fields.getPtr(id);
}

/// Current text of field `id` (empty if unknown). Used by the renderer and the
/// public `app.textInputValue` accessor.
pub fn value(id: u32) []const u8 {
    return if (fields.getPtr(id)) |te| te.text() else "";
}

/// Allocator for edit mutations (buffer growth). Stable for the process.
pub fn allocator() std.mem.Allocator {
    return gpa;
}

/// Drop all field state (tests, for isolation between cases).
pub fn reset() void {
    var it = fields.iterator();
    while (it.next()) |e| e.value_ptr.deinit(gpa);
    fields.clearAndFree(gpa);
}
