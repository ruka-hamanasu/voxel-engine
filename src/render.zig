const std = @import("std");
const world_mod = @import("world.zig");
const camera_mod = @import("camera.zig");
const lighting = @import("lighting.zig");

const World = world_mod.World;
const Camera = camera_mod.Camera;

pub const hfov: f32 = std.math.pi / 2.0;
pub const max_dist: f32 = 96.0;

/// Per-frame render configuration, threaded render -> renderColumn ->
/// processCell. fog_* went live in milestone 8, light in milestone 9;
/// sun/time/glow land in milestones 10-13.
pub const RenderParams = struct {
    fog_density: f32 = 0.025,
    fog_cutoff: f32 = max_dist,
    fog_color: u32 = 0x8ea6d2, // horizon-row sky color
    /// false = treat every column as unlit (identity tint), ignoring
    /// the flood-filled light runs; runtime toggle for the L hotkey.
    light: bool = true,
    sun_azimuth: f32 = 0.0,
    sun_elevation: f32 = 0.0,
    time_s: f64 = 0.0,
    glow_map: ?*const anyopaque = null,
};

const Face = enum(u2) { top, bottom, x_side, z_side };

/// 2D Amanatides-Woo XZ marcher. Extracted from renderColumn so the
/// milestone-12 sun shadow march reuses the identical stepping math
/// (elevation makes the shadow ray's height interval affine in t).
/// The field-access + advance() shape is deliberate: an iterator
/// next() ?DdaCell returning a cell record by value cost ~7% (state
/// spilled to memory each cell); this form is free.
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

/// Distance fog (milestone 8). fog_factor buckets a normalized
/// exponential falloff over [0, fog_cutoff]; fog_dest is the low-pass
/// variant: each material's color pre-collapses toward the shared fog
/// color on a front-loaded curve, so distant hues die before the
/// geometry fades, killing sub-pixel chromatic shimmer at 480x270.
/// Emissive materials ride separate row rules: half density, fading
/// toward a saturated version of their own color (volumetric neon
/// haze; dormant until milestone 9 flips crystals 9-11).
pub const fog_buckets = 64;

var fog_factor: [fog_buckets]f32 = undefined;
var fog_dest: [world_mod.default_palette.len][fog_buckets]u32 = undefined;

fn lerpColor(a: u32, b: u32, f: f32) u32 {
    var out: u32 = 0xff000000;
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const ca: f32 = @floatFromInt((a >> sh) & 0xff);
        const cb: f32 = @floatFromInt((b >> sh) & 0xff);
        const ch: u32 = @intFromFloat(ca + (cb - ca) * f);
        out |= ch << sh;
    }
    return out;
}

/// Normalized exponential falloff: 0 at t=0, exactly 1 at the cutoff,
/// so geometry at the march limit is indistinguishable from the fogged
/// horizon.
fn fogCurve(density: f32, t: f32, cutoff: f32) f32 {
    return (1.0 - @exp(-density * t)) / (1.0 - @exp(-density * cutoff));
}

