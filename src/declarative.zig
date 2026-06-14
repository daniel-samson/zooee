//! Declarative animation (#125): the CSS-like, high-level layer a component
//! library exposes on top of the driver (#20) and the animatable primitives
//! (#121/#118/#95). Two shapes, mirroring CSS:
//!
//! - `Transition`: "animate this value over `duration` `easing` when it
//!   changes." You set a target; if it differs from the current target the
//!   transition re-bases from the value-in-flight and eases to the new target.
//!   This is the read-modify model components want: render reads `value()`,
//!   the model sets `retarget(...)`, the frame loop calls `tick(dt)`.
//! - `Keyframes`: a timeline of stops at offsets 0→1, with `duration`,
//!   iteration count (finite or `infinite`), direction (normal / reverse /
//!   alternate), fill mode, and play/pause/cancel.
//!
//! Pure logic — no platform, no GPU, no clock. Time is nanoseconds (`u64`),
//! fed in as per-frame deltas exactly like `anim.Scheduler.tick`. Both types
//! report whether they're still animating so the loop keeps the idle guarantee:
//! once a transition settles or a finite timeline ends, `tick` returns false and
//! nothing schedules another frame.
//!
//! The backends stay animation-unaware: they're re-invoked each tick with the
//! interpolated values these produce. Color interpolates per-channel in straight
//! sRGB space — the same convention `style.Gradient` uses, so a tweened color
//! and a gradient stop at the same point agree.

const std = @import("std");
const anim = @import("anim.zig");
const style = @import("style.zig");

const Easing = anim.Easing;
const Color = style.Color;

/// Per-channel straight-sRGB interpolation, matching `style.Gradient`. `t` is
/// clamped to [0,1] so callers can pass a raw eased parameter.
pub fn lerpColor(a: Color, b: Color, t_in: f32) Color {
    const t = std.math.clamp(t_in, 0, 1);
    return .{
        .r = lerp8(a.r, b.r, t),
        .g = lerp8(a.g, b.g, t),
        .b = lerp8(a.b, b.b, t),
        .a = lerp8(a.a, b.a, t),
    };
}

fn lerp8(a: u8, b: u8, t: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(@round(fa + (fb - fa) * t));
}

/// Shared timing core for `Transition`: tracks `elapsed` over `delay + duration`
/// and yields the eased progress in [0,1]. Factored out so the scalar and color
/// transitions compute identical timing.
const Phase = struct {
    delay: u64,
    duration: u64,
    easing: Easing,
    elapsed: u64 = 0,
    active: bool = false,

    /// Restart the phase from zero (a fresh retarget).
    fn restart(self: *Phase) void {
        self.elapsed = 0;
        self.active = self.duration > 0 or self.delay > 0;
    }

    fn advance(self: *Phase, dt: u64) bool {
        if (!self.active) return false;
        self.elapsed +|= dt;
        if (self.elapsed >= self.delay + self.duration) self.active = false;
        return true;
    }

    /// Eased progress 0→1. 0 while still inside `delay`; 1 once finished.
    fn progress(self: *const Phase) f32 {
        if (self.elapsed <= self.delay) return 0;
        if (self.duration == 0) return 1;
        const local = self.elapsed - self.delay;
        const t = @as(f32, @floatFromInt(local)) / @as(f32, @floatFromInt(self.duration));
        return anim.ease(self.easing, t);
    }
};

/// A scalar value that eases toward a target whenever the target changes — the
/// CSS `transition: <prop> <duration> <easing> <delay>` model. Covers opacity,
/// lengths, positions, single transform components; for colors use
/// `ColorTransition`.
pub const Transition = struct {
    duration: u64,
    easing: Easing = .ease_out,
    delay: u64 = 0,
    /// Value to ease from this run (the value in flight when retargeted).
    from: f32,
    /// Current destination.
    to: f32,
    phase: Phase,

    /// A settled transition sitting at `initial` (no animation in flight).
    pub fn init(initial: f32, duration: u64, easing: Easing) Transition {
        return .{
            .duration = duration,
            .easing = easing,
            .from = initial,
            .to = initial,
            .phase = .{ .delay = 0, .duration = duration, .easing = easing },
        };
    }

    /// Point the transition at a new target. If it differs from the current
    /// target, the animation re-bases from the value currently in flight and
    /// restarts; an unchanged target is a no-op (no re-trigger).
    pub fn retarget(self: *Transition, target: f32) void {
        if (target == self.to) return;
        self.from = self.value();
        self.to = target;
        self.phase.delay = self.delay;
        self.phase.duration = self.duration;
        self.phase.easing = self.easing;
        self.phase.restart();
    }

    /// Advance by `dt`. Returns true while still animating (needs a redraw).
    pub fn tick(self: *Transition, dt: u64) bool {
        return self.phase.advance(dt);
    }

    /// The eased current value.
    pub fn value(self: *const Transition) f32 {
        return anim.lerp(self.from, self.to, self.phase.progress());
    }

    /// True once settled at the target.
    pub fn done(self: *const Transition) bool {
        return !self.phase.active;
    }
};

