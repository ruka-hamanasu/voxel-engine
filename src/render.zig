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
/// March hard cap. The fine world only ever marches to lod_dists[0];
/// the coarse (LOD) worlds absorb everything past it, so this sits far
/// above the default fog cutoff with headroom for long draws.
pub const max_dist: f32 = 16384.0;
/// Coarse LOD levels supported per render (level i marches at 1/2^i
/// resolution). Per-range DDA steps stay bounded at any depth — the
/// range length doubles while the cell size does — so f32 t suffices;
/// f64 t_max is the deferred lever if ranges ever exceed ~1000 steps.
pub const max_lods = 8;
/// Start offset for the coarse march: lodBoundary returns a distance
/// sitting exactly on a coarse-cell plane, where rounding could floor
/// the DDA's start position into the upstream cell; an epsilon step
/// into the boundary cell keeps the cell assignment exact.
const lod_eps: f32 = 1e-3;
/// Tallest renderable frame (the sky gradient buffer is stack-sized).
pub const max_sky_height = shade.max_sky_height;

/// Default master draw distance; every distance-derived RenderParams
/// default comes from forDrawDistance(draw_dist_default).
pub const draw_dist_default: f32 = 672.0;
/// Invariant density*cutoff: the normalized fog curve (shade.fogCurve)
/// is fixed in fractional terms when fog_density = fog_k / cutoff, so
/// each LOD handoff keeps the same fog concealment (~91%) at any draw
/// distance while the near field clears as the distance grows.
pub const fog_k: f32 = 11.2;
/// LOD handoffs as fractions of the draw distance.
pub const lod0_frac: f32 = 3.0 / 14.0;
pub const lod1_frac: f32 = 3.0 / 7.0;
const default_cutoff = @min(draw_dist_default, max_dist);

