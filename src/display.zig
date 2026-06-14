//! Display robustness (#27): the logic that keeps a window correct across DPI
//! changes (dragged between monitors), resize storms, and monitor hot-plug.
//!
//! The OS can fire resize/scale events far faster than frames — a drag-resize
//! emits one per mouse move, a monitor change re-scales mid-stream. Relaying
//! out on every one wastes work and can thrash the glyph atlas. `Coalescer`
//! absorbs the burst and yields **at most one** effective update per frame, at
//! the final size and scale, and flags when the backing scale changed so the
//! caller regenerates the glyph atlas (and re-snaps layout) only then.
//!
//! Pure logic — no platform — so the run loops feed it OS events and the whole
//! policy is unit- and harness-tested deterministically.

const std = @import("std");
const geometry = @import("geometry.zig");

const Size = geometry.Size;

/// The display metrics a frame renders against: logical size + backing scale
/// (device pixels per logical point; 2.0 on a Retina display).
pub const Metrics = struct {
    size: Size,
    scale: f32 = 1,

    pub fn approxEql(a: Metrics, b: Metrics) bool {
        return @abs(a.size.width - b.size.width) < 0.5 and
            @abs(a.size.height - b.size.height) < 0.5 and
            @abs(a.scale - b.scale) < 1e-4;
    }
};

/// Coalesces a burst of resize/DPI events into one update per `take`. The run
/// loop calls `postSize`/`postScale` for every OS event, then once per frame
/// calls `take`: it returns the final metrics if anything actually changed
/// (else null → no relayout, no redraw). `scale_changed` tells the caller to
/// regenerate the glyph atlas at the new scale.
pub const Coalescer = struct {
    /// The metrics currently rendered against.
    current: Metrics,
    /// The latest posted metrics awaiting a frame; null when nothing pending.
    pending: ?Metrics = null,
    /// Set by `take` when the scale differed from `current` — the signal to
    /// regenerate the glyph atlas and re-snap layout.
    scale_changed: bool = false,
    /// Monotonic count of effective updates applied (debugging/telemetry).
    generation: u64 = 0,

    pub fn init(initial: Metrics) Coalescer {
        return .{ .current = initial };
    }

    /// Record a new size from an OS resize event (keeps the current scale).
    pub fn postSize(self: *Coalescer, w: f32, h: f32) void {
        const base = self.pending orelse self.current;
        self.post(.{ .size = .{ .width = w, .height = h }, .scale = base.scale });
    }

    /// Record a new backing scale from a DPI-change event (keeps the size).
    pub fn postScale(self: *Coalescer, scale: f32) void {
        const base = self.pending orelse self.current;
        self.post(.{ .size = base.size, .scale = scale });
    }

    /// Record a full metrics update (size + scale together).
    pub fn post(self: *Coalescer, m: Metrics) void {
        self.pending = m;
    }

    /// True if a relayout is owed (the pending metrics differ from current).
    pub fn dirty(self: *const Coalescer) bool {
        const p = self.pending orelse return false;
        return !p.approxEql(self.current);
    }

    /// Apply the coalesced update for this frame. Returns the new metrics once
    /// (and clears pending), or null if nothing effectively changed. Sets
    /// `scale_changed` when the backing scale moved.
    pub fn take(self: *Coalescer) ?Metrics {
        const p = self.pending orelse return null;
        self.pending = null;
        if (p.approxEql(self.current)) return null;
        self.scale_changed = @abs(p.scale - self.current.scale) >= 1e-4;
        self.current = p;
        self.generation += 1;
        return p;
    }
};

// === Tests ==================================================================

const testing = std.testing;

test "resize storm coalesces to one update at the final size" {
    var c = Coalescer.init(.{ .size = .{ .width = 100, .height = 60 }, .scale = 1 });
    // A burst of resizes within one frame (drag-resize emits one per move).
    var w: f32 = 101;
    while (w <= 140) : (w += 1) c.postSize(w, 80);
    try testing.expect(c.dirty());
    const m = c.take().?; // exactly one effective update…
    try testing.expectApproxEqAbs(@as(f32, 140), m.size.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 80), m.size.height, 1e-3);
    try testing.expect(!c.scale_changed); // size-only, atlas stays
    try testing.expectEqual(@as(?Metrics, null), c.take()); // …and no more
    try testing.expectEqual(@as(u64, 1), c.generation);
}

test "DPI change flags an atlas regeneration" {
    var c = Coalescer.init(.{ .size = .{ .width = 100, .height = 60 }, .scale = 1 });
    c.postScale(2); // dragged onto a Retina monitor
    const m = c.take().?;
    try testing.expectApproxEqAbs(@as(f32, 2), m.scale, 1e-3);
    try testing.expect(c.scale_changed); // regenerate glyph atlas + re-snap
    try testing.expectApproxEqAbs(@as(f32, 100), m.size.width, 1e-3); // size kept
}

test "no-op when nothing changed: zero relayouts, zero redraws" {
    var c = Coalescer.init(.{ .size = .{ .width = 100, .height = 60 }, .scale = 2 });
    c.postSize(100, 60); // same size
    c.postScale(2); // same scale
    try testing.expect(!c.dirty());
    try testing.expectEqual(@as(?Metrics, null), c.take());
    try testing.expectEqual(@as(u64, 0), c.generation);
}

test "combined size + scale change in one burst" {
    var c = Coalescer.init(.{ .size = .{ .width = 100, .height = 60 }, .scale = 1 });
    // Monitor change: both size and scale move; only the last pair survives.
    c.postSize(200, 120);
    c.postScale(2);
    c.postSize(220, 130);
    const m = c.take().?;
    try testing.expectApproxEqAbs(@as(f32, 220), m.size.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2), m.scale, 1e-3);
    try testing.expect(c.scale_changed);
}
