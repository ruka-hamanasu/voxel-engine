const std = @import("std");
const world_mod = @import("../world.zig");
const lighting = @import("../lighting.zig");
const render = @import("../render.zig");

const RenderParams = render.RenderParams;

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

pub fn lerpColor(a: u32, b: u32, f: f32) u32 {
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

pub fn buildFogLuts(params: RenderParams) void {
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

/// Shaded color at a fractional AO level: lerps between the two
/// adjacent LUT entries so gradients stay smooth instead of snapping
/// to the four discrete levels.
pub fn shadeAt(mat: u8, face: usize, level: f32) u32 {
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

/// Lerp-to-white glow tint (the Gemini doc's BlendWithGlow): intensity
/// scales tint strength, so intensity 0 is identity and the flood edge
/// fades continuously into unlit geometry instead of clipping to black.
pub fn applyLight(c: u32, light: lighting.LightSample) u32 {
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

/// Fog one shaded stop: bucket the distance, lerp toward the material's
/// (pre-collapsed) fog destination. Per-stop so the gradient fill
/// lerps between fogged endpoints.
pub fn fogStop(mat: u8, t: f32, c: u32, params: RenderParams) u32 {
    const scale = @as(f32, @floatFromInt(fog_buckets)) / params.fog_cutoff;
    const b: usize = @intFromFloat(std.math.clamp(t * scale, 0.0, @as(f32, @floatFromInt(fog_buckets - 1))));
    return lerpColor(c, fog_dest[mat][b], fog_factor[b]);
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