/// Per-frame render configuration, threaded render -> renderColumn ->
/// processCell. fog_* went live in milestone 8, light in milestone 9.
pub const RenderParams = struct {
    fog_density: f32 = fog_k / default_cutoff,
    fog_cutoff: f32 = default_cutoff,
    fog_color: u32 = 0x8ea6d2, // horizon-row sky color
    /// false = treat every column as unlit (identity tint), ignoring
    /// the flood-filled light runs; runtime toggle for the L hotkey.
    light: bool = true,
    time_s: f64 = 0.0,
    /// March handoff distances into each coarse LOD level: past
    /// lod_dists[i] (snapped to a coarse-cell entry by lodBoundary,
    /// keeping each coarse voxel whole) the ray continues in the
    /// 1/2^(i+1)-resolution world (91% fogged at the default 144, so the
    /// silhouette overestimate stays hidden). Must be increasing; the
    /// first non-increasing entry (0 = disabled) ends the chain, as
    /// does running out of worlds passed to render.
    lod_dists: [max_lods]f32 = .{ default_cutoff * lod0_frac, default_cutoff * lod1_frac } ++ .{0.0} ** (max_lods - 2),
    /// Distance past which per-voxel shading detail (AO neighbor
    /// sampling, the colored-light zipper and glow) is dropped: cells
    /// beyond it shade with max AO and no light, collapsing each
    /// material run to one constant segment per sky half. Snapped per
    /// screen column to a cell entry (detailBoundary) so no cell
    /// straddles the mode line; the analytic sky bit stays (a cached
    /// compare, and it keeps cave/silhouette darkness) and fog hides
    /// the seam. 0 disables (full detail everywhere). Default: the
    /// first LOD handoff, so the detail pop coincides with the LOD0
    /// geometry transition.
    detail_dist: f32 = default_cutoff * lod0_frac,

    /// Derive every distance-related parameter from one master draw
    /// distance: fog cutoff = dist (clamped to max_dist), density from
    /// the fog_k invariant, LOD handoffs at the lod*_frac fractions,
    /// and detail tied to the first handoff.
    pub fn forDrawDistance(dist: f32) RenderParams {
        const d = @min(dist, max_dist);
        return .{
            .fog_density = fog_k / d,
            .fog_cutoff = d,
            .lod_dists = .{ d * lod0_frac, d * lod1_frac } ++ .{0.0} ** (max_lods - 2),
            .detail_dist = d * lod0_frac,
        };
    }
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

/// Previous boundary crossing on a DDA axis (t_max - t_delta), or
/// -inf when the ray never crosses that axis (zero direction
/// component), so it loses the max() for the cell-entry distance.
fn prevCross(t_max: f32, t_delta: f32) f32 {
    if (std.math.isInf(t_delta)) return -std.math.inf(f32);
    return t_max - t_delta;
}

/// Fine/coarse handoff distance, snapped to a coarse-cell boundary:
/// the entry distance of the first coarse cell whose center along the
/// ray is at or past lod_dist. Switching at the raw ray distance
/// starts the coarse march mid-cell, splitting the straddling coarse
/// voxel between the two worlds; snapping renders every coarse voxel
/// whole, by the world its center distance selects. scale is the
/// coarse world's unit length relative to the fine one (0.5 for level
/// 1, 0.25 for level 2).
fn lodBoundary(cam_x: f32, cam_z: f32, dx: f32, dz: f32, lod_dist: f32, limit: f32, scale: f32) f32 {
    const t_switch = @min(lod_dist, limit);
    var dda = DdaIterator.init(cam_x * scale + dx * scale * t_switch, cam_z * scale + dz * scale * t_switch, dx * scale, dz * scale, std.math.inf(f32));
    var t_enter = @max(prevCross(dda.t_max_x, dda.t_delta_x), prevCross(dda.t_max_z, dda.t_delta_z));
    while (t_switch + (t_enter + dda.t1()) * 0.5 < lod_dist and t_switch + t_enter < limit) {
        dda.advance();
        t_enter = dda.t0;
    }
    return std.math.clamp(t_switch + t_enter, 0.0, limit);
}

/// LOD chain layout for one ray: handoff distances t_b[1..n] into
/// coarse levels 1..n (t_b[0] = 0; level i marches lods[i-1]). The
/// chain ends at the first non-increasing distance (0 = disabled) or
/// when no world is passed for the level.
fn lodChain(params: RenderParams, n_worlds: usize, cam_x: f32, cam_z: f32, dx: f32, dz: f32, limit: f32, t_b: *[max_lods + 1]f32) usize {
    t_b[0] = 0.0;
    var n: usize = 0;
    var prev_d: f32 = 0.0;
    var scale: f32 = 1.0;
    for (params.lod_dists) |d| {
        if (d <= prev_d or n >= n_worlds) break;
        scale *= 0.5;
        n += 1;
        t_b[n] = lodBoundary(cam_x, cam_z, dx, dz, d, limit, scale);
        prev_d = d;
    }
    return n;
}

/// Simple-mode split distance, snapped to the entry of the fine DDA
/// cell containing detail_dist so each cell renders wholly in one
/// mode. Unlike lodBoundary no center-distance walk is needed: the
/// containing cell renders simple, so its entry is the split.
fn detailBoundary(cam_x: f32, cam_z: f32, dx: f32, dz: f32, detail_dist: f32) f32 {
    const dda = DdaIterator.init(cam_x + dx * detail_dist, cam_z + dz * detail_dist, dx, dz, std.math.inf(f32));
    const t_enter = @max(prevCross(dda.t_max_x, dda.t_delta_x), prevCross(dda.t_max_z, dda.t_delta_z));
    return @max(detail_dist + t_enter, 0.0);
}

pub fn render(fb: []u32, width: usize, height: usize, world: *const World, lods: []const *const World, cam: Camera, params: RenderParams) void {
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
        renderColumn(fb, height, world, lods, cam, f, s_max, sx, dx, dz, sky, params);
    }
}

/// Per-column ray frame for true radial fog distance: the FINE
/// march's squared XZ direction length (1 + hx^2) and reciprocal
/// focal length. Shared across LOD levels — t is march-scale
/// invariant (cam and dir scale together), so the stop distance
/// t*sqrt(dxz2 + s(r)^2) with row slope s(r) = (hf/2 - r)/f is too.
const FogRay = struct { dxz2: f32 = 1.0, inv_f: f32 = 1.0 };

/// One march's geometric frame: which world, and how ray distance t
/// maps into its coordinate system. The LOD march scales all lengths
/// by 1/2 (cam and direction halved, f doubled), which leaves
/// processCell's row and window math form-invariant: a coarse voxel at
/// y_c projects exactly like the 2 fine voxels it covers.
const MarchCfg = struct {
    world: *const World,
    /// Fine world the boundary cell's back faces shade from (coarse
    /// march only); null for the fine march.
    fine: ?*const World = null,
    cam_x: f32,
    cam_y: f32,
    cam_z: f32,
    f: f32,
    s_max: f32,
    dx: f32,
    dz: f32,
    fog: FogRay,
};

