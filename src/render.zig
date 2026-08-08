const std = @import("std");
const world_mod = @import("world.zig");
const camera_mod = @import("camera.zig");

const World = world_mod.World;
const Camera = camera_mod.Camera;

pub const hfov: f32 = std.math.pi / 2.0;
pub const max_dist: f32 = 48.0;

/// Per-frame render configuration, threaded render -> renderColumn ->
/// processCell. Fields become live in milestones 8-13; for now they
/// carry defaults only.
pub const RenderParams = struct {
    fog_density: f32 = 0.0,
    fog_cutoff: f32 = max_dist,
    sun_azimuth: f32 = 0.0,
    sun_elevation: f32 = 0.0,
    time_s: f64 = 0.0,
    glow_map: ?*const anyopaque = null,
};

const Face = enum(u2) { top, bottom, x_side, z_side };

/// 2D Amanatides-Woo XZ marcher. Extracted from renderColumn so the
/// milestone-12 sun shadow march reuses the identical stepping math
/// (elevation makes the shadow ray's height interval affine in t).
pub const DdaIterator = struct {
    max_t: f32,
    ix: i32,
    iz: i32,
    step_x: i32,
    step_z: i32,
    t_delta_x: f32,
    t_delta_z: f32,
    t_max_x: f32,
    t_max_z: f32,
    t0: f32,
    axis: Face,
    px: i32,
    pz: i32,
    has_prev: bool,

    pub fn init(x: f32, z: f32, dx: f32, dz: f32, max_t: f32) DdaIterator {
        const inf = std.math.inf(f32);
        return .{
            .max_t = max_t,
            .ix = @intFromFloat(@floor(x)),
            .iz = @intFromFloat(@floor(z)),
            .step_x = if (dx > 0) 1 else -1,
            .step_z = if (dz > 0) 1 else -1,
            .t_delta_x = if (dx != 0) @abs(1.0 / dx) else inf,
            .t_delta_z = if (dz != 0) @abs(1.0 / dz) else inf,
            .t_max_x = if (dx > 0)
                (@floor(x) + 1.0 - x) / dx
            else if (dx < 0)
                (@floor(x) - x) / dx
            else
                inf,
            .t_max_z = if (dz > 0)
                (@floor(z) + 1.0 - z) / dz
            else if (dz < 0)
                (@floor(z) - z) / dz
            else
                inf,
            .t0 = 0,
            .axis = .x_side,
            .px = 0,
            .pz = 0,
            .has_prev = false,
        };
    }

    /// Cell-exit distance of the current cell.
    pub fn t1(self: *const DdaIterator) f32 {
        return @min(@min(self.t_max_x, self.t_max_z), self.max_t);
    }

    /// Step into the next cell; the current cell's coordinates become
    /// the previous-cell record.
    pub fn advance(self: *DdaIterator) void {
        self.px = self.ix;
        self.pz = self.iz;
        self.has_prev = true;
        if (self.t_max_x < self.t_max_z) {
            self.t0 = self.t_max_x;
            self.t_max_x += self.t_delta_x;
            self.ix += self.step_x;
            self.axis = .x_side;
        } else {
            self.t0 = self.t_max_z;
            self.t_max_z += self.t_delta_z;
            self.iz += self.step_z;
            self.axis = .z_side;
        }
    }
};
const face_factor = [4]f32{ 1.0, 0.5, 0.8, 0.6 };
const ao_factor = [4]f32{ 0.45, 0.65, 0.82, 1.0 };

/// [palette][face][ao_level] -> shaded color; collapses all shading
/// arithmetic into one L1-resident lookup. Emissive materials bypass
/// face/AO shading: every entry in their row is the full-bright color.
/// Runtime-var so milestone 10's palette animation can rebuild it.
var shade_lut: [world_mod.default_palette.len][4][4]u32 = buildShadeLut(world_mod.default_palette);

fn buildShadeLut(palette: [world_mod.default_palette.len]world_mod.PaletteEntry) [world_mod.default_palette.len][4][4]u32 {
    var lut: [world_mod.default_palette.len][4][4]u32 = undefined;
    for (palette, 0..) |entry, m| {
        const cp = entry.rgb;
        for (face_factor, 0..) |ff, fi| {
            for (ao_factor, 0..) |af, ai| {
                const factor = if (entry.emissive != 0) 1.0 else ff * af;
                const r: u32 = @intFromFloat(@as(f32, @floatFromInt((cp >> 16) & 0xff)) * factor);
                const g: u32 = @intFromFloat(@as(f32, @floatFromInt((cp >> 8) & 0xff)) * factor);
                const b: u32 = @intFromFloat(@as(f32, @floatFromInt(cp & 0xff)) * factor);
                lut[m][fi][ai] = 0xff000000 | (r << 16) | (g << 8) | b;
            }
        }
    }
    return lut;
}