/// A color counterpart to `Transition`, easing per-channel in straight sRGB.
pub const ColorTransition = struct {
    duration: u64,
    easing: Easing = .ease_out,
    delay: u64 = 0,
    from: Color,
    to: Color,
    phase: Phase,

    pub fn init(initial: Color, duration: u64, easing: Easing) ColorTransition {
        return .{
            .duration = duration,
            .easing = easing,
            .from = initial,
            .to = initial,
            .phase = .{ .delay = 0, .duration = duration, .easing = easing },
        };
    }

    pub fn retarget(self: *ColorTransition, target: Color) void {
        if (std.meta.eql(target, self.to)) return;
        self.from = self.value();
        self.to = target;
        self.phase.delay = self.delay;
        self.phase.duration = self.duration;
        self.phase.easing = self.easing;
        self.phase.restart();
    }

    pub fn tick(self: *ColorTransition, dt: u64) bool {
        return self.phase.advance(dt);
    }

    pub fn value(self: *const ColorTransition) Color {
        return lerpColor(self.from, self.to, self.phase.progress());
    }

    pub fn done(self: *const ColorTransition) bool {
        return !self.phase.active;
    }
};

/// Playback direction for `Keyframes`, mirroring CSS `animation-direction`.
pub const Direction = enum {
    normal, // 0→1 every iteration
    reverse, // 1→0 every iteration
    alternate, // 0→1, then 1→0, ...
    alternate_reverse, // 1→0, then 0→1, ...
};

/// Fill mode, mirroring CSS `animation-fill-mode`: what the value reads as
/// before the first iteration and after the last. `none` snaps to the timeline
/// edges; `forwards` holds the final frame; `backwards` holds the first frame
/// during `delay`; `both` does both.
pub const Fill = enum { none, forwards, backwards, both };

