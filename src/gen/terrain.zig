const std = @import("std");
const gen = @import("../gen.zig");
const world_mod = @import("../world.zig");
const Noise = @import("noise.zig").Noise;
const Builder = @import("builder.zig").Builder;

const World = world_mod.World;
const Camera = @import("../camera.zig").Camera;

pub const mat = struct {
    pub const bedrock: u8 = 8;
    pub const stone: u8 = 1;
    pub const dirt: u8 = 7;
    pub const grass: u8 = 4;
    pub const sand: u8 = 3;
    pub const arch: u8 = 6;
    pub const crystal_cyan: u8 = 9;
    pub const crystal_magenta: u8 = 10;
    pub const crystal_amber: u8 = 11;
};

/// Tile width/depth of the staged generation pipeline; origin-aligned
/// so a chunked load (STREAMING.md phase 1, same 64-column chunk)
/// regenerates exactly the whole-world tiling.
pub const tile_size = 64;

/// Arch placement region: at most one arch per region, decided by a
/// hash of the region coords. The arch footprint reaches <= 35 voxels
/// past its origin, so a tile only consults its own plus the ring-1
/// neighbor regions.
pub const region_size = 128;
const arch_candidates = 8;

/// Position-deterministic generation context (STREAMING.md phase 0):
/// everything a column, tile, or arch query needs, derived from the
/// seed and world height alone. No mutable state, so results never
/// depend on evaluation order — per-chunk gen equals whole-world gen.
pub const Ctx = struct {
    n_terrain: Noise,
    n_biome: Noise,
    n_mask: Noise,
    n_cave_a: Noise,
    n_cave_b: Noise,
    n_crystal: Noise,
    n_arch: Noise,
    h: usize,
    base: f32,
    plain_amp: f32,
    mount_amp: f32,
    sand_level: f32,
    hi_cap: i32,

    pub fn init(seed: u64, h: usize) Ctx {
        std.debug.assert(h > 12);
        const n_terrain = Noise.init(seed);
        const hf: f32 = @floatFromInt(h);
        const base = hf * 0.30;
        const plain_amp = hf * 0.02;
        return .{
            .n_terrain = n_terrain,
            .n_biome = n_terrain.reseed(0xB10BE),
            .n_mask = n_terrain.reseed(0x51ED),
            .n_cave_a = n_terrain.reseed(0xCA0EA),
            .n_cave_b = n_terrain.reseed(0xCA0EB),
            .n_crystal = n_terrain.reseed(0xC2757A1),
            .n_arch = n_terrain.reseed(0xA4C4),
            .h = h,
            .base = base,
            .plain_amp = plain_amp,
            .mount_amp = hf * 0.3,
            .sand_level = base - plain_amp * 0.45,
            .hi_cap = @intCast(h - 12),
        };
    }
};

const Span = struct { min: u16, max: u16 };

/// Topmost solid y of the heightfield at (x, z). Pure, so arches and
/// spawn compute flatness spans on the fly and any chunk/tile/LOD
/// synthesis path regenerates the same surface. Biome split (WORLDGEN.md):
/// a plains-biased continentality mask lerps flat plains into ridged
/// mountains, so relief is small on the plains and towers in the ranges.
pub fn heightAt(ctx: *const Ctx, x: i32, z: i32) u16 {
    const xf: f32 = @floatFromInt(x);
    const zf: f32 = @floatFromInt(z);
    const bn = ctx.n_biome.fbm2(xf / 384.0, zf / 384.0, 2);
    const t = std.math.clamp((bn + 0.1) / 0.7, 0.0, 1.0);
    const mask = t * t * (3.0 - 2.0 * t);
    const plains = ctx.n_terrain.fbm2(xf / 128.0, zf / 128.0, 3) * ctx.plain_amp;
    const ridged = 1.0 - @abs(ctx.n_terrain.fbm2(xf / 96.0, zf / 96.0, 4));
    const mountains = ridged * ctx.mount_amp;
    const hi: i32 = std.math.clamp(@as(i32, @intFromFloat(ctx.base + std.math.lerp(plains, mountains, mask))), 6, ctx.hi_cap);
    return @intCast(hi);
}