fn buildFogLuts(params: RenderParams) void {
    const buckets_f: f32 = @floatFromInt(fog_buckets);
    for (0..fog_buckets) |b| {
        const t = (@as(f32, @floatFromInt(b)) + 0.5) * params.fog_cutoff / buckets_f;
        fog_factor[b] = fogCurve(params.fog_density, t, params.fog_cutoff);
    }
    for (world_mod.palette, 0..) |entry, m| {
        if (entry.emissive != 0) {
            const maxc: f32 = @floatFromInt(@max((entry.rgb >> 16) & 0xff, @max((entry.rgb >> 8) & 0xff, entry.rgb & 0xff)));
            const s = if (maxc > 0) 255.0 / maxc else 1.0;
            var sat: u32 = 0xff000000;
            inline for (0..3) |k| {
                const sh: u5 = @intCast((2 - k) * 8);
                const ch: f32 = @floatFromInt((entry.rgb >> sh) & 0xff);
                const v: u32 = @intFromFloat(@min(ch * s, 255.0));
                sat |= v << sh;
            }
            for (0..fog_buckets) |b| {
                const t = (@as(f32, @floatFromInt(b)) + 0.5) * params.fog_cutoff / buckets_f;
                fog_dest[m][b] = lerpColor(entry.rgb, sat, fogCurve(params.fog_density * 0.5, t, params.fog_cutoff));
            }
        } else {
            for (0..fog_buckets) |b| {
                const f = fog_factor[b];
                const lp = 1.0 - (1.0 - f) * (1.0 - f);
                fog_dest[m][b] = lerpColor(entry.rgb, params.fog_color, lp);
            }
        }
    }
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
    const fog_on = params.fog_density > 0;
    if (fog_on) buildFogLuts(params);

    var sky_buf: [max_sky_height]u32 = undefined;
    const sky = sky_buf[0..height];
    for (sky, 0..) |*px, row| px.* = skyColor(row, height);
    if (fog_on) {
        // Blend the sky toward the fog color around the horizon row
        // (always height/2: yaw-only camera) so geometry fogged out at
        // the cutoff meets the backdrop seamlessly.
        const hf: f32 = @floatFromInt(height);
        const horizon = hf * 0.5;
        const band = hf * 0.25;
        for (sky, 0..) |*px, row| {
            const w = 1.0 - @abs(@as(f32, @floatFromInt(row)) + 0.5 - horizon) / band;
            if (w > 0) px.* = lerpColor(px.*, params.fog_color, w);
        }
    }

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

    // March no farther than the fog cutoff: every later hit is fully
    // fogged, so the remaining free spans might as well be sky (whose
    // horizon row is the fog color).
    const limit = @min(max_dist, params.fog_cutoff);
    var dda = DdaIterator.init(cam.x, cam.z, dx, dz, max_dist);
    while (dda.t0 < limit and !free.isEmpty()) {
        processCell(fb, height, sx, world, dda.ix, dda.iz, dda.px, dda.pz, dda.has_prev, cam.x, cam.y, cam.z, f, dx, dz, dda.t0, dda.t1(), dda.axis, &free, params);
        dda.advance();
    }

    fillSpans(fb, height, sx, &free, 0, @floatFromInt(height), SkySrc{ .sky = sky });
}

fn rowAt(y: i32, cam_y: f32, f: f32, t: f32, hf: f32) f32 {
    // Per-cell reciprocal strength reduction (c - y*k, hoisting the
    // divide) was tried and REVERTED: the distributed form rounds
    // differently than (y - cam_y) * f / t and flips tie-break rows
    // when the camera sits at an exact integer height. Keep the
    // original op sequence.
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
/// endpoints. light is sampled at the air cell the face is exposed to
/// (side faces: the previous DDA cell's column; top/bottom faces: one
/// voxel above/below in the face's own column), uniform per segment —
/// the zipper splits segments at light-run boundaries. intensity 0 =
/// no colored light.
const Segment = struct {
    mat: u8,
    face: u8,
    r0: f32,
    r1: f32,
    t: [2]f32,
    ao: [2]f32,
    light: lighting.LightSample = .{},
};

/// Lerp-to-white glow tint (the Gemini doc's BlendWithGlow): intensity
/// scales tint strength, so intensity 0 is identity and the flood edge
/// fades continuously into unlit geometry instead of clipping to black.
fn applyLight(c: u32, light: lighting.LightSample) u32 {
    const f = @as(f32, @floatFromInt(light.intensity)) * (1.0 / 255.0);
    const lc = lighting.lightColor(light.color_id);
    var out: u32 = 0xff000000;
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const ch: f32 = @floatFromInt((c >> sh) & 0xff);
        const lch: f32 = @floatFromInt((lc >> sh) & 0xff);
        const v: u32 = @intFromFloat(ch * (255.0 + (lch - 255.0) * f) * (1.0 / 255.0));
        out |= v << sh;
    }
    return out;
}

