const std = @import("std");
const world_mod = @import("world.zig");
const lighting = @import("lighting.zig");
const terrain = @import("gen/terrain.zig");
const Builder = @import("gen/builder.zig").Builder;
const encodeDenseColumn = @import("gen/builder.zig").encodeDenseColumn;

const World = world_mod.World;
const chunk_w = world_mod.chunk_w;

/// Chunk lifecycle (plans/STREAMING.md phase 1). Kept out of world.zig so
/// the storage layer needs no upward imports: loadChunk drives the
/// terrain tile pipeline, unloadChunk drives a lighting relight.

/// Bring the chunk at (cx, cz) resident and fill it by running the
/// staged tile pipeline (dense fill -> run-encode) over
/// its 64x64 tile — identical to the eager whole-world tiling, so chunk
/// gen == whole-world gen. When light params are passed, the chunk box
/// then floods relight-style: the flood's confinement to resident
/// cells (lighting.propagate) means no stored chain can route through
/// the chunk's former absence, so the clear pass is a no-op and the
/// add pass — seed the chunk's emissives, propagate from the lit ring —
/// lands exactly the fixpoint a single flood over the resident set
/// computes. builder must be a 64x64 tile over `world`.
pub fn loadChunk(world: *World, ctx: *const terrain.Ctx, builder: *Builder, cx: i32, cz: i32, light: ?lighting.Params) !void {
    std.debug.assert(builder.tw == chunk_w and builder.td == chunk_w);
    _ = try world.ensureChunk(cx, cz);
    var tw: usize = chunk_w;
    var td: usize = chunk_w;
    if (world.w) |w| tw = @min(tw, w - @as(usize, @intCast(cx)) * chunk_w);
    if (world.d) |d| td = @min(td, d - @as(usize, @intCast(cz)) * chunk_w);
    const box: world_mod.Region = .{
        .x0 = cx * chunk_w,
        .y0 = 0,
        .z0 = cz * chunk_w,
        .x1 = cx * chunk_w + @as(i32, @intCast(tw)),
        .y1 = @intCast(world.h),
        .z1 = cz * chunk_w + @as(i32, @intCast(td)),
    };
    terrain.genTileDense(ctx, builder, box.x0, box.z0, tw, td);
    try commitChunk(world, builder, cx, cz, light);
}

/// Finishing step of a (possibly frame-sliced) chunk load: register
/// the chunk, run-encode the dense tile into it, and flood the chunk
/// box. The streamer fills the builder tile over several frames, then
/// commits in one step (plans/STREAMING.md phase 2).
pub fn commitChunk(world: *World, builder: *Builder, cx: i32, cz: i32, light: ?lighting.Params) !void {
    _ = try world.ensureChunk(cx, cz);
    var tw: usize = chunk_w;
    var td: usize = chunk_w;
    if (world.w) |w| tw = @min(tw, w - @as(usize, @intCast(cx)) * chunk_w);
    if (world.d) |d| td = @min(td, d - @as(usize, @intCast(cz)) * chunk_w);
    try terrain.emitTile(builder, cx * chunk_w, cz * chunk_w, tw, td, false);
    if (light) |params| {
        _ = try lighting.relight(world, world.allocator, .{ .x0 = cx * chunk_w, .y0 = 0, .z0 = cz * chunk_w, .x1 = cx * chunk_w + @as(i32, @intCast(tw)), .y1 = @intCast(world.h), .z1 = cz * chunk_w + @as(i32, @intCast(td)) }, params);
    }
}