fn renderColumn(fb: []u32, height: usize, world: *const World, lods: []const *const World, cam: Camera, f: f32, s_max: f32, sx: usize, dx: f32, dz: f32, sky: []const u32, params: RenderParams) void {
    var free = SpanList.initFull(@intCast(height));

    // March no farther than the fog cutoff: every later hit is fully
    // fogged (radial distance >= t at every row, so the t cutoff is
    // conservative), so the remaining free spans might as well be sky
    // (whose horizon row is the fog color).
    const limit = @min(max_dist, params.fog_cutoff);
    const fog_ray: FogRay = .{ .dxz2 = dx * dx + dz * dz, .inv_f = 1.0 / f };
    const cfg: MarchCfg = .{ .world = world, .cam_x = cam.x, .cam_y = cam.y, .cam_z = cam.z, .f = f, .s_max = s_max, .dx = dx, .dz = dz, .fog = fog_ray };
    // Shading-detail split (RenderParams.detail_dist): the mode flips
    // at most once per ray (t0 is monotonic), so the branch is hoisted
    // out of the march as a range split. limit when disabled or out of
    // reach, keeping --detail 0 a single detailed march (bit-identical
    // to the pre-split renderer).
    const t_detail = if (params.detail_dist > 0 and params.detail_dist < limit)
        detailBoundary(cam.x, cam.z, dx, dz, params.detail_dist)
    else
        limit;
    var t_b: [max_lods + 1]f32 = undefined;
    const n = lodChain(params, lods.len, cam.x, cam.z, dx, dz, limit, &t_b);
    if (n == 0) {
        marchFine(fb, height, sx, cfg, t_detail, limit, &free, params);
    } else {
        marchFine(fb, height, sx, cfg, t_detail, t_b[1], &free, params);
        var i: usize = 1;
        var scale: f32 = 0.5;
        while (i <= n and t_b[i] < limit and !free.isEmpty()) : ({
            i += 1;
            scale *= 0.5;
        }) {
            const cfg_i: MarchCfg = .{ .world = lods[i - 1], .fine = if (i == 1) world else lods[i - 2], .cam_x = cam.x * scale, .cam_y = cam.y * scale, .cam_z = cam.z * scale, .f = f / scale, .s_max = s_max * scale, .dx = dx * scale, .dz = dz * scale, .fog = fog_ray };
            const t_end = if (i < n) t_b[i + 1] else limit;
            if (t_b[i] >= t_detail) {
                marchRange(fb, height, sx, cfg_i, t_b[i] + lod_eps, t_end, &free, params, true, false);
            } else {
                marchRange(fb, height, sx, cfg_i, t_b[i] + lod_eps, t_end, &free, params, true, true);
            }
        }
    }

    spans.fillSpans(fb, height, sx, &free, 0, @floatFromInt(height), spans.SkySrc{ .sky = sky });
}

/// Fine march over [0, t_end), split at t_detail into a detailed and
/// a simple range (both comptime-specialized, so no per-cell mode
/// check). t_detail >= t_end collapses to the single detailed march.
fn marchFine(fb: []u32, height: usize, sx: usize, cfg: MarchCfg, t_detail: f32, t_end: f32, free: *SpanList, params: RenderParams) void {
    if (t_detail >= t_end) {
        marchRange(fb, height, sx, cfg, 0, t_end, free, params, false, true);
        return;
    }
    marchRange(fb, height, sx, cfg, 0, t_detail, free, params, false, true);
    if (!free.isEmpty()) marchRange(fb, height, sx, cfg, t_detail, t_end, free, params, false, false);
}

/// March cfg's world over absolute ray distances [t_begin, t_end).
/// With t_begin = 0 this is bit-identical to the plain single-world
/// march (same DDA state, same processCell arguments). The cell-exit
/// clamp preserves the historical max_dist = 96 semantics: t1 may
/// overshoot t_end up to 96 (or t_end when that is larger), which only
/// affects cells straddling the march limit and keeps the --lod 0 path
/// byte-identical. A mid-ray start (t_begin > 0: the coarse LOD march
/// or the simple shading range) seeds the upstream cell as the first
/// cell's previous-cell record, so it culls and samples neighbor sky
/// exactly as in an unsplit march. handoff additionally marks the
/// coarse (LOD) boundary: its first cell emits back faces with
/// no_cull — the fine march in front may have left those spans open,
/// and culling against the coarse neighbor's union-solidity would
/// punch holes along the boundary. comptime detail selects per-voxel
/// shading detail (milestone 15); false compiles AO and light away.
fn marchRange(fb: []u32, height: usize, sx: usize, cfg: MarchCfg, t_begin: f32, t_end: f32, free: *SpanList, params: RenderParams, handoff: bool, comptime detail: bool) void {
    const world = cfg.world;
    const t_clamp = @max(96.0, t_end);
    var dda = DdaIterator.init(cfg.cam_x + cfg.dx * t_begin, cfg.cam_z + cfg.dz * t_begin, cfg.dx, cfg.dz, t_clamp - t_begin);
    var no_cull = false;
    if (t_begin > 0) {
        if (prevCross(dda.t_max_x, dda.t_delta_x) > prevCross(dda.t_max_z, dda.t_delta_z)) {
            dda.px = dda.ix - dda.step_x;
            dda.pz = dda.iz;
            dda.axis = .x_side;
        } else {
            dda.px = dda.ix;
            dda.pz = dda.iz - dda.step_z;
            dda.axis = .z_side;
        }
        dda.has_prev = true;
        no_cull = handoff;
    }
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
                no_cull = false;
                continue;
            };
            if (h_lo > @as(f32, @floatFromInt(mmax)) + 1.0) {
                dda.advance();
                no_cull = false;
                continue;
            }
        }
        processCell(fb, height, sx, world, dda.ix, dda.iz, dda.px, dda.pz, dda.has_prev, cfg.cam_x, cfg.cam_y, cfg.cam_z, cfg.f, cfg.s_max, cfg.dx, cfg.dz, t0, t1, dda.axis, no_cull, cfg.fine, free, params, cfg.fog, detail);
        no_cull = false;
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
/// are the unclipped row range, ao the AO stops at those endpoints.
/// t is the XZ march parameter at the endpoints; SegmentSink.emit
/// rescales it to true radial distance before shading (fog on only). light is sampled at the air cell the face is exposed to
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
    const fogged = shade.fogStopsV(seg.mat, seg.t, .{ c0, c1 }, params);
    return .{ shade.packRgb(fogged[0]), shade.packRgb(fogged[1]) };
}