/// The single LUT/light/fog composition point; milestones 8-13 extend
/// this function and nowhere else.
fn segmentColor(seg: Segment, params: RenderParams) [2]u32 {
    var c0 = shadeAt(seg.mat, seg.face, seg.ao[0]);
    var c1 = shadeAt(seg.mat, seg.face, seg.ao[1]);
    // Emissive materials stay full-bright (shade LUT bypass), so their
    // own seed light is not reapplied on top.
    if (seg.light.intensity != 0 and world_mod.palette[seg.mat].emissive == 0) {
        c0 = applyLight(c0, seg.light);
        c1 = applyLight(c1, seg.light);
    }
    if (params.fog_density <= 0) return .{ c0, c1 };
    return .{
        fogStop(seg.mat, seg.t[0], c0, params),
        fogStop(seg.mat, seg.t[1], c1, params),
    };
}

/// Fog one shaded stop: bucket the distance, lerp toward the material's
/// (pre-collapsed) fog destination. Per-stop so the gradient fill
/// lerps between fogged endpoints.
fn fogStop(mat: u8, t: f32, c: u32, params: RenderParams) u32 {
    const scale = @as(f32, @floatFromInt(fog_buckets)) / params.fog_cutoff;
    const b: usize = @intFromFloat(std.math.clamp(t * scale, 0.0, @as(f32, @floatFromInt(fog_buckets - 1))));
    return lerpColor(c, fog_dest[mat][b], fog_factor[b]);
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
    col: *const world_mod.Column,
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
    side_face: u8,
    y_lo: i32,
    y_hi: i32,
    wh: i32,
    ncur: ?world_mod.RunCursor,
    lacur: ?world_mod.RunCursor,
    lbcur: ?world_mod.RunCursor,
    /// Light zipper state (milestone 9): cursors over the current and
    /// neighbor (previous DDA cell) columns' light runs plus their
    /// coverages (lo, hi]. Face light is sampled from the air cell in
    /// front of the face — side faces read the NEIGHBOR column, so a
    /// wall lit on its far side never glows through to its near side.
    lcur: ?world_mod.LightCursor,
    light_lo: i32,
    light_hi: i32,
    nlcur: ?world_mod.LightCursor,
    nlight_lo: i32,
    nlight_hi: i32,

    fn row(self: *const CellCtx, y: i32, t: f32) f32 {
        return rowAt(y, self.cam_y, self.f, t, self.hf);
    }

    /// Light of the current column at y (camera-cell side faces only;
    /// top/bottom faces use sampleLight scans). comptime lit = false
    /// folds every query to the default, letting genSegments' unlit
    /// specialization compile to the pre-lighting code shape.
    fn lightAt(self: *CellCtx, comptime lit: bool, y: i32) LightQuery {
        if (!lit) return .{ .sample = .{}, .hi = self.y_hi };
        return queryLightRuns(&self.lcur, self.light_lo, self.light_hi, self.y_hi, y);
    }

    /// Light of the air cell in front of the side face at y (the
    /// previous DDA cell's column), advancing the lockstep cursor.
    fn nLightAt(self: *CellCtx, comptime lit: bool, y: i32) LightQuery {
        if (!lit) return .{ .sample = .{}, .hi = self.y_hi };
        return queryLightRuns(&self.nlcur, self.nlight_lo, self.nlight_hi, self.y_hi, y);
    }
};

