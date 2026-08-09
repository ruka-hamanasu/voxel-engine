const std = @import("std");
const world_mod = @import("world.zig");
const camera_mod = @import("camera.zig");
const lighting = @import("lighting.zig");
const spans = @import("render/spans.zig");
const ao = @import("render/ao.zig");
const shade = @import("render/shade.zig");

const World = world_mod.World;
const Camera = camera_mod.Camera;
const SpanList = spans.SpanList;
const Face = shade.Face;
const OFace = shade.OFace;

pub const hfov: f32 = std.math.pi / 2.0;
/// March hard cap. The fine world only ever marches to lod_dist; the
/// coarse (LOD) world absorbs everything past it, so this can sit far
/// above the default fog cutoff.
pub const max_dist: f32 = 256.0;
/// Tallest renderable frame (the sky gradient buffer is stack-sized).
pub const max_sky_height = shade.max_sky_height;

/// Per-frame render configuration, threaded render -> renderColumn ->
/// processCell. fog_* went live in milestone 8, light in milestone 9.
pub const RenderParams = struct {
    fog_density: f32 = 0.025,
    fog_cutoff: f32 = 96.0,
    fog_color: u32 = 0x8ea6d2, // horizon-row sky color
    /// false = treat every column as unlit (identity tint), ignoring
    /// the flood-filled light runs; runtime toggle for the L hotkey.
    light: bool = true,
    time_s: f64 = 0.0,
    /// Fine/coarse march handoff distance. Past it the ray continues
    /// in the half-resolution LOD world (~77% fogged at the default
    /// 48, so the silhouette overestimate stays hidden). No effect
    /// when render's lod is null.
    lod_dist: f32 = 48.0,
};

/// Rebuild the shade LUT after a palette mutation (milestone 10 calls
/// this per frame while animating).
pub const rebuildShadeLut = shade.rebuildShadeLut;

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

pub fn render(fb: []u32, width: usize, height: usize, world: *const World, lod: ?*const World, cam: Camera, params: RenderParams) void {
    std.debug.assert(height <= shade.max_sky_height);
    const fog_on = params.fog_density > 0;
    if (fog_on) shade.buildFogLuts(params);

    var sky_buf: [shade.max_sky_height]u32 = undefined;
    const sky = sky_buf[0..height];
    for (sky, 0..) |*px, row| px.* = shade.skyColor(row, height);
    if (fog_on) {
        // Blend the sky toward the fog color around the horizon row
        // (always height/2: yaw-only camera) so geometry fogged out at
        // the cutoff meets the backdrop seamlessly.
        const hf: f32 = @floatFromInt(height);
        const horizon = hf * 0.5;
        const band = hf * 0.25;
        for (sky, 0..) |*px, row| {
            const w = 1.0 - @abs(@as(f32, @floatFromInt(row)) + 0.5 - horizon) / band;
            if (w > 0) px.* = shade.lerpColor(px.*, params.fog_color, w);
        }
    }

    const wf: f32 = @floatFromInt(width);
    const hf0: f32 = @floatFromInt(height);
    const f = (wf * 0.5) / @tan(hfov * 0.5);
    // Vertical half-window slope (rows per unit XZ distance), hoisted
    // out of the per-cell window math.
    const s_max = hf0 * 0.5 / f;
    const fwd = cam.forward();
    const rgt = cam.right();

    for (0..width) |sx| {
        const hx = (@as(f32, @floatFromInt(sx)) + 0.5 - wf * 0.5) / f;
        const dx = fwd[0] + rgt[0] * hx;
        const dz = fwd[1] + rgt[1] * hx;
        renderColumn(fb, height, world, lod, cam, f, s_max, sx, dx, dz, sky, params);
    }
}