/// Rebuild the shade LUT after a palette mutation (milestone 10 calls
/// this per frame while animating).
pub fn rebuildShadeLut() void {
    shade_lut = buildShadeLut(world_mod.palette);
}

/// Minecraft per-vertex AO: both edge neighbors solid -> darkest (0),
/// else 3 minus the count of solid occluders (corner included).
fn aoLevel(side1: bool, side2: bool, corner: bool) u2 {
    if (side1 and side2) return 0;
    return 3 - @as(u2, @intFromBool(side1)) - @as(u2, @intFromBool(side2)) - @as(u2, @intFromBool(corner));
}

fn frac01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

/// AO level at fractional face position u between corners a and b.
/// Kept fractional: rounding to discrete levels here makes the stop
/// jump a whole level when the sample point crosses a rounding
/// boundary, which bands adjacent screen columns.
fn lerpLevel(a: u2, b: u2, u: f32) f32 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return fa + (fb - fa) * u;
}

/// AO level at (u, v) on a horizontal face, bilinear between the four
/// corner levels (m/p = -/+ along x then z).
fn bilerpLevel(mm: u2, pm: u2, mp: u2, pp: u2, u: f32, v: f32) f32 {
    const fmm: f32 = @floatFromInt(mm);
    const fpm: f32 = @floatFromInt(pm);
    const fmp: f32 = @floatFromInt(mp);
    const fpp: f32 = @floatFromInt(pp);
    const lo = fmm + (fpm - fmm) * u;
    const hi = fmp + (fpp - fmp) * u;
    return lo + (hi - lo) * v;
}

/// Shaded color at a fractional AO level: lerps between the two
/// adjacent LUT entries so gradients stay smooth instead of snapping
/// to the four discrete levels.
fn shadeAt(mat: u8, face: usize, level: f32) u32 {
    const l = std.math.clamp(level, 0.0, 3.0);
    const lo: usize = @intFromFloat(l);
    const hi: usize = @min(lo + 1, 3);
    const frac = l - @as(f32, @floatFromInt(lo));
    const c0 = shade_lut[mat][face][lo];
    const c1 = shade_lut[mat][face][hi];
    var out: u32 = 0xff000000;
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const a: f32 = @floatFromInt((c0 >> sh) & 0xff);
        const b: f32 = @floatFromInt((c1 >> sh) & 0xff);
        const c: u32 = @intFromFloat(a + (b - a) * frac);
        out |= c << sh;
    }
    return out;
}

/// Borrows the cursor out of an optional (null = column outside the
/// world, treated as air).
fn optCursor(oc: *?world_mod.RunCursor) ?*const world_mod.RunCursor {
    if (oc.*) |*c| return c;
    return null;
}

fn peekSolid(oc: ?*const world_mod.RunCursor, y: i32) bool {
    const c = oc orelse return false;
    return c.peek(y) != 0;
}

/// {top, bottom} AO stops for the side face of voxel y, sampled at
/// lateral face position u. n is the air-side (previous DDA cell)
/// column; la/lb are the diagonal columns on either side of it. Corner
/// queries are skipped only when both edge neighbors are solid, where
/// the corner cannot affect the level.
fn sideAoStops(n: *const world_mod.RunCursor, la: ?*const world_mod.RunCursor, lb: ?*const world_mod.RunCursor, y: i32, u: f32) [2]f32 {
    const up = n.peek(y + 1) != 0;
    const dn = n.peek(y - 1) != 0;
    const sa = peekSolid(la, y);
    const sb = peekSolid(lb, y);
    const top_a = aoLevel(up, sa, if (up and sa) false else peekSolid(la, y + 1));
    const top_b = aoLevel(up, sb, if (up and sb) false else peekSolid(lb, y + 1));
    const bot_a = aoLevel(dn, sa, if (dn and sa) false else peekSolid(la, y - 1));
    const bot_b = aoLevel(dn, sb, if (dn and sb) false else peekSolid(lb, y - 1));
    return .{ lerpLevel(top_a, top_b, u), lerpLevel(bot_a, bot_b, u) };
}