/// A keyframe timeline: stops at offsets in [0,1] (ascending), interpolated and
/// eased over `duration`, repeated `iterations` times (or `infinite`), in
/// `direction`. The CSS `@keyframes` + `animation-*` shorthand, as data.
///
/// Stops are borrowed (`[]const Stop`) — typically a comptime literal. `value()`
/// is pure given the internal `elapsed`; `valueAt(ns)` exposes the same sampling
/// for testing or scrubbing.
pub const Keyframes = struct {
    pub const Stop = struct { offset: f32, value: f32 };

    /// Sentinel iteration count for an endlessly repeating animation.
    pub const infinite: u32 = std.math.maxInt(u32);

    stops: []const Stop,
    duration: u64,
    easing: Easing = .linear,
    iterations: u32 = 1,
    direction: Direction = .normal,
    fill: Fill = .none,
    delay: u64 = 0,

    // --- playback state ---
    elapsed: u64 = 0,
    playing: bool = true,

    /// Total active span (excludes the leading delay), or null when infinite.
    fn span(self: *const Keyframes) ?u64 {
        if (self.iterations == infinite) return null;
        return self.duration *| self.iterations;
    }

    /// Advance the timeline. Returns true while still producing motion (needs a
    /// redraw): false when paused, or when a finite animation has ended.
    pub fn tick(self: *Keyframes, dt: u64) bool {
        if (!self.playing) return false;
        if (self.done()) return false;
        self.elapsed +|= dt;
        return true;
    }

    /// True once a finite animation has run all iterations. Infinite never done.
    pub fn done(self: *const Keyframes) bool {
        const total = self.span() orelse return false;
        return self.elapsed >= self.delay + total;
    }

    pub fn pause(self: *Keyframes) void {
        self.playing = false;
    }
    pub fn play(self: *Keyframes) void {
        self.playing = true;
    }
    /// Rewind to the start (and keep playing).
    pub fn restart(self: *Keyframes) void {
        self.elapsed = 0;
        self.playing = true;
    }

    /// The current value at the internal `elapsed`.
    pub fn value(self: *const Keyframes) f32 {
        return self.valueAt(self.elapsed);
    }

    /// Sample the timeline at an absolute `elapsed` (ns since start, including
    /// the leading `delay`). Pure — no state. Honors direction, iteration count,
    /// and fill mode at the edges.
    pub fn valueAt(self: *const Keyframes, elapsed: u64) f32 {
        if (self.stops.len == 0) return 0;
        if (self.duration == 0) return self.sample(self.edgeProgress(self.iterations -| 1));

        // Before the first frame: backwards/both hold frame 0, else nothing
        // has started → the value at the very start of iteration 0.
        if (elapsed < self.delay) {
            const show_start = self.fill == .backwards or self.fill == .both;
            return self.sample(if (show_start) self.edgeProgress(0) else self.edgeProgress(0));
        }
        const active = elapsed - self.delay;

        // After the last frame of a finite animation: forwards/both hold the
        // final frame; otherwise snap to the timeline's resting edge (0).
        if (self.span()) |total| {
            if (active >= total) {
                const hold = self.fill == .forwards or self.fill == .both;
                if (hold) return self.sample(self.edgeProgress(self.iterations - 1));
                return self.sample(0);
            }
        }

        const iter: u32 = @intCast(active / self.duration);
        const within = active % self.duration;
        const t = @as(f32, @floatFromInt(within)) / @as(f32, @floatFromInt(self.duration));
        const p = self.directed(iter, anim.ease(self.easing, t));
        return self.sample(p);
    }

    /// The progress value (0 or 1) at the *end* edge of iteration `iter` — used
    /// for fill holds, so an `alternate` animation holds the right end.
    fn edgeProgress(self: *const Keyframes, iter: u32) f32 {
        return self.directed(iter, 1.0);
    }

    /// Map a within-iteration parameter `t` (0→1) to a timeline position,
    /// flipping per direction and per-iteration parity.
    fn directed(self: *const Keyframes, iter: u32, t: f32) f32 {
        return switch (self.direction) {
            .normal => t,
            .reverse => 1 - t,
            .alternate => if (iter % 2 == 0) t else 1 - t,
            .alternate_reverse => if (iter % 2 == 0) 1 - t else t,
        };
    }

    /// Interpolate the stop list at timeline position `p` in [0,1].
    fn sample(self: *const Keyframes, p_in: f32) f32 {
        const p = std.math.clamp(p_in, 0, 1);
        const s = self.stops;
        if (p <= s[0].offset) return s[0].value;
        var i: usize = 1;
        while (i < s.len) : (i += 1) {
            if (p <= s[i].offset) {
                const lo = s[i - 1];
                const hi = s[i];
                const w = hi.offset - lo.offset;
                const f = if (w > 0) (p - lo.offset) / w else 0;
                return anim.lerp(lo.value, hi.value, f);
            }
        }
        return s[s.len - 1].value;
    }
};

// === Tests ==================================================================

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "transition eases from current to a new target and settles" {
    var tr = Transition.init(0, 200 * ms, .linear);
    try testing.expect(tr.done());
    try testing.expectEqual(@as(f32, 0), tr.value());

    tr.retarget(100);
    try testing.expect(!tr.done());
    try testing.expect(tr.tick(100 * ms)); // halfway
    try testing.expectApproxEqAbs(@as(f32, 50), tr.value(), 1e-3);
    try testing.expect(tr.tick(100 * ms)); // reaches end
    try testing.expectApproxEqAbs(@as(f32, 100), tr.value(), 1e-3);
    try testing.expect(!tr.tick(50 * ms)); // settled → no redraw
    try testing.expect(tr.done());
}

test "retarget mid-flight re-bases from the value in flight" {
    var tr = Transition.init(0, 100 * ms, .linear);
    tr.retarget(100);
    _ = tr.tick(50 * ms); // value ~50, still moving toward 100
    try testing.expectApproxEqAbs(@as(f32, 50), tr.value(), 1e-3);
    tr.retarget(0); // reverse course from 50, not from 100
    try testing.expectApproxEqAbs(@as(f32, 50), tr.value(), 1e-3); // continuity
    _ = tr.tick(50 * ms);
    try testing.expectApproxEqAbs(@as(f32, 25), tr.value(), 1e-3); // halfway 50→0
}

