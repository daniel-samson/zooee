//! Native menu model (#129, menus half) — a backend-agnostic description of a
//! menu that the platform layers turn into an OS-native menu (macOS `NSMenu`,
//! Windows `HMENU`). The app builds an `Item` tree and asks a window to pop it
//! up as a context menu (`window.popupMenu`) — the OS draws it, handles keyboard
//! and accessibility, and returns the chosen item's `id`.
//!
//! v1 scope: the model (labels, separators, submenus, accelerators, enabled +
//! checked state) and synchronous context-menu popup on macOS/Windows. X11 has
//! no toolkit-agnostic native menu, so it falls back (see the platform layer) to
//! the in-window overlay surfaces (#17). Deferred (same issue): the persistent
//! app menu bar and native file dialogs' save variants.

const std = @import("std");

/// One menu entry. A plain item carries a non-zero `id` returned when chosen;
/// `separator` items are dividers; an item with a non-empty `submenu` opens a
/// child menu (its own `id` is ignored).
pub const Item = struct {
    /// Display text. Use "&File" style ampersand mnemonics on Windows; macOS
    /// ignores them. Empty for separators.
    label: [:0]const u8 = "",
    /// Command id reported back when this item is chosen. Must be non-zero for
    /// selectable items (0 is the "nothing chosen" sentinel). Ignored for
    /// separators and submenu parents.
    id: u32 = 0,
    /// Greyed-out and unselectable when false.
    enabled: bool = true,
    /// Draws a checkmark (toggle/radio state).
    checked: bool = false,
    /// A divider line; `label`/`id` ignored.
    separator: bool = false,
    /// Accelerator hint (e.g. "Cmd+S"). Display-only in v1 — the OS shows it;
    /// actual key dispatch stays with the app's event loop.
    accelerator: [:0]const u8 = "",
    /// Child entries; non-empty makes this a submenu parent.
    submenu: []const Item = &.{},
};

/// A separator entry (convenience).
pub const separator: Item = .{ .separator = true };

/// Total selectable (non-separator, non-submenu-parent) items in a tree,
/// recursing into submenus. Useful for tests and sanity checks.
pub fn countSelectable(items: []const Item) usize {
    var n: usize = 0;
    for (items) |it| {
        if (it.separator) continue;
        if (it.submenu.len > 0) {
            n += countSelectable(it.submenu);
        } else {
            n += 1;
        }
    }
    return n;
}

/// Find the item with the given `id` anywhere in the tree (depth-first), or
/// null. Ignores id 0.
pub fn findById(items: []const Item, id: u32) ?*const Item {
    if (id == 0) return null;
    for (items) |*it| {
        if (it.submenu.len > 0) {
            if (findById(it.submenu, id)) |found| return found;
        } else if (it.id == id) {
            return it;
        }
    }
    return null;
}

/// True if `id` names a selectable item that is currently enabled. The platform
/// popup also enforces this; exposed for the app's own validation/routing.
pub fn isEnabled(items: []const Item, id: u32) bool {
    const it = findById(items, id) orelse return false;
    return it.enabled;
}

// === Tests ==================================================================

const testing = std.testing;

const sample = [_]Item{
    .{ .label = "Open", .id = 1, .accelerator = "Cmd+O" },
    .{ .label = "Save", .id = 2, .enabled = false },
    separator,
    .{ .label = "Recent", .submenu = &.{
        .{ .label = "a.txt", .id = 10 },
        .{ .label = "b.txt", .id = 11 },
    } },
    .{ .label = "Word Wrap", .id = 3, .checked = true },
};

test "countSelectable skips separators and submenu parents, recurses" {
    // Open, Save, a.txt, b.txt, Word Wrap = 5 (separator + "Recent" parent excluded).
    try testing.expectEqual(@as(usize, 5), countSelectable(&sample));
}

test "findById locates top-level and nested items" {
    try testing.expectEqualStrings("Open", findById(&sample, 1).?.label);
    try testing.expectEqualStrings("b.txt", findById(&sample, 11).?.label);
    try testing.expect(findById(&sample, 999) == null);
    try testing.expect(findById(&sample, 0) == null); // sentinel never matches
}

test "isEnabled reflects item state" {
    try testing.expect(isEnabled(&sample, 1)); // Open
    try testing.expect(!isEnabled(&sample, 2)); // Save (disabled)
    try testing.expect(!isEnabled(&sample, 999)); // missing
}

test "checked and accelerator carried on the model" {
    try testing.expect(findById(&sample, 3).?.checked);
    try testing.expectEqualStrings("Cmd+O", findById(&sample, 1).?.accelerator);
}