/// One march's geometric frame: which world, and how ray distance t
/// maps into its coordinate system. The LOD march scales all lengths
/// by 1/2 (cam and direction halved, f doubled), which leaves
/// processCell's row and window math form-invariant: a coarse voxel at
/// y_c projects exactly like the 2 fine voxels it covers.
const MarchCfg = struct {
    world: *const World,
    cam_x: f32,
    cam_y: f32,
    cam_z: f32,
    f: f32,
    s_max: f32,
    dx: f32,
    dz: f32,
};

fn renderColumn(fb: []u32, height: usize, world: *const World, lod: ?*const World, cam: Camera, f: f32, s_max: f32, sx: usize, dx: f32, dz: f32, sky: []const u32, params: RenderParams) void {
    var free = SpanList.initFull(@intCast(height));

    // March no farther than the fog cutoff: every later hit is fully
    // fogged, so the remaining free spans might as well be sky (whose
    // horizon row is the fog color).
    const limit = @min(max_dist, params.fog_cutoff);
    const cfg: MarchCfg = .{ .world = world, .cam_x = cam.x, .cam_y = cam.y, .cam_z = cam.z, .f = f, .s_max = s_max, .dx = dx, .dz = dz };
    const t_switch = if (lod != null) @min(params.lod_dist, limit) else limit;
    marchRange(fb, height, sx, cfg, 0, t_switch, &free, params);
    if (lod) |lw| {
        if (t_switch < limit and !free.isEmpty()) {
            const cfg2: MarchCfg = .{ .world = lw, .cam_x = cam.x * 0.5, .cam_y = cam.y * 0.5, .cam_z = cam.z * 0.5, .f = f * 2.0, .s_max = s_max * 0.5, .dx = dx * 0.5, .dz = dz * 0.5 };
            marchRange(fb, height, sx, cfg2, t_switch, limit, &free, params);
        }
    }

    spans.fillSpans(fb, height, sx, &free, 0, @floatFromInt(height), spans.SkySrc{ .sky = sky });
}

/// March cfg's world over absolute ray distances [t_begin, t_end).
/// With t_begin = 0 this is bit-identical to the plain single-world
/// march (same DDA state, same processCell arguments). The cell-exit
/// clamp preserves the historical max_dist = 96 semantics: t1 may
/// overshoot t_end up to 96 (or t_end when that is larger), which only
/// affects cells straddling the march limit and keeps the --lod 0 path
/// byte-identical.
fn marchRange(fb: []u32, height: usize, sx: usize, cfg: MarchCfg, t_begin: f32, t_end: f32, free: *SpanList, params: RenderParams) void {
    const world = cfg.world;
    const t_clamp = @max(96.0, t_end);
    var dda = DdaIterator.init(cfg.cam_x + cfg.dx * t_begin, cfg.cam_z + cfg.dz * t_begin, cfg.dx, cfg.dz, t_clamp - t_begin);
    while (t_begin + dda.t0 < t_end and !free.isEmpty()) {
        const t0 = t_begin + dda.t0;
        const t1 = t_begin + dda.t1();
        // Macro-cell skip: the whole 8x8 group is provably below the
        // ray's height window (or out of the world entirely), so
        // processCell would emit nothing — decided without loading a
        // single Column (the macro grid stays L1-resident). Exact:
        // h_lo > mmax + 1 implies y_lo > top_solid for every column in
        // the group, the per-column sky-skip's own condition.
        if (world.macro_ok) {
            const t0c = @max(t0, 1e-4); // processCell's own clamp
            const h_lo = cfg.cam_y - @max(cfg.s_max * t0c, cfg.s_max * t1);
            const mmax = world.macroMax(dda.ix, dda.iz) orelse {
                dda.advance();
                continue;
            };
            if (h_lo > @as(f32, @floatFromInt(mmax)) + 1.0) {
                dda.advance();
                continue;
            }
        }
        processCell(fb, height, sx, world, dda.ix, dda.iz, dda.px, dda.pz, dda.has_prev, cfg.cam_x, cfg.cam_y, cfg.cam_z, cfg.f, cfg.s_max, cfg.dx, cfg.dz, t0, t1, dda.axis, free, params);
        dda.advance();
    }
}