const SegmentSink = struct {
    fb: []u32,
    height: usize,
    sx: usize,
    free: *SpanList,
    params: RenderParams,
    fog: FogRay,

    fn emit(self: *SegmentSink, seg_in: Segment) void {
        var seg = seg_in;
        if (self.params.fog_density > 0) {
            // True radial distance per stop: t is the XZ view-plane
            // parameter, so scale by the full 3D ray direction length
            // sqrt(dxz2 + s^2), s the stop row's vertical slope.
            // View-plane fog made bands shift under pure rotation.
            const hf: f32 = @floatFromInt(self.height);
            const V2 = @Vector(2, f32);
            const s = (@as(V2, @splat(hf * 0.5)) - @as(V2, .{ seg.r0, seg.r1 })) * @as(V2, @splat(self.fog.inv_f));
            const d = @as(V2, .{ seg.t[0], seg.t[1] }) * @sqrt(@as(V2, @splat(self.fog.dxz2)) + s * s);
            seg.t = .{ d[0], d[1] };
        }
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
    /// LOD boundary cell (marchRange handoff): emit back faces even
    /// where the seeded neighbor is solid — occlusion is left to span
    /// claiming, since the fine render in front owns the nearer spans.
    /// Fallback shading path when bfine is null.
    no_cull: bool,
    /// LOD boundary cell: the fine world plus the fine column the
    /// entry point backs onto (with its lateral AO flanks) and the
    /// lateral fraction within that column. Back faces sample
    /// sky/AO/light from these; the coarse neighbor's union-folded
    /// data darkens faces that front open fine air.
    bfine: ?*const World,
    bsel: [2]i32,
    bflanka: [2]i32,
    bflankb: [2]i32,
    bu: f32,

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

/// Sky bit for an LOD boundary back face: lit when the face's upper
/// fine layer clears the fronting fine column's top. The coarse
/// neighbor's union-raised top would read cave-dark against open
/// fine sky.
fn boundarySky(fine: *const World, sel: [2]i32, y: i32) u1 {
    const col = fine.columnAt(sel[0], sel[1]) orelse return 1;
    const t: i32 = if (col.top_solid_y == world_mod.no_solid) -1 else @as(i32, col.top_solid_y);
    return if (2 * y + 1 > t) 1 else 0;
}

/// Light for an LOD boundary back face: the brighter of the two fine
/// cells in front of it.
fn boundaryLight(fine: *const World, sel: [2]i32, y: i32) lighting.LightSample {
    const col = fine.columnAt(sel[0], sel[1]) orelse return .{};
    const a = lighting.sampleLight(col, 2 * y);
    const b = lighting.sampleLight(col, 2 * y + 1);
    return if (b.intensity > a.intensity) b else a;
}

fn processCell(fb: []u32, height: usize, sx: usize, world: *const World, ix: i32, iz: i32, px: i32, pz: i32, has_prev: bool, cam_x: f32, cam_y: f32, cam_z: f32, f: f32, s_max: f32, dx: f32, dz: f32, t0_in: f32, t1: f32, axis: Face, no_cull: bool, fine: ?*const World, free: *SpanList, params: RenderParams, fog_ray: FogRay, comptime detail: bool) void {
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
        .no_cull = no_cull,
        .bfine = null,
        .bsel = .{ 0, 0 },
        .bflanka = .{ 0, 0 },
        .bflankb = .{ 0, 0 },
        .bu = 0,
    };

    // LOD boundary cell: locate the fine column the entry point backs
    // onto (side_u selects between the face's two fine columns) and
    // its lateral flanks, for back-face shading.
    if (no_cull and has_prev and fine != null) {
        ctx.bfine = fine;
        const s: i32 = if (side_u >= 0.5) 1 else 0;
        ctx.bu = if (side_u >= 0.5) 2 * side_u - 1 else 2 * side_u;
        if (axis == .x_side) {
            const fx: i32 = if (dx > 0) 2 * ix - 1 else 2 * ix + 2;
            ctx.bsel = .{ fx, 2 * iz + s };
            ctx.bflanka = .{ fx, 2 * iz + s - 1 };
            ctx.bflankb = .{ fx, 2 * iz + s + 1 };
        } else {
            const fz: i32 = if (dz > 0) 2 * iz - 1 else 2 * iz + 2;
            ctx.bsel = .{ 2 * ix + s, fz };
            ctx.bflanka = .{ 2 * ix + s - 1, fz };
            ctx.bflankb = .{ 2 * ix + s + 1, fz };
        }
    }

    // Neighbor occupancy for face culling + side-face AO: ncur covers
    // the previous DDA cell (the air side of side faces); lacur/lbcur
    // cover the diagonal columns flanking it. All three walk y upward in
    // lockstep with the segment loop, amortized O(1) per voxel. Simple
    // mode (detail = false) keeps only ncur: culling is geometry, but
    // the diagonals exist solely for AO.
    const pcol: ?*const world_mod.Column = if (has_prev) world.columnAt(px, pz) else null;
    if (pcol) |pc| {
        ctx.nsky_y = if (pc.top_solid_y == world_mod.no_solid) -1 else pc.top_solid_y;
        ctx.ncur = world_mod.RunCursor.init(pc.runs, wh, y_lo);
        if (detail) {
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
    // as unlit. Simple mode skips the setup, so the genSegments
    // dispatch below always takes the unlit specialization.
    if (detail and params.light) {
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

    var sink: SegmentSink = .{ .fb = fb, .height = height, .sx = sx, .free = free, .params = params, .fog = fog_ray };
    if (!detail) {
        genSegments(&ctx, &sink, false, false);
    } else if (ctx.lcur != null or ctx.nlcur != null or (ctx.bfine != null and ctx.sky_on)) {
        genSegments(&ctx, &sink, true, true);
    } else {
        genSegments(&ctx, &sink, false, true);
    }
}

/// Segment generation: geometry/visibility only, emitting Segment
/// records front-to-back. All shading decisions live in segmentColor.
/// comptime lit selects the light-zipper code paths; columns without
/// light runs compile them away entirely. comptime detail = false
/// (cells past detail_dist) drops AO to the max level and runs unlit:
/// the max-AO accumulation then merges each material run into one
/// constant segment per sky half, and sky/culling/fog are unaffected.
fn genSegments(ctx: *CellCtx, sink: *SegmentSink, comptime lit: bool, comptime detail: bool) void {
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
            if (ctx.bfine) |fine| {
                // LOD boundary cell: never culled (span claiming
                // resolves occlusion against the fine render in
                // front); shaded from the fine column the face
                // fragment is actually exposed to.
                var yy = seg_lo;
                while (yy <= seg_hi) : (yy += 1) {
                    if (!spans.spanOverlap(free, ctx.row(yy + 1, ctx.t0), ctx.row(yy, ctx.t0))) continue;
                    const stops: [2]f32 = if (detail) ao.sideAoStopsFine(fine, ctx.bsel, ctx.bflanka, ctx.bflankb, yy, ctx.bu) else .{ 3, 3 };
                    const sky: u1 = if (!ctx.sky_on) 1 else boundarySky(fine, ctx.bsel, yy);
                    sink.emit(.{ .mat = mat, .face = ctx.side_face, .r0 = ctx.row(yy + 1, ctx.t0), .r1 = ctx.row(yy, ctx.t0), .t = .{ ctx.t0, ctx.t0 }, .ao = stops, .light = if (lit) boundaryLight(fine, ctx.bsel, yy) else .{}, .sky = sky });
                    if (free.isEmpty()) return;
                }
            } else if (ctx.ncur) |*n| {
                var sy = seg_lo;
                while (sy <= seg_hi) {
                    while (sy > n.hi) n.up();
                    const e = if (ctx.no_cull) seg_hi else @min(seg_hi, n.hi);
                    if ((ctx.no_cull or n.mat() == 0) and spans.spanOverlap(free, ctx.row(e + 1, ctx.t0), ctx.row(sy, ctx.t0))) {
                        // Air-backed sub-segment (no_cull: the whole
                        // run — the LOD boundary cell emits against the
                        // seeded neighbor, using it for AO/light/sky
                        // only). Claim per voxel with AO stops. Stops
                        // are not shareable between adjacent voxels
                        // (the below-voxel's top corner and the
                        // above-voxel's bottom corner sample different
                        // air-side voxels), but runs of max-AO voxels
                        // accumulate in [pend, yy) and flush as one
                        // constant segment; a light-run boundary or the
                        // sky boundary in the air-side column breaks
                        // the accumulation the same way, so every
                        // emitted segment has uniform light and sky.
                        var pend = sy;
                        var pend_light = ctx.nLightAt(lit, sy).sample;
                        var pend_sky = skyStop(ctx.sky_on, ctx.nsky_y, sy);
                        var yy = sy;
                        while (yy <= e) : (yy += 1) {
                            if (ctx.no_cull) while (yy > n.hi) n.up();
                            const stops: [2]f32 = if (detail) stops: {
                                if (ctx.lacur) |*la| {
                                    while (yy > la.hi) la.up();
                                }
                                if (ctx.lbcur) |*lb| {
                                    while (yy > lb.hi) lb.up();
                                }
                                break :stops ao.sideAoStops(n, ao.optCursor(&ctx.lacur), ao.optCursor(&ctx.lbcur), yy, ctx.side_u);
                            } else .{ 3, 3 };
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
                    const stops: [2]f32 = if (detail) ao.faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_lo - 1, ctx.ua, ctx.va, ctx.ub, ctx.vb) else .{ 3, 3 };
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
                    const stops: [2]f32 = if (detail) ao.faceAoStops(ctx.world, ctx.ix, ctx.iz, seg_hi + 1, ctx.ua, ctx.va, ctx.ub, ctx.vb) else .{ 3, 3 };
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

test "detailBoundary snaps the split to the containing cell's entry" {
    // Axis-aligned +x ray: t=32 lands in cell [35,36) (entry 31.1
    // along the ray), so the split moves down to the cell entry.
    try std.testing.expectApproxEqAbs(@as(f32, 31.1), detailBoundary(3.9, 10.5, 1.0, 0.0, 32.0), 1e-3);
    // t=32 exactly on a cell plane: the plane is the split, and the
    // same holds with a zero direction component or a negative
    // direction at an exact-integer position.
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), detailBoundary(4.0, 10.5, 1.0, 0.0, 32.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), detailBoundary(4.0, 10.0, 0.0, 1.0, 32.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 31.0), detailBoundary(100.0, 10.5, -1.0, 0.0, 32.0), 1e-3);
}

test "lodBoundary snaps the handoff to the first center-past coarse cell" {
    // Axis-aligned +x ray: coarse cells are 2 t-units wide. The cell
    // holding t=48 has center 47.1 (within lod_dist), so the boundary
    // moves to its exit.
    try std.testing.expectApproxEqAbs(@as(f32, 48.1), lodBoundary(3.9, 10.5, 1.0, 0.0, 48.0, 96.0, 0.5), 1e-3);
    // Same ray shifted so t=48 lands exactly on a cell plane: that
    // cell's center is past lod_dist, so the boundary is 48 exactly.
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), lodBoundary(4.0, 10.5, 1.0, 0.0, 48.0, 96.0, 0.5), 1e-3);
    // lod_dist at/past the march limit clamps to the limit (coarse
    // march skipped by the caller).
    try std.testing.expectApproxEqAbs(@as(f32, 96.0), lodBoundary(4.0, 10.5, 1.0, 0.0, 200.0, 96.0, 0.5), 1e-3);
    // Zero direction component (inf t_delta) and negative direction
    // with an exact-integer start both stay exact.
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), lodBoundary(4.0, 10.0, 0.0, 1.0, 48.0, 96.0, 0.5), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), lodBoundary(100.0, 10.5, -1.0, 0.0, 48.0, 96.0, 0.5), 1e-3);
}

test "forDrawDistance derives fog, LOD, and detail from one distance" {
    const p = RenderParams.forDrawDistance(672.0);
    try std.testing.expectEqual(@as(f32, 672.0), p.fog_cutoff);
    try std.testing.expectApproxEqAbs(@as(f32, 144.0), p.lod_dists[0], 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 288.0), p.lod_dists[1], 1e-2);
    try std.testing.expectEqual(p.lod_dists[0], p.detail_dist);
    try std.testing.expectEqual(@as(f32, 0.0), p.lod_dists[2]);
    // The fog_k invariant: density*cutoff stays 11.2 at any distance,
    // keeping the handoff concealment fixed while the near field clears.
    try std.testing.expectApproxEqAbs(fog_k, p.fog_density * p.fog_cutoff, 1e-3);
    const far = RenderParams.forDrawDistance(1344.0);
    try std.testing.expectApproxEqAbs(fog_k, far.fog_density * far.fog_cutoff, 1e-2);
    try std.testing.expectApproxEqAbs(p.fog_density / 2.0, far.fog_density, 1e-6);
    // Defaults equal the derivation at draw_dist_default.
    const d: RenderParams = .{};
    try std.testing.expectEqual(RenderParams.forDrawDistance(draw_dist_default).fog_density, d.fog_density);
    try std.testing.expectEqual(RenderParams.forDrawDistance(draw_dist_default).fog_cutoff, d.fog_cutoff);
    try std.testing.expectEqual(RenderParams.forDrawDistance(draw_dist_default).lod_dists, d.lod_dists);
    try std.testing.expectEqual(RenderParams.forDrawDistance(draw_dist_default).detail_dist, d.detail_dist);
    // Distances past the march hard cap clamp to it.
    try std.testing.expectEqual(max_dist, RenderParams.forDrawDistance(1e6).fog_cutoff);
}