fn heightSpanAt(ctx: *const Ctx, x0: i32, z0: i32, wx: usize, wz: usize) Span {
    var lo: u16 = std.math.maxInt(u16);
    var hi: u16 = 0;
    for (0..wx) |dx| {
        for (0..wz) |dz| {
            const v = heightAt(ctx, x0 + @as(i32, @intCast(dx)), z0 + @as(i32, @intCast(dz)));
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    return .{ .min = lo, .max = hi };
}

/// Heightfield strata only — no caves or crystals. Coarse-LOD
/// synthesis uses this (the ~10x cheaper approx lever, STREAMING.md):
/// the 8-voxel skin keeps caves sub-surface, so coarse column tops
/// (and every above-ground silhouette) match exact synthesis, and the
/// interior voids it fills are invisible past the fog.
pub fn genColumnFast(ctx: *const Ctx, x: i32, z: i32, dense: []u8) void {
    @memset(dense, 0);
    const surface: usize = heightAt(ctx, x, z);
    const sandy = @as(f32, @floatFromInt(surface)) < ctx.sand_level;
    for (0..surface + 1) |y| {
        dense[y] = if (y == 0)
            mat.bedrock
        else if (y + 4 < surface)
            mat.stone
        else if (sandy)
            mat.sand
        else if (y == surface)
            mat.grass
        else
            mat.dirt;
    }
}

/// Fill the dense column at (x, z): heightfield strata, caves, and
/// crystals. Arches are NOT here — they cross tile boundaries, so they
/// stamp into the dense tile after all its columns are filled (before
/// run-encoding). Crystal rolls derive from a coordinate hash, so the
/// result is independent of column evaluation order.
pub fn genColumn(ctx: *const Ctx, x: i32, z: i32, dense: []u8) void {
    genColumnFast(ctx, x, z, dense);
    const surface: usize = heightAt(ctx, x, z);

    const xf: f32 = @floatFromInt(x);
    const zf: f32 = @floatFromInt(z);
    if (ctx.n_mask.noise2(xf / 40.0, zf / 40.0) > -0.1) {
        // Caves scaled for a 16-voxel-tall player (milestone 22):
        // tunnels ~10 wide x ~14-18 headroom. The 8-voxel solid
        // skin under the surface keeps caverns from breaching it.
        var y: usize = 2;
        while (y + 9 < surface) : (y += 1) {
            const yf: f32 = @floatFromInt(y);
            const a = ctx.n_cave_a.fbm3(xf / 24.0, yf / 36.0, zf / 24.0, 2);
            const b = ctx.n_cave_b.fbm3(xf / 24.0, yf / 36.0, zf / 24.0, 2);
            if (a * a + b * b < 0.05) dense[y] = 0;
        }

        y = 3;
        while (y + 5 < surface) : (y += 1) {
            if (dense[y] == 0 and dense[y - 1] != 0 and dense[y + 1] == 0 and dense[y + 2] == 0 and
                dense[y + 3] == 0 and dense[y + 4] == 0)
            {
                const roll = ctx.n_crystal.hash3(x, @intCast(y), z);
                if (roll % 48 == 0) {
                    const crystal = switch ((roll >> 32) % 3) {
                        0 => mat.crystal_cyan,
                        1 => mat.crystal_magenta,
                        else => mat.crystal_amber,
                    };
                    dense[y] = crystal;
                    dense[y + 1] = crystal;
                    dense[y + 2] = crystal;
                    dense[y + 3] = crystal;
                }
            }
        }
    }
}

pub const Arch = struct {
    x: i32,
    y: i32,
    z: i32,
    along_x: bool,
};

/// Candidate origin range on one axis: region-local [10, 88] (10
/// voxels of margin plus room for the 27+6 footprint), intersected
/// with the bounded world's [10, size-40] placement range. n <= 0
/// means the region cannot hold an arch.
fn archAxisRange(ri: i32, bound: ?usize) struct { lo: i32, n: i32 } {
    var lo: i32 = ri * region_size + 10;
    var hi: i32 = ri * region_size + 88;
    if (bound) |b| {
        lo = @max(lo, 10);
        hi = @min(hi, @as(i32, @intCast(b)) - 40);
    }
    return .{ .lo = lo, .n = hi - lo + 1 };
}

/// The region's arch, if any: up to arch_candidates hash-derived
/// positions, first one passing the bounds/flatness/height checks
/// wins. Depends only on (seed, region, bounds), never on visit order
/// — this replaces the pre-streaming global attempts loop and
/// farFromLandmarks. bounds = null for an unbounded world.
pub fn archInRegion(ctx: *const Ctx, rx: i32, rz: i32, bounds: ?[2]usize) ?Arch {
    const xr = archAxisRange(rx, if (bounds) |b| b[0] else null);
    const zr = archAxisRange(rz, if (bounds) |b| b[1] else null);
    if (xr.n <= 0 or zr.n <= 0) return null;
    const xn: u64 = @intCast(xr.n);
    const zn: u64 = @intCast(zr.n);
    for (0..arch_candidates) |i| {
        var v = ctx.n_arch.hash3(rx, @intCast(i), rz);
        const ax = xr.lo + @as(i32, @intCast(v % xn));
        v /= xn;
        const az = zr.lo + @as(i32, @intCast(v % zn));
        v /= zn;
        const span = heightSpanAt(ctx, ax, az, 29, 29);
        // Lenient flatness: legs partially buried in a slope are
        // fine, an arch split by a ridge is not.
        if (span.max - span.min > 12) continue;
        if (@as(i32, span.min) + 34 > @as(i32, @intCast(ctx.h))) continue; // lintel must not clip the world top
        return .{ .x = ax, .y = span.min, .z = az, .along_x = v & 1 == 0 };
    }
    return null;
}

/// True when an arch origin lies within min_dist of (x, z) — the old
/// farFromLandmarks check, answered per region instead of from a
/// global landmark list.
fn nearArch(ctx: *const Ctx, bounds: ?[2]usize, x: i32, z: i32, min_dist: i32) bool {
    const rx0 = @divFloor(x - min_dist, region_size);
    const rx1 = @divFloor(x + min_dist, region_size);
    const rz0 = @divFloor(z - min_dist, region_size);
    const rz1 = @divFloor(z + min_dist, region_size);
    var rx = rx0;
    while (rx <= rx1) : (rx += 1) {
        var rz = rz0;
        while (rz <= rz1) : (rz += 1) {
            if (archInRegion(ctx, rx, rz, bounds)) |a| {
                const dx = x - a.x;
                const dz = z - a.z;
                if (dx * dx + dz * dz < min_dist * min_dist) return true;
            }
        }
    }
    return false;
}

/// One arch stamp box (material fill), y clipped to [0, h]; XZ left
/// unclipped for the caller (tile clip or column containment).
pub const ArchBox = struct { x0: i32, z0: i32, x1: i32, z1: i32, y0: i32, y1: i32, m: u8 };

/// The four stamp boxes of an arch. Geometry identical to the
/// pre-streaming fillBox arch: 27w x 33h x 6 thick, 17x18 opening
/// stepped to a lintel (a 16-voxel-tall player walks through).
pub fn archBoxes(arch: Arch, h: usize) [4]ArchBox {
    const hi: i32 = @intCast(h);
    const spec = .{ .{ 0, 27, -3, 30, mat.arch }, .{ 5, 22, 0, 18, @as(u8, 0) }, .{ 8, 19, 18, 22, 0 }, .{ 10, 17, 22, 26, 0 } };
    var out: [4]ArchBox = undefined;
    inline for (spec, 0..) |s, i| {
        const l0: i32 = s[0];
        const l1: i32 = s[1];
        const ry0: i32 = s[2];
        const ry1: i32 = s[3];
        out[i] = .{
            .x0 = if (arch.along_x) arch.x + l0 else arch.x,
            .x1 = if (arch.along_x) arch.x + l1 else arch.x + 6,
            .z0 = if (arch.along_x) arch.z else arch.z + l0,
            .z1 = if (arch.along_x) arch.z + 6 else arch.z + l1,
            .y0 = @max(arch.y + ry0, 0),
            .y1 = @min(arch.y + ry1, hi),
            .m = s[4],
        };
    }
    return out;
}

/// All arches whose stamps can reach the area [x0,x1)x[z0,z1): the
/// regions covering the area plus ring-1 (the footprint reaches <= 35
/// voxels past its origin). Ascending (rx, rz) order — overlapping
/// arch stamps only commute under a fixed order.
pub fn collectArches(ctx: *const Ctx, x0: i32, z0: i32, x1: i32, z1: i32, bounds: ?[2]usize, out: *std.ArrayList(Arch), allocator: std.mem.Allocator) !void {
    const rx0 = @divFloor(x0, region_size) - 1;
    const rx1 = @divFloor(x1 - 1, region_size) + 1;
    const rz0 = @divFloor(z0, region_size) - 1;
    const rz1 = @divFloor(z1 - 1, region_size) + 1;
    var rx = rx0;
    while (rx <= rx1) : (rx += 1) {
        var rz = rz0;
        while (rz <= rz1) : (rz += 1) {
            if (archInRegion(ctx, rx, rz, bounds)) |arch| try out.append(allocator, arch);
        }
    }
}

/// One arch stamp box, clipped into the dense tile.
fn archBox(b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, box: ArchBox) void {
    const cx0 = @max(box.x0, tx0);
    const cx1 = @min(box.x1, tx0 + @as(i32, @intCast(tw)));
    const cz0 = @max(box.z0, tz0);
    const cz1 = @min(box.z1, tz0 + @as(i32, @intCast(td)));
    if (cx0 >= cx1 or box.y0 >= box.y1 or cz0 >= cz1) return;
    const y0: usize = @intCast(box.y0);
    const y1: usize = @intCast(box.y1);
    var x = cx0;
    while (x < cx1) : (x += 1) {
        var z = cz0;
        while (z < cz1) : (z += 1) {
            @memset(b.at(@intCast(x - tx0), @intCast(z - tz0))[y0..y1], box.m);
        }
    }
}

fn stampArch(b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, arch: Arch) void {
    for (archBoxes(arch, b.world.h)) |box| archBox(b, tx0, tz0, tw, td, box);
}

/// Apply every arch box covering column (x, z) — the per-column
/// counterpart of stampArch for column-granular synthesis (coarse-LOD
/// repair, STREAMING.md phase 2).
pub fn archOverlayColumn(arches: []const Arch, h: usize, x: i32, z: i32, dense: []u8) void {
    for (arches) |arch| {
        for (archBoxes(arch, h)) |box| {
            if (x >= box.x0 and x < box.x1 and z >= box.z0 and z < box.z1)
                @memset(dense[@intCast(box.y0)..@intCast(box.y1)], box.m);
        }
    }
}

/// Fill stage of the staged per-tile pipeline: dense-fill columns
/// [col0, col1) in linear (lx*td + lz) order — column-ranged so the
/// streamer can budget the fill across frames (STREAMING.md phase 2).
/// caves=false selects the approx coarse-LOD synthesis (genColumnFast).
pub fn genTileFill(ctx: *const Ctx, b: *Builder, tx0: i32, tz0: i32, td: usize, col0: usize, col1: usize, caves: bool) void {
    for (col0..col1) |ci| {
        const lx = ci / td;
        const lz = ci % td;
        const col = b.column(lx, lz);
        if (caves)
            genColumn(ctx, tx0 + @as(i32, @intCast(lx)), tz0 + @as(i32, @intCast(lz)), col)
        else
            genColumnFast(ctx, tx0 + @as(i32, @intCast(lx)), tz0 + @as(i32, @intCast(lz)), col);
    }
}

/// Arch stage: stamp the arches of the 3x3 region neighborhood into
/// the filled dense tile. Runs once per tile after its fill completes.
pub fn genTileArches(ctx: *const Ctx, b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, bounds: ?[2]usize) !void {
    var arches: std.ArrayList(Arch) = .empty;
    defer arches.deinit(b.allocator);
    try collectArches(ctx, tx0, tz0, tx0 + @as(i32, @intCast(tw)), tz0 + @as(i32, @intCast(td)), bounds, &arches, b.allocator);
    for (arches.items) |arch| stampArch(b, tx0, tz0, tw, td, arch);
}

/// Dense stage of the staged per-tile pipeline: fill + arch stamps.
/// No world writes — coarse-LOD synthesis (STREAMING.md phase 2)
/// consumes the dense tile directly. Tile origins are i32 so negative
/// chunk coords work in the unbounded world.
pub fn genTileDense(ctx: *const Ctx, b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, bounds: ?[2]usize) !void {
    genTileFill(ctx, b, tx0, tz0, td, 0, tw * td, true);
    try genTileArches(ctx, b, tx0, tz0, tw, td, bounds);
}

/// Emit stage: run-encode the dense tile into the world. keep_light
/// preserves the columns' light runs (a chunk load writes terrain over
/// the pre-gen flood; see chunk.loadChunk).
pub fn emitTile(b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, keep_light: bool) !void {
    for (0..tw) |lx| {
        for (0..td) |lz| {
            try b.emit(tx0 + @as(i32, @intCast(lx)), tz0 + @as(i32, @intCast(lz)), lx, lz, keep_light);
        }
    }
}

/// The full pipeline (dense -> emit), exactly what a phase-1 chunk
/// load runs, so chunk gen == whole-world gen.
pub fn genTile(ctx: *const Ctx, b: *Builder, tx0: i32, tz0: i32, tw: usize, td: usize, bounds: ?[2]usize) !void {
    try genTileDense(ctx, b, tx0, tz0, tw, td, bounds);
    try emitTile(b, tx0, tz0, tw, td, false);
}

/// First acceptably flat spot on an expanding square-ring search near
/// the origin (bounded worlds clamp candidates into the world), at
/// least 20 voxels from any arch. Falls back to the world center
/// (bounded) or the origin (unbounded).
fn findSpawn(ctx: *const Ctx, bounds: ?[2]usize) struct { i32, i32 } {
    var r: i32 = 0;
    while (r <= 256) : (r += 4) {
        const side: i32 = @max(r * 2, 1);
        var s: i32 = 0;
        while (s < 4) : (s += 1) {
            var k: i32 = 0;
            while (k < side) : (k += 4) {
                const cx: i32, const cz: i32 = switch (s) {
                    0 => .{ k - r, -r },
                    1 => .{ r, k - r },
                    2 => .{ r - k, r },
                    else => .{ -r, r - k },
                };
                if (r > 0 and k == 0 and s > 0) continue; // shared corners
                const sx = if (bounds) |b| std.math.clamp(cx, 6, @as(i32, @intCast(b[0])) - 12) else cx;
                const sz = if (bounds) |b| std.math.clamp(cz, 6, @as(i32, @intCast(b[1])) - 12) else cz;
                const span = heightSpanAt(ctx, sx, sz, 6, 6);
                if (span.max - span.min > 2) continue;
                if (nearArch(ctx, bounds, sx, sz, 20)) continue;
                return .{ sx, sz };
            }
            if (r == 0) break;
        }
    }
    return .{ if (bounds) |b| @divTrunc(@as(i32, @intCast(b[0])), 2) else 0, if (bounds) |b| @divTrunc(@as(i32, @intCast(b[1])), 2) else 0 };
}

pub const SpawnPoint = struct { cam: Camera, landmarks: []gen.Landmark };

/// Spawn camera + landmark list without generating a world
/// (STREAMING.md phase 2: the unbounded default world never generates
/// eagerly). Landmarks = the arches of the regions near spawn
/// (headless debug logging + spawn yaw); bounds = null for the
/// unbounded world.
pub fn spawnPoint(allocator: std.mem.Allocator, ctx: *const Ctx, bounds: ?[2]usize) !SpawnPoint {
    const spawn_x, const spawn_z = findSpawn(ctx, bounds);

    var landmarks: std.ArrayList(gen.Landmark) = .empty;
    errdefer landmarks.deinit(allocator);
    {
        const rx0 = @divFloor(spawn_x - 192, region_size);
        const rx1 = @divFloor(spawn_x + 192, region_size);
        const rz0 = @divFloor(spawn_z - 192, region_size);
        const rz1 = @divFloor(spawn_z + 192, region_size);
        var rx = rx0;
        while (rx <= rx1) : (rx += 1) {
            var rz = rz0;
            while (rz <= rz1) : (rz += 1) {
                if (archInRegion(ctx, rx, rz, bounds)) |a|
                    try landmarks.append(allocator, .{ .x = a.x, .y = a.y, .z = a.z });
            }
        }
    }

    const spawn_ground: f32 = @floatFromInt(heightAt(ctx, spawn_x, spawn_z));
    var yaw: f32 = std.math.pi / 4.0;
    var best_dist: i32 = std.math.maxInt(i32);
    for (landmarks.items) |lm| {
        const dx: i32 = lm.x - spawn_x;
        const dz: i32 = lm.z - spawn_z;
        const dist = dx * dx + dz * dz;
        if (dist < best_dist) {
            best_dist = dist;
            yaw = std.math.atan2(@as(f32, @floatFromInt(dz)), @as(f32, @floatFromInt(dx)));
        }
    }

    return .{
        .cam = .{
            .x = @as(f32, @floatFromInt(spawn_x)) + 0.5,
            // Feet rest on the surface voxel's top face; the eye rides
            // 14 voxels up (the milestone-23 walking player's eye
            // height). The min() clamp only binds in tiny test worlds.
            .y = @min(spawn_ground + 15.0, @as(f32, @floatFromInt(ctx.h)) - 1),
            .z = @as(f32, @floatFromInt(spawn_z)) + 0.5,
            .yaw = yaw,
        },
        .landmarks = try landmarks.toOwnedSlice(allocator),
    };
}

pub fn generate(allocator: std.mem.Allocator, opts: gen.Options) !gen.Result {
    return generateTiled(allocator, opts, tile_size);
}

fn generateTiled(allocator: std.mem.Allocator, opts: gen.Options, tile: usize) !gen.Result {
    std.debug.assert(opts.w >= 32 and opts.h >= 24 and opts.d >= 32);

    var world = try World.init(allocator, opts.w, opts.h, opts.d);
    errdefer world.deinit();

    const ctx = Ctx.init(opts.seed, opts.h);
    const bounds: ?[2]usize = .{ opts.w, opts.d };

    var builder = try Builder.init(allocator, &world, tile, tile);
    defer builder.deinit();

    var tx: usize = 0;
    while (tx < opts.w) : (tx += tile) {
        var tz: usize = 0;
        while (tz < opts.d) : (tz += tile) {
            try genTile(&ctx, &builder, @intCast(tx), @intCast(tz), @min(tile, opts.w - tx), @min(tile, opts.d - tz), bounds);
        }
    }

    const sp = try spawnPoint(allocator, &ctx, bounds);
    return .{ .world = world, .spawn = sp.cam, .landmarks = sp.landmarks };
}

fn expectCoverage(world: *const World, x: i32, z: i32) !void {
    const col = world.columnAt(x, z).?;
    var total: usize = 0;
    for (col.runs) |run| {
        try std.testing.expect(run.count > 0);
        total += run.count;
    }
    try std.testing.expectEqual(world.h, total);
    if (col.light) |runs| {
        var ltotal: usize = 0;
        for (runs) |run| {
            try std.testing.expect(run.count > 0);
            ltotal += run.count;
        }
        try std.testing.expect(ltotal <= world.h);
    }
}

fn worldsEqual(a: *const World, b: *const World) bool {
    if (a.w != b.w or a.h != b.h or a.d != b.d) return false;
    for (0..a.w.?) |x| {
        for (0..a.d.?) |z| {
            const ca = a.columnAt(@intCast(x), @intCast(z)).?;
            const cb = b.columnAt(@intCast(x), @intCast(z)).?;
            if (ca.runs.len != cb.runs.len) return false;
            for (ca.runs, cb.runs) |ra, rb| {
                if (ra.count != rb.count or ra.palette_id != rb.palette_id) return false;
            }
            if ((ca.light == null) != (cb.light == null)) return false;
            if (ca.light) |la| {
                const lb = cb.light.?;
                if (ca.light_base_y != cb.light_base_y or la.len != lb.len) return false;
                for (la, lb) |ra, rb| {
                    if (ra.count != rb.count or ra.color_id != rb.color_id or ra.intensity != rb.intensity) return false;
                }
            }
        }
    }
    return true;
}

const test_opts: gen.Options = .{ .seed = 7, .w = 64, .h = 96, .d = 64 };

test "generation is deterministic per seed" {
    var r1 = try generate(std.testing.allocator, test_opts);
    defer r1.deinit(std.testing.allocator);
    var r2 = try generate(std.testing.allocator, test_opts);
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(worldsEqual(&r1.world, &r2.world));
    try std.testing.expectEqual(r1.spawn, r2.spawn);

    var r3 = try generate(std.testing.allocator, .{ .seed = 8, .w = 64, .h = 96, .d = 64 });
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(!worldsEqual(&r1.world, &r3.world));
}

test "generation is independent of the tile subdivision" {
    var r1 = try generateTiled(std.testing.allocator, test_opts, 64);
    defer r1.deinit(std.testing.allocator);
    var r2 = try generateTiled(std.testing.allocator, test_opts, 16);
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(worldsEqual(&r1.world, &r2.world));
}

test "columns stay covered and terrain in bounds" {
    var r = try generate(std.testing.allocator, test_opts);
    defer r.deinit(std.testing.allocator);
    for (0..r.world.w.?) |x| {
        for (0..r.world.d.?) |z| {
            try expectCoverage(&r.world, @intCast(x), @intCast(z));
            try std.testing.expect(r.world.get(@intCast(x), 0, @intCast(z)) != 0);
        }
    }
}

test "caves and arches exist" {
    var r = try generate(std.testing.allocator, test_opts);
    defer r.deinit(std.testing.allocator);

    var underground_air: usize = 0;
    for (0..r.world.w.?) |x| {
        for (0..r.world.d.?) |z| {
            const top: i32 = @intCast(r.world.columnAt(@intCast(x), @intCast(z)).?.top_solid_y);
            var y: i32 = 3;
            while (y + 4 < top) : (y += 1) {
                if (r.world.get(@intCast(x), y, @intCast(z)) == 0) underground_air += 1;
            }
        }
    }
    try std.testing.expect(underground_air > 64);

    try std.testing.expect(r.landmarks.len > 0);
    for (r.landmarks) |lm| {
        try std.testing.expectEqual(mat.arch, r.world.get(lm.x, lm.y, lm.z));
        // Orientation shows in the lintel (top beam, always arch): exactly
        // one of the +x / +z mid-beam probes is arch material. Probing the
        // opening instead is unreliable — terrain beside the arch can be
        // legitimately lower than the opening.
        const x_beam = r.world.get(lm.x + 13, lm.y + 28, lm.z) == mat.arch;
        const z_beam = r.world.get(lm.x, lm.y + 28, lm.z + 13) == mat.arch;
        try std.testing.expect(x_beam != z_beam);
    }
}

test "caves have player-height headroom" {
    // w/d < 51 disables arches, so every long enclosed air streak is a
    // cave. The milestone-23 walking player is 16 voxels tall.
    var r = try generate(std.testing.allocator, .{ .seed = 7, .w = 48, .h = 96, .d = 48 });
    defer r.deinit(std.testing.allocator);
    var walkable: usize = 0;
    for (0..r.world.w.?) |x| {
        for (0..r.world.d.?) |z| {
            const top: i32 = @intCast(r.world.columnAt(@intCast(x), @intCast(z)).?.top_solid_y);
            var streak: i32 = 0;
            var y: i32 = top - 5; // below the surface skin
            while (y >= 2) : (y -= 1) {
                if (r.world.get(@intCast(x), y, @intCast(z)) == 0) {
                    streak += 1;
                    if (streak >= 16) {
                        walkable += 1;
                        break;
                    }
                } else {
                    streak = 0;
                }
            }
        }
    }
    try std.testing.expect(walkable > 0);
}

test "biome split yields both plains and mountains" {
    // Sample the pure heightfield over a few mask wavelengths: plains
    // must dominate (flat, near base) and real mountains must exist.
    const ctx = Ctx.init(1337, 256);
    var flat_cols: usize = 0; // relief proxy: height within plains band
    var high_cols: usize = 0; // mountain proxy: well above base
    var total: usize = 0;
    var lo: u16 = std.math.maxInt(u16);
    var hi: u16 = 0;
    var z: i32 = -2048;
    while (z <= 2048) : (z += 8) {
        var x: i32 = -2048;
        while (x <= 2048) : (x += 8) {
            const h = heightAt(&ctx, x, z);
            lo = @min(lo, h);
            hi = @max(hi, h);
            const hf: f32 = @floatFromInt(h);
            if (hf < ctx.base + 3.0 * ctx.plain_amp) flat_cols += 1;
            if (hf > ctx.base + 0.5 * ctx.mount_amp) high_cols += 1;
            total += 1;
        }
    }
    try std.testing.expect(hi > @as(u16, @intFromFloat(ctx.base + 0.5 * ctx.mount_amp)));
    try std.testing.expect(flat_cols * 2 > total); // plains are the majority biome
}