fn rowAt(y: i32, cam_y: f32, f: f32, t: f32, hf: f32) f32 {
    // Per-cell reciprocal strength reduction (c - y*k, hoisting the
    // divide) was tried and REVERTED: the distributed form rounds
    // differently than (y - cam_y) * f / t and flips tie-break rows
    // when the camera sits at an exact integer height. Keep the
    // original op sequence.
    return hf * 0.5 - (@as(f32, @floatFromInt(y)) - cam_y) * f / t;
}

/// Visible face fragment produced by segment generation; the single
/// record type crossing from geometry/visibility into shading. r0/r1
/// are the unclipped row range, t/ao the distance and AO stops at those
/// endpoints. light is sampled at the air cell the face is exposed to
/// (side faces: the previous DDA cell's column; top/bottom faces: one
/// voxel above/below in the face's own column), uniform per segment —
/// the zipper splits segments at light-run boundaries. intensity 0 =
/// no colored light. segmentColor scales intensity by the alignment of
/// the sample's arrival direction with the (oriented) face normal.
/// sky is the milestone-11 analytic bit (1 = the face's air cell is
/// above its column's topmost solid); segments split at the sky
/// boundary plane, so it is uniform per segment too.
const Segment = struct {
    mat: u8,
    face: OFace,
    r0: f32,
    r1: f32,
    t: [2]f32,
    ao: [2]f32,
    light: lighting.LightSample = .{},
    sky: u1 = 1,
};