fn solidW(world: *const World, x: i32, y: i32, z: i32) bool {
    return world.get(x, y, z) != 0;
}

/// {near, far} AO stops for a horizontal face of column (ix, iz),
/// sampled at hit positions (ua, va) and (ub, vb). yf is the height of
/// the air block in front of the face (above for top, below for
/// bottom). Rare enough (run boundaries only) that direct World.get
/// queries beat maintaining eight lockstep cursors.
fn faceAoStops(world: *const World, ix: i32, iz: i32, yf: i32, ua: f32, va: f32, ub: f32, vb: f32) [2]f32 {
    const xm = solidW(world, ix - 1, yf, iz);
    const xp = solidW(world, ix + 1, yf, iz);
    const zm = solidW(world, ix, yf, iz - 1);
    const zp = solidW(world, ix, yf, iz + 1);
    const l_mm = aoLevel(xm, zm, if (xm and zm) false else solidW(world, ix - 1, yf, iz - 1));
    const l_pm = aoLevel(xp, zm, if (xp and zm) false else solidW(world, ix + 1, yf, iz - 1));
    const l_mp = aoLevel(xm, zp, if (xm and zp) false else solidW(world, ix - 1, yf, iz + 1));
    const l_pp = aoLevel(xp, zp, if (xp and zp) false else solidW(world, ix + 1, yf, iz + 1));
    return .{ bilerpLevel(l_mm, l_pm, l_mp, l_pp, ua, va), bilerpLevel(l_mm, l_pm, l_mp, l_pp, ub, vb) };
}

