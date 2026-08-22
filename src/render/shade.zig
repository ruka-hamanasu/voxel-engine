const std = @import("std");
const world_mod = @import("../world.zig");
const lighting = @import("../lighting.zig");
const render = @import("../render.zig");

const RenderParams = render.RenderParams;
const FogCurve = render.FogCurve;

pub const Face = enum(u2) { top, bottom, x_side, z_side };

/// Face with the outward normal's sign: the four shade classes split
/// by direction for the milestone-9b directional light weight. Value
/// order matches lighting.Dir, so the opposite normal is `f ^ 1`.
pub const OFace = enum(u3) { px, nx, py, ny, pz, nz };

pub fn faceClass(of: OFace) Face {
    return switch (of) {
        .py => .top,
        .ny => .bottom,
        .px, .nx => .x_side,
        .pz, .nz => .z_side,
    };
}

/// Arrival-direction weight (milestone 9b): how much of the sampled
/// air cell's light a face shows, by alignment of the face normal with
/// the direction the flood flowed into that cell. Flow heading
/// straight into the face = full, perpendicular (grazing, e.g. light
/// bending around a 45-degree corner) = half, opposing = none
/// (geometrically unreachable for solid-backed faces; kept for LUT
/// completeness). The none row is identity, so the pre-milestone-11
/// default sample is unaffected. Entries are tunable.
pub const dir_weight = buildDirWeight();

fn buildDirWeight() [7][6]u8 {
    const none = @intFromEnum(lighting.Dir.none);
    var lut: [7][6]u8 = undefined;
    for (0..7) |d| {
        for (0..6) |f| {
            lut[d][f] = if (d == none) 255 else if (d == (f ^ 1)) 255 else if (d == f) 0 else 128;
        }
    }
    return lut;
}

const face_factor = [4]f32{ 1.0, 0.5, 0.8, 0.6 };
const ao_factor = [4]f32{ 0.45, 0.65, 0.82, 1.0 };

/// Brightness of air below a column's topmost solid (milestone 11
/// analytic sky): caves/overhangs read dark but not black, and AO
/// still darkens further on top. Sky-lit air is factor 1.0.
pub const sky_ambient: f32 = 0.30;

/// [palette][face][ao_level][sky] -> shaded color; collapses all
/// shading arithmetic into one L1-resident lookup. sky is the milestone
/// 11 analytic bit: 1 = the face's air cell is above its column's
/// topmost solid, 0 = below (scaled by sky_ambient). Emissive materials
/// bypass face/AO/sky shading: every entry in their row is the
/// full-bright color. Runtime-var so milestone 10's palette animation
/// can rebuild it.
var shade_lut: [world_mod.default_palette.len][4][4][2]u32 = buildShadeLut(world_mod.default_palette);
/// Same table pre-unpacked into f32 lanes (exact: channels are 0-255),
/// so shadeAtV skips the per-stop unpack converts.
var shade_lut_v4: [world_mod.default_palette.len][4][4][2]V4 = unpackLut(buildShadeLut(world_mod.default_palette));
/// Unpacked palette colors for applyGlowV's light tint (rebuilt with
/// the shade LUT after palette mutations).
var light_v4: [world_mod.default_palette.len]V4 = unpackPalette(world_mod.default_palette);

fn unpackLut(lut: [world_mod.default_palette.len][4][4][2]u32) [world_mod.default_palette.len][4][4][2]V4 {
    @setEvalBranchQuota(10000);
    var out: [world_mod.default_palette.len][4][4][2]V4 = undefined;
    for (lut, 0..) |m, mi| {
        for (m, 0..) |f, fi| {
            for (f, 0..) |a, ai| {
                for (a, 0..) |c, si| out[mi][fi][ai][si] = unpackRgb(c);
            }
        }
    }
    return out;
}

fn unpackPalette(palette: [world_mod.default_palette.len]world_mod.PaletteEntry) [world_mod.default_palette.len]V4 {
    var out: [world_mod.default_palette.len]V4 = undefined;
    for (palette, 0..) |entry, m| out[m] = unpackRgb(entry.rgb);
    return out;
}