/// The single LUT/light/fog composition point; milestones 8-13 extend
/// this function and nowhere else. Stays in shade.V4 (float lanes with
/// a @trunc per stage) until one final pack — bit-identical to the
/// historical per-stage u32 round-trips.
fn segmentColor(seg: Segment, params: RenderParams) [2]u32 {
    const class = @intFromEnum(shade.faceClass(seg.face));
    var c0 = shade.shadeAtV(seg.mat, class, seg.ao[0], seg.sky);
    var c1 = shade.shadeAtV(seg.mat, class, seg.ao[1], seg.sky);
    // Emissive materials stay full-bright (shade LUT bypass), so their
    // own seed light is not reapplied on top.
    if (seg.light.intensity != 0 and world_mod.palette[seg.mat].emissive == 0) {
        var light = seg.light;
        light.intensity = @intCast(@as(u16, light.intensity) * shade.dir_weight[@intFromEnum(light.dir)][@intFromEnum(seg.face)] / 255);
        if (light.intensity != 0) {
            c0 = shade.applyGlowV(c0, light);
            c1 = shade.applyGlowV(c1, light);
        }
    }
    if (params.fog_density <= 0) return .{ shade.packRgb(c0), shade.packRgb(c1) };
    return .{
        shade.packRgb(shade.fogStopV(seg.mat, seg.t[0], c0, params)),
        shade.packRgb(shade.fogStopV(seg.mat, seg.t[1], c1, params)),
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
        spans.claimGrad(self.fb, self.height, self.sx, self.free, seg.r0, seg.r1, c[0], c[1]);
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
    /// Oriented outward normal of side faces in this cell: the DDA
    /// axis plus the sign pointing back along the march direction.
    side_face: OFace,
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
    /// Analytic sky (milestone 11): sky_on gates the whole path
    /// (params.light); sky_y is this column's cached topmost solid
    /// (-1 when fully air), nsky_y the previous DDA cell's. An air
    /// cell at y is sky-lit iff y > its column's sky_y — side faces
    /// sample the NEIGHBOR column (the air in front of the face, so a
    /// hillside above the adjacent terrain is lit), top/bottom faces
    /// their own column one voxel out.
    sky_on: bool,
    sky_y: i32,
    nsky_y: i32,

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
    return .{ .sample = .{ .color_id = run.color_id, .intensity = run.intensity, .dir = @enumFromInt(run.dir) }, .hi = lc.hi };
}

const LightQuery = struct {
    sample: lighting.LightSample,
    hi: i32,
};

/// Analytic sky stop for the air cell at y: lit (1) above the column's
/// topmost solid, dark (0) at or below it. sky_on = false (the
/// --light 0 identity path) keeps everything lit.
fn skyStop(sky_on: bool, sky_y: i32, y: i32) u1 {
    return if (!sky_on or y > sky_y) 1 else 0;
}

fn processCell(fb: []u32, height: usize, sx: usize, world: *const World, ix: i32, iz: i32, px: i32, pz: i32, has_prev: bool, cam_x: f32, cam_y: f32, cam_z: f32, f: f32, s_max: f32, dx: f32, dz: f32, t0_in: f32, t1: f32, axis: Face, free: *SpanList, params: RenderParams) void {
    if (free.isEmpty()) return;
    const t0 = @max(t0_in, 1e-4);
    const hf: f32 = @floatFromInt(height);
    const h_hi = cam_y + @max(s_max * t0, s_max * t1);
    const h_lo = cam_y - @max(s_max * t0, s_max * t1);
    const y_lo: i32 = @max(@as(i32, @intFromFloat(@floor(h_lo))), 0);
    const y_hi: i32 = @min(@as(i32, @intFromFloat(@floor(h_hi))), @as(i32, @intCast(world.h)) - 1);
    if (y_lo > y_hi) return;
    const col = world.columnAt(ix, iz) orelse return;
    const wh: i32 = @intCast(world.h);

    // Faces only ever come from this column's solids, so when the
    // ray's height window is entirely above the topmost solid (sky
    // cells, the bulk of long marches) nothing can emit: skip all
    // neighbor and light setup.
    if (col.top_solid_y == world_mod.no_solid or y_lo > col.top_solid_y) return;

    // Ray position within the cell at entry (a) and exit (b), clamped
    // against float error at boundaries; AO stop sample points.
    const ixf: f32 = @floatFromInt(ix);
    const izf: f32 = @floatFromInt(iz);
    const ua = ao.frac01(cam_x + dx * t0 - ixf);
    const va = ao.frac01(cam_z + dz * t0 - izf);
    const ub = ao.frac01(cam_x + dx * t1 - ixf);
    const vb = ao.frac01(cam_z + dz * t1 - izf);
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
        .side_face = if (axis == .x_side) (if (dx > 0) OFace.nx else OFace.px) else (if (dz > 0) OFace.nz else OFace.pz),
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
        .sky_on = params.light,
        .sky_y = if (col.top_solid_y == world_mod.no_solid) -1 else col.top_solid_y,
        .nsky_y = -1,
    };

    // Neighbor occupancy for face culling + side-face AO: ncur covers
    // the previous DDA cell (the air side of side faces); lacur/lbcur
    // cover the diagonal columns flanking it. All three walk y upward in
    // lockstep with the segment loop, amortized O(1) per voxel.
    const pcol: ?*const world_mod.Column = if (has_prev) world.columnAt(px, pz) else null;
    if (pcol) |pc| {
        ctx.nsky_y = if (pc.top_solid_y == world_mod.no_solid) -1 else pc.top_solid_y;
        ctx.ncur = world_mod.RunCursor.init(pc.runs, wh, y_lo);
        if (axis == .x_side) {
            if (world.columnAt(px, pz - 1)) |c| ctx.lacur = world_mod.RunCursor.init(c.runs, wh, y_lo);
            if (world.columnAt(px, pz + 1)) |c| ctx.lbcur = world_mod.RunCursor.init(c.runs, wh, y_lo);
        } else {
            if (world.columnAt(px - 1, pz)) |c| ctx.lacur = world_mod.RunCursor.init(c.runs, wh, y_lo);
            if (world.columnAt(px + 1, pz)) |c| ctx.lbcur = world_mod.RunCursor.init(c.runs, wh, y_lo);
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
            ctx.light_hi = col.light_base_y;
            ctx.light_lo = col.light_lo;
            ctx.lcur = world_mod.LightCursor.init(lruns, ctx.light_hi + 1, std.math.clamp(y_lo, ctx.light_lo, ctx.light_hi));
        }
        if (pcol) |pc| {
            if (pc.light) |nruns| {
                ctx.nlight_hi = pc.light_base_y;
                ctx.nlight_lo = pc.light_lo;
                ctx.nlcur = world_mod.LightCursor.init(nruns, ctx.nlight_hi + 1, std.math.clamp(y_lo, ctx.nlight_lo, ctx.nlight_hi));
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
    const top_face: OFace = .py;
    const bottom_face: OFace = .ny;

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
                    if (n.mat() == 0 and spans.spanOverlap(free, ctx.row(e + 1, ctx.t0), ctx.row(sy, ctx.t0))) {
                        // Air-backed sub-segment: claim per voxel with
                        // AO stops. Stops are not shareable between
                        // adjacent voxels (the below-voxel's top corner
                        // and the above-voxel's bottom corner sample
                        // different air-side voxels), but runs of max-AO
                        // voxels accumulate in [pend, yy) and flush as
                        // one constant segment; a light-run boundary or
                        // the sky boundary in the air-side column breaks
                        // the accumulation the same way, so every
                        // emitted segment has uniform light and sky.
                        var pend = sy;
                        var pend_light = ctx.nLightAt(lit, sy).sample;
                        var pend_sky = skyStop(ctx.sky_on, ctx.nsky_y, sy);
                        var yy = sy;
                        while (yy <= e) : (yy += 1) {
                            if (ctx.lacur) |*la| {
                                while (yy > la.hi) la.up();
                            }
                            if (ctx.lbcur) |*lb| {
                                while (yy > lb.hi) lb.up();
                            }
                            const stops = ao.sideAoStops(n, ao.optCursor(&ctx.lacur), ao.optCursor(&ctx.lbcur), yy, ctx.side_u);
                            const lq = ctx.nLightAt(lit, yy);
                            const sky = skyStop(ctx.sky_on, ctx.nsky_y, yy);
                            if (stops[0] == 3 and stops[1] == 3 and (!lit or std.meta.eql(lq.sample, pend_light)) and sky == pend_sky) continue;
                            if (pend < yy) {
                                sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = pend_light, .sky = pend_sky });
                            }
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = stops, .light = lq.sample, .sky = sky });
                            pend = yy + 1;
                            pend_light = if (lit and pend <= e) ctx.nLightAt(lit, pend).sample else .{};
                            pend_sky = skyStop(ctx.sky_on, ctx.nsky_y, pend);
                        }
                        if (pend <= e) {
                            sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(e + 1, ctx.t0), .r1 = ctx.row(pend, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = pend_light, .sky = pend_sky });
                        }
                        if (free.isEmpty()) return;
                    }
                    sy = e + 1;
                }
            } else if (!lit) {
                // Sky is binary per segment: split the whole-run fill
                // once when the boundary plane crosses it.
                if (ctx.sky_on and seg_lo <= ctx.sky_y and seg_hi > ctx.sky_y) {
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(ctx.sky_y + 1, ctx.t0), .r1 = ctx.row(seg_lo, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .sky = 0 });
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(seg_hi + 1, ctx.t0), .r1 = ctx.row(ctx.sky_y + 1, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .sky = 1 });
                } else {
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(seg_hi + 1, ctx.t0), .r1 = ctx.row(seg_lo, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .sky = skyStop(ctx.sky_on, ctx.sky_y, seg_lo) });
                }
                if (free.isEmpty()) return;
            } else {
                // Zipper: split the span at light-run boundaries so each
                // emitted segment carries a uniform light sample, and
                // at the sky boundary plane so its sky bit is uniform
                // too. With no light runs this is a single iteration
                // emitting the same constant segment as before lighting.
                var yy = seg_lo;
                while (yy <= seg_hi) {
                    const lq = ctx.lightAt(lit, yy);
                    var e2 = @min(seg_hi, lq.hi);
                    const sky = skyStop(ctx.sky_on, ctx.sky_y, yy);
                    if (sky == 0) e2 = @min(e2, ctx.sky_y);
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(e2 + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = .{ 3, 3 }, .light = lq.sample, .sky = sky });
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
                if (spans.spanOverlap(free, r_near, r_far)) {
                    const stops = ao.faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_lo - 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = mat, .face = bottom_face, .r0 = r_near, .r1 = r_far, .t = .{ ctx.t0, ctx.t1 }, .ao = stops, .light = if (lit) lighting.sampleLight(ctx.col, seg_lo - 1) else .{}, .sky = skyStop(ctx.sky_on, ctx.sky_y, seg_lo - 1) });
                    if (free.isEmpty()) return;
                }
            }
        }
        y = seg_hi + 1;
        if (y <= ctx.y_hi) cur.up();
    }

    y = ctx.y_hi;
    // cur already covers y_hi after the upward walk's normal exit —
    // no fresh cursor scan needed.
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
                if (spans.spanOverlap(free, r_far, r_near)) {
                    const stops = ao.faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_hi + 1, ctx.ua, ctx.va, ctx.ub, ctx.vb);
                    sink.emit(.{ .mat = cur.mat(), .face = top_face, .r0 = r_far, .r1 = r_near, .t = .{ ctx.t1, ctx.t0 }, .ao = .{ stops[1], stops[0] }, .light = if (lit) lighting.sampleLight(ctx.col, seg_hi + 1) else .{}, .sky = skyStop(ctx.sky_on, ctx.sky_y, seg_hi + 1) });
                    if (free.isEmpty()) return;
                }
            }
        }
        y = seg_lo - 1;
        if (y >= ctx.y_lo) cur.down();
    }
}