/// True if any free span intersects rows [r0, r1). Must gate every AO
/// computation: without this occlusion early-out, neighbor queries run
/// for faces that write no pixels and AO costs ~3x the base render.
fn spanOverlap(free: *const SpanList, r0: f32, r1: f32) bool {
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

const max_sky_height = 4096;

fn skyColor(row: usize, height: usize) u32 {
    const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(height));
    const r: u32 = @intFromFloat(88.0 + (196.0 - 88.0) * t);
    const g: u32 = @intFromFloat(118.0 + (214.0 - 118.0) * t);
    const b: u32 = @intFromFloat(186.0 + (234.0 - 186.0) * t);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

pub fn render(fb: []u32, width: usize, height: usize, world: *const World, cam: Camera, params: RenderParams) void {
    std.debug.assert(height <= max_sky_height);
    var sky_buf: [max_sky_height]u32 = undefined;
    const sky = sky_buf[0..height];
    for (sky, 0..) |*px, row| px.* = skyColor(row, height);

    const wf: f32 = @floatFromInt(width);
    const f = (wf * 0.5) / @tan(hfov * 0.5);
    const fwd = cam.forward();
    const rgt = cam.right();

    for (0..width) |sx| {
        const hx = (@as(f32, @floatFromInt(sx)) + 0.5 - wf * 0.5) / f;
        const dx = fwd[0] + rgt[0] * hx;
        const dz = fwd[1] + rgt[1] * hx;
        renderColumn(fb, height, world, cam, f, sx, dx, dz, sky, params);
    }
}

fn renderColumn(fb: []u32, height: usize, world: *const World, cam: Camera, f: f32, sx: usize, dx: f32, dz: f32, sky: []const u32, params: RenderParams) void {
    var free = SpanList.initFull(@intCast(height));

    var dda = DdaIterator.init(cam.x, cam.z, dx, dz, max_dist);
    while (dda.t0 < max_dist and !free.isEmpty()) {
        processCell(fb, height, sx, world, dda.ix, dda.iz, dda.px, dda.pz, dda.has_prev, cam.x, cam.y, cam.z, f, dx, dz, dda.t0, dda.t1(), dda.axis, &free, params);
        dda.advance();
    }

    fillSpans(fb, height, sx, &free, 0, @floatFromInt(height), SkySrc{ .sky = sky });
}

fn rowAt(y: i32, cam_y: f32, f: f32, t: f32, hf: f32) f32 {
    return hf * 0.5 - (@as(f32, @floatFromInt(y)) - cam_y) * f / t;
}

const ConstSrc = struct {
    c: u32,

    fn seek(self: *ConstSrc, row: u16) void {
        _ = self;
        _ = row;
    }

    fn next(self: *ConstSrc, row: u16) u32 {
        _ = row;
        return self.c;
    }
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

const SkySrc = struct {
    sky: []const u32,

    fn seek(self: *SkySrc, row: u16) void {
        _ = self;
        _ = row;
    }

    fn next(self: *SkySrc, row: u16) u32 {
        return self.sky[row];
    }
};

/// The single pixel-write path: claim, gradient claim, and the sky
/// fill all go through here, giving milestone 13's fog glow one
/// injection point. src provides seek(row)/next(row) color taps.
fn fillSpans(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, src: anytype) void {
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
        s.seek(ia);
        for (ia..ib) |row| {
            fb[sx * height + row] = s.next(@intCast(row));
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
fn claimGrad(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, c0: u32, c1: u32) void {
    if (c0 == c1) return claim(fb, height, sx, free, r0, r1, c0);
    if (free.isEmpty() or !(r1 > r0)) return;
    const ra: i32 = @intFromFloat(@ceil(r0));
    const rb: i32 = @intFromFloat(@ceil(r1));
    if (rb - ra <= 0) return;
    fillSpans(fb, height, sx, free, r0, r1, GradSrc.init(ra, rb, c0, c1));
}

/// Visible face fragment produced by segment generation; the single
/// record type crossing from geometry/visibility into shading. r0/r1
/// are the unclipped row range, t/ao the distance and AO stops at those
/// endpoints.
const Segment = struct {
    mat: u8,
    face: usize,
    r0: f32,
    r1: f32,
    t: [2]f32,
    ao: [2]f32,
};

/// The single LUT/light/fog composition point; milestones 8-13 extend
/// this function and nowhere else.
fn segmentColor(seg: Segment, params: RenderParams) [2]u32 {
    _ = params;
    return .{
        shadeAt(seg.mat, seg.face, seg.ao[0]),
        shadeAt(seg.mat, seg.face, seg.ao[1]),
    };
}

const SegmentSink = struct {
    fb: []u32,
    height: usize,
    sx: usize,
    free: *SpanList,
    params: RenderParams,

    fn emit(self: *SegmentSink, seg: Segment) void {
        const c = segmentColor(seg, self.params);
        claimGrad(self.fb, self.height, self.sx, self.free, seg.r0, seg.r1, c[0], c[1]);
    }
};

/// Immutable-ish cell context shared by the generation loops; the
/// neighbor cursors mutate as they walk y in lockstep.
const CellCtx = struct {
    world: *const World,
    runs: []const world_mod.MatRun,
    ix: i32,
    iz: i32,
    cam_y: f32,
    f: f32,
    t0: f32,
    t1: f32,
    hf: f32,
    ua: f32,
    va: f32,
    ub: f32,
    vb: f32,
    side_u: f32,
    side_face: usize,
    y_lo: i32,
    y_hi: i32,
    wh: i32,
    ncur: ?world_mod.RunCursor,
    lacur: ?world_mod.RunCursor,
    lbcur: ?world_mod.RunCursor,

    fn row(self: *const CellCtx, y: i32, t: f32) f32 {
        return rowAt(y, self.cam_y, self.f, t, self.hf);
    }
};

fn processCell(fb: []u32, height: usize, sx: usize, world: *const World, ix: i32, iz: i32, px: i32, pz: i32, has_prev: bool, cam_x: f32, cam_y: f32, cam_z: f32, f: f32, dx: f32, dz: f32, t0_in: f32, t1: f32, axis: Face, free: *SpanList, params: RenderParams) void {
    if (free.isEmpty()) return;
    const t0 = @max(t0_in, 1e-4);
    const hf: f32 = @floatFromInt(height);
    const s_max = hf * 0.5 / f;
    const h_hi = cam_y + @max(s_max * t0, s_max * t1);
    const h_lo = cam_y - @max(s_max * t0, s_max * t1);
    const y_lo: i32 = @max(@as(i32, @intFromFloat(@floor(h_lo))), 0);
    const y_hi: i32 = @min(@as(i32, @intFromFloat(@floor(h_hi))), @as(i32, @intCast(world.h)) - 1);
    if (y_lo > y_hi) return;
    const col = world.columnAt(ix, iz) orelse return;
    const wh: i32 = @intCast(world.h);

    // Ray position within the cell at entry (a) and exit (b), clamped
    // against float error at boundaries; AO stop sample points.
    const ixf: f32 = @floatFromInt(ix);
    const izf: f32 = @floatFromInt(iz);
    const ua = frac01(cam_x + dx * t0 - ixf);
    const va = frac01(cam_z + dz * t0 - izf);
    const ub = frac01(cam_x + dx * t1 - ixf);
    const vb = frac01(cam_z + dz * t1 - izf);
    const side_u = if (axis == .x_side) va else ua;

    var ctx: CellCtx = .{
        .world = world,
        .runs = col.runs,
        .ix = ix,
        .iz = iz,
        .cam_y = cam_y,
        .f = f,
        .t0 = t0,
        .t1 = t1,
        .hf = hf,
        .ua = ua,
        .va = va,
        .ub = ub,
        .vb = vb,
        .side_u = side_u,
        .side_face = @intFromEnum(axis),
        .y_lo = y_lo,
        .y_hi = y_hi,
        .wh = wh,
        .ncur = null,
        .lacur = null,
        .lbcur = null,
    };

    // Neighbor occupancy for face culling + side-face AO: ncur covers
    // the previous DDA cell (the air side of side faces); lacur/lbcur
    // cover the diagonal columns flanking it. All three walk y upward in
    // lockstep with the segment loop, amortized O(1) per voxel.
    if (has_prev) {
        if (world.columnAt(px, pz)) |pcol| {
            ctx.ncur = world_mod.RunCursor.init(pcol.runs, wh, y_lo);
            if (axis == .x_side) {
                if (world.columnAt(px, pz - 1)) |c| ctx.lacur = world_mod.RunCursor.init(c.runs, wh, y_lo);
                if (world.columnAt(px, pz + 1)) |c| ctx.lbcur = world_mod.RunCursor.init(c.runs, wh, y_lo);
            } else {
                if (world.columnAt(px - 1, pz)) |c| ctx.lacur = world_mod.RunCursor.init(c.runs, wh, y_lo);
                if (world.columnAt(px + 1, pz)) |c| ctx.lbcur = world_mod.RunCursor.init(c.runs, wh, y_lo);
            }
        }
    }

    var sink: SegmentSink = .{ .fb = fb, .height = height, .sx = sx, .free = free, .params = params };
    genSegments(&ctx, &sink);
}

/// Segment generation: geometry/visibility only, emitting Segment
/// records front-to-back. All shading decisions live in segmentColor.
fn genSegments(ctx: *CellCtx, sink: *SegmentSink) void {
    const free = sink.free;
    const top_face: usize = @intFromEnum(Face.top);
    const bottom_face: usize = @intFromEnum(Face.bottom);

    var y = ctx.y_lo;
    var cur = world_mod.RunCursor.init(ctx.runs, ctx.wh, ctx.y_lo);
    while (y <= ctx.y_hi) {
        const seg_lo = y;
        const seg_hi = @min(cur.hi, ctx.y_hi);
        if (cur.mat() != 0) {
            const mat = cur.mat();
            if (ctx.ncur) |*n| {
                var sy = seg_lo;
                while (sy <= seg_hi) {
                    while (sy > n.hi) n.up();
                    const e = @min(seg_hi, n.hi);
                    if (n.mat() == 0 and spanOverlap(free, ctx.row(e + 1, ctx.t0), ctx.row(sy, ctx.t0))) {
                        // Air-backed sub-segment: claim per voxel with
                        // AO stops. Stops are not shareable between
                        // adjacent voxels (the below-voxel's top corner
                        // and the above-voxel's bottom corner sample
                        // different air-side voxels), but runs of max-AO
                        // voxels accumulate in [pend, yy) and flush as
                        // one constant segment.
                        var pend = sy;
                        var yy = sy;
                        while (yy <= e) : (yy += 1) {
                            if (ctx.lacur) |*la| {
                                while (yy > la.hi) la.up();
                            }
                            if (ctx.lbcur) |*lb| {
                                while (yy > lb.hi) lb.up();
                            }
                            const stops = sideAoStops(n, optCursor(&ctx.lacur), optCursor(&ctx.lbcur), yy, ctx.side_u);
                            if (stops[0] == 3 and stops[1] == 3) continue;
                            if (pend < yy) {
                                sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 } });
                            }
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = stops });
                            pend = yy + 1;
                        }
                        if (pend <= e) {
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(e + 1, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 } });
                        }
                        if (free.isEmpty()) return;
                    }
                    sy = e + 1;
                }
            } else {
                sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(seg_hi + 1, ctx.t0), .r1 = ctx.row(seg_lo, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 } });
                if (free.isEmpty()) return;
            }
            // Bottom face visible only at a run's lower boundary where
            // the voxel below is air; interior planes are provably
            // occluded by the nearer voxel.
            const below_air = seg_lo == cur.lo and
                (cur.idx + 1 >= cur.runs.len or cur.runs[cur.idx + 1].palette_id == 0);
            if (below_air) {
                const r_near = ctx.row(seg_lo, ctx.t0);
                const r_far = ctx.row(seg_lo, ctx.t1);
                if (spanOverlap(free, r_near, r_far)) {
                    const stops = faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_lo - 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = mat, .face = bottom_face, .r0 = r_near, .r1 = r_far, .t = .{ ctx.t0, ctx.t1 }, .ao = stops });
                    if (free.isEmpty()) return;
                }
            }
        }
        y = seg_hi + 1;
        if (y <= ctx.y_hi) cur.up();
    }

    y = ctx.y_hi;
    cur = world_mod.RunCursor.init(ctx.runs, ctx.wh, ctx.y_hi);
    while (y >= ctx.y_lo) {
        const seg_hi = y;
        const seg_lo = @max(cur.lo, ctx.y_lo);
        if (cur.mat() != 0) {
            // Top face visible only at a run's upper boundary.
            const above_air = seg_hi == cur.hi and
                (cur.idx == 0 or cur.runs[cur.idx - 1].palette_id == 0);
            if (above_air) {
                const r_far = ctx.row(seg_hi + 1, ctx.t1);
                const r_near = ctx.row(seg_hi + 1, ctx.t0);
                if (spanOverlap(free, r_far, r_near)) {
                    const stops = faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_hi + 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = cur.mat(), .face = top_face, .r0 = r_far, .r1 = r_near, .t = .{ ctx.t1, ctx.t0 }, .ao = .{ stops[1], stops[0] } });
                    if (free.isEmpty()) return;
                }
            }
        }
        y = seg_lo - 1;
        if (y >= ctx.y_lo) cur.down();
    }
}