/// Downsample one dense tile to half resolution: dst voxel =
/// material of the highest solid src voxel in its 2x2x2 block (scan
/// y top-down, then x/z in order) — exactly lod.rebuildColumn's rule
/// on dense data, so a dense pyramid equals iterated lod.build.
/// Column-major tiles ((lx*side + lz) * h + y); dst side = src side/2.
pub fn downsampleDense(src: []const u8, ss: usize, sh: usize, dst: []u8) void {
    const ds = ss / 2;
    const dh = (sh + 1) / 2;
    std.debug.assert(dst.len == ds * ds * dh);
    std.debug.assert(src.len == ss * ss * sh);
    for (0..ds) |lcx| {
        for (0..ds) |lcz| {
            const out = dst[(lcx * ds + lcz) * dh ..][0..dh];
            var yc: usize = 0;
            while (yc < dh) : (yc += 1) {
                const yf_hi = @min(2 * yc + 1, sh - 1);
                var m: u8 = 0;
                var yf = yf_hi + 1;
                scan: while (yf > 2 * yc) {
                    yf -= 1;
                    for (0..2) |dx| {
                        for (0..2) |dz| {
                            const v = src[((2 * lcx + dx) * ss + (2 * lcz + dz)) * sh + yf];
                            if (v != 0) {
                                m = v;
                                break :scan;
                            }
                        }
                    }
                }
                out[yc] = m;
            }
        }
    }
}

/// Dense tile side/height at level L for a 64-wide chunk: 64/2^L
/// columns, ceil(fine_h/2^L) voxels.
pub fn levelDims(fine_h: usize, level: u32) struct { side: usize, h: usize } {
    const shift: u6 = @intCast(level);
    return .{ .side = @as(usize, chunk_w) >> shift, .h = (fine_h + (@as(usize, 1) << shift) - 1) >> shift };
}

/// Coarse-LOD chunk load (plans/STREAMING.md phase 2 item 10): the chunk's
/// 64x64 coarse columns are synthesized from position-deterministic
/// fine generation (genColumn over the 64*2^level-wide
/// fine footprint, tiled through fine_builder) and downsampled through
/// a dense pyramid — never read from resident fine chunks, so coarse
/// content carries no edits: edit-driven lod.rebuildRegion patches
/// resident coarse columns, and resynthCoarseRegion restores gen
/// content when a fine chunk unloads. Light floods on load exactly
/// like loadChunk (a pure add pass under the flood's resident-cell
/// confinement). pyr[L-1] is scratch for the level-L dense tile
/// (levelDims); coarse_builder is a 64x64 tile over `coarse`.
pub fn loadCoarseChunk(coarse: *World, ctx: *const terrain.Ctx, fine_builder: *Builder, coarse_builder: *Builder, pyr: [][]u8, level: u32, cx: i32, cz: i32, light: ?lighting.Params, caves: bool) !void {
    std.debug.assert(level >= 1 and pyr.len >= level);
    const shift: u6 = @intCast(level);
    const fine_h = fine_builder.world.h;
    std.debug.assert(coarse.h == levelDims(fine_h, level).h);
    std.debug.assert(fine_builder.tw == chunk_w and fine_builder.td == chunk_w);
    std.debug.assert(coarse_builder.tw == chunk_w and coarse_builder.td == chunk_w);
    _ = try coarse.ensureChunk(cx, cz);
    var tw: usize = chunk_w;
    var td: usize = chunk_w;
    if (coarse.w) |w| tw = @min(tw, w - @as(usize, @intCast(cx)) * chunk_w);
    if (coarse.d) |d| td = @min(td, d - @as(usize, @intCast(cz)) * chunk_w);
    const box: world_mod.Region = .{
        .x0 = cx * chunk_w,
        .y0 = 0,
        .z0 = cz * chunk_w,
        .x1 = cx * chunk_w + @as(i32, @intCast(tw)),
        .y1 = @intCast(coarse.h),
        .z1 = cz * chunk_w + @as(i32, @intCast(td)),
    };
    const tiles = @as(usize, 1) << shift;
    const cper = @as(usize, chunk_w) >> shift;
    var ttx: usize = 0;
    while (ttx < tiles) : (ttx += 1) {
        var ttz: usize = 0;
        while (ttz < tiles) : (ttz += 1) {
            const tx0 = (box.x0 << @as(u5, @intCast(level))) + @as(i32, @intCast(ttx * chunk_w));
            const tz0 = (box.z0 << @as(u5, @intCast(level))) + @as(i32, @intCast(ttz * chunk_w));
            terrain.genTileFill(ctx, fine_builder, tx0, tz0, chunk_w, 0, chunk_w * chunk_w, caves);
            // Pyramid down to the target level, then copy the tile's
            // coarse columns into the coarse builder tile.
            var src = fine_builder.dense;
            var ss: usize = chunk_w;
            var sh: usize = fine_h;
            for (0..level) |l| {
                downsampleDense(src, ss, sh, pyr[l]);
                src = pyr[l];
                ss /= 2;
                sh = (sh + 1) / 2;
            }
            const dim = levelDims(fine_h, level);
            for (0..dim.side) |lx| {
                for (0..dim.side) |lz| {
                    @memcpy(coarse_builder.at(ttx * cper + lx, ttz * cper + lz), src[(lx * dim.side + lz) * dim.h ..][0..dim.h]);
                }
            }
        }
    }
    try terrain.emitTile(coarse_builder, box.x0, box.z0, tw, td, false);
    if (light) |params| {
        _ = try lighting.relight(coarse, coarse.allocator, box, params);
    }
}