pub fn transpose(dst: []u32, src: []const u32, width: usize, height: usize) void {
    // 16x16 tiled: the naive row-major walk over a column-major source
    // is a cache-hostile gather (~2x slower at 960x540).
    const T = 16;
    var x0: usize = 0;
    while (x0 < width) : (x0 += T) {
        var y0: usize = 0;
        while (y0 < height) : (y0 += T) {
            const xe = @min(x0 + T, width);
            const ye = @min(y0 + T, height);
            for (x0..xe) |x| {
                for (y0..ye) |y| {
                    dst[y * width + x] = src[x * height + y];
                }
            }
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

test {
    _ = spans;
    _ = ao;
    _ = shade;
}

test "fog disabled leaves segment colors untouched" {
    const seg: Segment = .{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 2 } };
    const c = segmentColor(seg, .{ .fog_density = 0 });
    try std.testing.expectEqual(shade.shadeAt(1, 0, 3, 1), c[0]);
    try std.testing.expectEqual(shade.shadeAt(1, 0, 2, 1), c[1]);
}

test "dark-sky segments scale by the ambient floor; emissive bypasses" {
    const lit = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .sky = 1 }, .{ .fog_density = 0 });
    const dark = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .sky = 0 }, .{ .fog_density = 0 });
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const cl: i32 = @intCast((lit[0] >> sh) & 0xff);
        const cd: i32 = @intCast((dark[0] >> sh) & 0xff);
        try std.testing.expect(@abs(cd - @as(i32, @intFromFloat(@as(f32, @floatFromInt(cl)) * shade.sky_ambient))) <= 1);
    }
    // Emissive stays full-bright under a dark sky.
    const em_lit = segmentColor(.{ .mat = 9, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .sky = 1 }, .{ .fog_density = 0 });
    const em_dark = segmentColor(.{ .mat = 9, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .sky = 0 }, .{ .fog_density = 0 });
    try std.testing.expectEqual(em_lit, em_dark);
}

