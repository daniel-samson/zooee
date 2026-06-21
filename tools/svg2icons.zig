//! Build-time SVG → baked icon data (#272, build-time pipeline).
//!
//! Reads every `*.svg` in a directory and emits a generated Zig module with
//! each icon's geometry flattened to polyline subpaths in a normalized 0..1
//! unit square. Targets the subset real icon libraries (Lucide/Feather/
//! Heroicons/Material) use: `<path d>` (M/L/H/V/C/S/Q/T/A/Z, abs+rel),
//! `<circle>`, `<ellipse>`, `<rect>` (+ rx/ry), `<line>`, `<polyline>`,
//! `<polygon>`. Stroke-vs-fill intent comes from the root `fill`/`stroke`.
//!
//! Curves flatten at build time, so the runtime ships only `[]Point` tables and
//! never an SVG parser. The whole generated set compiles in (point tables are
//! tiny — ~21 Lucide icons cost well under a KB each), so curate icons/ to the
//! icons you actually ship.
//!
//! Usage: svg2icons <icons-dir> <out.zig>

const std = @import("std");

const Point = struct { x: f64, y: f64 };

const SubPath = struct {
    pts: std.ArrayList(Point),
    closed: bool = false,
};

const IconKind = enum { stroke, fill };

const Icon = struct {
    name: []const u8, // sanitized enum identifier
    subpaths: std.ArrayList(SubPath),
    stroke_width: f64, // normalized (0..1) units
    kind: IconKind,
};

const seg_per_curve = 24; // bezier flattening resolution
const seg_per_quarter = 8; // arc/circle quarter-turn resolution

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) {
        std.debug.print("usage: svg2icons <icons-dir> <out.zig>\n", .{});
        return error.BadArgs;
    }
    const dir_path = args[1];
    const out_path = args[2];

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessName);

    var icons: std.ArrayList(Icon) = .empty;
    for (names.items) |fname| {
        const svg = try dir.readFileAlloc(io, fname, a, .limited(1 << 20));
        const ident = try sanitize(a, fname[0 .. fname.len - 4]);
        const icon = try parseSvg(a, ident, svg);
        try icons.append(a, icon);
    }

    try emit(a, io, out_path, icons.items);
    std.debug.print("svg2icons: wrote {d} icons → {s}\n", .{ icons.items.len, out_path });
}