/// One coarse column straight from generation: the 2^level x 2^level
/// fine columns under it, downsampled
/// through the dense pyramid. grid holds span*span*fine_h bytes of
/// dense fine scratch, pyr[L-1] the level-L grid (levelDims of the
/// span footprint), out the coarse world's h.
pub fn synthCoarseColumn(ctx: *const terrain.Ctx, level: u32, fine_h: usize, ccx: i32, ccz: i32, grid: []u8, pyr: [][]u8, out: []u8, caves: bool) void {
    std.debug.assert(level >= 1 and pyr.len >= level);
    const shift: u6 = @intCast(level);
    const span = @as(usize, 1) << shift;
    std.debug.assert(grid.len == span * span * fine_h);
    for (0..span) |dx| {
        for (0..span) |dz| {
            const fx = (ccx << @as(u5, @intCast(level))) + @as(i32, @intCast(dx));
            const fz = (ccz << @as(u5, @intCast(level))) + @as(i32, @intCast(dz));
            const col = grid[(dx * span + dz) * fine_h ..][0..fine_h];
            if (caves) terrain.genColumn(ctx, fx, fz, col) else terrain.genColumnFast(ctx, fx, fz, col);
        }
    }
    var src = grid;
    var ss: usize = span;
    var sh: usize = fine_h;
    for (0..level) |l| {
        downsampleDense(src, ss, sh, pyr[l]);
        src = pyr[l];
        ss /= 2;
        sh = (sh + 1) / 2;
    }
    std.debug.assert(out.len == sh);
    @memcpy(out, src[0..sh]);
}

/// Re-synthesize from generation the resident coarse columns covering
/// a fine-coords region — a fine chunk unload drops its edits, and the
/// coarse tiers must follow (plans/STREAMING.md phase 2). Skips non-resident
/// coarse columns; finishes with a coarse relight when light params
/// are passed (kept light runs let the stale-clear pass find chains
/// from the previous content). grid/pyr/col are caller scratch.
pub fn resynthCoarseRegion(coarse: *World, ctx: *const terrain.Ctx, level: u32, fine_h: usize, r: world_mod.Region, light: ?lighting.Params, caves: bool, grid: []u8, pyr: [][]u8, col: []u8, allocator: std.mem.Allocator) !void {
    const shift: u6 = @intCast(level);
    const span: i32 = @intCast(@as(usize, 1) << shift);
    const cx0 = @divFloor(r.x0, span);
    const cz0 = @divFloor(r.z0, span);
    const cx1 = @divFloor(r.x1 - 1, span) + 1;
    const cz1 = @divFloor(r.z1 - 1, span) + 1;
    var any = false;
    var cx = cx0;
    while (cx < cx1) : (cx += 1) {
        var cz = cz0;
        while (cz < cz1) : (cz += 1) {
            if (coarse.columnAtMut(cx, cz) == null) continue;
            synthCoarseColumn(ctx, level, fine_h, cx, cz, grid, pyr, col, caves);
            try encodeDenseColumn(coarse, cx, cz, col, light != null);
            any = true;
        }
    }
    if (light) |params| {
        if (any) {
            _ = try lighting.relight(coarse, allocator, .{ .x0 = cx0, .y0 = 0, .z0 = cz0, .x1 = cx1, .y1 = @intCast(coarse.h), .z1 = cz1 }, params);
        }
    }
}