test "glow brightens and tints but never dims" {
    const plain = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 } }, .{ .fog_density = 0 });
    const zero = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 0 } }, .{ .fog_density = 0 });
    try std.testing.expectEqual(plain, zero);

    // Full-intensity cyan: each channel lifted by lch * gain,
    // clamped at 255 — brighter than plain in every channel.
    const lit = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 255 } }, .{ .fog_density = 0 });
    const shaded = shade.shadeAt(1, 0, 3, 1);
    const lc = [3]u32{ 0x46, 0xe6, 0xe6 };
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const ch: f32 = @floatFromInt((shaded >> sh) & 0xff);
        const want: i32 = @intFromFloat(@min(ch + @as(f32, @floatFromInt(lc[k])) * shade.glow_gain, 255.0));
        const got: i32 = @intCast((lit[0] >> sh) & 0xff);
        try std.testing.expect(@abs(got - want) <= 1);
        try std.testing.expect(got >= @as(i32, @intCast((shaded >> sh) & 0xff)));
    }

    // Weak light is a strictly weaker version of the same lift —
    // crucially the green channel is NOT dimmed below plain even
    // though cyan's green is below white.
    const weak = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 8 } }, .{ .fog_density = 0 });
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const pw: i32 = @intCast((plain[0] >> sh) & 0xff);
        const wk: i32 = @intCast((weak[0] >> sh) & 0xff);
        const fl: i32 = @intCast((lit[0] >> sh) & 0xff);
        try std.testing.expect(wk >= pw - 1);
        try std.testing.expect(wk <= fl + 1);
    }
}