/// Light sample at y plus the top of its uniform run; queries must be
/// non-decreasing in y. Outside the runs' coverage the identity
/// default applies, with .hi set to the next coverage boundary so
/// callers can span whole default-lit ranges in one segment. A null
/// cursor yields the default everywhere.
fn queryLightRuns(oc: *?world_mod.LightCursor, lo: i32, hi: i32, fallback_hi: i32, y: i32) LightQuery {
    if (oc.* == null) return .{ .sample = .{}, .hi = fallback_hi };
    const lc = &oc.*.?;
    if (y > hi) return .{ .sample = .{}, .hi = fallback_hi };
    if (y < lo) return .{ .sample = .{}, .hi = lo - 1 };
    while (y > lc.hi) lc.up();
    const run = lc.runs[lc.idx];
    return .{ .sample = .{ .color_id = run.color_id, .intensity = run.intensity }, .hi = lc.hi };
}

const LightQuery = struct {
    sample: lighting.LightSample,
    hi: i32,
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
        .col = col,
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
        .lcur = null,
        .light_lo = 0,
        .light_hi = -1,
        .nlcur = null,
        .nlight_lo = 0,
        .nlight_hi = -1,
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

    // Light zipper cursors over the current column (camera-cell side
    // faces) and the previous DDA cell's column (the air in front of
    // side faces). Both walk y upward in lockstep with the segment
    // loop, initialized clamped into coverage so out-of-coverage bands
    // query as defaults. The params.light toggle treats every column
    // as unlit.
    if (params.light) {
        if (col.light) |lruns| {
            var total: i32 = 0;
            for (lruns) |r| total += r.count;
            ctx.light_hi = col.light_base_y;
            ctx.light_lo = ctx.light_hi - total + 1;
            ctx.lcur = world_mod.LightCursor.init(lruns, ctx.light_hi + 1, std.math.clamp(y_lo, ctx.light_lo, ctx.light_hi));
        }
        if (has_prev) {
            if (world.columnAt(px, pz)) |pcol| {
                if (pcol.light) |nruns| {
                    var total: i32 = 0;
                    for (nruns) |r| total += r.count;
                    ctx.nlight_hi = pcol.light_base_y;
                    ctx.nlight_lo = ctx.nlight_hi - total + 1;
                    ctx.nlcur = world_mod.LightCursor.init(nruns, ctx.nlight_hi + 1, std.math.clamp(y_lo, ctx.nlight_lo, ctx.nlight_hi));
                }
            }
        }
    }

    var sink: SegmentSink = .{ .fb = fb, .height = height, .sx = sx, .free = free, .params = params };
    if (ctx.lcur != null or ctx.nlcur != null) {
        genSegments(&ctx, &sink, true);
    } else {
        genSegments(&ctx, &sink, false);
    }
}