test "lodChain ends at non-increasing distances, missing worlds, and the limit" {
    var t_b: [max_lods + 1]f32 = undefined;
    // Default chain with worlds present: two handoffs snapped near
    // the requested distances (within one coarse cell each).
    const n = lodChain(.{}, max_lods, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectApproxEqAbs(@as(f32, 144.0), t_b[1], 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 288.0), t_b[2], 4.0);
    try std.testing.expect(t_b[1] < t_b[2]);
    // A 0 entry ends the chain (the --lod2 0 form).
    const n1 = lodChain(.{ .lod_dists = .{ 96.0, 0.0 } ++ .{0.0} ** (max_lods - 2) }, max_lods, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b);
    try std.testing.expectEqual(@as(usize, 1), n1);
    // Non-increasing entries end it too.
    const n2 = lodChain(.{ .lod_dists = .{ 192.0, 96.0 } ++ .{0.0} ** (max_lods - 2) }, max_lods, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b);
    try std.testing.expectEqual(@as(usize, 1), n2);
    // Running out of worlds ends it even with positive distances.
    try std.testing.expectEqual(@as(usize, 0), lodChain(.{}, 0, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b));
    try std.testing.expectEqual(@as(usize, 1), lodChain(.{}, 1, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b));
    // A distance past the march limit clamps the handoff to the limit.
    const n3 = lodChain(.{ .lod_dists = .{ 96.0, 100000.0 } ++ .{0.0} ** (max_lods - 2) }, max_lods, 3.9, 10.5, 1.0, 0.0, 448.0, &t_b);
    try std.testing.expectEqual(@as(usize, 2), n3);
    try std.testing.expectEqual(@as(f32, 448.0), t_b[2]);
}