test "directional weight dims grazing faces and nulls opposed faces" {
    // Flow heading straight into the top face: full light, identical
    // to a direction-less sample.
    const aligned = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 200, .dir = .ny } }, .{ .fog_density = 0 });
    const plain = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 200 } }, .{ .fog_density = 0 });
    try std.testing.expectEqual(plain, aligned);

    // Grazing flow: half intensity, matching a pre-weighted sample.
    const grazing = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 200, .dir = .px } }, .{ .fog_density = 0 });
    const half = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 200 * 128 / 255 } }, .{ .fog_density = 0 });
    try std.testing.expectEqual(half, grazing);

    // Opposed flow: the face shows no light.
    const opposed = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 9, .intensity = 200, .dir = .py } }, .{ .fog_density = 0 });
    const unlit = segmentColor(.{ .mat = 1, .face = .py, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 } }, .{ .fog_density = 0 });
    try std.testing.expectEqual(unlit, opposed);
}

test "emissive materials bypass the light tint" {
    const seg: Segment = .{ .mat = 9, .face = .px, .r0 = 0, .r1 = 10, .t = .{ 20, 24 }, .ao = .{ 3, 3 }, .light = .{ .color_id = 10, .intensity = 255 } };
    const c = segmentColor(seg, .{ .fog_density = 0 });
    try std.testing.expectEqual(shade.shadeAt(9, 2, 3, 1), c[0]);
}

test "fogged segment converges to the fog color at the cutoff" {
    const params: RenderParams = .{};
    shade.buildFogLuts(params);
    const seg: Segment = .{ .mat = 1, .face = .px, .r0 = 0, .r1 = 10, .t = .{ params.fog_cutoff, params.fog_cutoff }, .ao = .{ 3, 3 } };
    const c = segmentColor(seg, params);
    try std.testing.expectEqual(c[0], c[1]);
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const got: i32 = @intCast((c[0] >> sh) & 0xff);
        const want: i32 = @intCast((params.fog_color >> sh) & 0xff);
        try std.testing.expect(@abs(got - want) <= 2);
    }
}