pub fn transpose(dst: []u32, src: []const u32, width: usize, height: usize) void {
    for (0..width) |x| {
        for (0..height) |y| {
            dst[y * width + x] = src[x * height + y];
        }
    }
}

pub fn writePpm(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pixels: []const u32, width: usize, height: usize) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{} {}\n255\n", .{ width, height });
    defer allocator.free(header);
    const body = try allocator.alloc(u8, header.len + width * height * 3);
    defer allocator.free(body);
    @memcpy(body[0..header.len], header);
    for (pixels, 0..) |p, i| {
        body[header.len + i * 3 + 0] = @truncate(p >> 16);
        body[header.len + i * 3 + 1] = @truncate(p >> 8);
        body[header.len + i * 3 + 2] = @truncate(p);
    }
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = body });
}

test "face ao darkens toward a taller neighbor" {
    var world = try World.init(std.testing.allocator, 4, 16, 4);
    defer world.deinit();
    try world.fillBox(1, 0, 1, 2, 5, 2, 7);
    try world.fillBox(2, 0, 1, 3, 6, 2, 7);
    const open = faceAoStops(&world, 1, 1, 5, 0.1, 0.5, 0.1, 0.5);
    try std.testing.expectApproxEqAbs(2.9, open[0], 1e-6);
    const near = faceAoStops(&world, 1, 1, 5, 0.9, 0.5, 0.9, 0.5);
    try std.testing.expect(near[0] < 3);
    const diag = faceAoStops(&world, 1, 1, 5, 0.9, 0.9, 0.9, 0.9);
    try std.testing.expect(diag[0] < 3);
}

test "ao level truth table" {
    try std.testing.expectEqual(0, aoLevel(true, true, false));
    try std.testing.expectEqual(0, aoLevel(true, true, true));
    try std.testing.expectEqual(1, aoLevel(true, false, true));
    try std.testing.expectEqual(2, aoLevel(true, false, false));
    try std.testing.expectEqual(2, aoLevel(false, false, true));
    try std.testing.expectEqual(3, aoLevel(false, false, false));
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
