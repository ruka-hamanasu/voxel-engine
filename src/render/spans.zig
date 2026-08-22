const std = @import("std");

/// True if any free span intersects rows [r0, r1). Must gate every AO
/// computation: without this occlusion early-out, neighbor queries run
/// for faces that write no pixels and AO costs ~3x the base render.
pub fn spanOverlap(free: *const SpanList, r0: f32, r1: f32) bool {
    if (!(r1 > r0)) return false;
    for (free.spans[0..free.len]) |s| {
        if (@min(r1, @as(f32, @floatFromInt(s.y1))) > @max(r0, @as(f32, @floatFromInt(s.y0)))) return true;
    }
    return false;
}

const Span = struct { y0: u16, y1: u16 };

pub const SpanList = struct {
    pub const max_spans = 8;

    spans: [max_spans]Span = undefined,
    len: usize = 0,

    pub fn initFull(h: u16) SpanList {
        var list: SpanList = .{};
        list.spans[0] = .{ .y0 = 0, .y1 = h };
        list.len = 1;
        return list;
    }

    pub fn isEmpty(self: *const SpanList) bool {
        return self.len == 0;
    }

    pub fn subtract(self: *SpanList, a: u16, b: u16) void {
        if (a >= b) return;
        var i: usize = 0;
        while (i < self.len) {
            const s = self.spans[i];
            if (b <= s.y0 or a >= s.y1) {
                i += 1;
                continue;
            }
            if (a <= s.y0 and b >= s.y1) {
                std.mem.copyForwards(Span, self.spans[i .. self.len - 1], self.spans[i + 1 .. self.len]);
                self.len -= 1;
                continue;
            }
            if (a <= s.y0) {
                self.spans[i].y0 = b;
                i += 1;
                continue;
            }
            if (b >= s.y1) {
                self.spans[i].y1 = a;
                i += 1;
                continue;
            }
            if (self.len == max_spans) {
                self.spans[i].y1 = a;
                i += 1;
                continue;
            }
            std.mem.copyBackwards(Span, self.spans[i + 2 .. self.len + 1], self.spans[i + 1 .. self.len]);
            self.spans[i] = .{ .y0 = s.y0, .y1 = a };
            self.spans[i + 1] = .{ .y0 = b, .y1 = s.y1 };
            self.len += 1;
            return;
        }
    }
};

const ConstSrc = struct {
    c: u32,
};

/// 16.16 fixed-point vertical lerp from c0 (at r0) to c1 (at r1). The
/// gradient is parameterized over the unclipped row domain so
/// span-clipped pieces sample the same ramp.
const GradSrc = struct {
    ch0: [3]i32,
    step: [3]i32,
    ra: i32,
    acc: [3]i32,

    fn init(ra: i32, rb: i32, c0: u32, c1: u32) GradSrc {
        const n = rb - ra;
        const ch0 = [3]i32{ @intCast((c0 >> 16) & 0xff), @intCast((c0 >> 8) & 0xff), @intCast(c0 & 0xff) };
        const ch1 = [3]i32{ @intCast((c1 >> 16) & 0xff), @intCast((c1 >> 8) & 0xff), @intCast(c1 & 0xff) };
        var step: [3]i32 = undefined;
        for (0..3) |k| step[k] = @divTrunc((ch1[k] - ch0[k]) << 16, n);
        return .{ .ch0 = ch0, .step = step, .ra = ra, .acc = undefined };
    }

    fn seek(self: *GradSrc, row: u16) void {
        const off: i32 = @as(i32, row) - self.ra;
        for (0..3) |k| self.acc[k] = (self.ch0[k] << 16) + off * self.step[k] + 0x8000;
    }

    fn next(self: *GradSrc, row: u16) u32 {
        _ = row;
        const cr: u32 = @intCast(std.math.clamp(self.acc[0] >> 16, 0, 255));
        const cg: u32 = @intCast(std.math.clamp(self.acc[1] >> 16, 0, 255));
        const cb: u32 = @intCast(std.math.clamp(self.acc[2] >> 16, 0, 255));
        for (0..3) |k| self.acc[k] += self.step[k];
        return 0xff000000 | (cr << 16) | (cg << 8) | cb;
    }
};

pub const SkySrc = struct {
    sky: []const u32,
};