fn lessName(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

/// "chevron-right" → "chevron_right"; leading digit gets an underscore.
fn sanitize(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (name.len > 0 and std.ascii.isDigit(name[0])) try buf.append(a, '_');
    for (name) |c| {
        try buf.append(a, switch (c) {
            'A'...'Z' => std.ascii.toLower(c),
            'a'...'z', '0'...'9' => c,
            else => '_',
        });
    }
    return buf.toOwnedSlice(a);
}

// ── SVG parsing ────────────────────────────────────────────────────────────

const ParseState = struct {
    a: std.mem.Allocator,
    subpaths: std.ArrayList(SubPath),
    cur: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    prev_cubic_ctrl: ?Point = null,
    prev_quad_ctrl: ?Point = null,

    fn open(self: *ParseState, p: Point) !void {
        try self.subpaths.append(self.a, .{ .pts = .empty });
        try self.subpaths.items[self.subpaths.items.len - 1].pts.append(self.a, p);
        self.cur = p;
        self.start = p;
    }
    fn line(self: *ParseState, p: Point) !void {
        if (self.subpaths.items.len == 0) try self.open(self.cur);
        try self.subpaths.items[self.subpaths.items.len - 1].pts.append(self.a, p);
        self.cur = p;
    }
    fn close(self: *ParseState) void {
        if (self.subpaths.items.len == 0) return;
        self.subpaths.items[self.subpaths.items.len - 1].closed = true;
        self.cur = self.start;
    }
};

fn parseSvg(a: std.mem.Allocator, ident: []const u8, svg: []const u8) !Icon {
    const vb = parseViewBox(svg);
    const root_stroke_w = attrFloat(rootTag(svg), "stroke-width") orelse 2;
    const fill_none = blk: {
        const f = attrStr(rootTag(svg), "fill") orelse break :blk false;
        break :blk std.mem.eql(u8, f, "none");
    };
    const kind: IconKind = if (fill_none) .stroke else .fill;

    var st = ParseState{ .a = a, .subpaths = .empty };

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, svg, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, svg, lt, '>') orelse break;
        const tag = svg[lt + 1 .. gt];
        i = gt + 1;
        // Each element's coordinates are independent: reset the current point so
        // a leading *relative* moveto (e.g. a `<path d="m9 12 …">` after a
        // `<rect>`) starts from the origin, not where the previous element ended.
        st.cur = .{ .x = 0, .y = 0 };
        st.start = .{ .x = 0, .y = 0 };
        st.prev_cubic_ctrl = null;
        st.prev_quad_ctrl = null;
        if (std.mem.startsWith(u8, tag, "path")) {
            if (attrStr(tag, "d")) |d| try parsePath(&st, d);
        } else if (std.mem.startsWith(u8, tag, "circle")) {
            try emitEllipse(&st, attrFloat(tag, "cx") orelse 0, attrFloat(tag, "cy") orelse 0, attrFloat(tag, "r") orelse 0, attrFloat(tag, "r") orelse 0);
        } else if (std.mem.startsWith(u8, tag, "ellipse")) {
            try emitEllipse(&st, attrFloat(tag, "cx") orelse 0, attrFloat(tag, "cy") orelse 0, attrFloat(tag, "rx") orelse 0, attrFloat(tag, "ry") orelse 0);
        } else if (std.mem.startsWith(u8, tag, "rect")) {
            try emitRect(&st, tag);
        } else if (std.mem.startsWith(u8, tag, "line")) {
            try st.open(.{ .x = attrFloat(tag, "x1") orelse 0, .y = attrFloat(tag, "y1") orelse 0 });
            try st.line(.{ .x = attrFloat(tag, "x2") orelse 0, .y = attrFloat(tag, "y2") orelse 0 });
        } else if (std.mem.startsWith(u8, tag, "polyline")) {
            try emitPoly(&st, attrStr(tag, "points") orelse "", false);
        } else if (std.mem.startsWith(u8, tag, "polygon")) {
            try emitPoly(&st, attrStr(tag, "points") orelse "", true);
        }
    }

    // Normalize to a 0..1 unit square using the viewBox.
    for (st.subpaths.items) |*sp| {
        for (sp.pts.items) |*p| {
            p.x = (p.x - vb.minx) / vb.w;
            p.y = (p.y - vb.miny) / vb.h;
        }
    }
    return .{ .name = ident, .subpaths = st.subpaths, .stroke_width = root_stroke_w / vb.w, .kind = kind };
}

const ViewBox = struct { minx: f64, miny: f64, w: f64, h: f64 };

fn rootTag(svg: []const u8) []const u8 {
    const lt = std.mem.indexOfScalar(u8, svg, '<') orelse return svg;
    const gt = std.mem.indexOfScalarPos(u8, svg, lt, '>') orelse return svg;
    return svg[lt + 1 .. gt];
}

fn parseViewBox(svg: []const u8) ViewBox {
    if (attrStr(rootTag(svg), "viewBox")) |vb| {
        var sc = NumScanner{ .s = vb };
        const a = sc.next() orelse 0;
        const b = sc.next() orelse 0;
        const c = sc.next() orelse 24;
        const d = sc.next() orelse 24;
        return .{ .minx = a, .miny = b, .w = if (c == 0) 24 else c, .h = if (d == 0) 24 else d };
    }
    return .{ .minx = 0, .miny = 0, .w = 24, .h = 24 };
}

fn emitEllipse(st: *ParseState, cx: f64, cy: f64, rx: f64, ry: f64) !void {
    const n = seg_per_quarter * 4;
    try st.open(.{ .x = cx + rx, .y = cy });
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)) * std.math.tau;
        try st.line(.{ .x = cx + rx * @cos(t), .y = cy + ry * @sin(t) });
    }
    st.close();
}