/// Drop the chunk at (cx, cz): blank its materials (keeping the light
/// runs so relight's stale-seed clear can find the orphaned chains),
/// relight the chunk box, then free. Neighbor chunks keep the
/// corrected light; the dropped terrain regenerates identically on
/// reload. Non-resident chunk: no-op. Null params skip the relight
/// (lighting disabled).
pub fn unloadChunk(world: *World, cx: i32, cz: i32, params: ?lighting.Params) !void {
    const chunk = world.chunks.get(world_mod.chunkKey(cx, cz)) orelse return;
    try world.blankChunk(chunk);
    if (params) |p| {
        const x0 = cx * chunk_w;
        const z0 = cz * chunk_w;
        const x1 = if (world.w) |w| @min(x0 + chunk_w, @as(i32, @intCast(w))) else x0 + chunk_w;
        const z1 = if (world.d) |d| @min(z0 + chunk_w, @as(i32, @intCast(d))) else z0 + chunk_w;
        _ = try lighting.relight(world, world.allocator, .{ .x0 = x0, .y0 = 0, .z0 = z0, .x1 = x1, .y1 = @intCast(world.h), .z1 = z1 }, p);
    }
    world.freeChunk(cx, cz);
}

test "loadChunk matches eager whole-world generation" {
    const allocator = std.testing.allocator;
    const gen = @import("gen.zig");
    const opts: gen.Options = .{ .seed = 7, .w = 128, .h = 96, .d = 128 }; // 2x2 chunks
    var r = try gen.generate(.terrain, allocator, opts);
    defer r.deinit();

    var world = try World.init(allocator, null, opts.h, null);
    defer world.deinit();
    const ctx = terrain.Ctx.init(opts.seed, opts.h);
    var builder = try Builder.init(allocator, &world, chunk_w, chunk_w);
    defer builder.deinit();
    for (0..2) |cx| {
        for (0..2) |cz| {
            try loadChunk(&world, &ctx, &builder, @intCast(cx), @intCast(cz), null);
        }
    }

    for (0..opts.w) |x| {
        for (0..opts.d) |z| {
            const ca = r.world.columnAt(@intCast(x), @intCast(z)).?;
            const cb = world.columnAt(@intCast(x), @intCast(z)).?;
            try std.testing.expectEqual(ca.runs.len, cb.runs.len);
            for (ca.runs, cb.runs) |ra, rb| try std.testing.expectEqual(ra, rb);
            try std.testing.expectEqual(ca.top_solid_y, cb.top_solid_y);
            try std.testing.expect(cb.light == null);
        }
    }
}