fn buildShadeLut(palette: [world_mod.default_palette.len]world_mod.PaletteEntry) [world_mod.default_palette.len][4][4][2]u32 {
    var lut: [world_mod.default_palette.len][4][4][2]u32 = undefined;
    for (palette, 0..) |entry, m| {
        const cp = entry.rgb;
        for (face_factor, 0..) |ff, fi| {
            for (ao_factor, 0..) |af, ai| {
                for (0..2) |sky| {
                    const sky_f: f32 = if (sky == 1) 1.0 else sky_ambient;
                    const factor = if (entry.emissive != 0) 1.0 else ff * af * sky_f;
                    const r: u32 = @intFromFloat(@as(f32, @floatFromInt((cp >> 16) & 0xff)) * factor);
                    const g: u32 = @intFromFloat(@as(f32, @floatFromInt((cp >> 8) & 0xff)) * factor);
                    const b: u32 = @intFromFloat(@as(f32, @floatFromInt(cp & 0xff)) * factor);
                    lut[m][fi][ai][sky] = 0xff000000 | (r << 16) | (g << 8) | b;
                }
            }
        }
    }
    return lut;
}

/// Rebuild the shade LUT after a palette mutation (milestone 10 calls
/// this per frame while animating).
pub fn rebuildShadeLut() void {
    shade_lut = buildShadeLut(world_mod.palette);
    shade_lut_v4 = unpackLut(shade_lut);
    light_v4 = unpackPalette(world_mod.palette);
}

/// Distance fog (milestone 8). fog_factor buckets the selected
/// RenderParams.fog_curve falloff over [0, fog_cutoff]; fog_dest is
/// the low-pass variant: each material's color pre-collapses toward
/// the shared fog color on a front-loaded curve, so distant hues die
/// before the geometry fades, killing sub-pixel chromatic shimmer at
/// 480x270.
/// Emissive materials ride separate row rules: the destination lerps
/// toward a saturated version of their own color on a half-density
/// curve (volumetric neon haze) and THEN toward the fog color on the
/// full-density curve, so the haze tints the mid-range but emissives
/// still converge to the fog color at the cutoff like everything
/// else (the unblended haze read as too bright through fog).
/// fogStopsV interpolates between adjacent buckets — plain truncation
/// left visible bands at the bucket boundaries while moving.
pub const fog_buckets = 64;

var fog_factor: [fog_buckets]f32 = undefined;
var fog_dest: [world_mod.default_palette.len][fog_buckets]u32 = undefined;
var fog_dest_v4: [world_mod.default_palette.len][fog_buckets]V4 = undefined;

/// RGB channel math as f32x4 (alpha lane unused, forced to 0xff on
/// pack). Per-lane op order matches the scalar original, so results
/// stay bit-identical.
pub const V4 = @Vector(4, f32);

fn unpackRgb(c: u32) V4 {
    return .{
        @floatFromInt((c >> 16) & 0xff),
        @floatFromInt((c >> 8) & 0xff),
        @floatFromInt(c & 0xff),
        0,
    };
}

pub fn packRgb(v: V4) u32 {
    const iv: @Vector(4, u32) = @intFromFloat(v);
    return 0xff000000 | (iv[0] << 16) | (iv[1] << 8) | iv[2];
}

/// The shading stages historically round-tripped through u32 with a
/// truncating conversion per stage; keeping the pipeline in the vector
/// domain with an explicit @trunc per stage reproduces those
/// intermediate integer values exactly while packing only once.
fn lerpColorV(a: V4, b: V4, f: f32) V4 {
    return @trunc(a + (b - a) * @as(V4, @splat(f)));
}

pub fn lerpColor(a: u32, b: u32, f: f32) u32 {
    return packRgb(lerpColorV(unpackRgb(a), unpackRgb(b), f));
}

/// Fog curves (see render.FogCurve). old: normalized exponential
/// falloff. clear: `(exp(k*x) - 1) / (exp(k) - 1)` over fractional
/// x = t/cutoff with k = density*cutoff — nearly clear through the
/// midrange, steep only near the cutoff. Both are 0 at t=0 and exactly
/// 1 at the cutoff, so geometry at the march limit is
/// indistinguishable from the fogged horizon.
fn fogCurve(curve: FogCurve, density: f32, t: f32, cutoff: f32) f32 {
    return switch (curve) {
        .old => (1.0 - @exp(-density * t)) / (1.0 - @exp(-density * cutoff)),
        .clear => clearShape(density * cutoff, t / cutoff),
    };
}