fn emitRect(st: *ParseState, tag: []const u8) !void {
    const x = attrFloat(tag, "x") orelse 0;
    const y = attrFloat(tag, "y") orelse 0;
    const w = attrFloat(tag, "width") orelse 0;
    const h = attrFloat(tag, "height") orelse 0;
    var rx = attrFloat(tag, "rx") orelse (attrFloat(tag, "ry") orelse 0);
    var ry = attrFloat(tag, "ry") orelse (attrFloat(tag, "rx") orelse 0);
    rx = @min(rx, w / 2);
    ry = @min(ry, h / 2);
    if (rx <= 0 or ry <= 0) {
        try st.open(.{ .x = x, .y = y });
        try st.line(.{ .x = x + w, .y = y });
        try st.line(.{ .x = x + w, .y = y + h });
        try st.line(.{ .x = x, .y = y + h });
        st.close();
        return;
    }
    // Rounded rect: four quarter-arcs joined by straight edges, clockwise.
    try st.open(.{ .x = x + rx, .y = y });
    try st.line(.{ .x = x + w - rx, .y = y });
    try arcQuarter(st, x + w - rx, y + ry, rx, ry, -std.math.pi / 2.0, 0);
    try st.line(.{ .x = x + w, .y = y + h - ry });
    try arcQuarter(st, x + w - rx, y + h - ry, rx, ry, 0, std.math.pi / 2.0);
    try st.line(.{ .x = x + rx, .y = y + h });
    try arcQuarter(st, x + rx, y + h - ry, rx, ry, std.math.pi / 2.0, std.math.pi);
    try st.line(.{ .x = x, .y = y + ry });
    try arcQuarter(st, x + rx, y + ry, rx, ry, std.math.pi, std.math.pi * 1.5);
    st.close();
}

fn arcQuarter(st: *ParseState, cx: f64, cy: f64, rx: f64, ry: f64, a0: f64, a1: f64) !void {
    var k: usize = 1;
    while (k <= seg_per_quarter) : (k += 1) {
        const t = a0 + (a1 - a0) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(seg_per_quarter));
        try st.line(.{ .x = cx + rx * @cos(t), .y = cy + ry * @sin(t) });
    }
}

fn emitPoly(st: *ParseState, points: []const u8, closed: bool) !void {
    var sc = NumScanner{ .s = points };
    const first_x = sc.next() orelse return;
    const first_y = sc.next() orelse return;
    try st.open(.{ .x = first_x, .y = first_y });
    while (sc.next()) |px| {
        const py = sc.next() orelse break;
        try st.line(.{ .x = px, .y = py });
    }
    if (closed) st.close();
}

// ── Path data (the `d` attribute) ──────────────────────────────────────────