test "boundary cell back faces are never culled but take neighbor AO" {
    var world = try World.init(std.testing.allocator, 4, 8, 4);
    defer world.deinit();
    try world.fillBox(1, 2, 1, 2, 6, 2, 3); // current column: solid 2..5
    try world.fillBox(0, 1, 1, 1, 7, 2, 3); // upstream column: solid 1..6
    const params: RenderParams = .{ .fog_density = 0, .light = false };
    const sentinel: u32 = 0xdeadbeef;

    // Control: normal culling drops every back face (the upstream
    // column is solid over the whole run), leaving the spans open.
    var fb0: [16]u32 = @splat(sentinel);
    var free0 = SpanList.initFull(16);
    processCell(&fb0, 16, 0, &world, 1, 1, 0, 1, true, 0.0, 7.0, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, false, null, &free0, params, .{}, true);
    try std.testing.expectEqualSlices(u32, &@as([16]u32, @splat(sentinel)), &fb0);

    // no_cull (the LOD boundary cell): the faces emit, shaded by the
    // neighbor's AO stops ({2,2}: solid above and below in the
    // upstream column).
    var fb1: [16]u32 = @splat(sentinel);
    var free1 = SpanList.initFull(16);
    processCell(&fb1, 16, 0, &world, 1, 1, 0, 1, true, 0.0, 7.0, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, true, null, &free1, params, .{}, true);
    try std.testing.expect(free1.isEmpty() == false);
    const want = segmentColor(.{ .mat = 3, .face = .nx, .r0 = 11.2, .r1 = 12.8, .t = .{ 10, 10 }, .ao = .{ 2, 2 }, .sky = 1 }, params)[0];
    try std.testing.expectEqual(want, fb1[12]);
    try std.testing.expectEqual(sentinel, fb1[9]);
    try std.testing.expect(fb1[10] != sentinel and fb1[15] != sentinel);
}