fn clearShape(k: f32, x: f32) f32 {
    return std.math.expm1(k * x) / std.math.expm1(k);
}

pub fn buildFogLuts(params: RenderParams) void {
    const buckets_f: f32 = @floatFromInt(fog_buckets - 1);
    for (0..fog_buckets) |b| {
        const t = @as(f32, @floatFromInt(b)) * params.fog_cutoff / buckets_f;
        fog_factor[b] = fogCurve(params.fog_curve, params.fog_density, t, params.fog_cutoff);
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
                const t = @as(f32, @floatFromInt(b)) * params.fog_cutoff / buckets_f;
                const haze = lerpColor(entry.rgb, sat, fogCurve(params.fog_curve, params.fog_density * 0.5, t, params.fog_cutoff));
                fog_dest[m][b] = lerpColor(haze, params.fog_color, fogCurve(params.fog_curve, params.fog_density, t, params.fog_cutoff));
            }
        } else {
            for (0..fog_buckets) |b| {
                const f = fog_factor[b];
                const lp = 1.0 - (1.0 - f) * (1.0 - f);
                fog_dest[m][b] = lerpColor(entry.rgb, params.fog_color, lp);
            }
        }
        for (0..fog_buckets) |b| fog_dest_v4[m][b] = unpackRgb(fog_dest[m][b]);
    }
}

/// Shaded color at a fractional AO level: lerps between the two
/// adjacent LUT entries so gradients stay smooth instead of snapping
/// to the four discrete levels. sky is the analytic sky bit (1 = lit).
pub fn shadeAtV(mat: u8, face: usize, level: f32, sky: u1) V4 {
    const l = std.math.clamp(level, 0.0, 3.0);
    const lo: usize = @intFromFloat(l);
    const hi: usize = @min(lo + 1, 3);
    const frac = l - @as(f32, @floatFromInt(lo));
    const c0 = shade_lut_v4[mat][face][lo][sky];
    const c1 = shade_lut_v4[mat][face][hi][sky];
    return @trunc(c0 + (c1 - c0) * @as(V4, @splat(frac)));
}

pub fn shadeAt(mat: u8, face: usize, level: f32, sky: u1) u32 {
    return packRgb(shadeAtV(mat, face, level, sky));
}

pub const glow_gain: f32 = 0.5;

/// Additive glow tint (milestone 11): light ADDS its color on top of
/// the shaded base, so it can brighten and shift hue but never dim —
/// the milestone-9 multiplicative lerp-to-white it replaces scaled any
/// channel whose light color was below white below the unlit base,
/// making weakly lit surfaces DARKER than unlit ones. The additive
/// form reads in both regimes: over the dark cave ambient the added
/// term dominates (neon pooling), over sky-lit surfaces it is a
/// bounded tint that saturates only near the source. intensity 0 is
/// identity, so the flood edge still fades continuously.
pub fn applyGlowV(c: V4, light: lighting.LightSample) V4 {
    const f = @as(f32, @floatFromInt(light.intensity)) * (1.0 / 255.0) * glow_gain;
    return @trunc(@min(c + light_v4[light.color_id] * @as(V4, @splat(f)), @as(V4, @splat(255.0))));
}

/// Fog both stops of a segment: bucket the distances, lerp toward the
/// material's (pre-collapsed) fog destination. Per-stop so the
/// gradient fill lerps between fogged endpoints. LUT entries span
/// [0, fog_cutoff] inclusive (bucket 0 = t 0, the last = exactly the
/// cutoff, where the curve is 1.0), so both the factor and the
/// destination interpolate between the two straddling buckets; the
/// index math runs 2-wide.
pub fn fogStopsV(mat: u8, ts: [2]f32, cs: [2]V4, params: RenderParams) [2]V4 {
    const V2 = @Vector(2, f32);
    const buckets_f: f32 = @floatFromInt(fog_buckets - 1);
    const u = @min(@max(@as(V2, ts) * @as(V2, @splat(buckets_f / params.fog_cutoff)), @as(V2, @splat(0.0))), @as(V2, @splat(buckets_f)));
    const b0v: @Vector(2, u32) = @intFromFloat(u);
    const fr = u - @as(V2, @floatFromInt(b0v));
    var out: [2]V4 = undefined;
    inline for (0..2) |i| {
        const b0: usize = b0v[i];
        const b1: usize = @min(b0 + 1, fog_buckets - 1);
        const factor = fog_factor[b0] + (fog_factor[b1] - fog_factor[b0]) * fr[i];
        const dest = fog_dest_v4[mat][b0] + (fog_dest_v4[mat][b1] - fog_dest_v4[mat][b0]) * @as(V4, @splat(fr[i]));
        out[i] = lerpColorV(cs[i], dest, factor);
    }
    return out;
}