fn parsePath(st: *ParseState, d: []const u8) !void {
    var sc = NumScanner{ .s = d };
    var cmd: u8 = 0;
    while (true) {
        sc.skipSep();
        if (sc.i >= sc.s.len) break;
        const c = sc.s[sc.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            sc.i += 1;
        } else if (cmd == 0) {
            break;
        }
        const rel = std.ascii.isLower(cmd);
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = sc.next() orelse break;
                const y = sc.next() orelse break;
                var p = Point{ .x = x, .y = y };
                if (rel) p = .{ .x = st.cur.x + x, .y = st.cur.y + y };
                try st.open(p);
                cmd = if (rel) 'l' else 'L'; // subsequent pairs are implicit lineto
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            'L' => {
                const x = sc.next() orelse break;
                const y = sc.next() orelse break;
                try st.line(if (rel) .{ .x = st.cur.x + x, .y = st.cur.y + y } else .{ .x = x, .y = y });
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            'H' => {
                const x = sc.next() orelse break;
                try st.line(.{ .x = if (rel) st.cur.x + x else x, .y = st.cur.y });
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            'V' => {
                const y = sc.next() orelse break;
                try st.line(.{ .x = st.cur.x, .y = if (rel) st.cur.y + y else y });
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            'C' => {
                const p1 = try readPt(&sc, st, rel) orelse break;
                const p2 = try readPt(&sc, st, rel) orelse break;
                const p = try readPt(&sc, st, rel) orelse break;
                try cubic(st, st.cur, p1, p2, p);
                st.prev_cubic_ctrl = p2;
                st.prev_quad_ctrl = null;
            },
            'S' => {
                const p2 = try readPt(&sc, st, rel) orelse break;
                const p = try readPt(&sc, st, rel) orelse break;
                const p1 = reflect(st.prev_cubic_ctrl, st.cur);
                try cubic(st, st.cur, p1, p2, p);
                st.prev_cubic_ctrl = p2;
                st.prev_quad_ctrl = null;
            },
            'Q' => {
                const c1 = try readPt(&sc, st, rel) orelse break;
                const p = try readPt(&sc, st, rel) orelse break;
                try quad(st, st.cur, c1, p);
                st.prev_quad_ctrl = c1;
                st.prev_cubic_ctrl = null;
            },
            'T' => {
                const p = try readPt(&sc, st, rel) orelse break;
                const c1 = reflect(st.prev_quad_ctrl, st.cur);
                try quad(st, st.cur, c1, p);
                st.prev_quad_ctrl = c1;
                st.prev_cubic_ctrl = null;
            },
            'A' => {
                const rx = sc.next() orelse break;
                const ry = sc.next() orelse break;
                const xrot = sc.next() orelse break;
                const large = (sc.next() orelse break) != 0;
                const sweep = (sc.next() orelse break) != 0;
                const ex = sc.next() orelse break;
                const ey = sc.next() orelse break;
                const end = if (rel) Point{ .x = st.cur.x + ex, .y = st.cur.y + ey } else Point{ .x = ex, .y = ey };
                try arcTo(st, rx, ry, xrot, large, sweep, end);
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            'Z' => {
                st.close();
                st.prev_cubic_ctrl = null;
                st.prev_quad_ctrl = null;
            },
            else => break,
        }
    }
}

fn readPt(sc: *NumScanner, st: *ParseState, rel: bool) !?Point {
    const x = sc.next() orelse return null;
    const y = sc.next() orelse return null;
    return if (rel) .{ .x = st.cur.x + x, .y = st.cur.y + y } else .{ .x = x, .y = y };
}

fn reflect(ctrl: ?Point, cur: Point) Point {
    const c = ctrl orelse return cur;
    return .{ .x = 2 * cur.x - c.x, .y = 2 * cur.y - c.y };
}

fn cubic(st: *ParseState, p0: Point, p1: Point, p2: Point, p3: Point) !void {
    var k: usize = 1;
    while (k <= seg_per_curve) : (k += 1) {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(seg_per_curve));
        const u = 1 - t;
        const x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x;
        const y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y;
        try st.line(.{ .x = x, .y = y });
    }
}

fn quad(st: *ParseState, p0: Point, p1: Point, p2: Point) !void {
    var k: usize = 1;
    while (k <= seg_per_curve) : (k += 1) {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(seg_per_curve));
        const u = 1 - t;
        const x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x;
        const y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y;
        try st.line(.{ .x = x, .y = y });
    }
}

/// Endpoint-parameterized arc → center form, then sample (SVG impl notes F.6).
fn arcTo(st: *ParseState, rx_in: f64, ry_in: f64, xrot_deg: f64, large: bool, sweep: bool, end: Point) !void {
    const p0 = st.cur;
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        try st.line(end);
        return;
    }
    const phi = xrot_deg * std.math.pi / 180.0;
    const cosp = @cos(phi);
    const sinp = @sin(phi);
    const dx = (p0.x - end.x) / 2.0;
    const dy = (p0.y - end.y) / 2.0;
    const x1p = cosp * dx + sinp * dy;
    const y1p = -sinp * dx + cosp * dy;
    // Correct out-of-range radii.
    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
        const s = @sqrt(lam);
        rx *= s;
        ry *= s;
    }
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = if (den == 0) 0 else @sqrt(@max(0.0, num / den));
    if (large == sweep) co = -co;
    const cxp = co * (rx * y1p) / ry;
    const cyp = co * -(ry * x1p) / rx;
    const cx = cosp * cxp - sinp * cyp + (p0.x + end.x) / 2.0;
    const cy = sinp * cxp + cosp * cyp + (p0.y + end.y) / 2.0;
    const ang = struct {
        fn f(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
            const dot = ux * vx + uy * vy;
            const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
            var ac = std.math.acos(std.math.clamp(dot / len, -1.0, 1.0));
            if (ux * vy - uy * vx < 0) ac = -ac;
            return ac;
        }
    }.f;
    const theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dtheta > 0) dtheta -= std.math.tau;
    if (sweep and dtheta < 0) dtheta += std.math.tau;
    const steps: usize = @max(2, @as(usize, @intFromFloat(@abs(dtheta) / (std.math.pi / 2.0) * seg_per_quarter)) + 1);
    var k: usize = 1;
    while (k <= steps) : (k += 1) {
        const t = theta1 + dtheta * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
        const ex = cosp * rx * @cos(t) - sinp * ry * @sin(t) + cx;
        const ey = sinp * rx * @cos(t) + cosp * ry * @sin(t) + cy;
        try st.line(.{ .x = ex, .y = ey });
    }
}

