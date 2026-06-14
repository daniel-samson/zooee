//! Animation and timer scheduling (#20): the time side of the event-driven
//! redraw model (#5). Pure logic — no platform, no GPU — so it is fully
//! unit-tested here and driven by whatever clock the runner owns.
//!
//! Three pieces:
//! - `Easing` + `lerp`: interpolation helpers for smooth transitions.
//! - `Timer`: one-shot and repeating wakeups (cursor blink, toast dismiss).
//! - `Tween`: a value animated from `from` to `to` over a duration.
//! - `Scheduler`: owns the timers and tweens, advances them by a delta, and —
//!   crucially — answers `nextDeadline()`: how long until the next wakeup, or
//!   `null` when nothing is active. That `null` is the idle guarantee: zero
//!   wakeups and zero redraws when nothing is animating.
//!
//! Time is nanoseconds (`u64` durations, monotonic). The runner samples its
//! own clock and feeds deltas to `tick`; the scheduler never reads a clock.

const std = @import("std");

/// Standard easing curves over a normalized parameter `t` in [0, 1].
pub const Easing = enum {
    linear,
    ease_in, // quadratic
    ease_out, // quadratic
    ease_in_out, // cubic smoothstep
};

/// Evaluate an easing curve. `t` is clamped to [0, 1]; the result is in [0, 1].
pub fn ease(e: Easing, t_in: f32) f32 {
    const t = std.math.clamp(t_in, 0, 1);
    return switch (e) {
        .linear => t,
        .ease_in => t * t,
        .ease_out => 1 - (1 - t) * (1 - t),
        .ease_in_out => t * t * (3 - 2 * t), // smoothstep
    };
}

/// Linear interpolation from `a` to `b` by `t` (t not clamped — callers that
/// need clamping ease `t` first).
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// A scheduled wakeup. One-shot timers fire once then become inactive;
/// repeating timers re-arm by their interval, carrying any overshoot so the
/// cadence does not drift across uneven ticks.
pub const Timer = struct {
    id: u32,
    interval: u64,
    remaining: u64,
    repeating: bool,
    active: bool = true,
    /// Number of times this timer's interval elapsed during the last `tick`.
    /// A long delta can fire a repeating timer more than once.
    fired: u32 = 0,

    /// Advance by `dt`, returning how many times the timer fired this step.
    fn advance(self: *Timer, dt: u64) u32 {
        self.fired = 0;
        if (!self.active) return 0;
        var left = dt;
        while (left >= self.remaining) {
            left -= self.remaining;
            self.fired += 1;
            if (self.repeating and self.interval > 0) {
                self.remaining = self.interval;
            } else {
                self.active = false;
                self.remaining = 0;
                break;
            }
        }
        if (self.active) self.remaining -= left;
        return self.fired;
    }
};

/// A value animated from `from` to `to` over `duration`, shaped by `easing`.
/// Holds its own elapsed time so it can be ticked independently.
pub const Tween = struct {
    id: u32,
    from: f32,
    to: f32,
    duration: u64,
    elapsed: u64 = 0,
    easing: Easing = .linear,
    active: bool = true,

    /// The eased current value. Past the duration it pins to `to`.
    pub fn value(self: *const Tween) f32 {
        if (self.duration == 0) return self.to;
        const t: f32 = @as(f32, @floatFromInt(self.elapsed)) / @as(f32, @floatFromInt(self.duration));
        return lerp(self.from, self.to, ease(self.easing, t));
    }

    /// True once the tween has run its full duration.
    pub fn done(self: *const Tween) bool {
        return self.elapsed >= self.duration;
    }

    fn advance(self: *Tween, dt: u64) void {
        if (!self.active) return;
        self.elapsed +|= dt; // saturating: never wrap
        if (self.done()) self.active = false;
    }
};

