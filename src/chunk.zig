const std = @import("std");
const world_mod = @import("world.zig");
const lighting = @import("lighting.zig");
const terrain = @import("gen/terrain.zig");
const Builder = @import("gen/builder.zig").Builder;

const World = world_mod.World;
const chunk_w = world_mod.chunk_w;

/// Chunk lifecycle (STREAMING.md phase 1). Kept out of world.zig so
/// the storage layer needs no upward imports: loadChunk drives the
/// terrain tile pipeline, unloadChunk drives a lighting relight.

/// Bring the chunk at (cx, cz) resident and fill it by running the
/// staged tile pipeline (dense fill -> arch stamps -> run-encode) over
/// its 64x64 tile — identical to the eager whole-world tiling, so chunk
/// gen == whole-world gen. Light runs stay null until the phase-2
/// chunk flood. builder must be a 64x64 tile over `world`.
pub fn loadChunk(world: *World, ctx: *const terrain.Ctx, builder: *Builder, cx: i32, cz: i32, bounds: ?[2]usize) !void {
    std.debug.assert(builder.tw == chunk_w and builder.td == chunk_w);
    _ = try world.ensureChunk(cx, cz);
    var tw: usize = chunk_w;
    var td: usize = chunk_w;
    if (world.w) |w| tw = @min(tw, w - @as(usize, @intCast(cx)) * chunk_w);
    if (world.d) |d| td = @min(td, d - @as(usize, @intCast(cz)) * chunk_w);
    try terrain.genTile(ctx, builder, cx * chunk_w, cz * chunk_w, tw, td, bounds);
}

/// Drop the chunk at (cx, cz): blank its materials (keeping the light
/// runs so relight's stale-seed clear can find the orphaned chains),
/// relight the chunk box, then free. Neighbor chunks keep the
/// corrected light; the dropped terrain regenerates identically on
/// reload. Non-resident chunk: no-op. Chunk coords must be
/// non-negative (Region is usize; signed regions are a phase-2 item).
pub fn unloadChunk(world: *World, cx: i32, cz: i32, params: lighting.Params) !void {
    std.debug.assert(cx >= 0 and cz >= 0);
    const chunk = world.chunks.get(world_mod.chunkKey(cx, cz)) orelse return;
    try world.blankChunk(chunk);
    const x0: usize = @intCast(cx * chunk_w);
    const z0: usize = @intCast(cz * chunk_w);
    const x1 = if (world.w) |w| @min(x0 + chunk_w, w) else x0 + chunk_w;
    const z1 = if (world.d) |d| @min(z0 + chunk_w, d) else z0 + chunk_w;
    _ = try lighting.relight(world, world.allocator, .{ .x0 = x0, .y0 = 0, .z0 = z0, .x1 = x1, .y1 = world.h, .z1 = z1 }, params);
    world.freeChunk(cx, cz);
}

test "loadChunk matches eager whole-world generation" {
    const allocator = std.testing.allocator;
    const gen = @import("gen.zig");
    const opts: gen.Options = .{ .seed = 7, .w = 128, .h = 96, .d = 128 }; // 2x2 chunks
    var r = try gen.generate(.terrain, allocator, opts);
    defer r.deinit(allocator);

    var world = try World.init(allocator, null, opts.h, null);
    defer world.deinit();
    const ctx = terrain.Ctx.init(opts.seed, opts.h);
    var builder = try Builder.init(allocator, &world, chunk_w, chunk_w);
    defer builder.deinit();
    const bounds: ?[2]usize = .{ opts.w, opts.d };
    for (0..2) |cx| {
        for (0..2) |cz| {
            try loadChunk(&world, &ctx, &builder, @intCast(cx), @intCast(cz), bounds);
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