test "boundary cell shades back faces from the fine world in front" {
    const lod_mod = @import("lod.zig");
    var fine = try World.init(std.testing.allocator, 8, 8, 8);
    defer fine.deinit();
    // Coarse cell (1,1) covers fine x,z in {2,3}: solid from column
    // (2,2) at fine y 4..7 -> coarse layers 2..3.
    try fine.fillBox(2, 4, 2, 3, 8, 3, 3);
    // Fronting fine columns (x=1, z=2..3) stay low (top y=1): the
    // back faces front open sky...
    try fine.fillBox(1, 0, 2, 2, 2, 3, 3);
    // ...but the coarse neighbor (0,1) also covers a tall spike in
    // its far column (0,2), union-raising its coarse top to layer 3 —
    // coarse-folded shading would read the faces cave-dark.
    try fine.fillBox(0, 0, 2, 1, 8, 3, 3);
    var lod = try lod_mod.build(std.testing.allocator, &fine);
    defer lod.deinit();
    const params: RenderParams = .{ .fog_density = 0, .light = true };
    const sentinel: u32 = 0xdeadbeef;

    var fb: [16]u32 = @splat(sentinel);
    var free = SpanList.initFull(16);
    processCell(&fb, 16, 0, &lod, 1, 1, 0, 1, true, 0.0, 3.5, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, true, &fine, &free, params, .{}, true);
    // Sky-lit, max-AO (nothing solid beside the faces in fine air).
    const want = segmentColor(.{ .mat = 3, .face = .nx, .r0 = 8.8, .r1 = 10.4, .t = .{ 10, 10 }, .ao = .{ 3, 3 }, .sky = 1 }, params)[0];
    try std.testing.expectEqual(want, fb[9]);
    const dark = segmentColor(.{ .mat = 3, .face = .nx, .r0 = 8.8, .r1 = 10.4, .t = .{ 10, 10 }, .ao = .{ 2, 2 }, .sky = 0 }, params)[0];
    try std.testing.expect(want != dark);

    // Control without the fine context: coarse-neighbor shading —
    // solid above and below (AO {2,2}) and under the union-raised
    // top (sky 0).
    var fb2: [16]u32 = @splat(sentinel);
    var free2 = SpanList.initFull(16);
    processCell(&fb2, 16, 0, &lod, 1, 1, 0, 1, true, 0.0, 3.5, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, true, null, &free2, params, .{}, true);
    try std.testing.expectEqual(dark, fb2[9]);
}