/// Owns the active timers and tweens. The runner calls `tick(dt)` each frame
/// (or after sleeping until `nextDeadline`), then reads back which timers fired
/// and what tween values to render. When `nextDeadline` returns null the app is
/// idle and the runner can block until the next input event.
pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    timers: std.ArrayListUnmanaged(Timer) = .empty,
    tweens: std.ArrayListUnmanaged(Tween) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Scheduler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scheduler) void {
        self.timers.deinit(self.gpa);
        self.tweens.deinit(self.gpa);
    }

    fn freshId(self: *Scheduler) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Schedule a one-shot wakeup `delay` ns from now. Returns its id.
    pub fn addTimeout(self: *Scheduler, delay: u64) !u32 {
        const id = self.freshId();
        try self.timers.append(self.gpa, .{ .id = id, .interval = delay, .remaining = delay, .repeating = false });
        return id;
    }

    /// Schedule a repeating wakeup every `interval` ns. Returns its id.
    pub fn addInterval(self: *Scheduler, interval: u64) !u32 {
        const id = self.freshId();
        try self.timers.append(self.gpa, .{ .id = id, .interval = interval, .remaining = interval, .repeating = true });
        return id;
    }

    /// Start a tween; returns its id so the caller can read `tweenValue(id)`.
    pub fn addTween(self: *Scheduler, from: f32, to: f32, duration: u64, easing: Easing) !u32 {
        const id = self.freshId();
        try self.tweens.append(self.gpa, .{ .id = id, .from = from, .to = to, .duration = duration, .easing = easing });
        return id;
    }

    /// Stop and forget a timer or tween by id. Safe if already gone.
    pub fn cancel(self: *Scheduler, id: u32) void {
        for (self.timers.items, 0..) |t, i| {
            if (t.id == id) {
                _ = self.timers.swapRemove(i);
                return;
            }
        }
        for (self.tweens.items, 0..) |t, i| {
            if (t.id == id) {
                _ = self.tweens.swapRemove(i);
                return;
            }
        }
    }

    /// Look up a timer by id (e.g. to read `fired`). Null if gone.
    pub fn timer(self: *Scheduler, id: u32) ?*Timer {
        for (self.timers.items) |*t| if (t.id == id) return t;
        return null;
    }

    /// The current eased value of a tween, or null if gone.
    pub fn tweenValue(self: *Scheduler, id: u32) ?f32 {
        for (self.tweens.items) |*t| if (t.id == id) return t.value();
        return null;
    }

    /// Advance every active timer and tween by `dt`. Returns true if anything
    /// fired or animated — i.e. the frame needs a redraw. Finished one-shot
    /// timers and completed tweens are pruned so they stop contributing to
    /// `nextDeadline` (the idle guarantee).
    pub fn tick(self: *Scheduler, dt: u64) bool {
        var dirty = false;
        for (self.timers.items) |*t| {
            if (t.advance(dt) > 0) dirty = true;
        }
        for (self.tweens.items) |*t| {
            if (t.active) {
                t.advance(dt);
                dirty = true; // an active tween changes its value every tick
            }
        }
        self.prune();
        return dirty;
    }

    fn prune(self: *Scheduler) void {
        var i: usize = 0;
        while (i < self.timers.items.len) {
            if (!self.timers.items[i].active) {
                _ = self.timers.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < self.tweens.items.len) {
            if (!self.tweens.items[i].active) {
                _ = self.tweens.swapRemove(i);
            } else i += 1;
        }
    }

    /// True when nothing is scheduled — the runner may block on input with no
    /// timer wakeup and perform zero redraws.
    pub fn isIdle(self: *const Scheduler) bool {
        return self.timers.items.len == 0 and self.tweens.items.len == 0;
    }

    /// Nanoseconds until the next wakeup, or null when idle. Active tweens want
    /// frame-aligned ticks, so they report 0 (wake on the next frame); timers
    /// report their soonest `remaining`.
    pub fn nextDeadline(self: *const Scheduler) ?u64 {
        if (self.tweens.items.len > 0) return 0;
        var soonest: ?u64 = null;
        for (self.timers.items) |t| {
            if (!t.active) continue;
            if (soonest == null or t.remaining < soonest.?) soonest = t.remaining;
        }
        return soonest;
    }
};

/// Monotonic frame clock: converts a runner's absolute timestamps into the
/// per-frame deltas `Scheduler.tick` wants, so the platform loops don't each
/// reimplement delta bookkeeping. The runner samples `std.time.Instant` (or
/// the platform clock) and feeds the nanosecond reading to `delta`.
pub const FrameClock = struct {
    last: ?u64 = null,

    /// Nanoseconds since the previous `delta` call; 0 on the first frame.
    /// Backward time jumps (clock adjustment) clamp to 0 rather than wrap.
    pub fn delta(self: *FrameClock, now: u64) u64 {
        defer self.last = now;
        const prev = self.last orelse return 0;
        return if (now > prev) now - prev else 0;
    }

    /// Forget the baseline so the next `delta` returns 0 (e.g. after a long
    /// idle block, to avoid a huge catch-up delta).
    pub fn reset(self: *FrameClock) void {
        self.last = null;
    }
};