test "per-chunk load floods match a single whole-world flood" {
    const allocator = std.testing.allocator;
    const gen = @import("gen.zig");
    const opts: gen.Options = .{ .seed = 17, .w = 192, .h = 96, .d = 128 }; // 3x2 chunks
    const params: lighting.Params = .{};

    // Reference: eager whole-world gen + one floodAll (bounded: the
    // flood is confined to the world box).
    var r = try gen.generate(.terrain, allocator, opts);
    defer r.deinit();
    _ = try lighting.floodAll(&r.world, allocator, params);

    // Chunked: unbounded world, chunks loaded one at a time with the
    // load flood, in a non-row-major order to pin order-independence.
    var world = try World.init(allocator, null, opts.h, null);
    defer world.deinit();
    const ctx = terrain.Ctx.init(opts.seed, opts.h);
    var builder = try Builder.init(allocator, &world, chunk_w, chunk_w);
    defer builder.deinit();
    const order = [_][2]i32{ .{ 1, 1 }, .{ 0, 0 }, .{ 2, 0 }, .{ 0, 1 }, .{ 2, 1 }, .{ 1, 0 } };
    for (order) |cc| try loadChunk(&world, &ctx, &builder, cc[0], cc[1], params);

    // Full-extent exact: the flood's confinement to resident cells
    // matches the bounded reference's box confinement one-to-one.
    // Intensity is compared strictly (the fixpoint intensity field is
    // unique); color only where intensities differ — an equal-
    // intensity color mismatch is a genuine two-seed tie (a bogus
    // color would extend its field past the reference's, which the
    // strict intensity check would catch along the path), and either
    // resolution is a valid fixpoint. Arrival dirs likewise differ at
    // ties and are not compared. (No stderr diagnostics: the 0.16
    // build runner displays any captured test stderr under a
    // misleading "failed command" header.)
    for (0..opts.w) |x| {
        for (0..opts.d) |z| {
            const ca = r.world.columnAt(@intCast(x), @intCast(z)).?;
            const cb = world.columnAt(@intCast(x), @intCast(z)).?;
            for (0..opts.h) |y| {
                const sa = lighting.sampleLight(ca, @intCast(y));
                const sb = lighting.sampleLight(cb, @intCast(y));
                try std.testing.expectEqual(sa.intensity, sb.intensity);
                const tied = sa.intensity != 0 and sa.color_id != sb.color_id;
                if (!tied) try std.testing.expectEqual(sa.color_id, sb.color_id);
            }
        }
    }
}

test "coarse chunk synthesis matches eager lod.build" {
    const allocator = std.testing.allocator;
    const gen = @import("gen.zig");
    const lod_mod = @import("lod.zig");
    const opts: gen.Options = .{ .seed = 17, .w = 256, .h = 96, .d = 256 };
    const params: lighting.Params = .{};

    // Eager references: bounded fine world, halved twice.
    var r = try gen.generate(.terrain, allocator, opts);
    defer r.deinit();
    var ref1 = try lod_mod.build(allocator, &r.world);
    defer ref1.deinit();
    var ref2 = try lod_mod.build(allocator, &ref1);
    defer ref2.deinit();
    _ = try lighting.floodAll(&ref1, allocator, params);

    const ctx = terrain.Ctx.init(opts.seed, opts.h);
    var fine_builder = try Builder.init(allocator, &r.world, chunk_w, chunk_w);
    defer fine_builder.deinit();

    // Level 1: 2x2 synthesized chunks cover the 128x48x128 coarse
    // world (shuffled order to pin order-independence).
    var c1 = try World.init(allocator, null, 48, null);
    defer c1.deinit();
    var cb1 = try Builder.init(allocator, &c1, chunk_w, chunk_w);
    defer cb1.deinit();
    const pyr1 = try allocator.alloc(u8, 32 * 32 * 48);
    defer allocator.free(pyr1);
    const pyr2 = try allocator.alloc(u8, 16 * 16 * 24);
    defer allocator.free(pyr2);
    const pyr = [_][]u8{ pyr1, pyr2 };
    const order = [_][2]i32{ .{ 1, 0 }, .{ 0, 1 }, .{ 0, 0 }, .{ 1, 1 } };
    for (order) |cc| try loadCoarseChunk(&c1, &ctx, &fine_builder, &cb1, @constCast(&pyr), 1, cc[0], cc[1], params, true);

    // Materials match over the full extent: generation is position-
    // deterministic, residency doesn't affect it.
    for (0..ref1.w.?) |x| {
        for (0..ref1.d.?) |z| {
            const ca = ref1.columnAt(@intCast(x), @intCast(z)).?;
            const cb = c1.columnAt(@intCast(x), @intCast(z)).?;
            try std.testing.expectEqual(ca.runs.len, cb.runs.len);
            for (ca.runs, cb.runs) |ra, rb| try std.testing.expectEqual(ra, rb);
        }
    }
    // Light too matches over the full extent (resident-cell
    // confinement == the bounded reference's box confinement), with
    // the fine parity test's tie rule.
    for (0..ref1.w.?) |x| {
        for (0..ref1.d.?) |z| {
            const ca = ref1.columnAt(@intCast(x), @intCast(z)).?;
            const cb = c1.columnAt(@intCast(x), @intCast(z)).?;
            for (0..ref1.h) |y| {
                const sa = lighting.sampleLight(ca, @intCast(y));
                const sb = lighting.sampleLight(cb, @intCast(y));
                try std.testing.expectEqual(sa.intensity, sb.intensity);
                const tied = sa.intensity != 0 and sa.color_id != sb.color_id;
                if (!tied) try std.testing.expectEqual(sa.color_id, sb.color_id);
            }
        }
    }

    // Level 2: one synthesized chunk covers the 64x24x64 world.
    var c2 = try World.init(allocator, null, 24, null);
    defer c2.deinit();
    var cb2 = try Builder.init(allocator, &c2, chunk_w, chunk_w);
    defer cb2.deinit();
    try loadCoarseChunk(&c2, &ctx, &fine_builder, &cb2, @constCast(&pyr), 2, 0, 0, null, true);
    for (0..ref2.w.?) |x| {
        for (0..ref2.d.?) |z| {
            const ca = ref2.columnAt(@intCast(x), @intCast(z)).?;
            const cb = c2.columnAt(@intCast(x), @intCast(z)).?;
            try std.testing.expectEqual(ca.runs.len, cb.runs.len);
            for (ca.runs, cb.runs) |ra, rb| try std.testing.expectEqual(ra, rb);
        }
    }
}