/// Segment generation: geometry/visibility only, emitting Segment
/// records front-to-back. All shading decisions live in segmentColor.
/// comptime lit selects the light-zipper code paths; columns without
/// light runs compile them away entirely.
fn genSegments(ctx: *CellCtx, sink: *SegmentSink, comptime lit: bool) void {
    const free = sink.free;
    const top_face: u8 = @intFromEnum(Face.top);
    const bottom_face: u8 = @intFromEnum(Face.bottom);

    var y = ctx.y_lo;
    var cur = world_mod.RunCursor.init(ctx.col.runs, ctx.wh, ctx.y_lo);
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
                        // one constant segment; a light-run boundary in
                        // the air-side column breaks the accumulation
                        // the same way, so every emitted segment has
                        // uniform light.
                        var pend = sy;
                        var pend_light = ctx.nLightAt(lit, sy).sample;
                        var yy = sy;
                        while (yy <= e) : (yy += 1) {
                            if (ctx.lacur) |*la| {
                                while (yy > la.hi) la.up();
                            }
                            if (ctx.lbcur) |*lb| {
                                while (yy > lb.hi) lb.up();
                            }
                            const stops = sideAoStops(n, optCursor(&ctx.lacur), optCursor(&ctx.lbcur), yy, ctx.side_u);
                            const lq = ctx.nLightAt(lit, yy);
                            if (stops[0] == 3 and stops[1] == 3 and (!lit or std.meta.eql(lq.sample, pend_light))) continue;
                            if (pend < yy) {
                                sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = pend_light });
                            }
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = stops, .light = lq.sample });
                            pend = yy + 1;
                            pend_light = if (lit and pend <= e) ctx.nLightAt(lit, pend).sample else .{};
                        }
                        if (pend <= e) {
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(e + 1, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = pend_light });
                        }
                        if (free.isEmpty()) return;
                    }
                    sy = e + 1;
                }
            } else if (!lit) {
                sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(seg_hi + 1, ctx.t0), .r1 = ctx.row(seg_lo, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 } });
                if (free.isEmpty()) return;
            } else {
                // Zipper: split the span at light-run boundaries so each
                // emitted segment carries a uniform light sample. With
                // no light runs this is a single iteration emitting the
                // same constant segment as before lighting.
                var yy = seg_lo;
                while (yy <= seg_hi) {
                    const lq = ctx.lightAt(lit, yy);
                    const e2 = @min(seg_hi, lq.hi);
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(e2 + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = lq.sample });
                    yy = e2 + 1;
                }
                if (free.isEmpty()) return;
            }
            // Bottom face visible only at a run's lower boundary where
            // the voxel below is air; interior planes are provably
            // occluded by the nearer voxel. Light comes from the air
            // cell below the face.
            const below_air = seg_lo == cur.lo and
                (cur.idx + 1 >= cur.runs.len or cur.runs[cur.idx + 1].palette_id == 0);
            if (below_air) {
                const r_near = ctx.row(seg_lo, ctx.t0);
                const r_far = ctx.row(seg_lo, ctx.t1);
                if (spanOverlap(free, r_near, r_far)) {
                    const stops = faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_lo - 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = mat, .face = bottom_face, .r0 = r_near, .r1 = r_far, .t = .{ ctx.t0, ctx.t1 }, .ao = stops, .light = if (lit) lighting.sampleLight(ctx.col, seg_lo - 1) else .{} });
                    if (free.isEmpty()) return;
                }
            }
        }
        y = seg_hi + 1;
        if (y <= ctx.y_hi) cur.up();
    }

    y = ctx.y_hi;
    cur = world_mod.RunCursor.init(ctx.col.runs, ctx.wh, ctx.y_hi);
    while (y >= ctx.y_lo) {
        const seg_hi = y;
        const seg_lo = @max(cur.lo, ctx.y_lo);
        if (cur.mat() != 0) {
            // Top face visible only at a run's upper boundary. Light
            // comes from the air cell above the face, via a plain scan
            // (boundary-only, rare) rather than the zipper cursor,
            // which walks upward.
            const above_air = seg_hi == cur.hi and
                (cur.idx == 0 or cur.runs[cur.idx - 1].palette_id == 0);
            if (above_air) {
                const r_far = ctx.row(seg_hi + 1, ctx.t1);
                const r_near = ctx.row(seg_hi + 1, ctx.t0);
                if (spanOverlap(free, r_far, r_near)) {
                    const stops = faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_hi + 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = cur.mat(), .face = top_face, .r0 = r_far, .r1 = r_near, .t = .{ ctx.t1, ctx.t0 }, .ao = .{ stops[1], stops[0] }, .light = if (lit) lighting.sampleLight(ctx.col, seg_hi + 1) else .{} });
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

test "fog lut is monotonic and saturates at the cutoff" {
    const params: RenderParams = .{};
    buildFogLuts(params);
    var prev: f32 = 0;
    for (fog_factor) |f| {
        try std.testing.expect(f >= prev);
        prev = f;
    }
    try std.testing.expect(fog_factor[0] > 0);
    try std.testing.expectApproxEqAbs(1.0, fog_factor[fog_buckets - 1], 0.01);
    // Low-pass dest of a normal material converges to the fog color.
    const dest = fog_dest[1][fog_buckets - 1];
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const got: i32 = @intCast((dest >> sh) & 0xff);
        const want: i32 = @intCast((params.fog_color >> sh) & 0xff);
        try std.testing.expect(@abs(got - want) <= 2);
    }
    // Near distances keep (almost) the material's own color.
    const near = fog_dest[1][0];
    try std.testing.expect(@abs(@as(i32, @intCast((near >> 16) & 0xff)) - 0x8c) <= 4);
}

test "fog disabled leaves segment colors untouched" {
    const seg: Segment = .{ .mat = 1, .face = 0, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 2 } };
    const c = segmentColor(seg, .{ .fog_density = 0 });
    try std.testing.expectEqual(shadeAt(1, 0, 3), c[0]);
    try std.testing.expectEqual(shadeAt(1, 0, 2), c[1]);
}