// === Tests ==================================================================

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "easing endpoints and monotonicity" {
    inline for (.{ Easing.linear, .ease_in, .ease_out, .ease_in_out }) |e| {
        try testing.expectApproxEqAbs(@as(f32, 0), ease(e, 0), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1), ease(e, 1), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0), ease(e, -5), 1e-6); // clamped
        try testing.expectApproxEqAbs(@as(f32, 1), ease(e, 5), 1e-6);
        var prev: f32 = -1;
        var k: f32 = 0;
        while (k <= 1.0001) : (k += 0.05) {
            const v = ease(e, k);
            try testing.expect(v >= prev - 1e-6); // non-decreasing
            prev = v;
        }
    }
    // ease_in_out is symmetric about 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease(.ease_in_out, 0.5), 1e-6);
}

test "one-shot timer fires once then idles" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    const id = try s.addTimeout(100 * ms);
    try testing.expect(!s.tick(40 * ms)); // not yet
    try testing.expectEqual(@as(?u64, 60 * ms), s.nextDeadline());
    try testing.expect(s.tick(70 * ms)); // crosses 100ms
    try testing.expect(s.isIdle()); // pruned
    try testing.expectEqual(@as(?u32, null), if (s.timer(id)) |_| @as(?u32, 1) else null);
    try testing.expectEqual(@as(?u64, null), s.nextDeadline());
}

test "repeating timer keeps cadence across uneven ticks" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    const id = try s.addInterval(50 * ms);
    _ = s.tick(50 * ms);
    try testing.expectEqual(@as(u32, 1), s.timer(id).?.fired);
    // A 120ms delta spans two intervals (100ms) with 20ms left over.
    _ = s.tick(120 * ms);
    try testing.expectEqual(@as(u32, 2), s.timer(id).?.fired);
    try testing.expectEqual(@as(u64, 30 * ms), s.timer(id).?.remaining); // 50-20
    try testing.expect(!s.isIdle()); // repeating stays active
}

test "tween interpolates and completes" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    const id = try s.addTween(0, 100, 200 * ms, .linear);
    try testing.expectEqual(@as(?u64, 0), s.nextDeadline()); // tween wants frames
    _ = s.tick(100 * ms);
    try testing.expectApproxEqAbs(@as(f32, 50), s.tweenValue(id).?, 1e-3);
    _ = s.tick(100 * ms); // reaches end
    try testing.expect(s.isIdle()); // completed tween pruned
    try testing.expectEqual(@as(?f32, null), s.tweenValue(id));
}

test "idle guarantee: empty scheduler reports no wakeup, no redraw" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    try testing.expect(s.isIdle());
    try testing.expectEqual(@as(?u64, null), s.nextDeadline());
    try testing.expect(!s.tick(1000 * ms)); // nothing happens, no redraw
}

test "cancel removes a timer before it fires" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    const id = try s.addTimeout(100 * ms);
    s.cancel(id);
    try testing.expect(s.isIdle());
    try testing.expect(!s.tick(200 * ms));
}

test "multiple timers report the soonest deadline" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    _ = try s.addTimeout(300 * ms);
    _ = try s.addTimeout(80 * ms);
    _ = try s.addInterval(150 * ms);
    try testing.expectEqual(@as(?u64, 80 * ms), s.nextDeadline());
}

test "frame clock yields per-frame deltas and clamps backward jumps" {
    var c: FrameClock = .{};
    try testing.expectEqual(@as(u64, 0), c.delta(1000)); // first frame
    try testing.expectEqual(@as(u64, 500), c.delta(1500));
    try testing.expectEqual(@as(u64, 0), c.delta(1400)); // backward jump clamps
    try testing.expectEqual(@as(u64, 100), c.delta(1500));
    c.reset();
    try testing.expectEqual(@as(u64, 0), c.delta(9999)); // baseline forgotten
}

test "blink-style interval drives a toggling redraw" {
    var s = Scheduler.init(testing.allocator);
    defer s.deinit();
    const blink = try s.addInterval(500 * ms);
    var visible = true;
    var redraws: u32 = 0;
    // Simulate 1.2s in 100ms frames: two toggles at 500ms and 1000ms.
    var elapsed: u64 = 0;
    while (elapsed < 1200 * ms) : (elapsed += 100 * ms) {
        if (s.tick(100 * ms)) {
            const t = s.timer(blink).?;
            if (t.fired > 0) {
                visible = !visible;
                redraws += 1;
            }
        }
    }
    try testing.expectEqual(@as(u32, 2), redraws);
    try testing.expect(visible); // toggled twice from true → back to true
}