test "retarget to the same value does not re-trigger" {
    var tr = Transition.init(10, 100 * ms, .linear);
    tr.retarget(10);
    try testing.expect(tr.done()); // unchanged → no animation
    try testing.expect(!tr.tick(50 * ms));
}

test "transition delay holds the start value" {
    var tr = Transition.init(0, 100 * ms, .linear);
    tr.delay = 50 * ms;
    tr.retarget(100);
    _ = tr.tick(40 * ms); // still inside delay
    try testing.expectApproxEqAbs(@as(f32, 0), tr.value(), 1e-3);
    _ = tr.tick(60 * ms); // 100ns in, 50 past delay → halfway
    try testing.expectApproxEqAbs(@as(f32, 50), tr.value(), 1e-3);
}

test "color transition interpolates per channel" {
    var tr = ColorTransition.init(.black, 100 * ms, .linear);
    tr.retarget(.white);
    _ = tr.tick(50 * ms);
    const c = tr.value();
    try testing.expectEqual(@as(u8, 128), c.r); // round(0 + 255*0.5)
    try testing.expectEqual(@as(u8, 128), c.b);
}

test "keyframes interpolate across stops with easing" {
    const kf = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 0.5, .value = 100 }, .{ .offset = 1, .value = 0 } },
        .duration = 100 * ms,
        .easing = .linear,
    };
    try testing.expectApproxEqAbs(@as(f32, 0), kf.valueAt(0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50), kf.valueAt(25 * ms), 1e-3); // up-ramp midpoint
    try testing.expectApproxEqAbs(@as(f32, 100), kf.valueAt(50 * ms), 1e-3); // peak
    try testing.expectApproxEqAbs(@as(f32, 50), kf.valueAt(75 * ms), 1e-3); // down-ramp midpoint
}

test "keyframes iteration count and done" {
    var kf = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 1, .value = 10 } },
        .duration = 100 * ms,
        .iterations = 2,
    };
    try testing.expect(kf.tick(150 * ms)); // mid second iteration
    try testing.expectApproxEqAbs(@as(f32, 5), kf.value(), 1e-3); // 50% of iter 2
    try testing.expect(!kf.done());
    try testing.expect(kf.tick(60 * ms)); // crosses the end this tick
    try testing.expect(kf.done());
    try testing.expect(!kf.tick(10 * ms)); // finished → no redraw
}

test "keyframes alternate flips direction each iteration" {
    const kf = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 1, .value = 100 } },
        .duration = 100 * ms,
        .iterations = Keyframes.infinite,
        .direction = .alternate,
    };
    try testing.expectApproxEqAbs(@as(f32, 50), kf.valueAt(50 * ms), 1e-3); // iter0 up
    try testing.expectApproxEqAbs(@as(f32, 50), kf.valueAt(150 * ms), 1e-3); // iter1 down → 50 too
    try testing.expectApproxEqAbs(@as(f32, 25), kf.valueAt(175 * ms), 1e-3); // iter1, t=.75 → 1-.75
}

test "keyframes infinite never finishes" {
    const kf = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 1, .value = 1 } },
        .duration = 100 * ms,
        .iterations = Keyframes.infinite,
    };
    try testing.expect(!kf.done());
}

test "keyframes fill forwards holds the final frame" {
    const base = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 1, .value = 100 } },
        .duration = 100 * ms,
        .iterations = 1,
    };
    // none: after the end, snaps back to the resting edge (offset 0 → 0).
    try testing.expectApproxEqAbs(@as(f32, 0), base.valueAt(200 * ms), 1e-3);
    // forwards: holds the last frame (100).
    var fwd = base;
    fwd.fill = .forwards;
    try testing.expectApproxEqAbs(@as(f32, 100), fwd.valueAt(200 * ms), 1e-3);
}

test "keyframes pause stops producing motion" {
    var kf = Keyframes{
        .stops = &.{ .{ .offset = 0, .value = 0 }, .{ .offset = 1, .value = 10 } },
        .duration = 100 * ms,
        .iterations = Keyframes.infinite,
    };
    _ = kf.tick(50 * ms);
    kf.pause();
    const v = kf.value();
    try testing.expect(!kf.tick(50 * ms)); // paused → no redraw
    try testing.expectApproxEqAbs(v, kf.value(), 1e-6); // frozen
    kf.play();
    try testing.expect(kf.tick(50 * ms)); // resumes
}