test "unloadChunk clears orphaned light like a full reflood" {
    const allocator = std.testing.allocator;
    const params: lighting.Params = .{};
    // 80x16x80 = 2x2 chunks. Cyan crystal at (62, 4, 40) sits 2 voxels
    // from the x=64 chunk border — its flood (reach 31) crosses into
    // chunk (1, 0). Amber crystal at (70, 4, 40) survives the unload.
    var world = try World.init(allocator, 80, 16, 80);
    defer world.deinit();
    try world.set(62, 4, 40, 9);
    try world.set(70, 4, 40, 11);
    _ = try lighting.floodAll(&world, allocator, params);
    _ = world.takeDirty();
    try std.testing.expect(world.columnAt(64, 40).?.light != null);

    try unloadChunk(&world, 0, 0, params);
    try std.testing.expectEqual(@as(?*const world_mod.Column, null), world.columnAt(10, 10));

    var ref = try World.init(allocator, 80, 16, 80);
    defer ref.deinit();
    try ref.set(70, 4, 40, 11);
    _ = try lighting.floodAll(&ref, allocator, params);

    for (64..80) |x| {
        for (0..80) |z| {
            const ca = world.columnAt(@intCast(x), @intCast(z)).?;
            const cb = ref.columnAt(@intCast(x), @intCast(z)).?;
            for (0..16) |y| {
                // Intensity and color only: arrival dirs may
                // legitimately differ from a fresh flood at
                // equal-level ties.
                const sa = lighting.sampleLight(ca, @intCast(y));
                const sb = lighting.sampleLight(cb, @intCast(y));
                try std.testing.expectEqual(sb.intensity, sa.intensity);
                try std.testing.expectEqual(sb.color_id, sa.color_id);
            }
        }
    }
    // The amber crystal's field reaches past the hole the unload left.
    try std.testing.expect(world.columnAt(70, 40).?.light != null);
}