// ── Attribute + number scanning ────────────────────────────────────────────

fn attrStr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        const after = at + name.len;
        // Require a word boundary before and '=' (after optional spaces) after.
        const boundary_ok = at == 0 or !isNameChar(tag[at - 1]);
        var j = after;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\n' or tag[j] == '\t')) j += 1;
        if (boundary_ok and j < tag.len and tag[j] == '=') {
            j += 1;
            while (j < tag.len and tag[j] != '"' and tag[j] != '\'') j += 1;
            if (j >= tag.len) return null;
            const q = tag[j];
            const start = j + 1;
            const end = std.mem.indexOfScalarPos(u8, tag, start, q) orelse return null;
            return tag[start..end];
        }
        i = after;
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn attrFloat(tag: []const u8, name: []const u8) ?f64 {
    const s = attrStr(tag, name) orelse return null;
    var sc = NumScanner{ .s = s };
    return sc.next();
}

/// Scans SVG numbers: separators are space/comma/tab/newline; a number may
/// also be terminated by a sign or a second decimal point (e.g. ".53.53").
const NumScanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(self: *NumScanner) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', ',', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn next(self: *NumScanner) ?f64 {
        self.skipSep();
        const start = self.i;
        var seen_digit = false;
        var seen_dot = false;
        var seen_exp = false;
        if (self.i < self.s.len and (self.s[self.i] == '+' or self.s[self.i] == '-')) self.i += 1;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c >= '0' and c <= '9') {
                seen_digit = true;
                self.i += 1;
            } else if (c == '.' and !seen_dot and !seen_exp) {
                seen_dot = true;
                self.i += 1;
            } else if ((c == 'e' or c == 'E') and seen_digit and !seen_exp) {
                seen_exp = true;
                self.i += 1;
                if (self.i < self.s.len and (self.s[self.i] == '+' or self.s[self.i] == '-')) self.i += 1;
            } else break;
        }
        if (!seen_digit) {
            self.i = start;
            return null;
        }
        return std.fmt.parseFloat(f64, self.s[start..self.i]) catch null;
    }
};

// ── Codegen ────────────────────────────────────────────────────────────────

fn emit(a: std.mem.Allocator, io: std.Io, out_path: []const u8, icons: []const Icon) !void {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\//! GENERATED by tools/svg2icons.zig — DO NOT EDIT.
        \\//! Regenerate with `zig build gen-icons`. Source SVGs live in icons/.
        \\const geometry = @import("geometry.zig");
        \\const P = geometry.Point;
        \\
        \\pub const SubPath = struct { pts: []const P, closed: bool };
        \\pub const IconData = struct { subpaths: []const SubPath, stroke_width: f32, stroke: bool };
        \\
        \\
    );

    // Enum of names.
    try w.writeAll("pub const Name = enum {\n");
    for (icons) |ic| try w.print("    {s},\n", .{ic.name});
    try w.writeAll("};\n\n");

    // Per-icon constants.
    for (icons) |ic| {
        try w.print("const data_{s} = IconData{{ .stroke_width = {d}, .stroke = {s}, .subpaths = &.{{\n", .{
            ic.name, fmtF(ic.stroke_width), if (ic.kind == .stroke) "true" else "false",
        });
        for (ic.subpaths.items) |sp| {
            if (sp.pts.items.len == 0) continue;
            try w.print("    .{{ .closed = {s}, .pts = &.{{", .{if (sp.closed) "true" else "false"});
            for (sp.pts.items, 0..) |p, idx| {
                if (idx != 0) try w.writeAll(", ");
                try w.print(".{{ .x = {d}, .y = {d} }}", .{ fmtF(p.x), fmtF(p.y) });
            }
            try w.writeAll("} },\n");
        }
        try w.writeAll("} };\n\n");
    }

    // Dispatch.
    try w.writeAll("pub fn get(n: Name) IconData {\n    return switch (n) {\n");
    for (icons) |ic| try w.print("        .{s} => data_{s},\n", .{ ic.name, ic.name });
    try w.writeAll("    };\n}\n");

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = aw.writer.buffered() });
}

/// Round to 4 decimals to keep the generated file compact and deterministic.
fn fmtF(v: f64) f64 {
    return @round(v * 10000.0) / 10000.0;
}