pub const max_sky_height = 4096;

pub fn skyColor(row: usize, height: usize) u32 {
    const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(height));
    const r: u32 = @intFromFloat(88.0 + (196.0 - 88.0) * t);
    const g: u32 = @intFromFloat(118.0 + (214.0 - 118.0) * t);
    const b: u32 = @intFromFloat(186.0 + (234.0 - 186.0) * t);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

test "fog lut is monotonic and saturates at the cutoff" {
    const params: RenderParams = .{};
    buildFogLuts(params);
    var prev: f32 = 0;
    for (fog_factor) |f| {
        try std.testing.expect(f >= prev);
        prev = f;
    }
    try std.testing.expectEqual(@as(f32, 0.0), fog_factor[0]);
    try std.testing.expect(fog_factor[1] > 0);
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

test "clear fog curve endpoints and midrange shape" {
    // Exactly 1 at the cutoff (hides the world edge/sky seam), 0 at
    // the origin, and nearly clear at the first LOD handoff (~2.5% at
    // x = 144/672 with k=4, vs ~91% under the old curve).
    const params: RenderParams = .{};
    buildFogLuts(params);
    defer buildFogLuts(params);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fog_factor[fog_buckets - 1], 0.01);
    const handoff_f = fog_factor[@intFromFloat(render.handoff0 / params.fog_cutoff * fog_buckets)];
    try std.testing.expect(handoff_f < 0.05);
    var prev: f32 = 0;
    for (fog_factor) |f| {
        try std.testing.expect(f >= prev);
        prev = f;
    }
    // The old curve remains selectable for the pinned fog_cutoff=96
    // tests; at its fog_k invariant the handoff is ~91% fogged.
    const old: RenderParams = .{ .fog_curve = .old, .fog_density = render.fog_k / render.draw_dist_default };
    buildFogLuts(old);
    try std.testing.expect(fog_factor[@intFromFloat(render.handoff0 / old.fog_cutoff * fog_buckets)] > 0.9);
}

test "emissive materials fade slower but converge to the fog color" {
    // Pinned cutoff + old curve at its fog_k density: the mid-bucket
    // expectations assume the milestone-24 96 cutoff, where a
    // mid-distance emissive still tints the haze visibly.
    const params: RenderParams = .{ .fog_cutoff = 96.0, .fog_curve = .old, .fog_density = render.fog_k / render.draw_dist_default };
    defer buildFogLuts(params);
    const saved = world_mod.palette[9];
    defer world_mod.palette[9] = saved;
    world_mod.palette[9].emissive = 1;
    buildFogLuts(params);
    const mid = fog_buckets / 2;
    // A normal material at the same distance is nearly all fog color...
    const normal = fog_dest[1][mid];
    try std.testing.expect(@abs(@as(i32, @intCast((normal >> 8) & 0xff)) - 0xa6) <= 8);
    // ...while the emissive crystal still tints the haze cyan...
    const glow = fog_dest[9][mid];
    try std.testing.expect((glow >> 8) & 0xff > 0xa6 + 10);
    try std.testing.expect(glow & 0xff > 0xd2 + 5);
    // ...but converges to the fog color at the cutoff.
    const far = fog_dest[9][fog_buckets - 1];
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const got: i32 = @intCast((far >> sh) & 0xff);
        const want: i32 = @intCast((params.fog_color >> sh) & 0xff);
        try std.testing.expect(@abs(got - want) <= 2);
    }
}