/// The single pixel-write path: claim, gradient claim, and the sky
/// fill all go through here, giving milestone 13's fog glow one
/// injection point. src provides seek(row)/next(row) color taps. The
/// write loop slices the destination once so ReleaseSafe drops the
/// per-pixel bounds checks; constant and sky sources get bulk fills.
pub fn fillSpans(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, src: anytype) void {
    if (free.isEmpty() or !(r1 > r0)) return;
    var s = src;
    var i: usize = 0;
    while (i < free.len) {
        const span = free.spans[i];
        const a = @max(r0, @as(f32, @floatFromInt(span.y0)));
        const b = @min(r1, @as(f32, @floatFromInt(span.y1)));
        if (!(b > a)) {
            i += 1;
            continue;
        }
        const ia: u16 = @intFromFloat(@ceil(a));
        const ib: u16 = @intFromFloat(@ceil(b));
        if (ib <= ia) {
            i += 1;
            continue;
        }
        const dst = fb[sx * height + ia .. sx * height + ib];
        const S = @TypeOf(s);
        if (S == SkySrc) {
            @memcpy(dst, s.sky[ia..ib]);
        } else if (S == ConstSrc) {
            for (dst) |*px| px.* = s.c;
        } else {
            s.seek(ia);
            for (dst, ia..) |*px, row| px.* = s.next(@intCast(row));
        }
        free.subtract(ia, ib);
        // A fully consumed span shifts the rest of the list down into
        // index i; only advance when span i survived (trimmed or split).
        if (!(ia <= span.y0 and ib >= span.y1)) i += 1;
    }
}

fn claim(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, color: u32) void {
    fillSpans(fb, height, sx, free, r0, r1, ConstSrc{ .c = color });
}

/// Equal stops (including both-max AO) take the constant-fill fast
/// path.
pub fn claimGrad(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, c0: u32, c1: u32) void {
    if (c0 == c1) return claim(fb, height, sx, free, r0, r1, c0);
    if (free.isEmpty() or !(r1 > r0)) return;
    const ra: i32 = @intFromFloat(@ceil(r0));
    const rb: i32 = @intFromFloat(@ceil(r1));
    if (rb - ra <= 0) return;
    fillSpans(fb, height, sx, free, r0, r1, GradSrc.init(ra, rb, c0, c1));
}

test "gradient claim fills a clipped lerp" {
    var fb: [8]u32 = @splat(0xdeadbeef);
    var free = SpanList.initFull(8);
    claimGrad(&fb, 8, 0, &free, 2.0, 6.0, 0xff000000, 0xffffffff);
    try std.testing.expectEqual(2, free.len);
    try std.testing.expectEqual(Span{ .y0 = 0, .y1 = 2 }, free.spans[0]);
    try std.testing.expectEqual(Span{ .y0 = 6, .y1 = 8 }, free.spans[1]);
    try std.testing.expectEqual(0xdeadbeef, fb[1]);
    try std.testing.expectEqual(0xdeadbeef, fb[6]);
    try std.testing.expectEqual(0xff000000, fb[2]);
    var prev: u32 = 0;
    for (fb[2..6]) |px| {
        const r = px & 0xff;
        try std.testing.expect(r >= prev);
        try std.testing.expect(r == (px >> 16 & 0xff) and r == (px >> 8 & 0xff));
        prev = r;
    }
    try std.testing.expect(prev > 0);

    claimGrad(&fb, 8, 0, &free, 0.0, 8.0, 0xff102030, 0xff102030);
    try std.testing.expectEqual(0xff102030, fb[0]);
    try std.testing.expectEqual(0xff102030, fb[7]);
    try std.testing.expect(free.isEmpty());
}

test "span subtract splits and trims" {
    var list = SpanList.initFull(100);
    list.subtract(40, 60);
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(Span{ .y0 = 0, .y1 = 40 }, list.spans[0]);
    try std.testing.expectEqual(Span{ .y0 = 60, .y1 = 100 }, list.spans[1]);

    list.subtract(10, 20);
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqual(Span{ .y0 = 0, .y1 = 10 }, list.spans[0]);
    try std.testing.expectEqual(Span{ .y0 = 20, .y1 = 40 }, list.spans[1]);

    list.subtract(0, 10);
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(Span{ .y0 = 20, .y1 = 40 }, list.spans[0]);

    list.subtract(90, 200);
    try std.testing.expectEqual(Span{ .y0 = 60, .y1 = 90 }, list.spans[1]);

    list.subtract(20, 40);
    try std.testing.expectEqual(1, list.len);

    list.subtract(0, 100);
    try std.testing.expect(list.isEmpty());

    list.subtract(0, 100);
    try std.testing.expect(list.isEmpty());
}