test "simple mode drops AO but claims identical geometry" {
    var world = try World.init(std.testing.allocator, 4, 8, 4);
    defer world.deinit();
    try world.fillBox(1, 2, 1, 2, 6, 2, 3); // current column: solid 2..5
    try world.fillBox(0, 6, 1, 1, 7, 2, 3); // upstream column: solid 6 only —
    // darkens the y=5 face's top AO stop in detailed mode without
    // culling it (the face stays air-backed).
    const params: RenderParams = .{ .fog_density = 0, .light = false };
    const sentinel: u32 = 0xdeadbeef;

    var fb_det: [16]u32 = @splat(sentinel);
    var free_det = SpanList.initFull(16);
    processCell(&fb_det, 16, 0, &world, 1, 1, 0, 1, true, 0.0, 7.0, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, false, null, &free_det, params, .{}, true);
    var fb_sim: [16]u32 = @splat(sentinel);
    var free_sim = SpanList.initFull(16);
    processCell(&fb_sim, 16, 0, &world, 1, 1, 0, 1, true, 0.0, 7.0, 0.0, 16.0, 0.5, 0.8, 0.0, 10.0, 12.0, .x_side, false, null, &free_sim, params, .{}, false);

    // Same spans claimed in both modes (geometry is detail-independent).
    try std.testing.expectEqual(free_det.len, free_sim.len);
    try std.testing.expectEqualSlices(@TypeOf(free_det.spans[0]), free_det.spans[0..free_det.len], free_sim.spans[0..free_sim.len]);
    // Simple mode renders the whole run as one constant max-AO
    // segment; detailed mode darkens the y=5 gradient rows.
    const plain = segmentColor(.{ .mat = 3, .face = .nx, .r0 = 9.6, .r1 = 16.0, .t = .{ 10, 10 }, .ao = .{ 3, 3 }, .sky = 1 }, params)[0];
    try std.testing.expectEqual(plain, fb_sim[10]);
    try std.testing.expectEqual(plain, fb_sim[14]);
    try std.testing.expectEqual(plain, fb_det[14]);
    try std.testing.expect(fb_det[10] != plain);
    try std.testing.expectEqual(sentinel, fb_sim[9]);
    try std.testing.expectEqual(sentinel, fb_det[9]);
}