test "light tints shaded stops; zero intensity is identity" {
    const plain = segmentColor(.{ .mat = 1, .face = 0, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 } }, .{ .fog_density = 0 });
    const zero = segmentColor(.{ .mat = 1, .face = 0, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 0 } }, .{ .fog_density = 0 });
    try std.testing.expectEqual(plain, zero);

    // Full-intensity cyan scales each channel by the crystal's rgb.
    const lit = segmentColor(.{ .mat = 1, .face = 0, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 255 } }, .{ .fog_density = 0 });
    const shaded = shadeAt(1, 0, 3);
    const want = [3]u32{ ((shaded >> 16) & 0xff) * 0x46 / 255, ((shaded >> 8) & 0xff) * 0xe6 / 255, (shaded & 0xff) * 0xe6 / 255 };
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const got: i32 = @intCast((lit[0] >> sh) & 0xff);
        try std.testing.expect(@abs(got - @as(i32, @intCast(want[k]))) <= 1);
    }

    // Half intensity tints halfway from white.
    const half = segmentColor(.{ .mat = 1, .face = 0, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 128 } }, .{ .fog_density = 0 });
    const full_r: i32 = @intCast((lit[0] >> 16) & 0xff);
    const plain_r: i32 = @intCast((plain[0] >> 16) & 0xff);
    const half_r: i32 = @intCast((half[0] >> 16) & 0xff);
    try std.testing.expect(@abs(half_r - @divTrunc(full_r + plain_r, 2)) <= 2);
}

test "emissive materials bypass the light tint" {
    const seg: Segment = .{ .mat = 9, .face = 2, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 10, .intensity = 255 } };
    const c = segmentColor(seg, .{ .fog_density = 0 });
    try std.testing.expectEqual(shadeAt(9, 2, 3), c[0]);
}

test "fogged segment converges to the fog color at the cutoff" {
    const params: RenderParams = .{};
    buildFogLuts(params);
    const seg: Segment = .{ .mat = 1, .face = 2, .r0 = 0, .r1 = 10, .t = .{ params.fog_cutoff, params.fog_cutoff }, .ao = .{ 3, 3 } };
    const c = segmentColor(seg, params);
    try std.testing.expectEqual(c[0], c[1]);
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const got: i32 = @intCast((c[0] >> sh) & 0xff);
        const want: i32 = @intCast((params.fog_color >> sh) & 0xff);
        try std.testing.expect(@abs(got - want) <= 2);
    }
}

test "emissive materials fade slower and toward their own color" {
    const params: RenderParams = .{};
    defer buildFogLuts(params);
    const saved = world_mod.palette[9];
    defer world_mod.palette[9] = saved;
    world_mod.palette[9].emissive = 1;
    buildFogLuts(params);
    const mid = fog_buckets / 2;
    // A normal material at the same distance is nearly all fog color...
    const normal = fog_dest[1][mid];
    try std.testing.expect(@abs(@as(i32, @intCast((normal >> 8) & 0xff)) - 0xa6) <= 8);
    // ...while the emissive crystal keeps its saturated cyan hue.
    const glow = fog_dest[9][mid];
    try std.testing.expect((glow >> 8) & 0xff > 200);
    try std.testing.expect(glow & 0xff > 200);
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
